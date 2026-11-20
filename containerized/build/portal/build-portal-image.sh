#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Build the OpenAN Portal container image from the published GitHub release
# artifact and (optionally) push a multi-architecture manifest list.
#
# Why a separate script: containerized/build/build.sh builds every component
# from a *source* archive using the component's own Dockerfile. The portal
# release ships a prebuilt static site (index.html + assets/ + plugins/) that
# already contains the compiled SPA and all bundle plugins, so building the
# image from the release is both faster and more faithful than rebuilding from
# source (which needs Node and, at v1.0.0, a Dockerfile whose COPY paths no
# longer exist). This script wraps that release-artifact path.
#
# The Dockerfile is generated inline, so nothing else in this image pipeline
# depends on the portal repo layout. The only bundled dependencies are the two
# nginx entrypoint files next to this script:
#   default.conf.template       API gateways + SPA fallback
#   15-openan-backends.envsh    composes BACKEND_URL / REGISTRY_URL
#
# Usage:
#   ./build-portal-image.sh                       # build+push v1.0.0, both arches
#   ./build-portal-image.sh -t v1.0.1             # different release/image tag
#   PUSH=0 PLATFORMS=linux/arm64 ./build-portal-image.sh   # local, single-arch
#   ./build-portal-image.sh -n                    # dry run (print plan only)
#   ./build-portal-image.sh -h                    # help
#
# Environment overrides (all optional):
#   TAG            release tag and default image tag  (default v1.0.0)
#   REGISTRY       registry host + namespace          (default ghcr.io/project-openan)
#   IMAGE_NAME     image name                         (default openan-portal)
#   PLATFORMS      buildx --platform list             (default linux/amd64,linux/arm64)
#   EXTRA_TAGS     space-separated additional tags    (default "")
#   PUSH           1 = push manifest list, 0 = load   (default 1)
#   BUILDER        buildx builder name                (default: first running docker-container)
#   TEMPLATE_SRC   dir holding the two nginx files    (default: this script's dir)
#   DIST_TARBALL   use this local tarball instead of downloading
#   SKIP_CHECKSUM  1 = skip sha256 verification       (default 0)
#   KEEP_CTX       1 = keep the temporary build context (default 0)
#
# NOTE: registry paths must be lowercase. `docker login ghcr.io -u MixedCase`
# is fine, but a tag like ghcr.io/MixedCase/img is rejected by the daemon.

set -euo pipefail

# ===== Defaults =====
TAG="${TAG:-v1.0.0}"
REGISTRY="${REGISTRY:-ghcr.io/project-openan}"
IMAGE_NAME="${IMAGE_NAME:-openan-portal}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
EXTRA_TAGS="${EXTRA_TAGS:-}"
PUSH="${PUSH:-1}"
BUILDER="${BUILDER:-}"
TEMPLATE_SRC="${TEMPLATE_SRC:-}"
DIST_TARBALL="${DIST_TARBALL:-}"
SKIP_CHECKSUM="${SKIP_CHECKSUM:-0}"
KEEP_CTX="${KEEP_CTX:-0}"

REPO_SLUG="project-openan/openan-portal"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "$TEMPLATE_SRC" ] || TEMPLATE_SRC="$SCRIPT_DIR"

# Pinned sha256 of the release asset, per tag. Bump when a new tag is added;
# verification is skipped (with a warning) for tags not listed here.
declare -A DIST_SHA=(
    [v1.0.0]="b43d943f45328ba8008dcb4d60d105e9e934e5737d040a6d8634986c0e04f9f5"
)

# ===== Output helpers =====
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_step()  { echo -e "${CYAN}==>${NC} $1" >&2; }
log_info()  { echo -e "${GREEN} ok ${NC} $1" >&2; }
log_warn()  { echo -e "${YELLOW}warn${NC} $1" >&2; }
log_error() { echo -e "${RED}FAIL${NC} $1" >&2; }
die()       { log_error "$1"; exit 1; }
have()      { command -v "$1" >/dev/null 2>&1; }

usage() {
    awk '/^# Build the OpenAN Portal/,/^set -euo pipefail/' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
    exit 0
}

