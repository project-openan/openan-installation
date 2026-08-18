#!/bin/bash
# =============================================================================
# Development environment setup script
# Downloads registry-center & orchestration-center releases, creates venvs, and starts all services.
# Prerequisites: curl, tar (required); python3.12+ & node 20.19+ & npm (auto-installed if missing)
# =============================================================================
set -euo pipefail

# =============================================================================
# Argument parsing: --reg | --orc | --sample | --help
# --reg and --orc are boolean flags; if neither is specified, both are enabled.
# This is consistent with configure_llm.sh's flag design.
# =============================================================================
# Track whether --reg/--orc was explicitly specified
REG_FLAG_SET=false
ORC_FLAG_SET=false
INSTALL_REGISTRY=true
INSTALL_ORCHESTRATION=true
USER_REGISTRY_URL=""
START_SAMPLE=false

print_usage() {
    cat << 'USAGE_EOF'
Usage: openan_install.sh [OPTIONS]

Options:
  --reg          Install registry-center
  --orc          Install orchestration-center
                 (default: both --reg --orc if neither specified)
  --sample       Start agents examples server (port 8080, off by default)
  -h, --help     Show this help message and exit

Examples:
  ./openan_install.sh                 # Install everything (default: --reg --orc)
  ./openan_install.sh --reg           # Install only registry-center
  ./openan_install.sh --orc           # Install only orchestration-center
  ./openan_install.sh --reg --orc --sample  # Install everything and start sample agents
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
            echo "[ERROR] --all has been removed. Use --reg --orc (or no flags) instead."
            echo "        See: ./openan_install.sh --help"
            exit 1
            ;;
        --register)
            echo "[ERROR] --register has been removed. Use --reg instead."
            echo "        See: ./openan_install.sh --help"
            exit 1
            ;;
        --orchestrate)
            echo "[ERROR] --orchestrate has been removed. Use --orc instead."
            echo "        See: ./openan_install.sh --help"
            exit 1
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# If neither --reg nor --orc was specified, default to both (consistent
# with configure_llm.sh's default behavior).
if [ "${REG_FLAG_SET}" = "false" ] && [ "${ORC_FLAG_SET}" = "false" ]; then
    INSTALL_REGISTRY=true
    INSTALL_ORCHESTRATION=true
fi

# --sample requires orchestration-center; warn and disable if not installing it.
if [ "${START_SAMPLE}" = "true" ] && [ "${INSTALL_ORCHESTRATION}" = "false" ]; then
    echo "[INFO] --sample has no effect without --orc (sample requires orchestration-center)."
    START_SAMPLE=false
fi

echo "[MODE] Install targets:"
echo "       registry-center:       ${INSTALL_REGISTRY}"
echo "       orchestration-center:  ${INSTALL_ORCHESTRATION}"
echo "       agents sample:         ${START_SAMPLE}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}"

REGISTRY_RELEASE_URL="https://github.com/project-openan/registry-center/archive/refs/tags/v1.0.0.tar.gz"
REGISTRY_VERSION="v1.0.0"
ORCHESTRATION_RELEASE_URL="https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz"
ORCHESTRATION_VERSION="v1.0.0"

REGISTRY_DIR="${WORK_DIR}/registry-center"
ORCHESTRATION_DIR="${WORK_DIR}/orchestration-center"

CERT_PASSWORD="Dev@12345"

# =============================================================================
# Python 3.12+ resolution functions
# Tries: existing python3.12/python3 → apt/dnf install → standalone download
# Supports: x86_64 & aarch64, Debian/Ubuntu & CentOS/RHEL/Rocky/Alma
# =============================================================================

PYTHON_CMD=""

# Check if a given Python command provides version >= 3.12.
# Echoes the version string on success; returns 1 on failure.
check_python_version() {
    local cmd="$1"
    local ver
    ver=$("$cmd" --version 2>&1 | awk '{print $2}') || return 1
    [ -n "$ver" ] || return 1
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    if [ "${major}" -eq 3 ] && [ "${minor}" -ge 12 ]; then
        echo "$ver"
        return 0
    fi
    return 1
}

# Run a command with sudo if not root, or directly if root.
run_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Try to install Python 3.12 via apt (Debian/Ubuntu).
install_python_apt() {
    echo "  [TRY] Attempting apt install python3.12..."
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "  [WARN] sudo not available, skipping apt install."
        return 1
    fi

    run_sudo apt-get update -qq 2>/dev/null || true
    run_sudo apt-get install -y -qq python3.12 python3.12-venv 2>/dev/null || true

    if command -v python3.12 >/dev/null 2>&1; then
        local ver
        ver=$(check_python_version python3.12 2>/dev/null) || true
        if [ -n "$ver" ]; then
            PYTHON_CMD="python3.12"
            echo "  [OK] Python $ver installed via apt"
            return 0
        fi
    fi

    # Try deadsnakes PPA (Ubuntu)
    if command -v add-apt-repository >/dev/null 2>&1; then
        echo "  [TRY] Adding deadsnakes PPA (Ubuntu)..."
        run_sudo add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
        run_sudo apt-get update -qq 2>/dev/null || true
        run_sudo apt-get install -y -qq python3.12 python3.12-venv 2>/dev/null || true
        if command -v python3.12 >/dev/null 2>&1; then
            local ver2
            ver2=$(check_python_version python3.12 2>/dev/null) || true
            if [ -n "$ver2" ]; then
                PYTHON_CMD="python3.12"
                echo "  [OK] Python $ver2 installed via deadsnakes PPA"
                return 0
            fi
        fi
    fi

    echo "  [WARN] apt install did not provide Python 3.12."
    return 1
}

# Try to install Python 3.12 via dnf/yum (CentOS/RHEL/Rocky/Alma).
install_python_yum() {
    local pkg_mgr=""
    if command -v dnf >/dev/null 2>&1; then
        pkg_mgr="dnf"
    elif command -v yum >/dev/null 2>&1; then
        pkg_mgr="yum"
    else
        echo "  [WARN] Neither dnf nor yum found."
        return 1
    fi

    echo "  [TRY] Attempting $pkg_mgr install python3.12..."
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "  [WARN] sudo not available, skipping $pkg_mgr install."
        return 1
    fi

    run_sudo "$pkg_mgr" install -y python3.12 2>/dev/null || true

    if command -v python3.12 >/dev/null 2>&1; then
        local ver
        ver=$(check_python_version python3.12 2>/dev/null) || true
        if [ -n "$ver" ]; then
            PYTHON_CMD="python3.12"
            echo "  [OK] Python $ver installed via $pkg_mgr"
            return 0
        fi
    fi

    # Try dnf module (RHEL 8/9)
    run_sudo "$pkg_mgr" module enable python3.12 2>/dev/null || true
    run_sudo "$pkg_mgr" install -y python3.12 2>/dev/null || true

    if command -v python3.12 >/dev/null 2>&1; then
        local ver2
        ver2=$(check_python_version python3.12 2>/dev/null) || true
        if [ -n "$ver2" ]; then
            PYTHON_CMD="python3.12"
            echo "  [OK] Python $ver2 installed via $pkg_mgr module"
            return 0
        fi
    fi

    echo "  [WARN] $pkg_mgr install did not provide Python 3.12."
    return 1
}

