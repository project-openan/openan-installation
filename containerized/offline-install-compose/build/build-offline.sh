#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
# Build a clean offline bundle; credentials/runtime data are never copied.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG=""; SOURCE_REF=""; APP_REGISTRY="ghcr.io/project-openan"; APP_SOURCE="pull"
REGISTRY_TAG=""; ORCHESTRATION_TAG=""; PORTAL_TAG=""
REGISTRY_SRC=""; ORCHESTRATION_SRC=""; REGISTRY_RELEASE=""; ORCHESTRATION_RELEASE=""; APP_TARS_DIR=""
PLATFORMS="linux/amd64"; OUT_DIR="$SCRIPT_DIR/dist"
log_warn() { echo "[WARN] $1"; }
while [ $# -gt 0 ]; do
    if [[ "$1" == --* && "$1" != --help ]] && { [ $# -lt 2 ] || [[ "$2" == --* ]] || [ -z "$2" ]; }; then
        echo "$1 requires a value" >&2; exit 2
    fi
    case "$1" in
        --tag) TAG="$2"; shift 2 ;;
        --registry-tag) REGISTRY_TAG="$2"; shift 2 ;;
        --orchestration-tag) ORCHESTRATION_TAG="$2"; shift 2 ;;
        --portal-tag) PORTAL_TAG="$2"; shift 2 ;;
        --source-ref) SOURCE_REF="$2"; shift 2 ;;
        --app-registry) APP_REGISTRY="$2"; shift 2 ;;
        --app-source) APP_SOURCE="$2"; shift 2 ;;
        --registry-src) REGISTRY_SRC="$2"; shift 2 ;;
        --orchestration-src) ORCHESTRATION_SRC="$2"; shift 2 ;;
        --registry-release) REGISTRY_RELEASE="$2"; shift 2 ;;
        --orchestration-release) ORCHESTRATION_RELEASE="$2"; shift 2 ;;
        --app-tars-dir) APP_TARS_DIR="$2"; shift 2 ;;
        --platforms) PLATFORMS="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --help|-h) echo 'Use --source-ref <main|tag> [or --tag <tag>] [--registry-tag/--orchestration-tag/--portal-tag <tag>] --app-source pull|build|tars [--registry-src/--orchestration-src <dir> | --registry-release/--orchestration-release <url>] [--platforms linux/amd64,linux/arm64] [--out <dir>]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
# Derive the image tag from --source-ref when --tag was not given: 'main'
# becomes a dated snapshot (main-YYYYMMDD); any other ref becomes the tag.
if [ -z "$TAG" ] && [ -n "$SOURCE_REF" ]; then
    if [ "$SOURCE_REF" = "main" ]; then
        TAG="main-$(date +%Y%m%d)"
    else
        TAG="$SOURCE_REF"
    fi
