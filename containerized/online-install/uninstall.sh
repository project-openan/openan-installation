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
# OpenAN Platform - One-click Uninstall Script
# Supports uninstalling with or without data cleanup

set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_prompt(){ echo -e "${BLUE}[?]${NC} $1"; }

# ===== Configuration =====
CONFIG_NAMESPACE="openan"
CONFIG_RELEASE_NAME="openan"
CONFIG_REMOVE_DATA=false
CONFIG_REMOVE_NAMESPACE=false

usage() {
    cat <<'EOF'
Usage: ./uninstall.sh [OPTIONS]

  --namespace NAME   namespace of the installation (default: openan)
  --release NAME     Helm release name (default: openan)
  --help, -h         show this help

Must match the --release/--namespace used by install.sh. The uninstaller
detects Helm release, namespace, PVCs, OpenAN PVs (labels, claim bindings
and local-fallback names), the openan-local StorageClass, MetalLB config and
hostPath data, and asks before removing anything.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --namespace|--release)
            [ $# -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }
            case "$1" in
                --namespace) CONFIG_NAMESPACE="$2" ;;
                --release) CONFIG_RELEASE_NAME="$2" ;;
            esac
            shift 2 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

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

# ===== Pre-flight Checks =====
check_prerequisites() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found"
        return 1
    fi
    
    if ! command -v helm &> /dev/null; then
        log_error "helm not found"
        return 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot access Kubernetes cluster"
        return 1
    fi
    
    log_info "Prerequisites satisfied"
    return 0
}

# ===== Detection Functions =====
DETECTED_PVS=()
DETECTED_HOSTPATHS=()   # entries of "path|node" (node may be empty)

scan_pv() {
    local pv="$1"
    local hostpath node
    # One PV can be found via label, claim binding and legacy name; scan once.
    if [[ " ${DETECTED_PVS[*]} " =~ " ${pv} " ]]; then
        return 0
    fi
    DETECTED_PVS+=("$pv")
    DETECTED_RESOURCES+=("pv")
    log_info "Found PV: $pv"
    hostpath=$(kubectl get pv "$pv" -o jsonpath='{.spec.hostPath.path}' 2>/dev/null)
    if [ -n "$hostpath" ]; then
        node=$(kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null)
        DETECTED_HOSTPATHS+=("${hostpath}|${node}")
        DETECTED_RESOURCES+=("hostpath")
        log_info "  hostPath: $hostpath (node: ${node:-unknown})"
    fi
}

