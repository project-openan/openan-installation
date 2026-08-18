#!/bin/bash
# =============================================================================
# Standalone LLM configuration script
# Updates model, url, and api_key in llm_config.json for registry-center
# and/or orchestration-center.
#
# Supports two modes:
# - Interactive: auto-triggered when any of --model/--url/--api-key is missing.
#   For --reg --orc, configures registry first, then offers to reuse the same
#   config for orchestration.
# - Non-interactive: all parameters provided via flags, same values written
#   to all target projects.
#
# Usage: ./configure_llm.sh --reg --orc --model <name> --url <url> --api-key <key>
#        ./configure_llm.sh --reg --orc          # interactive mode
#        ./configure_llm.sh --reg                # interactive, registry only
# =============================================================================
set -euo pipefail

# =============================================================================
# Constants
# =============================================================================
# No third-party defaults — users must provide their own model and URL.
DEFAULT_LLM_MODEL=""
DEFAULT_LLM_URL=""

# =============================================================================
# Argument parsing
# =============================================================================
DO_REGISTRY=false
DO_ORCHESTRATION=false
LLM_MODEL_FLAG=""
LLM_URL_FLAG=""
API_KEY_FLAG=""
VALIDATE=true

print_usage() {
    cat << 'USAGE_EOF'
Usage: configure_llm.sh [OPTIONS]

Update LLM configuration (model, url, api_key) in llm_config.json.
Supports interactive mode (auto-triggered when parameters are missing) and
non-interactive mode (all parameters provided via flags).

Options:
  --reg                Configure registry-center
  --orc                Configure orchestration-center
                       (default: both --reg --orc if neither specified)
  --model <name>       LLM model name
  --url <url>          LLM API URL
  --api-key <key>      API key (or set LLM_API_KEY env var)
  --validate           Validate API connection before writing (default)
  --no-validate        Skip validation
  -h, --help           Show this help message and exit

Interactive mode:
  When any of --model, --url, --api-key is missing, the script enters
  interactive mode. If both --reg and --orc are specified, registry is
  configured first, then the user is offered to reuse the same config
  for orchestration.

Examples:
  # Non-interactive (same config for both projects):
  ./configure_llm.sh --model <model-name> --url <api-url> --api-key your-key

  # Interactive (configure both projects separately):
  ./configure_llm.sh --reg --orc

  # Interactive (configure only registry):
  ./configure_llm.sh --reg

  # Non-interactive (only orchestration):
  ./configure_llm.sh --orc --model <model-name> --url <api-url> --api-key your-key

  # API key via env var (avoids key in shell history):
  LLM_API_KEY=your-key ./configure_llm.sh --model <model-name> --url <api-url>
USAGE_EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --reg)
            DO_REGISTRY=true
            shift
            ;;
        --orc)
            DO_ORCHESTRATION=true
            shift
            ;;
        --model)
            LLM_MODEL_FLAG="$2"
            shift 2
            ;;
        --url)
            LLM_URL_FLAG="$2"
            shift 2
            ;;
        --api-key)
            API_KEY_FLAG="$2"
            shift 2
            ;;
        --validate)
            VALIDATE=true
            shift
            ;;
        --no-validate)
            VALIDATE=false
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        --project)
            echo "[ERROR] --project has been removed. Use --reg and/or --orc instead."
            echo "        See: ./configure_llm.sh --help"
            exit 1
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Default: if neither --reg nor --orc, do both
if [ "${DO_REGISTRY}" = "false" ] && [ "${DO_ORCHESTRATION}" = "false" ]; then
    DO_REGISTRY=true
    DO_ORCHESTRATION=true
fi

# Resolve API key: --api-key flag takes priority over LLM_API_KEY env var.
# Note: Do NOT initialize LLM_API_KEY at the top of the script, as that would
# shadow the inherited environment variable. API_KEY_FLAG is used for the
# --api-key flag value, and LLM_API_KEY is read from the environment with
# ${LLM_API_KEY:-} to safely handle the case where it is not set.
if [ -n "${API_KEY_FLAG}" ]; then
    LLM_API_KEY="${API_KEY_FLAG}"
