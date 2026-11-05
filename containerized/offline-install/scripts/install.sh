#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# OpenAN offline installer (Kubernetes).
#
# Assumes a Kubernetes cluster (kubeadm, v1.33+) is already running and that
# this script is executed on a node with kubectl access and a working containerd
# (root). It never uses the internet and never edits the OS or container runtime
# configuration.
#
#   scripts/install.sh                       # interactive
#   scripts/install.sh --config config.env   # non-interactive
#   scripts/install.sh --config config.env --yes --skip-check

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE=""
SKIP_CHECK="false"
ASSUME_YES="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --config)     [ $# -ge 2 ] || { log_error "--config requires a file argument"; exit 2; }
                      CONFIG_FILE="$2"; shift 2 ;;
        --yes|-y)     ASSUME_YES="true"; shift ;;
        --skip-check) SKIP_CHECK="true"; shift ;;
        -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done
export ASSUME_YES

# --- Defaults (mirrors config.env.example) -----------------------------------
K8S_NAMESPACE="openan"
INSTALL_REGISTRY="true"
REGISTRY_NODE=""
REGISTRY_NODE_IP=""
REGISTRY_NODEPORT="30500"
INSTALL_METALLB="true"
METALLB_POOL=""
INGRESS_HOST=""
HTTPS_ENABLED="true"
HTTPS_VERIFY_CLIENT="false"
# TLS secrets: empty = generate self-signed certificates at install time
# (tool/gen_certs.py) into openan-rc-tls / openan-oc-tls /
# openan-ingress-client (+ openan-public-tls when INGRESS_HOST is set).
# Set all three names to use operator-provided Secrets instead.
RC_TLS_SECRET=""
OC_TLS_SECRET=""
INGRESS_CLIENT_SECRET=""
# Optional OC->RC client material (trust.cer + client.cer/client_key.pem for
# mTLS); empty in generate mode = auto-created as openan-registry-client.
REGISTRY_CLIENT_SECRET=""
PUBLIC_TLS_SECRET=""
STORAGE_MODE="auto"
STORAGE_CLASS=""
STORAGE_SIZE="20Gi"
HOSTPATH="/data/openan-postgres"
STORAGE_NODE=""
DB_TYPE="mysql"
# Required: no default password. 8+ characters (the database init script
# seeds the application users with this value).
DB_PASSWORD=""
REGISTRY_CENTER_IMAGE="project-openan/registry-center:v1.0.0"
ORCHESTRATION_CENTER_IMAGE="project-openan/orchestration-center:v1.0.0"
WORKFLOW_DESIGNER_IMAGE="project-openan/workflow-designer:v1.0.0"
FRONTEND_TYPE="portal"
PORTAL_IMAGE="project-openan/openan-portal:v1.0.0"
OC_ADMIN_PASSWORD=""
POSTGRES_IMAGE="library/postgres:15-alpine"
MYSQL_IMAGE="library/mysql:8.4.3"
REGISTRY_CHAT_MODEL=""
REGISTRY_CHAT_URL=""
REGISTRY_CHAT_APIKEY=""
ORCH_CHAT_MODEL=""
ORCH_CHAT_URL=""
ORCH_CHAT_APIKEY=""
LLM_VALIDATE="false"
REGISTRY_SIGNATURE_VALIDATION_ENABLED="false"
START_AGENTS_SERVER="false"

if [ -n "$CONFIG_FILE" ]; then
    [ -r "$CONFIG_FILE" ] || { log_error "Config file not readable: $CONFIG_FILE"; exit 2; }
    load_config "$CONFIG_FILE"
fi

# --- Normalize booleans (config values are free-text strings) -----------------
normalize_bool() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        true|yes|1)  echo "true" ;;
        false|no|0|"") echo "false" ;;
        *) return 1 ;;
    esac
}
for _bool_var in INSTALL_REGISTRY INSTALL_METALLB HTTPS_ENABLED HTTPS_VERIFY_CLIENT \
                 LLM_VALIDATE REGISTRY_SIGNATURE_VALIDATION_ENABLED START_AGENTS_SERVER; do
    _bool_val="$(normalize_bool "${!_bool_var}")" || {
        log_error "${_bool_var} must be true or false (got: ${!_bool_var})"
        exit 2
    }
    printf -v "$_bool_var" '%s' "$_bool_val"
done

# INGRESS_HOST may be a DNS name or a bare IP address: an IP enables
# https://<IP> public access directly (MetalLB VIP or node IP), with the
# matching IP SAN in the generated public certificate.

case "$DB_TYPE" in
    postgresql|mysql) ;;
    *) log_error "Invalid DB_TYPE: $DB_TYPE (use postgresql|mysql)"; exit 2 ;;
esac

ARCH="$(detect_arch || true)"
[ -n "$ARCH" ] || { log_error "unsupported architecture: $(uname -m)"; exit 1; }

# --- Tool resolution (prefer bundled binaries) -------------------------------
resolve_tool() {
    local name="$1"
    local bundled="$BUNDLE_DIR/deps/bin/${name}-linux-${ARCH}"
    if [ -x "$bundled" ]; then echo "$bundled"; return; fi
    if have "$name"; then echo "$name"; return; fi
    echo ""
}

KUBECTL="$(resolve_tool kubectl)"
HELM="$(resolve_tool helm)"
CRANE=""
[ -x "$BUNDLE_DIR/deps/bin/crane-linux-$ARCH" ] && CRANE="$BUNDLE_DIR/deps/bin/crane-linux-$ARCH"

