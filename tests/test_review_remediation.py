# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Anchoring regressions for reviewed deployment contracts, not cluster acceptance."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest
import yaml

from test_deployment_contract import BASH, CHART, ROOT, render


def external(db, port=None):
    settings = {"database.type": db, "postgresql.enabled": False, "database.host": "sql.example",
                "database.registry.existingSecret": "rc-db", "database.orchestration.existingSecret": "oc-db"}
    if port is not None:
        settings["database.port"] = port
    return settings


@pytest.mark.parametrize("db,port,expected", [
    ("postgresql", 5544, "5544"), ("postgresql", None, "5432"),
    ("mysql", 3344, "3344"), ("mysql", None, "3306"),
])
def test_external_port_is_consumed_by_both_services(db, port, expected):
    docs = render(external(db, port))
    for component in ("registry", "orchestration"):
        assert docs[component + "-center-config"]["data"]["DB_PORT"] == expected


def test_bundled_pg_uses_its_listener_not_external_port():
    docs = render({"postgresql.port": 5545, "database.port": 3344})
    assert docs["registry-center-config"]["data"]["DB_PORT"] == "5545"


@pytest.mark.parametrize("port", ["invalid", -1, 0, 65536, "12.5"])
def test_invalid_sql_port_fails_before_deployment(port):
    assert "SQL port" in render(external("postgresql", port), success=False)


def test_external_database_isolation_only_applies_to_enabled_services():
    settings = external("mysql")
    settings.update({"database.registry.name": "same_db", "database.orchestration.name": "same_db"})
    assert "separate external database names" in render(settings, success=False)
    render({**settings, "orchestration.enabled": False, "frontend.enabled": False})


def test_namespace_mismatch_is_rejected():
    assert "namespace must match" in render({"namespace": "another"}, success=False)


@pytest.mark.parametrize("component", ["registry", "orchestration", "frontend"])
def test_no_implicit_old_image_tag(component):
    assert "image.tag is required" in render({component + ".image.tag": ""}, success=False)


def test_probe_san_host_overrides_are_rendered():
    docs = render({"registry.extraEnv.REGISTRY_HEALTHCHECK_HOST": "registry-center",
                   "orchestration.extraEnv.ORCH_HEALTHCHECK_HOST": "orchestration-center"})
    assert docs["registry-center-config"]["data"]["REGISTRY_HEALTHCHECK_HOST"] == "registry-center"
    assert docs["orchestration-center-config"]["data"]["ORCH_HEALTHCHECK_HOST"] == "orchestration-center"
    # Avoid a bootstrap loop: Service endpoints don't exist until these probes pass.
    for component in ("registry", "orchestration"):
        spec = docs[component + "-center"]["spec"]["template"]["spec"]
        assert spec["hostAliases"] == [{"ip": "127.0.0.1", "hostnames": [component + "-center"]}]


def test_default_ip_probe_needs_no_dns_alias():
    docs = render()
    assert "hostAliases" not in docs["registry-center"]["spec"]["template"]["spec"]
    assert "hostAliases" not in docs["orchestration-center"]["spec"]["template"]["spec"]


@pytest.mark.parametrize("settings", [
    {"orchestration.extraEnv.ORCH_HEALTHCHECK_HOST": "registry-center"},
    {"registry.extraEnv.REGISTRY_HEALTHCHECK_HOST": "orchestration-center.openan.svc.cluster.local"},
    {"registry.extraEnv.REGISTRY_HEALTHCHECK_HOST": "openan-postgres"},
    {"orchestration.extraEnv.ORCH_HEALTHCHECK_HOST": "external.example",
     "orchestration.agentRegistryUrl": "https://external.example:8443"},
])
def test_probe_dns_alias_must_not_shadow_known_upstream(settings):
    assert "probe host must not shadow" in render(settings, success=False)