fi
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo 'Explicit --tag or --source-ref <main|tag> required' >&2; exit 2; }
# Per-component tags override the global tag for that component; unset
# components fall back to it. --orchestration-tag covers orchestration-center
# and workflow-designer (built from the same source tree).
for component_tag in "$REGISTRY_TAG" "$ORCHESTRATION_TAG" "$PORTAL_TAG"; do
    [ -n "$component_tag" ] || continue
    [[ "$component_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo 'Per-component tags must match [A-Za-z0-9_][A-Za-z0-9_.-]{0,127}' >&2; exit 2; }
done
[[ "$APP_REGISTRY" =~ ^[A-Za-z0-9][A-Za-z0-9./:_-]*$ ]] || { echo 'Invalid app registry' >&2; exit 2; }
[[ "$APP_SOURCE" == pull || "$APP_SOURCE" == build || "$APP_SOURCE" == tars ]] || { echo 'Invalid app source' >&2; exit 2; }
ARCHS=()
for platform in ${PLATFORMS//,/ }; do
    [[ "$platform" == linux/amd64 || "$platform" == linux/arm64 ]] || { echo 'Only linux/amd64 and linux/arm64 supported' >&2; exit 2; }
    for previous in "${ARCHS[@]}"; do [ "${platform#linux/}" != "$previous" ] || { echo 'Duplicate architecture' >&2; exit 2; }; done
    ARCHS+=("${platform#linux/}")
done
[ "${#ARCHS[@]}" -gt 0 ] || exit 2
for tool in docker python3 tar sha256sum; do command -v "$tool" >/dev/null || { echo "$tool required" >&2; exit 1; }; done
BUILD_TMP=""
if [ "$APP_SOURCE" == build ]; then
    # A component's build context is a local --*-src directory when given,
    # otherwise a remote tarball (explicit --*-release URL, or the GitHub
    # archive for --source-ref) is downloaded and extracted.
    resolve_src() {
        local local_dir="$1" url="$2" name="$3"
        if [ -n "$local_dir" ]; then
            local abs; abs="$(cd "$local_dir" 2>/dev/null && pwd)" || { echo "$name: source not found: $local_dir" >&2; return 1; }
            [ -f "$abs/Dockerfile" ] || { echo "$name: no Dockerfile in $abs" >&2; return 1; }
            printf '%s\n' "$abs"; return 0
        fi
        [ -n "$url" ] || { echo "$name: give --${name%-center}-src, --${name%-center}-release or --source-ref" >&2; return 1; }
        command -v curl >/dev/null || { echo "curl required for remote $name source" >&2; return 1; }
        mkdir -p "$BUILD_TMP/$name"
        curl -fSL -o "$BUILD_TMP/${name}.tar.gz" "$url" || { echo "$name download failed: $url" >&2; return 1; }
        tar -xzf "$BUILD_TMP/${name}.tar.gz" -C "$BUILD_TMP/$name"
        [ -f "$BUILD_TMP/$name/Dockerfile" ] && { printf '%s\n' "$BUILD_TMP/$name"; return 0; }
        for d in "$BUILD_TMP/$name"/*/; do [ -f "$d/Dockerfile" ] && { printf '%s\n' "$d"; return 0; }; done
        echo "$name: no Dockerfile after extracting $url" >&2; return 1
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
    [ -f "$ORCHESTRATION_SRC/workflow-designer/Dockerfile" ] || { echo 'orchestration-center source lacks workflow-designer/Dockerfile' >&2; exit 1; }
fi
# Portal is NOT built from source here — it uses a different build pipeline
# (containerized/build/portal/); this builder pulls it from the registry.
if [ "$APP_SOURCE" == tars ]; then [ -d "$APP_TARS_DIR" ] || { echo '--app-tars-dir required' >&2; exit 2; }; fi
mkdir -p "$OUT_DIR"
BUNDLE="$(cd "$OUT_DIR" && pwd)/openan-offline-compose-$TAG"
# Never recursively remove a caller-specified/previous bundle. A failed build
# leaves only its own partial output for diagnosis; it never publishes a tar.
[ ! -e "$BUNDLE" ] && [ ! -e "$BUNDLE.tar.gz" ] || { echo 'Output exists; choose a fresh output/tag' >&2; exit 1; }
mkdir -p "$BUNDLE/images" "$BUNDLE/deps" "$BUNDLE/scripts/lib" "$BUNDLE/compose/init"
for script in install.sh check-env.sh uninstall.sh configure.py gen-secrets.sh; do cp "$SOURCE/scripts/$script" "$BUNDLE/scripts/"; done
cp "$SOURCE/scripts/lib/common.sh" "$BUNDLE/scripts/lib/"
cp "$SOURCE/compose/init/create-databases.sh" "$SOURCE/compose/init/create-mysql-databases.sh" "$BUNDLE/compose/init/"
cp "$SOURCE/config.env.example" "$BUNDLE/"
mkdir -p "$BUNDLE/tool"
cp "$SOURCE/tool/gen-certs.sh" "$BUNDLE/tool/"
mkdir -p "$BUNDLE/templates"
for template in registry.env.example orchestration.env.example models.yaml.example integration_credentials.conf.example; do
    cp "$SOURCE/templates/$template" "$BUNDLE/templates/"
done
cp "$SOURCE/README.md" "$BUNDLE/"
mkdir -p "$BUNDLE/docs"; cp "$SOURCE/docs/DEPENDENCIES.md" "$BUNDLE/docs/"
# With umask077, cp produces0600. +x would produce0711, unreadable to the
# unprivileged MySQL/PostgreSQL entrypoint user that runs these public scripts.
chmod 0755 "$BUNDLE/scripts/"*.sh "$BUNDLE/tool/"*.sh "$BUNDLE/compose/init/"*.sh
RC="$APP_REGISTRY/registry-center:${REGISTRY_TAG:-$TAG}"; OC="$APP_REGISTRY/orchestration-center:${ORCHESTRATION_TAG:-$TAG}"; UI="$APP_REGISTRY/workflow-designer:${ORCHESTRATION_TAG:-$TAG}"; PORTAL="$APP_REGISTRY/openan-portal:${PORTAL_TAG:-$TAG}"
declare -A REFS=([registry-center]="$RC" [orchestration-center]="$OC" [workflow-designer]="$UI" [postgres]="postgres:15-alpine" [mysql]="mysql:8.4" [nginx]="nginx:1.27.5-alpine")
for arch in "${ARCHS[@]}"; do
    for component in registry-center orchestration-center workflow-designer postgres mysql nginx; do
        ref="${REFS[$component]}"
        echo "Preparing $component ($arch)"
        if [[ "$component" == postgres || "$component" == mysql || "$component" == nginx || "$APP_SOURCE" == pull ]]; then
            docker pull --platform "linux/$arch" "$ref"
        elif [ "$APP_SOURCE" == build ]; then
            case "$component" in registry-center) context="$REGISTRY_SRC" ;; orchestration-center) context="$ORCHESTRATION_SRC" ;; workflow-designer) context="$ORCHESTRATION_SRC/workflow-designer" ;; esac
            docker buildx build --platform "linux/$arch" --load -t "$ref" "$context"
        else
            tarfile="$APP_TARS_DIR/$component-$arch.tar"
            [ -s "$tarfile" ] || { echo "Missing image tar: $component-$arch.tar" >&2; exit 1; }
            docker load -i "$tarfile"
        fi
        actual="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$ref")"
        [ "$actual" == "linux/$arch" ] || { echo "Wrong image architecture: $component ($arch)" >&2; exit 1; }
        docker save -o "$BUNDLE/images/$component-$arch.tar" "$ref"
        [ -s "$BUNDLE/images/$component-$arch.tar" ] || { echo 'Empty saved image' >&2; exit 1; }
    done
done
# Optional portal frontend. The image is not published yet: a failed pull only
# downgrades the bundle to FRONTEND_TYPE=workflow-designer instead of failing
# the release, so deps/image-tags.json records portal only when every requested
# architecture produced a tar.
PORTAL_ARCHES=0
for arch in "${ARCHS[@]}"; do
    echo "Preparing portal ($arch)"
    if [ "$APP_SOURCE" == tars ] && [ -s "$APP_TARS_DIR/portal-$arch.tar" ]; then
        docker load -i "$APP_TARS_DIR/portal-$arch.tar"
    elif ! docker pull --platform "linux/$arch" "$PORTAL"; then
        log_warn "portal image unavailable for $arch; bundle supports only FRONTEND_TYPE=workflow-designer"
        continue
    fi
    actual="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$PORTAL")"
    [ "$actual" == "linux/$arch" ] || { echo "Wrong image architecture: portal ($arch)" >&2; exit 1; }
    docker save -o "$BUNDLE/images/portal-$arch.tar" "$PORTAL"
    [ -s "$BUNDLE/images/portal-$arch.tar" ] || { echo 'Empty saved image' >&2; exit 1; }
    PORTAL_ARCHES=$((PORTAL_ARCHES + 1))
done
PORTAL_TAG=""
if [ "$PORTAL_ARCHES" -eq "${#ARCHS[@]}" ]; then PORTAL_TAG="$PORTAL"; fi
[ -n "$BUILD_TMP" ] && rm -rf "$BUILD_TMP"
# Extract files without running the foreign-architecture frontend process.
docker load -i "$BUNDLE/images/workflow-designer-${ARCHS[0]}.tar"
cid="$(docker create --platform "linux/${ARCHS[0]}" "$UI")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
mkdir -p "$BUNDLE/web"
docker cp "$cid:/usr/share/nginx/html/." "$BUNDLE/web/"
[ -s "$BUNDLE/web/index.html" ] || { echo 'Frontend index.html missing' >&2; exit 1; }
find "$BUNDLE/web" -type d -exec chmod 0755 {} +
find "$BUNDLE/web" -type f -exec chmod 0644 {} +
docker rm -f "$cid" >/dev/null; trap - EXIT
python3 - "$BUNDLE/deps/image-tags.json" "$PLATFORMS" "$RC" "$OC" "$UI" "$PORTAL_TAG" <<'PY'
import json, sys
images = dict(zip(['registry-center','orchestration-center','workflow-designer','postgres','nginx','mysql'],
                  [*sys.argv[3:6], 'postgres:15-alpine','nginx:1.27.5-alpine','mysql:8.4']))
if sys.argv[6]:
    images['portal'] = sys.argv[6]
# str.removeprefix is Python 3.9+; use a compatible slice for older build hosts
archs = [p.split('/', 1)[1] if p.startswith('linux/') else p
         for p in sys.argv[2].split(',')]
with open(sys.argv[1], 'w', encoding='utf-8') as stream:
    json.dump({'architectures': archs, 'images': images}, stream, indent=2)
PY
(cd "$BUNDLE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
tar -C "$(dirname "$BUNDLE")" -czf "$BUNDLE.tar.gz" "$(basename "$BUNDLE")"
echo "Done. Offline bundle: $BUNDLE.tar.gz"
