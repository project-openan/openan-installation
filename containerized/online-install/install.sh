#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Single entry point for the online install:
#   ./install.sh               interactive guided install (requires a terminal)
#   ./install.sh --values ...  non-interactive deploy for prepared environments/CI
# Configuration and every secret stay in configure.py (kubectl stdin); this
# script only orchestrates and never echoes credentials.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_prompt(){ echo -e "${BLUE}[?]${NC} $1"; }

usage() {
    cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Without --values the installer is interactive and runs four guided phases
(requires a terminal):
  [1/4] preflight       kubectl / helm / python3 and cluster reachability; missing
                        kubectl/helm can be auto-installed on request (official
                        installers; python3 and Docker Desktop stay manual)
  [2/4] infrastructure  MetalLB + ingress-nginx (pinned, skipped when present)
  [3/4] application     guided wizard: components, image tag(s), models, signing, admin
                        password; SQL, storage and hostname are automatic
                        (in-cluster PostgreSQL, default StorageClass or local
                        hostPath fallback, catch-all host; use reviewed values
                        for external SQL, HTTPS and host-based routing)
  [4/4] deploy          deployment summary + confirmation, helm upgrade --install,
                        optional agent examples server (interactive offer when
                        orchestration is deployed), access summary

Release and namespace default to "openan" without prompts; override them with
--release/--namespace. Building from source is flag-driven, not a prompt.

With --values the installer is non-interactive (CI / prepared environments);
secrets must already exist as Kubernetes Secrets:

  --values FILE          deploy with a reviewed values file (skips every prompt)
  --release NAME         Helm release name (default: openan)
  --namespace NAME       target namespace (default: openan)
  --skip-build           skip the image build phase
  --tag TAG              shared application image tag; passed to the wizard as
                         the default, and required with the build flags below
  --registry-release URL registry-center source archive (build phase)
  --orchestration-release URL orchestration-center source archive (build phase)
  --skip-infra           skip the infrastructure phase
  --metallb-chart TGZ    reviewed local MetalLB chart package (infra phase)
  --metallb-values FILE  values for the MetalLB chart
  --ingress-chart TGZ    reviewed local ingress-nginx chart package (infra phase)
  --ingress-values FILE  values for the ingress-nginx chart

Secrets are collected only by configure.py and reach Kubernetes via kubectl stdin.
EOF
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-yes}"
    local answer

    if [ "$default" = "yes" ]; then
        log_prompt "$prompt [Y/n]:" >&2
        read -r answer
        [ -z "$answer" ] && answer="y"
    else
        log_prompt "$prompt [y/N]:" >&2
        read -r answer
        [ -z "$answer" ] && answer="n"
    fi

    [[ "$answer" =~ ^[Yy] ]]
}

ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [ -n "$default" ]; then
        log_prompt "$prompt [$default]:" >&2
    else
        log_prompt "$prompt:" >&2
    fi
    read -r value
    echo "${value:-$default}"
}

NAME_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

# ---------------------------------------------------------------------------
# Argument parsing (both modes)
# ---------------------------------------------------------------------------
VALUES=""
RELEASE="openan"
NAMESPACE="openan"
SKIP_BUILD=false
SKIP_INFRA=false
BUILD_TAG=""
RC_SOURCE=""
OC_SOURCE=""
METALLB_CHART=""
METALLB_VALUES=""
INGRESS_CHART=""
INGRESS_VALUES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --skip-infra) SKIP_INFRA=true; shift ;;
        --values|--release|--namespace|--tag|--registry-release|--orchestration-release|--metallb-chart|--metallb-values|--ingress-chart|--ingress-values)
            [ $# -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }
            case "$1" in
                --values) VALUES="$2" ;;
                --release) RELEASE="$2" ;;
                --namespace) NAMESPACE="$2" ;;
                --tag) BUILD_TAG="$2" ;;
                --registry-release) RC_SOURCE="$2" ;;
                --orchestration-release) OC_SOURCE="$2" ;;
                --metallb-chart) METALLB_CHART="$2" ;;
                --metallb-values) METALLB_VALUES="$2" ;;
                --ingress-chart) INGRESS_CHART="$2" ;;
                --ingress-values) INGRESS_VALUES="$2" ;;
            esac
            shift 2 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