def test_public_example_really_renders():
    from test_deployment_contract import HELM
    if not HELM:
        pytest.skip("Set HELM_BIN")
    result = subprocess.run([HELM, "template", "openan", str(CHART), "--namespace", "openan",
                             "-f", str(ROOT / "containerized/online-install/deployment.yaml.example")],
                            capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == 0, result.stderr
    docs = list(yaml.safe_load_all(result.stdout))
    assert any(d and d.get("kind") == "PersistentVolumeClaim" for d in docs)


def wizard():
    path = ROOT / "containerized/online-install/configure.py"
    spec = importlib.util.spec_from_file_location("guided_config", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _mock_wizard(monkeypatch, module, *, asks=None, chooses=None, secrets=None, optional=None, probe=True):
    """Wire monkeypatch mocks for the new wizard interaction model.

    ask() now takes (label, default="", required=True); choose() takes
    (label, options, default); secret_input() takes (label).  Each category
    has its own iterable consumed in call order, so tests don't depend on
    interleaving between ask/choose/secret/optional.
    """
    if asks is not None:
        asks = iter(asks)
        monkeypatch.setattr(module, "ask", lambda *a, **kw: next(asks))
    if chooses is not None:
        chooses = iter(chooses)
        monkeypatch.setattr(module, "choose", lambda *a, **kw: next(chooses))
    if optional is not None:
        optional = iter(optional)
        monkeypatch.setattr(module, "ask_optional", lambda *a, **kw: next(optional))
    else:
        monkeypatch.setattr(module, "ask_optional", lambda *a, **kw: "")
    if secrets is not None:
        secrets = iter(secrets)
        monkeypatch.setattr(module, "secret_input", lambda *a, **kw: next(secrets))
    else:
        monkeypatch.setattr(module, "secret_input", lambda *a, **kw: "SyntheticSecret9!")
    monkeypatch.setattr(module, "probe_llm", lambda model, url, key: probe)


def test_wizard_secret_only_uses_stdin_and_sanitizes_errors(monkeypatch):
    module = wizard()
    calls = []
    def run(command, **kwargs):
        calls.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0 if len(calls) == 1 else 1, "", "canary-secret")
    monkeypatch.setattr(module.subprocess, "run", run)
    with pytest.raises(RuntimeError) as error:
        module.create_secret("openan", "runtime", {"password": "canary-secret"})
    assert "canary-secret" not in str(error.value)
    assert all("canary-secret" not in json.dumps(command) for command, _ in calls)
    document = json.loads(calls[-1][1]["input"])
    assert base64.b64decode(document["data"]["password"]) == b"canary-secret"


def test_wizard_never_overwrites_an_existing_secret(monkeypatch):
    module = wizard()
    calls = []
    def run(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0, "secret/runtime\n", "")
    monkeypatch.setattr(module.subprocess, "run", run)
    with pytest.raises(RuntimeError):
        module.create_secret("openan", "runtime", {"password": "canary-secret"})
    assert len(calls) == 1


def test_wizard_generated_values_contain_references_not_credentials(tmp_path, monkeypatch):
    module = wizard()
    # Interaction: components=all, tags, frontend, LLM=skip, signing=auto
    _mock_wizard(
        monkeypatch, module,
        asks=["v1.0.0", "v1.0.0"],
        chooses=["all", "workflow-designer", "skip", "auto", "no"],
        secrets=["PgSecret123!", "AdminPass123!xy"],
    )
    saved = {}
    monkeypatch.setattr(module, "create_secret", lambda ns, name, data: saved.update({name: data}))
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "{}", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output)
    values = json.loads(output.read_text(encoding="utf-8"))
    assert "SyntheticSecret9!" not in output.read_text(encoding="utf-8")
    token = saved["openan-oc-runtime"]["REGISTRY_ACCESS_TOKEN"]
    assert token not in output.read_text(encoding="utf-8")
    assert "token_hash=" in saved["openan-rc-credentials"]["integration_credentials.conf"]
    # SQL is not asked: evaluation always uses in-cluster PostgreSQL
    assert values["postgresql"] == {"enabled": True, "existingSecret": "openan-pg"}
    assert values["database"] == {"type": "postgresql"}