# Download a prebuilt standalone Python 3.12 (python-build-standalone project).
# Works on any Linux with glibc, regardless of distribution.
install_python_standalone() {
    local py_arch="$1"
    local INSTALL_DIR="${WORK_DIR}/.python3.12"

    command -v curl >/dev/null 2>&1 || { echo "  [ERROR] curl is required to download Python."; return 1; }
    command -v tar  >/dev/null 2>&1 || { echo "  [ERROR] tar is required to extract Python.";  return 1; }

    local API_URL="https://api.github.com/repos/indygreg/python-build-standalone/releases/latest"
    echo "  [DOWNLOAD] Fetching latest Python 3.12 standalone build for ${py_arch}..."

    local release_info
    release_info=$(curl -fsSL "$API_URL" 2>/dev/null) || {
        echo "  [ERROR] Failed to fetch release info from GitHub API."
        return 1
    }

    # Find the matching asset: cpython-3.12.*-<arch>-unknown-linux-gnu-install_only_stripped.tar.gz
    local asset_url
    asset_url=$(echo "$release_info" | grep '"browser_download_url"' | \
        grep 'cpython-3\.12\.' | \
        grep "${py_arch}-unknown-linux-gnu" | \
        grep 'install_only_stripped\.tar\.gz' | \
        head -1 | sed 's/.*"browser_download_url": *"//;s/".*//') || asset_url=""

    if [ -z "$asset_url" ]; then
        echo "  [ERROR] Could not find a Python 3.12 standalone build for ${py_arch}."
        return 1
    fi

    echo "  [DOWNLOAD] URL: $asset_url"
    local tmp_tar
    tmp_tar=$(mktemp /tmp/python-3.12-XXXXXX.tar.gz)
    if ! curl -fsSL "$asset_url" -o "$tmp_tar"; then
        echo "  [ERROR] Failed to download Python 3.12."
        rm -f "$tmp_tar"
        return 1
    fi

    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    tar -xzf "$tmp_tar" -C "$INSTALL_DIR"
    rm -f "$tmp_tar"

    # The standalone build extracts to python/bin/python3.12
    local py_bin="${INSTALL_DIR}/python/bin/python3.12"
    if [ ! -f "$py_bin" ]; then
        py_bin="${INSTALL_DIR}/python/bin/python3"
    fi
    if [ ! -f "$py_bin" ]; then
        echo "  [ERROR] Python binary not found after extraction."
        return 1
    fi

    chmod +x "$py_bin"
    # Ensure python3 and python symlinks exist
    ln -sf "$py_bin" "${INSTALL_DIR}/python/bin/python3"
    ln -sf "$py_bin" "${INSTALL_DIR}/python/bin/python"

    # Add to PATH for this session
    export PATH="${INSTALL_DIR}/python/bin:${PATH}"
    PYTHON_CMD="$py_bin"

    local ver
    ver=$("$PYTHON_CMD" --version 2>&1 | awk '{print $2}')
    echo "  [OK] Python $ver installed (standalone)"
    echo "  [INFO] Location: ${INSTALL_DIR}/python"

    # Verify venv module works (required for later steps)
    if ! "$PYTHON_CMD" -m venv --help >/dev/null 2>&1; then
        echo "  [ERROR] venv module not available in standalone Python."
        return 1
    fi
}

# Main Python resolution: try existing → package manager → standalone download.
resolve_python() {
    # 1. Try python3.12
    if command -v python3.12 >/dev/null 2>&1; then
        local ver
        ver=$(check_python_version python3.12 2>/dev/null) || true
        if [ -n "$ver" ]; then
            PYTHON_CMD="python3.12"
            echo "  [OK] Python $ver (python3.12)"
            return 0
        fi
    fi

    # 2. Try python3
    if command -v python3 >/dev/null 2>&1; then
        local ver
        ver=$(check_python_version python3 2>/dev/null) || true
        if [ -n "$ver" ]; then
            PYTHON_CMD="python3"
            echo "  [OK] Python $ver (python3)"
            return 0
        fi
    fi

    # 3. Not found — attempt automatic installation
    echo "  [INFO] Python 3.12+ not found on this system."
    echo "         Will attempt automatic installation..."

    # Detect architecture
    local arch py_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  py_arch="x86_64" ;;
        aarch64|arm64) py_arch="aarch64" ;;
        *)
            echo "[ERROR] Unsupported architecture: $arch"
            echo "        Please install Python 3.12+ manually."
            exit 1
            ;;
    esac

    # Detect distribution
    local distro="unknown"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu) distro="debian" ;;
            centos|rhel|rocky|almalinux|fedora|amzn|openEuler|openeuler) distro="centos" ;;
            *)
                case "${ID_LIKE:-}" in
                    *debian*) distro="debian" ;;
                    *rhel*|*fedora*|*centos*) distro="centos" ;;
                esac
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        distro="debian"
    elif [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
        distro="centos"
    fi

    echo "  [INFO] Architecture: $py_arch, Distribution: $distro"

    # Try package manager first
    if [ "$distro" = "debian" ]; then
        install_python_apt || true
    elif [ "$distro" = "centos" ]; then
        install_python_yum || true
    fi

    if [ -n "$PYTHON_CMD" ]; then
        return 0
    fi

    # Fallback: download standalone Python (works on any distro with glibc)
    echo "  [INFO] Package manager install unavailable or failed."
    echo "         Downloading standalone Python 3.12 (python-build-standalone)..."
    install_python_standalone "$py_arch" || {
        echo "[ERROR] All Python installation methods failed."
        echo "        Please install Python 3.12+ manually from https://www.python.org/downloads/"
        exit 1
    }
}

