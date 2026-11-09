# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
"""Real offline bundle install, SQL persistence, nginx and service HTTP/HTTPS.

Linux/root only. Uses fresh synthetic inputs and unique Compose projects; never
targets an operator deployment. This is not an IAM/model/workflow execution test.
"""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
from http.cookiejar import CookieJar
from urllib.error import HTTPError, URLError
from urllib.request import HTTPSHandler, HTTPCookieProcessor, ProxyHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "synthetic-registry-container-token-000000000000"
HMAC = "synthetic-container-hmac-key"
ADMIN = "ContainerInitial9!"
NEW_ADMIN = "ContainerUpdated9!"
CASES = [("mysql", False, False, False, False, True),
         ("postgresql", False, False, False, False, True),
         ("mysql", True, True, True, False, True),
         ("postgresql", True, True, True, False, True),
         ("mysql", False, True, True, False, True),
         ("mysql", True, True, True, True, True),
         ("mysql", True, True, True, True, False),
         ("mysql", True, False, False, False, True),
         ("mysql", True, True, False, False, True),
         ("mysql", True, False, True, False, True)]


def require_card(cards, description="Synthetic container test"):
    matches = [c for c in cards if c.get("name") == "ComposeAgent"
               and c.get("provider", {}).get("organization") == "ComposeOrg"]
    assert len(matches) == 1, "Expected registered card is missing or duplicated"
    assert matches[0]["description"] == description, "Card description was not persisted"
    assert matches[0]["version"] == "1.0", "Card version was not persisted"
    return matches[0]


def require_workflow(payload, workflow_id):
    workflow = payload["data"]
    assert workflow["id"] == workflow_id, "Wrong persisted workflow"
    assert workflow["name"] == "Compose workflow", "Workflow name was not persisted"
    assert len(workflow["steps"]) == 1, "Workflow steps were lost"
    subtask = workflow["steps"][0]["subtasks"][0]
    assert subtask["task_id"] == "t1" and subtask["skill"] == "skill_a", "Workflow task content was lost"


def seed_runtime_records(compose):
    """Seed via real storage components, not an external model or task execution."""
    code = """from orchestrate.sandbox.store import SandboxStore
from orchestrate.sandbox.models import SandboxRunReport, StubTemplate
from orchestrate.solution_package.manager import SolutionPackageManager
from orchestrate.core.model.preflow import PreFlow
from orchestrate.core.persistence import WorkflowStorage
s=SandboxStore()
s.save_report(SandboxRunReport(verification_id='compose-verification',workflow_id='compose-workflow',workflow_name='Compose workflow',scenario='success',verdict='pass'), [{'marker':'persisted-event'}])
s.save_templates('compose-workflow',[StubTemplate(template_id='compose-stub',response_text='persisted-stub')])
assert SolutionPackageManager().store_solution_package('compose-persistence.pdf', {'Synthetic chapter':'persisted-package'})
WorkflowStorage().save_preflow(PreFlow(id='compose-preflow',name='Compose preflow',steps_md='persisted-preflow'))
"""
    command("docker", "compose", "-f", str(compose), "exec", "-T", "orchestration-center", "python", "-c", code)


def require_runtime_records(compose):
    code = """from orchestrate.sandbox.store import SandboxStore
from orchestrate.core.persistence import WorkflowStorage
s=SandboxStore()
assert s.load_report('compose-verification')['events'] == [{'marker':'persisted-event'}]
assert s.load_templates('compose-workflow')[0].response_text == 'persisted-stub'
assert WorkflowStorage().load_preflow('compose-preflow').steps_md == 'persisted-preflow'
"""
    command("docker", "compose", "-f", str(compose), "exec", "-T", "orchestration-center", "python", "-c", code)


def audit_snapshot(compose, previous=None):
    """Prove old audit bytes survive replacement while new records can append."""
    code = """import hashlib,json,sys
from pathlib import Path
p=Path('log/audit/audit.log')
data=p.read_bytes()
assert data, 'No audit records to test'
before=json.load(sys.stdin)
if before:
    assert len(data)>=before['size'] and hashlib.sha256(data[:before['size']]).hexdigest()==before['sha256'], 'Audit history was lost'
print(json.dumps({'size':len(data),'sha256':hashlib.sha256(data).hexdigest()}))
"""
    output = command("docker", "compose", "-f", str(compose), "exec", "-T", "registry-center", "python", "-c", code,
                     input=json.dumps(previous)).stdout
    return json.loads(output)