def test_offline_k8s_entrypoints_are_not_sealed():
    # The offline Kubernetes line is maintained again; the legacy refusal
    # seals must stay out of both entrypoints.
    for script in ("containerized/offline-install/scripts/install.sh",
                   "containerized/offline-install/build/build-offline.sh"):
        text = Path(ROOT, script).read_text(encoding="utf-8")
        assert "Legacy offline Kubernetes installer is unsupported" not in text
        assert "refuse execution" not in text


def test_wizard_in_cluster_default_values_shape(tmp_path, monkeypatch):
    module = wizard()
    _mock_wizard(
        monkeypatch, module,
        asks=["v1.0.0", "v1.0.0"],
        chooses=["all", "workflow-designer", "skip", "auto", "no"],
        secrets=["PgSecret123!", "AdminPass123!xy"],
    )
    saved = {}
    monkeypatch.setattr(module, "create_secret", lambda ns, name, data: saved.update({name: data}))
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output)
    text = output.read_text(encoding="utf-8")
    values = json.loads(text)
    assert values["postgresql"] == {"enabled": True, "existingSecret": "openan-pg"}
    assert values["database"] == {"type": "postgresql"}
    assert values["registry"]["signing"] == {"mode": "auto"}
    # Not asked anymore: evaluation always uses the catch-all host (LB-IP access)
    assert values["ingress"] == {"host": ""}
    assert saved["openan-pg"] == {"postgres-password": "PgSecret123!"}
    assert "PgSecret123!" not in text


def test_wizard_generate_models_keeps_keys_only_in_runtime_secrets(tmp_path, monkeypatch):
    module = wizard()
    # Interaction: all, tags, frontend, LLM=now + chat model/URL + reuse + no embed/rerank
    # + no a2at, signing=auto
    _mock_wizard(
        monkeypatch, module,
        asks=[
            "v1.0.0", "v1.0.0",
            "rc-model-id", "https://llm.example/v1/chat/completions",
        ],
        chooses=["all", "workflow-designer", "now", "yes", "no", "no", "auto"],
        secrets=["rc-llm-key", "PgSecret9!", "AdminPassw0rd!xy"],
        optional=iter(["", "", ""]),           # embed/rerank/a2at all skipped
    )
    saved, configmaps = {}, {}
    monkeypatch.setattr(module, "create_secret", lambda ns, name, data: saved.update({name: data}))
    monkeypatch.setattr(module, "create_configmap", lambda ns, name, data: configmaps.update({name: data}))
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output, tag="tested")
    text = output.read_text(encoding="utf-8")
    values = json.loads(text)

    rc_models = configmaps["openan-rc-models"]["models.yaml"]
    oc_models = configmaps["openan-oc-models"]["models.yaml"]
    assert "api_key_env: LLM_CHAT_API_KEY" in rc_models and "api_key_env: LLM_CHAT_API_KEY" in oc_models
    assert '"rc-model-id"' in rc_models and '"rc-model-id"' in oc_models
    assert "rc-llm-key" not in rc_models and "rc-llm-key" not in oc_models
    assert values["registry"]["modelsConfigMap"] == "openan-rc-models"
    assert values["orchestration"]["modelsConfigMap"] == "openan-oc-models"
    assert saved["openan-rc-runtime"]["LLM_CHAT_API_KEY"] == "rc-llm-key"
    assert saved["openan-oc-runtime"]["LLM_CHAT_API_KEY"] == "rc-llm-key"
    assert saved["openan-oc-runtime"]["OC_ADMIN_INITIAL_PASSWORD"] == "AdminPassw0rd!xy"
    assert "REGISTRY_ACCESS_TOKEN" in saved["openan-oc-runtime"]
    for secret in ("rc-llm-key", "AdminPassw0rd!xy", "PgSecret9!"):
        assert secret not in text


