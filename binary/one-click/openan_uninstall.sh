#!/bin/bash
# =============================================================================
# OpenAN Uninstallation Script
# Removes OpenAN project files, stops services, kills processes, and cleans
# nginx configuration. Preserves environment tools (Python, Node.js, npm, nginx).
#
# Usage: ./openan_uninstall.sh [--force] [-h, --help]
# See ADR-007 for design decisions.
# =============================================================================
set -uo pipefail

# =============================================================================
# Argument parsing: --force | --help
# =============================================================================
FORCE=false

print_usage() {
    cat << 'USAGE_EOF'
Usage: openan_uninstall.sh [OPTIONS]

Uninstall OpenAN projects (registry-center, orchestration-center), stop all
services, remove nginx configuration, and kill related processes.
Environment tools (Python, Node.js, npm, nginx) are preserved.

Options:
  --force       Skip interactive confirmation
  -h, --help    Show this help message and exit

Examples:
  ./openan_uninstall.sh           # Interactive confirmation
  ./openan_uninstall.sh --force   # No confirmation (for automation)
USAGE_EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force)
            FORCE=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}"

REGISTRY_DIR="${WORK_DIR}/registry-center"
ORCHESTRATION_DIR="${WORK_DIR}/orchestration-center"
NGINX_CONF_LOCAL="${WORK_DIR}/openan-nginx.conf"

NGINX_CONF_DEST="/etc/nginx/conf.d/openan.conf"
NGINX_SSL_DIR="/etc/nginx/ssl"

# =============================================================================
# Helper: run command with sudo if not root, or directly if root
# =============================================================================
run_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# =============================================================================
# Helper: find PIDs listening on a given TCP port.
# Priority: ss -tlnp (listeners only) → lsof -sTCP:LISTEN → fuser (last resort).
# Using ss/lsof with LISTEN filter avoids false positives from client connections
# that fuser reports (see ADR-008).
# Echoes space-separated PIDs on success, empty string if no process found.
# =============================================================================
find_pids_on_port() {
    local port="$1"
    local pids=""
    # 1. Prefer ss -tlnp (only returns listeners, not clients)
    if command -v ss >/dev/null 2>&1; then
        pids="$(ss -tlnp 2>/dev/null | grep ":${port}\b" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | tr '\n' ' ')" || true
    fi
    # 2. Fall back to lsof with LISTEN filter (only listeners)
    if [ -z "${pids}" ] && command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -t -i:"${port}" -sTCP:LISTEN 2>/dev/null)" || true
    fi
    # 3. Last resort: fuser (returns listeners AND clients — may produce false positives)
    if [ -z "${pids}" ] && command -v fuser >/dev/null 2>&1; then
        pids="$(fuser "${port}/tcp" 2>/dev/null)" || true
    fi
    echo "${pids}" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//'
}

# =============================================================================
# Helper: get full command line for a PID.
# Echoes the command line string, empty if PID invalid.
# =============================================================================
get_cmdline() {
    local pid="$1"
    if [ -n "${pid}" ] && [ -d "/proc/${pid}" ]; then
        cat "/proc/${pid}/cmdline" 2>/dev/null | tr '\0' ' ' || true
    elif command -v ps >/dev/null 2>&1; then
        ps -p "${pid}" -o args= 2>/dev/null || true
    fi
}

# =============================================================================
# Helper: kill a PID gracefully (SIGTERM first, then SIGKILL after 3s).
# =============================================================================
kill_pid() {
    local pid="$1"
    local label="$2"
    if [ -z "${pid}" ]; then
        return 0
    fi
    if ! kill -0 "${pid}" 2>/dev/null; then
        return 0
    fi
    echo "  [KILL] ${label} (PID: ${pid}) — sending SIGTERM..."
    kill "${pid}" 2>/dev/null || true
    local i
    for i in $(seq 1 3); do
        sleep 1
        if ! kill -0 "${pid}" 2>/dev/null; then
            echo "  [OK]   PID ${pid} terminated."
            return 0
        fi
    done
    echo "  [WARN] PID ${pid} did not respond to SIGTERM, sending SIGKILL..."
    kill -9 "${pid}" 2>/dev/null || true
    sleep 1
    if kill -0 "${pid}" 2>/dev/null; then
        echo "  [ERROR] Failed to kill PID ${pid}."
    else
        echo "  [OK]   PID ${pid} killed."
    fi
}

