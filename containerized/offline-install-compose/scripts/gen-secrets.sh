#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
# Prepare the private runtime files (registry.env, orchestration.env,
# models.yaml, integration_credentials.conf) from a single command.
#
#   scripts/gen-secrets.sh --interactive   # masked prompts
#   scripts/gen-secrets.sh --eval          # random keys, zero prompts (HTTP evaluation)
#   scripts/gen-secrets.sh --help
#
# --interactive asks for: LLM model/URL/API key, admin password, DB passwords.
# --eval generates random values for every secret; only LLM model/URL need
# manual editing in models.yaml afterwards (or use LLM_* env vars).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:---help}"

log()  { echo "[gen-secrets] $1"; }
warn() { echo "[gen-secrets][WARN] $1" >&2; }
die()  { echo "[gen-secrets][ERROR] $1" >&2; exit 1; }

rand() { openssl rand -hex 24; }

# Generate a password that meets the OC policy (8+ lower/upper/digit/special)
gen_password() {
    openssl rand -base64 18 | tr -d '/+=' | head -c 16 | cat <(echo -n 'A1a!') - | head -c 20
}

# Read a secret with masked input; falls back to random if empty in --eval
read_secret() {
    local prompt="$1" var="$2"
    read -rsp "$prompt: " "$var" 2>/dev/null < /dev/tty || true
    echo "" >&2
}

# Read a non-secret value; supports env-var preseed and default
read_value() {
    local prompt="$1" var="$2" default="${3:-}"
    local current="${!var:-}"
    if [ -n "$current" ]; then
        printf '%s\n' "$current"
        return
    fi
    if [ -n "$default" ]; then
        read -rp "$prompt [$default]: " "$var" < /dev/tty || true
        echo "${!var:-$default}"
    else
        read -rp "$prompt: " "$var" < /dev/tty || true
        echo "${!var:-}"
    fi
}

# --- Compute HMAC-SHA256 digest ---
hmac_digest() {
    local key="$1" token="$2"
    printf '%s' "$token" | openssl dgst -sha256 -hmac "$key" | awk '{print $NF}'
}

# Fill in a key in an env file if it's missing or empty (never overwrites non-empty)
fill_env_key() {
    local file="$1" key="$2" value="$3"
    local current
    current="$(grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-)"
    if [ -n "$current" ]; then
        return 0  # already set
    fi
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        # Key exists but is empty — fill it
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        # Key doesn't exist — append it
        echo "${key}=${value}" >> "$file"
    fi
    chmod 0600 "$file"
    log "  Filled: $key"
}

case "$MODE" in
--interactive|--eval)
    ;;
--help|-h|*)
    cat <<'EOF'
Usage: scripts/gen-secrets.sh --interactive | --eval

  --interactive  Prompt for LLM model/URL/API key, admin password, DB
                 passwords (masked input). Auto-generates HMAC keys,
                 fingerprint, access token, and the credential file.
  --eval         Zero prompts. Generates random values for every secret.
                 Edit models.yaml to set your LLM model/URL afterwards.

Both modes produce (never overwriting existing files):
  registry.env, orchestration.env,
  registry-models.yaml, orchestration-models.yaml,
  integration_credentials.conf

Combine with tool/gen-certs.sh to generate the ./pki/ TLS tree.
EOF
    exit 0
    ;;
esac

log "Mode: $MODE"
log "Bundle: $BUNDLE"

# --- LLM configuration ---
LLM_CHAT_MODEL="${LLM_CHAT_MODEL:-}"
LLM_CHAT_URL="${LLM_CHAT_URL:-}"
LLM_CHAT_API_KEY="${LLM_CHAT_API_KEY:-}"
OC_ADMIN_INITIAL_PASSWORD="${OC_ADMIN_INITIAL_PASSWORD:-}"
REGISTRY_DB_PASSWORD="${REGISTRY_DB_PASSWORD:-}"
ORCH_DB_PASSWORD="${ORCH_DB_PASSWORD:-}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"