def test_ci_uses_accepted_org_revisions():
    workflow = (ROOT / ".github/workflows/deployment-contract.yml").read_text(encoding="utf-8")
    assert "repository: project-openan/registry-center" in workflow
    assert "repository: project-openan/orchestration-center" in workflow
    assert "repository: Zhoujie628/" not in workflow


def test_frontend_cache_is_static_only():
    config = render()["openan-frontend-nginx-config"]["data"]["default.conf"]
    assert "gzip on;" in config and "gzip off;" in config
    assert 'location = /index.html' in config and '"no-store"' in config
    assert "^/assets/" in config and "immutable" in config
    assert 'add_header X-XSS-Protection' not in config


def test_guided_skip_phases_preserve_selected_release_namespace_and_fail_fast(tmp_path):
    if not BASH:
        pytest.skip("Set BASH_BIN")
    from test_offline_compose_contract import shell_path
    values = tmp_path / "deployment.yaml"
    values.write_text("namespace: team-a\n", encoding="utf-8")
    script = ROOT / "containerized/online-install/install.sh"
    # Exported functions are test-owned substitutes, never real cluster/build calls.
    shim = """
kubectl() { echo "KUBECTL:$*" >&2; }
helm() { echo "HELM:$*" >&2; }
python3() { echo "Unexpected wizard execution" >&2; return 99; }
export -f kubectl helm python3
bash "$@"
"""
    result = subprocess.run([BASH, "-c", shim, "test", shell_path(script),
                             "--skip-build", "--skip-infra", "--values", shell_path(values),
                             "--release", "custom", "--namespace", "team-a"],
                            capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == 0, result.stderr
    assert "HELM:upgrade --install custom" in result.stderr
    assert "--namespace team-a" in result.stderr
    assert "Unexpected wizard" not in result.stderr
    assert "metallb" not in result.stderr and "ingress-nginx" not in result.stderr
    failed = subprocess.run([BASH, "-c", shim, "test", shell_path(script), "--skip-build",
                             "--values", shell_path(values)], capture_output=True, text=True, encoding="utf-8")
    assert failed.returncode == 2
    assert "KUBECTL:" not in failed.stderr and "HELM:" not in failed.stderr


def test_wizard_rejects_missing_public_dependencies_before_secrets(tmp_path, monkeypatch):
    module = wizard()
    # When signing=secret the Secret name is validated BEFORE any secret is collected.
    _mock_wizard(
        monkeypatch, module,
        asks=["v1.0.0", "v1.0.0", "my-signing-secret"],
        chooses=["all", "workflow-designer", "skip", "secret", "no"],
        secrets=None,
    )
    # kubectl get returns non-zero -> reference check fails
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 1, "", ""))
    monkeypatch.setattr(module, "secret_input", lambda *a, **kw: pytest.fail("Must not collect secrets yet"))
    monkeypatch.setattr(module, "create_secret", lambda *args: pytest.fail("Must not create secrets yet"))
    with pytest.raises(ValueError, match="reference"):
        module.configure("openan", "openan", tmp_path / "values.json")


def test_compose_and_helm_static_asset_policy_agree():
    from test_offline_compose_contract import configure
    config = configure.nginx_config(False, [], Path("unused"), portal=False)
    assert "gzip on;" in config and "^/assets/" in config
    assert "immutable" in config and "no-store" in config
    assert 'add_header X-XSS-Protection' not in config


def test_wizard_local_storage_fallback_values(tmp_path, monkeypatch):
    module = wizard()
    _mock_wizard(
        monkeypatch, module,
        asks=["v1.0.0", "v1.0.0"],
        chooses=["all", "workflow-designer", "skip", "auto", "no"],
        secrets=["PgSecret123!", "AdminPass123!xy"],
    )
    # No default StorageClass and a detectable node: the fallback engages
    # automatically (no storage question anymore).
    monkeypatch.setattr(module, "first_node", lambda: "node-1")
    monkeypatch.setattr(module, "has_default_storageclass", lambda: False)
    monkeypatch.setattr(module, "create_secret", lambda *args: None)
    monkeypatch.setattr(module, "create_configmap", lambda *args: None)
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output, tag="tested")
    values = json.loads(output.read_text(encoding="utf-8"))
    assert values["postgresql"]["storage"] == {"createStorageClass": True, "storageClassName": "openan-local",
                                               "createPV": True, "useHostPath": True, "nodeName": "node-1"}
    for component in ("registry", "orchestration"):
        assert values[component]["persistence"] == {"storageClassName": "openan-local", "createPV": True,
                                                    "useHostPath": True, "nodeName": "node-1"}


