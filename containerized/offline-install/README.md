# OpenAN Offline Installation (Kubernetes)

> **Offline-install line.** The offline Kubernetes chart and installer are maintained on this line: they carry their own templates and implement the account (OC admin seeding), model (full models.yaml mount) and frontend (openan-portal) contracts for offline deployments. See [QUICKSTART.md](QUICKSTART.md) and the [deployment contract](../TRANSPORT_DEPLOYMENT.md).


Containerized, fully offline installation of the OpenAN platform on
an existing Kubernetes cluster. Nothing here touches the internet at install
time, and nothing modifies the OS or the container runtime — anything that must
be changed on a node is reported as a manual step (see
[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)).

> Docker Compose (single host, no Kubernetes) lives in the sibling directory
> [`containerized/offline-install-compose/`](../offline-install-compose).

## Topology

- 2 × `registry-center`, 2 × `orchestration-center`, 2 × `openan-frontend`
  (openan-portal by default; `FRONTEND_TYPE` selects the unified entry),
  1 × database (MySQL 8.4.3 by default, or PostgreSQL when
  `DB_TYPE=postgresql`).
- One `ingress-nginx` entry point behind a MetalLB LoadBalancer IP.
- Images come from an **in-cluster private registry** (NodePort `30500`, plain
  HTTP) populated from the bundle.

