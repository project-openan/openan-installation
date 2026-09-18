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
# uninstall.sh - Unified offline uninstaller for OpenAN
#
# Adapted from one-click uninstall.sh with Glob-based directory
# detection to handle versioned directory names (e.g. registry-center-1.0.0-linux/).
#
# Removes OpenAN project files, stops services, kills processes, and cleans
# nginx configuration. Preserves environment tools (Python, Node.js, npm, nginx).
#
# Usage: ./uninstall.sh [--force] [-h, --help]
# =============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Argument parsing: --force | --help
# =============================================================================
FORCE=false

print_usage() {
    cat << 'USAGE_EOF'
Usage: uninstall.sh [OPTIONS]

Uninstall OpenAN projects (registry-center, orchestration-center), stop all
services, remove nginx configuration, and kill related processes.
Environment tools (Python, Node.js, npm, nginx) are preserved.

Options:
  --force       Skip interactive confirmation
  -h, --help    Show this help message and exit

Examples:
  ./uninstall.sh           # Interactive confirmation
  ./uninstall.sh --force   # No confirmation (for automation)
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
            echo -e "${RED}Error: Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}"

# =============================================================================
# Glob-based directory detection (handles versioned directory names)
# =============================================================================
REGISTRY_DIR=""
for d in "${WORK_DIR}"/registry-center-*; do
    [ -d "$d" ] && REGISTRY_DIR="$d" && break
done

ORCHESTRATION_DIR=""
for d in "${WORK_DIR}"/orchestration-center-*; do
    [ -d "$d" ] && ORCHESTRATION_DIR="$d" && break
done

# Local nginx config copy (created by install.sh in orc root dir's log/)
NGINX_CONF_LOCAL=""
for f in "${WORK_DIR}"/orchestration-center-*/log/openan-nginx.conf; do
    [ -f "$f" ] && NGINX_CONF_LOCAL="$f" && break
done

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
# =============================================================================
find_pids_on_port() {
    local port="$1"
    local pids=""
    if command -v ss >/dev/null 2>&1; then
        pids="$(ss -tlnp 2>/dev/null | grep ":${port}\b" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | tr '\n' ' ')" || true
    fi
    if [ -z "${pids}" ] && command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -t -i:"${port}" -sTCP:LISTEN 2>/dev/null)" || true
    fi
    if [ -z "${pids}" ] && command -v fuser >/dev/null 2>&1; then
        pids="$(fuser "${port}/tcp" 2>/dev/null)" || true
    fi
    echo "${pids}" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//'
}

# =============================================================================
# Helper: get full command line for a PID.
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
    echo -e "  ${YELLOW}[KILL]${NC} ${label} (PID: ${pid}) — sending SIGTERM..."
    kill "${pid}" 2>/dev/null || true
    local i
    for i in $(seq 1 3); do
        sleep 1
        if ! kill -0 "${pid}" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC}   PID ${pid} terminated."
            return 0
        fi
    done
    echo -e "  ${YELLOW}⚠ PID ${pid} did not respond to SIGTERM, sending SIGKILL...${NC}"
    kill -9 "${pid}" 2>/dev/null || true
    sleep 1
    if kill -0 "${pid}" 2>/dev/null; then
        echo -e "  ${RED}Error: Failed to kill PID ${pid}.${NC}"
    else
        echo -e "  ${GREEN}✓${NC}   PID ${pid} killed."
    fi
}

# =============================================================================
# Global OpenAN process patterns and port-to-label mapping.
# =============================================================================
OPENAN_PATTERNS="agent_registry|orchestrate|samples"

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
# Pre-uninstall scan: detect what will be removed
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
if [ -n "${NGINX_CONF_LOCAL}" ]; then
    SCAN_NGINX="${SCAN_NGINX}  delete ${NGINX_CONF_LOCAL}\n"
fi

# Check project directories
SCAN_DIRS=""
if [ -n "${REGISTRY_DIR}" ] && [ -d "${REGISTRY_DIR}" ]; then
    SCAN_DIRS="${SCAN_DIRS}  delete ${REGISTRY_DIR}/\n"
fi
if [ -n "${ORCHESTRATION_DIR}" ] && [ -d "${ORCHESTRATION_DIR}" ]; then
    SCAN_DIRS="${SCAN_DIRS}  delete ${ORCHESTRATION_DIR}/\n"
fi

