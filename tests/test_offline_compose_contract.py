# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
"""Offline Compose regressions; controlled commands are not a live Docker test."""
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
OFFLINE = ROOT / "containerized/offline-install-compose"
BASH = os.environ.get("BASH_BIN") or shutil.which("bash")
SPEC = importlib.util.spec_from_file_location("offline_configure", OFFLINE / "scripts/configure.py")
configure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configure)


def load_smoke():
    spec = importlib.util.spec_from_file_location("compose_smoke", ROOT / "tests/offline_compose_container_smoke.py")
    smoke = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(smoke)
    return smoke


@pytest.mark.parametrize("gap", [None, "oc-card-missing", "ui-workflow-empty", "machine-workflow-wrong",
                                     "put-stale", "deleted-card-listed", "deleted-card-returned"])
def test_container_smoke_checks_business_content_not_only_status(monkeypatch, gap):
    smoke = load_smoke()
    card = {"name": "ComposeAgent", "provider": {"organization": "ComposeOrg"},
            "description": "Synthetic container test", "version": "1.0", "signatures": ["synthetic"]}
    workflow = {"id": "compose-workflow", "name": "Compose workflow", "steps": [
        {"subtasks": [{"task_id": "t1", "skill": "skill_a"}]}]}
    updated = False
    deleted = False

    def request(opener, base, path, expected=200, method="GET", body=None, headers=None):
        nonlocal updated, deleted
        payload, response_headers = {}, {}
        if path.endswith("/auth/login"):
            response_headers["Set-Cookie"] = "synthetic=cookie; Secure"
        elif path.endswith("/api/v1/auth/token"):
            payload = {"access_token": "synthetic-account-token", "token_type": "Bearer", "expires_in": 43200}
        elif path.endswith("/agent-cards/ComposeOrg/ComposeAgent"):
            if method == "PUT":
                updated = True
            elif method == "DELETE":
                deleted = True
            else:
                value = dict(card, description="Updated" if updated and gap != "put-stale" else card["description"])
                payload = {"agentCards": [] if deleted and gap != "deleted-card-returned" else [value]}
        elif path.endswith("/agent-cards"):
            if path.startswith("/api/orchestrate"):
                payload = {"data": [] if gap == "oc-card-missing" else [card]}
            else:
                payload = {"agentCards": [card] if updated and gap == "deleted-card-listed" else []}
        elif "/workflows/" in path or "/psop/" in path:
            value = workflow
            if gap == "ui-workflow-empty" and "/workflows/" in path:
                value = dict(workflow, steps=[])
            if gap == "machine-workflow-wrong" and "/psop/" in path:
                value = dict(workflow, id="wrong-workflow")
            payload = {"data": value}
        elif "/sandbox/verifications/" in path:
            payload = {"data": {"events": [{"marker": "persisted-event"}]}}
        elif "/sandbox/templates/" in path:
            payload = {"data": [{"response_text": "persisted-stub"}]}
        elif "/solution-packages/" in path:
            payload = {"data": {"chapters": {"Synthetic chapter": "persisted-package"}}}
        return json.dumps(payload).encode(), response_headers

    monkeypatch.setattr(smoke, "request", request)
    monkeypatch.setattr(smoke, "command", lambda *a, **kw: SimpleNamespace(stdout=""))
    monkeypatch.setattr(smoke, "require_runtime_records", lambda *a: None, raising=False)
    if gap:
        with pytest.raises(AssertionError):
            smoke.exercise(None, "https://synthetic.invalid", Path("synthetic.json"), first=False, workflow_id=workflow["id"])
    else:
        assert smoke.exercise(None, "https://synthetic.invalid", Path("synthetic.json"), first=False, workflow_id=workflow["id"]) == workflow["id"]


def test_smoke_protocol_matrix_includes_independent_backends():
    cases = load_smoke().CASES
    assert ("mysql", True, False, False, False, True) in cases
    assert ("mysql", True, True, False, False, True) in cases
    assert ("mysql", True, False, True, False, True) in cases
    assert all(not mtls or (rc_tls and oc_tls) for _, _, rc_tls, oc_tls, mtls, _ in cases)


