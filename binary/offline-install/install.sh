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
# install.sh - Unified offline installer for OpenAN
#
# Merges install_orc.sh and install_reg.sh into a single script with
# --reg/--orc flag design (consistent with one-click install.sh).
#
# Finds tarballs produced by pack.sh, extracts them, creates venvs,
# installs dependencies from local wheels, builds frontend from npm cache,
# configures nginx HTTPS reverse proxy, and starts all services.
#
# Usage:
#   ./install.sh              # Auto-detect and install available package(s)
#   ./install.sh --reg        # Install only registry-center
#   ./install.sh --orc        # Install only orchestration-center
#   ./install.sh --reg --orc  # Install both
#
# Prerequisites on the offline machine:
#   - Python 3.12+ (pre-installed, required)
#   - Node.js 20.19+ + npm (pre-installed, required for --orc)
#   - nginx (pre-installed, required for --orc)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Argument parsing: --reg | --orc | --help
# --reg and --orc are boolean flags; if neither is specified, auto-detect mode
# is enabled (search for available tarballs and install what's found, ADR-022).
# Consistent with one-click install.sh's flag design.
# =============================================================================
REG_FLAG_SET=false
ORC_FLAG_SET=false
AUTO_DETECT=false
INSTALL_REGISTRY=false
INSTALL_ORCHESTRATION=false
USER_REGISTRY_URL=""
START_SAMPLE=false

print_usage() {
    cat << 'USAGE_EOF'
Usage: install.sh [OPTIONS]

Options:
  --reg          Install registry-center
  --orc          Install orchestration-center
                 (default: auto-detect available packages if neither specified)
  --sample       Start agents examples server (port 8080, off by default)
  -h, --help     Show this help message and exit

Examples:
  ./install.sh                 # Auto-detect and install available package(s)
  ./install.sh --reg           # Install only registry-center
  ./install.sh --orc           # Install only orchestration-center
  ./install.sh --reg --orc     # Install both
  ./install.sh --reg --orc --sample  # Install everything and start sample agents
USAGE_EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --reg)
            REG_FLAG_SET=true
            INSTALL_REGISTRY=true
            INSTALL_ORCHESTRATION=false
            shift
            ;;
        --orc)
            ORC_FLAG_SET=true
            if [ "${REG_FLAG_SET}" = "true" ]; then
                INSTALL_ORCHESTRATION=true
            else
                INSTALL_REGISTRY=false
                INSTALL_ORCHESTRATION=true
            fi
            shift
            ;;
        --sample)
            START_SAMPLE=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --all)
            echo -e "${RED}Error: --all has been removed. Use --reg --orc (or no flags) instead.${NC}"
            echo "        See: ./install.sh --help"
            exit 1
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

# If neither --reg nor --orc was specified, enable auto-detect mode.
# Step 1 will search for available tarballs and set flags accordingly (ADR-022).
if [ "${REG_FLAG_SET}" = "false" ] && [ "${ORC_FLAG_SET}" = "false" ]; then
    AUTO_DETECT=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${CERT_PASSWORD:-}" ]; then
    # /dev/urandom instead of openssl rand: offline machines may lack openssl
    CERT_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
fi

# Initialize PIDs for dynamic summary
REGISTRY_PID=""
OC_BACKEND_PID=""
AGENTS_PID=""
NGINX_PID=""

# =============================================================================
# Helper functions
# =============================================================================

run_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

free_port() {
    local port="$1"
    local pids=""
    if command -v fuser >/dev/null 2>&1; then
        pids="$(fuser "${port}/tcp" 2>/dev/null)" || true
    elif command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -t -i:"${port}" 2>/dev/null)" || true
    elif command -v ss >/dev/null 2>&1; then
        pids="$(ss -tlnp 2>/dev/null | grep ":${port}\b" | grep -oE 'pid=[0-9]+' | cut -d= -f2)" || true
    fi
    if [ -n "${pids}" ]; then
        echo -e "${YELLOW}  Port ${port} is in use, killing PID(s): ${pids}...${NC}"
        echo "${pids}" | tr ' ' '\n' | xargs -r kill 2>/dev/null || true
        sleep 1
        echo "${pids}" | tr ' ' '\n' | xargs -r kill -9 2>/dev/null || true
    fi
}

find_nginx_binary() {
    local nginx_bin
    if nginx_bin=$(command -v nginx 2>/dev/null); then
        echo "$nginx_bin"
        return 0
    fi
    for dir in /usr/sbin /sbin; do
        if [ -x "${dir}/nginx" ]; then
            echo "${dir}/nginx"
            return 0
        fi
    done
    return 1
}

# Find wheels directory: check vendor/wheels/ first (new pack.sh),
# then fall back to wheels/ (old pack_reg.sh compatibility)
find_wheels_dir() {
    local root="$1"
    if [ -d "${root}/vendor/wheels" ]; then
        echo "${root}/vendor/wheels"
    elif [ -d "${root}/wheels" ]; then
        echo "${root}/wheels"
    else
        return 1
    fi
}

# Find tarball by component name: search dist/ first, then script directory
find_tarball() {
    local name="$1"
    local tarball=""
    for f in "${SCRIPT_DIR}"/dist/${name}-*.tar.gz; do
        [ -f "$f" ] && tarball="$f" && break
    done
    if [ -z "$tarball" ]; then
        for f in "${SCRIPT_DIR}"/${name}-*.tar.gz; do
            [ -f "$f" ] && tarball="$f" && break
        done
    fi
    echo "$tarball"
}