def command(*args, check=True, input=None):
    result = subprocess.run(args, encoding="utf-8", capture_output=True, timeout=900, input=input)
    if check and result.returncode:
        raise RuntimeError(result.stdout[-4000:] + result.stderr[-4000:])
    return result


def diagnose(compose):
    """Dump container states on failure: exit codes, OOM/restart flags, health
    probe logs and service log tails. Without this, an unhealthy container
    leaves no evidence of WHY it failed."""
    def soft(*args):
        result = subprocess.run(args, encoding="utf-8", capture_output=True, timeout=120)
        return (result.stdout + result.stderr)[-4000:]
    try:
        states = soft("docker", "compose", "-f", str(compose), "ps", "-a", "--format", "json")
        print(f"DIAGNOSE ps:\n{states}", flush=True)
        names = subprocess.run(["docker", "compose", "-f", str(compose), "ps", "-a", "--format", "{{.Name}}"],
                               encoding="utf-8", capture_output=True, timeout=120)
        for name in [n for n in names.stdout.splitlines() if n.strip()]:
            inspect = soft("docker", "inspect", name,
                           "--format", "{{json .State}}")
            print(f"DIAGNOSE {name}: {inspect}", flush=True)
            logs = soft("docker", "logs", "--tail", "60", name)
            print(f"DIAGNOSE {name} logs tail:\n{logs}", flush=True)
    except Exception as error:  # diagnostics must never mask the original failure
        print(f"DIAGNOSE failed: {error}", flush=True)


def certificates(root):
    # CA with v3_ca extensions: OpenSSL 3.5+/Python 3.14 strict verification
    # (ssl.create_default_context) requires keyUsage on the issuing CA.
    ca = root / "ca"
    ca.mkdir()
    ca_config = root / "ca.cnf"
    ca_config.write_text("[req]\nprompt = no\ndistinguished_name = dn\nx509_extensions = v3_ca\n"
                         "[dn]\nCN = SyntheticComposeCA\n"
                         "[v3_ca]\nbasicConstraints = critical,CA:TRUE\n"
                         "keyUsage = critical,keyCertSign,cRLSign\n"
                         "subjectKeyIdentifier = hash\n")
    command("openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256", "-days", "1",
            "-config", str(ca_config), "-keyout", str(ca / "key.pem"), "-out", str(ca / "trust.cer"))
    server = root / "server"
    server.mkdir()
    command("openssl", "req", "-new", "-newkey", "rsa:3072", "-sha256", "-subj", "/CN=localhost",
            "-passout", "pass:Container#2026", "-keyout", str(server / "server_key.pem"), "-out", str(server / "server.csr"))
    extensions = root / "server.ext"
    extensions.write_text("basicConstraints=critical,CA:FALSE\n"
                          "keyUsage=critical,digitalSignature,keyEncipherment\n"
                          "extendedKeyUsage=serverAuth\n"
                          "subjectKeyIdentifier=hash\n"
                          "authorityKeyIdentifier=keyid,issuer\n"
                          "subjectAltName=DNS:registry-center,DNS:orchestration-center,DNS:localhost,IP:127.0.0.1\n")
    command("openssl", "x509", "-req", "-in", str(server / "server.csr"), "-CA", str(ca / "trust.cer"),
            "-CAkey", str(ca / "key.pem"), "-CAcreateserial", "-days", "1", "-sha256",
            "-extfile", str(extensions), "-out", str(server / "server.cer"))
    shutil.copyfile(ca / "trust.cer", server / "trust.cer")
    (server / "cert_pwd").write_text("Container#2026")
    client = root / "client"
    client.mkdir()
    command("openssl", "req", "-new", "-newkey", "rsa:3072", "-nodes", "-sha256", "-subj", "/CN=synthetic-client",
            "-keyout", str(client / "client_key.pem"), "-out", str(client / "client.csr"))
    extensions.write_text("basicConstraints=critical,CA:FALSE\n"
                          "keyUsage=critical,digitalSignature,keyEncipherment\n"
                          "extendedKeyUsage=clientAuth\n"
                          "subjectKeyIdentifier=hash\n"
                          "authorityKeyIdentifier=keyid,issuer\n")
    command("openssl", "x509", "-req", "-in", str(client / "client.csr"), "-CA", str(ca / "trust.cer"),
            "-CAkey", str(ca / "key.pem"), "-CAcreateserial", "-days", "1", "-sha256",
            "-extfile", str(extensions), "-out", str(client / "client.cer"))
    shutil.copyfile(ca / "trust.cer", client / "trust.cer")
    shutil.copyfile(client / "client.cer", server / "probe-client.cer")
    shutil.copyfile(client / "client_key.pem", server / "probe-client.key")
    signing = root / "signing"
    signing.mkdir()
    shutil.copyfile(server / "server.cer", signing / "sign.cer")
    shutil.copyfile(server / "server_key.pem", signing / "sign_key.pem")
    shutil.copyfile(server / "cert_pwd", signing / "cert_pwd")
    for directory in (server, client, signing):
        directory.chmod(0o700)
        os.chown(directory, 10001, 10001)
        for file in directory.iterdir():
            file.chmod(0o600)
            os.chown(file, 10001, 10001)
    return server, client, signing, ca / "trust.cer"