if [ -z "$KUBECTL" ]; then log_error "kubectl not found (bundled or PATH)"; exit 1; fi
if [ -z "$HELM" ]; then log_error "helm not found (bundled or PATH)"; exit 1; fi
log_info "kubectl: $KUBECTL"
log_info "helm:    $HELM"

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------
if [ "$ASSUME_YES" != "true" ] && [ -z "$CONFIG_FILE" ]; then
    log_step "[1/7] Configuration"
    prompt_bool() {  # <current-value> <prompt> -> prints true/false
        if ask_yes_no "$2" "$([ "$1" = "true" ] && echo yes || echo no)"; then
            echo "true"
        else
            echo "false"
        fi
    }
    K8S_NAMESPACE="$(ask_input "  Kubernetes namespace" "$K8S_NAMESPACE")"
    INSTALL_METALLB="$(prompt_bool "$INSTALL_METALLB" "  Install MetalLB for LoadBalancer?")"
    if [ "$INSTALL_METALLB" = "true" ]; then
        METALLB_POOL="$(ask_input "  MetalLB IP pool (e.g. 192.168.1.200-192.168.1.250)" "$METALLB_POOL")"
    fi
    INGRESS_HOST="$(ask_input "  Ingress host (empty = access by IP)" "$INGRESS_HOST")"
    if ask_yes_no "  Enable HTTPS for in-cluster services" "yes"; then
        HTTPS_ENABLED="true"
        if ask_yes_no "  Generate self-signed certificates now (openssl, stored in Secrets)" "yes"; then
            : # generate mode: secrets are created during deploy
        else
            RC_TLS_SECRET="$(ask_input "  Registry TLS Secret name" "$RC_TLS_SECRET")"
            OC_TLS_SECRET="$(ask_input "  Orchestration TLS Secret name" "$OC_TLS_SECRET")"
            INGRESS_CLIENT_SECRET="$(ask_input "  Ingress client/CA Secret name (tls.crt, tls.key, ca.crt)" "$INGRESS_CLIENT_SECRET")"
            PUBLIC_TLS_SECRET="$(ask_input "  Public ingress TLS Secret name (empty = plain HTTP entry)" "$PUBLIC_TLS_SECRET")"
        fi
        if ask_yes_no "  Require client certificates (mTLS) on the registry listener" "no"; then
            HTTPS_VERIFY_CLIENT="true"
        fi
    else
        HTTPS_ENABLED="false"
    fi
    DB_TYPE="$(ask_choice "  Database backend:" "mysql" "postgresql")"
    DB_PASSWORD="$(ask_input_secret "  Database password (8+ characters)" "")"
    REGISTRY_CHAT_MODEL="$(ask_input "  Registry Center chat model" "$REGISTRY_CHAT_MODEL")"
    REGISTRY_CHAT_URL="$(ask_input "  Registry Center chat URL" "$REGISTRY_CHAT_URL")"
    if [ -n "$REGISTRY_CHAT_URL" ]; then
        REGISTRY_CHAT_APIKEY="$(ask_input_secret "  Registry Center API key" "")"
    fi
    ORCH_CHAT_MODEL="$(ask_input "  Orchestration Center chat model" "$ORCH_CHAT_MODEL")"
    ORCH_CHAT_URL="$(ask_input "  Orchestration Center chat URL" "$ORCH_CHAT_URL")"
    if [ -n "$ORCH_CHAT_URL" ]; then
        ORCH_CHAT_APIKEY="$(ask_input_secret "  Orchestration Center API key" "")"
    fi
    LLM_VALIDATE="$(prompt_bool "$LLM_VALIDATE" "  Validate LLM connectivity now?")"
    FRONTEND_TYPE="$(ask_choice "  Frontend:" "portal" "workflow-designer")"
    OC_ADMIN_PASSWORD="$(ask_input_secret "  OC admin password (portal login)" "$OC_ADMIN_PASSWORD")"
    START_AGENTS_SERVER="$(prompt_bool "$START_AGENTS_SERVER" "  Start the sample agents server in orchestration-center?")"
fi

if [ -z "$OC_ADMIN_PASSWORD" ]; then
    log_error "OC_ADMIN_PASSWORD is required: OC seeds its 'admin' account (portal login) from it and refuses to start over HTTP without a credential."
    log_error "Set OC_ADMIN_PASSWORD in config.env (or answer the interactive prompt) and re-run."
    exit 2
fi

# --- Validation (after prompts: interactive answers override config.env) -----
if [ -z "$DB_PASSWORD" ]; then
    log_error "DB_PASSWORD is required (config.env or the interactive prompt); there is no default."
    exit 2
fi
if [ "${#DB_PASSWORD}" -lt 8 ]; then
    log_error "DB_PASSWORD must be at least 8 characters"
    exit 2
fi
if ! printf '%s' "$K8S_NAMESPACE" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' || [ "${#K8S_NAMESPACE}" -gt 63 ]; then
    log_error "K8S_NAMESPACE must be a lowercase DNS label (a-z, 0-9, '-'), max 63 characters"
    exit 2
fi
if [ "$INSTALL_METALLB" = "true" ] && [ -n "$METALLB_POOL" ]; then
    pool_ok="true"
    IFS=','
    for token in $METALLB_POOL; do
        printf '%s' "$token" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}(-[0-9]{1,3}(\.[0-9]{1,3}){3}|/[0-9]{1,2})?$' || pool_ok="false"
    done
    unset IFS
    [ "$pool_ok" = "true" ] || {
        log_error "METALLB_POOL must be IP ranges (a.b.c.d-a.b.c.d) and/or CIDRs (a.b.c.d/n), comma-separated"
        exit 2
    }
fi

if [ -z "$REGISTRY_NODE" ]; then
    REGISTRY_NODE="$(hostname | tr '[:upper:]' '[:lower:]')"
fi
if [ -z "$REGISTRY_NODE_IP" ]; then
    REGISTRY_NODE_IP="$(default_ip || true)"
