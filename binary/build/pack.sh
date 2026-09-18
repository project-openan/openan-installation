#!/bin/bash

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

# =============================================================================
# pack.sh - Unified offline packager for OpenAN
#
# Merges pack_orc.sh and pack_reg.sh into a single script with
# --reg/--orc flag design (consistent with one-click install.sh).
#
# Run this on the ONLINE machine to build self-contained offline deployment
# packages. Each component produces an independent tarball in dist/.
#
# Usage:
#   ./pack.sh              # Pack both (default)
#   ./pack.sh --reg        # Pack only registry-center
#   ./pack.sh --orc        # Pack only orchestration-center
#   ./pack.sh --reg --orc  # Pack both
#   ./pack.sh --reg --orc-version v1.1.0
#                          # Pack registry-center (default) + orchestration-center v1.1.0
#                          # (--orc-version also selects orchestration-center, ADR-024)
#
# Prerequisites on the online machine:
#   - Python 3.12+ (required)
#   - Node.js 20.19+ + npm (required for --orc)
#   - curl, tar (for source download and extraction)
#   - Internet access (for source download, pip download and npm install)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Argument parsing: --reg | --orc | --help + version flags
# Component selection: every flag that names a component selects it.
#   General flags:  --reg, --orc                          (default version)
#   Specific flags: --reg-version, --orc-version          (pinned source tag)
# Selection is the union of all component flags, is order-independent, and
# defaults to both components when no component flag is given.
# =============================================================================
# Track flag presence for order-independent selection
REG_GENERAL=false        # --reg given
ORC_GENERAL=false        # --orc given
REG_SPECIFIED=false      # --reg-version given
ORC_SPECIFIED=false      # --orc-version given
PACK_REGISTRY=true
PACK_ORCHESTRATION=true
REG_VERSION_FLAG=""
ORC_VERSION_FLAG=""

print_usage() {
    cat << 'USAGE_EOF'
Usage: pack.sh [OPTIONS]

Component selection: every flag that names a component selects it.
General flags select at the default version; specific flags select AND pin
the source tag. Selection is order-independent.

Options:
  --reg                Pack registry-center (default version)
  --orc                Pack orchestration-center (default version)
                       (default: both if no component flag is specified)
  --reg-version <tag>  registry-center source tag (default: v1.0.0);
                       also selects registry-center
  --orc-version <tag>  orchestration-center source tag (default: v1.0.0);
                       also selects orchestration-center
  -h, --help           Show this help message and exit

Version overrides (precedence: flag > built-in default):
  Tags accept "v1.1.0" or "1.1.0"; the tarball name strips the leading "v".

Examples:
  ./pack.sh                              # Pack everything (default: --reg --orc)
  ./pack.sh --reg                        # Pack only registry-center
  ./pack.sh --orc                        # Pack only orchestration-center
  ./pack.sh --reg --orc                  # Pack both
  ./pack.sh --reg --orc-version v1.1.0   # registry-center (default) + orchestration-center v1.1.0
  ./pack.sh --orc-version v1.1.0         # Pack only orchestration-center v1.1.0
USAGE_EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --reg)
            REG_GENERAL=true
            shift
            ;;
        --orc)
            ORC_GENERAL=true
            shift
            ;;
        --reg-version)
            REG_VERSION_FLAG="$2"
            REG_SPECIFIED=true
            shift 2
            ;;
        --orc-version)
            ORC_VERSION_FLAG="$2"
            ORC_SPECIFIED=true
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

# Component selection: union of general and specific flags (ADR-024).
# A specific flag (--reg-version/--orc-version) selects
# its component just like the general flag does, so e.g.
#   ./pack.sh --reg --orc-version v1.0.0
# packs registry-center (default version) AND orchestration-center v1.0.0.
if [ "${REG_GENERAL}" = "true" ] || [ "${REG_SPECIFIED}" = "true" ]; then
    PACK_REGISTRY=true
else
    PACK_REGISTRY=false
fi
if [ "${ORC_GENERAL}" = "true" ] || [ "${ORC_SPECIFIED}" = "true" ]; then
    PACK_ORCHESTRATION=true
else
    PACK_ORCHESTRATION=false
fi

# No component flag at all -> pack both (consistent with one-click install.sh).
if [ "${REG_GENERAL}" = "false" ] && [ "${ORC_GENERAL}" = "false" ] \
   && [ "${REG_SPECIFIED}" = "false" ] && [ "${ORC_SPECIFIED}" = "false" ]; then
    PACK_REGISTRY=true
    PACK_ORCHESTRATION=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Constants & version/source resolution
