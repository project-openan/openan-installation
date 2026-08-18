# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

#!/bin/bash
# OpenAN Platform - One-click Setup Script
# Interactive setup: environment check, build, and deploy

set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
CHART_DIR="$SCRIPT_DIR/openan-chart"

# Ensure scripts are executable
chmod +x "$BUILD_DIR/build.sh" 2>/dev/null || true

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_prompt(){ echo -e "${BLUE}[?]${NC} $1"; }

# ===== Configuration =====
CONFIG_REGISTRY=true
CONFIG_ORCHESTRATION=true
CONFIG_K8S_NAMESPACE="openan"

# LLM Configuration for Registry Center
CONFIG_REGISTRY_CHAT_MODEL=""
CONFIG_REGISTRY_CHAT_URL=""
CONFIG_REGISTRY_CHAT_APIKEY=""

# LLM Configuration for Orchestration Center
CONFIG_ORCH_CHAT_MODEL=""
CONFIG_ORCH_CHAT_URL=""
CONFIG_ORCH_CHAT_APIKEY=""

CONFIG_DB_PASSWORD="openan-db-password"
CONFIG_INGRESS_HOST="openan.local"
CONFIG_START_AGENTS_SERVER=false

# ===== Helper Functions =====
ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local answer
    
    if [ "$default" = "yes" ]; then
        log_prompt "$prompt [Y/n]:" >&2
        read -r answer
        if [ -z "$answer" ]; then
            answer="y"
        fi
    else
        log_prompt "$prompt [y/N]:" >&2
        read -r answer
        if [ -z "$answer" ]; then
            answer="n"
        fi
    fi
    
    [[ "$answer" =~ ^[Yy] ]]
}

ask_input() {
    local prompt="$1"
    local default="$2"
    local value
    
    if [ -n "$default" ]; then
        log_prompt "$prompt [$default]:" >&2
    else
        log_prompt "$prompt:" >&2
    fi
    read -r value >&2
    echo "${value:-$default}"
}

ask_input_secret() {
    local prompt="$1"
    local default="$2"
    local value
    
    if [ -n "$default" ]; then
        log_prompt "$prompt [****]:" >&2
    else
        log_prompt "$prompt:" >&2
    fi
    read -s -r value >&2
    echo "" >&2
    echo "${value:-$default}"
}

validate_llm() {
    local model="$1"
    local url="$2"
    local api_key="$3"
    
    local test_url="${url}"
    if [[ "${test_url}" != */chat/completions ]]; then
        test_url="${test_url%/}/chat/completions"
    fi
    
    log_info "Validating LLM connection..." >&2
    log_info "  URL:   $test_url" >&2
    log_info "  Model: $model" >&2
    
    local tmp_resp http_code body
    tmp_resp=$(mktemp /tmp/llm-validate-XXXXXX)
    http_code=$(curl -s -o "${tmp_resp}" -w "%{http_code}" \
        -X POST "${test_url}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${api_key}" \
        -d "{\"model\": \"${model}\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}], \"max_tokens\": 1}" \
        --connect-timeout 10 \
        --max-time 30 2>/dev/null) || http_code="000"
    body=$(cat "${tmp_resp}" 2>/dev/null)
    rm -f "${tmp_resp}"
    
    case "${http_code}" in
        200|201)
            log_info "  [OK] LLM API validation successful (HTTP ${http_code})." >&2
            return 0
            ;;
        401|403)
            log_error "  Authentication failed (HTTP ${http_code}) - invalid API key." >&2
            [ -n "${body}" ] && log_info "  Response: $(printf '%.200s' "${body}")" >&2
            return 1
            ;;
        404)
            log_error "  Endpoint not found (HTTP 404) - invalid API URL." >&2
            log_info "  Tried: ${test_url}" >&2
            [ -n "${body}" ] && log_info "  Response: $(printf '%.200s' "${body}")" >&2
            return 1
            ;;
        000)
            log_error "  Cannot connect to ${test_url}." >&2
            log_info "  Please check the URL and your network connection." >&2
            return 1
            ;;
        *)
            log_error "  Validation failed (HTTP ${http_code})." >&2
            [ -n "${body}" ] && log_info "  Response: $(printf '%.200s' "${body}")" >&2
            return 1
            ;;
    esac
}