fi
if [ -z "$STORAGE_NODE" ]; then
    STORAGE_NODE="$REGISTRY_NODE"
fi
REG_HOST="${REGISTRY_NODE_IP}:${REGISTRY_NODEPORT}"

# ---------------------------------------------------------------------------
# 2. Environment check
# ---------------------------------------------------------------------------
if [ "$SKIP_CHECK" != "true" ]; then
    log_step "[2/7] Checking environment"
    # Export the effective configuration so check-env.sh sees it even in
    # interactive mode (no --config file).
    export K8S_NAMESPACE INSTALL_REGISTRY REGISTRY_NODE REGISTRY_NODE_IP \
        REGISTRY_NODEPORT INSTALL_METALLB METALLB_POOL INGRESS_HOST \
        HTTPS_ENABLED HTTPS_VERIFY_CLIENT \
        RC_TLS_SECRET OC_TLS_SECRET INGRESS_CLIENT_SECRET REGISTRY_CLIENT_SECRET \
        STORAGE_MODE STORAGE_CLASS STORAGE_SIZE HOSTPATH STORAGE_NODE \
        DB_TYPE FRONTEND_TYPE OC_ADMIN_PASSWORD REGISTRY_CHAT_URL LLM_VALIDATE
    check_args=()
    [ -n "$CONFIG_FILE" ] && check_args+=(--config "$CONFIG_FILE")
    if ! "$SCRIPT_DIR/check-env.sh" "${check_args[@]}"; then
        log_error "Environment check failed. Fix the items above and re-run,"
        log_error "or pass --skip-check to proceed at your own risk."
        exit 1
    fi
else
    log_warn "Skipping environment check (--skip-check)"
fi

# --- REGISTRY_NODE must match an actual Kubernetes node name ------------------
# The in-cluster registry and hostPath storage pin to this node; a hostname
# that differs from the node name (case, FQDN) leaves them unschedulable.
if node_list="$("$KUBECTL" get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"; then
    if ! printf '%s\n' "$node_list" | tr ' ' '\n' | grep -qx "$REGISTRY_NODE"; then
        log_error "REGISTRY_NODE '$REGISTRY_NODE' is not a Kubernetes node name (hostname case mismatch?)."
        log_error "Available nodes: $node_list"
        exit 1
    fi
else
    log_warn "Cannot list nodes to validate REGISTRY_NODE ('$REGISTRY_NODE')"
fi

# ---------------------------------------------------------------------------
# 3. Summary + confirm
# ---------------------------------------------------------------------------
REF_REPO() { echo "${1%:*}"; }
REF_TAG()  { echo "${1##*:}"; }

echo ""
echo "=========================================="
echo "  Offline installation summary"
echo "=========================================="
echo "  Architecture:     $ARCH"
echo "  Namespace:        $K8S_NAMESPACE"
echo "  Registry:         $REG_HOST (node: $REGISTRY_NODE)"
echo "  MetalLB:          $INSTALL_METALLB ${METALLB_POOL:+($METALLB_POOL)}"
echo "  Storage mode:     $STORAGE_MODE (node: $STORAGE_NODE, size: $STORAGE_SIZE)"
echo "  Database:         $DB_TYPE"
echo "  Frontend:         $FRONTEND_TYPE"
echo "  Ingress host:     ${INGRESS_HOST:-<none, IP access>}"
echo "  HTTPS (services): $HTTPS_ENABLED (verifyClient: $HTTPS_VERIFY_CLIENT)"
if [ "$HTTPS_ENABLED" = "true" ]; then
    if [ -n "$RC_TLS_SECRET" ] || [ -n "$OC_TLS_SECRET" ] || [ -n "$INGRESS_CLIENT_SECRET" ]; then
        echo "  TLS:              existing Secrets ($RC_TLS_SECRET / $OC_TLS_SECRET); ingress verifies backends"
    else
        echo "  TLS:              self-signed via tool/gen_certs.py; ingress verifies backends"
    fi
fi
echo "  Registry center:  $REGISTRY_CENTER_IMAGE"
echo "  Orchestration:    $ORCHESTRATION_CENTER_IMAGE"
if [ "$FRONTEND_TYPE" = "portal" ]; then
    echo "  Frontend image:   $PORTAL_IMAGE"
else
    echo "  Frontend image:   $WORKFLOW_DESIGNER_IMAGE"
fi
echo "  Sample agents:    $START_AGENTS_SERVER"
echo "=========================================="
echo ""

if ! ask_yes_no "Proceed with deployment?" "yes"; then
    log_info "Cancelled."
    exit 0
fi

# Persist the effective configuration for repeatability.
save_config "$BUNDLE_DIR/config.env"

# ---------------------------------------------------------------------------
# 4. Private registry (in-cluster)
# ---------------------------------------------------------------------------
log_step "[4/7] Private registry"

if [ "$INSTALL_REGISTRY" != "true" ]; then
    log_warn "INSTALL_REGISTRY=false — assuming an external registry at $REG_HOST"
