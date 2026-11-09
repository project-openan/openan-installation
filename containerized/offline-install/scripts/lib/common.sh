#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for the offline installer.
# Sourced by check-env.sh / install.sh / push-images.sh / uninstall.sh.

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_prompt(){ echo -e "${BLUE}[?]${NC} $1"; }


# ---------------------------------------------------------------------------
# Validation with interactive retry (issue #40 pattern)
# ---------------------------------------------------------------------------
# validate_with_retry <label> <validate-fn> <reprompt-fn>
#   Runs validate-fn; on failure (non-interactive) exits 2 immediately.
#   Interactive: re-runs reprompt-fn and validate-fn up to MAX_ATTEMPTS,
#   then offers [s]kip (with a warning) or abort.  The validate-fn must
#   print log_error lines describing every problem before returning 1.
MAX_ATTEMPTS=3
validate_with_retry() {
    local label="$1" validate_fn="$2" reprompt_fn="$3"
    if $validate_fn; then
        return 0
    fi
    if [ "$ASSUME_YES" = "true" ] || [ -n "$CONFIG_FILE" ]; then
        log_error "$label: validation failed in non-interactive mode; fix the values and re-run."
        exit 2
    fi
    local attempt=1
    while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
        log_warn "$label: validation failed (attempt $attempt/$MAX_ATTEMPTS). Re-prompting."
        $reprompt_fn
        if $validate_fn; then
            return 0
        fi
        attempt=$((attempt + 1))
    done
    log_error "$label still invalid after $MAX_ATTEMPTS attempts."
    if ask_yes_no "Skip $label validation and continue anyway (not recommended)?" "no"; then
        log_warn "Continuing with invalid $label."
        return 0
    fi
    log_error "Aborting. Re-run the installer to start over."
    exit 2
}

# --- Field validators (print every problem, return 1 on any failure) --------
# INGRESS_HOST contract (commit 4d518ea): a DNS name OR a bare IPv4/IPv6
# address (MetalLB VIP / node IP) enables https://<host> access with the
# matching SAN. Empty = direct IP access via the LoadBalancer / NodePort.
# We only reject values that are neither a DNS name nor an IP (whitespace,
# scheme, path, ...), so the retry loop re-prompts on real typos without
# regressing the bare-IP flow.
validate_ingress_host() {
    local rc=0
    if [ -n "$INGRESS_HOST" ]; then
        if printf '%s' "$INGRESS_HOST" | grep -q '[[:space:]]'; then
            log_error "INGRESS_HOST must not contain whitespace"
            rc=1
        elif printf '%s' "$INGRESS_HOST" | grep -q '://'; then
            log_error "INGRESS_HOST must be a host or IP only (no scheme/path, e.g. openan.example.com)"
            rc=1
        elif ! printf '%s' "$INGRESS_HOST" | grep -Eq '^[A-Za-z0-9._-]+$'; then
            log_error "INGRESS_HOST contains invalid characters (allowed: letters, digits, dot, dash, underscore)"
            rc=1
        fi
    fi
    return "$rc"
}

validate_db_password() {
    local rc=0
    if [ -z "$DB_PASSWORD" ]; then
        log_error "DB_PASSWORD is required (config.env or the interactive prompt); there is no default."
        rc=1
    elif [ "${#DB_PASSWORD}" -lt 8 ]; then
        log_error "DB_PASSWORD must be at least 8 characters"
        rc=1
    fi
    return "$rc"
}

validate_namespace() {
    local rc=0
    if ! printf '%s' "$K8S_NAMESPACE" | grep -Eq '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' || [ "${#K8S_NAMESPACE}" -gt 63 ]; then
        log_error "K8S_NAMESPACE must be a lowercase DNS label (a-z, 0-9, '-'), max 63 characters"
        rc=1
    fi
    return "$rc"
}