detect_installation() {
    DETECTED_RESOURCES=()
    DETECTED_PVS=()
    DETECTED_HOSTPATHS=()
    
    # Check Helm release
    if helm status "$CONFIG_RELEASE_NAME" -n "$CONFIG_NAMESPACE" &>/dev/null; then
        DETECTED_RESOURCES+=("helm-release")
        log_info "Found Helm release: $CONFIG_RELEASE_NAME"
    else
        log_warn "Helm release '$CONFIG_RELEASE_NAME' not found in namespace '$CONFIG_NAMESPACE'"
    fi
    
    # Check namespace
    if kubectl get namespace "$CONFIG_NAMESPACE" &>/dev/null; then
        DETECTED_RESOURCES+=("namespace")
        log_info "Found namespace: $CONFIG_NAMESPACE"
    fi
    
    # Check PVCs
    local pvc_count
    pvc_count=$(kubectl get pvc -n "$CONFIG_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [ "$pvc_count" -gt 0 ]; then
        DETECTED_RESOURCES+=("pvcs")
        log_info "Found $pvc_count PVC(s) in namespace $CONFIG_NAMESPACE"
    fi
    
    # Check PVs created by or bound to OpenAN: chart labels first, then PVs
    # bound to this namespace's claims (covers manually created PVs), then
    # the well-known names used by the local-storage fallback.
    local pv
    while IFS= read -r pv; do
        [ -n "$pv" ] && scan_pv "$pv"
    done < <(kubectl get pv -l app.kubernetes.io/part-of=openan -o name 2>/dev/null | sed 's|^PersistentVolume/||')
    while IFS= read -r pv; do
        [ -n "$pv" ] && scan_pv "$pv"
    done < <(kubectl get pvc -n "$CONFIG_NAMESPACE" -o jsonpath='{range .items[*]}{.spec.volumeName}{"\n"}{end}' 2>/dev/null)
    for pv in openan-postgres-pv openan-mysql-pv openan-rc-pv openan-oc-pv; do
        kubectl get pv "$pv" &>/dev/null && scan_pv "$pv"
    done
    
    # Check StorageClass created by OpenAN
    if kubectl get storageclass openan-local &>/dev/null; then
        DETECTED_RESOURCES+=("storageclass")
        log_info "Found StorageClass: openan-local"
    fi
    
    # Check MetalLB resources
    if kubectl get ipaddresspool openan-pool -n metallb-system &>/dev/null; then
        DETECTED_RESOURCES+=("metallb-pool")
        log_info "Found MetalLB IPAddressPool: openan-pool"
    fi
    
    if kubectl get l2advertisement openan-l2 -n metallb-system &>/dev/null; then
        DETECTED_RESOURCES+=("metallb-l2")
        log_info "Found MetalLB L2Advertisement: openan-l2"
    fi
    
    if [ ${#DETECTED_RESOURCES[@]} -eq 0 ]; then
        log_warn "No OpenAN resources detected"
        return 1
    fi
    
    return 0
}

# ===== Uninstall Functions =====
uninstall_helm_release() {
    log_step "Uninstalling Helm release..."
    
    if helm status "$CONFIG_RELEASE_NAME" -n "$CONFIG_NAMESPACE" &>/dev/null; then
        if helm uninstall "$CONFIG_RELEASE_NAME" -n "$CONFIG_NAMESPACE"; then
            log_info "Helm release uninstalled"
        else
            log_error "Failed to uninstall Helm release"
            return 1
        fi
    else
        log_info "Helm release not found, skipping"
    fi
    
    return 0
}

remove_metallb_resources() {
    log_step "Removing MetalLB configuration..."
    
    # Remove IPAddressPool and L2Advertisement
    if kubectl get ipaddresspool openan-pool -n metallb-system &>/dev/null; then
        kubectl delete ipaddresspool openan-pool -n metallb-system
        log_info "Deleted IPAddressPool: openan-pool"
    fi
    
    if kubectl get l2advertisement openan-l2 -n metallb-system &>/dev/null; then
        kubectl delete l2advertisement openan-l2 -n metallb-system
        log_info "Deleted L2Advertisement: openan-l2"
    fi
    
    return 0
}

clean_hostpath_node() {
    local target_node="$1"
    local paths="$2"
    local suffix="$3"
    
    log_info "Detected hostPath storage on node: $target_node"
    log_info "Paths: $paths"
    
    # Try to auto-clean using a privileged Job (one job removes all paths on the node)
    log_info "Attempting to auto-clean hostPath data..."
    
    local job_name="openan-cleanup-$(date +%s)-$suffix"
    local rm_list="" p
    for p in $paths; do
        rm_list="$rm_list /hostpath${p}"
    done
    
    kubectl apply -f - <<EOF >/dev/null 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
  namespace: $CONFIG_NAMESPACE
spec:
  template:
    spec:
      nodeName: $target_node
      hostPID: true
      containers:
      - name: cleanup
        image: busybox:latest
        command: ['sh', '-c', 'rm -rf$rm_list']
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-root
          mountPath: /hostpath
      volumes:
      - name: host-root
        hostPath:
          path: /
          type: Directory
      restartPolicy: Never
  backoffLimit: 1
EOF
    
    if [ $? -eq 0 ]; then
        # Wait for job to complete (max 30s)
        local wait_count=0
        while [ $wait_count -lt 6 ]; do
            local job_status
            job_status=$(kubectl get job "$job_name" -n "$CONFIG_NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null)
            if [ "$job_status" = "1" ]; then
                log_info "Successfully cleaned hostPath data on node: $target_node"
                kubectl delete job "$job_name" -n "$CONFIG_NAMESPACE" --ignore-not-found
                return 0
            fi
            sleep 5
            wait_count=$((wait_count + 1))
        done
        
        # Job failed or timed out
        log_warn "Auto-cleanup timed out or failed on node '$target_node'"
        log_warn "Manual cleanup required:"
        log_warn "  ssh $target_node"
        for p in $paths; do
            log_warn "  sudo rm -rf $p"
        done
        kubectl delete job "$job_name" -n "$CONFIG_NAMESPACE" --ignore-not-found
    else
        log_warn "Failed to create cleanup job for node '$target_node'"
        log_warn "Manual cleanup required:"
        for p in $paths; do
            log_warn "  sudo rm -rf $p"
        done
    fi
}

remove_data() {
    log_step "Removing persistent data..."
    
    # Remove PVCs
    local pvcs
    pvcs=$(kubectl get pvc -n "$CONFIG_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -n "$pvcs" ]; then
        for pvc in $pvcs; do
            kubectl delete pvc "$pvc" -n "$CONFIG_NAMESPACE"
            log_info "Deleted PVC: $pvc"
        done
    fi
    
    # Remove every detected OpenAN PV (postgres, registry, orchestration, manual)
    local pv
    for pv in "${DETECTED_PVS[@]}"; do
        kubectl delete pv "$pv" 2>/dev/null
        log_info "Deleted PV: $pv"
    done
    
    # Remove StorageClass
    if kubectl get storageclass openan-local &>/dev/null; then
        kubectl delete storageclass openan-local
        log_info "Deleted StorageClass: openan-local"
    fi
    
    # Clean hostPath data: group directories by target node (one job per node)
    if [ ${#DETECTED_HOSTPATHS[@]} -gt 0 ]; then
        local entry path node i idx
        local -a cleanup_nodes=()
        local -a cleanup_paths=()
        for entry in "${DETECTED_HOSTPATHS[@]}"; do
            [ -n "$entry" ] || continue
            path="${entry%%|*}"
            node="${entry##*|}"
            if [ -z "$node" ]; then
                log_warn "hostPath '$path' has no node affinity; manual cleanup may be required:"
                log_warn "  sudo rm -rf $path"
                continue
            fi
            idx=""
            for i in "${!cleanup_nodes[@]}"; do
                if [ "${cleanup_nodes[$i]}" = "$node" ]; then
                    idx=$i
                    break
                fi
            done
            if [ -z "$idx" ]; then
                cleanup_nodes+=("$node")
                cleanup_paths+=("$path")
            else
                cleanup_paths[$idx]="${cleanup_paths[$idx]} $path"
            fi
        done
        
        for i in "${!cleanup_nodes[@]}"; do
            clean_hostpath_node "${cleanup_nodes[$i]}" "${cleanup_paths[$i]}" "$i"
        done
    fi
    
    return 0
}

remove_namespace() {
    log_step "Removing namespace..."
    
    if kubectl get namespace "$CONFIG_NAMESPACE" &>/dev/null; then
        kubectl delete namespace "$CONFIG_NAMESPACE"
        log_info "Namespace '$CONFIG_NAMESPACE' deleted"
    else
        log_info "Namespace not found, skipping"
    fi
    
    return 0
}

# ===== Main Flow =====
echo ""
echo "=========================================="
echo "  OpenAN Platform - Uninstall"
echo "=========================================="
echo ""

# Step 1: Pre-flight checks
log_step "[1/3] Checking prerequisites..."
if ! check_prerequisites; then
    exit 1
fi

# Step 2: Detect installation
echo ""
log_step "[2/3] Detecting OpenAN installation..."
if ! detect_installation; then
    log_error "No OpenAN resources found. Nothing to uninstall."
    exit 0
fi

# Step 3: User confirmation
echo ""
log_step "[3/3] Uninstall options:"
echo ""

# Ask about data removal
if [[ " ${DETECTED_RESOURCES[*]} " =~ " pvcs " ]] || [[ " ${DETECTED_RESOURCES[*]} " =~ " pv " ]]; then
    echo "Data cleanup:"
    if [[ " ${DETECTED_RESOURCES[*]} " =~ " hostpath " ]]; then
        hp_entry=""
        for hp_entry in "${DETECTED_HOSTPATHS[@]}"; do
            hp_node="${hp_entry##*|}"
            if [ -n "$hp_node" ]; then
                echo "  Detected hostPath: ${hp_entry%%|*} (node: $hp_node)"
            else
                echo "  Detected hostPath: ${hp_entry%%|*} (node unknown)"
            fi
        done
    fi
    if ask_yes_no "Remove persistent data (PVCs, PVs, StorageClass, hostPath)?" "no"; then
        CONFIG_REMOVE_DATA=true
        echo "  - Will remove: PVCs, PVs, StorageClass"
        if [[ " ${DETECTED_RESOURCES[*]} " =~ " hostpath " ]]; then
            echo "  - Will attempt to clean hostPath data"
        fi
    else
        echo "  - Will preserve: PVCs, PVs, StorageClass"
    fi
    echo ""
fi

# Ask about namespace removal
if [[ " ${DETECTED_RESOURCES[*]} " =~ " namespace " ]]; then
    echo "Namespace cleanup:"
    if ask_yes_no "Delete namespace '$CONFIG_NAMESPACE'? (Removes all remaining resources)" "yes"; then
        CONFIG_REMOVE_NAMESPACE=true
        echo "  - Will delete namespace: $CONFIG_NAMESPACE"
    else
        echo "  - Will preserve namespace: $CONFIG_NAMESPACE"
    fi
    echo ""
fi

# Summary
echo "=========================================="
echo "  Uninstall Summary"
echo "=========================================="
echo ""
echo "  Actions:"
echo "    - Uninstall Helm release: $CONFIG_RELEASE_NAME"
echo "    - Remove MetalLB configuration (if exists)"
if [ "$CONFIG_REMOVE_DATA" = true ]; then
    echo "    - Remove persistent data: PVCs, PVs, StorageClass"
else
    echo "    - Preserve persistent data"
fi
if [ "$CONFIG_REMOVE_NAMESPACE" = true ]; then
    echo "    - Delete namespace: $CONFIG_NAMESPACE"
fi
echo ""

if ! ask_yes_no "Proceed with uninstall?" "yes"; then
    log_info "Uninstall cancelled"
    exit 0
fi

# Execute uninstall
echo ""
log_step "Starting uninstall..."
echo ""

# 1. Uninstall Helm release
uninstall_helm_release

# 2. Remove MetalLB resources (before namespace deletion)
if [[ " ${DETECTED_RESOURCES[*]} " =~ " metallb-pool " ]] || [[ " ${DETECTED_RESOURCES[*]} " =~ " metallb-l2 " ]]; then
    remove_metallb_resources
fi

# 3. Remove data if requested
if [ "$CONFIG_REMOVE_DATA" = true ]; then
    remove_data
fi

# 4. Remove namespace if requested
if [ "$CONFIG_REMOVE_NAMESPACE" = true ]; then
    remove_namespace
fi

# Final summary
echo ""
echo "=========================================="
echo "  Uninstall Complete!"
echo "=========================================="
echo ""

if [ "$CONFIG_REMOVE_DATA" = false ]; then
    log_info "Persistent data preserved. To remove later:"
    log_info "  kubectl delete pvc -n $CONFIG_NAMESPACE --all"
    for preserved_pv in "${DETECTED_PVS[@]}"; do
        log_info "  kubectl delete pv $preserved_pv"
    done
    echo ""
fi

if [ "$CONFIG_REMOVE_NAMESPACE" = false ]; then
    log_info "Namespace preserved. To remove later:"
    log_info "  kubectl delete namespace $CONFIG_NAMESPACE"
    echo ""
fi

log_info "OpenAN platform has been uninstalled"
echo ""