# =============================================================================
# Global OpenAN process patterns.
# If a process's cmdline matches ANY of these patterns (via grep -E),
# it is considered an OpenAN process and will be killed regardless of
# which port it is found on. This prevents cross-port process escape
# where a multi-port process (e.g. samples.start_agents_server) is
# skipped on all ports because no single per-port pattern matches.
# See ADR-008 for details.
# =============================================================================
OPENAN_PATTERNS="agent_registry|orchestrate|samples"

# =============================================================================
# Port-to-label mapping for scan display and kill logging.
# Format: "port:label"
# =============================================================================
#   port   label
#   5000   registry-center
#   5001   orchestration backend
#   8080   agents examples server (management port)
#   8899   sample agent — RAN Energy Saving Agent
#   8900   sample agent — Energy Saving Intent Agent
#   8901   sample agent — Live Streaming Agent
#   8902   sample agent — Assurance Agent
#   8903   sample agent — RAN Agent
#   8904   sample agent — Transport Workbench Agent
#   8905   sample agent — SPN Fault Handling Agent City1 OMC
#   8906   sample agent — SPN Fault Handling Agent City2 OMC
#   8907   sample agent — Uncertainty Simulation Agent
#   26335  sample agent — SPN Domain Agent
#   26336  sample agent — Workbench Platform Agent
#
# samples.start_agents_server is a single process listening on 12 ports
# (8080 + 11 agent ports). Killing it on any one port terminates all.
# See ADR-009 for the full sample agent port architecture.
OPENAN_PORTS=(
    "5000:registry-center"
    "5001:orchestration backend"
    "8080:agents examples server (management port)"
    "8899:sample agent — RAN Energy Saving Agent"
    "8900:sample agent — Energy Saving Intent Agent"
    "8901:sample agent — Live Streaming Agent"
    "8902:sample agent — Assurance Agent"
    "8903:sample agent — RAN Agent"
    "8904:sample agent — Transport Workbench Agent"
    "8905:sample agent — SPN Fault Handling Agent City1 OMC"
    "8906:sample agent — SPN Fault Handling Agent City2 OMC"
    "8907:sample agent — Uncertainty Simulation Agent"
    "26335:sample agent — SPN Domain Agent"
    "26336:sample agent — Workbench Platform Agent"
)

# =============================================================================
# Pre-uninstall scan: detect what will be removed (for confirmation display)
# =============================================================================
SCAN_PROCESSES=""
for entry in "${OPENAN_PORTS[@]}"; do
    port="${entry%%:*}"
    label="${entry#*:}"
    pids="$(find_pids_on_port "${port}")"
    if [ -n "${pids}" ]; then
        for pid in ${pids}; do
            cmdline="$(get_cmdline "${pid}")"
            if echo "${cmdline}" | grep -qE "${OPENAN_PATTERNS}"; then
                SCAN_PROCESSES="${SCAN_PROCESSES}  kill PID ${pid} (port ${port}, ${label})\n"
            fi
        done
    fi
done

# Check nginx
SCAN_NGINX=""
if pgrep -x nginx >/dev/null 2>&1; then
    SCAN_NGINX="  stop nginx process (port 443)\n"
fi
if [ -f "${NGINX_CONF_DEST}" ]; then
    SCAN_NGINX="${SCAN_NGINX}  delete ${NGINX_CONF_DEST}\n"
fi
if [ -f "${NGINX_SSL_DIR}/cert.pem" ] || [ -f "${NGINX_SSL_DIR}/key.pem" ]; then
    SCAN_NGINX="${SCAN_NGINX}  delete ${NGINX_SSL_DIR}/cert.pem, key.pem\n"
fi
if [ -f "${NGINX_CONF_LOCAL}" ]; then
    SCAN_NGINX="${SCAN_NGINX}  delete ${NGINX_CONF_LOCAL}\n"
fi

# Check project directories
SCAN_DIRS=""
if [ -d "${REGISTRY_DIR}" ]; then
    SCAN_DIRS="${SCAN_DIRS}  delete ${REGISTRY_DIR}/\n"
fi
if [ -d "${ORCHESTRATION_DIR}" ]; then
    SCAN_DIRS="${SCAN_DIRS}  delete ${ORCHESTRATION_DIR}/\n"
fi

