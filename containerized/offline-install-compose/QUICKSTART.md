# OpenAN Offline Installation Quickstart (Docker Compose)

> **Offline-install-compose line.** Single-host offline deployment of the
> OpenAN platform via Docker Compose: one registry-center, one
> orchestration-center and one Nginx public entry. No Kubernetes, no Helm,
> no cluster — the offline host only needs Docker and Python 3.

End-to-end guide: build the offline bundle on an **internet-connected
machine**, transfer it to the **offline machine**, and install OpenAN as a
self-contained Compose stack. Nothing at install time touches the internet.

For the full configuration reference, HTTP/HTTPS/mTLS profiles and
lifecycle details see [README.md](README.md) and
[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

---

## Prerequisites

### Build machine (online)

- Linux with **Docker** (buildx enabled for multi-arch builds)
- Matching application source revisions — old `v1.0.0` images are not
  certified; see [README.md](README.md#build-on-an-internet-connected-linux-host)
  for the accepted revisions

### Offline machine

- Linux amd64/arm64 matching the bundle
- **Docker Engine with Compose v2.20+** and **Python 3.10+** (standard
  library only — no pip, no Helm, no cluster, no registry)
- **Root privileges** — the installer provisions the application data/log
  directories as UID 10001
- An unused public bind/port (default `0.0.0.0:8080`) and enough disk for
  the images plus persisted SQL/application data
- External MySQL/PostgreSQL databases with separate users for registry and
  orchestration (production default), or the bundled MySQL/PostgreSQL for a
  self-contained stack
- All secrets are operator-provisioned: models.yaml files, runtime env
  files, registry credentials, signing material. Nothing sensitive ships
  inside the release tarball.

---

## Step 1: Build the bundle (online machine)

```bash
cd containerized/offline-install-compose

# From local source trees (matching revisions)
bash build/build-offline.sh --tag deployment-20261020 --app-source build \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --platforms linux/amd64 --out /path/to/output

# Or pull matching published tags
bash build/build-offline.sh --tag deployment-20261020 --app-source pull \
  --platforms linux/amd64 --out /path/to/output
```

The build verifies every image architecture, extracts the frontend assets,
writes `deps/image-tags.json` and `SHA256SUMS`, and refuses to publish a
tarball on any failure. The bundle contains images, scripts, templates,
frontend assets and checksums — **no operator configuration, passwords,
models, PKI or data**.

Transfer `openan-offline-compose-<tag>.tar.gz` to the offline machine.

## Step 2: Extract the bundle (offline machine)

```bash
tar -xzf openan-offline-compose-deployment-20261020.tar.gz
cd openan-offline-compose-deployment-20261020
```

## Step 3: Prepare private configuration

**Quick evaluation (recommended first run):**

```bash
# One command: auto-generates all secrets, certificates, models.yaml,
# credential file; configures bundled MySQL + HTTP + portal frontend.
sudo scripts/install.sh --eval
```

**Manual setup (interactive, for custom configurations):**

```bash
# Generates registry.env, orchestration.env, models.yaml, credential file
# with masked prompts for LLM key, admin password, DB password
scripts/gen-secrets.sh --interactive
chmod 600 config.env registry.env orchestration.env integration_credentials.conf
sudo scripts/check-env.sh --config config.env
sudo scripts/install.sh --config config.env
```

**Non-interactive setup (random keys, edit models.yaml afterwards):**

```bash
scripts/gen-secrets.sh --eval
# Edit registry-models.yaml / orchestration-models.yaml for your LLM
chmod 600 config.env registry.env orchestration.env integration_credentials.conf
sudo scripts/check-env.sh --config config.env
sudo scripts/install.sh --config config.env
```

Minimum decisions in `config.env`:

| Key | Meaning |
|-----|---------|
| `PUBLIC_BIND` / `PUBLIC_PORT` | The only exposed address (default `0.0.0.0:8080`) |
| `FRONTEND_TYPE` | `portal` (default; needs the portal image in the bundle) or `workflow-designer` |
| `DATABASE_TYPE` / `DATABASE_INTERNAL` | External SQL (production default) or bundled MySQL/PostgreSQL |
| `REGISTRY_DB_PASSWORD` / `ORCH_DB_PASSWORD` | Application database credentials |
| `REGISTRY_SIGN_ENABLED` | Default true; needs `sign.cer`/`sign_key.pem`/`cert_pwd` in `REGISTRY_SIGN_DIR` |
| `PUBLIC_ENABLE_HTTPS` | Public TLS termination (independent from backend TLS) |

Minimum secrets in the private env files:

- `registry.env`: `INTEGRATION_FINGERPRINT_KEY`, `INTEGRATION_TOKEN_HMAC_KEY`
  (static Bearer mode), `LLM_CHAT_API_KEY` (referenced by models.yaml)
- `orchestration.env`: `OC_ADMIN_INITIAL_PASSWORD` (first-start web login),
  `REGISTRY_ACCESS_TOKEN` (the plaintext counterpart of the credential-file
  digest; the installer rejects an unprovisioned token)

Files are literal `KEY=VALUE` data, never sourced as shell code. Quote
values containing spaces or `#`; dollar text in passwords survives Compose
interpolation. There is no interactive secret collection and no
`--skip-check` switch.

## Step 4: Check the environment (read-only)

```bash
sudo scripts/check-env.sh --config config.env
```

Verifies tools, bundle checksum, the six mandatory image tars, the frontend
choice and the complete configuration (via configure.py validation).
Failures are blockers: fix the reported items and re-run.

## Step 5: Install

```bash
sudo scripts/install.sh --config config.env
```

The installer loads the local image tars (`docker load` — the stack never
pulls), generates `runtime/compose.json` and `runtime/nginx.conf` (mode
0600, secrets included — do not print or upload them), validates the
Compose file, starts the stack with `--pull never --wait` and runs
`nginx -t` inside the running proxy.

## Step 6: Verify

```bash
sudo docker compose -f runtime/compose.json ps
sudo docker compose -f runtime/compose.json logs -f
```

All services report `healthy` (registry-center, orchestration-center,
nginx, plus portal and/or the bundled database when configured). The
installer's final `compose ps` output is the readiness summary.

Log in through the web entry with the OC admin account configured in
`orchestration.env` and change the password before API use. Public OC APIs
use the same account: `POST /api/v1/auth/token` returns a Bearer token;
cookies alone never authorize public APIs.

## Step 7: Access the platform

```bash
curl http://<host>:8080/    # PUBLIC_BIND:PUBLIC_PORT
```

Only the Nginx public entry is exposed — application and SQL ports are not
published. With `PUBLIC_ENABLE_HTTPS=true` use `https://<host>:<port>/`
and a certificate whose SAN matches the browser address.

---

## Runtime basics

```bash
sudo docker compose -f runtime/compose.json ps        # status
sudo docker compose -f runtime/compose.json logs -f   # follow logs
sudo scripts/uninstall.sh                              # stops containers, KEEPS all data
```

Uninstall removes the containers but retains SQL volumes, runtime files,
application data and source credentials; reinstalling over preserved data
reuses it. Keep `PROJECT_NAME` stable across reinstalls. Back up SQL and
`runtime/` before upgrading.

For HTTP/HTTPS/mTLS profiles, frontend selection, the OC admin token flow
and the acceptance smoke matrix, see [README.md](README.md).