# =============================================================================
# Node.js 20.19+ resolution functions
# Tries: existing node → apt/dnf install (with NodeSource fallback) → prebuilt binary
# Supports: x86_64 & aarch64, Debian/Ubuntu & CentOS/RHEL/Rocky/Alma
# =============================================================================

NODE_VERSION_TARGET="20.19.0"

# Check if a given Node.js command provides version >= 20.19.
# Echoes the version string on success; returns 1 on failure.
check_node_version() {
    local cmd="$1"
    local ver
    ver=$("$cmd" --version 2>&1 | sed 's/v//') || return 1
    [ -n "$ver" ] || return 1
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    if [ "${major}" -gt 20 ] || { [ "${major}" -eq 20 ] && [ "${minor}" -ge 19 ]; }; then
        echo "$ver"
        return 0
    fi
    return 1
}

# Ensure npm is available; if not, attempt to install via package manager.
# Returns 0 if npm is available, 1 otherwise.
ensure_npm() {
    local distro="$1"
    if command -v npm >/dev/null 2>&1; then
        echo "  [OK] npm $(npm --version 2>/dev/null)"
        return 0
    fi
    echo "  [WARN] npm not found. Attempting to install npm..."
    if [ "$distro" = "debian" ]; then
        run_sudo apt-get install -y -qq npm 2>/dev/null || true
    elif [ "$distro" = "centos" ]; then
        local pm=""
        command -v dnf >/dev/null 2>&1 && pm="dnf"
        command -v yum >/dev/null 2>&1 && [ -z "$pm" ] && pm="yum"
        [ -n "$pm" ] && run_sudo "$pm" install -y npm 2>/dev/null || true
    fi
    if command -v npm >/dev/null 2>&1; then
        echo "  [OK] npm $(npm --version 2>/dev/null)"
        return 0
    fi
    return 1
}

# Try to install Node.js via apt (Debian/Ubuntu).
# First tries default repos, then NodeSource setup_20.x as fallback.
install_node_apt() {
    echo "  [TRY] Attempting apt install nodejs npm..."
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "  [WARN] sudo not available, skipping apt install."
        return 1
    fi

    # 1. Try default repos
    run_sudo apt-get update -qq 2>/dev/null || true
    run_sudo apt-get install -y -qq nodejs npm 2>/dev/null || true

    if command -v node >/dev/null 2>&1; then
        local ver
        ver=$(check_node_version node 2>/dev/null) || true
        if [ -n "$ver" ]; then
            echo "  [OK] Node.js $ver installed via apt"
            return 0
        fi
    fi

    # 2. Try NodeSource setup_20.x
    echo "  [TRY] Adding NodeSource repository for Node.js 20.x..."
    if [ "$(id -u)" -eq 0 ]; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 2>/dev/null || true
    else
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null || true
    fi
    run_sudo apt-get install -y -qq nodejs 2>/dev/null || true

    if command -v node >/dev/null 2>&1; then
        local ver2
        ver2=$(check_node_version node 2>/dev/null) || true
        if [ -n "$ver2" ]; then
            echo "  [OK] Node.js $ver2 installed via NodeSource"
            return 0
        fi
    fi

    echo "  [WARN] apt install did not provide Node.js 20.19+."
    return 1
}

# Try to install Node.js via dnf/yum (CentOS/RHEL/Rocky/Alma).
# First tries default repos, then NodeSource setup_20.x as fallback.
install_node_yum() {
    local pkg_mgr=""
    if command -v dnf >/dev/null 2>&1; then
        pkg_mgr="dnf"
    elif command -v yum >/dev/null 2>&1; then
        pkg_mgr="yum"
    else
        echo "  [WARN] Neither dnf nor yum found."
        return 1
    fi

    echo "  [TRY] Attempting $pkg_mgr install nodejs npm..."
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "  [WARN] sudo not available, skipping $pkg_mgr install."
        return 1
    fi

    # 1. Try default repos
    run_sudo "$pkg_mgr" install -y nodejs npm 2>/dev/null || true

    if command -v node >/dev/null 2>&1; then
        local ver
        ver=$(check_node_version node 2>/dev/null) || true
        if [ -n "$ver" ]; then
            echo "  [OK] Node.js $ver installed via $pkg_mgr"
            return 0
        fi
    fi

    # 2. Try NodeSource setup_20.x
    echo "  [TRY] Adding NodeSource repository for Node.js 20.x..."
    if [ "$(id -u)" -eq 0 ]; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - 2>/dev/null || true
    else
        curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null || true
    fi
    run_sudo "$pkg_mgr" install -y nodejs 2>/dev/null || true

    if command -v node >/dev/null 2>&1; then
        local ver2
        ver2=$(check_node_version node 2>/dev/null) || true
        if [ -n "$ver2" ]; then
            echo "  [OK] Node.js $ver2 installed via NodeSource"
            return 0
        fi
    fi

    echo "  [WARN] $pkg_mgr install did not provide Node.js 20.19+."
    return 1
}

# Download a prebuilt Node.js binary from nodejs.org.
# Works on any Linux with glibc, regardless of distribution.
install_node_prebuilt() {
    local node_arch="$1"
    local INSTALL_DIR="${WORK_DIR}/.node"

    command -v curl >/dev/null 2>&1 || { echo "  [ERROR] curl is required to download Node.js."; return 1; }
    command -v tar  >/dev/null 2>&1 || { echo "  [ERROR] tar is required to extract Node.js.";  return 1; }

    local download_url="https://nodejs.org/dist/v${NODE_VERSION_TARGET}/node-v${NODE_VERSION_TARGET}-linux-${node_arch}.tar.xz"

    echo "  [DOWNLOAD] Fetching Node.js v${NODE_VERSION_TARGET} prebuilt binary for ${node_arch}..."
    echo "  [DOWNLOAD] URL: $download_url"

    local tmp_tar
    tmp_tar=$(mktemp /tmp/node-XXXXXX.tar.xz)
    if ! curl -fsSL "$download_url" -o "$tmp_tar"; then
        echo "  [ERROR] Failed to download Node.js v${NODE_VERSION_TARGET}."
        rm -f "$tmp_tar"
        return 1
    fi

    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    tar -xJf "$tmp_tar" -C "$INSTALL_DIR" --strip-components=1
    rm -f "$tmp_tar"

    local node_bin="${INSTALL_DIR}/bin/node"
    local npm_bin="${INSTALL_DIR}/bin/npm"

    if [ ! -f "$node_bin" ]; then
        echo "  [ERROR] Node.js binary not found after extraction."
        return 1
    fi

    chmod +x "$node_bin"
    [ -f "$npm_bin" ] && chmod +x "$npm_bin"

    # Add to PATH for this session
    export PATH="${INSTALL_DIR}/bin:${PATH}"

    local ver
    ver=$("$node_bin" --version 2>&1 | sed 's/v//')
    echo "  [OK] Node.js v${ver} installed (prebuilt)"
    echo "  [INFO] Location: ${INSTALL_DIR}"

    # Verify npm (bundled with prebuilt Node.js)
    if ! "$npm_bin" --version >/dev/null 2>&1; then
        echo "  [ERROR] npm not available in prebuilt Node.js."
        return 1
    fi
    echo "  [OK] npm $("$npm_bin" --version 2>/dev/null)"
}