# Extract tarball with top-level directory detection (ADR-019)
# Sets EXTRACT_RESULT global variable with the extracted directory path
EXTRACT_RESULT=""
extract_tarball() {
    local tarball="$1"
    local label="$2"

    local top_levels top_level_count
    top_levels=$(tar -tzf "$tarball" | cut -d/ -f1 | sort -u)
    top_level_count=$(echo "${top_levels}" | sed '/^$/d' | wc -l)
    if [ "${top_level_count}" -ne 1 ]; then
        echo -e "${RED}Error: Expected tarball to contain exactly ONE top-level directory.${NC}"
        echo "       Found: $(echo "${top_levels}" | tr '\n' ' ')"
        exit 1
    fi
    local extract_dir="${SCRIPT_DIR}/${top_levels}"

    if [ -d "$extract_dir" ]; then
        echo -e "${YELLOW}  Directory already exists: ${extract_dir}${NC}"
        read -r -p "  Overwrite? (y/n): " choice < /dev/tty || choice=""
        case "$choice" in
            [Yy]|[Yy][Ee][Ss])
                rm -rf "$extract_dir"
                tar -xzf "$tarball" -C "$SCRIPT_DIR"
                echo -e "  ${GREEN}✓${NC} Extracted (overwritten)."
                ;;
            *)
                echo -e "  ${GREEN}✓${NC} Using existing directory."
                ;;
        esac
    else
        tar -xzf "$tarball" -C "$SCRIPT_DIR"
        echo -e "  ${GREEN}✓${NC} Extracted to: ${extract_dir}"
    fi
    EXTRACT_RESULT="$extract_dir"
}

# =============================================================================
# Print mode info
# =============================================================================
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  OpenAN Offline Installer${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
if [ "${AUTO_DETECT}" = "true" ]; then
    echo -e "  Mode: ${YELLOW}auto-detect${NC} (no --reg/--orc specified)"
    echo -e "  Will search for available packages and install what's found."
else
    echo -e "  Install targets:"
    echo -e "    registry-center:       ${INSTALL_REGISTRY}"
    echo -e "    orchestration-center:  ${INSTALL_ORCHESTRATION}"
fi
echo -e "  sample agents:         ${START_SAMPLE}"
echo ""

# =============================================================================
# Step 1: Find tarballs
# =============================================================================
echo -e "${YELLOW}Step 1: Finding offline packages...${NC}"

REG_TARBALL=""
ORC_TARBALL=""

if [ "${AUTO_DETECT}" = "true" ]; then
    # Auto-detect mode: search for both tarballs, install what's found (ADR-022)
    REG_TARBALL=$(find_tarball "registry-center")
    ORC_TARBALL=$(find_tarball "orchestration-center")

    if [ -n "$REG_TARBALL" ]; then
        INSTALL_REGISTRY=true
        echo -e "  ${GREEN}✓${NC} Found: ${REG_TARBALL}"
    else
        echo -e "  ${YELLOW}⚠ registry-center tarball not found.${NC}"
    fi

    if [ -n "$ORC_TARBALL" ]; then
        INSTALL_ORCHESTRATION=true
        echo -e "  ${GREEN}✓${NC} Found: ${ORC_TARBALL}"
    else
        echo -e "  ${YELLOW}⚠ orchestration-center tarball not found.${NC}"
    fi

    if [ "${INSTALL_REGISTRY}" = "false" ] && [ "${INSTALL_ORCHESTRATION}" = "false" ]; then
        echo -e "${RED}Error: No offline packages found.${NC}"
        echo "       Searched: ${SCRIPT_DIR}/dist/registry-center-*.tar.gz"
        echo "       Searched: ${SCRIPT_DIR}/registry-center-*.tar.gz"
        echo "       Searched: ${SCRIPT_DIR}/dist/orchestration-center-*.tar.gz"
        echo "       Searched: ${SCRIPT_DIR}/orchestration-center-*.tar.gz"
        echo "       Please run pack.sh first to build offline packages."
        exit 1
    fi

    echo ""
    echo -e "  ${BLUE}Auto-detect result:${NC}"
    echo -e "    registry-center:       ${INSTALL_REGISTRY}"
    echo -e "    orchestration-center:  ${INSTALL_ORCHESTRATION}"
else
    if [ "${INSTALL_REGISTRY}" = "true" ]; then
        REG_TARBALL=$(find_tarball "registry-center")
        if [ -z "$REG_TARBALL" ]; then
            echo -e "${RED}Error: No registry-center tarball found.${NC}"
            echo "       Searched: ${SCRIPT_DIR}/dist/registry-center-*.tar.gz"
            echo "       Searched: ${SCRIPT_DIR}/registry-center-*.tar.gz"
            echo "       Please run pack.sh --reg first to build the offline package."
            exit 1
        fi
        echo -e "  ${GREEN}✓${NC} Found: ${REG_TARBALL}"
    fi

    if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
        ORC_TARBALL=$(find_tarball "orchestration-center")
        if [ -z "$ORC_TARBALL" ]; then
            echo -e "${RED}Error: No orchestration-center tarball found.${NC}"
            echo "       Searched: ${SCRIPT_DIR}/dist/orchestration-center-*.tar.gz"
            echo "       Searched: ${SCRIPT_DIR}/orchestration-center-*.tar.gz"
            echo "       Please run pack.sh --orc first to build the offline package."
            exit 1
        fi
        echo -e "  ${GREEN}✓${NC} Found: ${ORC_TARBALL}"
    fi
fi

# --sample requires orchestration-center; warn and disable if not installing it.
# Checked after Step 1 because auto-detect mode resolves INSTALL_ORCHESTRATION there (ADR-022).
if [ "${START_SAMPLE}" = "true" ] && [ "${INSTALL_ORCHESTRATION}" = "false" ]; then
    echo -e "${YELLOW}  ⚠ --sample has no effect without --orc (sample requires orchestration-center).${NC}"
    START_SAMPLE=false
fi
echo ""

# =============================================================================
# Step 2: Extract tarballs
# =============================================================================
echo -e "${YELLOW}Step 2: Extracting packages...${NC}"

REG_ROOT_DIR=""
ORC_ROOT_DIR=""

if [ "${INSTALL_REGISTRY}" = "true" ]; then
    extract_tarball "$REG_TARBALL" "registry-center"
    REG_ROOT_DIR="$EXTRACT_RESULT"
fi

if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    extract_tarball "$ORC_TARBALL" "orchestration-center"
    ORC_ROOT_DIR="$EXTRACT_RESULT"
fi
echo ""

# =============================================================================
# Step 3: Detect architecture and verify bundles
# =============================================================================
echo -e "${YELLOW}Step 3: Detecting system architecture...${NC}"

RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
    x86_64|amd64)
        NORMALIZED_ARCH="x86_64"
        ;;
    aarch64|arm64)
        NORMALIZED_ARCH="aarch64"
        ;;
    *)
        echo -e "${RED}Error: Unsupported architecture '${RAW_ARCH}'. Supported: x86_64, aarch64.${NC}"
        exit 1
        ;;