for name in "$RELEASE" "$NAMESPACE"; do
    if ! [[ "$name" =~ $NAME_RE && ${#name} -le 53 ]]; then
        echo "Invalid release/namespace: $name (see --help)" >&2
        exit 2
    fi
done

# ---------------------------------------------------------------------------
# Non-interactive mode: --values with prepared images, infrastructure and Secrets
# ---------------------------------------------------------------------------
if [ -n "$VALUES" ]; then
    [ -f "$VALUES" ] || { echo "Values file missing: $VALUES" >&2; exit 2; }
    if [ "$SKIP_BUILD" = false ]; then
        # Fail before any tool call: build requires explicit accepted sources.
        if [ -z "$RC_SOURCE" ] || [ -z "$OC_SOURCE" ] || [ -z "$BUILD_TAG" ]; then
            echo "Build requires --tag with --registry-release and --orchestration-release, or --skip-build." >&2
            exit 2
        fi
    fi
    if [ "$SKIP_INFRA" = false ]; then
        for file in "$METALLB_CHART" "$METALLB_VALUES" "$INGRESS_CHART" "$INGRESS_VALUES"; do
            [ -f "$file" ] || { echo "Provide reviewed local infrastructure chart packages and values, or --skip-infra." >&2; exit 2; }
        done
    fi
    for tool in kubectl helm python3; do
        command -v "$tool" >/dev/null 2>&1 || { echo "Missing tool: $tool" >&2; exit 2; }
    done
    kubectl cluster-info >/dev/null
    if [ "$SKIP_BUILD" = false ]; then
        bash "$SCRIPT_DIR/../build/build.sh" --tag "$BUILD_TAG" \
            --registry-release "$RC_SOURCE" --orchestration-release "$OC_SOURCE"
    fi
    if [ "$SKIP_INFRA" = false ]; then
        # Explicit operator-approved packages; no guessed IP pools, latest
        # downloads or cluster reconfiguration.
        helm upgrade --install metallb "$METALLB_CHART" --namespace metallb-system \
            --create-namespace --values "$METALLB_VALUES" --wait --timeout 5m
        helm upgrade --install ingress-nginx "$INGRESS_CHART" --namespace ingress-nginx \
            --create-namespace --values "$INGRESS_VALUES" --wait --timeout 5m
    fi
    # Validate before creating/upgrading application resources; namespace must match values.
    helm lint "$SCRIPT_DIR/openan-chart" --namespace "$NAMESPACE" --values "$VALUES"
    helm upgrade --install "$RELEASE" "$SCRIPT_DIR/openan-chart" --namespace "$NAMESPACE" \
        --create-namespace --values "$VALUES" --wait --timeout 10m
    exit 0
fi

# ---------------------------------------------------------------------------
# Interactive mode (requires a terminal; configure.py collects secrets via TTY)
# ---------------------------------------------------------------------------
[ -t 0 ] || { echo "install.sh without --values is interactive and requires a terminal; add --values FILE for automation" >&2; exit 2; }

echo ""
echo "=========================================="
echo "  OpenAN Platform - Interactive Install"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# [1/4] Preflight
# ---------------------------------------------------------------------------
log_step "[1/4] Preflight"

# Auto-install helpers: only run after an explicit interactive confirmation;
# official installers, no custom scripts. python3 stays manual (OS package).
install_binary() {  # $1 = download URL, $2 = binary name
    local url="$1" name="$2" dest_dir
    if [ -w /usr/local/bin ]; then
        dest_dir=/usr/local/bin
    elif command -v sudo >/dev/null 2>&1; then
        dest_dir=/usr/local/bin
    else
        dest_dir="$HOME/.local/bin"
        mkdir -p "$dest_dir"
    fi
    curl -fsSLo "./${name}" "$url" || return 1
    chmod 0755 "./${name}"
    if [ "$dest_dir" = /usr/local/bin ] && [ ! -w /usr/local/bin ]; then
        sudo install -m 0755 "./${name}" "${dest_dir}/${name}" || { rm -f "./${name}"; return 1; }
    else
        mv "./${name}" "${dest_dir}/${name}" || { rm -f "./${name}"; return 1; }
    fi
    case ":$PATH:" in
        *":${dest_dir}:"*) ;;
        *) log_warn "${dest_dir} is not on this shell's PATH; export PATH=\"\$PATH:${dest_dir}\" and re-run" ;;
    esac
}

install_tool() {
    local tool="$1" os arch version
    case "$(uname -s)" in
        Linux*)  os=linux ;;
        Darwin*) os=darwin ;;
        *) log_error "Automatic $tool installation is unsupported on $(uname -s)"; return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64)        arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) log_error "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac
    case "$tool" in
        kubectl)
            if [ "$os" = darwin ] && command -v brew >/dev/null 2>&1; then
                brew install kubectl
            else
                version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" || {
                    log_error "Could not resolve the stable kubectl version"; return 1; }
                install_binary "https://dl.k8s.io/release/${version}/bin/${os}/${arch}/kubectl" kubectl
            fi
            ;;
        helm)
            if [ "$os" = darwin ] && command -v brew >/dev/null 2>&1; then
                brew install helm
            else
                curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            fi
            ;;
    esac
}