else

    # Bootstrap: the registry image must exist locally before the registry exists.
    registry_tar="$BUNDLE_DIR/images/registry-2-${ARCH}.tar"
    if [ ! -r "$registry_tar" ]; then
        log_error "Missing $registry_tar (needed to bootstrap the registry)"
        exit 1
    fi
    if ctr -n k8s.io images ls -q 2>/dev/null | grep -q "docker.io/library/registry:2"; then
        log_info "registry:2 already present in containerd, skipping import"
    else
        log_info "Importing registry:2 into containerd..."
        ctr -n k8s.io images import "$registry_tar" >/dev/null || {
            log_error "Failed to import registry:2. Are you root?"
            exit 1
        }
    fi

    "$KUBECTL" get namespace "$K8S_NAMESPACE" >/dev/null 2>&1 || \
        "$KUBECTL" create namespace "$K8S_NAMESPACE"

    "$KUBECTL" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openan-registry
  namespace: ${K8S_NAMESPACE}
  labels:
    app: openan-registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openan-registry
  template:
    metadata:
      labels:
        app: openan-registry
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${REGISTRY_NODE}
      containers:
      - name: registry
        image: docker.io/library/registry:2
        imagePullPolicy: Never
        env:
        - name: REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY
          value: /var/lib/registry
        - name: REGISTRY_HTTP_ADDR
          value: 0.0.0.0:5000
        ports:
        - containerPort: 5000
        volumeMounts:
        - name: data
          mountPath: /var/lib/registry
        readinessProbe:
          httpGet:
            path: /v2/
            port: 5000
          initialDelaySeconds: 3
          periodSeconds: 5
      volumes:
      - name: data
        hostPath:
          path: /data/openan-registry
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: openan-registry
  namespace: ${K8S_NAMESPACE}
spec:
  type: NodePort
  selector:
    app: openan-registry
  ports:
  - name: registry
    port: 5000
    targetPort: 5000
    nodePort: ${REGISTRY_NODEPORT}
    protocol: TCP
EOF

    log_info "Waiting for the registry to become ready..."
    ok="false"
    for _ in $(seq 1 30); do
        if curl -sf -m 3 "http://${REG_HOST}/v2/" >/dev/null 2>&1; then ok="true"; break; fi
        sleep 4
    done
    if [ "$ok" != "true" ]; then
        log_error "Registry did not come up at http://${REG_HOST}/v2/"
        "$KUBECTL" -n "$K8S_NAMESPACE" get pods -l app=openan-registry
        exit 1
    fi
    log_info "Registry is up at ${REG_HOST}"
fi

# ---------------------------------------------------------------------------
# 5. Push images + install cluster add-ons
# ---------------------------------------------------------------------------
log_step "[5/7] Pushing images and installing add-ons"

if [ -z "$CRANE" ] && ! have crane; then
    log_error "crane not found — cannot push images (expected deps/bin/crane-linux-$ARCH)"
    log_error "Install: https://github.com/google/go-containerregistry/releases (go-containerregistry_Linux_*.tar.gz)"
    exit 1
fi
"$SCRIPT_DIR/push-images.sh" --config "$BUNDLE_DIR/config.env" || {
    log_error "Image push failed"
    exit 1
}

# --- MetalLB ----------------------------------------------------------------
if [ "$INSTALL_METALLB" = "true" ]; then
    if "$KUBECTL" get namespace metallb-system >/dev/null 2>&1; then
        log_info "MetalLB already installed, skipping"
    else
        log_info "Installing MetalLB offline..."
        sed -e "s|quay.io/metallb/|${REG_HOST}/metallb/|g" \
            -e "s|@sha256:[a-f0-9]*||g" \
            "$BUNDLE_DIR/deps/manifests/metallb-native.yaml" >/tmp/openan-metallb.yaml
        "$KUBECTL" apply -f /tmp/openan-metallb.yaml >/dev/null || { log_error "MetalLB apply failed"; exit 1; }
        "$KUBECTL" -n metallb-system rollout status deploy/metallb-controller --timeout=180s || true
        for _ in $(seq 1 24); do
            "$KUBECTL" get crd ipaddresspools.metallb.io >/dev/null 2>&1 && break || true
            sleep 5
        done
    fi
    if [ -z "$METALLB_POOL" ]; then
        log_error "METALLB_POOL is empty — cannot configure the LoadBalancer pool"
        exit 1
    fi
    log_info "Configuring MetalLB pool $METALLB_POOL"
    "$KUBECTL" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: openan-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_POOL}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: openan-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - openan-pool
EOF
fi

# --- ingress-nginx ----------------------------------------------------------
if "$KUBECTL" get ns ingress-nginx >/dev/null 2>&1; then
    log_info "ingress-nginx already installed, skipping"
else
    log_info "Installing ingress-nginx offline..."
    sed -e "s|registry.k8s.io/ingress-nginx/|${REG_HOST}/ingress-nginx/|g" \
        -e "s|@sha256:[a-f0-9]*||g" \
        "$BUNDLE_DIR/deps/manifests/ingress-nginx.yaml" >/tmp/openan-ingress.yaml
    "$KUBECTL" apply -f /tmp/openan-ingress.yaml >/dev/null || { log_error "ingress-nginx apply failed"; exit 1; }
    "$KUBECTL" -n ingress-nginx wait --for=condition=ready pod \
        -l app.kubernetes.io/component=controller --timeout=300s || true
fi

# --- LoadBalancer IP --------------------------------------------------------
INGRESS_IP=""
if "$KUBECTL" get svc -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
    svc_type="$("$KUBECTL" get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.type}' 2>/dev/null)"
    if [ "$svc_type" != "LoadBalancer" ] && [ "$INSTALL_METALLB" = "true" ]; then
        log_info "Switching ingress-nginx Service to LoadBalancer"
        "$KUBECTL" patch svc -n ingress-nginx ingress-nginx-controller -p '{"spec":{"type":"LoadBalancer"}}'
    fi
    if [ "$INSTALL_METALLB" = "true" ] || [ "$svc_type" = "LoadBalancer" ]; then
        log_info "Waiting for a LoadBalancer IP..."
        for _ in $(seq 1 36); do
            INGRESS_IP="$("$KUBECTL" get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
            [ -n "$INGRESS_IP" ] && break || true
            sleep 5
        done
    fi
fi
[ -n "$INGRESS_IP" ] && log_info "Ingress LoadBalancer IP: $INGRESS_IP" || log_warn "No LoadBalancer IP assigned (will fall back to NodePort access)"