else
    LLM_API_KEY="${LLM_API_KEY:-}"
fi

# Determine if interactive mode is needed.
# Interactive if any of model/url/api-key is not provided (flag or env var).
API_KEY_AVAILABLE=false
if [ -n "${API_KEY_FLAG}" ] || [ -n "${LLM_API_KEY:-}" ]; then
    API_KEY_AVAILABLE=true
fi

INTERACTIVE=false
if [ -z "${LLM_MODEL_FLAG}" ] || [ -z "${LLM_URL_FLAG}" ] || [ "${API_KEY_AVAILABLE}" = "false" ]; then
    INTERACTIVE=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Step 0: Pre-check target config files
# For each requested project, verify llm_config.json exists before asking
# the user for input or validating. Projects whose files are missing (not
# installed) are skipped. If neither file exists, exit early.
# =============================================================================
REG_CONFIG="${SCRIPT_DIR}/registry-center/common/config/llm_config.json"
ORC_CONFIG="${SCRIPT_DIR}/orchestration-center/common/config/llm_config.json"

if [ "${DO_REGISTRY}" = "true" ] && [ ! -f "${REG_CONFIG}" ]; then
    echo "[WARN] ${REG_CONFIG} not found, skipping."
    echo "       (Is the corresponding project installed?)"
    DO_REGISTRY=false
fi

if [ "${DO_ORCHESTRATION}" = "true" ] && [ ! -f "${ORC_CONFIG}" ]; then
    echo "[WARN] ${ORC_CONFIG} not found, skipping."
    echo "       (Is the corresponding project installed?)"
    DO_ORCHESTRATION=false
fi

if [ "${DO_REGISTRY}" = "false" ] && [ "${DO_ORCHESTRATION}" = "false" ]; then
    echo ""
    echo "[ERROR] No target llm_config.json files found."
    echo "        Neither registry-center nor orchestration-center appears to be installed."
    echo "        Please install the projects first, then run configure_llm.sh again."
    exit 1
fi

# =============================================================================
# Function: read_masked — read user input with asterisk masking.
# Usage: read_masked "Prompt: " VAR_NAME
# Reads from /dev/tty, echoes '*' for each character typed.
# Supports backspace. Press Enter to submit.
# =============================================================================
read_masked() {
    local prompt="$1"
    local var_name="$2"
    local char value=""

    printf '%s' "${prompt}"
    while IFS= read -rs -n1 char 2>/dev/null; do
        # Enter / newline — end input
        if [[ -z "${char}" ]]; then
            break
        fi
        # Backspace (ASCII 0x7F) or Ctrl-H (0x08)
        if [[ "${char}" == $'\177' || "${char}" == $'\010' ]]; then
            if [[ -n "${value}" ]]; then
                value="${value%?}"
                printf '\b \b'
            fi
            continue
        fi
        value+="${char}"
        printf '*'
    done < /dev/tty
    printf '\n'
    printf -v "${var_name}" '%s' "${value}"
}

