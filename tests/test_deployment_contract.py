# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
"""Helm render contracts and controlled build failures; not a cluster smoke test."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import tarfile

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
HELM = os.environ.get("HELM_BIN") or shutil.which("helm")
BASH = os.environ.get("BASH_BIN") or shutil.which("bash")
CHART = ROOT / "containerized/online-install/openan-chart"
BASE = {"registry.image.tag": "contract", "orchestration.image.tag": "contract",
        "frontend.type": "workflow-designer", "frontend.image.tag": "contract",
        "postgresql.existingSecret": "postgres-secret", "registry.runtimeSecret": "rc-runtime",
        "registry.credentialSecret": "rc-credentials", "orchestration.runtimeSecret": "oc-runtime",
        "registry.signing.mode": "off"}


def render(settings=None, success=True):
    if not HELM:
        pytest.skip("Set HELM_BIN to run real Helm render validation")
    command = [HELM, "template", "contract", str(CHART), "--namespace", "openan"]
    for key, value in {**BASE, **(settings or {})}.items():
        command += ["--set", f"{key}={str(value).lower() if isinstance(value, bool) else value}"]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=40)
    assert (result.returncode == 0) is success, result.stderr
    if not success:
        return result.stderr
    docs = {}
    for doc in yaml.safe_load_all(result.stdout):
        if doc:
            name = doc["metadata"]["name"]
            # A Service and Deployment can legally share a name.
            if name not in docs or doc["kind"] in {"Deployment", "StatefulSet"}:
                docs[name] = doc
            docs[f"{doc['kind']}/{name}"] = doc
    return docs


@pytest.mark.parametrize("protocol", ["http", "https"])
@pytest.mark.parametrize("db", ["mysql", "postgresql"])
def test_database_and_protocol_matrix(protocol, db):
    settings = {}
    if db == "mysql":
        settings.update({"database.type": "mysql", "postgresql.enabled": False, "database.host": "mysql.example",
                         "database.registry.existingSecret": "rc-db", "database.orchestration.existingSecret": "oc-db"})
    if protocol == "https":
        settings.update({"registry.tls.enabled": True, "registry.tls.existingSecret": "rc-tls",
                         "orchestration.tls.enabled": True, "orchestration.tls.existingSecret": "oc-tls",
                         "frontend.backendTls.existingSecret": "frontend-trust",
                         "orchestration.registryClientSecret": "oc-registry-trust",
                         "registry.ingressClientSecret": "rc-ingress-trust",
                         "orchestration.ingressClientSecret": "oc-ingress-trust"})
    docs = render(settings)
    for component, env in [("registry-center", "REGISTRY"), ("orchestration-center", "ORCH")]:
        conf = docs[component + "-config"]["data"]
        assert conf[env + "_ENABLE_HTTPS"] == str(protocol == "https").lower()
        assert conf[env + "_VERIFY_CLIENT"] == "false"
        assert conf["PERSISTENCE_MODE"] == db
        deployment = docs[component]["spec"]["template"]["spec"]
        assert deployment["securityContext"]["fsGroup"] == 10001
        container = deployment["containers"][0]
        assert "exec" in container["readinessProbe"]
        assert container["envFrom"][1]["secretRef"]["name"] in {"rc-runtime", "oc-runtime"}
        assert any(m["subPath"] == "models.yaml" for m in container["volumeMounts"] if "subPath" in m)
    assert docs["orchestration-center-config"]["data"]["AGENT_REGISTRY_URL"].startswith(protocol + "://")
    assert docs["orchestration-center-config"]["data"]["ORCH_EXTERNAL_AUTH_MODE"] == "user"
    nginx = docs["openan-frontend-nginx-config"]["data"]["default.conf"]
    assert f"proxy_pass {protocol}://orchestration-center:5001" in nginx
    assert "proxy_set_header Connection \"\"" in nginx
    assert "location ^~ /api/orchestrate/api/ { return 404; }" not in nginx
    assert nginx.count('proxy_set_header X-OpenAN-Browser-Gateway "1";') == 2
    assert docs["openan-registry-ingress"]["metadata"]["annotations"][
        "nginx.ingress.kubernetes.io/backend-protocol"] == protocol.upper()
    if db == "mysql":
        assert "openan-postgres" not in docs
        assert docs["registry-center-config"]["data"]["DB_PORT"] == "3306"


def test_mtls_material_and_probes_are_wired():
    docs = render({"registry.tls.enabled": True, "registry.tls.verifyClient": True,
                   "registry.tls.existingSecret": "rc-tls", "registry.identityMode": "certificate",
                   "registry.ingressClientSecret": "rc-ingress-client",
                   "orchestration.tls.enabled": True, "orchestration.tls.verifyClient": True,
                   "orchestration.tls.existingSecret": "oc-tls", "orchestration.ingressClientSecret": "oc-ingress-client",
                   "orchestration.registryClientSecret": "oc-registry-client",
                   "frontend.backendTls.existingSecret": "frontend-client"})
    for comp, env in [("registry-center", "REGISTRY"), ("orchestration-center", "ORCH")]:
        assert "HEALTHCHECK_CLIENT_CERT" in " ".join(docs[comp + "-config"]["data"])
        mounts = docs[comp]["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]
        assert any(m.get("subPath") == "probe-client.key" for m in mounts)
    assert docs["orchestration-center-config"]["data"]["REGISTRY_CLIENT_CERT"].endswith("client.cer")
    assert docs["orchestration-center-config"]["data"]["ORCH_EXTERNAL_AUTH_MODE"] == "user"
    assert "proxy_ssl_certificate_key" in docs["openan-frontend-nginx-config"]["data"]["default.conf"]


@pytest.mark.parametrize("name", ["registry-center", "orchestration-center"])
def test_probe_timeout_seconds_exceeds_healthcheck_time(name):
    # BUG-5: the exec healthchecks (Python startup + RSA3072 handshake) take
    # ~2.3s, beyond K8s's 1s default probe timeout; liveness killed the pod
    # before it ever became Ready. The same applies to startupProbe: the
    # orchestration startup probe measured 1.3-1.4s, so the K8s 1s default
    # made it fail forever. Guard a lower bound (>= 3s) instead of pinning
    # the exact value, so the timeout can be tuned later.
    docs = render()
    container = docs[name]["spec"]["template"]["spec"]["containers"][0]
    for probe in ("startupProbe", "livenessProbe", "readinessProbe"):
        if probe not in container:
            continue
        timeout = container[probe].get("timeoutSeconds")
        assert timeout is not None and timeout >= 3, (
            f"{name} {probe} timeoutSeconds must be set and >= 3s, got {timeout}"
        )


@pytest.mark.parametrize("invalid,message", [
    ({"database.type": "mysql"}, "postgresql.enabled=false"),
    ({"registry.tls.verifyClient": True}, "requires HTTPS"),
    ({"registry.tls.enabled": True}, "requires tls.mode=secret"),
    ({"registry.runtimeSecret": ""}, "runtimeSecret is required"),
    ({"registry.identityMode": "certificate"}, "certificate identity requires"),
    ({"orchestration.replicas": 2}, "sessions are process-local"),
    ({"registry.replicas": 2}, "events and dispatchers are process-local"),
    ({"registry.replicas": 1.5}, "events and dispatchers are process-local"),
    ({"orchestration.replicas": 1.5}, "sessions are process-local"),
    ({"registry.persistence.size": ""}, "persistence.size is required"),
    ({"registry.persistence.existingClaim": "shared", "orchestration.persistence.existingClaim": "shared"}, "separate runtime claims"),
    ({"registry.persistence.existingClaim": "orchestration-center-runtime"}, "separate runtime claims"),
    ({"orchestration.persistence.existingClaim": "registry-center-runtime"}, "separate runtime claims"),
    ({"ingress.tls.enabled": True}, "requires ingress.host"),
    ({"registry.vectordb.enabled": True}, "no authoritative SQL record store"),
    ({"registry.extraEnv.REGISTRY_ENABLE_HTTPS": True}, "duplicates managed setting"),
    ({"orchestration.extraEnv.REGISTRY_CA_FILE": "/wrong"}, "duplicates managed setting"),
    ({"registry.llm.chat.provider": "aoc_signed"}, "use modelsConfigMap"),
    ({"database.registry.existingSecret": "different-password"}, "for external SQL only"),
    ({"registry.tls.enabled": True, "registry.tls.existingSecret": "rc-tls",
      "orchestration.tls.enabled": True, "orchestration.tls.existingSecret": "oc-tls",
      "orchestration.registryClientSecret": "oc-registry-trust",
      "registry.ingressClientSecret": "rc-ingress-trust",
      "orchestration.ingressClientSecret": "oc-ingress-trust"}, "requires frontend.backendTls.existingSecret"),
])
def test_invalid_combinations_fail_before_install(invalid, message):
    assert message in render(invalid, success=False)


def test_signing_names_and_full_model_mount():
    docs = render({"registry.signing.mode": "auto"})
    assert set(docs["registry-center-signing"]["data"]) == {"sign.cer", "sign_key.pem", "cert_pwd"}
    models = yaml.safe_load(docs["registry-center-models"]["data"]["models.yaml"])
    assert set(models["models"]) == {"chat", "embed", "rerank"}


def test_orchestration_a2at_sdk_llm_renders():
    docs = render({"orchestration.a2atLlm.provider": "openai",
                   "orchestration.a2atLlm.model": "negotiate",
                   "orchestration.a2atLlm.baseUrl": "https://api.example.com/v1"})
    env = docs["orchestration-center-config"]["data"]
    assert env["A2AT_LLM_PROVIDER"] == "openai"
    assert env["A2AT_LLM_MODEL"] == "negotiate"
    assert env["A2AT_LLM_BASE_URL"] == "https://api.example.com/v1"
    # unset by default: the SDK stays unconfigured unless the values are set
    default = render()["orchestration-center-config"]["data"]
    assert "A2AT_LLM_MODEL" not in default


def test_orchestration_embed_rerank_models_render():
    docs = render({"orchestration.llm.embed.model": "emb",
                   "orchestration.llm.embed.url": "https://llm.example/v1/embeddings",
                   "orchestration.llm.rerank.model": "rr",
                   "orchestration.llm.rerank.url": "https://llm.example/v1/rerank"})
    models = yaml.safe_load(docs["orchestration-center-models"]["data"]["models.yaml"])
    assert set(models["models"]) == {"chat", "embed", "rerank"}
    assert models["models"]["embed"]["api_key_env"] == "LLM_EMBED_API_KEY"


def test_a2at_env_cannot_be_shadowed_via_extra_env():
    error = render({"orchestration.extraEnv.A2AT_LLM_MODEL": "x"}, success=False)
    assert "a2atLlm values" in error


@pytest.mark.parametrize("verify_server", [False, True])
@pytest.mark.parametrize("mtls", [False, True])
def test_registry_trust_and_client_identity_are_independent(verify_server, mtls):
    docs = render({"registry.tls.enabled": True, "registry.tls.existingSecret": "rc-tls",
                   "registry.tls.verifyClient": mtls, "registry.ingressClientSecret": "ingress-client",
                   "orchestration.registryClientSecret": "registry-client",
                   "orchestration.clientVerifyServer": verify_server})
    env = docs["orchestration-center-config"]["data"]
    assert ("REGISTRY_CA_FILE" in env) is verify_server
    assert ("REGISTRY_CLIENT_CERT" in env) is mtls
    assert ("REGISTRY_CLIENT_KEY" in env) is mtls
    assert env["ORCH_CLIENT_VERIFY_SERVER"] == str(verify_server).lower()


@pytest.mark.parametrize("component,name", [("registry", "registry-center"), ("orchestration", "orchestration-center")])
def test_runtime_files_use_retained_pvc_and_nonoverlapping_rollout(component, name, tmp_path):
    docs = render()
    deployment = docs[name]
    assert deployment["spec"]["replicas"] == 1
    assert deployment["spec"]["strategy"] == {"type": "Recreate"}
    pod = deployment["spec"]["template"]["spec"]
    volume = next(v for v in pod["volumes"] if v["name"] == "runtime")
    assert volume["persistentVolumeClaim"]["claimName"] == name + "-runtime"
    mounts = {m["subPath"]: m["mountPath"] for m in pod["containers"][0]["volumeMounts"] if m["name"] == "runtime"}
    assert mounts == {"data": f"/opt/{name}/data", "log": f"/opt/{name}/log"}
    initializer = pod["initContainers"][0]
    assert initializer["image"] == pod["containers"][0]["image"]
    assert initializer["command"][:2] == ["python", "-c"]
    # Execute the rendered initializer against a controlled local volume root.
    # chown/chgrp to a non-root uid/gid requires root privileges; skip the
    # ownership assertions on CI runners where we are not root (the mkdir and
    # chmod parts are still validated).
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    code = initializer["command"][2].replace("/runtime", runtime.as_posix())
    import os as _os
    _can_chown = hasattr(_os, "geteuid") and _os.geteuid() == 0
    if not _can_chown:
        # Strip chown/chgrp lines so the script succeeds without root.
        lines = [l for l in code.splitlines()
                 if not l.strip().startswith(("chown ", "chgrp "))]
        code = "\n".join(lines)
    subprocess.run(["/bin/sh", "-c", code], check=True, timeout=10)
    subprocess.run(["/bin/sh", "-c", code], check=True, timeout=10)
    assert (runtime / "data").is_dir() and (runtime / "log").is_dir()
    assert pod["securityContext"]["runAsUser"] == 10001
    assert initializer["securityContext"]["allowPrivilegeEscalation"] is False
    pvc = docs[name + "-runtime"]
    assert pvc["kind"] == "PersistentVolumeClaim"
    assert pvc["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"
    assert pvc["spec"]["accessModes"] == ["ReadWriteOnce"]
    assert "storageClassName" not in pvc["spec"]
    assert pvc["spec"]["resources"]["requests"]["storage"]


def test_existing_runtime_claims_are_reused_without_creating_resources():
    docs = render({"registry.persistence.existingClaim": "retained-rc", "orchestration.persistence.existingClaim": "retained-oc"})
    for name, claim in [("registry-center", "retained-rc"), ("orchestration-center", "retained-oc")]:
        assert name + "-runtime" not in docs
        volumes = docs[name]["spec"]["template"]["spec"]["volumes"]
        assert next(v for v in volumes if v["name"] == "runtime")["persistentVolumeClaim"]["claimName"] == claim


@pytest.mark.parametrize("storage_class,expected", [("-", ""), ("fast", "fast")])
def test_runtime_storage_class_selection(storage_class, expected):
    docs = render({"registry.persistence.storageClassName": storage_class})
    assert docs["registry-center-runtime"]["spec"]["storageClassName"] == expected


def test_local_storage_fallback_creates_node_pinned_pvs():
    # Clusters without a StorageClass leave every claim Pending; the wizard's
    # fallback must provide PVs for ALL workloads (postgres, registry,
    # orchestration), not just postgres.
    settings = {"postgresql.storage.createStorageClass": True,
                "postgresql.storage.storageClassName": "openan-local",
                "postgresql.storage.createPV": True,
                "postgresql.storage.useHostPath": True,
                "postgresql.storage.nodeName": "node-a",
                "registry.persistence.storageClassName": "openan-local",
                "registry.persistence.createPV": True,
                "registry.persistence.nodeName": "node-a",
                "orchestration.persistence.storageClassName": "openan-local",
                "orchestration.persistence.createPV": True,
                "orchestration.persistence.nodeName": "node-a"}
    docs = render(settings)
    assert docs["StorageClass/openan-local"]["provisioner"] == "kubernetes.io/no-provisioner"
    for pv_name, path in [("openan-postgres-pv", "/data/openan-postgres"),
                          ("openan-rc-pv", "/data/openan-registry"),
                          ("openan-oc-pv", "/data/openan-orchestration")]:
        pv = docs[pv_name]
        assert pv["spec"]["hostPath"]["path"] == path
        assert pv["spec"]["storageClassName"] == "openan-local"
        affinity = pv["spec"]["nodeAffinity"]["required"]["nodeSelectorTerms"][0]["matchExpressions"][0]
        assert affinity["values"] == ["node-a"]
    for claim in ("registry-center-runtime", "orchestration-center-runtime"):
        assert docs[claim]["spec"]["storageClassName"] == "openan-local"


@pytest.mark.parametrize("component", ["registry", "orchestration"])
def test_local_pv_fallback_requires_storage_class_then_node(component):
    settings = {f"{component}.persistence.createPV": True,
                f"{component}.persistence.useHostPath": False}
    assert "requires storageClassName" in render(settings, success=False)
    settings[f"{component}.persistence.storageClassName"] = "openan-local"
    assert "local PV requires nodeName" in render(settings, success=False)
    settings[f"{component}.persistence.nodeName"] = "node-a"
    render(settings)  # complete fallback triple renders


def test_postgres_local_pv_requires_node_name():
    settings = {"postgresql.storage.createPV": True, "postgresql.storage.useHostPath": False}
    assert "postgresql.storage local PV requires nodeName" in render(settings, success=False)


def test_disabled_registry_has_no_runtime_claim_or_replica_guard():
    docs = render({"registry.enabled": False, "registry.replicas": 2})
    assert "registry-center-runtime" not in docs


def test_existing_model_secret_wins_over_inline_key():
    docs = render({"registry.llm.chat.apiKey": "test-only-inline-value",
                   "registry.llm.chat.existingSecret": "preferred-model-secret"})
    env = docs["registry-center"]["spec"]["template"]["spec"]["containers"][0]["env"]
    entry = next(e for e in env if e["name"] == "LLM_CHAT_API_KEY")
    assert entry["valueFrom"]["secretKeyRef"]["name"] == "preferred-model-secret"
    assert "llm-chat-api-key" not in (docs["registry-center-secret"]["stringData"] or {})


@pytest.mark.parametrize("capability", ["chat", "embed", "rerank"])
def test_orchestration_inline_model_secrets_match_environment_references(capability):
    docs = render({f"orchestration.llm.{capability}.model": "test-model",
                   f"orchestration.llm.{capability}.url": "https://example.invalid/model",
                   f"orchestration.llm.{capability}.apiKey": "synthetic-model-key"})
    env = docs["orchestration-center"]["spec"]["template"]["spec"]["containers"][0]["env"]
    ref = next(e for e in env if e["name"] == f"LLM_{capability.upper()}_API_KEY")["valueFrom"]["secretKeyRef"]
    assert docs[ref["name"]]["stringData"][ref["key"]] == "synthetic-model-key"


def test_model_and_proxy_updates_roll_out_pods():
    original = render()
    changed = render({"registry.llm.chat.model": "replacement-model",
                      "orchestration.llm.chat.model": "replacement-model",
                      "frontend.nginxConfig": "server { listen 80; }"})
    for component, checksum in [("registry-center", "checksum/models"),
                                ("orchestration-center", "checksum/models"),
                                ("openan-frontend", "checksum/nginx")]:
        before = original[component]["spec"]["template"]["metadata"]["annotations"][checksum]
        after = changed[component]["spec"]["template"]["metadata"]["annotations"][checksum]
        assert before != after


def test_frontend_portal_default():
    docs = render({"frontend.type": "portal", "frontend.image.tag": "p1"})
    deployment = docs["openan-frontend"]
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    assert "openan-portal" in container["image"]
    assert container["ports"][0]["containerPort"] == 8080
    env = {e["name"]: e["value"] for e in container["env"]}
    assert env["BACKEND_URL"] == "http://orchestration-center:5001"
    assert env["REGISTRY_URL"] == "http://registry-center:5000"
    # portal renders no chart-managed nginx ConfigMap, backendTls or checksum
    spec = deployment["spec"]["template"]["spec"]
    assert "volumes" not in spec
    assert "volumeMounts" not in container
    assert "openan-frontend-nginx-config" not in docs
    assert "checksum/nginx" not in deployment["spec"]["template"]["metadata"].get("annotations", {})
    # Service keeps the stable external port, targets the container port
    service = docs["Service/openan-frontend"]
    assert service["spec"]["ports"][0]["port"] == 80
    assert service["spec"]["ports"][0]["targetPort"] == 8080


def test_frontend_invalid_type_fails():
    assert "frontend.type must be" in render({"frontend.type": "bogus"}, success=False)


def test_registry_ingress_exposes_api_registry_path():
    docs = render()
    paths = {p["path"]: p["backend"]["service"] for p in docs["openan-registry-ingress"]["spec"]["rules"][0]["http"]["paths"]}
    assert paths["/api/registry(/|$)(.*)"]["name"] == "registry-center"
    assert paths["/api/registry(/|$)(.*)"]["port"]["number"] == 5000
    assert paths["/registry(/|$)(.*)"]["name"] == "registry-center"


def test_frontend_image_override_beats_type_default():
    docs = render({"frontend.type": "portal", "frontend.image.repository": "harbor.local/openan/portal-custom",
                   "frontend.image.tag": "custom"})
    container = docs["openan-frontend"]["spec"]["template"]["spec"]["containers"][0]
    assert container["image"] == "harbor.local/openan/portal-custom:custom"


def test_portal_skips_backend_tls_requirement_under_oc_https():
    docs = render({"frontend.type": "portal",
                   "registry.tls.enabled": True, "registry.tls.existingSecret": "rc-tls",
                   "orchestration.tls.enabled": True, "orchestration.tls.existingSecret": "oc-tls",
                   "orchestration.registryClientSecret": "oc-registry-trust",
                   "registry.ingressClientSecret": "rc-ingress-trust",
                   "orchestration.ingressClientSecret": "oc-ingress-trust"})
    # Validation passes without frontend.backendTls; env URLs follow the TLS switches.
    container = docs["openan-frontend"]["spec"]["template"]["spec"]["containers"][0]
    env = {e["name"]: e["value"] for e in container["env"]}
    assert env["BACKEND_URL"] == "https://orchestration-center:5001"
    assert env["REGISTRY_URL"] == "https://registry-center:5000"


def test_external_full_model_config_accepts_custom_provider():
    docs = render({"registry.modelsConfigMap": "full-models",
                   "registry.llm.chat.provider": "aoc_signed"})
    assert "registry-center-models" not in docs
    volumes = docs["registry-center"]["spec"]["template"]["spec"]["volumes"]
    assert next(v for v in volumes if v["name"] == "models")["configMap"]["name"] == "full-models"


def test_internal_postgres_custom_port_is_used_by_server_and_probe():
    docs = render({"postgresql.port": 5544})
    container = docs["openan-postgres"]["spec"]["template"]["spec"]["containers"][0]
    assert container["args"] == ["-p", "5544"]
    assert container["readinessProbe"]["exec"]["command"][-2:] == ["-p", "5544"]
    assert docs["registry-center-config"]["data"]["DB_PORT"] == "5544"


@pytest.mark.parametrize("args,message", [
    (["--no-push"], "requires one platform"),
    (["--tag"], "requires a value"),
])
def test_invalid_build_flags_do_not_start_docker(args, message):
    if not BASH:
        pytest.skip("Bash unavailable")
    result = subprocess.run([BASH, str(ROOT / "containerized/build/build.sh"), *args],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode != 0
    assert message in result.stdout + result.stderr
    assert "Build completed" not in result.stdout


def test_build_failure_is_nonzero_and_does_not_report_success(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    source = tmp_path / "archive-source"
    source.mkdir()
    (source / "Dockerfile").write_text("FROM scratch\n")
    archive = tmp_path / "source.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(source, arcname="source")
    shim = tmp_path / "shim"
    shim.mkdir()
    docker = shim / "docker"
    docker.write_text('#!/usr/bin/env bash\nif [[ "$1 $2" == "buildx build" ]]; then exit 17; fi\nexit 0\n', newline="\n")
    docker.chmod(0o755)
    def shell_path(path):
        if os.name != "nt":
            return str(path)
        return subprocess.check_output([BASH, "-c", 'cygpath -u "$1"', "test", str(path)], text=True).strip()
    command = [BASH, "-c", 'export PATH="$1:$PATH"; shift; exec bash "$@"', "test", shell_path(shim),
               shell_path(ROOT / "containerized/build/build.sh"), "registry", "--platforms", "linux/amd64",
               "--no-push", "--registry-release", archive.as_uri()]
    result = subprocess.run(command, text=True, capture_output=True, timeout=30)
    assert result.returncode == 17, result.stdout + result.stderr
    assert "Build completed" not in result.stdout and "Done:" not in result.stdout


def _run_build_with_shim(script, args, shim_dir, timeout=60):
    # Prepend a stub dir to PATH so `curl`/`docker` can be faked; real python3/
    # tar/sha256sum remain available from the ambient PATH.
    command = [BASH, "-c", 'export PATH="$1:$PATH"; shift; exec bash "$@"', "test",
               str(shim_dir), str(script), *args]
    return subprocess.run(command, text=True, capture_output=True, timeout=timeout)


@pytest.mark.parametrize("args,expected", [
    (["--source-ref", "main"], r"main-\d{8}"),
    (["--source-ref", "v1.1.0"], r"v1\.1\.0"),
    (["--source-ref", "main", "--tag", "custom"], r"custom"),
])
def test_build_source_ref_derives_image_tag(args, expected, tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    shim = tmp_path / "bin"
    shim.mkdir()
    curl = shim / "curl"
    curl.write_text("#!/usr/bin/env bash\nexit 1\n")
    curl.chmod(0o755)
    result = _run_build_with_shim(ROOT / "containerized/build/build.sh", args, shim)
    match = re.search(r"Image tag:\s+(\S+)", result.stdout)
    assert match, result.stdout + result.stderr
    assert re.fullmatch(expected, match.group(1)), result.stdout


def test_offline_compose_source_ref_derives_dated_tag(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    shim = tmp_path / "bin"
    shim.mkdir()
    log = tmp_path / "docker-args.txt"
    docker = shim / "docker"
    docker.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{log}"\nexit 1\n')
    docker.chmod(0o755)
    python3 = shim / "python3"
    python3.write_text("#!/usr/bin/env bash\nexit 0\n")
    python3.chmod(0o755)
    result = _run_build_with_shim(
        ROOT / "containerized/offline-install-compose/build/build-offline.sh",
        ["--source-ref", "main", "--app-source", "pull",
         "--platforms", "linux/amd64", "--out", str(tmp_path / "dist")],
        shim)
    calls = log.read_text() if log.exists() else ""
    assert re.search(r"registry-center:main-\d{8}", calls), \
        result.stdout + result.stderr + "\nDOCKER CALLS:\n" + calls


def test_offline_compose_per_component_tags_override_global(tmp_path):
    # --registry-tag/--orchestration-tag/--portal-tag override the global
    # tag for their component; --orchestration-tag also covers
    # workflow-designer; unset components keep the global tag. The docker
    # shim succeeds for pull/inspect/save/create so every component is
    # prepared and logged before the (expected) web-extraction failure.
    if not BASH:
        pytest.skip("Bash unavailable")
    shim = tmp_path / "bin"
    shim.mkdir()
    log = tmp_path / "docker-args.txt"
    docker = shim / "docker"
    docker.write_text(f'''#!/usr/bin/env bash
printf "%s\\n" "$*" >> "{log}"
case "$1 $2" in
  "image inspect") echo "linux/amd64"; exit 0 ;;
  "save -o") printf x > "$3"; exit 0 ;;
  "create --platform") echo "fakecid"; exit 0 ;;
esac
exit 0
''')
    docker.chmod(0o755)
    python3 = shim / "python3"
    python3.write_text("#!/usr/bin/env bash\nexit 0\n")
    python3.chmod(0o755)
    result = _run_build_with_shim(
        ROOT / "containerized/offline-install-compose/build/build-offline.sh",
        ["--tag", "v1.0.0", "--app-source", "pull",
         "--registry-tag", "v1.1.2", "--orchestration-tag", "main-20261019",
         "--platforms", "linux/amd64", "--out", str(tmp_path / "dist")],
        shim)
    calls = log.read_text() if log.exists() else ""
    assert "registry-center:v1.1.2" in calls, \
        result.stdout + result.stderr + "\nDOCKER CALLS:\n" + calls
    assert "orchestration-center:main-20261019" in calls
    assert "workflow-designer:main-20261019" in calls  # shares the OC tag
    assert "openan-portal:v1.0.0" in calls             # unset -> global tag
    assert "registry-center:v1.0.0" not in calls       # overridden


def test_build_local_source_skips_remote_download(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    src = tmp_path / "registry-src"
    src.mkdir()
    (src / "Dockerfile").write_text("FROM scratch\n")
    shim = tmp_path / "bin"
    shim.mkdir()
    marker = tmp_path / "curl-called"
    curl = shim / "curl"
    curl.write_text(f'#!/usr/bin/env bash\ntouch "{marker}"\nexit 1\n')
    curl.chmod(0o755)
    docker = shim / "docker"
    docker.write_text("#!/usr/bin/env bash\nexit 0\n")
    docker.chmod(0o755)
    result = _run_build_with_shim(
        ROOT / "containerized/build/build.sh",
        ["registry", "--registry-src", str(src), "--no-push", "--platforms", "linux/amd64"],
        shim)
    assert not marker.exists(), result.stdout + result.stderr
    assert "Build completed" in result.stdout, result.stdout + result.stderr


def test_offline_compose_build_remote_source_downloads_archive(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    shim = tmp_path / "bin"
    shim.mkdir()
    log = tmp_path / "curl-urls.txt"
    curl = shim / "curl"
    curl.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{log}"\nexit 1\n')
    curl.chmod(0o755)
    docker = shim / "docker"
    docker.write_text("#!/usr/bin/env bash\nexit 0\n")
    docker.chmod(0o755)
    python3 = shim / "python3"
    python3.write_text("#!/usr/bin/env bash\nexit 0\n")
    python3.chmod(0o755)
    result = _run_build_with_shim(
        ROOT / "containerized/offline-install-compose/build/build-offline.sh",
        ["--source-ref", "main", "--app-source", "build",
         "--platforms", "linux/amd64", "--out", str(tmp_path / "dist")],
        shim)
    calls = log.read_text() if log.exists() else ""
    assert "registry-center/archive/main.tar.gz" in calls, \
        result.stdout + result.stderr + "\nCURL CALLS:\n" + calls


def test_offline_install_source_ref_derives_dated_tag(tmp_path):
    # The legacy k8s offline builder is no longer gated at entry (BUG-fix:
    # it was marked deprecated); verify it runs and derives main-YYYYMMDD.
    if not BASH:
        pytest.skip("Bash unavailable")
    shim = tmp_path / "bin"
    shim.mkdir()
    curl = shim / "curl"
    curl.write_text("#!/usr/bin/env bash\nexit 1\n")
    curl.chmod(0o755)
    docker = shim / "docker"
    docker.write_text("#!/usr/bin/env bash\nexit 0\n")
    docker.chmod(0o755)
    result = _run_build_with_shim(
        ROOT / "containerized/offline-install/build/build-offline.sh",
        ["--source-ref", "main", "--out", str(tmp_path / "dist")],
        shim, timeout=90)
    assert re.search(r"openan-offline-main-\d{8}", result.stdout), \
        result.stdout + result.stderr