MISSING_TOOLS=()
for tool in kubectl helm python3; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS+=("$tool")
done
if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    log_warn "Missing required tools: ${MISSING_TOOLS[*]}"
    if printf '%s\n' "${MISSING_TOOLS[@]}" | grep -q '^python3$'; then
        log_error "python3 must be installed manually (OS package manager)"
        exit 2
    fi
    if ask_yes_no "Install missing tools automatically (official kubectl/helm installers)?" "yes"; then
        for tool in "${MISSING_TOOLS[@]}"; do
            log_step "Installing $tool"
            install_tool "$tool" || { log_error "Failed to install $tool"; exit 2; }
        done
        for tool in "${MISSING_TOOLS[@]}"; do
            command -v "$tool" >/dev/null 2>&1 || {
                log_error "$tool still unavailable; install it manually and re-run"; exit 2; }
        done
        log_info "Missing tools installed"
    else
        log_info "  kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
        log_info "  helm: https://helm.sh/docs/intro/install/"
        exit 2
    fi
fi
if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "Kubernetes cluster unreachable: kubectl cluster-info failed"
    exit 2
fi
KUBECTL_CLIENT="$(kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
log_info "kubectl client version: ${KUBECTL_CLIENT:-unknown}"
log_info "Release: $RELEASE (override with --release)"
log_info "Namespace: $NAMESPACE (override with --namespace)"

# ---------------------------------------------------------------------------
# Images (optional pre-build from explicit sources; the wizard asks the tag
# itself; the tag has no default by contract: old v1.0.0 images are not
# compatible with the current chart)
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ] && { [ -n "$RC_SOURCE" ] || [ -n "$OC_SOURCE" ]; }; then
    if [ -z "$RC_SOURCE" ] || [ -z "$OC_SOURCE" ] || [ -z "$BUILD_TAG" ]; then
        log_error "Building requires --tag with --registry-release and --orchestration-release"
        exit 2
    fi
    # The build phase needs a working Docker daemon with buildx; offer the
    # official Linux installer behind an explicit confirmation.
    if ! docker buildx version >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        log_warn "The build phase needs a working Docker daemon with buildx"
        if [ "$(uname -s)" != Linux ]; then
            log_error "Install Docker Desktop manually: https://docs.docker.com/desktop/"
            exit 2
        fi
        if ask_yes_no "Install Docker automatically (get.docker.com)?" "yes"; then
            curl -fsSL https://get.docker.com | sh || { log_error "Docker installation failed"; exit 2; }
            if command -v systemctl >/dev/null 2>&1; then
                sudo systemctl enable --now docker 2>/dev/null || true
            fi
            if ! id -nG "$USER" 2>/dev/null | grep -qw docker; then
                sudo usermod -aG docker "$USER" 2>/dev/null || true
            fi
        else
            log_info "  Docker: https://docs.docker.com/get-docker/"
            exit 2
        fi
        docker info >/dev/null 2>&1 || {
            log_error "Docker daemon unreachable; if you were just added to the docker group, re-login and re-run"
            exit 2; }
        docker buildx version >/dev/null 2>&1 || { log_error "docker buildx unavailable"; exit 2; }
    fi
    log_step "Building images from source (tag $BUILD_TAG)"
    bash "$SCRIPT_DIR/../build/build.sh" --tag "$BUILD_TAG" \
        --registry-release "$RC_SOURCE" --orchestration-release "$OC_SOURCE"
fi

# ---------------------------------------------------------------------------
# [2/4] Infrastructure
# ---------------------------------------------------------------------------
log_step "[2/4] Infrastructure"
METALLB_PRESENT=false
INGRESS_PRESENT=false
if kubectl get namespace metallb-system >/dev/null 2>&1; then
    METALLB_PRESENT=true