# =============================================================================
OUTPUT_DIR="${SCRIPT_DIR}/dist"
PYTHON_VERSION="3.12"

# Built-in defaults, overridable via flags (precedence: flag > default)
DEFAULT_REGISTRY_VERSION="v1.0.0"
DEFAULT_ORCHESTRATION_VERSION="v1.0.0"
REGISTRY_SOURCE_BASE="https://github.com/project-openan/registry-center/archive/refs/tags"
ORCHESTRATION_SOURCE_BASE="https://github.com/project-openan/orchestration-center/archive/refs/tags"

# Accept "v1.1.0" or "1.1.0" (plain numbers get the "v" prefix); pass custom tags through
normalize_tag() {
    case "$1" in
        v*) echo "$1" ;;
        [0-9]*) echo "v$1" ;;
        *) echo "$1" ;;
    esac
}

# --- registry-center: tag ---
REGISTRY_VERSION_SOURCE="default"
if [ -n "${REG_VERSION_FLAG}" ]; then REGISTRY_VERSION_SOURCE="flag"; fi
REGISTRY_VERSION="$(normalize_tag "${REG_VERSION_FLAG:-${DEFAULT_REGISTRY_VERSION}}")"
# Package (tarball) version is derived from the tag, with the leading "v" stripped
REGISTRY_PKG_VERSION="${REGISTRY_VERSION#v}"
# Source URL is always derived from the built-in GitHub base + tag
# (official GitHub source only, no override)
REGISTRY_SOURCE_URL="${REGISTRY_SOURCE_BASE}/${REGISTRY_VERSION}.tar.gz"

# --- orchestration-center: tag ---
ORCHESTRATION_VERSION_SOURCE="default"
if [ -n "${ORC_VERSION_FLAG}" ]; then ORCHESTRATION_VERSION_SOURCE="flag"; fi
ORCHESTRATION_VERSION="$(normalize_tag "${ORC_VERSION_FLAG:-${DEFAULT_ORCHESTRATION_VERSION}}")"
ORCHESTRATION_PKG_VERSION="${ORCHESTRATION_VERSION#v}"
ORCHESTRATION_SOURCE_URL="${ORCHESTRATION_SOURCE_BASE}/${ORCHESTRATION_VERSION}.tar.gz"

# Platform tags for each architecture (newer packages like cryptography require manylinux_2_28+)
PIP_PLATFORMS_X86_64=(
    "manylinux_2_34_x86_64"
    "manylinux_2_28_x86_64"
    "manylinux_2_17_x86_64"
    "manylinux2014_x86_64"
)
PIP_PLATFORMS_AARCH64=(
    "manylinux_2_34_aarch64"
    "manylinux_2_28_aarch64"
    "manylinux_2_17_aarch64"
    "manylinux2014_aarch64"
)

# =============================================================================
# Helper function: download wheels for a specific architecture
# Args: arch_name, requirements_file, wheels_dir, platform_tags...
# Uses global: VENV_PACKAGING_DIR, PYTHON_VERSION
# =============================================================================
download_wheels_for_arch() {
    local arch_name="$1"
    local requirements_file="$2"
    local wheels_dir="$3"
    shift 3
    local platforms=("$@")
    local flags=()
    for p in "${platforms[@]}"; do
        flags+=("--platform" "$p")
    done

    echo -e "  ${YELLOW}Downloading binary wheels for ${arch_name}...${NC}"
    "${VENV_PACKAGING_DIR}/bin/pip" install --upgrade pip wheel >/dev/null 2>&1
    # NOTE: no '|| true' here — a failed download must abort the pack run so
    # the error surfaces at pack time, not at install time (see ADR-018).
    "${VENV_PACKAGING_DIR}/bin/pip" download \
        -r "$requirements_file" \
        "${flags[@]}" \
        --python-version "$PYTHON_VERSION" \
        --only-binary=:all: \
        --dest "$wheels_dir" \
        2>&1 | sed 's/^/  /'
}

