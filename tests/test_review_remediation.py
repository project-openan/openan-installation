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
    settings = {"database.type": db, "database.bundled": False, "database.host": "sql.example",
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


@pytest.mark.parametrize("db,port", [("gauss", 5432), ("oracle", 1521)])
def test_external_type_passthrough_flows_to_services(db, port):
    # issue #36: any backend the services support works as external SQL
    # with zero chart changes — the type passes through to PERSISTENCE_MODE.
    docs = render(external(db, port))
    for component in ("registry", "orchestration"):
        config = docs[component + "-center-config"]["data"]
        assert config["PERSISTENCE_MODE"] == db
        assert config["DB_HOST"] == "sql.example"
        assert config["DB_PORT"] == str(port)


def test_external_type_without_port_fails_with_clear_message():
    # Unknown types carry no default port: the omission must fail at render
    # time, not deploy a bogus port.
    assert "known default port" in render(external("gauss"), success=False)


def test_bundled_type_without_descriptor_fails_with_bundled_list():
    # A typo or a type the chart does not bundle must die at render time with
    # the valid bundled names — not silently deploy as external SQL.
    error = render({"database.type": "postgers", "database.existingSecret": "s"}, success=False)
    assert "database.backends entry" in error
    assert "mysql, postgresql" in error


def test_external_type_requires_host():
    # bundled=false without a host must fail loudly (the helper fires before
    # validate.yaml renders; messages are identical by contract).
    settings = {"database.type": "gauss", "database.bundled": False, "database.port": 5432,
                "database.registry.existingSecret": "rc-db",
                "database.orchestration.existingSecret": "oc-db"}
    assert "is external: set database.host" in render(settings, success=False)


def test_external_type_requires_per_service_secret_or_shared():
    settings = external("gauss", 5432)
    # The render BASE sets a shared database.existingSecret; clear it so the
    # per-service rule is what gets exercised.
    settings["database.existingSecret"] = ""
    del settings["database.registry.existingSecret"]
    assert "external SQL requires database.registry.existingSecret" in render(settings, success=False)
    # The shared database.existingSecret satisfies the external credential
    settings["database.existingSecret"] = "shared-db"
    render(settings)


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
    # An operator-created Secret (no wizard label) must never be touched.
    module = wizard()
    calls = []
    def run(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0, "secret/runtime\n", "")
    monkeypatch.setattr(module.subprocess, "run", run)
    with pytest.raises(RuntimeError):
        module.create_secret("openan", "runtime", {"password": "canary-secret"})
    # exists-check + label-check only; no create was ever submitted
    assert len(calls) == 2 and not any("create" in " ".join(map(str, c)) for c in calls)


def test_wizard_rerun_reuses_its_own_secrets_and_configmaps(monkeypatch, capsys):
    # A leftover from an interrupted wizard run must not dead-end the re-run:
    # wizard-labelled objects are adopted (idempotent re-run), never
    # re-created — the same contract as the offline installer's labelled
    # Secrets. Recovery from a midway crash is simply "run the wizard again".
    module = wizard()
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        argv = " ".join(map(str, command))
        if "jsonpath" in argv:
            # label check: the object carries the wizard label
            return subprocess.CompletedProcess(command, 0, "true\n", "")
        if "get secret" in argv:
            return subprocess.CompletedProcess(command, 0, "secret/openan-pg\n", "")
        if "get configmap" in argv:
            return subprocess.CompletedProcess(command, 0, "configmap/openan-rc-models\n", "")
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(module.subprocess, "run", run)
    module.create_secret("openan", "openan-pg", {"postgres-password": "canary-secret"})
    module.create_configmap("openan", "openan-rc-models", {"models.yaml": "..."})
    # exists-check + label-check per object; no create submitted, no values echoed
    assert len(calls) == 4 and not any("create" in " ".join(map(str, c)) for c in calls)
    captured = capsys.readouterr().out
    assert "canary-secret" not in captured
    # The reuse notice must be explicit that this run's entries do not apply
    assert "NOT applied" in captured
    assert "reusing the previous" in captured


def test_wizard_https_invokes_repo_root_gen_certs(tmp_path, monkeypatch):
    # The 1c6367f refactor moved gen_certs.py to the repo-root tool/ but left
    # the wizard resolving the old containerized/tool/ path — with the HTTPS
    # default flipped to "yes", every default wizard run failed with
    # "gen_certs.py not found at .../containerized/tool/gen_certs.py".
    # The HTTPS-yes flow must invoke the tool at its real repo-root location
    # and wire the generated material into the TLS Secrets.
    module = wizard()
    _mock_wizard(
        monkeypatch, module,
        asks=["v1.0.0", "v1.0.0"],
        chooses=["all", "workflow-designer", "in-cluster", "postgresql", "skip", "auto", "yes"],
        secrets=["PgSecret123!", "AdminPass123!xy"],
    )
    saved = {}
    monkeypatch.setattr(module, "create_secret", lambda ns, name, data: saved.update({name: data}))
    monkeypatch.setattr(module, "create_configmap", lambda ns, name, data: None)
    gen_calls = []

    def fake_run(command, **kwargs):
        argv = [str(part) for part in command]
        if any(part.endswith("gen_certs.py") for part in argv):
            gen_calls.append(argv)
            out = Path(argv[argv.index("--out") + 1])
            for service in ("registry-center", "orchestration-center"):
                (out / service).mkdir(parents=True, exist_ok=True)
                for key in ("server.cer", "server_key.pem", "cert_pwd", "trust.cer"):
                    (out / service / key).write_text("cert-material", encoding="utf-8")
            for sub in ("ingress-client", "ca", "ingress"):
                (out / sub).mkdir(parents=True, exist_ok=True)
            (out / "ingress-client" / "tls.crt").write_text("client-crt", encoding="utf-8")
            (out / "ingress-client" / "tls.key").write_text("client-key", encoding="utf-8")
            (out / "ca" / "ca.cer").write_text("ca-cer", encoding="utf-8")
            (out / "ingress" / "tls.crt").write_text("public-crt", encoding="utf-8")
            (out / "ingress" / "tls.key").write_text("public-key", encoding="utf-8")
            return subprocess.CompletedProcess(command, 0, "", "")
        # kubectl LB-IP lookup: empty stdout -> no --ingress-ip flag
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(module.subprocess, "run", fake_run)
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output)
    assert gen_calls, "the HTTPS=yes flow must invoke gen_certs.py"
    gen_script = Path(gen_calls[0][1])
    assert gen_script.is_file(), f"the invoked gen_certs.py must exist: {gen_script}"
    assert gen_script == (ROOT / "tool" / "gen_certs.py")
    # No removed flags: the tool is standalone (no --registry-center-src).
    assert not any("--registry-center-src" in flag for flag in gen_calls[0])
    # The generated material is wired into the TLS Secrets.
    assert saved["openan-rc-tls"]["server.cer"] == "cert-material"
    assert saved["openan-public-tls"]["tls.crt"] == "public-crt"