ask_llm_config() {
    local component_name="$1"
    local -n model_ref=$2
    local -n url_ref=$3
    local -n apikey_ref=$4
    
    echo ""
    log_info "Chat Model:"
    model_ref=$(ask_input "  Model name (e.g., gpt-4, claude-3-opus)" "")
    url_ref=$(ask_input "  API URL (e.g., https://api.openai.com/v1/chat/completions)" "")
    apikey_ref=$(ask_input_secret "  API Key" "")
    
    if [ -z "$model_ref" ] || [ -z "$url_ref" ] || [ -z "$apikey_ref" ]; then
        log_warn "LLM configuration incomplete, skipping validation."
        return 0
    fi
    
    while true; do
        echo ""
        log_info "Validating $component_name LLM configuration..."
        if validate_llm "$model_ref" "$url_ref" "$apikey_ref"; then
            log_info "LLM configuration validated successfully."
            return 0
        fi
        
        echo ""
        log_warn "Validation failed. Please choose an option:"
        echo "  1. Re-enter configuration"
        echo "  2. Skip validation and continue"
        echo "  3. Cancel $component_name configuration"
        read -r -p "  Enter choice [1/2/3]: " choice
        
        case "$choice" in
            1)
                echo ""
                log_info "Chat Model:"
                model_ref=$(ask_input "  Model name (e.g., gpt-4, claude-3-opus)" "$model_ref")
                url_ref=$(ask_input "  API URL (e.g., https://api.openai.com/v1/chat/completions)" "$url_ref")
                apikey_ref=$(ask_input_secret "  API Key" "")
                if [ -z "$model_ref" ] || [ -z "$url_ref" ] || [ -z "$apikey_ref" ]; then
                    log_warn "LLM configuration incomplete, skipping validation."
                    return 0
                fi
                ;;
            2)
                log_warn "Validation skipped. The configuration may not work correctly."
                return 0
                ;;
            3)
                log_info "$component_name LLM configuration cancelled."
                model_ref=""
                url_ref=""
                apikey_ref=""
                return 0
                ;;
            *)
                log_warn "Invalid choice, please try again."
                ;;
        esac
    done
}

ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice
    
    echo "" >&2
    log_prompt "$prompt" >&2
    for i in "${!options[@]}"; do
        echo "  $((i+1)). ${options[$i]}" >&2
    done
    read -r choice >&2
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
        echo "${options[$((choice-1))]}"
    else
        echo "${options[0]}"
    fi
}