# ---------------------------------------------------------------------------
# 6. Deploy OpenAN with Helm
# ---------------------------------------------------------------------------
log_step "[6/7] Deploying OpenAN"

# --- TLS certificates (HTTPS default) ----------------------------------------
# generate: tool/gen_certs.py (openssl) + installer-created Secrets
# existing: operator-provided Secrets (all three names required)
create_secret_from_files() {
    local name="$1"; shift
    if "$KUBECTL" -n "$K8S_NAMESPACE" get secret "$name" >/dev/null 2>&1; then
        log_info "TLS Secret $name already exists, reusing"
        return 0
    fi
    local args=() pair
    for pair in "$@"; do args+=(--from-file="$pair"); done
    "$KUBECTL" -n "$K8S_NAMESPACE" create secret generic "$name" "${args[@]}" \
        && "$KUBECTL" -n "$K8S_NAMESPACE" label secret "$name" openan-offline-installer=true >/dev/null
}

if [ "$HTTPS_ENABLED" = "true" ]; then
    if [ -n "$RC_TLS_SECRET" ] || [ -n "$OC_TLS_SECRET" ] || [ -n "$INGRESS_CLIENT_SECRET" ]; then
        if [ -z "$RC_TLS_SECRET" ] || [ -z "$OC_TLS_SECRET" ] || [ -z "$INGRESS_CLIENT_SECRET" ]; then
            log_error "Existing TLS mode requires RC_TLS_SECRET, OC_TLS_SECRET and INGRESS_CLIENT_SECRET together"
            exit 1
        fi
        log_info "Using operator-provided TLS Secrets: $RC_TLS_SECRET / $OC_TLS_SECRET / $INGRESS_CLIENT_SECRET"
    else
        RC_TLS_SECRET="openan-rc-tls"
        OC_TLS_SECRET="openan-oc-tls"
        INGRESS_CLIENT_SECRET="openan-ingress-client"
        CERT_DIR="$BUNDLE_DIR/certs"
        GEN_ARGS=(--out "$CERT_DIR" --namespace "$K8S_NAMESPACE")
        # INGRESS_HOST may be a DNS name (SAN via --ingress-host) or a bare IP
        # (SAN via --ingress-ip). The LoadBalancer VIP and the registry node IP
        # are added as IP SANs too, so https works via VIP and via NodePort.
        if [ -n "$INGRESS_HOST" ]; then
            if printf '%s' "$INGRESS_HOST" | grep -Eq '^[0-9.]+$' || printf '%s' "$INGRESS_HOST" | grep -q ':'; then
                GEN_ARGS+=(--ingress-ip "$INGRESS_HOST")
            else
                GEN_ARGS+=(--ingress-host "$INGRESS_HOST")
            fi
        fi
        [ -n "$INGRESS_IP" ] && [ "$INGRESS_IP" != "$INGRESS_HOST" ] && GEN_ARGS+=(--ingress-ip "$INGRESS_IP")
        if [ -n "$REGISTRY_NODE_IP" ] && [ "$REGISTRY_NODE_IP" != "$INGRESS_IP" ] && [ "$REGISTRY_NODE_IP" != "$INGRESS_HOST" ]; then
            GEN_ARGS+=(--ingress-ip "$REGISTRY_NODE_IP")
        fi
        log_info "Generating self-signed certificates (openssl)..."
        python3 "$BUNDLE_DIR/tool/gen_certs.py" "${GEN_ARGS[@]}" || {
            log_error "Certificate generation failed (openssl and python3 are required)"
            exit 1
        }
        create_secret_from_files "$RC_TLS_SECRET" \
            "server.cer=$CERT_DIR/registry-center/server.cer" \
            "server_key.pem=$CERT_DIR/registry-center/server_key.pem" \
            "trust.cer=$CERT_DIR/registry-center/trust.cer" \
            "cert_pwd=$CERT_DIR/registry-center/cert_pwd"
        create_secret_from_files "$OC_TLS_SECRET" \
            "server.cer=$CERT_DIR/orchestration-center/server.cer" \
            "server_key.pem=$CERT_DIR/orchestration-center/server_key.pem" \
            "trust.cer=$CERT_DIR/orchestration-center/trust.cer" \
            "cert_pwd=$CERT_DIR/orchestration-center/cert_pwd"
        create_secret_from_files "$INGRESS_CLIENT_SECRET" \
            "tls.crt=$CERT_DIR/ingress-client/tls.crt" \
            "tls.key=$CERT_DIR/ingress-client/tls.key" \
            "ca.crt=$CERT_DIR/ca/ca.cer"
        if [ -z "$REGISTRY_CLIENT_SECRET" ]; then
            REGISTRY_CLIENT_SECRET="openan-registry-client"
            create_secret_from_files "$REGISTRY_CLIENT_SECRET" \
                "trust.cer=$CERT_DIR/ca/ca.cer" \
                "client.cer=$CERT_DIR/ingress-client/tls.crt" \
                "client_key.pem=$CERT_DIR/ingress-client/tls.key"
        fi
        if [ -n "$INGRESS_HOST" ]; then
            PUBLIC_TLS_SECRET="openan-public-tls"
            if "$KUBECTL" -n "$K8S_NAMESPACE" get secret "$PUBLIC_TLS_SECRET" >/dev/null 2>&1; then
                log_info "TLS Secret $PUBLIC_TLS_SECRET already exists, reusing"
            else
                "$KUBECTL" -n "$K8S_NAMESPACE" create secret tls "$PUBLIC_TLS_SECRET" \
                    --cert="$CERT_DIR/ingress/tls.crt" --key="$CERT_DIR/ingress/tls.key" \
                    && "$KUBECTL" -n "$K8S_NAMESPACE" label secret "$PUBLIC_TLS_SECRET" openan-offline-installer=true >/dev/null
            fi
        fi
        log_info "TLS Secrets ready (ingress verifies backends against the shared CA)"
    fi
