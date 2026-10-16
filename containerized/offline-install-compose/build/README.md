# Offline Docker Compose Bundle Builder

Builds a self-contained offline bundle for deploying OpenAN on a single host
using Docker Compose, with no internet access. Run on an internet-connected
Linux machine with Docker.

See the [Compose README](../README.md) for the end-to-end flow.

## What the bundle contains

```
openan-offline-compose-<tag>/
├── images/            Per-architecture image tars (docker load format)
│   ├── registry-center-amd64.tar
│   ├── registry-center-arm64.tar
│   └── ...
├── deps/
│   └── image-tags.json   Machine-readable image manifest (consumed by configure.py)
├── scripts/           install.sh, check-env.sh, uninstall.sh, configure.py
├── compose/init/      Database initialization scripts (create-databases.sh, create-mysql-databases.sh)
├── web/               Frontend static files (extracted from the workflow-designer image)
└── SHA256SUMS
```

## Usage

```bash
cd containerized/offline-install-compose/build

# Pull app images from a registry (default ghcr.io/project-openan)
./build-offline.sh --tag v1.0.0 --app-source pull

# Build app images from local or remote source
./build-offline.sh --tag v1.0.0 --app-source build \
    --registry-src ~/src/registry-center \
    --orchestration-src ~/src/orchestration-center \
    --portal-src ~/src/openan-portal

# Reuse pre-built tars
./build-offline.sh --tag v1.0.0 --app-source tars --app-tars-dir ~/prebuilt
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--tag <tag>` | derived from `--source-ref` | App image tag |
| `--source-ref <ref>` | `v1.0.0` | Source Git ref; `main` → `main-YYYYMMDD`, other refs become the tag |
| `--app-registry <host/ns>` | `ghcr.io/project-openan` | Upstream app registry |
| `--app-source` | `pull` | `pull` \| `build` \| `tars` |
| `--registry-src <dir>` | — | Local registry-center source dir (overrides remote) |
| `--orchestration-src <dir>` | — | Local orchestration-center source dir |
| `--registry-release <url>` | GitHub archive | Remote registry-center source tarball |
| `--orchestration-release <url>` | GitHub archive | Remote orchestration-center source tarball |
| `--portal-src <dir>` | — | openan-portal source dir (optional) |
| `--platforms <list>` | `linux/amd64` | Target architectures (single-arch for Compose) |
| `--out <dir>` | `./dist` | Output directory |

## Bundled infrastructure images (always pulled)

| Image | Purpose |
|-------|---------|
| `postgres:15-alpine` | PostgreSQL database |
| `mysql:8.4` | MySQL database |
| `nginx:1.27.5-alpine` | Public nginx entry |

The **portal frontend** is optional: if the image is unavailable (not yet
published), the bundle gracefully degrades to `FRONTEND_TYPE=workflow-designer`
with a warning; `deps/image-tags.json` records portal only when every
requested architecture produced a tar.

The frontend static files are extracted from the workflow-designer image
into `web/` (mounted into the nginx container) — Compose does not run a
separate frontend container for the designer fallback.

## Relationship to other build scripts

| Script | Purpose |
|--------|---------|
| `containerized/build/build.sh` | Build images and push to a registry (online) |
| `../offline-install/build/build-offline.sh` | Package a K8s offline bundle (helm + chart + kubectl + manifests) |
| **this script** | Package a self-contained Compose offline bundle (configure.py + scripts + images + web) |