validate_metallb_pool() {
    local rc=0
    if [ "$INSTALL_METALLB" = "true" ] && [ -n "$METALLB_POOL" ]; then
        local pool_ok="true" token
        IFS=','
        for token in $METALLB_POOL; do
            printf '%s' "$token" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}(-[0-9]{1,3}(\.[0-9]{1,3}){3}|/[0-9]{1,2})?$' || pool_ok="false"
        done
        unset IFS
        if [ "$pool_ok" != "true" ]; then
            log_error "METALLB_POOL must be IP ranges (a.b.c.d-a.b.c.d) and/or CIDRs (a.b.c.d/n), comma-separated"
            rc=1
        fi
    fi
    return "$rc"
}

# --- Re-prompt helpers (interactive only) -----------------------------------
reprompt_ingress_host() {
    INGRESS_HOST="$(ask_input "  Ingress host (empty = access by IP)" "")"
}

reprompt_db_password() {
    DB_PASSWORD="$(ask_input_secret "  Database password (8+ characters)" "")"
}

reprompt_namespace() {
    K8S_NAMESPACE="$(ask_input "  Kubernetes namespace" "openan")"
}

reprompt_metallb_pool() {
    METALLB_POOL="$(ask_input "  MetalLB IP pool (e.g. 192.168.1.200-192.168.1.250)" "")"
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_arch() {
    # Container image arch suffix used by the offline bundle (amd64 / arm64)
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "" ;;
    esac
}

detect_os_id() {
    # Returns the /etc/os-release ID (e.g. openeuler, centos, ubuntu)
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Interactive helpers
# ---------------------------------------------------------------------------
ask_yes_no() {
    local prompt="$1"
    local default="${2:-yes}"
    local answer

    if [ "$ASSUME_YES" = "true" ]; then
        return 0
    fi

    if [ "$default" = "yes" ]; then
        log_prompt "$prompt [Y/n]:" >&2
        read -r answer
        [ -z "$answer" ] && answer="y"
    else
        log_prompt "$prompt [y/N]:" >&2
        read -r answer
        [ -z "$answer" ] && answer="n"
    fi

    [[ "$answer" =~ ^[Yy] ]]
}

ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [ -n "$default" ]; then
        log_prompt "$prompt [$default]:" >&2
    else
        log_prompt "$prompt:" >&2
    fi
    read -r value
    echo "${value:-$default}"
}

ask_input_secret() {
    local prompt="$1"
    local default="${2:-}"
    local char value=""

    if [ -n "$default" ]; then
        log_prompt "$prompt [****]:" >&2
    else
        log_prompt "$prompt:" >&2
    fi
    while IFS= read -rs -n1 char 2>/dev/null; do
        [ -z "${char}" ] && break
        if [[ "${char}" == $'\177' || "${char}" == $'\010' ]]; then
            if [ -n "${value}" ]; then
                value="${value%?}"
                printf '\b \b' >&2
            fi
            continue
        fi
        value+="${char}"
        printf '*' >&2
    done < /dev/tty
    printf '\n' >&2
    echo "${value:-$default}"
}

ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice i

    echo "" >&2
    log_prompt "$prompt" >&2
    for i in "${!options[@]}"; do
        echo "  $((i + 1)). ${options[$i]}" >&2
    done
    read -r choice >&2

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
        echo "${options[$((choice - 1))]}"
    else
        echo "${options[0]}"
    fi
}

# ---------------------------------------------------------------------------
# Config file handling (config.env is a plain KEY=VALUE shell file)
# ---------------------------------------------------------------------------
load_config() {
    local file="$1"
    if [ ! -r "$file" ]; then
        log_error "Config file not found or unreadable: $file"
        exit 1
    fi
    log_info "Loading config from $file"
    # shellcheck disable=SC1090
    . "$file"
}

