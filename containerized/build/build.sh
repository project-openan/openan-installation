#!/usr/bin/env bash
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

# OpenAN Platform - One-line Image Build Script
# Usage: ./build.sh [components] [options]
#   No arguments = build all components with defaults
#   Specify component names to build only those: registry, orchestration, portal
#
# Components (positional):
#   registry          Build Registry Center only
#   orchestration     Build Orchestration Center + Workflow Designer only
#   portal            Build OpenAN Portal only
#   (none)            Build all components
#
# Options:
#   --registry-release <url>   Registry Center release URL
#   --orchestration-release <url> Orchestration Center release URL
#   --registry-src <dir>       Local registry-center source dir (overrides remote download)
#   --orchestration-src <dir>  Local orchestration-center source dir (overrides remote download)
#   --portal-release <url>     OpenAN Portal release URL
#   --portal-src <dir>         OpenAN Portal source directory (overrides --portal-release)
#   --image-registry <url>     Image registry (default: ghcr.io)
#   --namespace <ns>           Image namespace (default: project-openan)
#   --tag <tag>                Image tag (overrides the tag derived from --source-ref)
#   --source-ref <ref>         Source Git ref (branch/tag/commit); when --tag is unset,
#                              'main' derives tag main-YYYYMMDD, other refs become the tag
#   --platforms <platforms>    Target platforms (default: linux/amd64,linux/arm64)
#   --no-push                  Build local only (single-arch only)
#   --help                     Show help

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===== Defaults =====
IMAGE_REGISTRY="ghcr.io"
NAMESPACE="project-openan"
TAG="v1.0.0"
TAG_EXPLICIT=false
SOURCE_REF="v1.0.0"
REGISTRY_RELEASE=""
ORCHESTRATION_RELEASE=""
REGISTRY_SRC=""
ORCHESTRATION_SRC=""
PORTAL_RELEASE=""
PORTAL_SRC=""
PLATFORMS="linux/amd64,linux/arm64"
PUSH=true

BUILD_REGISTRY=false
BUILD_ORCHESTRATION=false
BUILD_PORTAL=false
COMPONENTS_SPECIFIED=false

TEMP_DIR=""

# Log messages go to stderr so command substitution (resolve_src, etc.)
# captures only the intended return value on stdout.
log_info()  { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1" >&2; }

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && [[ "${TEMP_DIR##*/}" == openan-build.* ]]; then
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
  portal            Build OpenAN Portal only
  (none)            Build all components

Options:
  --image-registry <url>     Image registry (default: ghcr.io)
  --namespace <ns>           Image namespace (default: project-openan)
  --tag <tag>                Image tag (overrides the tag derived from --source-ref)
  --source-ref <ref>         Source Git ref (default: v1.0.0); when --tag is unset, 'main'
                             derives tag main-YYYYMMDD and other refs become the tag
  --registry-release <url>   Registry Center release tarball URL
  --orchestration-release <url>  Orchestration Center release tarball URL
  --registry-src <dir>       Local registry-center source dir (overrides remote download)
  --orchestration-src <dir>  Local orchestration-center source dir (overrides remote download)
  --portal-release <url>     OpenAN Portal release tarball URL
  --portal-src <dir>         OpenAN Portal source directory (overrides --portal-release)
  --platforms <platforms>    Target platforms (default: linux/amd64,linux/arm64)
  --no-push                  Build local only (single-arch only)
  --help                     Show help

Examples:
  ./build.sh                                                          # Build all components
  ./build.sh registry                                                 # Build Registry Center only
  ./build.sh orchestration                                            # Build Orchestration + Frontend only
  ./build.sh portal                                                   # Build OpenAN Portal only
  ./build.sh registry orchestration                                   # Build both, no portal
  ./build.sh --tag v1.1.0                                             # Custom tag, build all
  ./build.sh registry --image-registry harbor.example.com             # Private registry, registry only
  ./build.sh orchestration --platforms linux/amd64 --no-push          # Local single-arch, orchestration only
  ./build.sh --source-ref main                                        # Build main, tagged main-YYYYMMDD
  ./build.sh --registry-src ~/src/registry-center --orchestration-src ~/src/orchestration-center
  ./build.sh portal --portal-src ~/src/openan-portal                  # Portal from local source
EOF
    exit 0
}