# ===== Environment Check =====
check_docker() {
    if command -v docker &> /dev/null; then
        local version=$(sudo docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        log_info "Docker installed: $version"
        return 0
    else
        log_error "Docker not found"
        return 1
    fi
}

check_kubectl() {
    if command -v kubectl &> /dev/null; then
        local version
        version=$(kubectl version --client -o json 2>/dev/null | grep -oP '"gitVersion":\s*"v\K[^"]+' | head -1)
        if [ -z "$version" ]; then
            version=$(kubectl version --client 2>/dev/null | grep -oP 'Client Version:.*?v\K[^\s]+' | head -1)
        fi
        
        local major
        local minor
        major=$(echo "$version" | cut -d. -f1)
        minor=$(echo "$version" | cut -d. -f2)
        
        if [ -n "$major" ] && [ -n "$minor" ]; then
            if [ "$major" -lt 1 ] || ([ "$major" -eq 1 ] && [ "$minor" -lt 25 ]); then
                log_error "kubectl version $version is too old (requires 1.25+)"
                return 1
            fi
        fi
        
        log_info "kubectl installed: $version"
        return 0
    else
        log_error "kubectl not found"
        return 1
    fi
}

check_helm() {
    if command -v helm &> /dev/null; then
        local version=$(helm version --short 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        local major=$(echo "$version" | cut -d. -f1)
        local minor=$(echo "$version" | cut -d. -f2)
        
        if [ "$major" -lt 3 ] || ([ "$major" -eq 3 ] && [ "$minor" -lt 10 ]); then
            log_error "Helm version $version is too old (requires 3.10.0+)"
            return 1
        fi
        
        log_info "Helm installed: $version"
        return 0
    else
        log_error "Helm not found"
        return 1
    fi
}

check_k8s_cluster() {
    if kubectl cluster-info &> /dev/null; then
        log_info "Kubernetes cluster accessible"
        return 0
    else
        log_error "Cannot access Kubernetes cluster"
        return 1
    fi
}

check_ingress_controller() {
    if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller &> /dev/null; then
        log_info "Nginx Ingress Controller found"
        return 0
    elif kubectl get pods -n kube-system -l app.kubernetes.io/name=ingress-nginx &> /dev/null; then
        log_info "Nginx Ingress Controller found (kube-system)"
        return 0
    else
        log_warn "Nginx Ingress Controller not found"
        return 1
    fi
}

install_dependency() {
    local dep="$1"
    
    echo ""
    log_step "Installing $dep..."
    
    case "$dep" in
        docker)
            if [[ "$OSTYPE" == "linux-gnu"* ]]; then
                log_info "Installing Docker on Linux..."
                curl -fsSL https://get.docker.com | sh
                sudo usermod -aG docker $USER
                sudo systemctl start docker
                sudo systemctl enable docker
                log_info "Docker service started"
            elif [[ "$OSTYPE" == "darwin"* ]]; then
                log_error "Please install Docker Desktop manually:"
                log_info "  brew install --cask docker"
                log_info "  Or download from: https://docs.docker.com/desktop/install/mac-install/"
                return 1
            else
                log_error "Automatic Docker installation not supported on this platform"
                return 1
            fi
            ;;
        kubectl)
            if [[ "$OSTYPE" == "linux-gnu"* ]]; then
                # Detect architecture
                ARCH=$(uname -m)
                case $ARCH in
                    x86_64)  ARCH="amd64" ;;
                    aarch64) ARCH="arm64" ;;
                    armv7l)  ARCH="arm" ;;
                    *)       log_error "Unsupported architecture: $ARCH"; return 1 ;;
                esac
                curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
                sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
                rm -f kubectl
            elif [[ "$OSTYPE" == "darwin"* ]]; then
                if command -v brew &> /dev/null; then
                    brew install kubectl
                else
                    # Detect architecture for macOS
                    ARCH=$(uname -m)
                    case $ARCH in
                        x86_64)  ARCH="amd64" ;;
                        arm64)   ARCH="arm64" ;;
                        *)       log_error "Unsupported architecture: $ARCH"; return 1 ;;
                    esac
                    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/${ARCH}/kubectl"
                    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
                    rm -f kubectl
                fi
            else
                log_error "Automatic kubectl installation not supported on this platform"
                return 1
            fi
            ;;
        helm)
            if [[ "$OSTYPE" == "darwin"* ]] && command -v brew &> /dev/null; then
                brew install helm
            else
                curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            fi
            ;;
        ingress-nginx)
            log_info "Installing Nginx Ingress Controller..."
            kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml
            log_info "Waiting for Ingress Controller to be ready..."
            kubectl wait --namespace ingress-nginx \
                --for=condition=ready pod \
                --selector=app.kubernetes.io/component=controller \
                --timeout=120s
            ;;
    esac
    
    return $?
}

verify_installation() {
    local dep="$1"
    
    case "$dep" in
        docker)
            if sudo docker info &> /dev/null; then
                return 0
            fi
            ;;
        kubectl)
            if command -v kubectl &> /dev/null; then
                return 0
            fi
            ;;
        helm)
            if command -v helm &> /dev/null; then
                return 0
            fi
            ;;
        ingress-nginx)
            if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q "Running"; then
                return 0
            fi
            ;;
    esac
    
    return 1
}

# ===== LoadBalancer Detection & MetalLB =====
INGRESS_IP=""
LB_STATUS=""