fi
if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
    INGRESS_PRESENT=true
fi
# MetalLB namespace may exist while its IPAddressPool was removed (e.g. by a
# previous uninstall or manual cleanup); the pool is what actually assigns
# LoadBalancer IPs, so treat a missing pool as "not present".
if [ "$METALLB_PRESENT" = true ]; then
    if ! kubectl get ipaddresspool openan-pool -n metallb-system >/dev/null 2>&1; then
        log_warn "MetalLB namespace found but openan-pool IPAddressPool is missing"
        METALLB_PRESENT=false
    fi
fi
if [ "$METALLB_PRESENT" = true ] && [ "$INGRESS_PRESENT" = true ]; then
    log_info "MetalLB and ingress-nginx already installed, skipping"
else
    if ask_yes_no "Install MetalLB + ingress-nginx automatically (pinned versions)?" "yes"; then
        log_info "Applying ingress-nginx controller-v1.15.1"
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml
        log_info "Applying MetalLB v0.16.1"
        kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml
        log_info "Waiting for MetalLB CRDs (up to 60s)"
        CRD_READY=false
        for _ in $(seq 1 12); do
            if kubectl get crd ipaddresspools.metallb.io >/dev/null 2>&1; then
                CRD_READY=true
                break
            fi
            sleep 5
        done
        if [ "$CRD_READY" != true ]; then
            log_error "MetalLB CRDs (ipaddresspools.metallb.io) not available after 60s"
            exit 1
        fi
    else
        log_warn "Install MetalLB/ingress-nginx yourself, or rerun and answer yes; see QUICKSTART.md"
    fi
fi

# The pool is applied unconditionally (unlike the namespace-scoped install above):
# a previous uninstall or manual cleanup may have deleted the IPAddressPool while
# leaving the MetalLB deployment intact, which would strand LoadBalancer services
# in <pending> forever.
METALLB_POOL_CFG=""
if kubectl get ipaddresspool openan-pool -n metallb-system >/dev/null 2>&1; then
    log_info "MetalLB pool openan-pool already exists, skipping pool configuration"
else
    if [ -t 0 ]; then
        for _ in 1 2 3; do
            METALLB_POOL_CFG="$(ask_input "MetalLB IP pool (e.g. 192.168.1.200-192.168.1.250 or a CIDR, leave empty to skip)" "")"
            [ -z "$METALLB_POOL_CFG" ] && break
            if printf '%s' "$METALLB_POOL_CFG" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(-([0-9]{1,3}\.){3}[0-9]{1,3}|/[0-9]{1,2})?$'; then
                break
            fi
            log_warn "Pool must be an IP range (a.b.c.d-a.b.c.d) or a CIDR (a.b.c.d/n)"
            METALLB_POOL_CFG=""
        done
    else
        log_warn "No terminal; skipping MetalLB pool prompt (existing pool not found)"
    fi
    if [ -n "$METALLB_POOL_CFG" ]; then
        log_info "Configuring MetalLB pool: $METALLB_POOL_CFG"
        kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: openan-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_POOL_CFG}
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
    else
        log_warn "No MetalLB pool configured; LoadBalancer IPs stay pending on bare metal"
    fi
fi

# ---------------------------------------------------------------------------
# [3/4] Application (the wizard asks the image tag and everything else)
# ---------------------------------------------------------------------------
log_step "[3/4] Application"
VALUES="$PWD/deployment.generated.json"
if [ -e "$VALUES" ]; then
    log_warn "Found existing $VALUES"
    if ask_yes_no "Regenerate the configuration from scratch (removes this file and re-runs the wizard)?" "no"; then
        rm "$VALUES"
        log_info "Removed $VALUES; re-running the wizard."
    else
        log_info "Keeping $VALUES; redeploy it with: ./install.sh --values $VALUES --release $RELEASE --namespace $NAMESPACE --skip-build --skip-infra"
        exit 0
    fi
fi
CONFIGURE_ARGS=(--namespace "$NAMESPACE" --release "$RELEASE" --output "$VALUES")
if [ -n "$BUILD_TAG" ]; then
    # Preset shared tag (e.g. the one just built); the wizard still offers
    # per-component overrides.
    CONFIGURE_ARGS+=(--tag "$BUILD_TAG")
