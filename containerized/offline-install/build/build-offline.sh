#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Build the OpenAN offline bundle. Run this on an INTERNET-CONNECTED Linux
# machine with Docker (buildx enabled). The output is a self-contained
# directory + tarball that installs OpenAN on an offline cluster.
#
#   ./build-offline.sh                                  # pull app images from ghcr.io
#   ./build-offline.sh --tag v1.0.0 --app-source pull
#   ./build-offline.sh --app-source build \
#       --registry-src ~/src/registry-center \
#       --orchestration-src ~/src/orchestration-center
#   ./build-offline.sh --app-source tars --app-tars-dir ~/prebuilt
#   ./build-offline.sh --tag v1.0.0 --registry-tag v1.2.0 --app-source pull
#
# Options:
#   --tag <tag>                 app image tag for all components (overrides tags derived from --source-ref)
#   --registry-tag <tag>        registry-center image tag (overrides --tag)
#   --orchestration-tag <tag>   orchestration-center + workflow-designer tag (overrides --tag)
#   --portal-tag <tag>          openan-portal tag (overrides --tag)
#   --source-ref <ref>          Source Git ref; when --tag is unset, 'main' -> main-YYYYMMDD,
#                               any other ref becomes the tag (default v1.0.0)
#   --app-registry <host/ns>    upstream app registry (default ghcr.io/project-openan)
#   --app-source pull|build|tars
#   --registry-src <dir>        registry-center source dir (with Dockerfile) for --app-source build
#   --orchestration-src <dir>   orchestration-center source dir for --app-source build
#   --portal-src <dir>          openan-portal source (with Dockerfile) for --app-source build
#   --registry-release <url>    remote registry-center source tarball (used when no --registry-src)
#   --orchestration-release <url> remote orchestration-center source tarball (used when no --orchestration-src)
#   --app-tars-dir <dir>        directory of pre-built <base>-<arch>.tar for --app-source tars
#   --platforms a,b             target architectures (default linux/amd64,linux/arm64)
#   --out <dir>                 output directory (default ./dist)
#   --keep-images               do not delete pulled images afterwards

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$OFFLINE_SRC/../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# Resolve a caller-supplied path to an absolute, symlink-resolved path. Docker
# (buildx) resolves build contexts relative to the daemon's working directory,
# so a relative path that bash can resolve (e.g. ../../../src/registry-center)
# still fails inside docker with "unable to prepare context: path ... not found".
# Normalize here so the same path works everywhere; a missing or unresolvable
# path fails here with a clear error instead of failing deep inside docker.
resolve_abs() {
    local p
    p="$(readlink -e "$1" 2>/dev/null)" && [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    p="$(realpath -e "$1" 2>/dev/null)" && [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    return 1
}

# --- Pinned dependency versions (Kubernetes 1.34) ----------------------------
HELM_VERSION="v3.19.5"
KUBECTL_VERSION="v1.34.12"
CRANE_VERSION="v0.19.2"
INGRESS_NGINX_VERSION="controller-v1.15.1"
METALLB_VERSION="v0.16.1"

# --- Defaults -----------------------------------------------------------------
TAG="v1.0.0"
TAG_EXPLICIT=false
SOURCE_REF="v1.0.0"
REGISTRY_TAG=""
ORCHESTRATION_TAG=""
PORTAL_TAG=""
APP_REGISTRY="ghcr.io/project-openan"
APP_SOURCE="pull"
REGISTRY_SRC=""
ORCHESTRATION_SRC=""
PORTAL_SRC=""
REGISTRY_RELEASE=""
ORCHESTRATION_RELEASE=""
APP_TARS_DIR=""
PLATFORMS="linux/amd64,linux/arm64"
OUT_DIR="$SCRIPT_DIR/dist"
KEEP_IMAGES="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)               TAG="$2"; TAG_EXPLICIT=true; shift 2 ;;
        --registry-tag)      REGISTRY_TAG="$2"; shift 2 ;;
        --orchestration-tag) ORCHESTRATION_TAG="$2"; shift 2 ;;
        --portal-tag)        PORTAL_TAG="$2"; shift 2 ;;
        --app-registry)      APP_REGISTRY="$2"; shift 2 ;;
        --app-source)        APP_SOURCE="$2"; shift 2 ;;
        --registry-src)      REGISTRY_SRC="$2"; shift 2 ;;
        --orchestration-src) ORCHESTRATION_SRC="$2"; shift 2 ;;
        --portal-src)         PORTAL_SRC="$2"; shift 2 ;;
        --source-ref)        SOURCE_REF="$2"; shift 2 ;;
        --registry-release)  REGISTRY_RELEASE="$2"; shift 2 ;;
        --orchestration-release) ORCHESTRATION_RELEASE="$2"; shift 2 ;;
        --app-tars-dir)      APP_TARS_DIR="$2"; shift 2 ;;
        --platforms)         PLATFORMS="$2"; shift 2 ;;
        --out)               OUT_DIR="$2"; shift 2 ;;
        --keep-images)       KEEP_IMAGES="true"; shift ;;
        -h|--help)           sed -n '2,30p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done

