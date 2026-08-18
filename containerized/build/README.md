# OpenAN Platform Image Build Guide

This document describes how to build the container images required for the OpenAN Helm Chart.

## Directory Structure

```
build/
├── build.sh          # One-line build script
└── README.md         # This document
```

## Prerequisites

- Docker 20.10+ with buildx enabled
- curl
- (Optional) QEMU for multi-architecture builds

## Quick Start

### One-line Build

```bash
cd build
./build.sh
```

This single command downloads release v1.0.0 packages from GitHub, builds all component images, and pushes them to ghcr.io.

### Build Specific Components

```bash
./build.sh registry                 # Build Registry Center only
./build.sh orchestration            # Build Orchestration Center + Workflow Designer
./build.sh registry orchestration   # Build both (same as default)
```

### Custom Registry

```bash
./build.sh --image-registry harbor.example.com --namespace project-openan --tag v1.0.0
```

### Local Build (No Push)

```bash
./build.sh --platforms linux/amd64 --no-push
```

## Command Line Options

### Components (positional)

| Component | Description |
|-----------|-------------|
| `registry` | Build Registry Center only |
| `orchestration` | Build Orchestration Center + Workflow Designer |
| (none) | Build all components |

If no components specified, all components are built. Specify one or both to build selectively.

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `--image-registry <url>` | Image registry address | `ghcr.io` |
| `--namespace <ns>` | Image namespace | `project-openan` |
| `--tag <tag>` | Image tag | `v1.0.0` |
| `--registry-release <url>` | Registry Center release tarball URL | GitHub release v1.0.0 |
| `--orchestration-release <url>` | Orchestration Center release tarball URL | GitHub release v1.0.0 |
| `--platforms <platforms>` | Target platform architectures | `linux/amd64,linux/arm64` |
| `--no-push` | Build locally only (single-arch) | - |
| `--help` | Show help information | - |

### Examples

```bash
# Build all components (default)
./build.sh

# Build Registry Center only
./build.sh registry

# Build Orchestration Center + Workflow Designer only
./build.sh orchestration

# Build both explicitly
./build.sh registry orchestration

# Registry only, with custom registry and tag
./build.sh registry --image-registry harbor.example.com --tag v1.0.0

# Orchestration only, local single-arch build
./build.sh orchestration --platforms linux/amd64 --no-push

# All components, custom registry
./build.sh --image-registry harbor.example.com --namespace myorg
```

### Default Release URLs

The script downloads from these GitHub releases by default:

- Registry Center: `https://github.com/project-openan/registry-center/releases/download/v1.0.0/registry-center-v1.0.0.tar.gz`
- Orchestration Center: `https://github.com/project-openan/orchestration-center/releases/download/v1.0.0/orchestration-center-v1.0.0.tar.gz`

Override with `--registry-release` and `--orchestration-release` to use custom URLs or different versions.

## Multi-architecture Build

The build script uses `docker buildx` to support multi-architecture images (amd64 + arm64).

### Prerequisites

1. **Install QEMU** (for emulating different architectures)

   ```bash
   # Ubuntu/Debian
   sudo apt-get install qemu-user-static
   
   # Or using Docker
   docker run --privileged --rm tonistiigi/binfmt --install all
   ```

2. **Create buildx builder** (automatically done by the script)

   ```bash
   docker buildx create --name multiarch-builder --use
   ```

### Building Multi-architecture Images

```bash
# Default: build amd64 + arm64 and push
./build.sh

# Custom target platforms
./build.sh --platforms linux/amd64,linux/arm64,linux/arm/v7

# Single architecture only (faster)
./build.sh --platforms linux/amd64 --no-push
```

### Verifying Multi-architecture Images

```bash
# View supported architectures for an image
docker buildx imagetools inspect ghcr.io/project-openan/registry-center:v1.0.0

# Example output:
# Name: ghcr.io/project-openan/registry-center:v1.0.0
# Manifests:
#   Name: ...@sha256:abc123
#   Platform: linux/amd64
#   
#   Name: ...@sha256:def456
#   Platform: linux/arm64
```

### Notes

1. **Must push**: Multi-architecture images must be pushed to a registry, cannot be used locally
2. **Build time**: Multi-architecture build time is approximately N times single architecture (N = number of architectures)
3. **Registry support**: Ensure your image registry supports multi-architecture manifests (Docker Hub, Harbor, ACR, etc. all support this)

## Build Process