# =============================================================================
# Pack registry-center
# =============================================================================
pack_registry() {
    local pkg_name="registry-center-${REGISTRY_PKG_VERSION}-linux"
    local build_dir="${OUTPUT_DIR}/build/${pkg_name}"
    local wheels_dir="${build_dir}/vendor/wheels"

    echo -e "${BLUE}--- Packing registry-center ---${NC}"
    echo ""

    # Clean previous build
    echo -e "${YELLOW}Cleaning previous build...${NC}"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    echo -e "  ${GREEN}✓${NC} Build directory ready: $build_dir"
    echo ""

    # Download project source
    echo -e "${YELLOW}Downloading project source ${REGISTRY_VERSION}...${NC}"
    local tmp_tar
    tmp_tar=$(mktemp /tmp/registry-center-source-XXXXXX.tar.gz)
    if ! curl -fsSL "${REGISTRY_SOURCE_URL}" -o "${tmp_tar}"; then
        echo -e "${RED}Error: Failed to download registry-center source ${REGISTRY_VERSION} from:${NC}"
        echo -e "${RED}  ${REGISTRY_SOURCE_URL}${NC}"
        rm -f "${tmp_tar}"
        exit 1
    fi
    tar -xzf "${tmp_tar}" -C "${build_dir}" --strip-components=1
    rm -f "${tmp_tar}"
    echo -e "  ${GREEN}✓${NC} Source downloaded and extracted"
    echo ""

    # Clean unnecessary files
    find "$build_dir" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find "$build_dir" -type f -name "*.pyc" -delete 2>/dev/null || true
    rm -rf "${build_dir}/bin/package_offline.sh" 2>/dev/null || true

    # Create empty runtime directories
    mkdir -p "${build_dir}/log" "${build_dir}/run" "${build_dir}/data"

    # Download wheel packages for both architectures
    echo -e "${YELLOW}Downloading wheel packages for x86_64 and aarch64...${NC}"
    mkdir -p "$wheels_dir"

    download_wheels_for_arch "x86_64" "${build_dir}/requirements.txt" "$wheels_dir" "${PIP_PLATFORMS_X86_64[@]}"
    download_wheels_for_arch "aarch64" "${build_dir}/requirements.txt" "$wheels_dir" "${PIP_PLATFORMS_AARCH64[@]}"

    # Verify wheels were downloaded
    local wheel_count x86_count aarch64_count
    wheel_count=$(find "$wheels_dir" -name "*.whl" | wc -l)
    x86_count=$(find "$wheels_dir" -name "*.whl" | grep -i "x86_64" | wc -l)
    aarch64_count=$(find "$wheels_dir" -name "*.whl" | grep -i "aarch64" | wc -l)
    if [ "$wheel_count" -eq 0 ]; then
        echo -e "${RED}Error: No wheel packages downloaded. Check network and platform settings.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Downloaded ${wheel_count} wheel packages (x86_64: ${x86_count}, aarch64: ${aarch64_count})"
    echo ""

    # Generate README_OFFLINE.txt
    echo -e "${YELLOW}Generating README_OFFLINE.txt...${NC}"
    cat > "${build_dir}/README_OFFLINE.txt" <<EOF
==========================================================
 Registry Center v${REGISTRY_PKG_VERSION} - Offline Deployment Package
 Target: linux/x86_64, aarch64 | Python ${PYTHON_VERSION}
==========================================================

This package contains wheels for both x86_64 and aarch64 architectures.
The setup script will auto-detect the current machine architecture and
install the appropriate wheels.

Prerequisites:
  - Linux x86_64 or aarch64
  - Python ${PYTHON_VERSION} (pre-installed)
  - No internet connection required

Quick Start:
  Copy this tarball and install.sh into the SAME directory, then run:
  ./install.sh --reg

  It handles everything: extraction, venv creation, dependency
  installation, certificate generation, auto-configuration, and
  service start.

Configuration (can be re-run anytime):
  ./configure_llm.sh --reg

  Or manually edit:
  - etc/conf/server.conf       (IP, port, TLS, signing)
  - etc/conf/persistence.conf  (storage mode: file/postgresql)
  - common/config/llm_config.json (LLM API key, optional)

Directory Layout:
  agent_registry/       Application source code
  common/               Shared modules and config templates
  etc/conf/             Configuration files
  etc/systemd/          Systemd service templates
  bin/                  Operational scripts
  vendor/wheels/        Pre-downloaded Python wheel packages (x86_64 + aarch64)
  venv/                 Virtual environment (created by install.sh)
  log/                  Runtime logs
  run/                  Runtime PID/socket files
  data/                 File-based storage data
EOF
    echo -e "  ${GREEN}✓${NC} README generated"
    echo ""

    # Create tarball
    echo -e "${YELLOW}Creating archive...${NC}"
    mkdir -p "$OUTPUT_DIR"
    tar -czf "${OUTPUT_DIR}/${pkg_name}.tar.gz" -C "${OUTPUT_DIR}/build" "$pkg_name"

    # Cleanup build directory
    rm -rf "$build_dir"

    local archive_size
    archive_size=$(du -h "${OUTPUT_DIR}/${pkg_name}.tar.gz" | cut -f1)
    echo -e "  ${GREEN}✓${NC} Tarball created: ${OUTPUT_DIR}/${pkg_name}.tar.gz (${archive_size})"
    echo ""
}