# ===== Parse arguments =====
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-registry|--namespace|--tag|--source-ref|--registry-release|--orchestration-release|--registry-src|--orchestration-src|--portal-release|--portal-src|--platforms)
            if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
                log_error "$1 requires a value"; exit 2
            fi ;;
    esac
    case $1 in
        registry)                BUILD_REGISTRY=true; COMPONENTS_SPECIFIED=true; shift ;;
        orchestration)           BUILD_ORCHESTRATION=true; COMPONENTS_SPECIFIED=true; shift ;;
        portal)                  BUILD_PORTAL=true; COMPONENTS_SPECIFIED=true; shift ;;
        --image-registry)        IMAGE_REGISTRY="$2"; shift 2 ;;
        --namespace)             NAMESPACE="$2"; shift 2 ;;
        --tag)                   TAG="$2"; TAG_EXPLICIT=true; shift 2 ;;
        --source-ref)            SOURCE_REF="$2"; shift 2 ;;
        --registry-release)      REGISTRY_RELEASE="$2"; shift 2 ;;
        --orchestration-release) ORCHESTRATION_RELEASE="$2"; shift 2 ;;
        --registry-src)          REGISTRY_SRC="$2"; shift 2 ;;
        --orchestration-src)     ORCHESTRATION_SRC="$2"; shift 2 ;;
        --portal-release)        PORTAL_RELEASE="$2"; shift 2 ;;
        --portal-src)            PORTAL_SRC="$2"; shift 2 ;;
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
    BUILD_PORTAL=true
fi

# Auto-generate source URLs from SOURCE_REF, not the image TAG if not explicitly specified
if [ -z "$REGISTRY_RELEASE" ]; then
    REGISTRY_RELEASE="https://github.com/project-openan/registry-center/archive/${SOURCE_REF}.tar.gz"
fi
if [ -z "$ORCHESTRATION_RELEASE" ]; then
    ORCHESTRATION_RELEASE="https://github.com/project-openan/orchestration-center/archive/${SOURCE_REF}.tar.gz"
fi
if [ -z "$PORTAL_RELEASE" ] && [ -z "$PORTAL_SRC" ]; then
    PORTAL_RELEASE="https://github.com/project-openan/openan-portal/archive/${SOURCE_REF}.tar.gz"
fi

# Derive the image tag from the source ref when --tag was not given explicitly.
# 'main' becomes a dated snapshot (main-YYYYMMDD); any other ref (release tag
# or commit) becomes the tag itself, keeping image tag and source in sync.
if [ "$TAG_EXPLICIT" = false ]; then
    if [ "$SOURCE_REF" = "main" ]; then
        TAG="main-$(date +%Y%m%d)"
    else
        TAG="$SOURCE_REF"
    fi
fi

# Multi-arch requires push
if [[ "$PLATFORMS" == *","* ]] && [ "$PUSH" = false ]; then
    log_error "--no-push requires one platform (e.g. --platforms linux/amd64); nothing was pushed"
    exit 2
fi

# ===== Print configuration =====
COMPONENTS=""
if [ "$BUILD_REGISTRY" = true ]; then
    COMPONENTS="${COMPONENTS}registry-center "
fi
if [ "$BUILD_ORCHESTRATION" = true ]; then
    COMPONENTS="${COMPONENTS}orchestration-center workflow-designer "
fi
if [ "$BUILD_PORTAL" = true ]; then
    COMPONENTS="${COMPONENTS}openan-portal"
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
if [ "$BUILD_PORTAL" = true ]; then
    if [ -n "$PORTAL_SRC" ]; then
        echo "  Portal source:            $PORTAL_SRC"
    else
        echo "  Portal release:           $PORTAL_RELEASE"
    fi
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

TEMP_DIR=$(mktemp -d -t openan-build.XXXXXXXX)

# ===== Resolve component sources =====
# A component's source is a local --*-src directory when given; otherwise the
# remote release tarball (--*-release URL, or GitHub archive for --source-ref).
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

resolve_src() {
    local local_dir="$1" remote_url="$2" name="$3"
    if [ -n "$local_dir" ]; then
        local abs
        abs="$(cd "$local_dir" 2>/dev/null && pwd)" || { log_error "Local source path not found: $local_dir"; return 1; }
        [ -f "$abs/Dockerfile" ] || { log_error "No Dockerfile in local source: $abs"; return 1; }
        printf '%s\n' "$abs"
        return 0
    fi
    download_release "$remote_url" "$name"
    detect_src_dir "$TEMP_DIR/$name"
}

# ===== Image references =====
REGISTRY_IMAGE="$IMAGE_REGISTRY/$NAMESPACE/registry-center:$TAG"
ORCHESTRATION_IMAGE="$IMAGE_REGISTRY/$NAMESPACE/orchestration-center:$TAG"
FRONTEND_IMAGE="$IMAGE_REGISTRY/$NAMESPACE/workflow-designer:$TAG"
PORTAL_IMAGE="$IMAGE_REGISTRY/$NAMESPACE/openan-portal:$TAG"

if [ "$BUILD_REGISTRY" = true ]; then
    RC_SRC="$(resolve_src "$REGISTRY_SRC" "$REGISTRY_RELEASE" "registry-center")" || exit 1
    if [ -z "$RC_SRC" ]; then
        log_error "Cannot find Dockerfile for registry-center"
        exit 1
    fi
    log_info "Registry Center source: $RC_SRC"
fi