def test_audit_persistence_check_rejects_truncated_history(tmp_path, monkeypatch):
    smoke = load_smoke()
    audit = tmp_path / "log/audit/audit.log"
    audit.parent.mkdir(parents=True)
    audit.write_bytes(b"synthetic-original-audit\n")

    def command(*args, input=None, **kwargs):
        result = subprocess.run([sys.executable, "-c", args[-1]], cwd=tmp_path, input=input,
                                capture_output=True, text=True, timeout=10)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result

    monkeypatch.setattr(smoke, "command", command)
    before = smoke.audit_snapshot(Path("synthetic-compose.json"))
    with audit.open("ab") as stream:
        stream.write(b"synthetic-new-record\n")
    assert smoke.audit_snapshot(Path("synthetic-compose.json"), before)["size"] > before["size"]
    audit.write_bytes(b"synthetic-new-record\n")
    with pytest.raises(RuntimeError, match="Audit history was lost"):
        smoke.audit_snapshot(Path("synthetic-compose.json"), before)


@pytest.mark.parametrize("same_ips", [False, True])
def test_dns_replacement_fixture_uses_automatic_ipam_and_checks_changes(tmp_path, monkeypatch, same_ips):
    spec = importlib.util.spec_from_file_location("compose_smoke", ROOT / "tests/offline_compose_container_smoke.py")
    smoke = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(smoke)
    compose = tmp_path / "compose.json"
    compose.write_text(json.dumps({"name": "synthetic-project", "services": {"openan-nginx": {"image": "synthetic/nginx:test"}}}))
    calls, replaced = [], False

    def command(*args, **kwargs):
        nonlocal replaced
        calls.append(args)
        output = ""
        if args[1] == "compose" and "ps" in args:
            output = args[-1]
        elif args[1] == "inspect":
            offset = 0 if same_ips or not replaced else 10
            last = 3 if args[-1] == "registry-center" else 4
            output = json.dumps({"synthetic-network": {"IPAddress": f"172.18.0.{last + offset}"}})
        elif args[1] == "compose" and "up" in args:
            replaced = True
        return SimpleNamespace(stdout=output)

    monkeypatch.setattr(smoke, "command", command)
    if same_ips:
        with pytest.raises(AssertionError, match="IP did not change"):
            smoke.replace_backends(compose)
    else:
        smoke.replace_backends(compose)
    blockers = [call for call in calls if call[1] == "run"]
    assert len(blockers) == 2
    assert all("--network" in call and "--ip" not in call for call in blockers)
    assert [call[-1] for call in calls if call[1:3] == ("rm", "-f")] == [
        "synthetic-project-dns-blocker-0", "synthetic-project-dns-blocker-1"]


@pytest.fixture
def deployment(tmp_path):
    bundle = tmp_path / "bundle"
    (bundle / "deps").mkdir(parents=True)
    images = {name: f"contract/{name}:test" for name in ("registry-center", "orchestration-center", "workflow-designer", "nginx", "postgres", "mysql", "portal")}
    (bundle / "deps/image-tags.json").write_text(json.dumps({"architectures": ["amd64"], "images": images}))
    (bundle / "web").mkdir()
    (bundle / "web/index.html").write_text("synthetic frontend")
    (bundle / "compose/init").mkdir(parents=True)
    shutil.copyfile(OFFLINE / "compose/init/create-databases.sh", bundle / "compose/init/create-databases.sh")
    shutil.copyfile(OFFLINE / "compose/init/create-mysql-databases.sh", bundle / "compose/init/create-mysql-databases.sh")
    key, token = "synthetic-hmac-key", "synthetic-registry-token"
    (tmp_path / "registry.env").write_text(f"INTEGRATION_TOKEN_HMAC_KEY={key}\nINTEGRATION_FINGERPRINT_KEY=synthetic-fingerprint\n")
    (tmp_path / "orchestration.env").write_text(f"REGISTRY_ACCESS_TOKEN={token}\nOC_ADMIN_INITIAL_PASSWORD=synthetic-admin-password\n")
    digest = hmac.new(key.encode(), token.encode(), hashlib.sha256).hexdigest()
    (tmp_path / "credentials.conf").write_text(f"credential.oc.identity=orchestration\ncredential.oc.token_hash={digest}\ncredential.oc.role=partner_service\n")
    for name in ("registry-models.yaml", "orchestration-models.yaml"):
        (tmp_path / name).write_text("models: {chat: {provider: openai_compatible}, embed: {}, rerank: {}}\n")
    for role in ("registry", "orchestration", "public", "registry-proxy", "orch-proxy", "registry-client", "signing"):
        directory = tmp_path / role
        directory.mkdir()
        for name in ("server.cer", "server_key.pem", "cert_pwd", "trust.cer", "client.cer", "client_key.pem",
                     "probe-client.cer", "probe-client.key", "sign.cer", "sign_key.pem"):
            (directory / name).write_text("synthetic-material-not-a-real-certificate")
    config = {"DB_HOST": "mysql.example.invalid", "REGISTRY_DB_PASSWORD": "test-registry", "ORCH_DB_PASSWORD": "test-orch",
              "REGISTRY_CREDENTIAL_FILE": "credentials.conf", "REGISTRY_MODELS_FILE": "registry-models.yaml",
              "ORCH_MODELS_FILE": "orchestration-models.yaml", "REGISTRY_RUNTIME_ENV_FILE": "registry.env",
              "ORCH_RUNTIME_ENV_FILE": "orchestration.env", "REGISTRY_SIGN_DIR": "signing",
              "PUBLIC_TLS_DIR": "public", "REGISTRY_TLS_DIR": "registry", "ORCH_TLS_DIR": "orchestration",
              "REGISTRY_PROXY_TLS_DIR": "registry-proxy", "ORCH_PROXY_TLS_DIR": "orch-proxy", "REGISTRY_CLIENT_TLS_DIR": "registry-client"}
    config_file = tmp_path / "config.env"
    def generate(overrides=None):
        effective = {**config, **(overrides or {})}
        config_file.write_text("\n".join(f"{k}='{v}'" for k, v in effective.items()), encoding="utf-8")
        return configure.plan(config_file, bundle, "amd64")
    return tmp_path, bundle, config_file, generate