esac
echo -e "  ${GREEN}✓${NC} Detected: ${RAW_ARCH} → ${NORMALIZED_ARCH}"

# Verify wheels exist for detected architecture in each component
if [ "${INSTALL_REGISTRY}" = "true" ]; then
    REG_WHEELS_DIR=$(find_wheels_dir "$REG_ROOT_DIR") || {
        echo -e "${RED}Error: Wheels directory not found in ${REG_ROOT_DIR}${NC}"
        exit 1
    }
    REG_ARCH_WHEELS=$(find "$REG_WHEELS_DIR" -name "*.whl" 2>/dev/null | grep -i "$NORMALIZED_ARCH" | head -1)
    if [ -z "$REG_ARCH_WHEELS" ]; then
        echo -e "${RED}Error: No wheels found for architecture '${NORMALIZED_ARCH}' in ${REG_WHEELS_DIR}.${NC}"
        exit 1
    fi
    REG_WHEEL_COUNT=$(find "$REG_WHEELS_DIR" -name "*.whl" 2>/dev/null | wc -l)
    echo -e "  ${GREEN}✓${NC} registry-center: ${REG_WHEEL_COUNT} wheels (${NORMALIZED_ARCH} confirmed)"
fi

if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    ORC_WHEELS_DIR=$(find_wheels_dir "$ORC_ROOT_DIR") || {
        echo -e "${RED}Error: Wheels directory not found in ${ORC_ROOT_DIR}${NC}"
        exit 1
    }
    ORC_ARCH_WHEELS=$(find "$ORC_WHEELS_DIR" -name "*.whl" 2>/dev/null | grep -i "$NORMALIZED_ARCH" | head -1)
    if [ -z "$ORC_ARCH_WHEELS" ]; then
        echo -e "${RED}Error: No wheels found for architecture '${NORMALIZED_ARCH}' in ${ORC_WHEELS_DIR}.${NC}"
        exit 1
    fi
    ORC_WHEEL_COUNT=$(find "$ORC_WHEELS_DIR" -name "*.whl" 2>/dev/null | wc -l)
    echo -e "  ${GREEN}✓${NC} orchestration-center: ${ORC_WHEEL_COUNT} wheels (${NORMALIZED_ARCH} confirmed)"

    # Check npm cache
    ORC_NPM_CACHE_DIR="${ORC_ROOT_DIR}/vendor/npm-cache"
    if [ -d "${ORC_ROOT_DIR}/workflow-designer" ] && [ ! -d "$ORC_NPM_CACHE_DIR" ]; then
        echo -e "  ${YELLOW}⚠ npm cache not found, frontend will not be available.${NC}"
    elif [ -d "$ORC_NPM_CACHE_DIR" ]; then
        echo -e "  ${GREEN}✓${NC} npm cache found"
    fi
fi

# Create runtime directories
if [ "${INSTALL_REGISTRY}" = "true" ]; then
    mkdir -p "${REG_ROOT_DIR}/log" "${REG_ROOT_DIR}/run"
fi
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    mkdir -p "${ORC_ROOT_DIR}/log" "${ORC_ROOT_DIR}/run"
fi
echo ""

# =============================================================================
# Step 4: Check prerequisites
# =============================================================================
echo -e "${YELLOW}Step 4: Checking prerequisites...${NC}"

# Check Python 3.12+ (always required)
PYTHON_CMD=""
for candidate in python3.13 python3.12 python3; do
    if command -v "$candidate" &>/dev/null; then
        CAND_VERSION=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        CAND_MAJOR=$(echo "$CAND_VERSION" | cut -d. -f1)
        CAND_MINOR=$(echo "$CAND_VERSION" | cut -d. -f2)
        if [ "$CAND_MAJOR" -eq 3 ] && [ "$CAND_MINOR" -ge 12 ]; then
            PYTHON_CMD="$candidate"
            SYSTEM_PY="$CAND_VERSION"
            break
        fi
    fi