DRY_RUN=0
while getopts ":t:r:i:p:nh" opt; do
    case "$opt" in
        t) TAG="$OPTARG" ;;
        r) REGISTRY="$OPTARG" ;;
        i) IMAGE_NAME="$OPTARG" ;;
        p) PLATFORMS="$OPTARG" ;;
        n) DRY_RUN=1 ;;
        h) usage ;;
        \?) die "unknown option -$OPTARG (try -h)" ;;
        :)  die "option -$OPTARG requires a value" ;;
    esac
done

RELEASE_BASE="https://github.com/${REPO_SLUG}/releases/download/${TAG}"
IMAGE_REF="${REGISTRY}/${IMAGE_NAME}:${TAG}"
# Docker rejects uppercase repository names. Catch it here with a clear message
# instead of failing deep inside buildx ("repository name must be lowercase").
if printf '%s' "$IMAGE_REF" | grep -q '[A-Z]'; then
    die "image reference must be lowercase: $IMAGE_REF
     (docker login user may be mixed-case, but the registry path may not)"
fi
TAGS=(-t "$IMAGE_REF")
for et in $EXTRA_TAGS; do TAGS+=(-t "${REGISTRY}/${IMAGE_NAME}:${et}"); done

# ===== Preflight =====
echo "" >&2
echo "==========================================" >&2
echo "  OpenAN Portal Image Build (release)" >&2
echo "==========================================" >&2
echo "  Release tag:      $TAG" >&2
echo "  Image:            $IMAGE_REF" >&2
if [ -n "$EXTRA_TAGS" ]; then echo "  Extra tags:       $EXTRA_TAGS" >&2; fi
echo "  Platforms:        $PLATFORMS" >&2
echo "  Push:             $PUSH" >&2
echo "  nginx templates:  $TEMPLATE_SRC" >&2
echo "==========================================" >&2
echo "" >&2

have docker || die "docker not found"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon"
docker buildx version >/dev/null 2>&1 || die "docker buildx not installed"

MULTIARCH=0
case "$PLATFORMS" in *,*) MULTIARCH=1 ;; esac
if [ "$MULTIARCH" = 1 ] && [ "$PUSH" = 0 ]; then
    die "multi-arch builds must push (set PUSH=1); a manifest list cannot be --load'ed"
fi
if [ "$DRY_RUN" = 0 ]; then
    have curl || die "curl not found"
    have sha256sum || die "sha256sum not found"
fi
if [ "$DRY_RUN" = 1 ]; then log_step "DRY RUN — nothing will be built or pushed"; fi

# ===== Build context =====
CTX="$(mktemp -d -t openan-portal-ctx.XXXXXXXX)"
cleanup() { [ "$KEEP_CTX" = 1 ] || rm -rf "$CTX"; }
trap cleanup EXIT
log_step "build context: $CTX"

# 1) release payload (index.html + assets/ + plugins/)
if [ -n "$DIST_TARBALL" ]; then
    tarball="$DIST_TARBALL"
    [ -f "$tarball" ] || die "DIST_TARBALL not found: $tarball"
    log_step "using local tarball: $tarball"
else
    tarball="$CTX/openan-portal-dist.tar.gz"
    url="${RELEASE_BASE}/openan-portal-dist.tar.gz"
    log_step "downloading $url"
    [ "$DRY_RUN" = 1 ] || curl -fSL --retry 3 -o "$tarball" "$url" \
        || die "download failed: $url"
fi

# 2) checksum verification
if [ "$SKIP_CHECKSUM" != 1 ]; then
    want="${DIST_SHA[$TAG]:-}"
    if [ -z "$want" ]; then
        log_warn "no pinned sha256 for tag $TAG — skipping verification"
    elif [ "$DRY_RUN" = 1 ]; then
        log_step "would verify sha256 == $want"
    else
        got="$(sha256sum "$tarball" | awk '{print $1}')"
        [ "$got" = "$want" ] || die "checksum mismatch for $tarball
     expected $want
     got      $got"
        log_info "sha256 verified ($got)"
    fi
fi

# 3) extract payload
if [ "$DRY_RUN" = 0 ]; then
    tar -xzf "$tarball" -C "$CTX"
    [ -f "$CTX/index.html" ] || die "release payload has no index.html"
    [ -d "$CTX/plugins" ]    || die "release payload has no plugins/"
fi

