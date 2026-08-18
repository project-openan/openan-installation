# OpenAN One-Click Deployment & Uninstallation Script Guide

This script deploys the full OpenAN stack on a Linux server in one command, including registry-center, orchestration-center backend and frontend, agents example server, and an Nginx HTTPS reverse proxy. The following guide provides a solution of deploying projects on vps and access the frontend on local machine，and, currently, we do not provide any solution in other way. When deployed on a VPS, the script auto-detects the VPS IP and displays remote access URLs (`https://[ip-of-vps]`) in the summary output, accessible directly from a local browser.

---

### Table of Contents

- [Prerequisites](#prerequisites)
- [From Clone to Running](#from-clone-to-running)
- [Script Execution Flow](#script-execution-flow)
- [Interactive Prompts](#interactive-prompts)
- [Service Ports and URLs](#service-ports-and-urls)
- [Log File Locations](#log-file-locations)
- [Stopping Services](#stopping-services)
- [Uninstalling OpenAN](#uninstalling-openan)

---

### Prerequisites

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| OS | Linux (x86_64 / aarch64) | Supports Debian/Ubuntu, CentOS/RHEL/Rocky/Alma/openEuler |
| Python | 3.12+ | Auto-detected; script will attempt to install |
| Node.js | 20.19+ | Auto-detected; script will attempt to install |
| npm | Bundled with Node.js | — |
| curl | Any | Pre-installed |
| tar | Any | Pre-installed |
| Network | Required | Needs GitHub access to download component releases |

> If Python 3.12+, Node.js 20.19+, or nginx is not installed, the script will attempt to install them via the system package manager or prebuilt binaries. This may require **sudo privileges**.

---

### From Clone to Running

#### 1. Clone the repository

```bash
git clone https://github.com/project-openan/openan-installation.git
cd openan-installation/binary/one-click
```

#### 2. Grant execute permission (if needed)

```bash
chmod +x openan_install.sh openan_uninstall.sh configure_llm.sh
```

#### 3. Run the script

```bash
./openan_install.sh
```

The script handles all downloads, configuration, and service startup automatically. There are a few interactive prompts during execution (see below); everything else is fully automated.

#### 4. Choose installation mode (optional)

The script uses `--reg` and `--orc` flags to select installation targets, consistent with `configure_llm.sh`'s flag design:

| Flag | Description |
|------|-------------|
| `--reg` | Install registry-center |
| `--orc` | Install orchestration-center |
| (neither specified) | Default: install both (equivalent to `--reg --orc`) |
| `--sample` | Start agents examples server (port 8080, off by default) |
| `-h` / `--help` | Show help and exit |

```bash
# Examples
./openan_install.sh                    # Install everything (default: --reg --orc)
./openan_install.sh --reg               # Install only registry-center
./openan_install.sh --orc               # Install only orchestration-center
./openan_install.sh --reg --orc --sample # Install everything and start sample agents
./openan_install.sh --help              # Show help
```

> In `--orc` mode (without `--reg`), the script prompts for the URL of the running registry-center (default `https://127.0.0.1:5000`). The URL is written as-is to `server.conf` and the `AGENT_REGISTRY_URL` environment variable — no `https→http` conversion.

**Step comparison by mode:**

| Step | `--reg --orc` | `--reg` | `--orc` |
|------|---------------|---------|---------|
| Python 3.12+ check | ✅ | ✅ | ✅ |
| Node.js / npm check & install | ✅ | ❌ Skipped | ✅ |
| Nginx check & install | ✅ | ❌ Skipped | ✅ |
| Download registry-center | ✅ | ✅ | ❌ Skipped |
| Download orchestration-center | ✅ | ❌ Skipped | ✅ |
| Configure registry-center | ✅ | ✅ | ❌ Skipped |
| Configure orchestration-center | ✅ | ❌ Skipped | ✅ |
| LLM configuration | ✅ Both | ✅ Registry only | ✅ Orchestration only |
| Prompt for registry URL | ❌ Auto-fix | ❌ Not needed | ✅ Interactive input |
| Nginx configuration | ✅ | ❌ Skipped | ✅ /registry/ → user URL |
| Start registry-center | ✅ | ✅ | ❌ |
| Start orchestration backend | ✅ | ❌ | ✅ |
| Start orchestration frontend | ✅ | ❌ | ✅ |
| Start agents server | ⬜ Optional | ❌ | ⬜ Optional |
| Start Nginx | ✅ | ❌ | ✅ |

#### 5. Uninstall (optional)

To completely uninstall OpenAN (stop all processes, clean nginx configuration, remove project directories), use the uninstall script:

```bash
./openan_uninstall.sh           # Interactive confirmation
./openan_uninstall.sh --force   # Skip confirmation (for automation)
```

> The uninstall script **preserves environment tools** (Python, Node.js, npm, nginx) for faster reinstallation. See [Uninstalling OpenAN](#uninstalling-openan) for details.

---

### Script Execution Flow

#### Step 0: Environment Check

- **Python 3.12+**: Tries `python3.12` → `python3` in order. If neither exists, auto-detects the distribution and attempts:
  - Debian/Ubuntu: `apt-get install python3.12` (with deadsnakes PPA fallback)
  - CentOS/RHEL/Rocky/Alma/openEuler: `dnf/yum install python3.12` (with module enable fallback)
  - Final fallback: Download standalone Python from [python-build-standalone](https://github.com/indygreg/python-build-standalone)
- **Node.js 20.19+**: Tries existing `node` command. If not found or version insufficient, auto-detects the distribution and attempts:
  - Debian/Ubuntu: `apt-get install nodejs npm` (with NodeSource setup_20.x fallback)
  - CentOS/RHEL/Rocky/Alma/openEuler: `dnf/yum install nodejs npm` (with NodeSource setup_20.x fallback)
  - Final fallback: Download prebuilt binary from [nodejs.org](https://nodejs.org/dist/) (v20.19.0, includes npm, installed to local `.node` directory)
- **npm**: Verified alongside Node.js; if Node.js exists but npm is missing, attempts to install npm via package manager
- **curl / tar**: Checks availability

#### Step 0.5: Check Nginx

- If `nginx` or `openssl` is not installed, auto-installs via package manager (apt / dnf / yum)
- Requires sudo privileges

#### Step 1: Download Component Source

Downloads and extracts from GitHub Release (using `curl` + `tar`, no `git clone` dependency):

| Component | Download URL | Version |
|-----------|-------------|---------|
| registry-center | `https://github.com/project-openan/registry-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |
| orchestration-center | `https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |

> If the directory already exists and is non-empty, the download is skipped.

#### Step 2: Configure registry-center

1. Create a Python virtual environment (venv)
2. Install Python dependencies (`pip install -r requirements.txt`)
3. Generate self-signed certificate (RSA, serverAuth, password `Dev@12345`)
4. Prepare SSL directory (`etc/ssl/`), copy certificates and set 0600 permissions
5. Fix `jwk_private_key_path` in `server.conf`
6. Run `python -m agent_registry.init` initialization (automated input with defaults, no user interaction needed)

#### Step 3: Configure orchestration-center

1. Create a Python virtual environment (venv)
2. Install backend Python dependencies
3. Enter `workflow-designer/` directory, run `npm install --force` to install frontend dependencies

#### Step 3.5: Configure LLM and Registry URL

**This step involves user interaction. See [Interactive Prompts](#interactive-prompts).**

- Option to skip LLM configuration
- Delegates to `configure_llm.sh` for interactive input, validation, and writing (in `--reg --orc` mode, configures registry and orchestration separately with a reuse option)
- Automatic LLM connectivity validation (per-project, sends a test request)
- Allows re-entry or skipping on validation failure
- Writes configuration to `llm_config.json` (mode-dependent: `--reg --orc` configures both, `--reg` writes registry-center only, `--orc` writes orchestration-center only)
- Regardless of whether skipped, the script always prints `configure_llm.sh` usage at the end of Step 3.5 for users to reconfigure LLM at any time (use `--reg`/`--orc` to target specific projects)
- `--reg --orc` mode: Fixes `agent_registry_url` in `server.conf` from `https://` to `http://` (avoids SSL version mismatch errors)
- `--orc` (without `--reg`) mode: Interactively prompts for the running registry-center URL, written as-is to `server.conf` and environment variable

#### Step 3.7: Configure Nginx HTTPS Reverse Proxy

1. Generate self-signed SSL certificate (`/etc/nginx/ssl/cert.pem`, `key.pem`, valid for 365 days)
2. Generate Nginx configuration and deploy to `/etc/nginx/conf.d/openan.conf`
3. Remove Debian/Ubuntu default site config (avoids port conflicts)
4. Test Nginx configuration validity

#### Step 4: Start All Services

Starts the following 4 services in order. Each service's port is automatically freed before startup:

| Service | Port | Start Method |
|---------|------|-------------|
| registry-center | 5000 | `python -m agent_registry.start` |
| orchestration-center backend | 5001 | `python -m orchestrate.start` |
| agents example server | 8080 | `python -m samples.start_agents_server` |
| Nginx HTTPS proxy | 443 | `systemctl start nginx` or `nginx` |

> The frontend is built as static assets via `npm run build` during installation and served directly by nginx, not as a separate process (see ADR-014).

---

### Interactive Prompts

During execution, the script may present the following interactive prompts. Except for LLM configuration, all are sudo password prompts or automated.

#### 1. sudo Password Prompt (may appear multiple times)

```
[sudo] password for <username>:
```

**When**: When the script needs to install Python, Node.js, npm, nginx, openssl, or modify `/etc/nginx/` directory.

**What to do**: Enter your sudo password. If running as root, this prompt will not appear.

---

#### 2. Skip LLM Configuration

```
Skip LLM configuration and configure manually? [y/N]:
```

**What**: Choose whether to skip the LLM configuration step. If skipped, the script will not ask for model name, API URL, or API Key, and will not modify `llm_config.json`. If not skipped, `configure_llm.sh` handles the interactive configuration: in `--reg --orc` mode, it configures registry first, then prompts whether to use the same config for orchestration.

**Default**: `N` (do not skip, enter interactive configuration)

**What to do**:
- Press Enter (or type `n`) to enter the interactive LLM configuration flow
- Type `y` to skip LLM configuration and use defaults

> Regardless of whether you skip, the script always prints `configure_llm.sh` usage at the end of Step 3.5 for you to reconfigure the LLM at any time:

```bash
# Reconfigure LLM (run from the script directory):
./configure_llm.sh --model <model-name> --url <url> --api-key <your-api-key>

# Or pass API key via env var (avoids key in shell history):
LLM_API_KEY=<your-api-key> ./configure_llm.sh --model <model-name> --url <url>

# Interactive mode (configure registry and orchestration separately, with reuse option):
./configure_llm.sh --reg --orc

# Update only a specific project (default: both):
./configure_llm.sh --reg --api-key <your-api-key>
./configure_llm.sh --orc --api-key <your-api-key
>
# Show full help:
./configure_llm.sh --help
```

> **`--reg`/`--orc` flags**: The install script and `configure_llm.sh` use the same flags. If the specified project is not installed (`llm_config.json` missing), the script detects this before asking for config and skips it with a warning. If neither project is installed, the script exits with an error.
>
> If you skipped interactive configuration, LLM-related features will use defaults and may not work correctly. Please run `configure_llm.sh` to configure before starting services.

---

> **Split-asking flow in `--reg --orc` mode**: `configure_llm.sh` first asks for registry's LLM config (prompts 3-5 below), then after validation prompts "Use same LLM config for orchestration? [Y/n]". Choose Y to reuse all registry config values; choose n to enter orchestration config separately. When only `--reg` or `--orc` is specified, only one project is configured.

#### 3. LLM Model Name

```
Enter LLM model name:
```

**What**: Specifies the LLM chat model name. The script uses this name to call the LLM API.

**Default**: None (must be entered)

**What to do**: Type your model name.

---

#### 4. LLM API URL

```
Enter LLM API URL:
```

**What**: The LLM service API endpoint (OpenAI-compatible format). The script automatically appends `/chat/completions` if not already present.

**Default**: None (must be entered)

**What to do**: Type your API URL.

---

#### 5. LLM API Key

```
Enter your API key:
```

**What**: The API key for calling the LLM API, used for authentication.

**Default**: None (must be entered)

**What to do**: Enter the API key obtained from your LLM provider. If left empty, validation is skipped and you'll be prompted to edit `llm_config.json` manually.

> The key is masked in output (only first 4 and last 4 characters shown).

---

#### 6. Retry Prompt After LLM Validation Failure

When API Key / URL / model validation fails, the script re-prompts for all three:

```
[RETRY] Please re-enter LLM configuration.
        (Type 'skip' at any prompt to bypass validation)

Model [current model]:
API URL [current URL]:
API key [***]:
```

**What to do**:
- Correct the erroneous value and press Enter
- Type `skip` at any prompt to bypass validation (configuration may be incorrect; edit `llm_config.json` manually later)
- Press Enter to keep the current value unchanged

---

#### 7. Registry Center URL (--orc mode only, without --reg)

```
Enter registry center URL [https://127.0.0.1:5000]:
```

**What**: In `--orc` mode (without `--reg`), the orchestration-center needs to connect to a running registry-center. The script prompts you for its URL.

**Default**: `https://127.0.0.1:5000`

**What to do**:
- Press Enter for the default (for a locally running registry-center)
- Enter the actual URL of a remote registry-center (e.g., `https://10.0.0.5:5000`)

> The URL is written as-is to `agent_registry_url` in `server.conf` and the `AGENT_REGISTRY_URL` environment variable — no `https→http` conversion. Ensure the URL matches the registry-center's actual running mode (HTTP or HTTPS).
>
> The Nginx `/registry/` location block also proxies to this URL.

---

### Service Ports and URLs

After deployment, services are accessible at the following addresses:

| Service | Local Access (HTTP) | Remote Access (HTTPS, via Nginx proxy) |
|---------|---------------------|---------------------------------------|
| registry-center | http://127.0.0.1:5000 | https://[ip-of-vps]/registry/ |
| orchestration backend | http://127.0.0.1:5001 | https://[ip-of-vps]/api/orchestrate/ |
| Frontend (static files) | — | https://[ip-of-vps]/ |
| agents example server | http://127.0.0.1:8080 | — |
| Nginx HTTPS entry | — | https://[ip-of-vps] |

> **VPS remote access**: When the script runs on a VPS, the Summary output auto-detects the VPS network IP (via `hostname -I`) and displays remote access URLs in the form `https://[ip-of-vps]`. Replace `[ip-of-vps]` with your actual VPS IP address (e.g., `https://203.0.113.50`).
>
> All backend services bind to `127.0.0.1` and cannot be accessed externally. **Nginx is the sole remote entry point** (listening on `0.0.0.0:443`), proxying to services via path prefixes: `/` → frontend, `/api/orchestrate/` → backend, `/registry/` → registry-center. The agents example server has no nginx proxy and is not remotely accessible.
>
> Nginx uses a self-signed certificate. Browsers will show a security warning; choose "Proceed" to continue.

---

### Log File Locations

| Service | Log Path |
|---------|----------|
| registry-center | `registry-center/registry-center.log` |
| orchestration backend | `orchestration-center/backend.log` |
| orchestration frontend | `orchestration-center/frontend.log` |
| agents example server | `orchestration-center/agents-server.log` |

> Log files are relative to the script directory (i.e., `binary/one-click/`).

---

### Stopping Services

The script dynamically outputs the PIDs and stop command for services that were actually started (only lists started services). To stop:

```bash
# Stop Python and Node.js services
kill <REGISTRY_PID> <BACKEND_PID> <FRONTEND_PID> <AGENTS_PID>

# Stop Nginx
sudo systemctl stop nginx
# or
sudo nginx -s stop
```

> Replace `<PID>` with the actual PIDs output at the end of the script.

---

### Uninstalling OpenAN

To completely uninstall OpenAN projects (remove project directories, stop all processes,
and clean nginx configuration), use the `openan_uninstall.sh` script.
**Environment tools (Python, Node.js, npm, nginx) are preserved** for faster reinstallation.

#### Usage

```bash
./openan_uninstall.sh           # Interactive confirmation
./openan_uninstall.sh --force   # Skip confirmation (for automation)
```

#### What Gets Removed

| Step | Action | Description |
|------|--------|-------------|
| Step 1 | Kill processes | Find and kill OpenAN processes by port (5000/5001/8080/8899-8907/26335/26336), with smart identification to avoid killing non-OpenAN processes |
| Step 2 | Stop nginx | Three-level fallback: `systemctl stop` → `nginx -s stop` → `pkill nginx` |
| Step 3 | Remove nginx config | Delete `/etc/nginx/conf.d/openan.conf`, `/etc/nginx/ssl/` certificates, local `openan-nginx.conf` |
| Step 4 | Remove project dirs | Delete `registry-center/` and `orchestration-center/` |

#### What Gets Preserved

The following are **not deleted**, for faster reinstallation:

- Python 3.12+ (system-installed or `.python3.12/` directory)
- Node.js 20.19+ (system-installed or `.node/` directory)
- npm
- nginx binary and system package
- openssl
- `configure_llm.sh` (part of the deployment repo)

#### Interactive Confirmation

When running `./openan_uninstall.sh`, the script first scans the system and lists all
planned actions:

```
==========================================
 OpenAN Uninstallation Plan
==========================================

Processes to kill:
  kill PID 12345 (port 5000, registry-center)
  kill PID 12346 (port 5001, orchestration backend)
  ...

Nginx to stop/clean:
  stop nginx process (port 443)
  delete /etc/nginx/conf.d/openan.conf
  delete /etc/nginx/ssl/cert.pem, key.pem
  ...

Directories to delete:
  delete /path/to/registry-center/
  delete /path/to/orchestration-center/

Environment tools (Python, Node.js, npm, nginx) will be PRESERVED.

Proceed with uninstallation? [y/N]:
```

Type `y` to confirm, or any other input / Enter to cancel. Use `--force` to skip this confirmation.