done
if [ -z "$PYTHON_CMD" ]; then
    echo -e "${RED}Error: Python 3.12+ not found.${NC}"
    echo "       Searched: python3.13, python3.12, python3"
    echo "       Please install Python 3.12+ and try again."
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Python ${SYSTEM_PY} ($PYTHON_CMD)"

# Check Node.js 20.19+ and npm (only for orchestration-center)
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    if ! command -v node &>/dev/null; then
        echo -e "${RED}Error: Node.js not found. Need Node.js 20.19+.${NC}"
        echo "       Please install Node.js 20.19+ and try again."
        exit 1
    fi
    NODE_VERSION=$(node --version | sed 's/v//')
    NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d. -f1)
    NODE_MINOR=$(echo "$NODE_VERSION" | cut -d. -f2)
    if [ "$NODE_MAJOR" -lt 20 ] || { [ "$NODE_MAJOR" -eq 20 ] && [ "$NODE_MINOR" -lt 19 ]; }; then
        echo -e "${RED}Error: Node.js 20.19+ required, found v${NODE_VERSION}.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Node.js v${NODE_VERSION}"

    if ! command -v npm &>/dev/null; then
        echo -e "${RED}Error: npm not found. Need npm for frontend build.${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} npm $(npm --version)"

    # Check nginx (required for HTTPS reverse proxy)
    if ! find_nginx_binary >/dev/null 2>&1; then
        echo -e "${RED}Error: nginx not found.${NC}"
        echo "       nginx is required for HTTPS reverse proxy and frontend serving."
        exit 1
    fi
    NGINX_BIN=$(find_nginx_binary)
    echo -e "  ${GREEN}✓${NC} nginx $("$NGINX_BIN" -v 2>&1 | awk '{print $3}')"

    # Check openssl
    if ! command -v openssl &>/dev/null; then
        echo -e "${YELLOW}  ⚠ openssl not found; SSL certificate generation may fail.${NC}"
    else
        echo -e "  ${GREEN}✓${NC} openssl $(openssl version 2>/dev/null | awk '{print $2}')"
    fi
else
    echo -e "  ${YELLOW}⚠ Node.js/npm/nginx check skipped (not needed for registry-only install).${NC}"
fi
echo ""

# =============================================================================
# Step 5: Install registry-center
# =============================================================================
if [ "${INSTALL_REGISTRY}" = "true" ]; then
echo -e "${YELLOW}Step 5: Setting up registry-center...${NC}"

REG_VENV_DIR="${REG_ROOT_DIR}/venv"
REG_REQUIREMENTS_FILE="${REG_ROOT_DIR}/requirements.txt"

cd "$REG_ROOT_DIR"

# Create venv
if [ -d "$REG_VENV_DIR" ]; then
    echo -e "${YELLOW}  venv already exists, recreating...${NC}"
    rm -rf "$REG_VENV_DIR"
fi
"$PYTHON_CMD" -m venv "$REG_VENV_DIR"
echo -e "  ${GREEN}✓${NC} venv created at ${REG_VENV_DIR}"

# Upgrade pip from local wheels
"${REG_VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --no-index --find-links "$REG_WHEELS_DIR" 2>/dev/null || true

# Install dependencies from local wheels (no internet needed)
echo -e "  ${YELLOW}Installing dependencies from wheels (this may take a moment)...${NC}"
if ! "${REG_VENV_DIR}/bin/pip" install --no-index --find-links "$REG_WHEELS_DIR" \
    -r "$REG_REQUIREMENTS_FILE" 2>&1 | sed 's/^/  /'; then
    echo -e "${RED}Error: Failed to install dependencies.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Python dependencies installed"

# Generate self-signed certificates
echo -e "  ${YELLOW}Generating self-signed certificates...${NC}"
REG_CERT_DIR="${REG_ROOT_DIR}/etc/cert"
REG_SSL_DIR="${REG_ROOT_DIR}/etc/ssl"
mkdir -p "$REG_CERT_DIR" "$REG_SSL_DIR"

# CERT_PASSWORD is passed via the process environment, not the command line:
# /proc/<pid>/cmdline is world-readable, environ is same-user/root only (ADR-023).
REG_CERT_DIR="${REG_CERT_DIR}" CERT_PASSWORD="${CERT_PASSWORD}" "${REG_VENV_DIR}/bin/python" -c '
import os
import sys
sys.path.insert(0, ".")
from common.cert.certificate_generator import CertificateGenerator

cert_dir = os.environ["REG_CERT_DIR"]
cert_password = os.environ["CERT_PASSWORD"]
generator = CertificateGenerator(key_algorithm="RSA")
if generator.generate_self_signed_cert(cert_dir, "serverAuth", cert_password):
    print("  Certificate generated.")
else:
    print("  Certificate already exists.")
' || {
    echo -e "${YELLOW}  Warning: Certificate generation failed, continuing anyway.${NC}"
}

# Key is unencrypted at rest; protect it with 0600 permissions (ADR-023)
chmod 600 "${REG_CERT_DIR}/server_key_RSA.pem" 2>/dev/null || true