@pytest.mark.parametrize("frontend", ["portal", "workflow-designer"])
def test_compose_entry_nginx_security_headers(deployment, frontend):
    # Issue #55: the compose entry nginx emits the standard security header
    # set at the server level; the add_header-heavy static locations repeat
    # it (nginx inheritance breaks there).
    _, _, _, generate = deployment
    compose, nginx = generate({"FRONTEND_TYPE": frontend})
    conf = nginx if isinstance(nginx, str) else nginx["content"]
    for header in ("Content-Security-Policy", "X-Frame-Options", "X-Content-Type-Options",
                   "Referrer-Policy", "Permissions-Policy"):
        assert header in conf, f"{frontend}: entry nginx missing {header}"
    # The static locations repeat the set where nginx inheritance breaks.
    assert conf.count("Permissions-Policy") >= (1 if frontend == "portal" else 3)


@pytest.mark.parametrize("frontend", ["portal", "workflow-designer"])
@pytest.mark.parametrize("db", ["mysql", "postgresql"])
@pytest.mark.parametrize("public_https", ["false", "true"])
@pytest.mark.parametrize("rc_https,oc_https", [("false", "false"), ("true", "true"), ("false", "true"), ("true", "false")])
def test_compose_database_and_three_protocol_matrix(deployment, db, public_https, rc_https, oc_https, frontend):
    _, _, _, generate = deployment
    compose, nginx = generate({"DATABASE_TYPE": db, "PUBLIC_ENABLE_HTTPS": public_https,
                               "REGISTRY_ENABLE_HTTPS": rc_https, "ORCH_ENABLE_HTTPS": oc_https,
                               "FRONTEND_TYPE": frontend})
    services = compose["services"]
    expected = {"registry-center", "orchestration-center", "openan-nginx"}
    if frontend == "portal":
        expected.add("openan-portal")
    assert set(services) == expected
    for role, name, secure in [("REGISTRY", "registry-center", rc_https), ("ORCH", "orchestration-center", oc_https)]:
        service = services[name]
        assert service["pull_policy"] == "never"
        assert "ports" not in service
        assert service["environment"]["PERSISTENCE_MODE"] == db
        assert service["environment"][role + "_ENABLE_HTTPS"] == secure
        assert service["environment"][role + "_VERIFY_CLIENT"] == "false"
        assert any(m["target"].endswith("/models.yaml") for m in service["volumes"])
        assert "healthcheck" in service
    assert services["registry-center"]["environment"]["REGISTRY_OWNER_IDENTITY_MODE"] == "token"
    assert services["orchestration-center"]["environment"]["ORCH_PUBLIC_SCHEME"] == ("https" if public_https == "true" else "http")
    assert services["orchestration-center"]["environment"]["AGENT_REGISTRY_URL"].startswith("https" if rc_https == "true" else "http")
    assert f"proxy_pass {'https' if rc_https == 'true' else 'http'}://registry_center/;" in nginx
    assert f"proxy_pass {'https' if oc_https == 'true' else 'http'}://orchestration_center/;" in nginx
    assert "resolver 127.0.0.11 valid=2s ipv6=off;" in nginx
    assert "server registry-center:5000 resolve;" in nginx
    assert "server orchestration-center:5001 resolve;" in nginx
    assert nginx.count("zone registry_center 64k;") == 1
    assert nginx.count("zone orchestration_center 64k;") == 1
    assert f"proxy_pass {'https' if oc_https == 'true' else 'http'}://orchestration_center;" in nginx
    assert 'proxy_set_header Connection "";' in nginx
    assert "location ^~ /api/orchestrate/api/ { return 404; }" not in nginx
    assert nginx.count('proxy_set_header X-OpenAN-Browser-Gateway "1";') == (3 if frontend == "portal" else 2)
    assert "ip_hash" not in nginx and "$request " not in nginx
    nginx_volumes = services["openan-nginx"]["volumes"]
    if frontend == "portal":
        portal = services["openan-portal"]
        assert portal["image"] == "contract/portal:test"
        assert portal["pull_policy"] == "never"
        assert "ports" not in portal
        assert portal["environment"]["BACKEND_URL"] == f"{'https' if oc_https == 'true' else 'http'}://orchestration-center:5001"
        assert portal["environment"]["REGISTRY_URL"] == f"{'https' if rc_https == 'true' else 'http'}://registry-center:5000"
        assert portal["healthcheck"]["test"] == ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/"]
        assert services["openan-nginx"]["depends_on"]["openan-portal"] == {"condition": "service_healthy"}
        assert services["orchestration-center"]["depends_on"]["registry-center"] == {"condition": "service_healthy"}
        # Wait-for-database wrapper: the DB healthcheck can pass before the
        # app user's grant is live; OC's backend constructors make a real
        # connection at construction time and crash on refusal.
        oc_command = services["orchestration-center"]["command"]
        assert oc_command[0] == "sh" and oc_command[1] == "-c"
        assert "PERSISTENCE_MODE" in oc_command[2]
        assert "pymysql" in oc_command[2] and "psycopg2" in oc_command[2]
        assert "os.environ['DB_PASSWORD']" in oc_command[2]
        assert "exec python3 -m orchestrate.start" in oc_command[2]
        assert "server openan-portal:8080 resolve;" in nginx
        assert "proxy_pass http://portal/;" in nginx
        assert "location ^~ /api/registry/ {" in nginx
        assert 'proxy_set_header X-OpenAN-Browser-Gateway "1";' in nginx.split("location ^~ /api/registry/ {")[1].split("}")[0]
        assert "try_files" not in nginx and "location = /index.html" not in nginx
        assert not any(volume.get("target") == "/usr/share/nginx/html" for volume in nginx_volumes)
    else:
        assert "openan-portal" not in services and "openan-portal" not in services["openan-nginx"]["depends_on"]
        assert "location / { try_files $uri $uri/ /index.html; }" in nginx
        assert "location ^~ /api/registry/" not in nginx and "proxy_pass http://portal/;" not in nginx
        assert any(volume.get("target") == "/usr/share/nginx/html" for volume in nginx_volumes)