The bundle is **per-architecture**: every image ships as
`images/<component>-<arch>.tar`, so each node only ever imports its own
architecture; a multi-arch manifest list is built in the registry so a single
tag serves both amd64 and arm64 nodes. See [Image packaging](#image-packaging).

## Prerequisites

A running Kubernetes cluster (kubeadm, v1.33+; v1.33 verified in the field). Building the cluster itself is
out of scope — see [docs/KUBEADM_CLUSTER.md](docs/KUBEADM_CLUSTER.md).

## Build the bundle (internet-connected machine)

Requires Linux + Docker with buildx. To build for a foreign architecture
(e.g. amd64 images on an arm64 host), install QEMU user-mode emulation once:
`docker run --rm --privileged tonistiigi/binfmt --install amd64` (see
[QUICKSTART.md](QUICKSTART.md#building-from-source-on-an-arm64-or-amd64-host)).

```bash
cd build
./build-offline.sh --tag v1.0.0 --app-source pull
```

Application image sources (`--app-source`):

| value | meaning |
|---|---|
| `pull` | `docker pull` the app images (registry-center, orchestration-center, workflow-designer, openan-portal) from `--app-registry` (default `ghcr.io/project-openan`) |
| `build` | build them from local source (`--registry-src`, `--orchestration-src`; portal is pull-only) |
| `tars` | reuse pre-built tars (`--app-tars-dir`) |

Everything else (PostgreSQL / MySQL, registry:2, ingress-nginx, MetalLB, helm,
kubectl, crane) is pinned and downloaded automatically. The result is
`build/dist/openan-offline-<tag>/` plus a `openan-offline-<tag>.tar.gz`.

## Install on an offline machine

```bash
tar -xzf openan-offline-v1.0.0.tar.gz
cd openan-offline-v1.0.0
cp config.env.example config.env
vi config.env

scripts/check-env.sh --config config.env
sudo scripts/install.sh --config config.env
```

`config.env` is documented inline. Interactive use is also supported: run
`install.sh` with no arguments and it will prompt, then write `config.env` for
you.

## Database selection

`DB_TYPE` in `config.env` selects the database backend:

| `DB_TYPE` | Bundled image | Used by |
|---|---|---|
| `mysql` (default) | `mysql:8.4.3` | registry-center + orchestration-center |
| `postgresql` | `postgres:15-alpine` | registry-center + orchestration-center |

When `mysql` is selected (the default) the installer deploys a single
`openan-mysql` StatefulSet (hostPath fallback `/data/openan-mysql`), creates
the same two databases, and points both applications at it
(`PERSISTENCE_MODE=mysql`).
> **Note:** MySQL mode in orchestration-center requires an application version
> that implements the MySQL persistence handler; verify your image supports it
> before selecting `DB_TYPE=mysql`.

## What the installer does

1. **Checks** the environment (`scripts/check-env.sh`) and aborts on unmet
   prerequisites.
2. Bootstraps an **in-cluster registry** (`registry:2`, pinned to `REGISTRY_NODE`,
   data in `/data/openan-registry`).
3. **Pushes** every bundle image to the registry and stitches a **multi-arch
   manifest list** per component with the bundled `crane`, so a single tag
   serves both amd64 and arm64 nodes.
4. Installs **MetalLB** (optional) and **ingress-nginx** offline.
5. **Generates TLS certificates** by default (`tool/gen_certs_offline.py`, openssl):
   a CA plus per-service certs stored as Secrets; the ingress verifies
   backend certificates against the shared CA, and OC verifies the registry's
   certificate on its outbound connection. Operator-provided Secrets are
   supported (`RC_TLS_SECRET` / `OC_TLS_SECRET` / `INGRESS_CLIENT_SECRET`,
   optional `REGISTRY_CLIENT_SECRET`). Database, admin and LLM credentials
   are created as Secrets (`openan-db-credentials`, `openan-admin`,
   `openan-llm-keys`) and referenced — never inlined into the values file.
6. Deploys the chart with `helm upgrade --install` and a generated values
   file — a fresh cluster gets a plain install, an existing release is
   upgraded in place (see below).
7. **Self-checks**: pods ready, registry catalog reachable, API smoke tests.

## Re-running, changing configuration and uninstalling

The installer is idempotent: existing infrastructure (registry, MetalLB,
ingress-nginx) and Secrets are reused. When the Helm release `openan` already
exists, re-running `scripts/install.sh` **upgrades it in place** (`helm upgrade
--install` with the values regenerated from the current answers) — no
`uninstall.sh` needed, PVCs and Helm revision history are preserved.

**Changing the configuration after installation** — pick the flow that fits:

```bash
# A. Change config.env and re-run the installer (regenerates config.values.yaml)
vi config.env                       # e.g. image tags, INGRESS_HOST, replicas
sudo scripts/install.sh --config config.env

# B. One-field change applied directly with Helm (everything else kept)
helm upgrade openan ./chart -n openan --reuse-values --set https.enabled=false
```

Two things to know about flow A:

- **Secrets are reused, not rotated.** `DB_PASSWORD`, `OC_ADMIN_PASSWORD` and
  LLM API keys land in Secrets once; changing them in `config.env` does *not*
  update an existing Secret. Rotate explicitly, then re-run:

  ```bash
  kubectl -n openan delete secret openan-db-credentials   # or openan-admin, openan-llm-keys
  ```

- **New image tags must also be in the registry.** Re-running the installer
  re-pushes every image from `images/`, so a new bundle version upgrades the
  deployed version end to end; with flow B, push the image first
  (`scripts/push-images.sh`) or `IfNotPresent` keeps the old one running.

**Inspecting the deployed state** — the installer never writes rendered
manifests to disk; Helm keeps them in the release history, which is the source
of truth for what is running:

```bash
helm get values openan -n openan      # values the release was last deployed with
helm get manifest openan -n openan     # fully rendered Kubernetes manifests
helm history openan -n openan         # revision history (upgrade keeps it)
helm rollback openan <rev> -n openan   # undo a failed or unwanted upgrade
```

`helm get manifest` is the rendered chart output after values and templates
were applied — exactly what is running. Add `--revision N` to inspect an older
revision; the output is plain YAML, so it can be diffed between revisions for
audits or troubleshooting.

`scripts/uninstall.sh` removes the release, the in-cluster registry, optionally
the persistent volumes and the namespace. It never edits `containerd`; the
insecure-registry reminder is printed for you to apply manually.

## Image packaging

`docker save` cannot hold two architectures in one archive, so each component
ships as one tar per architecture:

```
images/registry-center-amd64.tar
images/registry-center-arm64.tar
images/...
```

`scripts/push-images.sh` pushes both variants under side tags and then creates
the real tag as a manifest list. `deps/infra-images.list` records the exact
registry-relative reference of each infrastructure image.

## Layout

```
offline-install/
├── chart/            Helm chart (offline copy; postgres/mysql image + node-pinned PV)
├── build/            build-offline.sh (runs on the internet build machine)
├── scripts/          check-env.sh, install.sh, push-images.sh, uninstall.sh,
│                     lib/common.sh
├── docs/             DEPENDENCIES.md, KUBEADM_CLUSTER.md
├── config.env.example
├── QUICKSTART.md
└── README.md
```

## Documentation

- [QUICKSTART.md](QUICKSTART.md) — end-to-end flow: build → transfer → install
- [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) — what you must provide manually
- [docs/KUBEADM_CLUSTER.md](docs/KUBEADM_CLUSTER.md) — building the Kubernetes
  cluster itself (offline)