# Prepare SSL directory with certificate copies expected by server.conf
cp -f "${REG_CERT_DIR}/server_RSA.cer" "${REG_SSL_DIR}/server.cer" 2>/dev/null || true
cp -f "${REG_CERT_DIR}/server_RSA.cer" "${REG_SSL_DIR}/trust.cer" 2>/dev/null || true
cp -f "${REG_CERT_DIR}/server_key_RSA.pem" "${REG_SSL_DIR}/server_key.pem" 2>/dev/null || true
chmod 600 "${REG_SSL_DIR}"/*.pem "${REG_SSL_DIR}"/*.cer 2>/dev/null || true

# Update jwk_private_key_path in server.conf
REG_SERVER_CONF="${REG_ROOT_DIR}/etc/conf/server.conf"
if [ -f "$REG_SERVER_CONF" ]; then
    sed -i 's|^jwk_private_key_path=.*|jwk_private_key_path=etc/ssl/server_key.pem|' "$REG_SERVER_CONF"
fi

# Clean stale agent card data from a previous run (see ADR-009)
if [ -d "${REG_ROOT_DIR}/data" ]; then
    rm -rf "${REG_ROOT_DIR}/data"
    echo -e "  ${GREEN}✓${NC} Cleaned stale data/ directory."
fi

# Run init with automated input
echo -e "  ${YELLOW}Running registry-center initialization...${NC}"
printf '\n\nn\nn\nn\n\n\nn\n\n' | "${REG_VENV_DIR}/bin/python" -m agent_registry.init
echo -e "  ${GREEN}✓${NC} Configuration complete."

cd "$SCRIPT_DIR"
echo ""
else
    echo -e "${YELLOW}Step 5: Setting up registry-center...${NC}"
    echo -e "  ${YELLOW}⚠ Skipped (--orc only, no --reg).${NC}"
    echo ""
fi

# =============================================================================
# Step 6: Install orchestration-center
# =============================================================================
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
echo -e "${YELLOW}Step 6: Setting up orchestration-center...${NC}"

ORC_VENV_DIR="${ORC_ROOT_DIR}/venv"
ORC_REQUIREMENTS_FILE="${ORC_ROOT_DIR}/requirements.txt"
ORC_FRONTEND_DIR="${ORC_ROOT_DIR}/workflow-designer"

cd "$ORC_ROOT_DIR"

# Create venv
if [ -d "$ORC_VENV_DIR" ]; then
    echo -e "${YELLOW}  venv already exists, recreating...${NC}"
    rm -rf "$ORC_VENV_DIR"
fi
"$PYTHON_CMD" -m venv "$ORC_VENV_DIR"
echo -e "  ${GREEN}✓${NC} venv created at ${ORC_VENV_DIR}"

# Upgrade pip from local wheels
"${ORC_VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools --no-index --find-links "$ORC_WHEELS_DIR" 2>/dev/null || true

# Install dependencies from local wheels (no internet needed)
echo -e "  ${YELLOW}Installing dependencies from wheels (this may take a moment)...${NC}"
if ! "${ORC_VENV_DIR}/bin/pip" install --no-index --find-links "$ORC_WHEELS_DIR" \
    -r "$ORC_REQUIREMENTS_FILE" 2>&1 | sed 's/^/  /'; then
    echo -e "${RED}Error: Failed to install dependencies.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Python dependencies installed"

# Build frontend from npm cache
if [ -d "$ORC_FRONTEND_DIR" ] && [ -d "$ORC_NPM_CACHE_DIR" ]; then
    cd "$ORC_FRONTEND_DIR"

    echo -e "  ${YELLOW}Running npm install (offline, from cache)...${NC}"
    npm install --force --cache "$ORC_NPM_CACHE_DIR" --prefer-offline 2>&1 | sed 's/^/  /' || {
        echo -e "${RED}Error: npm install failed.${NC}"
        echo "       The npm cache may be incomplete."
        cd "$SCRIPT_DIR"
        exit 1
    }
    echo -e "  ${GREEN}✓${NC} Frontend dependencies installed"

    echo -e "  ${YELLOW}Building frontend static assets...${NC}"
    npm run build > "${ORC_ROOT_DIR}/log/frontend-build.log" 2>&1 || {
        echo -e "${RED}Error: Frontend build failed.${NC}"
        echo "       Check log: ${ORC_ROOT_DIR}/log/frontend-build.log"
        cd "$SCRIPT_DIR"
        exit 1
    }
    echo -e "  ${GREEN}✓${NC} Frontend built to dist/"

    # Deploy static assets to system web directory (see ADR-014)
    echo -e "  ${YELLOW}Deploying static assets to /var/www/openan/...${NC}"
    run_sudo mkdir -p /var/www/openan
    run_sudo cp -r "${ORC_FRONTEND_DIR}/dist/"* /var/www/openan/
    run_sudo chmod -R 755 /var/www/openan
    echo -e "  ${GREEN}✓${NC} Static assets deployed to /var/www/openan/"

    cd "$ORC_ROOT_DIR"
else
    echo -e "${YELLOW}  Frontend not available (no npm cache or no frontend dir)${NC}"
fi

cd "$SCRIPT_DIR"
echo ""
else
    echo -e "${YELLOW}Step 6: Setting up orchestration-center...${NC}"
    echo -e "  ${YELLOW}⚠ Skipped (--reg only, no --orc).${NC}"
    echo ""
fi

# =============================================================================
# Step 7: Configure LLM & registry URL
# =============================================================================
echo -e "${YELLOW}Step 7: Configuring LLM & registry URL...${NC}"

# --- LLM Configuration ---
# Build LLM_FLAGS from install targets
LLM_FLAGS=""
[ "${INSTALL_REGISTRY}" = "true" ] && LLM_FLAGS="--reg"
[ "${INSTALL_ORCHESTRATION}" = "true" ] && LLM_FLAGS="${LLM_FLAGS} --orc"
LLM_FLAGS="${LLM_FLAGS# }"

echo -e "  ${YELLOW}LLM configuration is required for the chat model.${NC}"
echo ""
echo "  You can skip this step and run configure_llm.sh later."
echo ""
read -r -p "        Skip LLM configuration and configure manually? [y/N]: " SKIP_LLM_INPUT < /dev/tty || SKIP_LLM_INPUT=""
LLM_SKIPPED=false
case "${SKIP_LLM_INPUT}" in
    [yY]|[yY][eE][sS])
        LLM_SKIPPED=true
        echo -e "  ${YELLOW}⚠ LLM configuration skipped.${NC}"
        echo "         Run configure_llm.sh later to configure."
        ;;
esac

if [ "${LLM_SKIPPED}" = "false" ]; then
    echo -e "  ${YELLOW}Starting interactive LLM configuration via configure_llm.sh...${NC}"
    echo ""
    bash "${SCRIPT_DIR}/configure_llm.sh" ${LLM_FLAGS}
else
    echo -e "  ${YELLOW}⚠ LLM configuration skipped. Default values will be used.${NC}"
fi

# Always print configure_llm.sh usage
echo ""
echo -e "  ${YELLOW}To reconfigure LLM at any time:${NC}"
echo "    ./configure_llm.sh --reg --orc"
echo "    ./configure_llm.sh --model <model> --url <url> --api-key <key>"
echo "    LLM_API_KEY=your-key ./configure_llm.sh --model <model> --url <url>"
echo ""

# --- Configure agent_registry_url in orchestration-center server.conf ---
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    ORC_SERVER_CONF="${ORC_ROOT_DIR}/etc/conf/server.conf"
    if [ -f "$ORC_SERVER_CONF" ]; then
        if [ "${INSTALL_REGISTRY}" = "false" ]; then
            # --orc only: prompt for remote registry URL
            DEFAULT_REGISTRY_URL="https://127.0.0.1:5000"
            echo ""
            echo -e "  ${YELLOW}Orchestration-center needs to connect to a running registry-center.${NC}"
            read -r -p "        Enter registry center URL [${DEFAULT_REGISTRY_URL}]: " USER_REGISTRY_URL < /dev/tty || USER_REGISTRY_URL=""
            USER_REGISTRY_URL="${USER_REGISTRY_URL:-${DEFAULT_REGISTRY_URL}}"
            echo -e "  ${GREEN}✓${NC} Registry URL set to: ${USER_REGISTRY_URL}"

            echo -e "  ${YELLOW}Setting agent_registry_url in server.conf...${NC}"
            sed -i "s|^agent_registry_url=.*|agent_registry_url=${USER_REGISTRY_URL}|" "$ORC_SERVER_CONF"
            echo -e "  ${GREEN}✓${NC} server.conf agent_registry_url set to ${USER_REGISTRY_URL}."
        else
            # --reg --orc mode: local registry runs HTTP, fix https->http
            echo -e "  ${YELLOW}Fixing agent_registry_url in server.conf (https -> http)...${NC}"
            sed -i 's|agent_registry_url=https://|agent_registry_url=http://|' "$ORC_SERVER_CONF"
            echo -e "  ${GREEN}✓${NC} server.conf agent_registry_url set to http."
        fi
    else
        echo -e "  ${YELLOW}⚠ server.conf not found at ${ORC_SERVER_CONF}, skipping registry URL fix.${NC}"
    fi
fi

# --- Sample Agents Interactive Prompt ---
if [ "${INSTALL_ORCHESTRATION}" = "true" ] && [ "${START_SAMPLE}" = "false" ]; then
    echo ""
    echo -e "  ${YELLOW}Sample agents server provides demo agents for testing (port 8080).${NC}"
    read -r -p "        Start sample agents server? [y/N]: " START_SAMPLE_INPUT < /dev/tty || START_SAMPLE_INPUT=""
    case "${START_SAMPLE_INPUT}" in
        [yY]|[yY][eE][sS])
            START_SAMPLE=true
            echo -e "  ${GREEN}✓${NC} Sample agents server will be started."
            ;;
        *)
            echo -e "  ${YELLOW}⚠ Sample agents server will not be started.${NC}"
            ;;
    esac
fi
echo ""

# =============================================================================
# Step 8: Configure nginx (HTTPS reverse proxy)
# =============================================================================
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
echo -e "${YELLOW}Step 8: Configuring nginx...${NC}"

# Generate self-signed SSL certificate for HTTPS
NGINX_SSL_DIR="/etc/nginx/ssl"
if [ ! -f "${NGINX_SSL_DIR}/cert.pem" ] || [ ! -f "${NGINX_SSL_DIR}/key.pem" ]; then
    echo -e "  ${YELLOW}Generating self-signed SSL certificate...${NC}"
    run_sudo mkdir -p "${NGINX_SSL_DIR}"
    run_sudo openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "${NGINX_SSL_DIR}/key.pem" \
        -out "${NGINX_SSL_DIR}/cert.pem" \
        -subj "/CN=localhost" 2>/dev/null
    if [ -f "${NGINX_SSL_DIR}/cert.pem" ] && [ -f "${NGINX_SSL_DIR}/key.pem" ]; then
        echo -e "  ${GREEN}✓${NC} SSL certificate generated at ${NGINX_SSL_DIR}"
    else
        echo -e "${RED}Error: Failed to generate SSL certificate.${NC}"
        exit 1
    fi
else
    echo -e "  ${GREEN}✓${NC} SSL certificate already exists at ${NGINX_SSL_DIR}"
fi

# Generate nginx configuration file
echo -e "  ${YELLOW}Generating nginx configuration...${NC}"
NGINX_CONF_LOCAL="${ORC_ROOT_DIR}/log/openan-nginx.conf"
cat > "$NGINX_CONF_LOCAL" << 'NGINX_EOF'
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;

    # Frontend (static files served from /var/www/openan, see ADR-014)
    location / {
        root /var/www/openan;
        try_files $uri $uri/ /index.html;
    }

    # Orchestration backend API (trailing slash strips /api/orchestrate prefix)
    location /api/orchestrate/ {
        proxy_pass http://127.0.0.1:5001/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Registry Center (trailing slash strips /registry prefix)
    location /registry/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX_EOF

# When --orc only (no --reg), replace the /registry/ proxy_pass with user-provided URL
if [ "${INSTALL_REGISTRY}" = "false" ] && [ -n "${USER_REGISTRY_URL}" ]; then
    REGISTRY_PROXY_URL="${USER_REGISTRY_URL}"
    [[ "${REGISTRY_PROXY_URL}" != */ ]] && REGISTRY_PROXY_URL="${REGISTRY_PROXY_URL}/"
    sed -i "s|proxy_pass http://127.0.0.1:5000/;|proxy_pass ${REGISTRY_PROXY_URL};|" "$NGINX_CONF_LOCAL"
    echo -e "  ${GREEN}✓${NC} Nginx /registry/ proxy_pass set to ${REGISTRY_PROXY_URL}"