# =============================================================================
# Interactive confirmation (skip with --force)
# =============================================================================
if [ "${FORCE}" = "false" ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  OpenAN Uninstallation Plan${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    if [ -n "${SCAN_PROCESSES}" ]; then
        echo "Processes to kill:"
        printf "%b" "${SCAN_PROCESSES}"
    else
        echo -e "Processes to kill: ${YELLOW}(none detected)${NC}"
    fi
    echo ""
    if [ -n "${SCAN_NGINX}" ]; then
        echo "Nginx to stop/clean:"
        printf "%b" "${SCAN_NGINX}"
    else
        echo -e "Nginx to stop/clean: ${YELLOW}(none detected)${NC}"
    fi
    echo ""
    if [ -n "${SCAN_DIRS}" ]; then
        echo "Directories to delete:"
        printf "%b" "${SCAN_DIRS}"
    else
        echo -e "Directories to delete: ${YELLOW}(none detected)${NC}"
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
            echo -e "${YELLOW}[CANCEL] Uninstallation aborted.${NC}"
            exit 0
            ;;
    esac
fi

# =============================================================================
# Step 1: Kill OpenAN processes by port with smart identification
# =============================================================================
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW} Step 1: Stopping OpenAN processes${NC}"
echo -e "${BLUE}========================================${NC}"

for entry in "${OPENAN_PORTS[@]}"; do
    port="${entry%%:*}"
    label="${entry#*:}"

    pids="$(find_pids_on_port "${port}")"
    if [ -z "${pids}" ]; then
        echo -e "  ${YELLOW}⚠${NC} Port ${port} (${label}) — no process listening."
        continue
    fi

    for pid in ${pids}; do
        cmdline="$(get_cmdline "${pid}")"
        if echo "${cmdline}" | grep -qE "${OPENAN_PATTERNS}"; then
            kill_pid "${pid}" "${label} (port ${port})"
        else
            echo -e "  ${YELLOW}⚠${NC} Port ${port} (PID: ${pid}) — cmdline does not match any OpenAN pattern."
            echo "         cmdline: $(printf '%.120s' "${cmdline}")"
            echo "         Skipping to avoid killing non-OpenAN process."
        fi
    done
done

echo ""

# =============================================================================
# Step 2: Stop nginx (three-level fallback)
# =============================================================================
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW} Step 2: Stopping nginx${NC}"
echo -e "${BLUE}========================================${NC}"

NGINX_STOPPED=false

if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
    echo -e "  ${YELLOW}[TRY] systemctl stop nginx...${NC}"
    if run_sudo systemctl stop nginx 2>/dev/null; then
        NGINX_STOPPED=true
        echo -e "  ${GREEN}✓${NC} nginx stopped via systemctl."
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
        echo -e "  ${YELLOW}[TRY] ${nginx_bin} -s stop...${NC}"
        run_sudo "${nginx_bin}" -s stop 2>/dev/null && NGINX_STOPPED=true || true
        sleep 1
    fi
fi

if [ "${NGINX_STOPPED}" = "false" ]; then
    if pgrep -x nginx >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[TRY] pkill nginx...${NC}"
        run_sudo pkill -x nginx 2>/dev/null || true
        sleep 1
        if ! pgrep -x nginx >/dev/null 2>&1; then
            NGINX_STOPPED=true
            echo -e "  ${GREEN}✓${NC} nginx killed via pkill."
        fi
    fi
fi

if [ "${NGINX_STOPPED}" = "false" ]; then
    if ! pgrep -x nginx >/dev/null 2>&1; then
        echo -e "  ${YELLOW}⚠${NC} nginx is not running."
    else
        echo -e "  ${YELLOW}⚠ Failed to stop nginx. It may be managed by a different init system.${NC}"
        echo "         Please stop it manually: sudo systemctl stop nginx  (or: sudo nginx -s stop)"
    fi
else
    echo -e "  ${GREEN}✓${NC} nginx stopped."
fi

echo ""

# =============================================================================
# Step 3: Remove nginx configuration files
# =============================================================================
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW} Step 3: Removing nginx configuration${NC}"
echo -e "${BLUE}========================================${NC}"

# Remove deployed nginx config
if [ -f "${NGINX_CONF_DEST}" ]; then
    echo -e "  ${YELLOW}[DEL]${NC} ${NGINX_CONF_DEST}"
    run_sudo rm -f "${NGINX_CONF_DEST}" 2>/dev/null && echo -e "  ${GREEN}✓${NC} Removed." || \
        echo -e "  ${YELLOW}⚠ Failed to remove. Please delete manually: sudo rm -f ${NGINX_CONF_DEST}${NC}"
else
    echo -e "  ${YELLOW}⚠${NC} ${NGINX_CONF_DEST} — not found."
fi