# =============================================================================
# Function: validate LLM API key and URL by sending a minimal test request.
# Returns 0 if valid, 1 otherwise.
# =============================================================================
validate_llm() {
    local model="$1"
    local url="$2"
    local api_key="$3"

    # Construct the chat completions endpoint.
    # If the URL doesn't already end with /chat/completions, append it.
    local test_url="${url}"
    if [[ "${test_url}" != */chat/completions ]]; then
        test_url="${test_url%/}/chat/completions"
    fi

    echo "  [TEST] Validating LLM connection..."
    echo "         URL:   ${test_url}"
    echo "         Model: ${model}"

    local tmp_resp http_code body
    tmp_resp=$(mktemp /tmp/llm-validate-XXXXXX)
    http_code=$(curl -s -o "${tmp_resp}" -w "%{http_code}" \
        -X POST "${test_url}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${api_key}" \
        -d "{\"model\": \"${model}\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}], \"max_tokens\": 1}" \
        --connect-timeout 10 \
        --max-time 30 2>/dev/null) || http_code="000"
    body=$(cat "${tmp_resp}" 2>/dev/null)
    rm -f "${tmp_resp}"

    case "${http_code}" in
        200|201)
            echo "  [OK] LLM API validation successful (HTTP ${http_code})."
            return 0
            ;;
        401|403)
            echo "  [ERROR] Authentication failed (HTTP ${http_code}) — invalid API key."
            [ -n "${body}" ] && echo "          Response: $(printf '%.300s' "${body}")"
            return 1
            ;;
        404)
            echo "  [ERROR] Endpoint not found (HTTP 404) — invalid API URL."
            echo "          Tried: ${test_url}"
            [ -n "${body}" ] && echo "          Response: $(printf '%.300s' "${body}")"
            return 1
            ;;
        000)
            echo "  [ERROR] Cannot connect to ${test_url}."
            echo "          Please check the URL and your network connection."
            return 1
            ;;
        *)
            echo "  [ERROR] Validation failed (HTTP ${http_code})."
            [ -n "${body}" ] && echo "          Response: $(printf '%.300s' "${body}")"
            return 1
            ;;
    esac
}

