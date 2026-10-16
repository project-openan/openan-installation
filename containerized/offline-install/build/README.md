# Offline Kubernetes Bundle Builder

Builds a self-contained offline bundle for deploying OpenAN on an existing
Kubernetes cluster with no internet access. Run on an internet-connected
Linux machine with Docker (buildx enabled).

See [QUICKSTART.md](../QUICKSTART.md) for the end-to-end flow: build →
transfer → install.

## What the bundle contains

```
openan-offline-<tag>/
├── images/            Per-architecture image tars (docker save format)
│   ├── registry-center-amd64.tar
│   ├── registry-center-arm64.tar
│   └── ...
├── deps/
│   ├── bin/           helm, kubectl, crane (per-architecture)
│   ├── manifests/     ingress-nginx, MetalLB (pinned YAML manifests)
│   ├── infra-images.list  registry-relative refs of all infra images
│   └── image-tags.env     app image references used by the installer
├── chart/             Helm chart (offline copy)
├── scripts/           install.sh, check-env.sh, uninstall.sh, push-images.sh
├── config.env.example
└── SHA256SUMS
```

## Usage

```bash
cd containerized/offline-install/build

# Pull app images from a registry (default ghcr.io/project-openan)
./build-offline.sh --tag v1.0.0 --app-source pull

# Build app images from local source
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
| `--registry-src <dir>` | — | registry-center source dir (with Dockerfile) |
| `--orchestration-src <dir>` | — | orchestration-center source dir |
| `--portal-src <dir>` | — | openan-portal source dir (optional; absent → designer-only bundle) |
| `--registry-release <url>` | GitHub archive | Remote registry-center source tarball |
| `--orchestration-release <url>` | GitHub archive | Remote orchestration-center source tarball |
| `--platforms <list>` | `linux/amd64,linux/arm64` | Target architectures |
| `--out <dir>` | `./dist` | Output directory |
| `--keep-images` | off | Do not delete pulled images afterwards |

## Pinned dependencies (downloaded automatically)

| Component | Version |
|-----------|---------|
| helm | v3.19.5 |
| kubectl | v1.34.12 |
| crane | v0.19.2 |
| ingress-nginx | controller-v1.15.1 |
| MetalLB | v0.16.1 |

The bundle is **per-architecture**: every image ships as one tar per arch.
The installer pushes each arch separately and stitches a multi-arch manifest
list in the in-cluster registry so a single tag serves both amd64 and arm64
nodes.

## Relationship to other build scripts

| Script | Purpose |
|--------|---------|
| `containerized/build/build.sh` | Build images and push to a registry (online) |
| **this script** | Package a self-contained K8s offline bundle (helm + chart + tools + images) |
| `../offline-install-compose/build/build-offline.sh` | Package a self-contained Compose offline bundle (different tooling and layout) |
