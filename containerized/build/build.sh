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
# OpenAN Platform - One-line Image Build Script
# Usage: ./build.sh [components] [options]
#   No arguments = build all components with defaults
#   Specify component names to build only those: registry, orchestration
#
# Components (positional):
#   registry          Build Registry Center only
#   orchestration     Build Orchestration Center + Workflow Designer only
#   (none)            Build all components
#
# Options:
#   --registry-release <url>   Registry Center release URL
#   --orchestration-release <url> Orchestration Center release URL
#   --image-registry <url>     Image registry (default: ghcr.io)
#   --namespace <ns>           Image namespace (default: project-openan)
#   --tag <tag>                Image tag (default: v1.0.0)
#   --platforms <platforms>    Target platforms (default: linux/amd64,linux/arm64)
#   --no-push                  Build local only (single-arch only)
#   --help                     Show help

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===== Defaults =====
IMAGE_REGISTRY="ghcr.io"
NAMESPACE="project-openan"
TAG="v1.0.0"
REGISTRY_RELEASE=""
ORCHESTRATION_RELEASE=""
PLATFORMS="linux/amd64,linux/arm64"
PUSH=true

BUILD_REGISTRY=false
BUILD_ORCHESTRATION=false
COMPONENTS_SPECIFIED=false

TEMP_DIR=""

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

show_help() {
    cat << EOF
OpenAN Platform - One-line Image Build

Usage: ./build.sh [components] [options]

Components (positional, specify any):
  registry          Build Registry Center only
  orchestration     Build Orchestration Center + Workflow Designer only
  (none)            Build all components

Options:
  --image-registry <url>     Image registry (default: ghcr.io)
  --namespace <ns>           Image namespace (default: project-openan)
  --tag <tag>                Image tag (default: v1.0.0)
  --registry-release <url>   Registry Center release tarball URL
  --orchestration-release <url>  Orchestration Center release tarball URL
  --platforms <platforms>    Target platforms (default: linux/amd64,linux/arm64)
  --no-push                  Build local only (single-arch only)
  --help                     Show help

Examples:
  ./build.sh                                                          # Build all components
  ./build.sh registry                                                 # Build Registry Center only
  ./build.sh orchestration                                            # Build Orchestration + Frontend only
  ./build.sh registry orchestration                                   # Same as default (both)
  ./build.sh --tag v1.1.0                                             # Custom tag, build all
  ./build.sh registry --image-registry harbor.example.com             # Private registry, registry only
  ./build.sh orchestration --platforms linux/amd64 --no-push          # Local single-arch, orchestration only
EOF
    exit 0
}

# ===== Parse arguments =====
while [[ $# -gt 0 ]]; do
    case $1 in
        registry)                BUILD_REGISTRY=true; COMPONENTS_SPECIFIED=true; shift ;;
        orchestration)           BUILD_ORCHESTRATION=true; COMPONENTS_SPECIFIED=true; shift ;;
        --image-registry)        IMAGE_REGISTRY="$2"; shift 2 ;;
        --namespace)             NAMESPACE="$2"; shift 2 ;;
        --tag)                   TAG="$2"; shift 2 ;;
        --registry-release)      REGISTRY_RELEASE="$2"; shift 2 ;;
        --orchestration-release) ORCHESTRATION_RELEASE="$2"; shift 2 ;;
        --platforms)             PLATFORMS="$2"; shift 2 ;;
        --no-push)               PUSH=false; shift ;;
        --help)                  show_help ;;
        *)                       log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# If no components specified, build all
if [ "$COMPONENTS_SPECIFIED" = false ]; then
    BUILD_REGISTRY=true
    BUILD_ORCHESTRATION=true
fi

# Auto-generate release URLs based on TAG if not explicitly specified
if [ -z "$REGISTRY_RELEASE" ]; then
    REGISTRY_RELEASE="https://github.com/project-openan/registry-center/archive/refs/tags/${TAG}.tar.gz"
fi
if [ -z "$ORCHESTRATION_RELEASE" ]; then
    ORCHESTRATION_RELEASE="https://github.com/project-openan/orchestration-center/archive/refs/tags/${TAG}.tar.gz"
fi

# Multi-arch requires push
if [[ "$PLATFORMS" == *","* ]] && [ "$PUSH" = false ]; then
    log_warn "Multi-arch images must be pushed to registry, enabling push automatically"
    PUSH=true
fi

# ===== Print configuration =====
COMPONENTS=""
if [ "$BUILD_REGISTRY" = true ]; then
    COMPONENTS="${COMPONENTS}registry-center "
fi
if [ "$BUILD_ORCHESTRATION" = true ]; then
    COMPONENTS="${COMPONENTS}orchestration-center workflow-designer"
fi

echo ""
echo "=========================================="
echo "  OpenAN Platform Image Build"
echo "=========================================="
echo ""
if [ "$BUILD_REGISTRY" = true ]; then
    echo "  Registry Center release:  $REGISTRY_RELEASE"
fi
if [ "$BUILD_ORCHESTRATION" = true ]; then
    echo "  Orchestration release:    $ORCHESTRATION_RELEASE"
fi
echo "  Image registry:           $IMAGE_REGISTRY"
echo "  Image namespace:          $NAMESPACE"
echo "  Image tag:                $TAG"
echo "  Platforms:                $PLATFORMS"
echo "  Push:                     $PUSH"
echo "  Components:               $COMPONENTS"
echo ""
echo "=========================================="
echo ""

TEMP_DIR=$(mktemp -d)

# ===== Download release packages =====
download_release() {
    local url=$1
    local name=$2
    local dest="$TEMP_DIR/$name"

    log_step "Downloading $name from release..."
    log_info "URL: $url"

    mkdir -p "$dest"
    curl -fSL --progress-bar -o "$TEMP_DIR/${name}.tar.gz" "$url"
    tar -xzf "$TEMP_DIR/${name}.tar.gz" -C "$dest"
    log_info "$name downloaded and extracted to $dest"
}