check_loadbalancer() {
    local svc_type
    svc_type=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
        -o jsonpath='{.spec.type}' 2>/dev/null)

    if [ "$svc_type" = "LoadBalancer" ]; then
        local ip
        ip=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ -n "$ip" ]; then
            INGRESS_IP="$ip"
            LB_STATUS="Existing LB detected"
            log_info "LoadBalancer IP already assigned: $INGRESS_IP"
            return 0
        else
            log_info "Ingress Controller is LoadBalancer but no IP assigned yet"
            return 1
        fi
    elif [ "$svc_type" = "NodePort" ]; then
        log_info "Ingress Controller is NodePort, will switch to LoadBalancer"
        return 1
    else
        log_info "Ingress Controller Service type: $svc_type"
        return 1
    fi
}

install_metallb() {
    if kubectl get namespace metallb-system &>/dev/null; then
        log_info "MetalLB already installed (metallb-system namespace exists)"
    else
        log_info "Installing MetalLB..."
        helm repo add metallb https://metallb.github.io/metallb 2>/dev/null
        helm repo update 2>/dev/null
        if ! helm install metallb metallb/metallb -n metallb-system --create-namespace; then
            log_error "Failed to install MetalLB"
            return 1
        fi
    fi

    log_info "Waiting for MetalLB controller to be ready..."
    if ! kubectl wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=120s 2>/dev/null; then
        log_error "MetalLB controller not ready after 120s"
        return 1
    fi
    log_info "MetalLB controller ready"
    return 0
}

derive_metallb_pool() {
    local node_ip
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

    if [ -z "$node_ip" ]; then
        log_error "Cannot detect node IP for MetalLB pool"
        return 1
    fi

    log_info "Detected node IP: $node_ip"

    local prefix
    prefix=$(echo "$node_ip" | cut -d. -f1-3)

    local pool_start="${prefix}.200"
    local pool_end="${prefix}.250"

    local all_node_ips
    all_node_ips=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

    local excluded=""
    for ip in $all_node_ips; do
        local ip_prefix
        ip_prefix=$(echo "$ip" | cut -d. -f4)
        if [ "$ip_prefix" -ge 200 ] && [ "$ip_prefix" -le 250 ] 2>/dev/null; then
            excluded="$excluded $ip"
        fi
    done

    if [ -n "$excluded" ]; then
        log_warn "Node IPs in pool range (will be excluded by MetalLB):$excluded"
    fi

    METALLB_POOL="${pool_start}-${pool_end}"
    log_info "MetalLB IP pool: $METALLB_POOL"
}

configure_metallb() {
    log_info "Waiting for MetalLB CRDs to be ready..."
    local i
    for i in $(seq 1 12); do
        if kubectl get crd ipaddresspools.metallb.io &>/dev/null && \
           kubectl get crd l2advertisements.metallb.io &>/dev/null; then
            log_info "MetalLB CRDs found"
            break
        fi
        if [ "$i" -eq 12 ]; then
            log_error "MetalLB CRDs not ready after 60s"
            log_info "Checking MetalLB installation status..."
            kubectl get pods -n metallb-system
            kubectl get crd | grep metallb
            return 1
        fi
        sleep 5
    done
    
    log_info "Creating MetalLB IPAddressPool and L2Advertisement..."

    kubectl apply -f - <<EOF
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

    if [ $? -ne 0 ]; then
        log_error "Failed to create MetalLB configuration"
        log_info "Available MetalLB CRDs:"
        kubectl get crd | grep metallb
        return 1
    fi
    log_info "MetalLB configuration applied"
    return 0
}

wait_for_ingress_ip() {
    log_info "Waiting for LoadBalancer IP assignment..."
    local i
    for i in $(seq 1 12); do
        INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ -n "$INGRESS_IP" ]; then
            LB_STATUS="MetalLB installed"
            log_info "LoadBalancer IP assigned: $INGRESS_IP"
            return 0
        fi
        sleep 5
    done

    log_error "Timed out waiting for LoadBalancer IP (60s)"
    log_info "Check MetalLB status: kubectl get pods -n metallb-system"
    log_info "Check Service: kubectl get svc -n ingress-nginx ingress-nginx-controller"
    return 1
}