# Derive the image tag from --source-ref when --tag was not given explicitly.
# 'main' becomes a dated snapshot (main-YYYYMMDD); any other ref (release tag
# or commit) becomes the tag itself, keeping image tag and source in sync.
if [ "$TAG_EXPLICIT" = false ]; then
    if [ "$SOURCE_REF" = "main" ]; then
        TAG="main-$(date +%Y%m%d)"
    else
        TAG="$SOURCE_REF"
    fi
fi

for t in docker curl; do
    command -v "$t" >/dev/null 2>&1 || { log_error "$t is required"; exit 1; }
done
docker buildx version >/dev/null 2>&1 || { log_error "docker buildx is required"; exit 1; }

# --- Layout -------------------------------------------------------------------
# Per-component tags: --registry-tag/--orchestration-tag/--portal-tag override
# the global --tag for that component; unset components fall back to --tag.
APP_REGISTRY_CENTER_REF="$APP_REGISTRY/registry-center:${REGISTRY_TAG:-$TAG}"
APP_ORCHESTRATION_CENTER_REF="$APP_REGISTRY/orchestration-center:${ORCHESTRATION_TAG:-$TAG}"
APP_WORKFLOW_DESIGNER_REF="$APP_REGISTRY/workflow-designer:${ORCHESTRATION_TAG:-$TAG}"
APP_PORTAL_REF="$APP_REGISTRY/openan-portal:${PORTAL_TAG:-$TAG}"

mkdir -p "$OUT_DIR"
BUNDLE="$(cd "$OUT_DIR" && pwd)/openan-offline-$TAG"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/images" "$BUNDLE/deps/bin" "$BUNDLE/deps/manifests"