# =============================================================================
# Interactive confirmation (skip with --force)
# =============================================================================
if [ "${FORCE}" = "false" ]; then
    echo "=========================================="
    echo " OpenAN Uninstallation Plan"
    echo "=========================================="
    echo ""
    if [ -n "${SCAN_PROCESSES}" ]; then
        echo "Processes to kill:"
        printf "%b" "${SCAN_PROCESSES}"
    else
        echo "Processes to kill: (none detected)"
    fi
    echo ""
    if [ -n "${SCAN_NGINX}" ]; then
        echo "Nginx to stop/clean:"
        printf "%b" "${SCAN_NGINX}"
    else
        echo "Nginx to stop/clean: (none detected)"
    fi
    echo ""
    if [ -n "${SCAN_DIRS}" ]; then
        echo "Directories to delete:"
        printf "%b" "${SCAN_DIRS}"
    else
        echo "Directories to delete: (none detected)"
    fi
    echo ""
    echo "Environment tools (Python, Node.js, npm, nginx) will be PRESERVED."
    echo ""
    read -r -p "Proceed with uninstallation? [y/N]: " CONFIRM < /dev/tty || CONFIRM=""
    case "${CONFIRM}" in
        [yY]|[yY][eE][sS])
            echo ""
            ;;
        *)
            echo "[CANCEL] Uninstallation aborted."
            exit 0
            ;;
    esac
fi

# =============================================================================
# Step 1: Kill OpenAN processes by port with smart identification
# =============================================================================
echo "=========================================="
echo " Step 1: Stopping OpenAN processes"
echo "=========================================="

for entry in "${OPENAN_PORTS[@]}"; do
    port="${entry%%:*}"
    label="${entry#*:}"

    pids="$(find_pids_on_port "${port}")"
    if [ -z "${pids}" ]; then
        echo "  [SKIP] Port ${port} (${label}) — no process listening."
        continue
    fi

    for pid in ${pids}; do
        cmdline="$(get_cmdline "${pid}")"
        if echo "${cmdline}" | grep -qE "${OPENAN_PATTERNS}"; then
            kill_pid "${pid}" "${label} (port ${port})"
        else
            echo "  [WARN] Port ${port} (PID: ${pid}) — cmdline does not match any OpenAN pattern."
            echo "         cmdline: $(printf '%.120s' "${cmdline}")"
            echo "         Skipping to avoid killing non-OpenAN process."
        fi
    done
done

echo ""

# =============================================================================
# Step 2: Stop nginx (three-level fallback, symmetric to install script)
# =============================================================================
echo "=========================================="
echo " Step 2: Stopping nginx"
echo "=========================================="

NGINX_STOPPED=false

if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
    echo "  [TRY] systemctl stop nginx..."
    if run_sudo systemctl stop nginx 2>/dev/null; then
        NGINX_STOPPED=true
        echo "  [OK] nginx stopped via systemctl."
    fi
fi

if [ "${NGINX_STOPPED}" = "false" ]; then
    nginx_bin=""
    if command -v nginx >/dev/null 2>&1; then
        nginx_bin="nginx"
    elif [ -x /usr/sbin/nginx ]; then
        nginx_bin="/usr/sbin/nginx"
    elif [ -x /sbin/nginx ]; then
        nginx_bin="/sbin/nginx"
    fi
    if [ -n "${nginx_bin}" ]; then
        echo "  [TRY] ${nginx_bin} -s stop..."
        run_sudo "${nginx_bin}" -s stop 2>/dev/null && NGINX_STOPPED=true || true
        sleep 1
    fi
fi

if [ "${NGINX_STOPPED}" = "false" ]; then
    if pgrep -x nginx >/dev/null 2>&1; then
        echo "  [TRY] pkill nginx..."
        run_sudo pkill -x nginx 2>/dev/null || true
        sleep 1
        if ! pgrep -x nginx >/dev/null 2>&1; then
            NGINX_STOPPED=true
            echo "  [OK] nginx killed via pkill."
        fi
    fi
fi

if [ "${NGINX_STOPPED}" = "false" ]; then
    if ! pgrep -x nginx >/dev/null 2>&1; then
        echo "  [SKIP] nginx is not running."
    else
        echo "  [WARN] Failed to stop nginx. It may be managed by a different init system."
        echo "         Please stop it manually: sudo systemctl stop nginx  (or: sudo nginx -s stop)"
    fi
else
    echo "  [OK] nginx stopped."
fi

echo ""

# =============================================================================
# Step 3: Remove nginx configuration files
# =============================================================================
echo "=========================================="
echo " Step 3: Removing nginx configuration"
echo "=========================================="

