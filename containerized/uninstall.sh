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
DETECTED_HOSTPATH=""
DETECTED_HOSTPATH_NODE=""

detect_installation() {
    DETECTED_RESOURCES=()
    DETECTED_HOSTPATH=""
    DETECTED_HOSTPATH_NODE=""
    
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
    
    # Check PVs created by OpenAN
    if kubectl get pv openan-postgres-pv &>/dev/null; then
        DETECTED_RESOURCES+=("pv")
        log_info "Found PV: openan-postgres-pv"
        
        # Check if PV uses hostPath
        local pv_hostpath
        pv_hostpath=$(kubectl get pv openan-postgres-pv -o jsonpath='{.spec.hostPath.path}' 2>/dev/null)
        if [ -n "$pv_hostpath" ]; then
            DETECTED_RESOURCES+=("hostpath")
            DETECTED_HOSTPATH="$pv_hostpath"
            log_info "Found hostPath storage: $pv_hostpath"
            
            # Detect target node from nodeAffinity
            local node
            node=$(kubectl get pv openan-postgres-pv -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null)
            if [ -n "$node" ]; then
                DETECTED_HOSTPATH_NODE="$node"
                log_info "hostPath pinned to node: $node"
            fi
        fi
    fi
    
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

remove_data() {
    log_step "Removing persistent data..."
    
    # Use pre-detected hostPath info
    local hostpath_enabled=false
    local hostpath_dir=""
    local target_node=""
    
    if [[ " ${DETECTED_RESOURCES[*]} " =~ " hostpath " ]]; then
        hostpath_enabled=true
        hostpath_dir="$DETECTED_HOSTPATH"
        target_node="$DETECTED_HOSTPATH_NODE"
    fi
    
    # If node not detected from PV, try to get from postgres pod
    if [ "$hostpath_enabled" = true ] && [ -z "$target_node" ]; then
        target_node=$(kubectl get pod openan-postgres-0 -n "$CONFIG_NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
        if [ -n "$target_node" ]; then
            DETECTED_HOSTPATH_NODE="$target_node"
        fi
    fi
    
    # Remove PVCs
    local pvcs
    pvcs=$(kubectl get pvc -n "$CONFIG_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -n "$pvcs" ]; then
        for pvc in $pvcs; do
            kubectl delete pvc "$pvc" -n "$CONFIG_NAMESPACE"
            log_info "Deleted PVC: $pvc"
        done
    fi
    
    # Remove PV
    if kubectl get pv openan-postgres-pv &>/dev/null; then
        kubectl delete pv openan-postgres-pv
        log_info "Deleted PV: openan-postgres-pv"
    fi
    
    # Remove StorageClass
    if kubectl get storageclass openan-local &>/dev/null; then
        kubectl delete storageclass openan-local
        log_info "Deleted StorageClass: openan-local"
    fi
    
    # Handle hostPath data cleanup
    if [ "$hostpath_enabled" = true ] && [ -n "$target_node" ]; then
        log_info "Detected hostPath storage on node: $target_node"
        log_info "Path: $hostpath_dir"
        
        # Try to auto-clean using a privileged Job
        log_info "Attempting to auto-clean hostPath data..."
        
        local job_name="openan-cleanup-$(date +%s)"
        
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
        command: ['sh', '-c', 'rm -rf /hostpath${hostpath_dir}']
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
                    break
                fi
                sleep 5
                wait_count=$((wait_count + 1))
            done
            
            # Check if job failed or timed out
            if [ "$wait_count" -ge 6 ]; then
                log_warn "Auto-cleanup timed out or failed"
                log_warn "Manual cleanup required on node '$target_node':"
                log_warn "  ssh $target_node"
                log_warn "  sudo rm -rf $hostpath_dir"
                kubectl delete job "$job_name" -n "$CONFIG_NAMESPACE" --ignore-not-found
            fi
        else
            log_warn "Failed to create cleanup job"
            log_warn "Manual cleanup required on node '$target_node':"
            log_warn "  ssh $target_node"
            log_warn "  sudo rm -rf $hostpath_dir"
        fi
    elif [ "$hostpath_enabled" = true ]; then
        log_warn "hostPath storage detected but could not determine target node"
        log_warn "Manual cleanup may be required on cluster nodes:"
        log_warn "  sudo rm -rf $hostpath_dir"
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
        echo "  Detected hostPath storage: $DETECTED_HOSTPATH"
        if [ -n "$DETECTED_HOSTPATH_NODE" ]; then
            echo "  Located on node: $DETECTED_HOSTPATH_NODE"
        fi
    fi
    if ask_yes_no "Remove persistent data (PVCs, PVs, StorageClass, hostPath)?" "no"; then
        CONFIG_REMOVE_DATA=true
        echo "  - Will remove: PVCs, PV, StorageClass"
        if [[ " ${DETECTED_RESOURCES[*]} " =~ " hostpath " ]]; then
            echo "  - Will attempt to clean hostPath data"
        fi
    else
        echo "  - Will preserve: PVCs, PV, StorageClass"
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
    echo "    - Remove persistent data: PVCs, PV, StorageClass"
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
    if kubectl get pv openan-postgres-pv &>/dev/null; then
        log_info "  kubectl delete pv openan-postgres-pv"
    fi
    echo ""
fi

if [ "$CONFIG_REMOVE_NAMESPACE" = false ]; then
    log_info "Namespace preserved. To remove later:"
    log_info "  kubectl delete namespace $CONFIG_NAMESPACE"
    echo ""
fi

log_info "OpenAN platform has been uninstalled"
echo ""