if [ "$BUILD_ORCHESTRATION" = true ]; then
    OC_SRC="$(resolve_src "$ORCHESTRATION_SRC" "$ORCHESTRATION_RELEASE" "orchestration-center")" || exit 1
    if [ -z "$OC_SRC" ]; then
        log_error "Cannot find Dockerfile for orchestration-center"
        exit 1
    fi
    log_info "Orchestration Center source: $OC_SRC"
fi

PORTAL_SOURCE_DIR=""
if [ "$BUILD_PORTAL" = true ]; then
    PORTAL_SOURCE_DIR="$(resolve_src "$PORTAL_SRC" "$PORTAL_RELEASE" "openan-portal")" || exit 1
    if [ -z "$PORTAL_SOURCE_DIR" ]; then
        log_error "Cannot find Dockerfile for openan-portal"
        exit 1
    fi
    log_info "Portal source: $PORTAL_SOURCE_DIR"
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

BUILD_CMD=(docker buildx build --platform "$PLATFORMS"
    --label "org.opencontainers.image.version=$TAG"
    --label "io.openan.source.ref=$SOURCE_REF")
if [ "$PUSH" = true ]; then
    BUILD_CMD+=(--push)
else
    BUILD_CMD+=(--load)
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
if [ "$BUILD_PORTAL" = true ] && [ -n "$PORTAL_SOURCE_DIR" ]; then
    TOTAL=$((TOTAL + 1))
fi
CURRENT=0

if [ "$BUILD_REGISTRY" = true ] && [ -n "$RC_SRC" ]; then
    CURRENT=$((CURRENT + 1))
    log_step "[$CURRENT/$TOTAL] Building Registry Center..."
    "${BUILD_CMD[@]}" --label "org.opencontainers.image.source=https://github.com/project-openan/registry-center" --label "org.opencontainers.image.revision=$(git -C "$RC_SRC" rev-parse HEAD 2>/dev/null || printf unknown)" -t "$REGISTRY_IMAGE" "$RC_SRC"
    log_info "Done: $REGISTRY_IMAGE"
fi

if [ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ]; then
    CURRENT=$((CURRENT + 1))
    log_step "[$CURRENT/$TOTAL] Building Orchestration Center..."
    "${BUILD_CMD[@]}" --label "org.opencontainers.image.source=https://github.com/project-openan/orchestration-center" --label "org.opencontainers.image.revision=$(git -C "$OC_SRC" rev-parse HEAD 2>/dev/null || printf unknown)" -t "$ORCHESTRATION_IMAGE" "$OC_SRC"
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
        "${BUILD_CMD[@]}" --label "org.opencontainers.image.source=https://github.com/project-openan/orchestration-center" --label "org.opencontainers.image.revision=$(git -C "$OC_SRC" rev-parse HEAD 2>/dev/null || printf unknown)" -t "$FRONTEND_IMAGE" "$WD_SRC"
        log_info "Done: $FRONTEND_IMAGE"
    else
        log_warn "Workflow Designer Dockerfile not found, skipping"
    fi
fi

if [ "$BUILD_PORTAL" = true ] && [ -n "$PORTAL_SOURCE_DIR" ]; then
    CURRENT=$((CURRENT + 1))
    log_step "[$CURRENT/$TOTAL] Building OpenAN Portal..."
    "${BUILD_CMD[@]}" --label "org.opencontainers.image.source=https://github.com/project-openan/openan-portal" --label "org.opencontainers.image.revision=$(git -C "$PORTAL_SOURCE_DIR" rev-parse HEAD 2>/dev/null || printf unknown)" -t "$PORTAL_IMAGE" "$PORTAL_SOURCE_DIR"
    log_info "Done: $PORTAL_IMAGE"
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
if [ "$BUILD_PORTAL" = true ] && [ -n "$PORTAL_SOURCE_DIR" ]; then
    echo "    - $PORTAL_IMAGE"
fi
echo ""
echo "  Deploy:"
echo "    helm upgrade --install openan ./online-install/openan-chart -n openan --create-namespace -f /path/to/deployment.yaml \\"
if [ "$BUILD_REGISTRY" = true ] && [ -n "$RC_SRC" ]; then
    echo "      --set registry.image.repository=$IMAGE_REGISTRY/$NAMESPACE/registry-center --set registry.image.tag=$TAG \\"
fi
if [ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ]; then
    echo "      --set orchestration.image.repository=$IMAGE_REGISTRY/$NAMESPACE/orchestration-center --set orchestration.image.tag=$TAG \\"
fi
if [ -n "$WD_SRC" ]; then
    echo "      --set frontend.image.repository=$IMAGE_REGISTRY/$NAMESPACE/workflow-designer --set frontend.image.tag=$TAG \\"
fi
if [ "$BUILD_PORTAL" = true ] && [ -n "$PORTAL_SOURCE_DIR" ]; then
    echo "      --set frontend.image.repository=$IMAGE_REGISTRY/$NAMESPACE/openan-portal --set frontend.image.tag=$TAG"
fi
echo ""