# Remove deployed nginx config
if [ -f "${NGINX_CONF_DEST}" ]; then
    echo "  [DEL] ${NGINX_CONF_DEST}"
    run_sudo rm -f "${NGINX_CONF_DEST}" 2>/dev/null && echo "  [OK] Removed." || \
        echo "  [WARN] Failed to remove. Please delete manually: sudo rm -f ${NGINX_CONF_DEST}"
else
    echo "  [SKIP] ${NGINX_CONF_DEST} — not found."
fi

# Remove SSL certificates
if [ -f "${NGINX_SSL_DIR}/cert.pem" ] || [ -f "${NGINX_SSL_DIR}/key.pem" ]; then
    echo "  [DEL] ${NGINX_SSL_DIR}/cert.pem, key.pem"
    run_sudo rm -f "${NGINX_SSL_DIR}/cert.pem" "${NGINX_SSL_DIR}/key.pem" 2>/dev/null && echo "  [OK] SSL certificates removed." || \
        echo "  [WARN] Failed to remove SSL certificates. Please delete manually: sudo rm -f ${NGINX_SSL_DIR}/cert.pem ${NGINX_SSL_DIR}/key.pem"
else
    echo "  [SKIP] ${NGINX_SSL_DIR}/cert.pem, key.pem — not found."
fi

# Remove static assets directory (frontend dist deployed by ADR-014)
if [ -d /var/www/openan ]; then
    echo "  [DEL] /var/www/openan"
    run_sudo rm -rf /var/www/openan 2>/dev/null && echo "  [OK] Static assets removed." || \
        echo "  [WARN] Failed to remove. Please delete manually: sudo rm -rf /var/www/openan"
else
    echo "  [SKIP] /var/www/openan — not found."
fi

# Remove local nginx config copy
if [ -f "${NGINX_CONF_LOCAL}" ]; then
    echo "  [DEL] ${NGINX_CONF_LOCAL}"
    rm -f "${NGINX_CONF_LOCAL}" && echo "  [OK] Removed." || \
        echo "  [WARN] Failed to remove ${NGINX_CONF_LOCAL}."
else
    echo "  [SKIP] ${NGINX_CONF_LOCAL} — not found."
fi

echo ""

# =============================================================================
# Step 4: Remove project directories
# =============================================================================
echo "=========================================="
echo " Step 4: Removing project directories"
echo "=========================================="

# Remove registry-center
if [ -d "${REGISTRY_DIR}" ]; then
    echo "  [DEL] ${REGISTRY_DIR}"
    rm -rf "${REGISTRY_DIR}" 2>/dev/null && echo "  [OK] registry-center removed." || \
        echo "  [WARN] Failed to remove. Please delete manually: rm -rf ${REGISTRY_DIR}"
else
    echo "  [SKIP] ${REGISTRY_DIR} — not found."
fi

# Remove orchestration-center
if [ -d "${ORCHESTRATION_DIR}" ]; then
    echo "  [DEL] ${ORCHESTRATION_DIR}"
    rm -rf "${ORCHESTRATION_DIR}" 2>/dev/null && echo "  [OK] orchestration-center removed." || \
        echo "  [WARN] Failed to remove. Please delete manually: rm -rf ${ORCHESTRATION_DIR}"
else
    echo "  [SKIP] ${ORCHESTRATION_DIR} — not found."
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "=========================================="
echo " Uninstallation complete!"
echo "=========================================="
echo ""
echo " Removed:"
echo "   - OpenAN processes (ports 5000, 5001, 8080, 8899-8907, 26335, 26336)"
echo "   - nginx process (port 443)"
echo "   - nginx config: ${NGINX_CONF_DEST}"
echo "   - nginx SSL certs: ${NGINX_SSL_DIR}/cert.pem, key.pem"
echo "   - local nginx config: ${NGINX_CONF_LOCAL}"
echo "   - static assets: /var/www/openan/"
echo "   - project dirs: registry-center/, orchestration-center/"
echo ""
echo " Preserved (environment tools):"
echo "   - Python, Node.js, npm, nginx binary, openssl"
if [ -d "${WORK_DIR}/.python3.12" ]; then
    echo "   - ${WORK_DIR}/.python3.12/"
fi
if [ -d "${WORK_DIR}/.node" ]; then
    echo "   - ${WORK_DIR}/.node/"
fi
echo ""
echo " To reinstall OpenAN:"
echo "   ./openan_install.sh"
echo "=========================================="