fi

# Secrets travel via stdin JSON (kubectl create -f -), never argv or disk.
create_secret_from_pairs() {
    local name="$1"; shift
    if "$KUBECTL" -n "$K8S_NAMESPACE" get secret "$name" >/dev/null 2>&1; then
        log_info "Secret $name already exists, reusing"
        return 0
    fi
    printf '%s\n' "$@" | python3 -c '
import base64, json, sys
data = {}
for line in sys.stdin:
    key, sep, value = line.rstrip("\n").partition("=")
    if sep and key:
        data[key] = base64.b64encode(value.encode()).decode()
document = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"namespace": sys.argv[1], "name": sys.argv[2],
                         "labels": {"openan-offline-installer": "true"}},
            "data": data}
print(json.dumps(document))' "$K8S_NAMESPACE" "$name" | "$KUBECTL" create -f - >/dev/null
}

# Credentials as Kubernetes Secrets; the generated values file carries
# references only (no secrets in config.values.yaml or Helm release data).
create_secret_from_pairs "openan-db-credentials" \
    "postgres-password=${DB_PASSWORD}" \
    "mysql-root-password=${DB_PASSWORD}"
create_secret_from_pairs "openan-admin" \
    "admin-password=${OC_ADMIN_PASSWORD}"
LLM_PAIRS=()
[ -n "$REGISTRY_CHAT_APIKEY" ] && LLM_PAIRS+=("registry-chat=${REGISTRY_CHAT_APIKEY}")
[ -n "$ORCH_CHAT_APIKEY" ] && LLM_PAIRS+=("orch-chat=${ORCH_CHAT_APIKEY}")
if [ ${#LLM_PAIRS[@]} -gt 0 ]; then
    create_secret_from_pairs "openan-llm-keys" "${LLM_PAIRS[@]}"
fi

VALUES="$BUNDLE_DIR/config.values.yaml"

# emit_db_storage <hostpath> — shared storage block for the database values
emit_db_storage() {
    local hostpath="$1"
    echo "  storage:"
    echo "    size: ${STORAGE_SIZE}"
    if [ "$STORAGE_MODE" = "sc" ] || { [ "$STORAGE_MODE" = "auto" ] && [ -n "$STORAGE_CLASS" ]; }; then
        echo "    storageClassName: \"${STORAGE_CLASS}\""
    fi
    if [ "$STORAGE_MODE" = "hostpath" ] || [ "$STORAGE_MODE" = "auto" ]; then
        # Distinct storageClassName per PV/PVC pair prevents cross-binding
        # (e.g. the OC runtime PVC claiming the MySQL PV).
        echo "    createStorageClass: true"
        echo "    storageClassName: openan-local"
        echo "    createPV: true"
        echo "    useHostPath: true"
        echo "    hostPath: \"${hostpath}\""
        echo "    nodeName: ${STORAGE_NODE}"
    fi
}

(umask 077
{
    echo "namespace: ${K8S_NAMESPACE}"
    echo "database:"
    echo "  type: ${DB_TYPE}"
    echo "https:"
    echo "  enabled: ${HTTPS_ENABLED}"
    echo "  verifyClient: ${HTTPS_VERIFY_CLIENT}"
    echo "postgresql:"
    if [ "$DB_TYPE" = "mysql" ]; then
        echo "  enabled: false"
        echo "  existingSecret: openan-db-credentials"
    else
        echo "  enabled: true"
        echo "  existingSecret: openan-db-credentials"
        echo "  image: \"${REG_HOST}/${POSTGRES_IMAGE}\""
        emit_db_storage "$HOSTPATH"
    fi
    echo "mysql:"
    if [ "$DB_TYPE" = "mysql" ]; then
        # HOSTPATH keeps its postgres default when unset — swap to the mysql default
        MYSQL_HOSTPATH="${HOSTPATH}"
        [ "$MYSQL_HOSTPATH" = "/data/openan-postgres" ] && MYSQL_HOSTPATH="/data/openan-mysql"
        echo "  enabled: true"
        echo "  existingSecret: openan-db-credentials"
        echo "  image: \"${REG_HOST}/${MYSQL_IMAGE}\""
        emit_db_storage "$MYSQL_HOSTPATH"
    else
        echo "  enabled: false"
        echo "  existingSecret: openan-db-credentials"
    fi
    echo "registry:"
    echo "  enabled: true"
    echo "  replicas: 2"
    echo "  signatureValidationEnabled: ${REGISTRY_SIGNATURE_VALIDATION_ENABLED}"
    echo "  image:"
    echo "    repository: ${REG_HOST}/$(REF_REPO "$REGISTRY_CENTER_IMAGE")"
    echo "    tag: $(REF_TAG "$REGISTRY_CENTER_IMAGE")"
    echo "    pullPolicy: IfNotPresent"
    if [ "$HTTPS_ENABLED" = "true" ]; then
        echo "  tls:"
        echo "    mode: secret"
        echo "    existingSecret: \"${RC_TLS_SECRET}\""
        echo "  ingressClientSecret: \"${INGRESS_CLIENT_SECRET}\""
    fi
    if [ -n "$REGISTRY_CHAT_MODEL" ]; then
        echo "  llm:"
        echo "    chat:"
        echo "      model: \"${REGISTRY_CHAT_MODEL}\""
        echo "      url: \"${REGISTRY_CHAT_URL}\""
        if [ -n "$REGISTRY_CHAT_APIKEY" ]; then
            echo "      existingSecret: openan-llm-keys"
            echo "      existingSecretKey: registry-chat"
        fi
    fi
    echo "orchestration:"
    echo "  enabled: true"
    echo "  replicas: 1"
    echo "  image:"
    echo "    repository: ${REG_HOST}/$(REF_REPO "$ORCHESTRATION_CENTER_IMAGE")"
    echo "    tag: $(REF_TAG "$ORCHESTRATION_CENTER_IMAGE")"
    echo "    pullPolicy: IfNotPresent"
    echo "  admin:"
    echo "    existingSecret: openan-admin"
    if [ "$HTTPS_ENABLED" = "true" ]; then
        echo "  tls:"
        echo "    mode: secret"
        echo "    existingSecret: \"${OC_TLS_SECRET}\""
        echo "  ingressClientSecret: \"${INGRESS_CLIENT_SECRET}\""
        if [ -n "$REGISTRY_CLIENT_SECRET" ]; then
            echo "  clientVerifyServer: true"
            echo "  registryClientSecret: \"${REGISTRY_CLIENT_SECRET}\""
        else
            echo "  clientVerifyServer: false"
        fi
    fi
    if [ -n "$ORCH_CHAT_MODEL" ]; then
        echo "  llm:"
        echo "    chat:"
        echo "      model: \"${ORCH_CHAT_MODEL}\""
        echo "      url: \"${ORCH_CHAT_URL}\""
        if [ -n "$ORCH_CHAT_APIKEY" ]; then
            echo "      existingSecret: openan-llm-keys"
            echo "      existingSecretKey: orch-chat"
        fi
    fi
    # Runtime PVC storage: same fallback pattern as the database
    OC_PERSISTENCE_OPEN=false
    if [ "$STORAGE_MODE" = "sc" ] || { [ "$STORAGE_MODE" = "auto" ] && [ -n "$STORAGE_CLASS" ]; }; then
        echo "  persistence:"
        echo "    storageClassName: \"${STORAGE_CLASS}\""
        OC_PERSISTENCE_OPEN=true
    fi
    if [ "$STORAGE_MODE" = "hostpath" ] || [ "$STORAGE_MODE" = "auto" ]; then
        if [ "$OC_PERSISTENCE_OPEN" = "false" ]; then
            echo "  persistence:"
            OC_PERSISTENCE_OPEN=true
        fi
        # Distinct class from the database: prevents cross-binding
        echo "    storageClassName: openan-oc-runtime"
        echo "    createPV: true"
        echo "    useHostPath: true"
        echo "    hostPath: \"/data/openan-orchestration-runtime\""
        echo "    nodeName: ${STORAGE_NODE}"
    fi
    echo "frontend:"
    echo "  enabled: true"
    echo "  type: ${FRONTEND_TYPE}"
    echo "  replicas: 2"
    echo "  image:"
    if [ "$FRONTEND_TYPE" = "portal" ]; then
        echo "    repository: ${REG_HOST}/$(REF_REPO "$PORTAL_IMAGE")"
        echo "    tag: $(REF_TAG "$PORTAL_IMAGE")"
    else
        echo "    repository: ${REG_HOST}/$(REF_REPO "$WORKFLOW_DESIGNER_IMAGE")"
        echo "    tag: $(REF_TAG "$WORKFLOW_DESIGNER_IMAGE")"
    fi
    echo "    pullPolicy: IfNotPresent"
    # Frontend nginx backend TLS: same material as the ingress client
    # (verify backend certs, present client cert for mTLS backends).
    if [ "$HTTPS_ENABLED" = "true" ] && [ -n "$INGRESS_CLIENT_SECRET" ]; then
        echo "  backendTlsSecret: \"${INGRESS_CLIENT_SECRET}\""
    fi
    echo "ingress:"
    echo "  enabled: true"
    echo "  className: nginx"
    echo "  host: \"${INGRESS_HOST}\""
    if [ "$HTTPS_ENABLED" = "true" ]; then
        echo "  backendVerifyServer: true"
        if [ -n "$INGRESS_HOST" ] && [ -n "$PUBLIC_TLS_SECRET" ]; then
            echo "  tls:"
            echo "    enabled: true"
            echo "    secretName: \"${PUBLIC_TLS_SECRET}\""
        fi
    fi
} >"$VALUES"
)
chmod 600 "$VALUES"

if "$HELM" status openan -n "$K8S_NAMESPACE" >/dev/null 2>&1; then
    log_error "Helm release 'openan' already exists in namespace '$K8S_NAMESPACE'."
    log_error "This version does not support upgrades. Run scripts/uninstall.sh first."
    exit 1
fi

if ! "$HELM" install openan "$BUNDLE_DIR/chart" \
    -n "$K8S_NAMESPACE" --create-namespace \
    -f "$VALUES"; then
    log_error "helm install failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# 7. Self-check
# ---------------------------------------------------------------------------
log_step "[7/7] Verifying deployment"

SELFCHECK="ok"
log_info "Waiting for pods to become ready..."
for _ in $(seq 1 60); do
    not_ready="$("$KUBECTL" -n "$K8S_NAMESPACE" get pods --no-headers 2>/dev/null | grep -Evc "Running|Completed" || true)"
    [ "$not_ready" = "0" ] && break || true
    sleep 5
done
"$KUBECTL" -n "$K8S_NAMESPACE" get pods || true

if "$KUBECTL" -n "$K8S_NAMESPACE" get pods --no-headers 2>/dev/null | grep -Evq "Running|Completed"; then
    log_error "Some pods are not Running"
    SELFCHECK="fail"
fi

# Registry catalog
catalog="$(curl -sf -m 5 "http://${REG_HOST}/v2/_catalog" 2>/dev/null || true)"
if [ -n "$catalog" ]; then log_info "Registry catalog: $catalog"; else log_warn "Registry catalog unreachable"; fi

# Optional demo agents server: verify the sample exists in the image first,
# then start it and health-check it — never report success on a swallowed error.
if [ "$START_AGENTS_SERVER" = "true" ]; then
    log_step "Starting agent examples server"
    ORCH_POD="$("$KUBECTL" -n "$K8S_NAMESPACE" get pods -l app=orchestration-center -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$ORCH_POD" ]; then
        log_warn "No orchestration-center pod found; skipping the agents server"
    elif ! "$KUBECTL" exec "$ORCH_POD" -n "$K8S_NAMESPACE" -- /bin/sh -c \
            "test -f /opt/orchestration-center/samples/start_agents_server.py" 2>/dev/null; then
        log_warn "samples/start_agents_server.py is absent from the orchestration-center image"
        log_warn "The agents server cannot start (check the image build); continuing without it"
    elif "$KUBECTL" exec "$ORCH_POD" -n "$K8S_NAMESPACE" -- /bin/sh -c \
            "cd /opt/orchestration-center && PYTHONPATH=/opt/orchestration-center nohup python3 samples/start_agents_server.py > /tmp/agents-server.log 2>&1 &"; then
        log_info "Agents server starting in $ORCH_POD; waiting for port 8903..."
        agents_ok="false"
        for _ in $(seq 1 12); do
            if "$KUBECTL" exec "$ORCH_POD" -n "$K8S_NAMESPACE" -- /bin/sh -c \
                    "curl -sf http://127.0.0.1:8903/health > /dev/null" 2>/dev/null; then
                agents_ok="true"
                break
            fi
            sleep 5
        done
        if [ "$agents_ok" = "true" ]; then
            log_info "Agent examples server healthy (port 8903)"
        else
            log_error "Agents server did not become healthy within 60s; last log lines:"
            "$KUBECTL" exec "$ORCH_POD" -n "$K8S_NAMESPACE" -- /bin/sh -c \
                "tail -n 20 /tmp/agents-server.log 2>/dev/null" || true
        fi
    else
        log_error "Failed to start the agents server in $ORCH_POD; last log lines:"
        "$KUBECTL" exec "$ORCH_POD" -n "$K8S_NAMESPACE" -- /bin/sh -c \
            "cat /tmp/agents-server.log 2>/dev/null || tail -n 20 /tmp/agents-server.log 2>/dev/null" || true
    fi
fi

# API smoke tests
smoke() {
    local url="$1" name="$2"
    local code
    # CURL_EXTRA carries --resolve/--cacert (or -k) for public HTTPS
    code="$(curl $CURL_EXTRA -s -o /dev/null -w '%{http_code}' -m 10 "$url" 2>/dev/null || true)"
    if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 500 ] 2>/dev/null; then
        log_info "smoke $name: HTTP $code"
    else
        log_warn "smoke $name: HTTP ${code:-000} ($url)"
    fi
}