def request(opener, base, path, expected=200, method="GET", body=None, headers=None):
    req = Request(base + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                  headers={"Content-Type": "application/json", **(headers or {})})
    try:
        response = opener.open(req, timeout=15)
    except HTTPError as exc:
        response = exc
    with response:
        raw = response.read()
        assert response.status == expected, (path, response.status, raw[:500])
        return raw, response.headers


def exercise(opener, base, compose, first=True, workflow_id=None):
    registry = "/registry/rest/v1/registry-center/agent-cards"
    headers = {"Authorization": "Bearer " + TOKEN}
    request(opener, base, "/")
    request(opener, base, registry, expected=401)
    request(opener, base, registry, headers=headers)
    card = {"name": "ComposeAgent", "provider": {"organization": "ComposeOrg"}, "description": "Synthetic container test", "version": "1.0", "skills": []}
    target = registry + "/ComposeOrg/ComposeAgent"
    if first:
        request(opener, base, registry, expected=201, method="POST", body={"agentCards": [card]}, headers=headers)
    raw, _ = request(opener, base, target, headers=headers)
    signed = require_card(json.loads(raw)["agentCards"])
    assert signed["signatures"]
    verify = """import json, sys
from cryptography import x509
from a2a.types import AgentCard
from google.protobuf.json_format import ParseDict
from a2a.utils.signing import create_signature_verifier
key=x509.load_pem_x509_certificate(open('etc/sign_cert/sign.cer','rb').read()).public_key()
create_signature_verifier(lambda kid,jku:key,['RS256'])(ParseDict(json.load(sys.stdin),AgentCard()))
"""
    command("docker", "compose", "-f", str(compose), "exec", "-T", "registry-center", "python", "-c", verify, input=json.dumps(signed))
    request(opener, base, "/registry/rest/v1/registry-center/keys")
    auth = "/api/orchestrate/rest/v1/orchestrate/auth"
    if first:
        request(opener, base, auth + "/login", expected=401, method="POST", body={"username": "admin", "password": "OpenAN@2026"})
    _, cookie = request(opener, base, auth + "/login", method="POST", body={"username": "admin", "password": ADMIN if first else NEW_ADMIN})
    assert ("; secure" in cookie["Set-Cookie"].lower()) == base.startswith("https:")
    if first:
        request(opener, base, auth + "/change-password", method="POST", body={"old_password": ADMIN, "new_password": NEW_ADMIN})
        # A credential change revokes all sessions, including the login cookie.
        request(opener, base, auth + "/login", method="POST", body={"username": "admin", "password": NEW_ADMIN})
    # OC reaches RC through its own separately authenticated/TLS registry client.
    raw, _ = request(opener, base, "/api/orchestrate/rest/v1/orchestrate/agent-cards")
    require_card(json.loads(raw)["data"])
    workflows = "/api/orchestrate/rest/v1/orchestrate/workflows"
    if first:
        psop = {"id": "compose-workflow", "name": "Compose workflow", "description": "Synthetic",
                "steps": [{"name": "step", "type": "AllSuccess", "subtasks": [{"task_id": "t1", "description": "Synthetic", "agent": "agent_a", "skill": "skill_a", "status": "pending"}], "next": None, "layer": 0}], "tags": []}
        body, _ = request(opener, base, workflows, expected=201, method="POST", body={"psop": psop})
        workflow_id = json.loads(body)["data"]["workflow_id"]
    raw, _ = request(opener, base, workflows + "/" + workflow_id)
    require_workflow(json.loads(raw), workflow_id)
    external = "/api/v1/orchestrate/psop/" + workflow_id
    request(opener, base, external, expected=401)  # Cookie alone is not public API authorization.
    raw, _ = request(opener, base, "/api/orchestrate/api/v1/auth/token", method="POST",
                     body={"username": "admin", "password": NEW_ADMIN})
    bearer = {"Authorization": "Bearer " + json.loads(raw)["access_token"]}
    raw, _ = request(opener, base, external, headers=bearer)
    require_workflow(json.loads(raw), workflow_id)
    request(opener, base, "/api/orchestrate" + external, expected=401)
    raw, _ = request(opener, base, "/api/orchestrate" + external, headers=bearer)
    require_workflow(json.loads(raw), workflow_id)
    if first:
        seed_runtime_records(compose)
    require_runtime_records(compose)
    api = "/api/orchestrate/rest/v1/orchestrate"
    raw, _ = request(opener, base, api + "/sandbox/verifications/compose-verification")
    assert json.loads(raw)["data"]["events"] == [{"marker": "persisted-event"}]
    raw, _ = request(opener, base, api + "/sandbox/templates/compose-workflow")
    assert json.loads(raw)["data"][0]["response_text"] == "persisted-stub"
    raw, _ = request(opener, base, api + "/solution-packages/compose-persistence.pdf")
    assert json.loads(raw)["data"]["chapters"] == {"Synthetic chapter": "persisted-package"}
    if not first:
        request(opener, base, target, method="PUT", headers=headers, body={"agentCards": [dict(card, description="Updated")]})
        raw, _ = request(opener, base, target, headers=headers)
        require_card(json.loads(raw)["agentCards"], "Updated")
        request(opener, base, target, method="DELETE", headers=headers)
        # RC's published lookup contract is 200 + an empty agentCards list,
        # unlike OC's workflow lookup, which uses HTTP 404.
        raw, _ = request(opener, base, target, headers=headers)
        assert json.loads(raw)["agentCards"] == [], "Deleted card can still be retrieved"
        raw, _ = request(opener, base, registry, headers=headers)
        assert not any(c.get("name") == "ComposeAgent" for c in json.loads(raw)["agentCards"]), "Deleted card remains listed"
        request(opener, base, workflows + "/" + workflow_id, method="DELETE")
        request(opener, base, workflows + "/" + workflow_id, expected=404)
        request(opener, base, external, expected=404, headers=bearer)
    request(opener, base, "/api/orchestrate/api/v1/auth/logout", method="POST", headers=bearer)
    request(opener, base, external, expected=401, headers=bearer)
    request(opener, base, auth + "/logout", method="POST")
    request(opener, base, workflows, expected=401)
    return workflow_id


