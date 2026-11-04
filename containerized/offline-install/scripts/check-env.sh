#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Environment check for the OpenAN offline installer.
#
# It ONLY detects and reports; it never modifies the OS or the container
# runtime. Anything that needs changing is printed as a manual fix step.
#
#   scripts/check-env.sh                 # check the Kubernetes target
#   scripts/check-env.sh --soft          # report only, never exit non-zero

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SOFT="false"
CONFIG_FILE=""

# Load config early so checks can use REGISTRY_NODE_IP, METALLB_POOL, ...
set +u
while [ $# -gt 0 ]; do
    case "$1" in
        --soft)   SOFT="true"; shift ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done
set -u

# --- Defaults (mirrors config.env.example) -----------------------------------
K8S_NAMESPACE="${K8S_NAMESPACE:-openan}"
INSTALL_REGISTRY="${INSTALL_REGISTRY:-true}"
REGISTRY_NODE="${REGISTRY_NODE:-}"
REGISTRY_NODE_IP="${REGISTRY_NODE_IP:-}"
REGISTRY_NODEPORT="${REGISTRY_NODEPORT:-30500}"
INSTALL_METALLB="${INSTALL_METALLB:-true}"
METALLB_POOL="${METALLB_POOL:-}"
INGRESS_HOST="${INGRESS_HOST:-}"
HTTPS_ENABLED="${HTTPS_ENABLED:-true}"
RC_TLS_SECRET="${RC_TLS_SECRET:-}"
OC_TLS_SECRET="${OC_TLS_SECRET:-}"
INGRESS_CLIENT_SECRET="${INGRESS_CLIENT_SECRET:-}"
STORAGE_MODE="${STORAGE_MODE:-auto}"
STORAGE_NODE="${STORAGE_NODE:-}"
DB_TYPE="${DB_TYPE:-mysql}"
FRONTEND_TYPE="${FRONTEND_TYPE:-portal}"
OC_ADMIN_PASSWORD="${OC_ADMIN_PASSWORD:-}"
REGISTRY_CHAT_URL="${REGISTRY_CHAT_URL:-}"
LLM_VALIDATE="${LLM_VALIDATE:-false}"

if [ -n "$CONFIG_FILE" ]; then
    load_config "$CONFIG_FILE"
fi

FAILURES=()
WARNINGS=()

pass() { echo -e "  ${GREEN}[ OK ]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAILURES+=("$1"); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARNINGS+=("$1"); }

section() { echo ""; echo -e "${CYAN}== $1 ==${NC}"; }

# ---------------------------------------------------------------------------
# Shared checks
# ---------------------------------------------------------------------------
ARCH="$(detect_arch)"
OS_ID="$(detect_os_id)"

section "Platform"
if [ -n "$ARCH" ]; then pass "architecture: $ARCH"; else fail "unsupported architecture: $(uname -m) (need x86_64 or aarch64)"; fi
pass "os: $OS_ID ($(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}"))"

