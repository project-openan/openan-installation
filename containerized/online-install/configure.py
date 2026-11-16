#!/usr/bin/env python3
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Guided evaluation configuration; secrets only in memory and kubectl stdin.

Interactive wizard: components -> image tags -> database -> LLM -> signing
-> secrets. The database is one open contract: an in-cluster backend (menu
from the chart's database.backends data) or an external SQL whose type
passes through to the services verbatim. Storage is automatic (the
cluster's default StorageClass, with a node-pinned local hostPath fallback
when none exists), as are auto signing, generated models.yaml, and the
empty catch-all Ingress host for direct LB-IP access.

Production profiles (HTTPS, host-based routing) use reviewed values (see
example.values.yaml) and existing Secrets instead. No defaults for
passwords, no credential arguments, no Secret overwrite.
"""
import argparse
import base64
import getpass
import hashlib
import hmac
import json
from pathlib import Path
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.request

COMPONENTS = ("registry", "orchestration")

MAX_ATTEMPTS = 3


def _kubectl_json(args, stdin=None):
    return subprocess.run(["kubectl", *args], input=stdin, capture_output=True, text=True)


CHART_VALUES = Path(__file__).resolve().parent / "openan-chart" / "values.yaml"

# Fields of each database.backends entry the wizard needs; everything else
# (image, probes, volumes) is consumed by the chart's generic templates.
_BACKEND_FIELDS = ("passwordKey", "credentialSecretSuffix", "port")


def bundled_backends():
    """Bundled in-cluster backends are data in the chart: the keys of
    database.backends in openan-chart/values.yaml. The wizard stays
    type-agnostic — adding a bundled backend = one chart descriptor entry +
    one init template, and this menu follows without any wizard change.
    Narrow YAML parse (no PyYAML: the installer requires only python3).
    Returns {type: {passwordKey, credentialSecretSuffix, port}}, falling
    back to the historical postgresql-pg pair when the chart is unreadable.
    """
    fallback = {"postgresql": {"passwordKey": "postgres-password",
                               "credentialSecretSuffix": "pg", "port": "5432"}}
    try:
        lines = CHART_VALUES.read_text(encoding="utf-8").splitlines()
    except OSError:
        return dict(fallback)
    backends, current = {}, None
    in_database = in_backends = False
    for line in lines:
        # Order matters: "database:" itself is a top-level line, so the
        # database entry must be recognized before the generic reset.
        if re.match(r"^database:\s*$", line):
            in_database = True
            in_backends = False
            current = None
            continue
        if re.match(r"^\S", line):
            in_database = in_backends = False
            current = None
            continue
        if not in_database:
            continue
        if re.match(r"^  backends:\s*$", line):
            in_backends = True
            continue
        if in_backends and re.match(r"^  \S", line):
            in_backends = False
            current = None
            continue
        if in_backends:
            match = re.match(r"^    ([a-z0-9_-]+):\s*$", line)
            if match:
                current = match.group(1)
                backends.setdefault(current, {})
                continue
            field = re.match(r"^      (\w+):\s*(\S+)\s*$", line)
            if current is not None and field and field.group(1) in _BACKEND_FIELDS:
                backends[current][field.group(1)] = field.group(2).strip('"')
    return backends or dict(fallback)


# Objects the wizard creates carry this label; a re-run adopts them
# (recovering from an interrupted run) while operator-created objects with
# the same name still fail fast — the offline installer's Secret contract.
WIZARD_LABEL = "openan-online-installer"


def create_secret(namespace, name, values):
    result = _kubectl_json(["get", "secret", name, "-n", namespace, "--ignore-not-found", "-o", "name"])
    if result.returncode:
        raise RuntimeError(f"Could not check Secret '{name}' in namespace '{namespace}'; verify kubeconfig and RBAC")
    if result.stdout.strip():
        owned = _kubectl_json(["get", "secret", name, "-n", namespace,
                               "-o", f"jsonpath={{.metadata.labels.{WIZARD_LABEL}}}"])
        if owned.returncode == 0 and owned.stdout.strip() == "true":
            print(f"  [INFO] Secret '{name}' from a previous wizard run found — reusing the "
                  f"previous values; entries made this run are NOT applied "
                  f"(delete the Secret first to set new credentials)")
            return
        raise RuntimeError(f"Secret '{name}' already exists; use reviewed values for upgrades instead of overwriting")
    document = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                "metadata": {"namespace": namespace, "name": name,
                             "labels": {WIZARD_LABEL: "true"}},
                "data": {key: base64.b64encode(value.encode()).decode() for key, value in values.items()}}
    result = _kubectl_json(["create", "-f", "-"], stdin=json.dumps(document))
    if result.returncode:
        # Kubernetes error output can include submitted objects; never echo it.
        raise RuntimeError(f"Creating Secret '{name}' failed; inspect Kubernetes status without exposing credentials")


def create_configmap(namespace, name, data):
    result = _kubectl_json(["get", "configmap", name, "-n", namespace, "--ignore-not-found", "-o", "name"])
    if result.returncode:
        raise RuntimeError(f"Could not check ConfigMap '{name}' in namespace '{namespace}'; verify kubeconfig and RBAC")
    if result.stdout.strip():
        owned = _kubectl_json(["get", "configmap", name, "-n", namespace,
                               "-o", f"jsonpath={{.metadata.labels.{WIZARD_LABEL}}}"])
        if owned.returncode == 0 and owned.stdout.strip() == "true":
            print(f"  [INFO] ConfigMap '{name}' from a previous wizard run found — reusing the "
                  f"previous content; entries made this run are NOT applied "
                  f"(delete the ConfigMap first to regenerate it)")
            return
        raise RuntimeError(f"ConfigMap '{name}' already exists; use existing references for upgrades")
    document = {"apiVersion": "v1", "kind": "ConfigMap",
                "metadata": {"namespace": namespace, "name": name,
                             "labels": {WIZARD_LABEL: "true"}},
                "data": data}
    result = _kubectl_json(["create", "-f", "-"], stdin=json.dumps(document))
    if result.returncode:
        raise RuntimeError(f"Creating ConfigMap '{name}' failed; inspect Kubernetes status without exposing credentials")


def step_banner(step, total, title):
    print()
    print(f"  {'=' * 50}")
    print(f"  Step {step}/{total}: {title}")
    print(f"  {'=' * 50}")
    print()


def ask(label, default="", required=True):
    """Ask a question; empty input falls back to default if given, else retries."""
    prompt = f"{label} [{default}]: " if default else f"{label}: "
    for attempt in range(MAX_ATTEMPTS):
        value = input(prompt).strip()
        if value:
            return value
        if default:
            return default
        if required:
            print(f"  [WARN] {label} is required ({attempt + 1}/{MAX_ATTEMPTS})")
    raise ValueError(f"{label} not provided after {MAX_ATTEMPTS} attempts")


def choose(label, options, default):
    """Single-choice prompt; accepts full word or first-letter abbreviation."""
    for attempt in range(MAX_ATTEMPTS):
        raw = input(f"{label} [{'/'.join(options)}, default: {default}]: ").strip().lower()
        if not raw:
            return default
        # exact match
        if raw in options:
            return raw
        # first-letter abbreviation (only when unambiguous)
        matches = [o for o in options if o.startswith(raw)]
        if len(matches) == 1:
            return matches[0]
        print(f"  [WARN] '{raw}' is ambiguous or invalid; pick one of: {', '.join(options)} ({attempt + 1}/{MAX_ATTEMPTS})")
    raise ValueError(f"{label}: unsupported choice after {MAX_ATTEMPTS} attempts")


def secret_input(label):
    """Password input with asterisk masking; supports backspace."""
    if not sys.stdin.isatty():
        raise ValueError("Interactive secrets require a terminal; use --values with existing Secrets in CI")
    print(f"{label}: ", end="", flush=True)
    value = ""
    while True:
        ch = sys.stdin.read(1)
        if ch in ("\n", "\r"):
            break
        if ch in ("\x7f", "\x08"):  # backspace
            if value:
                value = value[:-1]
                print("\b \b", end="", flush=True)
            continue
        value += ch
        print("*", end="", flush=True)
    print()
    if not value:
        raise ValueError("Empty secrets are not allowed")
    return value


def _offer_skip(label):
    """Issue #40 escape hatch: after MAX_ATTEMPTS failures offer skip-or-abort."""
    prompt = f"  Skip {label} validation and continue anyway (not recommended)? [y/N]: "
    answer = input(prompt).strip().lower()
    if answer in ("y", "yes"):
        print(f"  [WARN] Continuing with invalid {label}.")
        return True
    raise ValueError(f"{label}: validation failed and was not skipped; aborting")


def ask_secret(label, required=True):
    """Hidden input with retry (MAX_ATTEMPTS), preserving secret_input()'s
    masking and non-TTY guard so existing test mocks keep working."""
    for attempt in range(MAX_ATTEMPTS):
        try:
            return secret_input(label)
        except ValueError as exc:
            if "Empty secrets are not allowed" not in str(exc):
                raise  # non-TTY / other hard failures propagate unchanged
            if not required:
                return ""
            print(f"  [WARN] {label} is required ({attempt + 1}/{MAX_ATTEMPTS})")
    if _offer_skip(label):
        return ""
    raise ValueError(f"{label} not provided after {MAX_ATTEMPTS} attempts")


def ask_optional(label):
    value = input(label + " [empty to skip]: ").strip()
    return value


def has_default_storageclass():
    jsonpath = (r'jsonpath={.items[?(@.metadata.annotations.storageclass\.kubernetes\.io'
                r'/is-default-class=="true")].metadata.name}')
    result = _kubectl_json(["get", "storageclass", "-o", jsonpath])
    return result.returncode == 0 and bool(result.stdout.strip())


def first_node():
    result = _kubectl_json(["get", "nodes", "-o", "jsonpath={.items[0].metadata.name}"])
    return result.stdout.strip() if result.returncode == 0 else ""


def leftover_local_pvs():
    found = []
    for name in ("openan-postgres-pv", "openan-rc-pv", "openan-oc-pv"):
        result = _kubectl_json(["get", "pv", name, "-o", "name"])
        if result.returncode == 0 and result.stdout.strip():
            found.append(name)
    return found


def probe_llm(model, url, api_key):
    """Best-effort connectivity probe; never includes the key in any message."""
    payload = json.dumps({"model": model, "messages": [{"role": "user", "content": "ping"}],
                          "max_tokens": 1}).encode()
    request = urllib.request.Request(url, data=payload, method="POST",
                                     headers={"Content-Type": "application/json",
                                              "Authorization": "Bearer " + api_key})
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            if response.status == 200:
                print("  [OK] LLM endpoint reachable")
                return True
            print(f"  [WARN] LLM endpoint answered HTTP {response.status}")
            return False
    except urllib.error.HTTPError as error:
        print(f"  [WARN] LLM endpoint answered HTTP {error.code} (check model id and API key)")
        return False
    except (urllib.error.URLError, OSError, TimeoutError) as error:
        print(f"  [WARN] LLM endpoint unreachable: {error}")
        return False


def models_yaml(chat, embed=None, rerank=None):
    """models.yaml for chat plus optional embed/rerank; keys referenced by
    env name, never inlined (embed drives semantic search/retrieval)."""
    def block(capability, model, url):
        return (f"  {capability}:\n"
                "    provider: openai_compatible\n"
                f"    model: {json.dumps(model)}\n"
                f"    url: {json.dumps(url)}\n"
                f"    api_key_env: LLM_{capability.upper()}_API_KEY\n")
    text = "models:\n" + block("chat", chat[0], chat[1])
    for capability, config in (("embed", embed), ("rerank", rerank)):
        if config:
            text += block(capability, config[0], config[1])
    return text


def collect_optional_model(component, capability):
    """Optional embed/rerank model: model id, URL and API key."""
    model = ask_optional(f"{component} {capability} model id")
    if not model:
        return None
    url = ask(f"{component} {capability} model URL (e.g. https://api.example.com/v1/{capability}s)")
    api_key = ask_secret(f"{component} {capability} API key")
    return model, url, api_key


def collect_llm(component):
    """Collect chat model/URL/key with validation retry loop."""
    for attempt in range(MAX_ATTEMPTS):
        model = ask(f"{component} chat model id")
        url = ask(f"{component} chat URL (e.g. https://api.example.com/v1/chat/completions)")
        api_key = ask_secret(f"{component} chat API key")
        if probe_llm(model, url, api_key):
            break
        if attempt < MAX_ATTEMPTS - 1:
            retry = input(f"  Continue anyway? [y/N]: ").strip().lower()
            if retry in ("y", "yes"):
                break
            print(f"  Retrying ({attempt + 2}/{MAX_ATTEMPTS})...")
    else:
        raise ValueError(f"LLM configuration for {component} abandoned after {MAX_ATTEMPTS} attempts")
    return {"chat": (model, url, api_key),
            "embed": collect_optional_model(component, "embed"),
            "rerank": collect_optional_model(component, "rerank")}


def choose_components():
    selection = choose("components", ["all", "registry", "orchestration"], "all")
    if selection == "all":
        return {"registry": True, "orchestration": True}
    if selection == "registry":
        return {"registry": True, "orchestration": False}
    return {"registry": False, "orchestration": True}


def generate_password(length=16):
    """Generate a random password with lower/upper/digit/special classes."""
    while True:
        pwd = secrets.token_urlsafe(length)[:length]
        if (len(pwd) >= 8
                and re.search(r"[a-z]", pwd) and re.search(r"[A-Z]", pwd)
                and re.search(r"[0-9]", pwd) and re.search(r"[^a-zA-Z0-9]", pwd)):
            return pwd


def configure(namespace, release, output, tag=None):
    if not output.parent.is_dir():
        raise ValueError("Output parent directory must already exist")
    if output.exists():
        raise ValueError("Output exists; refusing to overwrite deployment configuration")

    prefix = release + "-"

    # ------------------------------------------------------------------
    # Step 1: Components
    # ------------------------------------------------------------------
    step_banner(1, 5, "Component Selection")
    components = choose_components()
    enabled = [c for c in COMPONENTS if components[c]]
    print(f"  -> Selected: {', '.join(enabled)}")

    # ------------------------------------------------------------------
    # Step 2: Image Tags
    # ------------------------------------------------------------------
    step_banner(2, 5, "Image Tags")
    tags = {}
    if components["registry"]:
        tags["registry"] = ask("registry-center image tag", default=tag or "")
    if components["orchestration"]:
        tags["orchestration"] = ask("orchestration-center image tag", default=tag or "")
        frontend_type = choose("frontend image", ["workflow-designer", "portal"], "workflow-designer")
        if frontend_type == "portal":
            tags["frontend"] = ask("portal image tag", default=tag or "")
            print(f"  -> frontend = portal:{tags['frontend']}")
        else:
            tags["frontend"] = tags["orchestration"]
            print(f"  -> frontend = workflow-designer (follows orchestration tag: {tags['frontend']})")

    # ------------------------------------------------------------------
    # Step 3: SQL and Storage
    # ------------------------------------------------------------------
    step_banner(3, 5, "SQL & Storage")
    # One open contract (issue #36): the bundled menu follows the chart's
    # database.backends data; external SQL passes the type through verbatim
    # (PERSISTENCE_MODE) — the services must support it.
    backends = bundled_backends()
    db_bundled = True
    db_type = "postgresql"
    db_host = db_port = None
    if choose("Database", ["in-cluster", "external SQL"], "in-cluster") == "external SQL":
        db_bundled = False
        for attempt in range(MAX_ATTEMPTS):
            db_type = ask("External SQL type (postgresql|mysql|gauss|...; the services must support it)").strip().lower()
            if db_type and not re.search(r"[\sA-Z]", db_type):
                break
            print(f"  [WARN] Type must be non-empty lowercase without spaces ({attempt + 1}/{MAX_ATTEMPTS})")
        else:
            raise ValueError("External SQL type must be non-empty lowercase without spaces")
        db_host = ask("External SQL host")
        # Port default mirrors the chart: descriptor port when the type has
        # one (postgresql/mysql), explicit otherwise.
        descriptor_port = backends.get(db_type, {}).get("port", "")
        db_port_default = str(descriptor_port) if descriptor_port else ""
        for attempt in range(MAX_ATTEMPTS):
            db_port = ask("External SQL port (1..65535)", default=db_port_default)
            if db_port.isdigit() and 1 <= int(db_port) <= 65535:
                break
            print(f"  [WARN] Port must be an integer in 1..65535 ({attempt + 1}/{MAX_ATTEMPTS})")
        else:
            raise ValueError("External SQL port must be an integer in 1..65535")
        print(f"  -> external {db_type} at {db_host}:{db_port}"
              " (the databases/users must already exist on it)")
    else:
        if len(backends) > 1:
            db_type = choose("Database backend", list(backends), "postgresql")
        else:
            db_type = next(iter(backends), "postgresql")
        print(f"  -> bundled in-cluster {db_type}")
    storage_node = None
    local_storage_class = "openan-local"
    if has_default_storageclass():
        print("  Cluster has a default StorageClass; claims use it as-is")
    else:
        print("  No default StorageClass found; enabling the local hostPath fallback")
        for pv in leftover_local_pvs():
            print(f"  Warning: leftover PV '{pv}' detected. If it still holds data (e.g. stale"
                  " pgdata), in-cluster SQL users keep their OLD passwords;"
                  " remove the PV and its hostPath data first (uninstall.sh can clean it)")
        storage_node = first_node() or None
        if storage_node:
            scope = "registry, orchestration" if not db_bundled else f"{db_type}, registry, orchestration"
            print(f"  Local evaluation storage: {local_storage_class} StorageClass +"
                  f" node-pinned hostPath PVs on {storage_node}"
                  f" ({scope})")
        else:
            print("  Warning: no node name detectable; claims are left unbound."
                  " Provide a StorageClass or configure persistence in reviewed values")

    # ------------------------------------------------------------------
    # Step 4: LLM Configuration
    # ------------------------------------------------------------------
    step_banner(4, 5, "LLM Configuration")
    llm = {}
    a2at = None
    models_ref = {}

    configure_llm = choose("Configure LLM now", ["now", "skip"], "now")
    if configure_llm == "now":
        first = enabled[0]
        llm[first] = collect_llm(first)
        for other in enabled[1:]:
            reuse = choose(f"Use same LLM for {other}", ["yes", "no"], "yes")
            if reuse == "no":
                llm[other] = collect_llm(other)
            else:
                llm[other] = llm[first]
                print(f"  -> {other} reuses {first}'s LLM config")

        if components["orchestration"]:
            a2at_model = ask_optional("A2A-T SDK negotiation model (workflow execution)")
            if a2at_model:
                a2at_url = ask("A2A-T SDK base URL (e.g. https://api.example.com/v1)")
                a2at_key = ask_secret("A2A-T SDK API key")
                a2at = {"model": a2at_model, "baseUrl": a2at_url, "key": a2at_key}
    else:
        print("  LLM configuration skipped. models.yaml will use placeholder values.")
        print("  Run configure.py again or use reviewed values to configure LLM later.")

    # ------------------------------------------------------------------
    # Step 5: Signing & Secrets
    # ------------------------------------------------------------------
    step_banner(5, 5, "Signing & Secrets")

    signing_ref = None
    if components["registry"]:
        if choose("Registry signing material", ["auto", "secret"], "auto") == "secret":
            signing_ref = ask("Existing registry signing Secret (sign.cer, sign_key.pem, cert_pwd)")

    agent_registry_url = None
    if components["orchestration"] and not components["registry"]:
        for attempt in range(MAX_ATTEMPTS):
            agent_registry_url = ask("External agent registry URL for orchestration (http(s)://...)")
            if re.match(r"^https?://", agent_registry_url):
                break
            print(f"  [WARN] URL must start with http:// or https:// ({attempt + 1}/{MAX_ATTEMPTS})")
        else:
            # Issue #40: offer skip-or-abort after MAX_ATTEMPTS instead of
            # raising immediately; a skipped value leaves the default.
            if _offer_skip("agent registry URL"):
                agent_registry_url = ""
            else:
                raise ValueError("Agent registry URL must start with http:// or https://")

    # Check public references before collecting/creating any credentials.
    checks = [("configmap", name) for name in models_ref.values()]
    if signing_ref:
        checks.append(("secret", signing_ref))
    for kind, name in checks:
        result = _kubectl_json(["get", kind, name, "-n", namespace, "-o", "name"])
        if result.returncode:
            raise ValueError(f"Required model/signing reference is missing or inaccessible: {name}")

    print()
    print("  Setting up secrets (input is hidden)...")
    print()

    # Database password: the bundled backend's bootstrap credential, or the
    # external SQL credential shared by both services' Secrets.
    db_password_label = ("External SQL password (8+ characters, shared by both services)"
                         if not db_bundled else f"{db_type} password (8+ characters)")
    for attempt in range(MAX_ATTEMPTS):
        db_password = ask_secret(db_password_label)
        if len(db_password) >= 8:
            break
        print(f"  [WARN] Password must be at least 8 characters ({attempt + 1}/{MAX_ATTEMPTS})")
    else:
        # Issue #40: offer skip-or-abort after MAX_ATTEMPTS.
        if _offer_skip("Database password"):
            db_password = ""
        else:
            raise ValueError("Database password must be at least 8 characters")

    # Admin password
    admin = None
    if components["orchestration"]:
        pwd_hint = "8+ chars, lower/upper/digit/special"
        for attempt in range(MAX_ATTEMPTS):
            admin = ask_secret(f"Initial admin password ({pwd_hint})")
            if (len(admin) >= 8
                    and re.search(r"[a-z]", admin) and re.search(r"[A-Z]", admin)
                    and re.search(r"[0-9]", admin) and re.search(r"[^a-zA-Z0-9]", admin)):
                break
            print(f"  [WARN] Password does not meet requirements ({pwd_hint}) ({attempt + 1}/{MAX_ATTEMPTS})")
        else:
            # Issue #40: offer skip-or-abort after MAX_ATTEMPTS.
            if _offer_skip("admin password"):
                admin = None
            else:
                raise ValueError(f"Admin password does not meet requirements: {pwd_hint}")

    # --- Service-token machinery (registry <-> orchestration pairing) ---------
    token = hmac_key = fingerprint = credential = None
    if components["registry"]:
        token, hmac_key, fingerprint = (secrets.token_urlsafe(48) for _ in range(3))
        credential = ("credential.orchestration.identity=orchestration-service\n"
                      "credential.orchestration.role=partner_service\n"
                      "credential.orchestration.enabled=true\ncredential.orchestration.token_hash="
                      + hmac.new(hmac_key.encode(), token.encode(), hashlib.sha256).hexdigest() + "\n")

    # Namespace creation is idempotent and carries no secret material.
    ns = subprocess.run(["kubectl", "create", "namespace", namespace, "--dry-run=client", "-o", "json"],
                        capture_output=True, text=True, check=True)
    subprocess.run(["kubectl", "apply", "-f", "-"], input=ns.stdout, text=True, check=True)

    # --- Create Secrets / ConfigMaps -----------------------------------------
    if db_bundled:
        # Bundled backend credential: name and key follow the chart's
        # database.backends descriptor (openan-pg/postgres-password,
        # openan-mysql/mysql-root-password, ...).
        backend = backends.get(db_type, {})
        db_suffix = backend.get("credentialSecretSuffix") or db_type
        db_key = backend.get("passwordKey") or "password"
        create_secret(namespace, prefix + db_suffix, {db_key: db_password})
    else:
        # Per-service external SQL credentials (chart contract:
        # database.<service>.existingSecret, key db-password).
        if components["registry"]:
            create_secret(namespace, prefix + "rc-db", {"db-password": db_password})
        if components["orchestration"]:
            create_secret(namespace, prefix + "oc-db", {"db-password": db_password})

    if configure_llm == "now":
        for component in enabled:
            name = prefix + ("rc-models" if component == "registry" else "oc-models")
            create_configmap(namespace, name,
                             {"models.yaml": models_yaml(llm[component]["chat"],
                                                         llm[component]["embed"],
                                                         llm[component]["rerank"])})
            models_ref[component] = name

    rc_runtime = {"INTEGRATION_TOKEN_HMAC_KEY": hmac_key, "INTEGRATION_FINGERPRINT_KEY": fingerprint} \
        if components["registry"] else None
    if rc_runtime is not None and configure_llm == "now" and components["registry"]:
        rc_runtime["LLM_CHAT_API_KEY"] = llm["registry"]["chat"][2]
        for capability in ("embed", "rerank"):
            if llm["registry"][capability]:
                rc_runtime[f"LLM_{capability.upper()}_API_KEY"] = llm["registry"][capability][2]
    oc_runtime = {}
    if admin is not None:
        oc_runtime["OC_ADMIN_INITIAL_PASSWORD"] = admin
        if components["registry"]:
            oc_runtime["REGISTRY_ACCESS_TOKEN"] = token
        if configure_llm == "now" and components["orchestration"]:
            oc_runtime["LLM_CHAT_API_KEY"] = llm["orchestration"]["chat"][2]
            for capability in ("embed", "rerank"):
                if llm["orchestration"][capability]:
                    oc_runtime[f"LLM_{capability.upper()}_API_KEY"] = llm["orchestration"][capability][2]
    if a2at:
        oc_runtime["A2AT_LLM_API_KEY"] = a2at["key"]
    if rc_runtime is not None:
        create_secret(namespace, prefix + "rc-runtime", rc_runtime)
        create_secret(namespace, prefix + "rc-credentials", {"integration_credentials.conf": credential})
    if oc_runtime:
        create_secret(namespace, prefix + "oc-runtime", oc_runtime)

    # --- HTTPS (optional, self-signed) ---------------------------------------
    https_enabled = choose("Enable HTTPS with self-signed certificates", ["yes", "no"], "yes")
    https_config = {}
    if https_enabled == "yes":
        # Generate self-signed certificates with the standalone gen_certs.py
        # tool (cryptography library only; no source-tree dependency). The
        # tool lives in the repo-root tool/ directory (moved there from the
        # per-line tool/ copies); resolve it relative to this file:
        # containerized/online-install/ -> parents[2] is the repo root.
        cert_dir = output.parent / "certs"
        cert_dir.mkdir(exist_ok=True)
        script_dir = Path(__file__).resolve().parents[2]
        gen_script = script_dir / "tool" / "gen_certs.py"
        if not gen_script.is_file():
            raise ValueError(f"gen_certs.py not found at {gen_script}")
        gen_cmd = [
            sys.executable, str(gen_script),
            "--out", str(cert_dir),
            "--namespace", namespace,
        ]
        # Discover the LoadBalancer IP for the ingress SAN, if already assigned.
        lb_ip = subprocess.run(
            ["kubectl", "get", "svc", "-n", "ingress-nginx", "ingress-nginx-controller",
             "-o", "jsonpath={.status.loadBalancer.ingress[0].ip}"],
            capture_output=True, text=True)
        if lb_ip.returncode == 0 and lb_ip.stdout.strip():
            gen_cmd += ["--ingress-ip", lb_ip.stdout.strip()]
        result = subprocess.run(gen_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"Certificate generation failed: {result.stderr.strip()}")
        print(f"  Certificates generated in {cert_dir}")

        # Create TLS Secrets for each component.
        create_secret(namespace, prefix + "rc-tls", {
            "server.cer": (cert_dir / "registry-center" / "server.cer").read_text(),
            "server_key.pem": (cert_dir / "registry-center" / "server_key.pem").read_text(),
            "cert_pwd": (cert_dir / "registry-center" / "cert_pwd").read_text(),
            "trust.cer": (cert_dir / "registry-center" / "trust.cer").read_text(),
        })
        create_secret(namespace, prefix + "oc-tls", {
            "server.cer": (cert_dir / "orchestration-center" / "server.cer").read_text(),
            "server_key.pem": (cert_dir / "orchestration-center" / "server_key.pem").read_text(),
            "cert_pwd": (cert_dir / "orchestration-center" / "cert_pwd").read_text(),
            "trust.cer": (cert_dir / "orchestration-center" / "trust.cer").read_text(),
        })
        create_secret(namespace, prefix + "ingress-client", {
            "tls.crt": (cert_dir / "ingress-client" / "tls.crt").read_text(),
            "tls.key": (cert_dir / "ingress-client" / "tls.key").read_text(),
            "ca.crt": (cert_dir / "ca" / "ca.cer").read_text(),
        })
        create_secret(namespace, prefix + "registry-client", {
            "trust.cer": (cert_dir / "ca" / "ca.cer").read_text(),
            "client.cer": (cert_dir / "ingress-client" / "tls.crt").read_text(),
            "client_key.pem": (cert_dir / "ingress-client" / "tls.key").read_text(),
        })
        create_secret(namespace, prefix + "public-tls", {
            "tls.crt": (cert_dir / "ingress" / "tls.crt").read_text(),
            "tls.key": (cert_dir / "ingress" / "tls.key").read_text(),
        })
        https_config = {
            "tls": {"enabled": True, "verifyClient": False},
            "backendTls": {"verifyServer": True, "existingSecret": prefix + "ingress-client"},
        }

    # --- Assemble non-secret values -------------------------------------------
    frontend_values = {"image": {"tag": tags["frontend"]}}
    if components["orchestration"]:
        frontend_values["type"] = frontend_type or "workflow-designer"
    if https_enabled == "yes":
        frontend_values.update(https_config.get("backendTls", {}))
    database_values = {"bundled": db_bundled, "type": db_type}
    if db_bundled:
        database_values["existingSecret"] = prefix + (backends.get(db_type, {}).get("credentialSecretSuffix") or db_type)
    else:
        database_values.update({"host": db_host, "port": int(db_port)})
        if components["registry"]:
            database_values["registry"] = {"existingSecret": prefix + "rc-db"}
        if components["orchestration"]:
            database_values["orchestration"] = {"existingSecret": prefix + "oc-db"}
    values = {"namespace": namespace, "frontend": frontend_values,
              "database": database_values}
    if storage_node is not None:
        storage_block = {"createStorageClass": True, "storageClassName": local_storage_class}
        if db_bundled:
            storage_block.update({"createPV": True, "useHostPath": True, "nodeName": storage_node})
        values["database"]["storage"] = storage_block
    if components["registry"]:
        values["registry"] = {"runtimeSecret": prefix + "rc-runtime",
                              "credentialSecret": prefix + "rc-credentials",
                              "modelsConfigMap": models_ref.get("registry", ""), "image": {"tag": tags["registry"]}}
        if https_enabled == "yes":
            values["registry"]["tls"] = {"enabled": True, "verifyClient": False,
                                          "mode": "secret", "existingSecret": prefix + "rc-tls"}
            values["registry"]["ingressClientSecret"] = prefix + "ingress-client"
        if signing_ref:
            values["registry"]["signing"] = {"mode": "secret", "existingSecret": signing_ref}
        else:
            values["registry"]["signing"] = {"mode": "auto"}
        if storage_node is not None:
            values["registry"]["persistence"] = {
                "storageClassName": local_storage_class, "createPV": True,
                "useHostPath": True, "nodeName": storage_node}
    else:
        values["registry"] = {"enabled": False}
    if components["orchestration"]:
        values["orchestration"] = {"runtimeSecret": prefix + "oc-runtime",
                                   "modelsConfigMap": models_ref.get("orchestration", ""),
                                   "image": {"tag": tags["orchestration"]}}
        if https_enabled == "yes":
            values["orchestration"]["tls"] = {"enabled": True, "verifyClient": False,
                                               "mode": "secret", "existingSecret": prefix + "oc-tls"}
            values["orchestration"]["ingressClientSecret"] = prefix + "ingress-client"
            values["orchestration"]["clientVerifyServer"] = True
            values["orchestration"]["registryClientSecret"] = prefix + "registry-client"
        if agent_registry_url:
            values["orchestration"]["agentRegistryUrl"] = agent_registry_url
        if a2at:
            values["orchestration"]["a2atLlm"] = {"provider": "openai",
                                                  "model": a2at["model"],
                                                  "baseUrl": a2at["baseUrl"]}
        if storage_node is not None:
            values["orchestration"]["persistence"] = {
                "storageClassName": local_storage_class, "createPV": True,
                "useHostPath": True, "nodeName": storage_node}
    else:
        values["orchestration"] = {"enabled": False}
        values["frontend"] = {"enabled": False, "image": {"tag": tags["frontend"]}}
    values["ingress"] = {"host": ""}
    if https_enabled == "yes":
        values["ingress"]["tls"] = {"enabled": True, "secretName": prefix + "public-tls"}

    # Only non-secret JSON/YAML-compatible values. Exclusive creation preserves operator files.
    with output.open("x", encoding="utf-8") as stream:
        json.dump(values, stream, indent=2)
    print("Non-secret values created. Secrets are stored only in Kubernetes. Use reviewed HTTPS values for production.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tag", help="Default image tag for components that don't specify one")
    args = parser.parse_args()
    for name in (args.namespace, args.release):
        if not re.fullmatch(r"[a-z0-9](?:[-a-z0-9]*[a-z0-9])?", name) or len(name) > 53:
            parser.error("Invalid namespace/release")
    try:
        configure(args.namespace, args.release, args.output, tag=args.tag)
    except (ValueError, RuntimeError, OSError, EOFError, subprocess.SubprocessError) as error:
        # Concrete reason, never the value: every raise site is audited to
        # exclude secrets (and kubectl stderr, which can echo submitted objects).
        parser.exit(2, f"Configuration failed: {error}\n"
                      "Secret values are never echoed; existing Secrets are not overwritten.\n")