# Remove SSL certificates
if [ -f "${NGINX_SSL_DIR}/cert.pem" ] || [ -f "${NGINX_SSL_DIR}/key.pem" ]; then
    echo -e "  ${YELLOW}[DEL]${NC} ${NGINX_SSL_DIR}/cert.pem, key.pem"
    run_sudo rm -f "${NGINX_SSL_DIR}/cert.pem" "${NGINX_SSL_DIR}/key.pem" 2>/dev/null && echo -e "  ${GREEN}✓${NC} SSL certificates removed." || \
        echo -e "  ${YELLOW}⚠ Failed to remove SSL certificates. Please delete manually.${NC}"
else
    echo -e "  ${YELLOW}⚠${NC} ${NGINX_SSL_DIR}/cert.pem, key.pem — not found."
fi

# Remove static assets directory (frontend dist deployed by ADR-014)
if [ -d /var/www/openan ]; then
    echo -e "  ${YELLOW}[DEL]${NC} /var/www/openan"
    run_sudo rm -rf /var/www/openan 2>/dev/null && echo -e "  ${GREEN}✓${NC} Static assets removed." || \
        echo -e "  ${YELLOW}⚠ Failed to remove. Please delete manually: sudo rm -rf /var/www/openan${NC}"
else
    echo -e "  ${YELLOW}⚠${NC} /var/www/openan — not found."
fi

# Remove local nginx config copy
if [ -n "${NGINX_CONF_LOCAL}" ] && [ -f "${NGINX_CONF_LOCAL}" ]; then
    echo -e "  ${YELLOW}[DEL]${NC} ${NGINX_CONF_LOCAL}"
    rm -f "${NGINX_CONF_LOCAL}" && echo -e "  ${GREEN}✓${NC} Removed." || \
        echo -e "  ${YELLOW}⚠ Failed to remove ${NGINX_CONF_LOCAL}.${NC}"
else
    echo -e "  ${YELLOW}⚠${NC} Local nginx config copy — not found."
fi

echo ""

# =============================================================================
# Step 4: Remove project directories
# =============================================================================
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW} Step 4: Removing project directories${NC}"
echo -e "${BLUE}========================================${NC}"

# Remove registry-center
if [ -n "${REGISTRY_DIR}" ] && [ -d "${REGISTRY_DIR}" ]; then
    echo -e "  ${YELLOW}[DEL]${NC} ${REGISTRY_DIR}"
    rm -rf "${REGISTRY_DIR}" 2>/dev/null && echo -e "  ${GREEN}✓${NC} registry-center removed." || \
        echo -e "  ${YELLOW}⚠ Failed to remove. Please delete manually: rm -rf ${REGISTRY_DIR}${NC}"
else
    echo -e "  ${YELLOW}⚠${NC} registry-center directory — not found."
fi

# Remove orchestration-center
if [ -n "${ORCHESTRATION_DIR}" ] && [ -d "${ORCHESTRATION_DIR}" ]; then
    echo -e "  ${YELLOW}[DEL]${NC} ${ORCHESTRATION_DIR}"
    rm -rf "${ORCHESTRATION_DIR}" 2>/dev/null && echo -e "  ${GREEN}✓${NC} orchestration-center removed." || \
        echo -e "  ${YELLOW}⚠ Failed to remove. Please delete manually: rm -rf ${ORCHESTRATION_DIR}${NC}"
else
    echo -e "  ${YELLOW}⚠${NC} orchestration-center directory — not found."
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Uninstallation complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "  Removed:"
echo "   - OpenAN processes (ports 5000, 5001, 8080, 8899-8907, 26335, 26336)"
echo "   - nginx process (port 443)"
echo "   - nginx config: ${NGINX_CONF_DEST}"
echo "   - nginx SSL certs: ${NGINX_SSL_DIR}/cert.pem, key.pem"
if [ -n "${NGINX_CONF_LOCAL}" ]; then
    echo "   - local nginx config: ${NGINX_CONF_LOCAL}"
fi
echo "   - static assets: /var/www/openan/"
if [ -n "${REGISTRY_DIR}" ]; then
    echo "   - project dir: ${REGISTRY_DIR}/"
fi
if [ -n "${ORCHESTRATION_DIR}" ]; then
    echo "   - project dir: ${ORCHESTRATION_DIR}/"
fi
echo ""
echo "  Preserved (environment tools):"
echo "   - Python, Node.js, npm, nginx binary, openssl"
if [ -d "${WORK_DIR}/.python3.12" ]; then
    echo "   - ${WORK_DIR}/.python3.12/"
fi
if [ -d "${WORK_DIR}/.node" ]; then
    echo "   - ${WORK_DIR}/.node/"
fi
echo ""
echo "  To reinstall OpenAN:"
echo "    ./install.sh"
echo -e "${BLUE}========================================${NC}"