def wait_for_proxy(opener, base):
    """Allow only bounded DNS/transport recovery; never retry business mutations."""
    deadline = time.monotonic() + 30
    while True:
        try:
            request(opener, base, "/registry/rest/v1/registry-center/agent-cards", expected=401)
            request(opener, base, "/api/orchestrate/health")
            return
        except (AssertionError, URLError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(1)


def replace_backends(compose):
    """Consume freed addresses and require actual IP changes after replacement.

    Default Docker networks have automatic IPAM and reject --ip reservations.
    Use automatic allocation for blockers too; explicit assertions below prevent
    a same-address replacement from falsely passing the DNS regression.
    """
    services = ("registry-center", "orchestration-center")
    before = {}
    for service in services:
        cid = command("docker", "compose", "-f", str(compose), "ps", "-q", service).stdout.strip()
        networks = json.loads(command("docker", "inspect", "--format", "{{json .NetworkSettings.Networks}}", cid).stdout)
        assert len(networks) == 1
        network, details = next(iter(networks.items()))
        before[service] = (network, details["IPAddress"])
    proxy = command("docker", "compose", "-f", str(compose), "ps", "-q", "openan-nginx").stdout.strip()
    image = json.loads(compose.read_text())["services"]["openan-nginx"]["image"]
    blockers = []
    try:
        command("docker", "compose", "-f", str(compose), "stop", *services)
        command("docker", "compose", "-f", str(compose), "rm", "-f", *services)
        project = json.loads(compose.read_text())["name"]
        for index, (network, _) in enumerate(before.values()):
            name = f"{project}-dns-blocker-{index}"
            blockers.append(name)  # Also clean up containers whose start fails.
            command("docker", "run", "-d", "--name", name, "--network", network,
                    "--entrypoint", "sleep", image, "600")
        command("docker", "compose", "-f", str(compose), "up", "-d", "--no-deps", "--pull", "never",
                "--wait", "--wait-timeout", "180", *services)
        for service, (network, address) in before.items():
            cid = command("docker", "compose", "-f", str(compose), "ps", "-q", service).stdout.strip()
            networks = json.loads(command("docker", "inspect", "--format", "{{json .NetworkSettings.Networks}}", cid).stdout)
            assert networks[network]["IPAddress"] != address, "Backend IP did not change"
        assert command("docker", "compose", "-f", str(compose), "ps", "-q", "openan-nginx").stdout.strip() == proxy
    finally:
        for cid in blockers:
            command("docker", "rm", "-f", cid, check=False)


def run(bundle):
    if os.name == "nt" or os.geteuid() != 0 or not shutil.which("docker"):
        raise SystemExit("Requires Linux Docker and root for isolated UID=10001 fixtures")
    bundle = Path(bundle).resolve()
    with tempfile.TemporaryDirectory(prefix="openan-compose-smoke-") as temp:
        root = Path(temp)
        server, client, signing, ca = certificates(root)
        for index, (db, public_tls, registry_tls, orchestration_tls, mtls, verify_upstream) in enumerate(CASES):
            case = root / f"case-{index}"
            # Reuse immutable image files without copying gigabytes; this is a
            # controlled smoke fixture, not the distributed release layout.
            shutil.copytree(bundle, case, ignore=shutil.ignore_patterns("images", "runtime"))
            (case / "images").symlink_to(bundle / "images", target_is_directory=True)
            config = case / "config.env"
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            digest = hmac.new(HMAC.encode(), TOKEN.encode(), hashlib.sha256).hexdigest()
            credentials = case / "credentials.conf"
            credentials.write_text(f"credential.smoke.identity=synthetic\ncredential.smoke.token_hash={digest}\ncredential.smoke.role=nms_oss\n")
            credentials.chmod(0o600); os.chown(credentials, 10001, 10001)
            model = case / "models.yaml"
            model.write_text("models:\n  chat:\n    provider: openai_compatible\n    model: synthetic-model\n    url: http://127.0.0.1:9/v1/chat/completions\n")
            model.chmod(0o600); os.chown(model, 10001, 10001)
            (case / "rc.env").write_text(f"INTEGRATION_TOKEN_HMAC_KEY={HMAC}\nINTEGRATION_FINGERPRINT_KEY=synthetic-fingerprint\nREGISTRY_AGENT_APPROVAL_ENABLED=false\nREGISTRY_SIGNATURE_VALIDATION_ENABLED=false\nREGISTRY_HEARTBEAT_ENABLED=false\n")
            (case / "oc.env").write_text(f"OC_ADMIN_INITIAL_PASSWORD='{ADMIN}'\nREGISTRY_ACCESS_TOKEN={TOKEN}\nEXTRA_LITERAL='price $5 ${{NOT_EXPANDED}} # text'\n")
            settings = {"PROJECT_NAME": f"openan-smoke-{os.getpid()}-{index}", "PUBLIC_BIND": "127.0.0.1", "PUBLIC_PORT": str(port),
                        "PUBLIC_ENABLE_HTTPS": str(public_tls).lower(), "PUBLIC_TLS_DIR": str(server),
                        # Portal image is not published yet (openan-portal#11);
                        # the bundle built here carries only workflow-designer.
                        "FRONTEND_TYPE": "workflow-designer",
                        "DATABASE_TYPE": db, "DATABASE_INTERNAL": "true", "REGISTRY_DB_PASSWORD": "Registry'$\\Smoke9!",
                        "ORCH_DB_PASSWORD": "Orch'$\\Smoke9!", "POSTGRES_PASSWORD": "RootSmoke9!", "MYSQL_ROOT_PASSWORD": "RootSmoke9!",
                        "REGISTRY_ENABLE_HTTPS": str(registry_tls).lower(), "ORCH_ENABLE_HTTPS": str(orchestration_tls).lower(),
                        "REGISTRY_VERIFY_CLIENT": str(mtls).lower(), "ORCH_VERIFY_CLIENT": str(mtls).lower(),
                        "BACKEND_VERIFY_SERVER": str(verify_upstream).lower(), "ORCH_CLIENT_VERIFY_SERVER": str(verify_upstream).lower(),
                        "REGISTRY_TLS_DIR": str(server), "ORCH_TLS_DIR": str(server), "REGISTRY_PROXY_TLS_DIR": str(client),
                        "ORCH_PROXY_TLS_DIR": str(client), "REGISTRY_CLIENT_TLS_DIR": str(client),
                        "REGISTRY_SIGN_DIR": str(signing), "REGISTRY_CREDENTIAL_FILE": str(credentials),
                        "REGISTRY_MODELS_FILE": str(model), "ORCH_MODELS_FILE": str(model),
                        "REGISTRY_RUNTIME_ENV_FILE": str(case / "rc.env"), "ORCH_RUNTIME_ENV_FILE": str(case / "oc.env")}
            # shlex.quote keeps the deliberately awkward password literal.
            import shlex
            config.write_text("\n".join(key + "=" + shlex.quote(value) for key, value in settings.items()))
            compose = case / "runtime/compose.json"
            try:
                try:
                    command("bash", str(case / "scripts/install.sh"), "--config", str(config))
                except RuntimeError:
                    diagnose(compose)
                    raise
                command("docker", "compose", "-f", str(compose), "exec", "-T", "orchestration-center", "python", "-c",
                        "import os; assert os.environ['EXTRA_LITERAL'] == 'price $5 ${NOT_EXPANDED} # text'")
                opener = build_opener(ProxyHandler({}), HTTPCookieProcessor(CookieJar()), HTTPSHandler(context=ssl.create_default_context(cafile=str(ca))))
                base = f"{'https' if public_tls else 'http'}://127.0.0.1:{port}"
                wait_for_proxy(opener, base)
                workflow_id = exercise(opener, base, compose)
                history = audit_snapshot(compose)
                command("docker", "compose", "-f", str(compose), "restart", "registry-center", "orchestration-center")
                command("docker", "compose", "-f", str(compose), "up", "-d", "--pull", "never", "--wait", "--wait-timeout", "180")
                wait_for_proxy(opener, base)
                replace_backends(compose)
                wait_for_proxy(opener, base)
                exercise(opener, base, compose, first=False, workflow_id=workflow_id)
                audit_snapshot(compose, history)
                print(f"PASS: {db}, public_https={public_tls}, registry_https={registry_tls}, orchestration_https={orchestration_tls}, mtls={mtls}, verify_upstream={verify_upstream}, CRUD content/auth/signing/SQL+file persistence/backend IP replacement", flush=True)
            except BaseException:
                if compose.is_file():
                    for service in ("openan-mysql" if db == "mysql" else "openan-postgres", "registry-center", "orchestration-center", "openan-nginx"):
                        print(command("docker", "compose", "-f", str(compose), "logs", "--tail", "35", service, check=False).stdout[-6000:])
                    if db == "mysql":
                        # Synthetic fixtures only: identify the actual SQL error
                        # without relying on production's sanitized pool logs.
                        diagnostic = """import os,pymysql
e=os.environ
assert e['DB_PASSWORD'] == "Registry'$\\\\Smoke9!", 'password transport mismatch'
try:
    c=pymysql.connect(host=e['DB_HOST'],port=int(e['DB_PORT']),user=e['DB_USERNAME'],password=e['DB_PASSWORD'],database=e['DB_NAME'])
    c.close(); print('Synthetic direct SQL connection passed')
except Exception as exc:
    print(type(exc).__name__, exc.args)
    raise
"""
                        result = command("docker", "compose", "-f", str(compose), "run", "--rm", "--no-deps", "--entrypoint", "python",
                                         "registry-center", "-c", diagnostic, check=False)
                        print(result.stdout + result.stderr)
                raise
            finally:
                if compose.is_file():
                    # Only this script's uniquely named, newly created test project.
                    command("docker", "compose", "-f", str(compose), "down", "--volumes", "--remove-orphans", check=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", required=True)
    run(parser.parse_args().bundle)