def test_wizard_generated_values_contain_references_not_credentials(tmp_path, monkeypatch):
    module = wizard()
    # Interaction: components=all, tags, frontend, LLM=skip, signing=auto
    _mock_wizard(
        monkeypatch, module,
        asks=["v1.0.0", "v1.0.0"],
        chooses=["all", "workflow-designer", "in-cluster", "postgresql", "skip", "auto", "no"],
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
    # Default path: in-cluster postgresql from the chart's descriptor data
    # (bundled flag + shared credential Secret named by the descriptor).
    assert values["database"] == {"bundled": True, "type": "postgresql",
                                  "existingSecret": "openan-pg"}
    assert "postgresql" not in values


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
        chooses=["all", "workflow-designer", "in-cluster", "postgresql", "skip", "auto", "no"],
        secrets=["PgSecret123!", "AdminPass123!xy"],
    )
    saved = {}
    monkeypatch.setattr(module, "create_secret", lambda ns, name, data: saved.update({name: data}))
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output)
    text = output.read_text(encoding="utf-8")
    values = json.loads(text)
    assert values["database"] == {"bundled": True, "type": "postgresql",
                                  "existingSecret": "openan-pg"}
    assert values["registry"]["signing"] == {"mode": "auto"}
    # Not asked anymore: evaluation always uses the catch-all host (LB-IP access)
    assert values["ingress"] == {"host": ""}
    assert saved["openan-pg"] == {"postgres-password": "PgSecret123!"}
    assert "PgSecret123!" not in text