# Main Node.js resolution: try existing → package manager → prebuilt download.
resolve_node() {
    # Detect architecture
    local arch node_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  node_arch="x64" ;;
        aarch64|arm64) node_arch="arm64" ;;
        *)
            echo "[ERROR] Unsupported architecture: $arch"
            echo "        Please install Node.js 20.19+ manually."
            exit 1
            ;;
    esac

    # Detect distribution (inline, matching resolve_python pattern)
    local distro="unknown"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu) distro="debian" ;;
            centos|rhel|rocky|almalinux|fedora|amzn|openEuler|openeuler) distro="centos" ;;
            *)
                case "${ID_LIKE:-}" in
                    *debian*) distro="debian" ;;
                    *rhel*|*fedora*|*centos*) distro="centos" ;;
                esac
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        distro="debian"
    elif [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
        distro="centos"
    fi

    # 1. Try existing node
    if command -v node >/dev/null 2>&1; then
        local ver
        ver=$(check_node_version node 2>/dev/null) || true
        if [ -n "$ver" ]; then
            echo "  [OK] Node.js v${ver}"
            ensure_npm "$distro" || {
                echo "  [ERROR] npm is not installed and could not be installed."
                echo "          Please install npm manually."
                exit 1
            }
            return 0
        else
            # Node exists but version < 20.19
            local existing_ver
            existing_ver=$(node --version 2>/dev/null | sed 's/v//')
            echo "  [INFO] Node.js v${existing_ver} found but 20.19+ required."
            echo "         Will attempt to install a compatible version locally..."
        fi
    else
        echo "  [INFO] Node.js not found on this system."
        echo "         Will attempt automatic installation..."
    fi

    echo "  [INFO] Architecture: $node_arch, Distribution: $distro"

    # 2. Try package manager
    if [ "$distro" = "debian" ]; then
        install_node_apt || true
    elif [ "$distro" = "centos" ]; then
        install_node_yum || true
    fi

    # Check if package manager succeeded
    if command -v node >/dev/null 2>&1; then
        local ver
        ver=$(check_node_version node 2>/dev/null) || true
        if [ -n "$ver" ]; then
            ensure_npm "$distro" || {
                echo "  [ERROR] npm is not installed and could not be installed."
                echo "          Please install npm manually."
                exit 1
            }
            return 0
        fi
    fi

    # 3. Fallback: download prebuilt Node.js (works on any distro with glibc)
    echo "  [INFO] Package manager install unavailable or did not provide Node.js 20.19+."
    echo "         Downloading prebuilt Node.js ${NODE_VERSION_TARGET} from nodejs.org..."
    install_node_prebuilt "$node_arch" || {
        echo "[ERROR] All Node.js installation methods failed."
        echo "        Please install Node.js 20.19+ manually from https://nodejs.org/"
        exit 1
    }
}

# =============================================================================
# Step 0: Verify prerequisites
# =============================================================================
echo "=========================================="
echo " Step 0: Verifying prerequisites"
echo "=========================================="

# Check Python 3.12+ (auto-install if not found)
resolve_python

# Check Node.js 20.19+ and npm (auto-install if not found, only needed for orchestration-center)
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    resolve_node
else
    echo "  [SKIP] Node.js/npm check skipped (not needed for registry-only install)."
fi

# Check curl and tar
command -v curl >/dev/null 2>&1 || { echo "[ERROR] curl is not installed."; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "[ERROR] tar is not installed."; exit 1; }
echo "  [OK] curl and tar available"
echo ""

# -----------------------------------------------------------------------------
# Helper: kill any process listening on a given TCP port.
# Prevents leftover processes from a previous run causing PID mismatches.
# -----------------------------------------------------------------------------
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
        echo "  [WARN] Port ${port} is in use, killing PID(s): ${pids}..."
        echo "${pids}" | tr ' ' '\n' | xargs -r kill 2>/dev/null || true
        sleep 1
        # Force kill if still alive
        echo "${pids}" | tr ' ' '\n' | xargs -r kill -9 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Detect Linux distribution for package manager selection.
# Echoes "debian", "centos", or "unknown".
# -----------------------------------------------------------------------------
detect_distro() {
    local distro="unknown"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu) distro="debian" ;;
            centos|rhel|rocky|almalinux|fedora|amzn|openEuler|openeuler) distro="centos" ;;
            *)
                case "${ID_LIKE:-}" in
                    *debian*) distro="debian" ;;
                    *rhel*|*fedora*|*centos*) distro="centos" ;;
                esac
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        distro="debian"
    elif [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
        distro="centos"
    fi
    echo "$distro"
}