# =============================================================================
# Function: mask_key — produce a masked display string for an API key.
# Shows first 4 and last 4 characters; short keys show "***".
# =============================================================================
mask_key() {
    local key="$1"
    local len=${#key}
    if [ "${len}" -gt 8 ]; then
        echo "${key:0:4}...${key: -4}"
    else
        echo "***"
    fi
}

# =============================================================================
# Function: write_config — update a single llm_config.json file.
# Args: config_path, model, url, api_key
# Returns 0 on success, 1 on failure.
# =============================================================================
write_config() {
    local config_path="$1"
    local model="$2"
    local url="$3"
    local api_key="$4"

    # Defense-in-depth: Step 0 pre-check should have already caught missing
    # files, but keep this check in case write_config is called directly.
    if [ ! -f "${config_path}" ]; then
        echo "[WARN] ${config_path} not found, skipping."
        echo "       (Is the corresponding project installed?)"
        return 1
    fi

    echo "[CONFIG] Updating ${config_path}..."

    # Use inline env vars so Python can read them safely (avoids shell
    # escaping issues with special characters in command-line arguments)
    if LLM_WRITE_MODEL="${model}" \
       LLM_WRITE_URL="${url}" \
       LLM_WRITE_API_KEY="${api_key}" \
       "${PYTHON_CMD}" -c "
import json, os, sys

config_path = sys.argv[1]
api_key = os.environ.get('LLM_WRITE_API_KEY', '')
model = os.environ.get('LLM_WRITE_MODEL', '')
url = os.environ.get('LLM_WRITE_URL', '')

try:
    with open(config_path, 'r', encoding='utf-8') as f:
        config = json.load(f)
except json.JSONDecodeError as e:
    print(f'  [ERROR] Invalid JSON in {config_path}: {e}', file=sys.stderr)
    sys.exit(1)
except FileNotFoundError:
    print(f'  [ERROR] File not found: {config_path}', file=sys.stderr)
    sys.exit(1)

if 'chat' not in config:
    print(f'  [ERROR] Missing \"chat\" key in {config_path}', file=sys.stderr)
    sys.exit(1)

config['chat']['model'] = model
config['chat']['url'] = url
if api_key:
    config['chat']['api_key'] = api_key

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write('\n')

# Report what was written for verification
written_key = config.get('chat', {}).get('api_key', '(missing)')
if written_key and len(written_key) > 8:
    display = written_key[:4] + '...' + written_key[-4:]
else:
    display = '***'
print(f'  chat.model    = {model}')
print(f'  chat.url      = {url}')
print(f'  chat.api_key  = {display}')
" "${config_path}" 2>&1; then
        echo "  [OK] Updated: ${config_path}"
        return 0
    else
        echo "  [ERROR] Failed to update ${config_path}"
        return 1
    fi
}

# =============================================================================
# Step 1: Resolve Python command
# Try venv python first, fall back to system python3.
# configure_llm.sh only uses the standard library json module, so python3
# without venv is sufficient.
# =============================================================================
PYTHON_CMD=""

# Try registry-center venv
if [ -x "${SCRIPT_DIR}/registry-center/venv/bin/python" ]; then
    PYTHON_CMD="${SCRIPT_DIR}/registry-center/venv/bin/python"
# Try orchestration-center venv
elif [ -x "${SCRIPT_DIR}/orchestration-center/venv/bin/python" ]; then
    PYTHON_CMD="${SCRIPT_DIR}/orchestration-center/venv/bin/python"
# Fall back to system python3
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_CMD="python3"
else
    echo "[ERROR] Python 3 is required but not found."
    echo "        No venv found in registry-center/ or orchestration-center/,"
    echo "        and python3 is not available in PATH."
    exit 1
fi

echo "[PYTHON] Using: ${PYTHON_CMD}"
echo ""

# =============================================================================
# Step 2: Configuration
# =============================================================================
SUCCESS_COUNT=0
FAIL_COUNT=0

if [ "${INTERACTIVE}" = "true" ]; then
    # -------------------------------------------------------------------------
    # Interactive mode
    # -------------------------------------------------------------------------
    # Per-project config variables
    REG_MODEL="" REG_URL="" REG_API_KEY=""
    ORC_MODEL="" ORC_URL="" ORC_API_KEY=""
    REG_VALID=false
    ORC_VALID=false

    # Compute default values for prompts (from flags or built-in defaults)
    DEFAULT_MODEL="${LLM_MODEL_FLAG:-${DEFAULT_LLM_MODEL}}"
    DEFAULT_URL="${LLM_URL_FLAG:-${DEFAULT_LLM_URL}}"

    # --- Registry section ---
    if [ "${DO_REGISTRY}" = "true" ]; then
        echo "[CONFIG] === Registry Center LLM Configuration ==="
        echo ""

        read -r -p "  Enter LLM model name${DEFAULT_MODEL:+ [${DEFAULT_MODEL}]}: " REG_MODEL < /dev/tty || REG_MODEL=""
        REG_MODEL="${REG_MODEL:-${DEFAULT_MODEL}}"

        read -r -p "  Enter LLM API URL${DEFAULT_URL:+ [${DEFAULT_URL}]}: " REG_URL < /dev/tty || REG_URL=""
        REG_URL="${REG_URL:-${DEFAULT_URL}}"

        if [ -n "${LLM_API_KEY}" ]; then
            read_masked "  Enter API key [***]: " REG_API_KEY
            REG_API_KEY="${REG_API_KEY:-${LLM_API_KEY}}"
        else
            read_masked "  Enter your API key: " REG_API_KEY
        fi

        # Validate with retry
        if [ "${VALIDATE}" = "true" ]; then
            while true; do
                if [ -z "${REG_API_KEY}" ]; then
                    echo "  [WARN] No API key provided. Skipping validation."
                    break
                fi
                if validate_llm "${REG_MODEL}" "${REG_URL}" "${REG_API_KEY}"; then
                    REG_VALID=true
                    break
                fi
                # Validation failed — prompt user for corrected values
                echo ""
                echo "  [RETRY] Please re-enter LLM configuration."
                echo "          (Type 'skip' at any prompt to bypass validation)"
                read -r -p "        Model [${REG_MODEL}]: " NEW_MODEL < /dev/tty || NEW_MODEL=""
                if [ "${NEW_MODEL}" = "skip" ]; then
                    echo "  [WARN] Validation skipped. The configuration may not work correctly."
                    break
                fi
                REG_MODEL="${NEW_MODEL:-${REG_MODEL}}"

                read -r -p "        API URL [${REG_URL}]: " NEW_URL < /dev/tty || NEW_URL=""
                if [ "${NEW_URL}" = "skip" ]; then
                    echo "  [WARN] Validation skipped. The configuration may not work correctly."
                    break
                fi
                REG_URL="${NEW_URL:-${REG_URL}}"

                read_masked "        API key [***]: " NEW_KEY
                if [ "${NEW_KEY}" = "skip" ]; then
                    echo "  [WARN] Validation skipped. The configuration may not work correctly."
                    break
                fi
                REG_API_KEY="${NEW_KEY:-${REG_API_KEY}}"
            done
        else
            echo "  [SKIP] Validation skipped (--no-validate)."
            REG_VALID=true
        fi

        # Display registry config
        if [ -n "${REG_API_KEY}" ]; then
            echo "  [OK] Registry config -> model=${REG_MODEL}, url=${REG_URL}, key=$(mask_key "${REG_API_KEY}")"
        else
            echo "  [WARN] No API key set for registry."
        fi
        echo ""
    fi

    # --- Orchestration section ---
    if [ "${DO_ORCHESTRATION}" = "true" ]; then
        # If registry was also configured and validation failed, ask whether to continue
        if [ "${DO_REGISTRY}" = "true" ] && [ "${REG_VALID}" = "false" ]; then
            read -r -p "  Registry validation failed. Continue to orchestration? [y/N]: " CONTINUE_ORC < /dev/tty || CONTINUE_ORC=""
            case "${CONTINUE_ORC}" in
                [yY]|[yY][eE][sS])
                    echo "  [OK] Continuing to orchestration configuration."
                    ;;
                *)
                    echo "  [SKIP] Orchestration configuration skipped."
                    DO_ORCHESTRATION=false
                    ;;
            esac
        fi

        if [ "${DO_ORCHESTRATION}" = "true" ]; then
            echo "[CONFIG] === Orchestration Center LLM Configuration ==="
            echo ""

            # Offer reuse option if registry was configured with an API key
            if [ "${DO_REGISTRY}" = "true" ] && [ -n "${REG_API_KEY}" ]; then
                read -r -p "  Use same LLM config for orchestration? [Y/n]: " REUSE_CONFIG < /dev/tty || REUSE_CONFIG=""
                case "${REUSE_CONFIG}" in
                    [nN]|[nN][oO])
                        REUSE_CONFIG=false
                        ;;
                    *)
                        REUSE_CONFIG=true
                        ;;
                esac

                if [ "${REUSE_CONFIG}" = "true" ]; then
                    ORC_MODEL="${REG_MODEL}"
                    ORC_URL="${REG_URL}"
                    ORC_API_KEY="${REG_API_KEY}"
                    echo "  [OK] Using same config: model=${ORC_MODEL}, url=${ORC_URL}, key=$(mask_key "${ORC_API_KEY}")"

                    # Validate reused config
                    if [ "${VALIDATE}" = "true" ] && [ -n "${ORC_API_KEY}" ]; then
                        if validate_llm "${ORC_MODEL}" "${ORC_URL}" "${ORC_API_KEY}"; then
                            ORC_VALID=true
                        else
                            echo "  [WARN] Validation failed for reused config."
                            echo "         Config will still be written. You may reconfigure later."
                        fi
                    else
                        ORC_VALID=true
                    fi
                fi
            fi

            # If not reusing (or registry not configured), read separately
            if [ -z "${ORC_MODEL}" ]; then
                read -r -p "  Enter LLM model name${DEFAULT_MODEL:+ [${DEFAULT_MODEL}]}: " ORC_MODEL < /dev/tty || ORC_MODEL=""
                ORC_MODEL="${ORC_MODEL:-${DEFAULT_MODEL}}"

                read -r -p "  Enter LLM API URL${DEFAULT_URL:+ [${DEFAULT_URL}]}: " ORC_URL < /dev/tty || ORC_URL=""
                ORC_URL="${ORC_URL:-${DEFAULT_URL}}"

                if [ -n "${LLM_API_KEY}" ]; then
                    read_masked "  Enter API key [***]: " ORC_API_KEY
                    ORC_API_KEY="${ORC_API_KEY:-${LLM_API_KEY}}"
                else
                    read_masked "  Enter your API key: " ORC_API_KEY
                fi

                # Validate with retry
                if [ "${VALIDATE}" = "true" ]; then
                    while true; do
                        if [ -z "${ORC_API_KEY}" ]; then
                            echo "  [WARN] No API key provided. Skipping validation."
                            break
                        fi
                        if validate_llm "${ORC_MODEL}" "${ORC_URL}" "${ORC_API_KEY}"; then
                            ORC_VALID=true
                            break
                        fi
                        # Validation failed — prompt user for corrected values
                        echo ""
                        echo "  [RETRY] Please re-enter LLM configuration."
                        echo "          (Type 'skip' at any prompt to bypass validation)"
                        read -r -p "        Model [${ORC_MODEL}]: " NEW_MODEL < /dev/tty || NEW_MODEL=""
                        if [ "${NEW_MODEL}" = "skip" ]; then
                            echo "  [WARN] Validation skipped. The configuration may not work correctly."
                            break
                        fi
                        ORC_MODEL="${NEW_MODEL:-${ORC_MODEL}}"

                        read -r -p "        API URL [${ORC_URL}]: " NEW_URL < /dev/tty || NEW_URL=""
                        if [ "${NEW_URL}" = "skip" ]; then
                            echo "  [WARN] Validation skipped. The configuration may not work correctly."
                            break
                        fi
                        ORC_URL="${NEW_URL:-${ORC_URL}}"

                        read_masked "        API key [***]: " NEW_KEY
                        if [ "${NEW_KEY}" = "skip" ]; then
                            echo "  [WARN] Validation skipped. The configuration may not work correctly."
                            break
                        fi
                        ORC_API_KEY="${NEW_KEY:-${ORC_API_KEY}}"
                    done
                else
                    echo "  [SKIP] Validation skipped (--no-validate)."
                    ORC_VALID=true
                fi
            fi

            # Display orchestration config
            if [ -n "${ORC_API_KEY}" ]; then
                echo "  [OK] Orchestration config -> model=${ORC_MODEL}, url=${ORC_URL}, key=$(mask_key "${ORC_API_KEY}")"
            else
                echo "  [WARN] No API key set for orchestration."
            fi
            echo ""
        fi
    fi

    # --- Write phase ---
    if [ "${DO_REGISTRY}" = "true" ] && [ -n "${REG_API_KEY}" ]; then
        if write_config "${REG_CONFIG}" \
            "${REG_MODEL}" "${REG_URL}" "${REG_API_KEY}"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    elif [ "${DO_REGISTRY}" = "true" ]; then
        echo "[WARN] No API key for registry-center. Skipping llm_config.json update."
        echo "       Run configure_llm.sh --reg later after obtaining an API key."
    fi

    if [ "${DO_ORCHESTRATION}" = "true" ] && [ -n "${ORC_API_KEY}" ]; then
        if write_config "${ORC_CONFIG}" \
            "${ORC_MODEL}" "${ORC_URL}" "${ORC_API_KEY}"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    elif [ "${DO_ORCHESTRATION}" = "true" ]; then
        echo "[WARN] No API key for orchestration-center. Skipping llm_config.json update."
        echo "       Run configure_llm.sh --orc later after obtaining an API key."
    fi