def test_mtls_stays_authenticated_when_upstream_verification_is_off(deployment):
    _, _, _, generate = deployment
    compose, nginx = generate({"REGISTRY_ENABLE_HTTPS": "true", "ORCH_ENABLE_HTTPS": "true",
                               "REGISTRY_VERIFY_CLIENT": "true", "ORCH_VERIFY_CLIENT": "true",
                               "BACKEND_VERIFY_SERVER": "false", "ORCH_CLIENT_VERIFY_SERVER": "false"})
    for role, name in (("REGISTRY", "registry-center"), ("ORCH", "orchestration-center")):
        env = compose["services"][name]["environment"]
        assert env[role + "_HEALTHCHECK_CLIENT_CERT"].endswith("probe-client.cer")
    env = compose["services"]["orchestration-center"]["environment"]
    assert env["REGISTRY_CLIENT_KEY"].endswith("client_key.pem")
    assert env["ORCH_EXTERNAL_AUTH_MODE"] == "user"
    assert "proxy_ssl_certificate_key" in nginx and "proxy_ssl_verify off;" in nginx


@pytest.mark.parametrize("invalid,message", [
    ({"DATABASE_TYPE": "sqlite"}, "supports mysql/postgresql"),
    ({"FRONTEND_TYPE": "legacy"}, "supports portal/workflow-designer"),
    ({"REGISTRY_VERIFY_CLIENT": "true"}, "requires HTTPS"),
    ({"ORCH_ENABLE_HTTPS": "yes"}, "true or false"),
    ({"REGISTRY_DB_NAME": "orchestration_center"}, "distinct databases"),
    ({"PUBLIC_BIND": "0.0.0.0; echo unsafe"}, "decimal digits"),
    ({"REGISTRY_MODELS_FILE": "missing.yaml"}, "existing file"),
    ({"REGISTRY_ENABLE_HTTPS": "true", "REGISTRY_PROXY_TLS_DIR": ""}, "upstream CA verification"),
    ({"REGISTRY_ENABLE_HTTPS": "true", "REGISTRY_CLIENT_TLS_DIR": ""}, "registry TLS"),
    ({"REGISTRY_CHAT_APIKEY": "legacy"}, "Unknown deployment keys"),
])
def test_invalid_configs_fail_closed(deployment, invalid, message):
    with pytest.raises(ValueError, match=message):
        deployment[3](invalid)