fi
python3 "$SCRIPT_DIR/configure.py" "${CONFIGURE_ARGS[@]}"
log_info "Linting the chart against the generated values"
helm lint "$SCRIPT_DIR/openan-chart" --namespace "$NAMESPACE" --values "$VALUES"

# ---------------------------------------------------------------------------
# [4/4] Deploy
# ---------------------------------------------------------------------------
log_step "[4/4] Deploy"

# Parse the generated values once: deployment choices and access summary.
SCHEME="http"
INGRESS_HOST=""
REGISTRY_ENABLED=true
ORCHESTRATION_ENABLED=true
FRONTEND_ENABLED=true
TAG_REGISTRY="-"
TAG_ORCHESTRATION="-"
TAG_FRONTEND="-"
SIGNING="-"
MODELS_RC="-"
MODELS_OC="-"
PG_SECRET="-"
STORAGE_NODE=""
while read -r key value; do
    case "$key" in
        scheme) SCHEME="$value" ;;
        host) INGRESS_HOST="$value" ;;
        registry) REGISTRY_ENABLED="$value" ;;
        orchestration) ORCHESTRATION_ENABLED="$value" ;;
        frontend) FRONTEND_ENABLED="$value" ;;
        tag_registry) TAG_REGISTRY="$value" ;;
        tag_orchestration) TAG_ORCHESTRATION="$value" ;;
        tag_frontend) TAG_FRONTEND="$value" ;;
        signing) SIGNING="$value" ;;
        models_rc) MODELS_RC="$value" ;;
        models_oc) MODELS_OC="$value" ;;
        pg_secret) PG_SECRET="$value" ;;
        storage_node) STORAGE_NODE="$value" ;;
    esac
done < <(python3 - "$VALUES" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    values = json.load(stream)
ingress = values.get("ingress") or {}
print("scheme", "https" if (ingress.get("tls") or {}).get("enabled") else "http")
print("host", ingress.get("host") or "")
for comp in ("registry", "orchestration", "frontend"):
    block = values.get(comp) or {}
    print(comp, str(bool(block.get("enabled", True))).lower())
    print("tag_" + comp, (block.get("image") or {}).get("tag") or "-")
print("signing", ((values.get("registry") or {}).get("signing") or {}).get("mode") or "-")
print("models_rc", (values.get("registry") or {}).get("modelsConfigMap") or "-")
print("models_oc", (values.get("orchestration") or {}).get("modelsConfigMap") or "-")
print("pg_secret", (values.get("postgresql") or {}).get("existingSecret") or "-")
print("storage_node", ((values.get("postgresql") or {}).get("storage") or {}).get("nodeName") or "")
PY
)

# Confirmation gate: non-secret summary before anything is deployed. Secrets
# and ConfigMaps already created by the wizard remain if cancelled (the
# wizard is not transactional; the redeploy command reuses the same values).
echo ""
echo "=========================================="
echo "  Deployment summary"
echo "=========================================="
echo "  Release/namespace: $RELEASE / $NAMESPACE"
COMPONENTS=""
if [ "$REGISTRY_ENABLED" = true ]; then COMPONENTS="registry"; fi
if [ "$ORCHESTRATION_ENABLED" = true ]; then COMPONENTS="${COMPONENTS:+$COMPONENTS }orchestration"; fi
if [ "$FRONTEND_ENABLED" = true ]; then COMPONENTS="${COMPONENTS:+$COMPONENTS }frontend"; fi
echo "  Components:        ${COMPONENTS:-none}"
echo "  Image tags:        registry=$TAG_REGISTRY orchestration=$TAG_ORCHESTRATION frontend=$TAG_FRONTEND"
echo "  SQL:               in-cluster PostgreSQL (Secret $PG_SECRET)"
if [ -n "$STORAGE_NODE" ]; then
    echo "  Storage:           local hostPath fallback on node $STORAGE_NODE (openan-local)"
else
    echo "  Storage:           cluster-provided StorageClass"
fi
echo "  Models:            $MODELS_RC / $MODELS_OC"
echo "  Signing:           $SIGNING"
echo "  Ingress host:      ${INGRESS_HOST:-<empty: direct LB-IP access>}"
echo "  Note: Secrets/ConfigMaps are already created; cancelling keeps them."
echo "=========================================="
if ! ask_yes_no "Deploy with this configuration?" "yes"; then
    log_info "Deployment cancelled. Values kept at: $VALUES"
    log_info "Redeploy later with: ./install.sh --values $VALUES --release $RELEASE --namespace $NAMESPACE --skip-build --skip-infra"
    exit 0