if [ "$MODE" = "--interactive" ]; then
    [ -t 0 ] || die "--interactive requires a terminal"
    LLM_CHAT_MODEL="$(read_value 'LLM chat model id' LLM_CHAT_MODEL)"
    LLM_CHAT_URL="$(read_value 'LLM chat URL' LLM_CHAT_URL)"
    if [ -n "$LLM_CHAT_URL" ]; then
        read_secret 'LLM chat API key' LLM_CHAT_API_KEY_VAR
        LLM_CHAT_API_KEY="$LLM_CHAT_API_KEY_VAR"
    fi
    read_secret 'Admin password (8+ lower/upper/digit/special)' ADMIN_VAR
    OC_ADMIN_INITIAL_PASSWORD="$ADMIN_VAR"
    read_secret 'Database password (shared by app users)' DB_VAR
    REGISTRY_DB_PASSWORD="$DB_VAR"
    ORCH_DB_PASSWORD="$DB_VAR"
    MYSQL_ROOT_PASSWORD="$DB_VAR"
fi

# --- Auto-generate missing secrets ---
[ -z "$OC_ADMIN_INITIAL_PASSWORD" ] && OC_ADMIN_INITIAL_PASSWORD="$(gen_password)" && \
    warn "Admin password auto-generated (check orchestration.env)"
[ -z "$REGISTRY_DB_PASSWORD" ] && REGISTRY_DB_PASSWORD="$(gen_password)"
[ -z "$ORCH_DB_PASSWORD" ] && ORCH_DB_PASSWORD="$REGISTRY_DB_PASSWORD"
[ -z "$MYSQL_ROOT_PASSWORD" ] && MYSQL_ROOT_PASSWORD="$REGISTRY_DB_PASSWORD"

INTEGRATION_FINGERPRINT_KEY="$(rand)"
INTEGRATION_TOKEN_HMAC_KEY="$(rand)"
REGISTRY_ACCESS_TOKEN="$(rand)"
LLM_CHAT_API_KEY="${LLM_CHAT_API_KEY:-$(rand)}"

# --- Write registry.env (fill in missing keys, never overwrite existing values) ---
REG_ENV="$BUNDLE/registry.env"
if [ ! -f "$REG_ENV" ]; then
    printf 'INTEGRATION_FINGERPRINT_KEY=%s\nINTEGRATION_TOKEN_HMAC_KEY=%s\nLLM_CHAT_API_KEY=%s\n' \
        "$INTEGRATION_FINGERPRINT_KEY" "$INTEGRATION_TOKEN_HMAC_KEY" "$LLM_CHAT_API_KEY" > "$REG_ENV"
    chmod 0600 "$REG_ENV"
    log "Created: registry.env"
else
    # Fill in any empty/missing required keys
    fill_env_key "$REG_ENV" "INTEGRATION_FINGERPRINT_KEY" "$INTEGRATION_FINGERPRINT_KEY"
    fill_env_key "$REG_ENV" "INTEGRATION_TOKEN_HMAC_KEY" "$INTEGRATION_TOKEN_HMAC_KEY"
    fill_env_key "$REG_ENV" "LLM_CHAT_API_KEY" "$LLM_CHAT_API_KEY"
    log "Filled missing keys in existing registry.env"
fi

# --- Write orchestration.env (fill in missing keys) ---
OC_ENV="$BUNDLE/orchestration.env"
if [ ! -f "$OC_ENV" ]; then
    printf 'OC_ADMIN_INITIAL_PASSWORD=%s\nREGISTRY_ACCESS_TOKEN=%s\nLLM_CHAT_API_KEY=%s\nRETRIEVAL_VECTOR_ENABLED=false\n' \
        "$OC_ADMIN_INITIAL_PASSWORD" "$REGISTRY_ACCESS_TOKEN" "$LLM_CHAT_API_KEY" > "$OC_ENV"
    chmod 0600 "$OC_ENV"
    log "Created: orchestration.env"
else
    fill_env_key "$OC_ENV" "OC_ADMIN_INITIAL_PASSWORD" "$OC_ADMIN_INITIAL_PASSWORD"
    fill_env_key "$OC_ENV" "REGISTRY_ACCESS_TOKEN" "$REGISTRY_ACCESS_TOKEN"
    fill_env_key "$OC_ENV" "LLM_CHAT_API_KEY" "$LLM_CHAT_API_KEY"
    log "Filled missing keys in existing orchestration.env"