setup_loadbalancer() {
    if check_loadbalancer; then
        return 0
    fi

    if ! install_metallb; then
        return 1
    fi

    if ! derive_metallb_pool; then
        return 1
    fi

    if ! configure_metallb; then
        return 1
    fi

    local svc_type
    svc_type=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
        -o jsonpath='{.spec.type}' 2>/dev/null)
    if [ "$svc_type" != "LoadBalancer" ]; then
        log_info "Switching Ingress Controller Service to LoadBalancer..."
        kubectl patch svc ingress-nginx-controller -n ingress-nginx \
            -p '{"spec":{"type":"LoadBalancer"}}'
    fi

    if ! wait_for_ingress_ip; then
        return 1
    fi

    return 0
}

# ===== Main Setup Flow =====
echo ""
echo "=========================================="
echo "  OpenAN Platform - One-click Setup"
echo "=========================================="
echo ""

# Step 1: Environment Check
log_step "[1/5] Checking prerequisites and LoadBalancer..."
echo ""

MISSING_DEPS=()
FAILED_INSTALLS=()

# Check each dependency
check_kubectl || MISSING_DEPS+=("kubectl")
check_helm || MISSING_DEPS+=("helm")

# Check K8S cluster (requires kubectl)
if command -v kubectl &> /dev/null; then
    if ! check_k8s_cluster; then
        log_error "Cannot access Kubernetes cluster"
        log_info "Please configure kubeconfig first:"
        log_info "  export KUBECONFIG=~/.kube/config"
        log_info "  Or copy kubeconfig to ~/.kube/config"
        exit 1
    fi
else
    log_warn "kubectl not found, skipping cluster check"
    MISSING_DEPS+=("kubectl")
    MISSING_DEPS+=("k8s-cluster-check")
fi

# Check Ingress Controller (requires kubectl and cluster)
if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
    check_ingress_controller || MISSING_DEPS+=("ingress-nginx")
fi

# Check and setup LoadBalancer (requires kubectl, cluster, and ingress controller)
if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
    if kubectl get svc -n ingress-nginx ingress-nginx-controller &>/dev/null; then
        setup_loadbalancer || log_warn "LoadBalancer setup incomplete, will use default ingress host"
    fi
fi

# Install missing dependencies
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo ""
    log_warn "Missing dependencies: ${MISSING_DEPS[*]}"
    
    if ask_yes_no "Install missing dependencies automatically?" "yes"; then
        for dep in "${MISSING_DEPS[@]}"; do
            if [ "$dep" = "k8s-cluster-check" ]; then
                continue
            fi
            
            if install_dependency "$dep"; then
                # Verify installation
                if verify_installation "$dep"; then
                    log_info "✓ $dep installed and verified"
                else
                    log_warn "✗ $dep installed but verification failed"
                    FAILED_INSTALLS+=("$dep")
                fi
            else
                log_error "✗ Failed to install $dep"
                FAILED_INSTALLS+=("$dep")
            fi
        done
        
        # Re-check K8S cluster if kubectl was just installed
        if [[ " ${MISSING_DEPS[@]} " =~ " kubectl " ]]; then
            if ! check_k8s_cluster; then
                log_error "Still cannot access Kubernetes cluster"
                log_info "Please configure kubeconfig and re-run"
                exit 1
            fi
        fi
    else
        log_error "Please install dependencies manually:"
        if [[ "${MISSING_DEPS[*]}" =~ "docker" ]]; then
            log_info "  Docker: https://docs.docker.com/get-docker/"
        fi
        if [[ "${MISSING_DEPS[*]}" =~ "kubectl" ]]; then
            log_info "  kubectl: https://kubernetes.io/docs/tasks/tools/"
        fi
        if [[ "${MISSING_DEPS[*]}" =~ "helm" ]]; then
            log_info "  Helm: https://helm.sh/docs/intro/install/"
        fi
        if [[ "${MISSING_DEPS[*]}" =~ "ingress-nginx" ]]; then
            log_info "  Ingress: kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml"
        fi
        exit 1
    fi
fi