fi

# Agent examples server: interactive-only demo agents in the OC pod.
START_AGENTS_SERVER=false
if [ "$ORCHESTRATION_ENABLED" = true ] && ask_yes_no "Start the agent examples server (demo agents) after deploy?" "yes"; then
    START_AGENTS_SERVER=true
fi

if ! helm upgrade --install "$RELEASE" "$SCRIPT_DIR/openan-chart" \
        --namespace "$NAMESPACE" --create-namespace --values "$VALUES" \
        --wait --timeout 10m; then
    log_error "Helm deploy failed; inspect with: kubectl -n $NAMESPACE get pods"
    exit 1
fi

# Optional agent examples server: demo agents run inside the OC pod via
# kubectl exec + nohup, mirroring the offline installer. Convenience only:
# not a chart resource and it does not survive pod restarts/recreation.
if [ "$START_AGENTS_SERVER" = true ]; then
    log_step "Starting agent examples server"
    ORCH_POD="$(kubectl get pods -l app=orchestration-center -n "$NAMESPACE" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$ORCH_POD" ]; then
        log_warn "No orchestration-center pod found; skipping the agents server"
    elif kubectl exec "$ORCH_POD" -n "$NAMESPACE" -- /bin/sh -c \
        "cd /opt/orchestration-center && PYTHONPATH=/opt/orchestration-center nohup python3 samples/start_agents_server.py > /tmp/agents-server.log 2>&1 &" 2>/dev/null; then
        log_info "Agents server start requested in $ORCH_POD; waiting for port 8903..."
        AGENTS_OK=false
        for _ in $(seq 1 12); do
            if kubectl exec "$ORCH_POD" -n "$NAMESPACE" -- /bin/sh -c \
                "curl -sf http://127.0.0.1:8903/health > /dev/null" 2>/dev/null; then
                AGENTS_OK=true
                break
            fi
            sleep 5
        done
        if [ "$AGENTS_OK" = true ]; then
            log_info "Agent examples server healthy (port 8903)"
        else
            log_warn "Agents server not healthy after 60s; check: kubectl exec $ORCH_POD -n $NAMESPACE -- cat /tmp/agents-server.log"
        fi
    else
        log_warn "Could not start the agents server (samples/start_agents_server.py may be absent from the image)"
    fi
fi

# Access summary: LoadBalancer IP preferred, NodePort fallback (no secrets).
INGRESS_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

echo ""
echo "=========================================="
echo "  Install complete"
echo "=========================================="
if [ -n "$INGRESS_IP" ]; then
    if [ -n "$INGRESS_HOST" ]; then
        echo "  Platform:   ${SCHEME}://${INGRESS_HOST}/"
        echo "  Ingress IP: ${INGRESS_IP} (point DNS or an /etc/hosts entry for ${INGRESS_HOST} at it)"
    else
        echo "  Platform: ${SCHEME}://${INGRESS_IP}/"
    fi
    if [ "$SCHEME" = "https" ]; then
        echo "  HTTPS: enabled in values (ingress.tls)"
    fi
else
    NODE_PORT="$(kubectl -n "$NAMESPACE" get svc openan-frontend \
        -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
    if [ -n "$NODE_PORT" ] && [ "$FRONTEND_ENABLED" = true ]; then
        NODE_IP="$(kubectl get nodes \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
        if [ -n "$NODE_IP" ]; then
            echo "  Platform (NodePort): http://${NODE_IP}:${NODE_PORT}/"
            echo "  No LoadBalancer IP; the NodePort serves the frontend only"
        else
            echo "  NodePort: ${NODE_PORT} (node IP could not be detected)"
        fi
    else
        log_warn "No LoadBalancer IP and no frontend NodePort (frontend disabled or not ready)"
    fi
fi
if [ "$ORCHESTRATION_ENABLED" = true ]; then
    echo "  Login:     use the admin account configured in the wizard, then change the password in the web UI"
fi
echo "  Status:    kubectl -n $NAMESPACE get pods"
echo "  Ingress:   kubectl -n $NAMESPACE get ingress"
echo "  Uninstall: helm uninstall $RELEASE -n $NAMESPACE (or bash $SCRIPT_DIR/uninstall.sh)"
echo ""
