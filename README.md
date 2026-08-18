# OpenAN Installation

System-level installation tooling for OpenAN, providing one-click binary installation and clustered containerized installation with modular component selection and fully configurable parameters.

## Project Structure

```
openan-installation/
├── binary/one-click/                # Binary installation
│   ├── openan_install.sh            # one-click installation script
│   ├── openan_uninstall.sh          # one-click uninstall script
│   ├── README.md                    # Binary installation guide
└── containerized/                   # Containerized installation
    ├── build/                       # Image build scripts
    ├── install.sh                   # Interactive installation tool
    ├── uninstall.sh                 # One-click uninstall script
    ├── openan-chart/                # Helm chart
    └── QUICKSTART.md                # Quick start guide
```

## Installation Methods

### 1. Clustered Containerized Installation (Kubernetes)

Production-grade installation using Helm charts. Supports multi-node clusters, HPA auto-scaling, and TLS certificates.

```bash
git clone https://github.com/project-openan/openan-installation.git
cd openan-installation/containerized
./install.sh
```

**Features:**
- Modular component selection (Registry Center, Orchestration Center, Workflow Designer)
- Fully configurable parameters (LLM API keys, image registry, storage)
- Auto-detects cluster environment (StorageClass, Ingress Controller, LoadBalancer)
- MetalLB auto-installation for bare-metal clusters
- One-click uninstall with optional data cleanup

**Manual / System Admin Installation:**
If you prefer to manually install the Helm chart, follow these steps:
- Prerequisites: Ensure you have a Kubernetes cluster (v1.25+) and Helm 3.10.0+ installed.
- Build your local images by running `containerized/build/build.sh` or pull from ghcr.io.
- Customize the Helm chart values in `containerized/openan-chart/values.yaml`, and then install the chart using Helm:
```bash
cd containerized
helm install openan ./openan-chart -n openan --create-namespace
```

### 2. One-Click Binary Installation

Binary-based installation for virtual machines or bare-metal servers. Downloads and starts all services locally with automatic dependency setup.

**Linux/macOS:**
```bash
cd binary/one-click
./openan_install.sh
```

**Features:**
- Downloads and starts all services locally (PostgreSQL, Registry, Orchestration, Frontend)
- Automatic dependency setup (Python venvs, Node.js)
- Ready for installation in minutes

## Uninstall

### Containerized

```bash
cd containerized
./uninstall.sh
```

Or manually:

```bash
helm uninstall openan -n openan
kubectl delete namespace openan
```

### Binary

```bash
cd binary/one-click
./openan_uninstall.sh
```

## Upgrade

> **Note:** Upgrade functionality including single component upgrades and all-in-one upgrades is currently under development and not yet available.

## Documentation

- [Quick Start](./containerized/QUICKSTART.md) - One-click installation guide
- [Helm Chart](./containerized/openan-chart/README.md) - Helm configuration reference
- [Image Build](./containerized/build/README.md) - Custom image building
- [Binary Installation](./binary/one-click/README.md) - Binary installation details

