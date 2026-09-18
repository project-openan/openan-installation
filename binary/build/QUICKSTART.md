# OpenAN Offline Package Builder

`pack.sh` builds **self-contained offline deployment packages** for OpenAN. Run it on an **online machine**; the resulting tarballs can be transferred to an air-gapped machine and installed with the [offline installer](../offline-install/QUICKSTART.md) without any internet access.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [What the Script Does](#what-the-script-does)
- [Output](#output)
- [Next Steps](#next-steps)

---

## How It Works

```
 ┌───────────────────────┐          ┌───────────────────────┐
 │   Online Machine      │          │  Offline Machine      │
 │                       │          │                       │
 │  1. ./pack.sh         │  transfer│  2. ./install.sh      │
 │     ↓                 │ ───────> │     ↓                 │
 │  dist/*.tar.gz        │  USB/SCP │  Extract + venv +     │
 │  (source + wheels +   │          │  install wheels +     │
 │   npm cache)          │          │  build frontend +     │
 │                       │          │  nginx + start        │
 └───────────────────────┘          └───────────────────────┘
```

Each component (registry-center, orchestration-center) is packed into an independent tarball containing:
- Full project source code
- Pre-downloaded Python wheels for **both x86_64 and aarch64** architectures
- npm cache for offline frontend build (orchestration-center only)

The install script auto-detects the target machine's architecture and installs the appropriate wheels — no internet connection needed at install time.

---

## Prerequisites

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| OS | Linux (x86_64 / aarch64) | — |
| Python | 3.12+ | Required |
| Node.js | 20.19+ + npm | Required for `--orc` (frontend cache) |
| curl | Any | For source download |
| tar | Any | For source extraction |
| Internet | Required | Needs GitHub and PyPI access |

> When packing `--orc`, `npm install` is also executed and requires npm registry access.

---

## Usage

#### 1. Clone and enter the build directory

```bash
git clone https://github.com/project-openan/openan-installation.git
cd openan-installation/binary/build
```

#### 2. Grant execute permission (if needed)

```bash
chmod +x pack.sh
```

#### 3. Run the packager

```bash
./pack.sh              # Pack both components (default)
```

Or pack individual components. Version flags (`--reg-version`, `--orc-version`) are **specific flags**: each also selects its component and pins its source tag (ADR-024). Selection is the union of all component flags and is order-independent:

| Flag | Description |
|------|-------------|
| `--reg` | General: pack only registry-center (default version) |
| `--orc` | General: pack only orchestration-center (default version) |
| `--reg-version <tag>` | Specific: pack registry-center and pin its source tag |
| `--orc-version <tag>` | Specific: pack orchestration-center and pin its source tag |
| (no component flag) | Default: pack both (equivalent to `--reg --orc`) |
| `-h` / `--help` | Show help and exit |

```bash
# Examples
./pack.sh                    # Pack everything (default)
./pack.sh --reg              # Pack only registry-center
./pack.sh --orc              # Pack only orchestration-center
./pack.sh --reg --orc        # Pack both
./pack.sh --reg --orc-version v1.1.0  # registry-center (default) + orchestration-center v1.1.0
./pack.sh --help             # Show help
```

---

## What the Script Does

1. Checks prerequisites (Python 3.12+, Node.js/npm for `--orc`, curl, tar)
2. Downloads project source from GitHub Release (via `curl` + `tar`, no `git clone`)
3. Downloads Python wheels for both x86_64 and aarch64 (using `pip download` with manylinux platform tags)
4. Runs `npm install` to populate the npm cache (orchestration-center only; `node_modules` are NOT bundled)
5. Generates README/manifest inside the tarball
6. Creates the tarball in `dist/`

> A temporary packaging venv is created under `/tmp` and removed automatically when the script exits.

---

## Output

Tarballs are produced in `dist/` (i.e., `binary/build/dist/`):

```
dist/
├── registry-center-1.0.0-linux.tar.gz
└── orchestration-center-1.0.0-linux.tar.gz
```

Each tarball is fully self-contained — no additional downloads are needed at install time.

---

## Next Steps

Transfer the tarballs together with the [offline-install](../offline-install/QUICKSTART.md) scripts (`install.sh`, `uninstall.sh`, `configure_llm.sh`) to the air-gapped machine, then run `./install.sh`. See [Phase 2 of the offline deployment guide](../offline-install/QUICKSTART.md#phase-2-install-on-air-gapped-machine-offline) for details.