save_config() {
    local file="$1"
    # umask 077 in a subshell: private at creation, not after a world-readable write
    (umask 077
    {
        echo "# OpenAN offline installation config (generated $(date -u +%Y-%m-%dT%H:%M:%SZ))"
        echo "K8S_NAMESPACE=\"${K8S_NAMESPACE}\""
        echo "STORAGE_NODE=\"${STORAGE_NODE}\""
        echo "REGISTRY_NODE=\"${REGISTRY_NODE}\""
        echo "REGISTRY_NODE_IP=\"${REGISTRY_NODE_IP}\""
        echo "REGISTRY_NODEPORT=\"${REGISTRY_NODEPORT}\""
        echo "INSTALL_REGISTRY=\"${INSTALL_REGISTRY}\""
        echo "INSTALL_METALLB=\"${INSTALL_METALLB}\""
        echo "METALLB_POOL=\"${METALLB_POOL}\""
        echo "INGRESS_HOST=\"${INGRESS_HOST}\""
        echo "HTTPS_ENABLED=\"${HTTPS_ENABLED}\""
        echo "HTTPS_VERIFY_CLIENT=\"${HTTPS_VERIFY_CLIENT}\""
        echo "RC_TLS_SECRET=\"${RC_TLS_SECRET}\""
        echo "OC_TLS_SECRET=\"${OC_TLS_SECRET}\""
        echo "INGRESS_CLIENT_SECRET=\"${INGRESS_CLIENT_SECRET}\""
        echo "REGISTRY_CLIENT_SECRET=\"${REGISTRY_CLIENT_SECRET}\""
        echo "PUBLIC_TLS_SECRET=\"${PUBLIC_TLS_SECRET}\""
        echo "DB_TYPE=\"${DB_TYPE}\""
        echo "DB_PASSWORD=\"${DB_PASSWORD}\""
        echo "STORAGE_MODE=\"${STORAGE_MODE}\""
        echo "STORAGE_CLASS=\"${STORAGE_CLASS}\""
        echo "STORAGE_SIZE=\"${STORAGE_SIZE}\""
        echo "HOSTPATH=\"${HOSTPATH}\""
        echo "POSTGRES_IMAGE=\"${POSTGRES_IMAGE}\""
        echo "MYSQL_IMAGE=\"${MYSQL_IMAGE}\""
        echo "REGISTRY_CENTER_IMAGE=\"${REGISTRY_CENTER_IMAGE}\""
        echo "ORCHESTRATION_CENTER_IMAGE=\"${ORCHESTRATION_CENTER_IMAGE}\""
        echo "WORKFLOW_DESIGNER_IMAGE=\"${WORKFLOW_DESIGNER_IMAGE}\""
        echo "FRONTEND_TYPE=\"${FRONTEND_TYPE}\""
        echo "PORTAL_IMAGE=\"${PORTAL_IMAGE}\""
        echo "OC_ADMIN_PASSWORD=\"${OC_ADMIN_PASSWORD}\""
        echo "REGISTRY_CHAT_MODEL=\"${REGISTRY_CHAT_MODEL}\""
        echo "REGISTRY_CHAT_URL=\"${REGISTRY_CHAT_URL}\""
        echo "REGISTRY_CHAT_APIKEY=\"${REGISTRY_CHAT_APIKEY}\""
        echo "ORCH_CHAT_MODEL=\"${ORCH_CHAT_MODEL}\""
        echo "ORCH_CHAT_URL=\"${ORCH_CHAT_URL}\""
        echo "ORCH_CHAT_APIKEY=\"${ORCH_CHAT_APIKEY}\""
        echo "LLM_VALIDATE=\"${LLM_VALIDATE}\""
        echo "REGISTRY_SIGNATURE_VALIDATION_ENABLED=\"${REGISTRY_SIGNATURE_VALIDATION_ENABLED}\""
        echo "START_AGENTS_SERVER=\"${START_AGENTS_SERVER}\""
    } >"$file"
    )
    chmod 600 "$file"
    log_info "Wrote config to $file"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
mask_key() {
    local key="$1"
    local len=${#key}
    if [ "$len" -gt 8 ]; then
        echo "${key:0:4}...${key: -4}"
    else
        echo "***"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# Returns 0 when the local node's containerd has the given registry host
# configured as insecure (or skipped TLS verification).
containerd_insecure_configured() {
    local host="$1"
    local cfg="/etc/containerd/config.toml"
    [ -r "$cfg" ] || return 1
    grep -q "$host" "$cfg" 2>/dev/null
}

default_ip() {
    # Best-effort primary IP of the local node
    ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1
}