def test_wizard_per_component_image_tags(tmp_path, monkeypatch):
    module = wizard()
    # Per-component tags: registry and orchestration get different tags, frontend=portal
    # gets its own tag (not following orchestration).
    _mock_wizard(
        monkeypatch, module,
        asks=["v1.1.2", "main-20261019", "v2.0.0"],
        chooses=["all", "portal", "skip", "auto", "no"],
        secrets=["PgSecret123!", "AdminPass123!xy"],
    )
    monkeypatch.setattr(module, "create_secret", lambda *args: None)
    monkeypatch.setattr(module, "create_configmap", lambda *args: None)
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output)
    values = json.loads(output.read_text(encoding="utf-8"))
    assert values["registry"]["image"]["tag"] == "v1.1.2"
    assert values["orchestration"]["image"]["tag"] == "main-20261019"
    assert values["frontend"]["image"]["tag"] == "v2.0.0"


def test_wizard_frontend_workflow_designer_follows_orchestration_tag(tmp_path, monkeypatch):
    module = wizard()
    _mock_wizard(
        monkeypatch, module,
        asks=["v1.1.2", "main-20261019"],
        chooses=["all", "workflow-designer", "skip", "auto", "no"],
        secrets=["PgSecret123!", "AdminPass123!xy"],
    )
    monkeypatch.setattr(module, "create_secret", lambda *args: None)
    monkeypatch.setattr(module, "create_configmap", lambda *args: None)
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output)
    values = json.loads(output.read_text(encoding="utf-8"))
    assert values["frontend"]["image"]["tag"] == "main-20261019"


def test_wizard_optional_models_and_a2at_land_in_values_and_secrets(tmp_path, monkeypatch):
    module = wizard()
    # Interaction: all, tags, frontend, LLM=now + chat + reuse=yes + embed=yes +
    # rerank=no + a2at=yes, signing=auto
    # a2at model goes through ask_optional; its URL goes through ask.
    _mock_wizard(
        monkeypatch, module,
        asks=[
            "v1.0.0", "v1.0.0",
            "rc-chat-model", "https://llm.example/v1/chat/completions",
            "https://llm.example/v1/embeddings",   # embed URL
            "https://api.example.com/v1",          # a2at URL
        ],
        chooses=["all", "workflow-designer", "now", "yes", "auto", "no"],
        secrets=[
            "rc-chat-key", "rc-embed-key",       # registry chat + embed keys
            "a2at-key",                           # a2at key
            "PgSecret9!", "AdminPassw0rd!xy",
        ],
        optional=iter(["rc-embed-model", "", "a2at-model"]),  # embed model, rerank skip, a2at model
    )
    saved, configmaps = {}, {}
    monkeypatch.setattr(module, "create_secret", lambda ns, name, data: saved.update({name: data}))
    monkeypatch.setattr(module, "create_configmap", lambda ns, name, data: configmaps.update({name: data}))
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output, tag="tested")
    text = output.read_text(encoding="utf-8")
    values = json.loads(text)
    rc_models = configmaps["openan-rc-models"]["models.yaml"]
    oc_models = configmaps["openan-oc-models"]["models.yaml"]
    assert "embed:" in rc_models and "api_key_env: LLM_EMBED_API_KEY" in rc_models
    assert "rerank:" not in rc_models  # skipped for registry
    assert "embed:" in oc_models and "rerank:" not in oc_models
    assert saved["openan-rc-runtime"]["LLM_EMBED_API_KEY"] == "rc-embed-key"
    assert "LLM_RERANK_API_KEY" not in saved["openan-rc-runtime"]
    assert saved["openan-oc-runtime"]["LLM_EMBED_API_KEY"] == "rc-embed-key"
    assert saved["openan-oc-runtime"]["A2AT_LLM_API_KEY"] == "a2at-key"
    assert values["orchestration"]["a2atLlm"] == {"provider": "openai", "model": "a2at-model",
                                                  "baseUrl": "https://api.example.com/v1"}
    for secret in ("rc-chat-key", "rc-embed-key", "a2at-key", "AdminPassw0rd!xy"):
        assert secret not in text