def test_wizard_backend_menu_follows_chart_data():
    # The wizard's bundled menu is data-driven from the chart's
    # database.backends descriptor (issue #36): adding a chart backend
    # extends the wizard with zero wizard changes. The contract locks the
    # parser output to the chart file.
    module = wizard()
    backends = module.bundled_backends()
    assert set(backends) == {"postgresql", "mysql"}
    assert backends["postgresql"] == {"passwordKey": "postgres-password",
                                      "credentialSecretSuffix": "pg", "port": "5432"}
    assert backends["mysql"] == {"passwordKey": "mysql-root-password",
                                 "credentialSecretSuffix": "mysql", "port": "3306"}


def test_wizard_in_cluster_mysql_flow(tmp_path, monkeypatch):
    module = wizard()
    _mock_wizard(
        monkeypatch, module,
        asks=["v1.0.0", "v1.0.0"],
        chooses=["all", "workflow-designer", "in-cluster", "mysql", "skip", "auto", "no"],
        secrets=["MyRootPass123!", "AdminPass123!xy"],
    )
    saved = {}
    monkeypatch.setattr(module, "create_secret", lambda ns, name, data: saved.update({name: data}))
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output)
    values = json.loads(output.read_text(encoding="utf-8"))
    # Descriptor-driven Secret name and credential key: openan-mysql +
    # mysql-root-password (historical openan-pg stays untouched).
    assert values["database"] == {"bundled": True, "type": "mysql",
                                  "existingSecret": "openan-mysql"}
    assert saved["openan-mysql"] == {"mysql-root-password": "MyRootPass123!"}
    assert "openan-pg" not in saved
    assert "MyRootPass123!" not in output.read_text(encoding="utf-8")