if [ "$BUILD_REGISTRY" = true ]; then
    download_release "$REGISTRY_RELEASE" "registry-center"
fi
if [ "$BUILD_ORCHESTRATION" = true ]; then
    download_release "$ORCHESTRATION_RELEASE" "orchestration-center"
fi

# ===== Detect source directories =====
REGISTRY_IMAGE="$IMAGE_REGISTRY/$NAMESPACE/registry-center:$TAG"
ORCHESTRATION_IMAGE="$IMAGE_REGISTRY/$NAMESPACE/orchestration-center:$TAG"
FRONTEND_IMAGE="$IMAGE_REGISTRY/$NAMESPACE/workflow-designer:$TAG"

RC_SRC=""
OC_SRC=""

detect_src_dir() {
    local base_dir="$1"
    # Check if Dockerfile is directly in base_dir
    if [ -f "$base_dir/Dockerfile" ]; then
        echo "$base_dir"
        return 0
    fi
    # Check subdirectories (GitHub archive extracts to repo-tag/ subfolder)
    for d in "$base_dir"/*/; do
        if [ -f "$d/Dockerfile" ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

if [ "$BUILD_REGISTRY" = true ]; then
    RC_SRC=$(detect_src_dir "$TEMP_DIR/registry-center") || true
    if [ -z "$RC_SRC" ]; then
        log_error "Cannot find Dockerfile for registry-center in $TEMP_DIR/registry-center"
        exit 1
    fi
    log_info "Registry Center source: $RC_SRC"
fi

if [ "$BUILD_ORCHESTRATION" = true ]; then
    OC_SRC=$(detect_src_dir "$TEMP_DIR/orchestration-center") || true
    if [ -z "$OC_SRC" ]; then
        log_error "Cannot find Dockerfile for orchestration-center in $TEMP_DIR/orchestration-center"
        exit 1
    fi
    log_info "Orchestration Center source: $OC_SRC"
fi

# ===== Build images =====
if ! docker buildx version &> /dev/null; then
    log_error "docker buildx not installed"
    exit 1
fi

if ! docker buildx inspect multiarch-builder &> /dev/null; then
    log_step "Creating buildx builder: multiarch-builder"
    docker buildx create --name multiarch-builder --use
else
    docker buildx use multiarch-builder
fi

BUILD_CMD="docker buildx build --platform $PLATFORMS"
if [ "$PUSH" = true ]; then
    BUILD_CMD="$BUILD_CMD --push"
else
    BUILD_CMD="$BUILD_CMD --load"
fi

TOTAL=0
if [ "$BUILD_REGISTRY" = true ] && [ -n "$RC_SRC" ]; then
    TOTAL=$((TOTAL + 1))
fi
if [ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ]; then
    TOTAL=$((TOTAL + 1))
fi
if [ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ] && [ -d "$OC_SRC/workflow-designer" ]; then
    TOTAL=$((TOTAL + 1))
fi
CURRENT=0

if [ "$BUILD_REGISTRY" = true ] && [ -n "$RC_SRC" ]; then
    CURRENT=$((CURRENT + 1))
    log_step "[$CURRENT/$TOTAL] Building Registry Center..."
    $BUILD_CMD -t "$REGISTRY_IMAGE" "$RC_SRC"
    log_info "Done: $REGISTRY_IMAGE"
fi

if [ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ]; then
    CURRENT=$((CURRENT + 1))
    log_step "[$CURRENT/$TOTAL] Building Orchestration Center..."
    $BUILD_CMD -t "$ORCHESTRATION_IMAGE" "$OC_SRC"
    log_info "Done: $ORCHESTRATION_IMAGE"
fi

WD_SRC=""
if [ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ]; then
    if [ -f "$OC_SRC/workflow-designer/Dockerfile" ]; then
        WD_SRC="$OC_SRC/workflow-designer"
    fi
    if [ -n "$WD_SRC" ]; then
        CURRENT=$((CURRENT + 1))
        log_step "[$CURRENT/$TOTAL] Building Workflow Designer..."
        $BUILD_CMD -t "$FRONTEND_IMAGE" "$WD_SRC"
        log_info "Done: $FRONTEND_IMAGE"
    else
        log_warn "Workflow Designer Dockerfile not found, skipping"
    fi
fi

# ===== Result =====
echo ""
echo "=========================================="
echo "  Build completed!"
echo "=========================================="
echo ""
echo "  Images:"
if [ "$BUILD_REGISTRY" = true ] && [ -n "$RC_SRC" ]; then
    echo "    - $REGISTRY_IMAGE"
fi
if [ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ]; then
    echo "    - $ORCHESTRATION_IMAGE"
fi
if [ -n "$WD_SRC" ]; then
    echo "    - $FRONTEND_IMAGE"
fi
echo ""
echo "  Deploy:"
echo "    helm install openan ./openan-chart -n openan --create-namespace \\"
if [ "$BUILD_REGISTRY" = true ] && [ -n "$RC_SRC" ]; then
    echo "      --set registry.image.repository=$IMAGE_REGISTRY/$NAMESPACE/registry-center --set registry.image.tag=$TAG \\"
fi
if [ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ]; then
    echo "      --set orchestration.image.repository=$IMAGE_REGISTRY/$NAMESPACE/orchestration-center --set orchestration.image.tag=$TAG \\"
fi
if [ -n "$WD_SRC" ]; then
    echo "      --set frontend.image.repository=$IMAGE_REGISTRY/$NAMESPACE/workflow-designer --set frontend.image.tag=$TAG"
fi
echo ""