# =============================================================================
# Pack orchestration-center
# =============================================================================
pack_orchestration() {
    local pkg_name="orchestration-center-${ORCHESTRATION_PKG_VERSION}-linux"
    local build_dir="${OUTPUT_DIR}/build/${pkg_name}"
    local wheels_dir="${build_dir}/vendor/wheels"

    echo -e "${BLUE}--- Packing orchestration-center ---${NC}"
    echo ""

    # Clean previous build
    echo -e "${YELLOW}Cleaning previous build...${NC}"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    echo -e "  ${GREEN}✓${NC} Build directory ready: $build_dir"
    echo ""

    # Download project source
    echo -e "${YELLOW}Downloading project source ${ORCHESTRATION_VERSION}...${NC}"
    local tmp_tar
    tmp_tar=$(mktemp /tmp/orchestration-center-source-XXXXXX.tar.gz)
    if ! curl -fsSL "${ORCHESTRATION_SOURCE_URL}" -o "${tmp_tar}"; then
        echo -e "${RED}Error: Failed to download orchestration-center source ${ORCHESTRATION_VERSION} from:${NC}"
        echo -e "${RED}  ${ORCHESTRATION_SOURCE_URL}${NC}"
        rm -f "${tmp_tar}"
        exit 1
    fi

    # Extract to a temp source dir, then rsync to build dir with excludes
    local tmp_source
    tmp_source=$(mktemp -d /tmp/orchestration-center-src-XXXXXX)
    tar -xzf "${tmp_tar}" -C "${tmp_source}" --strip-components=1
    rm -f "${tmp_tar}"

    if command -v rsync &>/dev/null; then
        rsync -a \
            --exclude='.git' \
            --exclude='__pycache__' \
            --exclude='*.pyc' \
            --exclude='.venv' \
            --exclude='venv' \
            --exclude='node_modules' \
            --exclude='.pytest_cache' \
            --exclude='.ruff_cache' \
            --exclude='.mypy_cache' \
            --exclude='/log/' \
            --exclude='/run/' \
            --exclude='*.log' \
            "$tmp_source/" "$build_dir/"
    else
        # Fallback: cp + manual cleanup
        cp -r "$tmp_source"/* "$build_dir/"
        cp -r "$tmp_source"/.??* "$build_dir/" 2>/dev/null || true
        rm -rf "$build_dir/.git"
        find "$build_dir" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
        find "$build_dir" -name '*.pyc' -delete 2>/dev/null || true
        rm -rf "$build_dir/.venv" "$build_dir/venv" "$build_dir/workflow-designer/node_modules"
        rm -rf "$build_dir/.pytest_cache" "$build_dir/.ruff_cache" "$build_dir/.mypy_cache"
    fi
    rm -rf "$tmp_source"
    echo -e "  ${GREEN}✓${NC} Source downloaded and copied"
    echo ""

    # Download Python wheels for both architectures
    echo -e "${YELLOW}Downloading Python wheels (x86_64 + aarch64)...${NC}"
    mkdir -p "$wheels_dir"

    download_wheels_for_arch "x86_64" "${build_dir}/requirements.txt" "$wheels_dir" "${PIP_PLATFORMS_X86_64[@]}"
    download_wheels_for_arch "aarch64" "${build_dir}/requirements.txt" "$wheels_dir" "${PIP_PLATFORMS_AARCH64[@]}"

    # Verify wheels were downloaded
    local wheel_count x86_count aarch64_count
    wheel_count=$(find "$wheels_dir" -name "*.whl" | wc -l)
    x86_count=$(find "$wheels_dir" -name "*.whl" | grep -i "x86_64" | wc -l)
    aarch64_count=$(find "$wheels_dir" -name "*.whl" | grep -i "aarch64" | wc -l)
    if [ "$wheel_count" -eq 0 ]; then
        echo -e "${RED}Error: No wheel packages downloaded. Check network and requirements.txt.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Wheels downloaded: ${wheel_count} total (x86_64: ${x86_count}, aarch64: ${aarch64_count})"
    echo ""

    # Prepare npm cache for offline frontend build
    echo -e "${YELLOW}Preparing npm cache for offline frontend build...${NC}"
    local frontend_dir="${build_dir}/workflow-designer"
    cd "$frontend_dir"

    echo -e "  ${YELLOW}Running npm install to fill cache (this may take a while)...${NC}"
    echo -e "  ${YELLOW}(node_modules will NOT be bundled — built on the target machine)${NC}"
    npm install --force
    echo -e "  ${GREEN}✓${NC} npm install completed (cache populated)"

    # Copy npm cache for offline use
    local npm_cache_dir="${build_dir}/vendor/npm-cache"
    mkdir -p "$npm_cache_dir"
    npm cache verify 2>/dev/null || true
    local npm_global_cache
    npm_global_cache=$(npm config get cache 2>/dev/null || echo "")
    if [ -n "$npm_global_cache" ] && [ -d "$npm_global_cache" ]; then
        cp -r "$npm_global_cache"/* "$npm_cache_dir/" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} npm cache copied to vendor/npm-cache/"
    else
        echo -e "  ${YELLOW}⚠ npm cache not found, frontend offline build may fail${NC}"
    fi

    # Clean up node_modules — not bundled (target machine will rebuild from cache)
    rm -rf "$frontend_dir/node_modules"
    cd "$SCRIPT_DIR"
    echo ""

    # Ensure bin scripts are executable
    echo -e "${YELLOW}Ensuring scripts are executable...${NC}"
    chmod +x "${build_dir}/bin/"*.sh 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Scripts are executable"
    echo ""

    # Create bundle manifest
    echo -e "${YELLOW}Creating manifest...${NC}"
    local manifest="${build_dir}/OFFLINE_BUNDLE_MANIFEST.txt"
    cat > "$manifest" << EOF
============================================================
  Orchestration Center - Offline Deployment Bundle
============================================================

Bundle created:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Created on host:   $(hostname)
Python version:    $("$PYTHON_BIN" --version)
Node.js version:   $(node --version)
npm version:       $(npm --version)
Target archs:      x86_64, aarch64

Contents:
  - Project source code (Python + React)
  - vendor/wheels/       — Pre-downloaded Python wheels (x86_64 + aarch64)
  - vendor/npm-cache/    — npm cache for offline frontend build
  - etc/conf/            — Configuration files (EDIT THESE on target machine)
  - common/config/       — LLM configuration (EDIT THESE on target machine)

Note: venv and node_modules are NOT pre-built. They will be created on the
target machine from the bundled wheels and npm cache. This ensures architecture
compatibility (the target machine may have a different CPU architecture).

To install on the air-gapped machine:
  Copy this tarball and install.sh into the SAME directory, then run
  ./install.sh --orc — it handles everything: extraction, venv creation,
  dependency installation, frontend build, nginx configuration, and
  service start.

EOF
    echo -e "  ${GREEN}✓${NC} Manifest created"
    echo ""

    # Create the tarball
    echo -e "${YELLOW}Creating tarball...${NC}"
    mkdir -p "$OUTPUT_DIR"
    tar -czf "${OUTPUT_DIR}/${pkg_name}.tar.gz" -C "${OUTPUT_DIR}/build" "$pkg_name"

    # Cleanup build directory
    rm -rf "$build_dir"

    local archive_size
    archive_size=$(du -h "${OUTPUT_DIR}/${pkg_name}.tar.gz" | cut -f1)
    echo -e "  ${GREEN}✓${NC} Tarball created: ${OUTPUT_DIR}/${pkg_name}.tar.gz (${archive_size})"
    echo ""
}

# =============================================================================
# Print mode info
# =============================================================================
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  OpenAN Offline Packager${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "  Pack targets:"
echo -e "    registry-center:       ${PACK_REGISTRY}"
echo -e "    orchestration-center:  ${PACK_ORCHESTRATION}"
echo -e "  Versions (flag > default):"
echo -e "    registry-center:       ${REGISTRY_VERSION} (${REGISTRY_VERSION_SOURCE})"
echo -e "      ${REGISTRY_SOURCE_URL}"
echo -e "    orchestration-center:  ${ORCHESTRATION_VERSION} (${ORCHESTRATION_VERSION_SOURCE})"
echo -e "      ${ORCHESTRATION_SOURCE_URL}"
echo -e "  Target archs:    x86_64, aarch64"
echo -e "  Python version:  ${PYTHON_VERSION}"
echo -e "  Output:          ${OUTPUT_DIR}"
echo ""

# =============================================================================
# Check prerequisites
# =============================================================================
echo -e "${YELLOW}Checking prerequisites...${NC}"

# Check Python 3.12+
PYTHON_BIN=""
for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" &>/dev/null; then
        CAND_VERSION=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        CAND_MAJOR=$(echo "$CAND_VERSION" | cut -d. -f1)
        CAND_MINOR=$(echo "$CAND_VERSION" | cut -d. -f2)
        if [ "$CAND_MAJOR" -eq 3 ] && [ "$CAND_MINOR" -ge 12 ]; then
            PYTHON_BIN="$candidate"
            PY_VERSION="$CAND_VERSION"
            break
        fi
    fi
done
if [ -z "$PYTHON_BIN" ]; then
    echo -e "${RED}Error: Python 3.12+ not found.${NC}"
    echo "       Searched: python3.13, python3.12, python3.11, python3"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Python ${PY_VERSION} ($PYTHON_BIN)"

# Check Node.js and npm (only for orchestration-center)
if [ "${PACK_ORCHESTRATION}" = "true" ]; then
    if ! command -v node &>/dev/null; then
        echo -e "${RED}Error: node not found. Need Node.js 20.19+.${NC}"
        exit 1
    fi
    NODE_VERSION=$(node --version | sed 's/v//')
    echo -e "  ${GREEN}✓${NC} Node.js ${NODE_VERSION}"

    if ! command -v npm &>/dev/null; then
        echo -e "${RED}Error: npm not found.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} npm $(npm --version)"
else
    echo -e "  ${YELLOW}⚠ Node.js/npm check skipped (not needed for registry-only pack).${NC}"
fi

# Check curl and tar (required for source download)
if ! command -v curl &>/dev/null; then
    echo -e "${RED}Error: curl not found. Required to download source code.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} curl (for source download)"
if ! command -v tar &>/dev/null; then
    echo -e "${RED}Error: tar not found. Required to extract source code.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} tar (for source extraction)"
echo ""

# =============================================================================
# Create packaging venv (shared by both components)
# =============================================================================
echo -e "${YELLOW}Creating packaging venv...${NC}"
VENV_PACKAGING_DIR=""
cleanup() {
    [ -n "$VENV_PACKAGING_DIR" ] && rm -rf "$VENV_PACKAGING_DIR"
}
trap cleanup EXIT

VENV_PACKAGING_DIR=$(mktemp -d /tmp/pack-openan-venv-XXXXXX)
"$PYTHON_BIN" -m venv "$VENV_PACKAGING_DIR"
echo -e "  ${GREEN}✓${NC} Packaging venv created: ${VENV_PACKAGING_DIR}"
echo ""

# =============================================================================
# Pack components
# =============================================================================
if [ "${PACK_REGISTRY}" = "true" ]; then
    pack_registry
fi

if [ "${PACK_ORCHESTRATION}" = "true" ]; then
    pack_orchestration
fi

# =============================================================================
# Summary
# =============================================================================
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Package(s) built successfully!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ "${PACK_REGISTRY}" = "true" ]; then
    REG_TARBALL="${OUTPUT_DIR}/registry-center-${REGISTRY_PKG_VERSION}-linux.tar.gz"
    REG_SIZE=$(du -h "$REG_TARBALL" | cut -f1)
    echo "  registry-center:        ${REG_TARBALL} (${REG_SIZE})"
fi
if [ "${PACK_ORCHESTRATION}" = "true" ]; then
    ORC_TARBALL="${OUTPUT_DIR}/orchestration-center-${ORCHESTRATION_PKG_VERSION}-linux.tar.gz"
    ORC_SIZE=$(du -h "$ORC_TARBALL" | cut -f1)
    echo "  orchestration-center:   ${ORC_TARBALL} (${ORC_SIZE})"
fi

echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Copy the tarball(s) and install.sh to the air-gapped machine"
echo "     (USB, SCP, etc.)"
echo "  2. Install:  ./install.sh"
echo ""
echo -e "${BLUE}========================================${NC}"