fi

# --- Compute and write integration_credentials.conf ---
CRED="$BUNDLE/integration_credentials.conf"
if [ ! -f "$CRED" ] || ! grep -q 'token_hash=' "$CRED" 2>/dev/null || \
   grep -q '^credential\..*\.token_hash=$' "$CRED" 2>/dev/null; then
    # Read from the env files (they now have values after fill_env_key)
    HMAC_KEY="$(grep '^INTEGRATION_TOKEN_HMAC_KEY=' "$REG_ENV" 2>/dev/null | cut -d= -f2-)"
    TOKEN="$(grep '^REGISTRY_ACCESS_TOKEN=' "$OC_ENV" 2>/dev/null | cut -d= -f2-)"
    if [ -z "$HMAC_KEY" ] || [ -z "$TOKEN" ]; then
        die "Cannot read HMAC key or token from env files (this is a bug)"
    fi
    DIGEST="$(hmac_digest "$HMAC_KEY" "$TOKEN")"
    cat > "$CRED" <<EOF
credential.orchestration.identity=orchestration-service
credential.orchestration.token_hash=$DIGEST
credential.orchestration.role=partner_service
credential.orchestration.enabled=true
EOF
    chmod 0600 "$CRED"
    log "Created: integration_credentials.conf (HMAC pairing computed)"
else
    log "integration_credentials.conf exists with token_hash, skipping"
fi

# --- Write models.yaml (only if using our env files) ---
for svc in registry orchestration; do
    MODELS_FILE="$BUNDLE/${svc}-models.yaml"
    if [ -f "$MODELS_FILE" ]; then
        log "${svc}-models.yaml exists, skipping"
        continue
    fi
    cat > "$MODELS_FILE" <<EOF
models:
  chat:
    provider: openai_compatible
    model: ${LLM_CHAT_MODEL:-your-chat-model}
    url: ${LLM_CHAT_URL:-https://your-llm-provider.com/v1/chat/completions}
    api_key_env: LLM_CHAT_API_KEY
EOF
    chmod 0600 "$MODELS_FILE"
    log "Created: ${svc}-models.yaml"
done

# --- Append DB passwords to config.env if not already there ---
CONFIG="$BUNDLE_DIR/config.env"
if [ -f "$CONFIG" ]; then
    for pair in "REGISTRY_DB_PASSWORD=$REGISTRY_DB_PASSWORD" \
                "ORCH_DB_PASSWORD=$ORCH_DB_PASSWORD" \
                "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD"; do
        key="${pair%%=*}"
        val="${pair#*=}"
        if grep -q "^${key}=" "$CONFIG" && [ -n "$(grep "^${key}=" "$CONFIG" | cut -d= -f2-)" ]; then
            log "$key already set in config.env"
        elif grep -q "^${key}=" "$CONFIG"; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$CONFIG"
            log "Filled $key in config.env"
        else
            echo "${key}=${val}" >> "$CONFIG"
            log "Set $key in config.env"
        fi
    done
    # Disable signing if the directory doesn't exist
    if grep -q '^REGISTRY_SIGN_ENABLED=true' "$CONFIG"; then
        SIGN_DIR="$(grep '^REGISTRY_SIGN_DIR=' "$CONFIG" | cut -d= -f2-)"
        if [ -n "$SIGN_DIR" ] && [ ! -d "$BUNDLE_DIR/$SIGN_DIR" ] && [ ! -d "$SIGN_DIR" ]; then
            sed -i 's|^REGISTRY_SIGN_ENABLED=.*|REGISTRY_SIGN_ENABLED=false|' "$CONFIG"
            warn "REGISTRY_SIGN_ENABLED disabled: signing directory not found"
        fi
    fi
    chmod 0600 "$CONFIG"
fi

log ""
log "Private files prepared. Next steps:"
echo "  1. Review/edit the generated files (especially models.yaml for your LLM)"
echo "  2. For HTTPS: bash tool/gen-certs.sh"
echo "  3. Run: sudo scripts/check-env.sh --config config.env"
echo "  4. Run: sudo scripts/install.sh --config config.env"