# Check for failed installations
if [ ${#FAILED_INSTALLS[@]} -gt 0 ]; then
    echo ""
    log_error "Some dependencies failed to install: ${FAILED_INSTALLS[*]}"
    log_info "Please install them manually and re-run"
    exit 1
fi

echo ""
log_info "All prerequisites satisfied!"

# Step 2: Component Selection
echo ""
log_step "[2/5] Select components to deploy:"
echo ""
log_prompt "Components:"
echo "  1. All components (Registry Center + Orchestration Center + Workflow Designer)"
echo "  2. Registry Center only"
echo "  3. Orchestration Center + Workflow Designer only"
read -r choice

case "$choice" in
    1) CONFIG_REGISTRY=true; CONFIG_ORCHESTRATION=true ;;
    2) CONFIG_REGISTRY=true; CONFIG_ORCHESTRATION=false ;;
    3) CONFIG_REGISTRY=false; CONFIG_ORCHESTRATION=true ;;
    *) CONFIG_REGISTRY=true; CONFIG_ORCHESTRATION=true ;;
esac

# Registry Center URL Configuration (when not deploying registry locally)
if [ "$CONFIG_REGISTRY" = false ] && [ "$CONFIG_ORCHESTRATION" = true ]; then
    echo ""
    log_step "Registry Center Connection:"
    log_info "Orchestration Center needs to connect to a Registry Center."
    CONFIG_REGISTRY_URL=$(ask_input "  Registry Center URL" "https://127.0.0.1:5000")
fi

# Step 3: LLM Configuration for Registry Center
if [ "$CONFIG_REGISTRY" = true ]; then
    echo ""
    log_step "[3/5] Registry Center LLM Configuration:"
    ask_llm_config "Registry Center" CONFIG_REGISTRY_CHAT_MODEL CONFIG_REGISTRY_CHAT_URL CONFIG_REGISTRY_CHAT_APIKEY
fi

# Step 4: LLM Configuration for Orchestration Center
if [ "$CONFIG_ORCHESTRATION" = true ]; then
    echo ""
    log_step "[4/5] Orchestration Center LLM Configuration:"
    
    if [ "$CONFIG_REGISTRY" = true ] && [ -n "$CONFIG_REGISTRY_CHAT_APIKEY" ]; then
        echo ""
        if ask_yes_no "Use same LLM config for Orchestration Center?" "yes"; then
            CONFIG_ORCH_CHAT_MODEL="$CONFIG_REGISTRY_CHAT_MODEL"
            CONFIG_ORCH_CHAT_URL="$CONFIG_REGISTRY_CHAT_URL"
            CONFIG_ORCH_CHAT_APIKEY="$CONFIG_REGISTRY_CHAT_APIKEY"
            log_info "Using same LLM config as Registry Center."
            
            echo ""
            log_info "Validating Orchestration Center LLM configuration..."
            if ! validate_llm "$CONFIG_ORCH_CHAT_MODEL" "$CONFIG_ORCH_CHAT_URL" "$CONFIG_ORCH_CHAT_APIKEY"; then
                log_warn "Validation failed for reused config. You can reconfigure later."
            fi
        else
            ask_llm_config "Orchestration Center" CONFIG_ORCH_CHAT_MODEL CONFIG_ORCH_CHAT_URL CONFIG_ORCH_CHAT_APIKEY
        fi
    else
        ask_llm_config "Orchestration Center" CONFIG_ORCH_CHAT_MODEL CONFIG_ORCH_CHAT_URL CONFIG_ORCH_CHAT_APIKEY
    fi
fi

# Step 5: Agent Examples Server
if [ "$CONFIG_ORCHESTRATION" = true ]; then
    echo ""
    log_step "[5/5] Agent Examples Configuration:"
    if ask_yes_no "Start agent examples server (required for demo agents)?" "yes"; then
        CONFIG_START_AGENTS_SERVER=true
    else
        CONFIG_START_AGENTS_SERVER=false
    fi
fi

# ===== Summary =====
echo ""
echo "=========================================="
echo "  Configuration Summary"
echo "=========================================="
echo ""
echo "  Components:"
if [ "$CONFIG_REGISTRY" = true ]; then
    echo "    - Registry Center"
fi
if [ "$CONFIG_ORCHESTRATION" = true ]; then
    echo "    - Orchestration Center"
    echo "    - Workflow Designer"
fi