# -----------------------------------------------------------------------------
# Find nginx binary path, checking PATH then common sbin locations.
# On Debian/CentOS, nginx installs to /usr/sbin which is not in non-root PATH.
# Echoes the binary path on success; returns 1 if not found.
# -----------------------------------------------------------------------------
find_nginx_binary() {
    local nginx_bin
    local dir
    # 1. Check PATH (works for root or if already in PATH)
    if nginx_bin=$(command -v nginx 2>/dev/null); then
        echo "$nginx_bin"
        return 0
    fi
    # 2. Check common sbin locations (Debian/CentOS install nginx to /usr/sbin)
    for dir in /usr/sbin /sbin; do
        if [ -x "${dir}/nginx" ]; then
            echo "${dir}/nginx"
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# Install nginx and openssl if not already present.
# Uses apt (Debian/Ubuntu) or dnf/yum (CentOS/RHEL/Rocky/Alma).
# -----------------------------------------------------------------------------
setup_nginx() {
    local need_nginx=false
    local need_openssl=false
    local nginx_bin=""

    if ! find_nginx_binary >/dev/null 2>&1; then
        need_nginx=true
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        need_openssl=true
    fi

    if [ "$need_nginx" = "false" ] && [ "$need_openssl" = "false" ]; then
        nginx_bin=$(find_nginx_binary)
        echo "  [OK] nginx $("$nginx_bin" -v 2>&1 | awk '{print $3}')"
        echo "  [OK] openssl $(openssl version 2>/dev/null | awk '{print $2}')"
        return 0
    fi

    local distro
    distro=$(detect_distro)

    if [ "$distro" = "unknown" ]; then
        echo "  [ERROR] Cannot detect Linux distribution to install nginx."
        echo "          Please install nginx and openssl manually."
        exit 1
    fi

    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "  [ERROR] sudo is required but not available."
        echo "          Please install nginx and openssl manually."
        exit 1
    fi

    if [ "$distro" = "debian" ]; then
        echo "  [INFO] Installing nginx and openssl via apt..."
        run_sudo apt-get update -qq 2>/dev/null || true
        run_sudo apt-get install -y -qq nginx openssl 2>/dev/null || true
    elif [ "$distro" = "centos" ]; then
        local pkg_mgr=""
        if command -v dnf >/dev/null 2>&1; then
            pkg_mgr="dnf"
        elif command -v yum >/dev/null 2>&1; then
            pkg_mgr="yum"
        else
            echo "  [ERROR] Neither dnf nor yum found."
            echo "          Please install nginx and openssl manually."
            exit 1
        fi
        echo "  [INFO] Installing nginx and openssl via $pkg_mgr..."
        # Install EPEL for nginx on CentOS/RHEL
        run_sudo "$pkg_mgr" install -y epel-release 2>/dev/null || true
        run_sudo "$pkg_mgr" install -y nginx openssl 2>/dev/null || true
    fi

    # Verify installation
    if ! find_nginx_binary >/dev/null 2>&1; then
        echo "  [ERROR] nginx installation failed."
        echo "          Please install nginx manually."
        exit 1
    fi
    nginx_bin=$(find_nginx_binary)
    echo "  [OK] nginx $("$nginx_bin" -v 2>&1 | awk '{print $3}')"

    if ! command -v openssl >/dev/null 2>&1; then
        echo "  [WARN] openssl not found; SSL certificate generation may fail."
    else
        echo "  [OK] openssl $(openssl version 2>/dev/null | awk '{print $2}')"
    fi
}

# =============================================================================
# Step 0.5: Check nginx (auto-install if not found)
# =============================================================================
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
echo "=========================================="
echo " Step 0.5: Checking nginx"
echo "=========================================="
setup_nginx
echo ""
else
    echo "=========================================="
    echo " Step 0.5: Checking nginx"
    echo "=========================================="
    echo "  [SKIP] nginx check skipped (not needed for registry-only install)."
    echo ""
fi

# =============================================================================
# Step 1: Prepare repositories
# =============================================================================
echo "=========================================="
echo " Step 1: Fetching repositories"
echo "=========================================="

if [ "${INSTALL_REGISTRY}" = "true" ]; then
if [ -d "${REGISTRY_DIR}" ] && [ -n "$(ls -A "${REGISTRY_DIR}" 2>/dev/null)" ]; then
    echo "[SKIP] registry-center already exists, skipping download..."
else
    rm -rf "${REGISTRY_DIR}"
    echo "[DOWNLOAD] registry-center release ${REGISTRY_VERSION}..."
    TMP_TAR=$(mktemp /tmp/registry-center-XXXXXX.tar.gz)
    if curl -fsSL "${REGISTRY_RELEASE_URL}" -o "${TMP_TAR}"; then
        mkdir -p "${REGISTRY_DIR}"
        tar -xzf "${TMP_TAR}" -C "${REGISTRY_DIR}" --strip-components=1
        echo "  [OK] registry-center ${REGISTRY_VERSION} downloaded and extracted."
    else
        echo "  [ERROR] Failed to download registry-center release."
        rm -f "${TMP_TAR}"
        exit 1
    fi
    rm -f "${TMP_TAR}"
fi
else
    echo "[SKIP] registry-center download skipped (--orc only, no --reg)."
fi

if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
if [ -d "${ORCHESTRATION_DIR}" ] && [ -n "$(ls -A "${ORCHESTRATION_DIR}" 2>/dev/null)" ]; then
    echo "[SKIP] orchestration-center already exists, skipping download..."
else
    rm -rf "${ORCHESTRATION_DIR}"
    echo "[DOWNLOAD] orchestration-center release ${ORCHESTRATION_VERSION}..."
    TMP_TAR=$(mktemp /tmp/orchestration-center-XXXXXX.tar.gz)
    if curl -fsSL "${ORCHESTRATION_RELEASE_URL}" -o "${TMP_TAR}"; then
        mkdir -p "${ORCHESTRATION_DIR}"
        tar -xzf "${TMP_TAR}" -C "${ORCHESTRATION_DIR}" --strip-components=1
        echo "  [OK] orchestration-center ${ORCHESTRATION_VERSION} downloaded and extracted."
    else
        echo "  [ERROR] Failed to download orchestration-center release."
        rm -f "${TMP_TAR}"
        exit 1
    fi
    rm -f "${TMP_TAR}"
fi
else
    echo "[SKIP] orchestration-center download skipped (--reg only, no --orc)."
fi

# =============================================================================
# Step 2: Setup registry-center
# =============================================================================
if [ "${INSTALL_REGISTRY}" = "true" ]; then
echo ""
echo "=========================================="
echo " Step 2: Setting up registry-center"
echo "=========================================="

cd "${REGISTRY_DIR}"

# Create venv
if [ ! -d "venv" ]; then
    echo "[VENV] Creating virtual environment..."
    ${PYTHON_CMD} -m venv venv
fi
source venv/bin/activate

# Install dependencies
echo "[PIP] Installing registry-center dependencies..."
pip install --upgrade pip -q
pip install -r requirements.txt -q

# Generate self-signed certificate (serverAuth)
echo "[CERT] Generating self-signed certificates..."
CERT_DIR="${REGISTRY_DIR}/etc/cert"
mkdir -p "${CERT_DIR}"

python3 -c "
import sys
sys.path.insert(0, '.')
from common.cert.certificate_generator import CertificateGenerator

generator = CertificateGenerator(key_algorithm='RSA')
if generator.generate_self_signed_cert('${CERT_DIR}', 'serverAuth', '${CERT_PASSWORD}'):
    print('  [OK] Self-signed certificate generated in ${CERT_DIR}')
else:
    print('  [SKIP] Certificate already exists')
"

# Prepare etc/ssl/ directory with certificate copies expected by server.conf.
# generate_self_signed_cert creates server_RSA.cer and server_key_RSA.pem in etc/cert/,
# but server.conf defaults reference etc/ssl/server.cer and etc/ssl/server_key.pem.
# init.py validates these paths (file exists, correct extension, 0o600 permissions).
echo "[SSL] Preparing SSL directory for init..."
SSL_DIR="${REGISTRY_DIR}/etc/ssl"
mkdir -p "${SSL_DIR}"
cp -f "${CERT_DIR}/server_RSA.cer" "${SSL_DIR}/server.cer"
cp -f "${CERT_DIR}/server_RSA.cer" "${SSL_DIR}/trust.cer"
cp -f "${CERT_DIR}/server_key_RSA.pem" "${SSL_DIR}/server_key.pem"
chmod 600 "${SSL_DIR}/server.cer" "${SSL_DIR}/trust.cer" "${SSL_DIR}/server_key.pem"

# Update jwk_private_key_path in server.conf to point to a valid .pem file.
# Default template has jwk_private_key_path=etc/sign_cert (wrong extension, file missing).
SERVER_CONF="${REGISTRY_DIR}/etc/conf/server.conf"
if [ -f "${SERVER_CONF}" ]; then
    sed -i 's|^jwk_private_key_path=.*|jwk_private_key_path=etc/ssl/server_key.pem|' "${SERVER_CONF}"
fi

# Clean stale agent card data from a previous --sample run.
# data/agentcard.json persists across runs and causes 404 when agents
# are not running (see ADR-009).
if [ -d "${REGISTRY_DIR}/data" ]; then
    rm -rf "${REGISTRY_DIR}/data"
    echo "  [CLEAN] Removed stale data/ directory."
fi

# Run init with automated input:
#   - IP: default (empty -> 127.0.0.1)
#   - Port: default (empty -> 5000)
#   - Enable HTTPS: n
#   - Enable registry signing: n
#   - Enable signature validation: n
#   - JWK cert path: default (empty -> etc/ssl/server.cer)
#   - JWK private key path: default (empty -> etc/ssl/server_key.pem)
#   - Enable agent approval: n
#   - Storage mode: default (empty -> file)
echo "[INIT] Running registry-center initialization..."
printf '\n\nn\nn\nn\n\n\nn\n\n' | python -m agent_registry.init

echo "[DONE] registry-center initialized."
else
    echo ""
    echo "=========================================="
    echo " Step 2: Setting up registry-center"
    echo "=========================================="
    echo "  [SKIP] registry-center setup skipped (--orc only, no --reg)."
    echo ""
fi

# =============================================================================
# Step 3: Setup orchestration-center
# =============================================================================
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
echo ""
echo "=========================================="
echo " Step 3: Setting up orchestration-center"
echo "=========================================="

cd "${ORCHESTRATION_DIR}"

# Create venv
if [ ! -d "venv" ]; then
    echo "[VENV] Creating virtual environment..."
    ${PYTHON_CMD} -m venv venv
fi
source venv/bin/activate

# Install backend dependencies
echo "[PIP] Installing orchestration-center backend dependencies..."
pip install --upgrade pip -q
if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt -q
fi

# Install frontend dependencies and build static assets
# npm run build produces dist/ which nginx serves directly (see ADR-014)
echo "[NPM] Installing orchestration-center frontend dependencies..."
cd "${ORCHESTRATION_DIR}/workflow-designer"
npm install --force

echo "[BUILD] Building frontend static assets..."
npm run build > "${ORCHESTRATION_DIR}/frontend-build.log" 2>&1
echo "  [OK] Frontend built to dist/"

# Deploy static assets to system web directory (see ADR-014)
# nginx (www-data) cannot traverse user home directory, so we copy dist/
# to /var/www/openan/ with world-readable permissions.
echo "[DEPLOY] Copying frontend assets to /var/www/openan/..."
run_sudo mkdir -p /var/www/openan
run_sudo cp -r "${ORCHESTRATION_DIR}/workflow-designer/dist/"* /var/www/openan/
run_sudo chmod -R 755 /var/www/openan
echo "  [OK] Static assets deployed to /var/www/openan/"

cd "${ORCHESTRATION_DIR}"
else
    echo ""
    echo "=========================================="
    echo " Step 3: Setting up orchestration-center"
    echo "=========================================="
    echo "  [SKIP] orchestration-center setup skipped (--reg only, no --orc)."
    echo ""
fi

# =============================================================================
# Step 3.5: Configure LLM API key & fix registry URL
# =============================================================================
echo ""
echo "=========================================="
echo " Step 3.5: Configuring LLM & registry URL"
echo "=========================================="

# --- LLM Configuration ---
# Delegate to configure_llm.sh which handles interactive input, validation,
# and writing. The install flags map directly to configure_llm.sh flags:
#   --reg --orc  → --reg --orc  (interactive split-asking with reuse option)
#   --reg        → --reg        (interactive, registry only)
#   --orc        → --orc        (interactive, orchestration only)

# Build LLM_FLAGS from install targets
LLM_FLAGS=""
[ "${INSTALL_REGISTRY}" = "true" ] && LLM_FLAGS="--reg"
[ "${INSTALL_ORCHESTRATION}" = "true" ] && LLM_FLAGS="${LLM_FLAGS} --orc"
LLM_FLAGS="${LLM_FLAGS# }"

echo "[INPUT] LLM configuration is required for the chat model."
echo ""
echo "  You can skip this step and run configure_llm.sh later."
echo ""
read -r -p "        Skip LLM configuration and configure manually? [y/N]: " SKIP_LLM_INPUT < /dev/tty || SKIP_LLM_INPUT=""
LLM_SKIPPED=false
case "${SKIP_LLM_INPUT}" in
    [yY]|[yY][eE][sS])
        LLM_SKIPPED=true
        echo "  [SKIP] LLM configuration skipped."
        echo "         Run configure_llm.sh later to configure."
        ;;