def test_portal_frontend_requires_bundle_portal_image(deployment):
    _, bundle, _, generate = deployment
    manifest = json.loads((bundle / "deps/image-tags.json").read_text(encoding="utf-8"))
    del manifest["images"]["portal"]
    (bundle / "deps/image-tags.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(ValueError, match="requires a portal image"):
        generate({"FRONTEND_TYPE": "portal"})
    compose, nginx = generate({"FRONTEND_TYPE": "workflow-designer"})
    assert set(compose["services"]) == {"registry-center", "orchestration-center", "openan-nginx"}
    assert "proxy_pass http://portal/;" not in nginx
    assert "location ^~ /api/registry/" not in nginx


def test_internal_postgres_and_quoted_credentials(deployment):
    _, _, _, generate = deployment
    compose, _ = generate({"DATABASE_TYPE": "postgresql", "DATABASE_INTERNAL": "true", "POSTGRES_PASSWORD": "test-root", "DB_PORT": "5544"})
    pg = compose["services"]["openan-postgres"]
    assert pg["command"] == ["postgres", "-p", "5544"]
    assert pg["healthcheck"]["test"][-1] == "5544"
    # Network-based probe: proves the Docker network listener is ready, not
    # just the loopback socket that apps on the same container would use.
    assert "openan-postgres" in " ".join(pg["healthcheck"]["test"])
    assert pg["environment"]["REGISTRY_DB_PASSWORD"] != pg["environment"]["ORCH_DB_PASSWORD"]
    init = (OFFLINE / "compose/init/create-databases.sh").read_text()
    assert ":'password'" in init and "<<'EOSQL'" in init
    assert "'${POSTGRES_PASSWORD}'" not in init


def test_internal_mysql_is_single_host_and_uses_authenticated_probe(deployment):
    compose, _ = deployment[3]({"DATABASE_INTERNAL": "true", "MYSQL_ROOT_PASSWORD": "test-root"})
    db = compose["services"]["openan-mysql"]
    assert "mysql-data:/var/lib/mysql" in db["volumes"]
    assert "MYSQL_ROOT_PASSWORD" in db["healthcheck"]["test"][-1]
    # Network-based probe: proves the Docker network listener is ready, not
    # just the loopback socket.
    assert "openan-mysql" in db["healthcheck"]["test"][-1]
    for service in ("registry-center", "orchestration-center"):
        assert compose["services"][service]["environment"]["DB_HOST"] == "openan-mysql"
    init = (OFFLINE / "compose/init/create-mysql-databases.sh").read_text()
    assert "NO_BACKSLASH_ESCAPES" in init
    assert 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD"' in init


def test_unprovisioned_token_or_managed_env_override_is_rejected(deployment):
    root, _, _, generate = deployment
    (root / "credentials.conf").write_text("# No credentials\n")
    with pytest.raises(ValueError, match="no enabled matching identity"):
        generate()
    with (root / "registry.env").open("a") as stream:
        stream.write("REGISTRY_ENABLE_HTTPS=true\n")
    with pytest.raises(ValueError, match="overrides managed keys"):
        generate()


@pytest.mark.parametrize("alias", ["POSTGRES_HOST", "REGISTRY_MYSQL_HOST", "ORCH_SSL_CERTFILE", "DATABASE_CONFIG_DIR"])
def test_runtime_aliases_cannot_bypass_managed_mounts(deployment, alias):
    root, _, _, generate = deployment
    with (root / "orchestration.env").open("a") as stream:
        stream.write(alias + "=unsafe-override\n")
    with pytest.raises(ValueError, match="overrides managed keys"):
        generate()


def test_config_is_literal_and_dollar_text_survives_compose(deployment):
    root, bundle, _, generate = deployment
    marker = root / "should-not-exist"
    env = root / "literal.env"
    env.write_text(f'TEST="$(touch {marker.as_posix()}) $HOME `id`"\n', encoding="utf-8")
    assert configure.read_env(env)["TEST"].startswith("$(touch ")
    assert not marker.exists()
    with (root / "orchestration.env").open("a") as stream:
        stream.write("EXTRA_LITERAL='price $5 ${NOT_EXPANDED} # text'\n")
    compose, nginx = generate()
    configure.write_plan(compose, nginx, bundle)
    generated = bundle / "runtime/compose.json"
    parsed = json.loads(generated.read_text(encoding="utf-8"))
    assert parsed["services"]["orchestration-center"]["environment"]["EXTRA_LITERAL"] == "price $$5 $${NOT_EXPANDED} # text"
    if os.name != "nt":
        assert generated.stat().st_mode & 0o777 == 0o600
    if shutil.which("docker"):
        # Real Compose's config parser requires no running containers or images.
        result = subprocess.run(["docker", "compose", "-f", str(generated), "config", "--format", "json"],
                                capture_output=True, encoding="utf-8", timeout=30, check=True)
        resolved = json.loads(result.stdout)
        # config re-escapes dollars for round-trip serialization; it is not the
        # container environment. The live smoke asserts the process value.
        assert resolved["services"]["orchestration-center"]["environment"]["EXTRA_LITERAL"] == "price $$5 $${NOT_EXPANDED} # text"


def test_legacy_data_and_project_identity_are_not_silently_replaced(deployment):
    _, bundle, _, generate = deployment
    compose, nginx = generate()
    configure.write_plan(compose, nginx, bundle)
    with pytest.raises(ValueError, match="PROJECT_NAME must remain stable"):
        generate({"PROJECT_NAME": "replacement"})
    legacy = bundle / "compose/data/postgres"
    legacy.mkdir(parents=True)
    (legacy / "PG_VERSION").write_text("15")
    with pytest.raises(ValueError, match="explicit backup/restore"):
        generate()


def test_failed_checksum_is_a_blocker_not_a_warning(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    bundle = tmp_path / "bundle"
    bundle.mkdir()
    (bundle / "payload").write_text("tampered")
    (bundle / "SHA256SUMS").write_text("0" * 64 + "  payload\n")
    result = subprocess.run([BASH, "-c", 'BUNDLE_DIR="$1"; ARCH=amd64; source "$2"; verify_bundle',
                             "test", shell_path(bundle), shell_path(OFFLINE / "scripts/lib/common.sh")],
                            encoding="utf-8", capture_output=True, timeout=10)
    assert result.returncode != 0 and "checksum FAILED" in result.stderr


@pytest.mark.parametrize("args", [["--tag"], ["--tag", ".."], ["--tag", "contract", "--platforms", "linux/ppc64le"]])
def test_invalid_build_arguments_do_not_publish(args, tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    result = subprocess.run([BASH, str(OFFLINE / "build/build-offline.sh"), *args],
                            encoding="utf-8", capture_output=True, timeout=10)
    assert result.returncode != 0
    assert "Done." not in result.stdout


@pytest.mark.parametrize("failure", ["", "save", "cp"])
def test_complete_bundle_is_allowlisted_and_extraction_failure_blocks_release(tmp_path, failure):
    if not BASH:
        pytest.skip("Bash unavailable")
    source = tmp_path / "source"
    shutil.copytree(OFFLINE, source, ignore=shutil.ignore_patterns("dist", "runtime", "__pycache__"))
    for name in ("config.env", "runtime/secret", "compose/data/private", "templates/operator.env"):
        private = source / name
        private.parent.mkdir(parents=True, exist_ok=True)
        private.write_text("OPERATOR_SECRET_CANARY_MUST_NOT_SHIP")
    shim = tmp_path / "shim"
    shim.mkdir()
    python_shim(shim)
    docker = shim / "docker"
    docker.write_text('''#!/usr/bin/env bash
set -e
if [[ "$1" == "$FAIL_STAGE" && -n "$FAIL_STAGE" ]]; then exit 19; fi
case "$1" in
  image) echo linux/amd64 ;;
  save) printf 'synthetic image' > "$3" ;;
  create) echo synthetic-container ;;
  cp) mkdir -p "$3"; printf '<html>synthetic frontend</html>' > "$3/index.html" ;;
esac
''', newline="\n")
    docker.chmod(0o755)
    out = tmp_path / "dist"
    result = subprocess.run([BASH, "-c", 'export PATH="$1:$PATH"; export FAIL_STAGE="$2"; shift 2; exec bash "$@"',
                             "test", shell_path(shim), failure, shell_path(source / "build/build-offline.sh"),
                             "--tag", "contract", "--out", shell_path(out)],
                            encoding="utf-8", capture_output=True, timeout=30)
    if failure:
        assert result.returncode == 19, result.stdout + result.stderr
        assert not list(out.glob("*.tar.gz"))
    else:
        assert result.returncode == 0, result.stdout + result.stderr
        bundle = out / "openan-offline-compose-contract"
        assert (bundle / "web/index.html").is_file()
        if os.name != "nt":
            for script in (bundle / "compose/init").glob("*.sh"):
                assert script.stat().st_mode & 0o777 == 0o755
        for file in bundle.rglob("*"):
            if file.is_file():
                assert b"OPERATOR_SECRET_CANARY_MUST_NOT_SHIP" not in file.read_bytes(), file
        assert not (bundle / "config.env").exists() and not (bundle / "runtime").exists()
        assert (out / "openan-offline-compose-contract.tar.gz").is_file()


def shell_path(path):
    if os.name != "nt":
        return str(path)
    return subprocess.check_output([BASH, "-c", 'cygpath -u "$1"', "test", str(path)], text=True).strip()


def python_shim(directory):
    """Git Bash need not provide python3; run the same interpreter as pytest."""
    if os.name == "nt":
        executable = directory / "python3"
        executable.write_text('#!/usr/bin/env bash\nexec ' + shlex.quote(shell_path(sys.executable)) + ' "$@"\n', newline="\n")
        executable.chmod(0o755)


def test_failed_image_pull_never_produces_offline_release(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    shim = tmp_path / "shim"
    shim.mkdir()
    python_shim(shim)
    docker = shim / "docker"
    docker.write_text('#!/usr/bin/env bash\nif [[ "$1" == pull ]]; then exit 17; fi\nexit 0\n', newline="\n")
    docker.chmod(0o755)
    out = tmp_path / "dist"
    result = subprocess.run([BASH, "-c", 'export PATH="$1:$PATH"; shift; exec bash "$@"', "test",
                             shell_path(shim), shell_path(OFFLINE / "build/build-offline.sh"),
                             "--tag", "contract", "--platforms", "linux/amd64", "--out", shell_path(out)],
                            text=True, encoding="utf-8", capture_output=True, timeout=30)
    assert result.returncode == 17, result.stdout + result.stderr
    assert not list(out.glob("*.tar.gz"))
    assert "Done." not in result.stdout


def test_uninstall_targets_generated_project_and_retains_volumes(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    bundle = tmp_path / "bundle"
    (bundle / "runtime").mkdir(parents=True)
    (bundle / "runtime/compose.json").write_text(json.dumps({"name": "controlled-stack"}))
    shutil.copytree(OFFLINE / "scripts", bundle / "scripts")
    shim = tmp_path / "shim"
    shim.mkdir()
    python_shim(shim)
    docker = shim / "docker"
    docker.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@"\n', newline="\n")
    docker.chmod(0o755)
    result = subprocess.run([BASH, "-c", 'export PATH="$1:$PATH"; export COMPOSE_PROJECT_NAME=unrelated-stack; exec bash "$2"',
                             "test", shell_path(shim), shell_path(bundle / "scripts/uninstall.sh")],
                            encoding="utf-8", capture_output=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
    args = result.stdout.splitlines()
    assert args[:3] == ["compose", "--project-name", "controlled-stack"]
    assert "down" in args and "--volumes" not in args
    assert "unrelated-stack" not in args
    assert (bundle / "runtime/compose.json").exists()