if [ "$CONFIG_REGISTRY" = false ] && [ "$CONFIG_ORCHESTRATION" = true ] && [ -n "$CONFIG_REGISTRY_URL" ]; then
    echo ""
    echo "  Registry Connection:"
    echo "    URL: $CONFIG_REGISTRY_URL"
fi

echo ""
echo "  LLM Configuration:"
if [ "$CONFIG_REGISTRY" = true ]; then
    echo "    Registry Center:"
    echo "      Chat:   $CONFIG_REGISTRY_CHAT_MODEL"
fi
if [ "$CONFIG_ORCHESTRATION" = true ]; then
    echo "    Orchestration Center:"
    echo "      Chat:   $CONFIG_ORCH_CHAT_MODEL"
fi

if [ "$CONFIG_ORCHESTRATION" = true ]; then
    echo ""
    echo "  Agent Examples Server: $CONFIG_START_AGENTS_SERVER"
fi

if [ -n "$LB_STATUS" ]; then
    echo ""
    echo "  LoadBalancer:"
    echo "    Status: $LB_STATUS"
    echo "    IP: ${INGRESS_IP:-Pending}"
fi

echo ""
echo "=========================================="
echo ""

if ! ask_yes_no "Proceed with setup?" "yes"; then
    log_info "Setup cancelled"
    exit 0
fi

# ===== Execute Setup =====

log_step "Deploying with Helm..."

HELM_ARGS=""
if [ "$CONFIG_REGISTRY" = true ]; then
    HELM_ARGS="$HELM_ARGS --set registry.enabled=true"
else
    HELM_ARGS="$HELM_ARGS --set registry.enabled=false"
fi
if [ "$CONFIG_ORCHESTRATION" = true ]; then
    HELM_ARGS="$HELM_ARGS --set orchestration.enabled=true --set frontend.enabled=true"
else
    HELM_ARGS="$HELM_ARGS --set orchestration.enabled=false --set frontend.enabled=false"
fi

if [ "$CONFIG_REGISTRY" = true ]; then
    # Registry LLM Chat
    if [ -n "$CONFIG_REGISTRY_CHAT_MODEL" ]; then
        HELM_ARGS="$HELM_ARGS --set registry.llm.chat.model=$CONFIG_REGISTRY_CHAT_MODEL"
        if [ -n "$CONFIG_REGISTRY_CHAT_URL" ]; then
            HELM_ARGS="$HELM_ARGS --set registry.llm.chat.url=$CONFIG_REGISTRY_CHAT_URL"
        fi
        if [ -n "$CONFIG_REGISTRY_CHAT_APIKEY" ]; then
            HELM_ARGS="$HELM_ARGS --set registry.llm.chat.apiKey=$CONFIG_REGISTRY_CHAT_APIKEY"
        fi
    fi
fi

if [ "$CONFIG_ORCHESTRATION" = true ]; then
    # External Registry URL (when not deploying registry locally)
    if [ "$CONFIG_REGISTRY" = false ] && [ -n "$CONFIG_REGISTRY_URL" ]; then
        HELM_ARGS="$HELM_ARGS --set orchestration.agentRegistryUrl=$CONFIG_REGISTRY_URL"
    fi
    
    # Orchestration LLM Chat
    if [ -n "$CONFIG_ORCH_CHAT_MODEL" ]; then
        HELM_ARGS="$HELM_ARGS --set orchestration.llm.chat.model=$CONFIG_ORCH_CHAT_MODEL"
        if [ -n "$CONFIG_ORCH_CHAT_URL" ]; then
            HELM_ARGS="$HELM_ARGS --set orchestration.llm.chat.url=$CONFIG_ORCH_CHAT_URL"
        fi
        if [ -n "$CONFIG_ORCH_CHAT_APIKEY" ]; then
            HELM_ARGS="$HELM_ARGS --set orchestration.llm.chat.apiKey=$CONFIG_ORCH_CHAT_APIKEY"
        fi
    fi
fi

HELM_ARGS="$HELM_ARGS --set postgresql.password=$CONFIG_DB_PASSWORD"
if [ -n "$INGRESS_IP" ]; then
    log_info "Using LoadBalancer IP: $INGRESS_IP"
else
    HELM_ARGS="$HELM_ARGS --set ingress.host=$CONFIG_INGRESS_HOST"