else
    # -------------------------------------------------------------------------
    # Non-interactive mode (all parameters provided via flags)
    # -------------------------------------------------------------------------
    LLM_MODEL="${LLM_MODEL_FLAG:-${DEFAULT_LLM_MODEL}}"
    LLM_URL="${LLM_URL_FLAG:-${DEFAULT_LLM_URL}}"

    if [ -z "${LLM_API_KEY}" ]; then
        echo "[ERROR] API key is required."
        echo "        Provide via --api-key flag or LLM_API_KEY environment variable."
        exit 1
    fi

    # Display configuration
    KEY_LEN=${#LLM_API_KEY}
    KEY_MASK=$(mask_key "${LLM_API_KEY}")

    echo "[CONFIG] LLM configuration:"
    echo "         model:    ${LLM_MODEL}"
    echo "         url:      ${LLM_URL}"
    echo "         api_key:  ${KEY_MASK} (length=${KEY_LEN})"
    if [ "${DO_REGISTRY}" = "true" ] && [ "${DO_ORCHESTRATION}" = "true" ]; then
        echo "         targets:  registry + orchestration"
    elif [ "${DO_REGISTRY}" = "true" ]; then
        echo "         targets:  registry"
    else
        echo "         targets:  orchestration"
    fi
    echo "         validate: ${VALIDATE}"
    echo ""

    # Validate LLM connection (if enabled)
    if [ "${VALIDATE}" = "true" ]; then
        if ! validate_llm "${LLM_MODEL}" "${LLM_URL}" "${LLM_API_KEY}"; then
            echo ""
            echo "[ERROR] LLM validation failed. Configuration was NOT written."
            echo "        Use --no-validate to skip validation."
            exit 1
        fi
        echo ""
    else
        echo "[SKIP] LLM validation skipped (--no-validate)."
        echo ""
    fi

    # Build target file list
    LLM_CONFIGS=()
    if [ "${DO_REGISTRY}" = "true" ]; then
        LLM_CONFIGS+=("${REG_CONFIG}")
    fi
    if [ "${DO_ORCHESTRATION}" = "true" ]; then
        LLM_CONFIGS+=("${ORC_CONFIG}")
    fi

    # Write configs (same values for all targets)
    for LLM_CONFIG in "${LLM_CONFIGS[@]}"; do
        if write_config "${LLM_CONFIG}" "${LLM_MODEL}" "${LLM_URL}" "${LLM_API_KEY}"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done
fi

# =============================================================================
# Summary
# Determine header: "skipped" when no files were written and no failures
# occurred (user provided no config in interactive mode, see ADR-013).
# =============================================================================
if [ "${SUCCESS_COUNT}" -eq 0 ] && [ "${FAIL_COUNT}" -eq 0 ]; then
    SUMMARY_HEADER="LLM configuration skipped"
else
    SUMMARY_HEADER="LLM configuration complete"
fi

echo ""
echo "=========================================="
echo " ${SUMMARY_HEADER}"
echo "=========================================="
echo "  Updated: ${SUCCESS_COUNT} file(s)"
if [ "${FAIL_COUNT}" -gt 0 ]; then
    echo "  Failed:  ${FAIL_COUNT} file(s)"
fi

if [ "${INTERACTIVE}" = "true" ]; then
    if [ "${DO_REGISTRY}" = "true" ] && [ -n "${REG_API_KEY}" ]; then
        echo "  Registry:        model=${REG_MODEL}, key=$(mask_key "${REG_API_KEY}")"
    fi
    if [ "${DO_ORCHESTRATION}" = "true" ] && [ -n "${ORC_API_KEY}" ]; then
        if [ "${DO_REGISTRY}" = "true" ] && [ "${ORC_MODEL}" = "${REG_MODEL}" ] && [ "${ORC_API_KEY}" = "${REG_API_KEY}" ]; then
            echo "  Orchestration:   (same as registry)"
        else
            echo "  Orchestration:   model=${ORC_MODEL}, key=$(mask_key "${ORC_API_KEY}")"
        fi
    fi
else
    echo "  Model:   ${LLM_MODEL}"
    echo "  URL:     ${LLM_URL}"
    echo "  API Key: ${KEY_MASK}"
fi
echo "=========================================="

if [ "${SUCCESS_COUNT}" -eq 0 ]; then
    echo ""
    if [ "${FAIL_COUNT}" -gt 0 ]; then
        echo "[ERROR] No files were updated. Please check the warnings above."
        exit 1
    else
        echo "[SKIP] LLM configuration skipped. No files were updated."
        echo "       Run configure_llm.sh later to configure."
        exit 0
    fi
fi