def test_wizard_failure_prints_concrete_reason_without_traceback(tmp_path):
    result = subprocess.run(
        [sys.executable, str(ROOT / "containerized/online-install/configure.py"),
         "--namespace", "openan", "--release", "openan", "--output", str(tmp_path / "values.json")],
        input="", capture_output=True, text=True, encoding="utf-8", timeout=30)
    assert result.returncode == 2
    assert "Configuration failed:" in result.stderr
    assert "Traceback" not in result.stderr


def test_uninstall_detects_all_openan_pvs_and_grouped_hostpath_cleanup():
    # Regression: uninstall used to recognize only openan-postgres-pv and scan
    # a single hostPath; manually created rc/oc PVs were never cleaned.
    text = (ROOT / "containerized/online-install/uninstall.sh").read_text(encoding="utf-8")
    assert "app.kubernetes.io/part-of=openan" in text
    assert "{.spec.volumeName}" in text
    for pv in ("openan-postgres-pv", "openan-rc-pv", "openan-oc-pv"):
        assert pv in text
    assert "clean_hostpath_node" in text


def test_uninstall_accepts_release_and_namespace_overrides():
    # install.sh defaults release/namespace but allows --release/--namespace;
    # the uninstaller must accept the same overrides or it cannot find them.
    text = (ROOT / "containerized/online-install/uninstall.sh").read_text(encoding="utf-8")
    assert "--namespace" in text and "--release" in text
    assert 'CONFIG_NAMESPACE="' in text and 'CONFIG_RELEASE_NAME="' in text


def test_install_nodeport_fallback_uses_the_frontend_service():
    # Regression: the fallback queried the legacy "workflow-designer" Service,
    # but both frontend types deploy as openan-frontend — the NodePort lookup
    # always failed.
    text = (ROOT / "containerized/online-install/install.sh").read_text(encoding="utf-8")
    assert "get svc openan-frontend" in text
    assert "get svc workflow-designer" not in text


def test_install_offers_agent_examples_server_interactively():
    # Demo agents (samples/start_agents_server.py) run in the orchestration
    # pod on request, mirroring the offline installer; the offer is
    # interactive-only (--values mode never starts it) and health-checked.
    text = (ROOT / "containerized/online-install/install.sh").read_text(encoding="utf-8")
    assert "start_agents_server.py" in text
    assert "Start the agent examples server" in text
    assert "127.0.0.1:8903/health" in text
    values_mode = text.split("Interactive mode")[0]
    assert "start_agents_server.py" not in values_mode


def test_install_auto_install_and_deploy_gate_are_interactive_only():
    # Missing kubectl/helm (and Docker for builds) can be auto-installed via
    # official installers behind an explicit confirmation, and the deploy is
    # gated by a non-secret summary — but never in --values/CI mode.
    text = (ROOT / "containerized/online-install/install.sh").read_text(encoding="utf-8")
    assert "Install missing tools automatically" in text
    assert "https://dl.k8s.io/release" in text
    assert "get-helm-3" in text
    assert "get.docker.com" in text
    assert "Deploy with this configuration?" in text
    assert "python3 must be installed manually" in text
    values_mode = text.split("Interactive mode")[0]
    assert "dl.k8s.io" not in values_mode
    assert "get-helm-3" not in values_mode
    assert "get.docker.com" not in values_mode
    assert "Deploy with this configuration?" not in values_mode