fi

# Check if default StorageClass exists
if kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | grep -q .; then
    log_info "Default StorageClass found, using existing storage"
else
    log_info "No default StorageClass found, creating PV with hostPath"
    HELM_ARGS="$HELM_ARGS --set postgresql.storage.createPV=true"
    HELM_ARGS="$HELM_ARGS --set postgresql.storage.useHostPath=true"
    HELM_ARGS="$HELM_ARGS --set postgresql.storage.hostPath=/data/openan-postgres"
fi

cd "$CHART_DIR"

# Check if release already exists
if helm status openan -n "$CONFIG_K8S_NAMESPACE" &>/dev/null 2>&1; then
    log_info "Upgrading existing release..."
    if ! helm upgrade openan . \
        -n "$CONFIG_K8S_NAMESPACE" \
        $HELM_ARGS; then
        log_error "Helm upgrade failed"
        exit 1
    fi
else
    log_info "Installing new release..."
    if ! helm install openan . \
        -n "$CONFIG_K8S_NAMESPACE" \
        --create-namespace \
        $HELM_ARGS; then
        log_error "Helm install failed"
        exit 1
    fi
fi

# ===== Start Agents Server =====
if [ "$CONFIG_ORCHESTRATION" = true ] && [ "$CONFIG_START_AGENTS_SERVER" = true ]; then
    echo ""
    log_step "Starting Agent Examples Server..."
    
    log_info "Waiting for Registry Center to be ready..."
    
    # Wait for registry-center pod to be running
    kubectl wait --for=condition=ready pod -l app=registry-center -n "$CONFIG_K8S_NAMESPACE" --timeout=300s
    
    # Get the first orchestration-center pod name
    ORCH_POD=$(kubectl get pods -l app=orchestration-center -n "$CONFIG_K8S_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
    
    if [ -n "$ORCH_POD" ]; then
        log_info "Starting agents server in $ORCH_POD..."
        
        # Start agents server in background
        kubectl exec "$ORCH_POD" -n "$CONFIG_K8S_NAMESPACE" -- /bin/sh -c "cd /opt/orchestration-center && PYTHONPATH=/opt/orchestration-center nohup python3 samples/start_agents_server.py > /tmp/agents-server.log 2>&1 &"
        
        # Wait for agents server to start
        log_info "Waiting for agents server to initialize..."
        sleep 10
        
        # Verify agents server is running
        if kubectl exec "$ORCH_POD" -n "$CONFIG_K8S_NAMESPACE" -- /bin/sh -c "curl -s http://127.0.0.1:8903/health > /dev/null 2>&1"; then
            log_info "✓ Agents server started successfully (port 8903)"
        else
            log_warn "Agents server may not be ready yet. Check logs: kubectl exec $ORCH_POD -n $CONFIG_K8S_NAMESPACE -- cat /tmp/agents-server.log"
        fi
    else
        log_warn "Could not find orchestration-center pod"
    fi
fi

# ===== Final Summary =====
echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""

if [ -n "$INGRESS_IP" ]; then
    echo "  Access the platform (LoadBalancer):"
    echo "    - Workflow Designer: http://$INGRESS_IP/"
    echo "    - Registry API:      http://$INGRESS_IP/registry/rest/v1/registry-center/agent-cards"
    echo "    - Orchestration API: http://$INGRESS_IP/api/orchestrate/rest/v1/orchestrate/agent-cards"
else
    NODE_PORT=$(kubectl get svc -n "$CONFIG_K8S_NAMESPACE" workflow-designer -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    echo "  Access the platform (NodePort):"
    echo "    - Workflow Designer: http://$NODE_IP:$NODE_PORT/"
    echo ""
    echo "  Note: NodePort only provides frontend access. Use port-forwarding for API access."
fi

echo ""
echo "  Check status:"
echo "    kubectl -n $CONFIG_K8S_NAMESPACE get pods"
echo "    kubectl -n $CONFIG_K8S_NAMESPACE get ingress"
echo ""
echo "  Uninstall:"
echo "    helm uninstall openan -n $CONFIG_K8S_NAMESPACE"
echo ""