esac

if [ "${LLM_SKIPPED}" = "false" ]; then
    echo "[CONFIG] Starting interactive LLM configuration via configure_llm.sh..."
    echo ""
    bash "${SCRIPT_DIR}/configure_llm.sh" ${LLM_FLAGS}
else
    echo "  [INFO] LLM configuration skipped. Default values will be used."
    echo "         Run configure_llm.sh later to configure."
fi

# ---------------------------------------------------------------------------
# Always print configure_llm.sh usage so the user can reconfigure LLM later,
# regardless of whether they completed interactive config or skipped it.
# ---------------------------------------------------------------------------
echo ""
echo "[INFO] To reconfigure LLM at any time, run configure_llm.sh:"
echo ""
echo "  # Non-interactive (same config for both projects):"
echo "  ./configure_llm.sh --model <model> --url <url> --api-key <key>"
echo ""
echo "  # Interactive (configure each project separately):"
echo "  ./configure_llm.sh --reg --orc"
echo ""
echo "  # Or set LLM_API_KEY env var (avoids key in shell history):"
echo "  LLM_API_KEY=your-key ./configure_llm.sh --model <model> --url <url>"
echo ""
echo "  Options:"
echo "    --reg                Configure registry-center"
echo "    --orc                Configure orchestration-center"
echo "                         (default: both if neither specified)"
echo "    --model <name>       LLM model name"
echo "    --url <url>          LLM API URL"
echo "    --api-key <key>      API key (or LLM_API_KEY env var)"
echo "    --validate           Validate API connection (default)"
echo "    --no-validate        Skip validation"
echo "    -h, --help           Show help"
echo ""