fi

# Deploy configuration to nginx conf.d
NGINX_CONF_DEST="/etc/nginx/conf.d/openan.conf"
run_sudo cp "$NGINX_CONF_LOCAL" "$NGINX_CONF_DEST"
echo -e "  ${GREEN}✓${NC} Configuration deployed to ${NGINX_CONF_DEST}"

# Remove default site if it conflicts
if [ -f /etc/nginx/sites-enabled/default ]; then
    echo -e "  ${YELLOW}Removing default nginx site to avoid conflicts...${NC}"
    run_sudo rm -f /etc/nginx/sites-enabled/default
fi

# Test nginx configuration
echo -e "  ${YELLOW}Validating nginx configuration...${NC}"
if run_sudo "$NGINX_BIN" -t 2>&1; then
    echo -e "  ${GREEN}✓${NC} nginx configuration is valid."
else
    echo -e "${RED}Error: nginx configuration test failed.${NC}"
    exit 1
fi
echo ""
else
    echo -e "${YELLOW}Step 8: Configuring nginx...${NC}"
    echo -e "  ${YELLOW}⚠ Skipped (--reg only, no --orc).${NC}"
    echo ""
fi

# =============================================================================
# Step 9: Start services
# =============================================================================
echo -e "${YELLOW}Step 9: Starting services...${NC}"

