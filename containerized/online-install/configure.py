#!/usr/bin/env python3
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Guided evaluation configuration; secrets only in memory and kubectl stdin.

Interactive wizard: components -> image tags -> LLM -> signing -> secrets.
Everything else is automatic evaluation mode: in-cluster PostgreSQL, storage
on the cluster's default StorageClass (automatic node-pinned local hostPath
fallback when none exists), auto signing, generated models.yaml, and the
empty catch-all Ingress host for direct LB-IP access.

Production profiles (external SQL, HTTPS, host-based routing) use reviewed
values (see example.values.yaml) and existing Secrets instead. No defaults
for passwords, no credential arguments, no Secret overwrite.
"""
import argparse
import base64
import getpass
import hashlib
import hmac
import json
import os
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


def create_secret(namespace, name, values):
    result = _kubectl_json(["get", "secret", name, "-n", namespace, "--ignore-not-found", "-o", "name"])
    if result.returncode:
        raise RuntimeError(f"Could not check Secret '{name}' in namespace '{namespace}'; verify kubeconfig and RBAC")
    if result.stdout.strip():
        raise RuntimeError(f"Secret '{name}' already exists; use reviewed values for upgrades instead of overwriting")
    document = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                "metadata": {"namespace": namespace, "name": name},
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
        raise RuntimeError(f"ConfigMap '{name}' already exists; use existing references for upgrades")
    document = {"apiVersion": "v1", "kind": "ConfigMap",
                "metadata": {"namespace": namespace, "name": name},
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
    api_key = secret_input(f"{component} {capability} API key")
    return model, url, api_key


def collect_llm(component):
    """Collect chat model/URL/key with validation retry loop."""
    for attempt in range(MAX_ATTEMPTS):
        model = ask(f"{component} chat model id")
        url = ask(f"{component} chat URL (e.g. https://api.example.com/v1/chat/completions)")
        api_key = secret_input(f"{component} chat API key")
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
    # Step 3: SQL and Storage (automatic)
    # ------------------------------------------------------------------
    step_banner(3, 5, "SQL & Storage (automatic)")
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
            print(f"  Local evaluation storage: {local_storage_class} StorageClass +"
                  f" node-pinned hostPath PVs on {storage_node}"
                  " (postgres, registry, orchestration)")
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
                a2at_key = secret_input("A2A-T SDK API key")
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

    # PostgreSQL password
    for attempt in range(MAX_ATTEMPTS):
        in_cluster_password = secret_input("PostgreSQL password (8+ characters)")
        if len(in_cluster_password) >= 8:
            break
        print(f"  [WARN] Password must be at least 8 characters ({attempt + 1}/{MAX_ATTEMPTS})")
    else:
        raise ValueError("PostgreSQL password must be at least 8 characters")

    # Admin password
    admin = None
    if components["orchestration"]:
        pwd_hint = "8+ chars, lower/upper/digit/special"
        for attempt in range(MAX_ATTEMPTS):
            admin = secret_input(f"Initial admin password ({pwd_hint})")
            if (len(admin) >= 8
                    and re.search(r"[a-z]", admin) and re.search(r"[A-Z]", admin)
                    and re.search(r"[0-9]", admin) and re.search(r"[^a-zA-Z0-9]", admin)):
                break
            print(f"  [WARN] Password does not meet requirements ({pwd_hint}) ({attempt + 1}/{MAX_ATTEMPTS})")
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
    create_secret(namespace, prefix + "pg", {"postgres-password": in_cluster_password})

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
    https_enabled = choose("Enable HTTPS with self-signed certificates", ["yes", "no"], "no")
    https_config = {}
    if https_enabled == "yes":
        # Generate self-signed certificates using the bundled gen_certs.py tool.
        # The tool requires the registry-center source tree (CertificateGenerator).
        cert_dir = output.parent / "certs"
        cert_dir.mkdir(exist_ok=True)
        script_dir = Path(__file__).resolve().parent
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
        rc_src = os.environ.get("OPENAN_REGISTRY_CENTER_SRC", "")
        if rc_src:
            gen_cmd += ["--registry-center-src", rc_src]
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
    values = {"namespace": namespace, "frontend": frontend_values,
              "postgresql": {"enabled": True, "existingSecret": prefix + "pg"},
              "database": {"type": "postgresql"}}
    if storage_node is not None:
        values["postgresql"]["storage"] = {"createStorageClass": True,
                                           "storageClassName": local_storage_class,
                                           "createPV": True, "useHostPath": True,
                                           "nodeName": storage_node}
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