section "Transport security (HTTPS)"
if [ "$(printf '%s' "$HTTPS_ENABLED" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
    warn "HTTPS_ENABLED is not true — in-cluster traffic stays plain HTTP"
else
    if [ -n "$INGRESS_HOST" ]; then
        pass "Ingress host: $INGRESS_HOST (DNS name or IP; IP enables https://<IP> public access)"
    fi
    if [ -n "$RC_TLS_SECRET" ] || [ -n "$OC_TLS_SECRET" ] || [ -n "$INGRESS_CLIENT_SECRET" ]; then
        # Existing-Secret mode: all three names required and present in the cluster
        if [ -z "$RC_TLS_SECRET" ] || [ -z "$OC_TLS_SECRET" ] || [ -z "$INGRESS_CLIENT_SECRET" ]; then
            fail "existing TLS mode requires RC_TLS_SECRET, OC_TLS_SECRET and INGRESS_CLIENT_SECRET together"
        elif kubectl get secret "$RC_TLS_SECRET" "$OC_TLS_SECRET" "$INGRESS_CLIENT_SECRET" -n "$K8S_NAMESPACE" >/dev/null 2>&1; then
            pass "TLS Secrets present: $RC_TLS_SECRET / $OC_TLS_SECRET / $INGRESS_CLIENT_SECRET"
        else
            fail "configured TLS Secrets not found in namespace '$K8S_NAMESPACE' (create them first)"
        fi
    else
        if have openssl; then
            pass "openssl present (self-signed certificate generation)"
        else
            fail "openssl not found — required to generate certificates (tool/gen_certs.py)"
        fi
        if have python3; then
            pass "python3 present (tool/gen_certs.py)"
        else
            fail "python3 not found — required to generate certificates (tool/gen_certs.py)"
        fi
        if [ -x "$BUNDLE_DIR/tool/gen_certs.py" ] || [ -f "$BUNDLE_DIR/tool/gen_certs.py" ]; then
            pass "tool/gen_certs.py bundled"
        else
            fail "tool/gen_certs.py missing from the bundle"
        fi
    fi
fi

section "Bundle"
if [ -d "$BUNDLE_DIR/images" ] && [ -n "$(ls -A "$BUNDLE_DIR/images" 2>/dev/null)" ]; then
    pass "images/ present ($(ls "$BUNDLE_DIR/images" | wc -l) files)"
else
    fail "images/ missing or empty — run this from an unpacked offline bundle"
fi
if [ -r "$BUNDLE_DIR/SHA256SUMS" ]; then
    if (cd "$BUNDLE_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
        pass "bundle checksum verified"
    else
        warn "SHA256SUMS present but verification FAILED — bundle may be corrupted/incomplete"
    fi
else
    warn "SHA256SUMS not found, skipping integrity check"
fi

need_image_tar() {
    local name="$1"
    local f="$BUNDLE_DIR/images/${name}-${ARCH}.tar"
    if [ -r "$f" ]; then pass "image tar: $(basename "$f")"; else fail "missing image tar for this arch: images/${name}-${ARCH}.tar"; fi
}

# ---------------------------------------------------------------------------
# Kubernetes mode
# ---------------------------------------------------------------------------
check_k8s() {
    section "Kubernetes tooling"
    if have kubectl; then
        local v
        v="$(kubectl version --client -o json 2>/dev/null | grep -oP '"gitVersion":\s*"v\K[^"]+' | head -1)"
        [ -z "$v" ] && v="$(kubectl version --client 2>/dev/null | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        pass "kubectl: ${v:-unknown}"
    else
        fail "kubectl not found (bundled copy is in deps/, install.sh can use it)"
    fi

    if have helm; then
        pass "helm: $(helm version --short 2>/dev/null)"
    else
        warn "helm not found on PATH (bundled copy is in deps/, install.sh can use it)"
    fi

    if have ctr; then
        if ctr -n k8s.io images ls >/dev/null 2>&1; then
            pass "containerd reachable via ctr (k8s.io namespace)"
        else
            warn "ctr present but cannot talk to containerd (rerun as root?)"
        fi
    else
        fail "ctr not found — containerd is required (see docs/KUBEADM_CLUSTER.md)"
    fi

    if have curl; then
        pass "curl: $(curl --version 2>/dev/null | head -1 | awk '{print $1, $2}')"
    else
        fail "curl not found — required for registry readiness checks and API smoke tests"
    fi

    section "Cluster"
    if kubectl cluster-info >/dev/null 2>&1; then
        pass "cluster reachable"
        local nodes
        nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
        pass "nodes: $nodes"
        # Mixed-arch detection
        local arches
        arches="$(kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}' 2>/dev/null | tr ' ' '\n' | sort -u | tr '\n' ',')"
        log_info "node architectures: ${arches%,}"
    else
        fail "cannot reach Kubernetes cluster (check KUBECONFIG)"
        return
    fi

    # Default storage class
    section "Storage"
    local defsc
    defsc="$(kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)"
    if [ -n "$defsc" ]; then
        pass "default StorageClass: $defsc"
    else
        case "$STORAGE_MODE" in
            sc)       fail "STORAGE_MODE=sc but no default StorageClass found";;
            hostpath) warn "no default StorageClass — will use hostPath local PV on STORAGE_NODE=${STORAGE_NODE:-<this node>}";;
            *)        warn "no default StorageClass — will fall back to hostPath local PV (set STORAGE_NODE explicitly for multi-node clusters)";;
        esac
    fi

    # Ingress controller
    section "Ingress"
    if kubectl get ns ingress-nginx >/dev/null 2>&1; then
        pass "ingress-nginx namespace present (will be reused if healthy)"
    else
        warn "ingress-nginx not installed — install.sh will install it offline from deps/"
    fi

    # MetalLB + pool
    section "LoadBalancer"
    if [ "$INSTALL_METALLB" = "true" ]; then
        if [ -z "$METALLB_POOL" ]; then
            fail "INSTALL_METALLB=true but METALLB_POOL is empty — provide a routable internal range"
        else
            pass "MetalLB pool configured: $METALLB_POOL (ensure it is routable and unused)"
        fi
    else
        warn "INSTALL_METALLB=false — ensure another LoadBalancer/NodePort strategy exists"
    fi

    # Registry node / containerd insecure
    # containerd v2 reads /etc/containerd/certs.d/<host:port>/hosts.toml at
    # startup only; after adding or changing hosts.toml you MUST restart
    # containerd on every node (systemctl restart containerd).
    section "Private registry"
    if [ "$INSTALL_REGISTRY" = "true" ]; then
        local host="${REGISTRY_NODE_IP:-}"
        [ -z "$host" ] && host="$(default_ip)"
        if [ -n "$host" ]; then
            pass "registry endpoint will be ${host}:${REGISTRY_NODEPORT}"
            if containerd_insecure_configured "$host"; then
                pass "containerd on this node appears to trust $host"
            else
                warn "containerd on THIS node does not list $host as insecure"
                warn "  FIX (manual, every node): add the host to /etc/containerd/config.toml"
                warn "  under   plugins.'io.containerd.grpc.v1.cri'.registry.configs"
                warn "  then:   systemctl restart containerd"
                warn "  See docs/DEPENDENCIES.md for the exact snippet."
            fi
        else
            fail "cannot determine registry node IP — set REGISTRY_NODE_IP"
        fi
    fi

    # OC admin credential (portal login; OC refuses to start over HTTP without one)
    section "OC admin"
    if [ -n "$OC_ADMIN_PASSWORD" ]; then
        pass "OC admin password configured"
    else
        fail "OC_ADMIN_PASSWORD is empty - OC seeds its 'admin' account (portal login) from it and refuses to start over HTTP without a credential. Set it in config.env."
    fi

    section "Image tars (this arch: $ARCH)"
    need_image_tar "registry-center"
    need_image_tar "orchestration-center"
    case "$FRONTEND_TYPE" in
        portal)            need_image_tar "portal";;
        workflow-designer) need_image_tar "workflow-designer";;
        *)                 fail "invalid FRONTEND_TYPE: $FRONTEND_TYPE (use portal|workflow-designer)";;
    esac
    need_image_tar "registry-2"
    case "$DB_TYPE" in
        mysql)      need_image_tar "mysql-8-4-3";;
        postgresql) need_image_tar "postgres-15-alpine";;
        *)          fail "invalid DB_TYPE: $DB_TYPE (use postgresql|mysql)";;
    esac
    need_image_tar "ingress-nginx-controller"
    if [ "$INSTALL_METALLB" = "true" ]; then
        need_image_tar "metallb-controller"
        need_image_tar "metallb-speaker"
    fi

    section "Time & disks"
    if have timedatectl && timedatectl show -p NTPSynchronized 2>/dev/null | grep -q "yes"; then
        pass "clock is NTP-synchronised"
    elif have chronyc && chronyc tracking >/dev/null 2>&1; then
        pass "chrony present"
    else
        warn "cannot confirm NTP sync — unsynchronised clocks break TLS and image pulls"
    fi
    local avail
    avail="$(df -Pk "$BUNDLE_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "$avail" ] && [ "$avail" -lt 5242880 ]; then
        warn "less than 5 GiB free next to the bundle"
    else
        pass "disk space looks sufficient"
    fi

    if [ -n "$REGISTRY_CHAT_URL" ] && [ "$LLM_VALIDATE" = "true" ]; then
        section "LLM"
        if curl -sf -m 5 -o /dev/null "$REGISTRY_CHAT_URL"; then
            pass "LLM endpoint reachable: $REGISTRY_CHAT_URL"
        else
            warn "LLM endpoint not reachable: $REGISTRY_CHAT_URL"
        fi
    fi
}

check_k8s

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
if [ "${#FAILURES[@]}" -eq 0 ]; then
    echo -e "${GREEN}Environment check PASSED${NC}"
    if [ "${#WARNINGS[@]}" -gt 0 ]; then
        echo -e "${YELLOW}${#WARNINGS[@]} warning(s) — review the manual items above.${NC}"
    fi
    echo "=========================================="
    exit 0
else
    echo -e "${RED}Environment check FAILED (${#FAILURES[@]} issue(s))${NC}"
    echo "=========================================="
    i=1
    for f in "${FAILURES[@]}"; do
        echo "  $i. $f"
        i=$((i + 1))
    done
    echo ""
    echo "Resolve the items above and re-run. See docs/DEPENDENCIES.md."
    if [ "$SOFT" = "true" ]; then
        exit 0
    fi
    exit 1
fi
