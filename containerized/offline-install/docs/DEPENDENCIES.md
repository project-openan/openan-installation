# Offline dependencies — what you must provide manually

The installer is deliberately split in two:

- **The bundle installs these for you** (no internet, no manual work).
- **You must provide these manually** — they are OS-level or environment-level
  and the installer only *detects* and *reports* them. It never edits
  `containerd`, the firewall or the network configuration.

`scripts/check-env.sh` checks everything below and prints the exact fix.

---

## 1. Installed automatically from the bundle

| Component | How |
|---|---|
| helm, kubectl, crane | binaries in `deps/bin/` (both amd64 + arm64) |
| registry:2 (private registry) | in-cluster Deployment, NodePort 30500 |
| ingress-nginx | `deps/manifests/ingress-nginx.yaml` (image refs rewritten) |
| MetalLB | `deps/manifests/metallb-native.yaml` (image refs rewritten) |
| Database (PostgreSQL 15 or MySQL 8.4.3, per `DB_TYPE`) | chart image, rewritten to `<registry>/library/postgres:15-alpine` or `<registry>/library/mysql:8.4.3` |
| OpenAN app images | registry-center, orchestration-center, workflow-designer, openan-portal |
| TLS certificates | `tool/gen_certs_offline.py` (openssl CLI) generates a CA + per-service certs at install time into Secrets, unless operator Secrets are configured |

Nothing above reaches the internet.

---

## 2. You must provide manually — Kubernetes

### 2.1 A running Kubernetes cluster (v1.33+)

See [KUBEADM_CLUSTER.md](KUBEADM_CLUSTER.md). This is a hard prerequisite: the
installer deploys *onto* a cluster, it does not create one.

### 2.1b openssl and python3 on the install node (HTTPS default)

In-cluster HTTPS is enabled by default. Unless you bring your own TLS Secrets
(`RC_TLS_SECRET` / `OC_TLS_SECRET` / `INGRESS_CLIENT_SECRET`), the installer
generates certificates with `tool/gen_certs_offline.py`, which needs the `openssl`
CLI and `python3` on the install node (both standard on supported Linux
hosts; verified by `check-env.sh`).

### 2.2 containerd must trust the private registry (every node)

The in-cluster registry is plain **HTTP** on `<REGISTRY_NODE_IP>:30500`. Every
node's containerd must be told to use HTTP for it, otherwise image pulls fail
with `http: server gave HTTP response to HTTPS client`.

**Preferred (portable) — `certs.d` host config.** On *every* node:

```bash
sudo mkdir -p /etc/containerd/certs.d/192.168.1.10:30500
sudo tee /etc/containerd/certs.d/192.168.1.10:30500/hosts.toml >/dev/null <<'EOF'
server = "http://192.168.1.10:30500"

[host."http://192.168.1.10:30500"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
```

Then make sure `/etc/containerd/config.toml` points containerd at that directory:

```toml
# containerd 1.6 / 1.7
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"

# containerd 2.x
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = "/etc/containerd/certs.d"
```

**Alternative — inline mirror config:**

```toml
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."192.168.1.10:30500"]
  endpoint = ["http://192.168.1.10:30500"]

[plugins."io.containerd.grpc.v1.cri".registry.configs."192.168.1.10:30500".tls]
  insecure_skip_verify = true
```

Finally restart containerd on every node:

```bash
sudo systemctl restart containerd
```

> Replace `192.168.1.10` with your `REGISTRY_NODE_IP`. `check-env.sh` reports
> whether *this* node already trusts the registry.

### 2.3 MetalLB address pool

MetalLB needs a range of **routable, currently-unused** IPs on your LAN:

```bash
# config.env
INSTALL_METALLB="true"
METALLB_POOL="192.168.1.200-192.168.1.250"
```

The range must not contain any node IP, and your switches/router must be able to
reach the chosen VIP (L2 mode: the VIP lives on one node at a time).

### 2.4 Storage

`STORAGE_MODE=auto` (default):

- if the cluster has a **default StorageClass**, it is used as-is;
- otherwise a **hostPath PV** is created on `STORAGE_NODE` at `HOSTPATH`
  (`/data/openan-postgres`, or `/data/openan-mysql` when `DB_TYPE=mysql`), pinned to that node via node affinity. The
  directory is created automatically (`DirectoryOrCreate`).

Provide a `STORAGE_NODE` explicitly for a multi-node cluster if `install.sh` is
not run on the intended storage node. Set `STORAGE_MODE=sc` and `STORAGE_CLASS`
to force a specific class.

### 2.5 Time synchronisation

Unsynchronised clocks break TLS, token signing and image checks. Ensure NTP is
running on all nodes (`chronyd` on openEuler/CentOS, `systemd-timesyncd` on
Ubuntu).

### 2.6 Disk space

Roughly 5 GiB free next to the bundle for extraction, plus the registry data
(`/data/openan-registry`) and the database (`/data/openan-postgres`, or
`/data/openan-mysql` when `DB_TYPE=mysql`; default `20Gi`).

### 2.7 Firewall

Open on every node:

- `30500/tcp` — the private registry NodePort;
- the NodePort range (`30000-32767/tcp`) and `80/443/tcp` for ingress-nginx;
- MetalLB L2 traffic (ARP) must not be filtered on the node interfaces.

### 2.8 SELinux (openEuler / CentOS / Rocky)

With SELinux in `enforcing` mode, `hostPath` volumes for the database and the
registry may be denied. Either label the data directories:

```bash
sudo chcon -Rt container_file_t /data/openan-postgres /data/openan-mysql /data/openan-registry
```

or set `SELINUX=permissive` in `/etc/selinux/config` (per your security policy).

### 2.9 An internal LLM endpoint

OpenAN needs a chat model at run time. In an offline network this is normally
an **internal** LLM service (vLLM / MindIE / Ollama / an internal gateway):

```bash
REGISTRY_CHAT_MODEL / REGISTRY_CHAT_URL / REGISTRY_CHAT_APIKEY
ORCH_CHAT_MODEL     / ORCH_CHAT_URL     / ORCH_CHAT_APIKEY
```

LLM connectivity is **not validated** during an offline install by default
(`LLM_VALIDATE=false`). Set it to `true` if you want `check-env.sh` to probe the
endpoint.

---

## 3. Docker Compose deployments

Docker Compose is a separate deliverable with its own manual dependency list —
see [`containerized/offline-install-compose/docs/DEPENDENCIES.md`](../../offline-install-compose/docs/DEPENDENCIES.md).

---

## 4. Frequently missed

- Registry IP must be **reachable from every node** (not just the node that runs
  the registry). Use a node IP, not `127.0.0.1`.
- `REGISTRY_NODE_IP` must match the address you put in `certs.d`.
- Node hostnames must match the Kubernetes node names (`kubectl get nodes`) —
  the registry and storage pinning use `kubernetes.io/hostname`.