log_step "Assembling bundle at $BUNDLE"
cp -r "$OFFLINE_SRC/scripts" "$BUNDLE/scripts"
cp -r "$OFFLINE_SRC/chart" "$BUNDLE/chart"
cp -r "$OFFLINE_SRC/docs" "$BUNDLE/docs"
cp "$OFFLINE_SRC/README.md" "$BUNDLE/README.md" 2>/dev/null || true
cp "$OFFLINE_SRC/config.env.example" "$BUNDLE/config.env.example"
chmod +x "$BUNDLE/scripts"/*.sh 2>/dev/null || true

# --- Dependencies -------------------------------------------------------------
log_step "Downloading dependencies"
ARCHS=()
for p in ${PLATFORMS//,/ }; do ARCHS+=("${p#linux/}"); done

for a in "${ARCHS[@]}"; do
    # helm
    if [ ! -x "$BUNDLE/deps/bin/helm-linux-$a" ]; then
        log_info "helm $HELM_VERSION ($a)"
        curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${a}.tar.gz" -o /tmp/helm-$a.tgz
        tar -xzf /tmp/helm-$a.tgz -C /tmp
        cp "/tmp/linux-${a}/helm" "$BUNDLE/deps/bin/helm-linux-$a"
        chmod +x "$BUNDLE/deps/bin/helm-linux-$a"
    fi
    # kubectl
    log_info "kubectl $KUBECTL_VERSION ($a)"
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${a}/kubectl" -o "$BUNDLE/deps/bin/kubectl-linux-$a"
    chmod +x "$BUNDLE/deps/bin/kubectl-linux-$a"
    # crane
    local_asset="x86_64"; [ "$a" = "arm64" ] && local_asset="arm64"
    log_info "crane $CRANE_VERSION ($a)"
    curl -fsSL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_Linux_${local_asset}.tar.gz" -o /tmp/crane-$a.tgz
    tar -xzf /tmp/crane-$a.tgz -C /tmp crane
    cp /tmp/crane "$BUNDLE/deps/bin/crane-linux-$a"
    chmod +x "$BUNDLE/deps/bin/crane-linux-$a"
done

log_info "ingress-nginx $INGRESS_NGINX_VERSION manifest"
curl -fsSL "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml" \
    -o "$BUNDLE/deps/manifests/ingress-nginx.yaml"
log_info "metallb $METALLB_VERSION manifest"
curl -fsSL "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" \
    -o "$BUNDLE/deps/manifests/metallb-native.yaml"

# Derive infra image refs from the manifests so versions always match.
ING_CTRL=$(grep -oE 'registry\.k8s\.io/ingress-nginx/controller:[^ @]+' "$BUNDLE/deps/manifests/ingress-nginx.yaml" | head -1)
ING_CGEN=$(grep -oE 'registry\.k8s\.io/ingress-nginx/kube-webhook-certgen:[^ @]+' "$BUNDLE/deps/manifests/ingress-nginx.yaml" | head -1)
MB_CTRL=$(grep -oE 'quay\.io/metallb/controller:[^ @]+' "$BUNDLE/deps/manifests/metallb-native.yaml" | head -1)
MB_SPK=$(grep -oE 'quay\.io/metallb/speaker:[^ @]+' "$BUNDLE/deps/manifests/metallb-native.yaml" | head -1)

log_info "ingress-nginx controller : $ING_CTRL"
log_info "ingress-nginx certgen    : $ING_CGEN"
log_info "metallb controller       : $MB_CTRL"
log_info "metallb speaker          : $MB_SPK"

# base|upstream-ref|registry-relative-ref
INFRA=(
    "registry-2|docker.io/library/registry:2|library/registry:2"
    "postgres-15-alpine|docker.io/library/postgres:15-alpine|library/postgres:15-alpine"
    "mysql-8-4-3|docker.io/library/mysql:8.4.3|library/mysql:8.4.3"
    "ingress-nginx-controller|$ING_CTRL|${ING_CTRL#registry.k8s.io/}"
    "ingress-nginx-kube-webhook-certgen|$ING_CGEN|${ING_CGEN#registry.k8s.io/}"
    "metallb-controller|$MB_CTRL|${MB_CTRL#quay.io/}"
    "metallb-speaker|$MB_SPK|${MB_SPK#quay.io/}"
)

: >"$BUNDLE/deps/infra-images.list"
for entry in "${INFRA[@]}"; do
    IFS='|' read -r _base _up _rel <<<"$entry"
    echo "${_base}|${_rel}" >>"$BUNDLE/deps/infra-images.list"
done

# --- Image saving -------------------------------------------------------------
save_image() {
    local ref="$1" base="$2"
    for a in "${ARCHS[@]}"; do
        local out="$BUNDLE/images/${base}-${a}.tar"
        log_info "  save $base ($a)"
        docker pull --platform "linux/${a}" "$ref" >/dev/null || { log_error "pull failed: $ref"; return 1; }
        docker save -o "$out" "$ref" || { log_error "save failed: $ref"; return 1; }
    done
}

log_step "Pulling and saving infrastructure images"
for entry in "${INFRA[@]}"; do
    IFS='|' read -r _base _up _rel <<<"$entry"
    save_image "$_up" "$_base"
done

log_step "Preparing application images ($APP_SOURCE)"
case "$APP_SOURCE" in
    pull)
        save_image "$APP_REGISTRY_CENTER_REF" "registry-center"
        save_image "$APP_ORCHESTRATION_CENTER_REF" "orchestration-center"
        save_image "$APP_WORKFLOW_DESIGNER_REF" "workflow-designer"
        save_image "$APP_PORTAL_REF" "portal"
        ;;
    build)
        # A component's source is a local --*-src dir when given, otherwise a
        # remote tarball (explicit --*-release URL, or the GitHub archive for
        # --source-ref) is downloaded and extracted. Portal uses --portal-src
        # only (local path, optional).
        resolve_src() {
            local local_dir="$1" url="$2" name="$3"
            if [ -n "$local_dir" ]; then
                local abs
                abs="$(resolve_abs "$local_dir")" || { log_error "$name: source not found: $local_dir"; return 1; }
                [ -f "$abs/Dockerfile" ] || { log_error "$name: no Dockerfile in $abs"; return 1; }
                printf '%s\n' "$abs"; return 0
            fi
            [ -n "$url" ] || { log_error "$name: give --${name%-center}-src, --${name%-center}-release or --source-ref"; return 1; }
            local dest="$BUILD_TMP/$name"
            mkdir -p "$dest"
            log_step "Downloading $name source: $url"
            curl -fSL -o "$BUILD_TMP/${name}.tar.gz" "$url" || { log_error "$name download failed: $url"; return 1; }
            tar -xzf "$BUILD_TMP/${name}.tar.gz" -C "$dest" || { log_error "$name extract failed: $url"; return 1; }
            [ -f "$dest/Dockerfile" ] && { printf '%s\n' "$dest"; return 0; }
            for d in "$dest"/*/; do [ -f "$d/Dockerfile" ] && { printf '%s\n' "$d"; return 0; }; done
            log_error "$name: no Dockerfile after extracting $url"; return 1
        }
        BUILD_TMP="$(mktemp -d -t openan-src.XXXXXXXX)"
        trap 'rm -rf "$BUILD_TMP" 2>/dev/null || true' EXIT
        RC_URL=""; OC_URL=""
        if [ -n "$SOURCE_REF" ]; then
            RC_URL="https://github.com/project-openan/registry-center/archive/${SOURCE_REF}.tar.gz"
            OC_URL="https://github.com/project-openan/orchestration-center/archive/${SOURCE_REF}.tar.gz"
        fi
        REGISTRY_SRC="$(resolve_src "$REGISTRY_SRC" "${REGISTRY_RELEASE:-$RC_URL}" "registry-center")" || exit 1
        ORCHESTRATION_SRC="$(resolve_src "$ORCHESTRATION_SRC" "${ORCHESTRATION_RELEASE:-$OC_URL}" "orchestration-center")" || exit 1
        if [ -n "$PORTAL_SRC" ]; then
            PORTAL_SRC="$(resolve_abs "$PORTAL_SRC")" || { log_error "--portal-src path not found: $PORTAL_SRC"; exit 1; }
        fi
        for a in "${ARCHS[@]}"; do
            log_info "  build registry-center ($a)"
            docker buildx build --platform "linux/${a}" --load -t "$APP_REGISTRY_CENTER_REF" "$REGISTRY_SRC" || exit 1
            docker save -o "$BUNDLE/images/registry-center-${a}.tar" "$APP_REGISTRY_CENTER_REF"
            log_info "  build orchestration-center ($a)"
            docker buildx build --platform "linux/${a}" --load -t "$APP_ORCHESTRATION_CENTER_REF" "$ORCHESTRATION_SRC" || exit 1
            docker save -o "$BUNDLE/images/orchestration-center-${a}.tar" "$APP_ORCHESTRATION_CENTER_REF"
            if [ -f "$ORCHESTRATION_SRC/workflow-designer/Dockerfile" ]; then
                log_info "  build workflow-designer ($a)"
                docker buildx build --platform "linux/${a}" --load -t "$APP_WORKFLOW_DESIGNER_REF" "$ORCHESTRATION_SRC/workflow-designer" || exit 1
                docker save -o "$BUNDLE/images/workflow-designer-${a}.tar" "$APP_WORKFLOW_DESIGNER_REF"
            else
                log_warn "  no workflow-designer/Dockerfile — skipping"
            fi
            if [ -n "$PORTAL_SRC" ]; then
                log_info "  build portal ($a)"
                docker buildx build --platform "linux/${a}" --load -t "$APP_PORTAL_REF" "$PORTAL_SRC" || exit 1
                docker save -o "$BUNDLE/images/portal-${a}.tar" "$APP_PORTAL_REF"
            else
                log_warn "  --portal-src not given - portal image not built; bundle only supports FRONTEND_TYPE=workflow-designer"
            fi
        done
        rm -rf "$BUILD_TMP"
        ;;
    tars)
        [ -d "$APP_TARS_DIR" ] || { log_error "--app-tars-dir is required for --app-source tars"; exit 1; }
        APP_TARS_DIR="$(resolve_abs "$APP_TARS_DIR")"
        for base in registry-center orchestration-center workflow-designer; do
            for a in "${ARCHS[@]}"; do
                [ -r "$APP_TARS_DIR/${base}-${a}.tar" ] || { log_error "missing $APP_TARS_DIR/${base}-${a}.tar"; exit 1; }
                cp "$APP_TARS_DIR/${base}-${a}.tar" "$BUNDLE/images/"
            done
        done
        for a in "${ARCHS[@]}"; do
            if [ -r "$APP_TARS_DIR/portal-${a}.tar" ]; then
                cp "$APP_TARS_DIR/portal-${a}.tar" "$BUNDLE/images/"
            else
                log_warn "missing optional $APP_TARS_DIR/portal-${a}.tar - bundle only supports FRONTEND_TYPE=workflow-designer"
            fi
        done
        ;;
    *)
        log_error "invalid --app-source: $APP_SOURCE (use pull|build|tars)"; exit 2 ;;