CURL_EXTRA=""
echo ""
# Public HTTPS entry (DNS name or bare IP) takes precedence over the plain
# LoadBalancer-IP / frontend-NodePort fallbacks. An IP INGRESS_HOST needs no
# --resolve (clients connect to the IP directly, no SNI); a DNS name resolves
# through the LoadBalancer VIP when one is assigned.
if [ "$HTTPS_ENABLED" = "true" ] && [ -n "$INGRESS_HOST" ] && [ -n "$PUBLIC_TLS_SECRET" ]; then
    if printf '%s' "$INGRESS_HOST" | grep -Eq '^[0-9.]+$' || printf '%s' "$INGRESS_HOST" | grep -q ':'; then
        CURL_EXTRA=""
        [ -n "$INGRESS_IP" ] && [ "$INGRESS_IP" != "$INGRESS_HOST" ] && CURL_EXTRA="--resolve ${INGRESS_HOST}:443:${INGRESS_IP}"
    else
        CURL_EXTRA="--resolve ${INGRESS_HOST}:443:${INGRESS_IP}"
    fi
    if [ -n "$BUNDLE_DIR/certs/ca/ca.cer" ] && [ -r "$BUNDLE_DIR/certs/ca/ca.cer" ]; then
        CURL_EXTRA="$CURL_EXTRA --cacert $BUNDLE_DIR/certs/ca/ca.cer"
    else
        CURL_EXTRA="$CURL_EXTRA -k"
    fi
    echo "  Access URL:  https://${INGRESS_HOST}/"
    smoke "https://${INGRESS_HOST}/registry/rest/v1/registry-center/agent-cards" "registry"
    smoke "https://${INGRESS_HOST}/api/orchestrate/rest/v1/orchestrate/agent-cards" "orchestration"
    smoke "https://${INGRESS_HOST}/api/registry/rest/v1/registry-center/agent-cards" "registry-via-gateway"
elif [ -n "$INGRESS_IP" ]; then
    echo "  Access URL:  http://${INGRESS_IP}/"
    smoke "http://${INGRESS_IP}/registry/rest/v1/registry-center/agent-cards" "registry"
    smoke "http://${INGRESS_IP}/api/orchestrate/rest/v1/orchestrate/agent-cards" "orchestration"
    smoke "http://${INGRESS_IP}/api/registry/rest/v1/registry-center/agent-cards" "registry-via-gateway"
else
    NODE_PORT="$("$KUBECTL" -n "$K8S_NAMESPACE" get svc openan-frontend -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
    NODE_IP="$("$KUBECTL" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
    echo "  Access URL (NodePort): http://${NODE_IP}:${NODE_PORT}/"
fi
echo ""
echo "  Status:  $KUBECTL -n $K8S_NAMESPACE get pods,ingress,svc"
echo "  Uninstall: scripts/uninstall.sh --config $BUNDLE_DIR/config.env"
echo ""

if [ "$SELFCHECK" != "ok" ]; then
    log_error "Deployment finished with errors — inspect the pods above."
    exit 1
fi
log_info "Installation complete."