# 4) nginx entrypoint files (bundled next to this script)
for f in default.conf.template 15-openan-backends.envsh; do
    if [ "$DRY_RUN" = 1 ]; then
        log_step "would copy $TEMPLATE_SRC/$f"
        continue
    fi
    [ -f "$TEMPLATE_SRC/$f" ] || die "missing dependency: $TEMPLATE_SRC/$f"
    cp "$TEMPLATE_SRC/$f" "$CTX/$f"
    log_step "copied $f"
done

# 5) inline Dockerfile (keeps the image independent of the portal repo layout)
if [ "$DRY_RUN" = 0 ]; then
    cat > "$CTX/Dockerfile" <<'DOCKERFILE'
# OpenAN Portal image — generated by build-portal-image.sh.
# Serves the prebuilt release site (index.html + assets/ + plugins/) with an
# unprivileged nginx. No Node build stage: the release already ships the
# compiled SPA and all bundle plugins.
FROM nginx:1.27-alpine

# Explicit copies so the nginx entrypoint files below never land in the webroot.
COPY index.html /usr/share/nginx/html/
COPY assets/    /usr/share/nginx/html/assets/
COPY plugins/   /usr/share/nginx/html/plugins/

COPY default.conf.template    /etc/nginx/templates/default.conf.template
COPY 15-openan-backends.envsh /docker-entrypoint.d/15-openan-backends.envsh

RUN sed -i 's/\r$//' /docker-entrypoint.d/15-openan-backends.envsh \
    && chmod 0755 /docker-entrypoint.d/15-openan-backends.envsh \
    && sed -i 's/^user /#user /' /etc/nginx/nginx.conf \
    && touch /var/run/nginx.pid \
    && chown -R 101:0 /var/cache/nginx /var/run/nginx.pid /etc/nginx \
    && chmod -R g+w /var/cache/nginx /var/run/nginx.pid /etc/nginx \
    && rm -f /usr/share/nginx/html/50x.html
USER 101

ENV REGISTRY_HOST=registry-center REGISTRY_PORT=5000 REGISTRY_SCHEME=http \
    BACKEND_HOST=orchestration-center BACKEND_PORT=5001 BACKEND_SCHEME=http
EXPOSE 8080
DOCKERFILE
fi

# ===== Buildx builder =====
# A docker-container builder is required for multi-arch. Parse the plain-text
# listing (no --format: field names differ across buildx versions) and accept
# the first docker-container builder whose node is actually running, so we skip
# errored/unreachable builders.
if [ -z "$BUILDER" ]; then
    BUILDER="$(docker buildx ls 2>/dev/null | awk '
        /^[^[:space:]]/ && $1 != "NAME/NODE" { name=$1; drv=$2; gsub(/\*/,"",name); next }
        drv=="docker-container" && /[[:space:]]running([[:space:]]|$)/ { print name; exit }
    ' || true)"
fi
if [ -z "$BUILDER" ]; then
    BUILDER="openan-multiarch"
    log_step "creating buildx builder: $BUILDER"
    [ "$DRY_RUN" = 1 ] || docker buildx create --name "$BUILDER" --driver docker-container >/dev/null
fi
log_step "buildx builder: $BUILDER"

# ===== Build =====
build_args=(buildx build --builder "$BUILDER" --platform "$PLATFORMS"
            --provenance=false --sbom=false
            --label "org.opencontainers.image.source=https://github.com/${REPO_SLUG}"
            --label "org.opencontainers.image.version=${TAG}"
            "${TAGS[@]}" -f "$CTX/Dockerfile")
if [ "$PUSH" = 1 ]; then build_args+=(--push); else build_args+=(--load); fi
build_args+=("$CTX")

if [ "$DRY_RUN" = 1 ]; then
    log_step "would run: docker ${build_args[*]}"
    log_info "dry run complete"
    exit 0
fi

log_step "building ..."
docker "${build_args[@]}" || die "build failed"

# ===== Result =====
echo "" >&2
echo "==========================================" >&2
if [ "$PUSH" = 1 ]; then
    log_step "pushed manifest list: $IMAGE_REF"
    docker buildx imagetools inspect "$IMAGE_REF" >&2 2>/dev/null || true
else
    log_info "built locally: $IMAGE_REF"
fi
log_info "Done."