esac

# --- Record tags --------------------------------------------------------------
{
    echo "APP_REGISTRY_CENTER_TAG=$APP_REGISTRY_CENTER_REF"
    echo "APP_ORCHESTRATION_CENTER_TAG=$APP_ORCHESTRATION_CENTER_REF"
    echo "APP_WORKFLOW_DESIGNER_TAG=$APP_WORKFLOW_DESIGNER_REF"
    echo "APP_PORTAL_TAG=$APP_PORTAL_REF"
} >"$BUNDLE/deps/image-tags.env"

# --- Checksums ----------------------------------------------------------------
log_step "Generating SHA256SUMS"
(cd "$BUNDLE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)

# --- Tarball ------------------------------------------------------------------
log_step "Creating tarball"
tar -C "$(dirname "$BUNDLE")" -czf "$BUNDLE.tar.gz" "$(basename "$BUNDLE")"
log_info "Bundle:   $BUNDLE"
log_info "Tarball:  $BUNDLE.tar.gz ($(du -sh "$BUNDLE.tar.gz" | cut -f1))"

if [ "$KEEP_IMAGES" != "true" ]; then
    log_info "Leaving pulled images in the local Docker cache (use --keep-images to silence this)."
fi

echo ""
log_info "Done. Copy $BUNDLE.tar.gz to the offline machine, then:"
log_info "  tar -xzf $(basename "$BUNDLE.tar.gz")"
log_info "  cd $(basename "$BUNDLE")"
log_info "  cp config.env.example config.env && vi config.env"
log_info "  scripts/check-env.sh --config config.env"
log_info "  sudo scripts/install.sh --config config.env"