# --- Configure agent_registry_url in server.conf ---
# When both --reg and --orc: local registry-center runs HTTP, so convert https->http.
# When --orc only (no --reg): prompt user for the remote registry URL and use it as-is.
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
SERVER_CONF="${ORCHESTRATION_DIR}/etc/conf/server.conf"
if [ -f "${SERVER_CONF}" ]; then
    if [ "${INSTALL_REGISTRY}" = "false" ]; then
        # Prompt for the running registry center's URL
        DEFAULT_REGISTRY_URL="https://127.0.0.1:5000"
        echo ""
        echo "[INPUT] Orchestration-center needs to connect to a running registry-center."
        read -r -p "        Enter registry center URL [${DEFAULT_REGISTRY_URL}]: " USER_REGISTRY_URL < /dev/tty || USER_REGISTRY_URL=""
        USER_REGISTRY_URL="${USER_REGISTRY_URL:-${DEFAULT_REGISTRY_URL}}"
        echo "  [OK] Registry URL set to: ${USER_REGISTRY_URL}"

        # Set agent_registry_url in server.conf to user-provided value (no protocol conversion)
        echo "[CONFIG] Setting agent_registry_url in server.conf..."
        sed -i "s|^agent_registry_url=.*|agent_registry_url=${USER_REGISTRY_URL}|" "${SERVER_CONF}"
        echo "  [OK] server.conf agent_registry_url set to ${USER_REGISTRY_URL}."
    else
        # --reg --orc mode: local registry runs HTTP, fix https->http
        echo "[CONFIG] Fixing agent_registry_url in server.conf (https -> http)..."
        sed -i 's|agent_registry_url=https://|agent_registry_url=http://|' "${SERVER_CONF}"
        echo "  [OK] server.conf agent_registry_url set to http."
    fi
else
    echo "  [WARN] server.conf not found at ${SERVER_CONF}, skipping registry URL fix."
fi
fi

# --- Sample Agents Interactive Prompt ---
if [ "${INSTALL_ORCHESTRATION}" = "true" ] && [ "${START_SAMPLE}" = "false" ]; then
    echo ""
    echo "[INPUT] Sample agents server provides demo agents for testing (port 8080)."
    read -r -p "        Start sample agents server? [y/N]: " START_SAMPLE_INPUT < /dev/tty || START_SAMPLE_INPUT=""
    case "${START_SAMPLE_INPUT}" in
        [yY]|[yY][eE][sS])
            START_SAMPLE=true
            echo "  [OK] Sample agents server will be started."
            ;;
        *)
            echo "  [SKIP] Sample agents server will not be started."
            ;;
    esac
fi

# =============================================================================
# Step 3.7: Configure Nginx (HTTPS reverse proxy on port 443)
# =============================================================================
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
echo ""
echo "=========================================="
echo " Step 3.7: Configuring Nginx"
echo "=========================================="

# Generate self-signed SSL certificate for HTTPS
NGINX_SSL_DIR="/etc/nginx/ssl"
if [ ! -f "${NGINX_SSL_DIR}/cert.pem" ] || [ ! -f "${NGINX_SSL_DIR}/key.pem" ]; then
    echo "[SSL] Generating self-signed SSL certificate..."
    run_sudo mkdir -p "${NGINX_SSL_DIR}"
    run_sudo openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "${NGINX_SSL_DIR}/key.pem" \
        -out "${NGINX_SSL_DIR}/cert.pem" \
        -subj "/CN=localhost" 2>/dev/null
    if [ -f "${NGINX_SSL_DIR}/cert.pem" ] && [ -f "${NGINX_SSL_DIR}/key.pem" ]; then
        echo "  [OK] SSL certificate generated at ${NGINX_SSL_DIR}"
    else
        echo "  [ERROR] Failed to generate SSL certificate."
        exit 1
    fi
else
    echo "[SKIP] SSL certificate already exists at ${NGINX_SSL_DIR}"
fi

# Generate nginx configuration file
echo "[CONFIG] Generating nginx configuration..."
NGINX_CONF_LOCAL="${WORK_DIR}/openan-nginx.conf"
cat > "${NGINX_CONF_LOCAL}" << 'NGINX_EOF'
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
    # Ensure trailing slash for nginx proxy_pass
    [[ "${REGISTRY_PROXY_URL}" != */ ]] && REGISTRY_PROXY_URL="${REGISTRY_PROXY_URL}/"
    sed -i "s|proxy_pass http://127.0.0.1:5000/;|proxy_pass ${REGISTRY_PROXY_URL};|" "${NGINX_CONF_LOCAL}"
    echo "  [OK] Nginx /registry/ proxy_pass set to ${REGISTRY_PROXY_URL}"
fi

# Deploy configuration to nginx conf.d
NGINX_CONF_DEST="/etc/nginx/conf.d/openan.conf"
run_sudo cp "${NGINX_CONF_LOCAL}" "${NGINX_CONF_DEST}"
echo "  [OK] Configuration deployed to ${NGINX_CONF_DEST}"