# Clean all sample agent ports (defensive — residual samples.start_agents_server
# processes from a previous --sample run can cause 404 on orchestration API routes).
# See ADR-009 for the full 11-port sample agent architecture.
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    for sap in 8899 8900 8901 8902 8903 8904 8905 8906 8907 26335 26336; do
        free_port "${sap}"
    done
fi

# Start registry-center (port 5000)
if [ "${INSTALL_REGISTRY}" = "true" ]; then
    free_port 5000
    echo -e "  ${YELLOW}Starting registry-center (http://127.0.0.1:5000)...${NC}"
    cd "$REG_ROOT_DIR"
    nohup "${REG_VENV_DIR}/bin/python" -m agent_registry.start > "${REG_ROOT_DIR}/log/registry-center.log" 2>&1 &
    REGISTRY_PID=$!
    sleep 2
    if kill -0 "$REGISTRY_PID" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} registry-center started (PID: ${REGISTRY_PID})"
    else
        echo -e "${RED}  Error: registry-center failed to start.${NC}"
        echo "  Check log: ${REG_ROOT_DIR}/log/registry-center.log"
        exit 1
    fi
    cd "$SCRIPT_DIR"
fi

# Start orchestration-center backend (port 5001)
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    free_port 5001
    free_port 443
    echo -e "  ${YELLOW}Starting orchestration-center backend (http://127.0.0.1:5001)...${NC}"
    cd "$ORC_ROOT_DIR"
    if [ "${INSTALL_REGISTRY}" = "false" ] && [ -n "${USER_REGISTRY_URL}" ]; then
        export AGENT_REGISTRY_URL="${USER_REGISTRY_URL}"
    else
        export AGENT_REGISTRY_URL="http://127.0.0.1:5000"
    fi
    nohup "${ORC_VENV_DIR}/bin/python" -m orchestrate.start > "${ORC_ROOT_DIR}/log/backend.log" 2>&1 &
    OC_BACKEND_PID=$!
    sleep 2
    if kill -0 "$OC_BACKEND_PID" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Backend started (PID: ${OC_BACKEND_PID})"
    else
        echo -e "${RED}  Error: Backend failed to start.${NC}"
        echo "  Check log: ${ORC_ROOT_DIR}/log/backend.log"
        exit 1
    fi
    cd "$SCRIPT_DIR"