def test_wizard_external_sql_flow(tmp_path, monkeypatch):
    module = wizard()
    _mock_wizard(
        monkeypatch, module,
        asks=["v1.0.0", "v1.0.0", "gauss", "gauss.internal", "5433"],
        chooses=["all", "workflow-designer", "external SQL", "skip", "auto", "no"],
        secrets=["ExtSecret123!", "AdminPass123!xy"],
    )
    saved = {}
    monkeypatch.setattr(module, "create_secret", lambda ns, name, data: saved.update({name: data}))
    monkeypatch.setattr(module, "create_configmap", lambda *args: None)
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output)
    values = json.loads(output.read_text(encoding="utf-8"))
    # External SQL: no bundled workload or Secret, per-service credentials,
    # type/host/port passed through (PERSISTENCE_MODE verbatim).
    assert values["database"] == {"bundled": False, "type": "gauss",
                                  "host": "gauss.internal", "port": 5433,
                                  "registry": {"existingSecret": "openan-rc-db"},
                                  "orchestration": {"existingSecret": "openan-oc-db"}}
    assert saved["openan-rc-db"] == {"db-password": "ExtSecret123!"}
    assert saved["openan-oc-db"] == {"db-password": "ExtSecret123!"}
    assert "openan-pg" not in saved and "openan-mysql" not in saved
    assert "ExtSecret123!" not in output.read_text(encoding="utf-8")


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
        chooses=["all", "workflow-designer", "in-cluster", "postgresql", "now", "yes", "no", "no", "auto"],
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
        chooses=["all", "workflow-designer", "in-cluster", "postgresql", "skip", "secret", "no"],
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
        chooses=["all", "workflow-designer", "in-cluster", "postgresql", "skip", "auto", "no"],
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
    assert values["database"]["storage"] == {"createStorageClass": True, "storageClassName": "openan-local",
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
        chooses=["all", "portal", "in-cluster", "postgresql", "skip", "auto", "no"],
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
        chooses=["all", "workflow-designer", "in-cluster", "postgresql", "skip", "auto", "no"],
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
        chooses=["all", "workflow-designer", "in-cluster", "postgresql", "now", "yes", "auto", "no"],
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
    for pv in ("openan-postgres-pv", "openan-mysql-pv", "openan-rc-pv", "openan-oc-pv"):
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


# ---------------------------------------------------------------------------
# Issue #40: interactive validation retries instead of exiting immediately
# ---------------------------------------------------------------------------
def test_issue40_offline_installer_uses_validate_with_retry():
    # The post-prompt validation block must route through the shared helper
    # (retry + skip-or-abort) instead of bare `exit 2` on the first failure.
    text = (ROOT / "containerized/offline-install/scripts/install.sh").read_text(encoding="utf-8")
    assert "validate_with_retry" in text
    for validator in ("validate_ingress_host", "validate_db_password",
                      "validate_namespace", "validate_metallb_pool"):
        assert validator in text, f"{validator} not wired into install.sh"


def test_issue40_offline_common_defines_retry_helpers():
    text = (ROOT / "containerized/offline-install/scripts/lib/common.sh").read_text(encoding="utf-8")
    assert "validate_with_retry()" in text
    assert "MAX_ATTEMPTS=3" in text
    for name in ("validate_ingress_host", "validate_db_password",
                 "validate_namespace", "validate_metallb_pool",
                 "reprompt_ingress_host", "reprompt_db_password",
                 "reprompt_namespace", "reprompt_metallb_pool"):
        assert name in text, f"{name} missing from common.sh"
    # Non-interactive fast-fail is preserved inside the helper.
    assert 'exit 2' in text


def test_issue40_online_installer_uses_validate_with_retry():
    text = (ROOT / "containerized/online-install/install.sh").read_text(encoding="utf-8")
    assert "validate_with_retry()" in text
    assert "MAX_ATTEMPTS=3" in text
    # The MetalLB pool validation routes through the shared helper.
    assert "validate_metallb_pool_cfg" in text
    assert "validate_with_retry" in text


def test_issue40_online_configure_offers_skip_after_retries():
    module = wizard()
    assert hasattr(module, "_offer_skip")
    assert hasattr(module, "ask_secret")
    # Every `for ... else: raise ValueError` validation block must route the
    # exhausted-retries path through _offer_skip before raising.
    import inspect
    source = inspect.getsource(module.configure)
    assert "_offer_skip" in source
    assert source.count("_offer_skip") >= 3, (
        "agent registry URL / PostgreSQL password / admin password must each offer skip")


def test_issue40_binary_one_click_registry_url_retry():
    text = (ROOT / "binary/one-click/install.sh").read_text(encoding="utf-8")
    assert "Issue #40" in text
    assert "MAX_ATTEMPTS=3" in text
    assert "ask_with_retry" in text
    assert "validate_registry_url" in text
    assert "reprompt_registry_url" in text
    assert "Registry URL must start with http:// or https://" in text
    # The skip prompt text uses the helper's "$label" interpolation; assert on
    # the static parts instead of the full rendered sentence.
    assert "Skip $label validation and continue anyway" in text
    # The retry is driven by the shared helper (no ad-hoc loop needed).
    assert "ask_with_retry" in text


def test_issue40_validate_ingress_host_contract():
    # Bare IP and DNS names are BOTH accepted (commit 4d518ea contract);
    # only whitespace / scheme / invalid chars fail.
    script = ROOT / "containerized/offline-install/scripts/lib/common.sh"
    text = script.read_text(encoding="utf-8")
    # Positive: the validator checks whitespace, scheme, and invalid chars —
    # the bare-IP acceptance is implicit (no IP-rejecting branch).
    assert "validate_ingress_host()" in text
    assert "must not contain whitespace" in text
    assert "no scheme/path" in text
    assert "invalid characters" in text


def test_issue40_offline_cert_ca_has_key_usage(tmp_path):
    # Regression for the CI failure: certificates() must produce a CA with
    # critical keyUsage so ssl.create_default_context accepts the chain.
    # The chown in certificates() requires root; CI runners are non-root, so
    # we monkeypatch os.chown for the cert-content assertions only.
    import subprocess
    smoke = ROOT / "tests/offline_compose_container_smoke.py"
    import importlib.util
    spec = importlib.util.spec_from_file_location("smoke", smoke)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # Non-root CI cannot chown; patch it out (cert content is what we verify).
    module.os.chown = lambda *a, **kw: None
    server, client, signing, ca_cert = module.certificates(tmp_path)
    text = subprocess.run(["openssl", "x509", "-in", str(ca_cert), "-noout", "-text"],
                          capture_output=True, text=True, check=True).stdout
    assert "X509v3 Key Usage: critical" in text
    assert "Certificate Sign" in text
    assert "CA:TRUE" in text