```
1. Parse arguments and print configuration
   ↓
2. Download release packages
   ├─ Registry Center tarball → extract to temp directory
   └─ Orchestration Center tarball → extract to temp directory
   ↓
3. Detect source directories (handle tarball extraction variations)
   ↓
4. Create or select buildx builder
   ↓
5. Build images
   ├─ [1/3] registry-center
   ├─ [2/3] orchestration-center
   └─ [3/3] workflow-designer (if Dockerfile found in orchestration-center/workflow-designer)
   ↓
6. Push images to registry (if --push or multi-arch)
   ↓
7. Print result and Helm deploy command
   ↓
8. Clean up temp directories
```

## Image Naming Convention

Built images follow this naming format:

```
{registry}/{namespace}/{component}:{tag}
```

Examples:
- `ghcr.io/project-openan/registry-center:v1.0.0`
- `ghcr.io/project-openan/orchestration-center:v1.0.0`
- `ghcr.io/project-openan/workflow-designer:v1.0.0`

Private registry examples:
- `harbor.example.com/project-openan/registry-center:v1.0.0`
- `harbor.example.com/project-openan/orchestration-center:v1.0.0`
- `harbor.example.com/project-openan/workflow-designer:v1.0.0`

## Integration with Helm Chart

After building, deploy using the Helm Chart:

```bash
# Using command-line overrides
helm install openan ./openan-chart \
  -n openan --create-namespace \
  --set registry.image.repository=ghcr.io/project-openan/registry-center \
  --set registry.image.tag=v1.0.0 \
  --set orchestration.image.repository=ghcr.io/project-openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=ghcr.io/project-openan/workflow-designer \
  --set frontend.image.tag=v1.0.0

# Or edit values-custom.yaml
# registry:
#   image:
#     repository: ghcr.io/project-openan/registry-center
#     tag: v1.0.0
# orchestration:
#   image:
#     repository: ghcr.io/project-openan/orchestration-center
#     tag: v1.0.0
# frontend:
#   image:
#     repository: ghcr.io/project-openan/workflow-designer
#     tag: v1.0.0

helm install openan ./openan-chart -n openan --create-namespace -f values-custom.yaml
```

## FAQ

### Q: How to build from local source code?

A: The simplified script downloads release packages. For local source builds, use `docker buildx` directly:

```bash
# Build Registry Center from local source
docker buildx build --platform linux/amd64 \
  -t registry-center:latest --load \
  /path/to/registry-center

# Build Orchestration Center from local source
docker buildx build --platform linux/amd64 \
  -t orchestration-center:latest --load \
  /path/to/orchestration-center

# Build Workflow Designer from local source
docker buildx build --platform linux/amd64 \
  -t workflow-designer:latest --load \
  /path/to/orchestration-center/workflow-designer
```

### Q: How to use a different release version?

A: Override the release URLs:

```bash
./build.sh \
  --tag v1.1.0 \
  --registry-release https://github.com/project-openan/registry-center/releases/download/v1.1.0/registry-center-v1.1.0.tar.gz \
  --orchestration-release https://github.com/project-openan/orchestration-center/releases/download/v1.1.0/orchestration-center-v1.1.0.tar.gz
```

### Q: How to skip Workflow Designer?

A: If the orchestration-center release doesn't contain a `workflow-designer` directory with a Dockerfile, it's skipped automatically with a warning.

### Q: Build failed with "docker buildx not installed"?

A: Ensure Docker 20.10+ is installed and buildx is enabled:

```bash
docker buildx version
docker buildx create --name default --use
```

### Q: How to use private image registry?

A: Specify registry and namespace:

```bash
./build.sh --image-registry harbor.example.com --namespace project-openan --tag v1.0.0
```

Ensure you're logged in:

```bash
docker login harbor.example.com
```

### Q: How to verify successful image build?

A: Use these commands to check:

```bash
# List images
docker images | grep openan

# For multi-arch images, inspect manifest
docker buildx imagetools inspect ghcr.io/project-openan/registry-center:v1.0.0
```

## Best Practices

1. **Version tags**: Use semantic versioning (e.g., `v1.0.0`) for production, `latest` for development
2. **Image scanning**: Scan images for vulnerabilities using `trivy` or `snyk` before pushing to production
3. **Multi-architecture support**: Use the default multi-arch build for cross-platform compatibility
4. **Private registry**: Use private registries for production deployments with proper access control
5. **Resource limits**: Set appropriate resource limits in Helm values to prevent resource abuse
6. **Cache optimization**: The build script uses buildx which leverages Docker layer cache automatically

## Related Documentation

- [Quick Start](../QUICKSTART.md) (Build + Deploy one-stop guide)
- [Helm Chart Deployment](../openan-chart/README.md)
- [K8S Deployment Guide](../../k8s-deployment-guide.md)
- [Docker Official Documentation](https://docs.docker.com/)