# Remove default site if it conflicts (Debian/Ubuntu ships a default server on port 80)
if [ -f /etc/nginx/sites-enabled/default ]; then
    echo "[CLEAN] Removing default nginx site to avoid conflicts..."
    run_sudo rm -f /etc/nginx/sites-enabled/default
fi

# Test nginx configuration
echo "[TEST] Validating nginx configuration..."
if run_sudo nginx -t 2>&1; then
    echo "  [OK] nginx configuration is valid."
else
    echo "  [ERROR] nginx configuration test failed."
    exit 1
fi
else
    echo ""
    echo "=========================================="
    echo " Step 3.7: Configuring Nginx"
    echo "=========================================="
    echo "  [SKIP] nginx configuration skipped (--reg only, no --orc)."
    echo ""
fi

# =============================================================================
# Step 4: Start all services
# =============================================================================
echo ""
echo "=========================================="
echo " Step 4: Starting all services"
echo "=========================================="

# Initialize PIDs for dynamic summary
REGISTRY_PID=""
OC_BACKEND_PID=""
AGENTS_PID=""
NGINX_PID=""

# Clean all sample agent ports (defensive — residual samples.start_agents_server
# processes from a previous --sample run can cause 404 on orchestration API routes).
# samples.start_agents_server is a single process listening on 12 ports
# (8080 + 11 agent ports). See ADR-009 for the full port architecture.
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
    for sap in 8899 8900 8901 8902 8903 8904 8905 8906 8907 26335 26336; do
        free_port "${sap}"
    done
fi

# Start registry-center (port 5000)
if [ "${INSTALL_REGISTRY}" = "true" ]; then
free_port 5000
echo "[START] registry-center (http://127.0.0.1:5000)..."
cd "${REGISTRY_DIR}"
source venv/bin/activate
nohup python -m agent_registry.start > "${REGISTRY_DIR}/registry-center.log" 2>&1 &
REGISTRY_PID=$!
echo "  PID: ${REGISTRY_PID}"
fi

# Start orchestration-center backend (port 5001)
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
free_port 5001
echo "[START] orchestration-center backend (http://127.0.0.1:5001)..."
cd "${ORCHESTRATION_DIR}"
source venv/bin/activate
if [ "${INSTALL_REGISTRY}" = "false" ] && [ -n "${USER_REGISTRY_URL}" ]; then
    export AGENT_REGISTRY_URL="${USER_REGISTRY_URL}"
else
    export AGENT_REGISTRY_URL="http://127.0.0.1:5000"
fi
nohup python -m orchestrate.start > "${ORCHESTRATION_DIR}/backend.log" 2>&1 &
OC_BACKEND_PID=$!
echo "  PID: ${OC_BACKEND_PID}"
fi

# Start agents examples server (provides sample agents for testing)
if [ "${INSTALL_ORCHESTRATION}" = "true" ] && [ "${START_SAMPLE}" = "true" ]; then
AGENTS_PORT=8080
free_port "${AGENTS_PORT}"
echo "[START] agents examples server (http://127.0.0.1:${AGENTS_PORT})..."
cd "${ORCHESTRATION_DIR}"
source venv/bin/activate
nohup python -m samples.start_agents_server > "${ORCHESTRATION_DIR}/agents-server.log" 2>&1 &
AGENTS_PID=$!
echo "  PID: ${AGENTS_PID}"
elif [ "${INSTALL_ORCHESTRATION}" = "true" ] && [ "${START_SAMPLE}" = "false" ]; then
echo "[SKIP] agents examples server skipped (use --sample to enable)."
fi

# Start nginx (HTTPS reverse proxy on port 443)
if [ "${INSTALL_ORCHESTRATION}" = "true" ]; then
free_port 443
echo "[START] nginx (https://localhost)..."
if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
    echo "  [INFO] nginx is already running, reloading configuration..."
    run_sudo nginx -s reload 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
    run_sudo systemctl start nginx 2>/dev/null || run_sudo nginx
else
    run_sudo nginx 2>/dev/null || true
fi
sleep 1
NGINX_PID="$(pgrep -f 'nginx: master' 2>/dev/null | head -1)" || NGINX_PID=""
if [ -n "${NGINX_PID}" ]; then
    echo "  [OK] nginx started (PID: ${NGINX_PID})"
else
    echo "  [WARN] Could not determine nginx master PID."
fi
fi

# =============================================================================
# Detect VPS IP for remote access display in summary
# =============================================================================
VPS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || VPS_IP=""
[ -z "${VPS_IP}" ] && VPS_IP="localhost"

# =============================================================================
# Summary (dynamic — only lists services that were actually started)
# =============================================================================
echo ""
echo "=========================================="
echo " All services started!"
echo "=========================================="

STOP_PIDS=""
if [ -n "${REGISTRY_PID}" ]; then
    echo " registry-center:        http://127.0.0.1:5000  (PID: ${REGISTRY_PID})"
    STOP_PIDS="${REGISTRY_PID}"
fi
if [ -n "${OC_BACKEND_PID}" ]; then
    echo " orchestration backend:  http://127.0.0.1:5001  (PID: ${OC_BACKEND_PID})"
    STOP_PIDS="${STOP_PIDS} ${OC_BACKEND_PID}"
fi
if [ -n "${AGENTS_PID}" ]; then
    echo " agents examples server: http://127.0.0.1:8080  (PID: ${AGENTS_PID})"
    STOP_PIDS="${STOP_PIDS} ${AGENTS_PID}"
fi
if [ -n "${NGINX_PID}" ]; then
    echo " nginx (HTTPS):          https://${VPS_IP}  (PID: ${NGINX_PID})"
fi

echo ""
echo " Logs:"
if [ -n "${REGISTRY_PID}" ]; then
    echo "   ${REGISTRY_DIR}/registry-center.log"
fi
if [ -n "${OC_BACKEND_PID}" ]; then
    echo "   ${ORCHESTRATION_DIR}/backend.log"
fi
if [ -n "${AGENTS_PID}" ]; then
    echo "   ${ORCHESTRATION_DIR}/agents-server.log"
fi

echo ""
# Trim leading/trailing whitespace from STOP_PIDS
STOP_PIDS="$(echo ${STOP_PIDS})"
if [ -n "${STOP_PIDS}" ]; then
    echo " To stop all: kill ${STOP_PIDS}"
fi
if [ -n "${NGINX_PID}" ]; then
    echo "           nginx: sudo systemctl stop nginx  (or: sudo nginx -s stop)"
fi
echo "=========================================="