fi

# Start agents examples server (provides sample agents for testing)
if [ "${INSTALL_ORCHESTRATION}" = "true" ] && [ "${START_SAMPLE}" = "true" ]; then
    AGENTS_PORT=8080
    free_port "${AGENTS_PORT}"
    echo -e "  ${YELLOW}Starting agents examples server (http://127.0.0.1:${AGENTS_PORT})...${NC}"
    cd "$ORC_ROOT_DIR"
    nohup "${ORC_VENV_DIR}/bin/python" -m samples.start_agents_server \
        > "${ORC_ROOT_DIR}/log/agents-server.log" 2>&1 &
    AGENTS_PID=$!
    sleep 2
    if kill -0 "$AGENTS_PID" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Sample agents server started (PID: ${AGENTS_PID})"
    else
        echo -e "${RED}  Error: Sample agents server failed to start.${NC}"
        echo "  Check log: ${ORC_ROOT_DIR}/log/agents-server.log"
    fi
    cd "$SCRIPT_DIR"
elif [ "${INSTALL_ORCHESTRATION}" = "true" ] && [ "${START_SAMPLE}" = "false" ]; then
    echo -e "  ${YELLOW}⚠ Sample agents server skipped (use --sample to enable).${NC}"
fi

# Start nginx (HTTPS reverse proxy on port 443)
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    echo -e "  ${YELLOW}Starting nginx (https://localhost)...${NC}"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
        echo -e "  ${YELLOW}nginx is already running, reloading configuration...${NC}"
        run_sudo "$NGINX_BIN" -s reload 2>/dev/null || true
    elif command -v systemctl >/dev/null 2>&1; then
        run_sudo systemctl start nginx 2>/dev/null || run_sudo "$NGINX_BIN"
    else
        run_sudo "$NGINX_BIN" 2>/dev/null || true
    fi
    sleep 1
    NGINX_PID="$(pgrep -f 'nginx: master' 2>/dev/null | head -1)" || NGINX_PID=""
    if [ -n "$NGINX_PID" ]; then
        echo -e "  ${GREEN}✓${NC} nginx started (PID: ${NGINX_PID})"
    else
        echo -e "${YELLOW}  ⚠ Could not determine nginx master PID.${NC}"
    fi
fi
echo ""

# =============================================================================
# Step 10: Summary
# =============================================================================
VPS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || VPS_IP=""
[ -z "${VPS_IP}" ] && VPS_IP="localhost"

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  OpenAN installed and started!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

if [ -n "${REGISTRY_PID}" ]; then
    echo "  registry-center:        http://127.0.0.1:5000  (PID: ${REGISTRY_PID})"
fi
if [ -n "${OC_BACKEND_PID}" ]; then
    echo "  orchestration backend:  http://127.0.0.1:5001  (PID: ${OC_BACKEND_PID})"
fi
if [ -n "${AGENTS_PID}" ]; then
    echo "  agents examples server: http://127.0.0.1:8080  (PID: ${AGENTS_PID})"
fi
if [ -n "${NGINX_PID}" ]; then
    echo "  nginx (HTTPS):          https://${VPS_IP}  (PID: ${NGINX_PID})"
fi

echo ""
echo "  Logs:"
if [ -n "${REGISTRY_PID}" ]; then
    echo "    registry-center:      ${REG_ROOT_DIR}/log/registry-center.log"
fi
if [ -n "${OC_BACKEND_PID}" ]; then
    echo "    backend:              ${ORC_ROOT_DIR}/log/backend.log"
    echo "    frontend build:       ${ORC_ROOT_DIR}/log/frontend-build.log"
fi
if [ -n "${AGENTS_PID}" ]; then
    echo "    agents server:        ${ORC_ROOT_DIR}/log/agents-server.log"
fi

echo ""
echo "  To stop:"
STOP_PIDS=""
if [ -n "${REGISTRY_PID}" ]; then
    STOP_PIDS="${REGISTRY_PID}"
fi
if [ -n "${OC_BACKEND_PID}" ]; then
    STOP_PIDS="${STOP_PIDS} ${OC_BACKEND_PID}"
fi
if [ -n "${AGENTS_PID}" ]; then
    STOP_PIDS="${STOP_PIDS} ${AGENTS_PID}"
fi
STOP_PIDS="$(echo ${STOP_PIDS})"
if [ -n "${STOP_PIDS}" ]; then
    echo "    kill ${STOP_PIDS}"
fi
if [ -n "${NGINX_PID}" ]; then
    echo "    nginx: sudo systemctl stop nginx  (or: sudo ${NGINX_BIN} -s stop)"
fi

echo ""
echo -e "  ${YELLOW}Configuration files (edit and restart if needed):${NC}"
if [ -n "${REGISTRY_PID}" ]; then
    echo "    ${REG_ROOT_DIR}/etc/conf/server.conf"
    echo "    ${REG_ROOT_DIR}/common/config/llm_config.json"
fi
if [ -n "${OC_BACKEND_PID}" ]; then
    echo "    ${ORC_ROOT_DIR}/etc/conf/server.conf"
    echo "    ${ORC_ROOT_DIR}/common/config/llm_config.json"
fi

echo ""
echo -e "  ${YELLOW}To uninstall:${NC}"
echo "    ./uninstall.sh"
echo ""
echo -e "${BLUE}========================================${NC}"
