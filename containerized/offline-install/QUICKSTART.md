# OpenAN Offline Installation Quickstart (Kubernetes)

> **Offline-install line.** The offline Kubernetes chart and installer are maintained on this line: they carry their own templates and implement the account (OC admin seeding), model (full models.yaml mount) and frontend (openan-portal) contracts for offline deployments. See the [deployment contract](../TRANSPORT_DEPLOYMENT.md).


End-to-end guide: build the offline bundle on an **internet-connected machine**,
transfer it to the **offline machine**, and install OpenAN onto an existing
Kubernetes cluster. Nothing at install time touches the internet.

For architecture, configuration reference and troubleshooting see
[README.md](README.md) and [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

---

## Prerequisites

### Build machine (online)

- Linux with **Docker** (buildx enabled) and `curl`
- Internet access to `ghcr.io`, `docker.io`, `registry.k8s.io`, `quay.io`,
  `get.helm.sh`, `dl.k8s.io`, `github.com`

### Offline machine / cluster

The cluster and its OS-level dependencies are **already installed** — the
installer deploys *onto* a cluster, it does not create one:

- A running **Kubernetes cluster (v1.33+)**, e.g. built with `kubeadm`
  (`kubeadm`, `kubelet`, `kubectl`, containerd and the control-plane images all
  in place). Building the cluster offline is covered by
  [docs/KUBEADM_CLUSTER.md](docs/KUBEADM_CLUSTER.md).
- `kubectl` access to the cluster from the machine you run the installer on
  (`~/.kube/config` present, nodes `Ready`).
- **At least 20 GB of free disk space** on the install node: the extracted
  bundle images, the containerd import and the crane pushes all land on this
  node before the cluster pulls them. (`check-env.sh` only warns below
  5 GiB, which is not enough for a full bundle; clean old deployments and
  stale images first, e.g. `kubectl delete ns <old-namespace>` and
  `docker system prune -a --volumes`.)

Prepare the following items **before** running the installer (full details and
the exact check commands for each are in
[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)):

**1. Every node's containerd trusts the in-cluster registry**
([DEPENDENCIES.md §2.2](docs/DEPENDENCIES.md#22-containerd-must-trust-the-private-registry-every-node)).
The registry is plain HTTP on `<REGISTRY_NODE_IP>:30500`. On **every** node:

```bash
sudo mkdir -p /etc/containerd/certs.d/192.168.1.10:30500
sudo tee /etc/containerd/certs.d/192.168.1.10:30500/hosts.toml >/dev/null <<'EOF'
server = "http://192.168.1.10:30500"

[host."http://192.168.1.10:30500"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
```

Make sure `/etc/containerd/config.toml` enables `config_path = "/etc/containerd/certs.d"`
(containerd 1.6/1.7 and 2.x use different sections — see the doc), then
`sudo systemctl restart containerd` on every node. Replace `192.168.1.10` with
your `REGISTRY_NODE_IP`. `check-env.sh` verifies this per node.

**2. A MetalLB address pool** (bare-metal clusters,
[§2.3](docs/DEPENDENCIES.md#23-metallb-address-pool)) — a range of routable,
currently-unused IPs on your LAN, e.g. `192.168.1.200-192.168.1.250`. Goes into
`METALLB_POOL` in `config.env`.

**3. Storage** ([§2.4](docs/DEPENDENCIES.md#24-storage)) — either a default
StorageClass exists, or the installer falls back to a node-pinned hostPath PV
(`HOSTPATH=/data/openan-postgres`, or `/data/openan-mysql` when
`DB_TYPE=mysql`; `STORAGE_NODE`).

**4. Time synchronisation, disk space, firewall, SELinux**
([§2.5–2.8](docs/DEPENDENCIES.md#25-time-synchronisation)) — NTP running on all
nodes; ~5 GiB free; open `30500/tcp`, `30000-32767/tcp`, `80/443/tcp`, and do
not filter MetalLB L2/ARP traffic; on openEuler/CentOS/Rocky either label the
data directories or set SELinux permissive.

**5. An internal LLM endpoint** ([§2.9](docs/DEPENDENCIES.md#29-an-internal-llm-endpoint)) —
OpenAN needs a chat model at run time; in an offline network this is normally
an internal service (vLLM / MindIE / Ollama / gateway). Its model/URL/API key
go into `config.env` (`REGISTRY_CHAT_*`, `ORCH_CHAT_*`).

---

## Phase 1: Build the offline bundle (online machine)

```bash
cd containerized/offline-install/build
./build-offline.sh --tag v1.0.0 --app-source pull
```

This downloads the pinned dependencies (helm, kubectl, crane, ingress-nginx,
MetalLB manifests) and pulls/builds all images, then produces:

```
build/dist/openan-offline-v1.0.0/         # bundle directory
build/dist/openan-offline-v1.0.0.tar.gz   # transferable tarball
```

Application image sources (`--app-source`):

| value | meaning |
|---|---|
| `pull` (default) | pull the app images (registry-center, orchestration-center, workflow-designer, openan-portal) from `--app-registry` (default `ghcr.io/project-openan`) |
| `build` | build from local source: `--registry-src <dir> --orchestration-src <dir>` (portal is pull-only; see the build README) |
| `tars` | reuse pre-built `<base>-<arch>.tar` from `--app-tars-dir <dir>` |

Useful options: `--platforms linux/amd64,linux/arm64` (default both),
`--out <dir>`, `--keep-images`. See `./build-offline.sh --help`.

### Building from source on an arm64 (or amd64) host

When the build machine's architecture differs from one of the target
platforms, Docker needs QEMU user-mode emulation for the foreign architecture.
Install it **once** per machine (e.g. on an arm64 host, to build amd64
images):

```bash
docker run --rm --privileged tonistiigi/binfmt --install amd64
```

Then build both platforms from local source:

```bash
cd containerized/offline-install/build
./build-offline.sh --tag v1.0.0 --app-source build \
    --registry-src ~/src/registry-center \
    --orchestration-src ~/src/orchestration-center \
    --platforms linux/amd64,linux/arm64 --keep-images
```

> Same machine arch for all platforms? The QEMU step is unnecessary.
> On an amd64 host building arm64 images, use `--install arm64` instead.

## Phase 2: Transfer the bundle to the offline machine

Copy `openan-offline-v1.0.0.tar.gz` to the offline machine (the node where you
will run the installer — it must have `kubectl` access and will host the
in-cluster registry by default), using SCP, USB or an internal file server:

```bash
scp build/dist/openan-offline-v1.0.0.tar.gz user@<offline-node>:~
```

## Phase 3: Install on the offline machine

```bash
tar -xzf openan-offline-v1.0.0.tar.gz
cd openan-offline-v1.0.0

# 1. Configure — every option is documented inline
cp config.env.example config.env
vi config.env          # at minimum: METALLB_POOL, DB_PASSWORD, OC_ADMIN_PASSWORD, LLM endpoints

# 2. Verify the environment (never changes anything)
scripts/check-env.sh --config config.env

# 3. Install
sudo scripts/install.sh --config config.env
```

Interactive mode is also supported: run `sudo scripts/install.sh` with no
arguments and it prompts for the same values, then writes `config.env` for you.

The installer will:

1. Run the environment check (skip with `--skip-check` if already verified).
2. Bootstrap an in-cluster private registry (`registry:2`, NodePort `30500`).
   The registry is plain HTTP, so **every node's containerd must be configured
   to trust it** (`certs.d` host config) before images can be pulled — see
   [docs/DEPENDENCIES.md §2.2](docs/DEPENDENCIES.md#22-containerd-must-trust-the-private-registry-every-node)
   for the exact per-node setup.
3. Push all bundle images and stitch multi-arch manifest lists.
4. Install MetalLB (optional) and ingress-nginx offline.
5. `helm install` the OpenAN chart with a generated values file.
6. Self-check: pods ready, registry catalog reachable, API smoke tests.

## Verify

```bash
kubectl -n openan get pods,svc,ingress
```

The installer prints the access URL at the end — either the MetalLB
LoadBalancer IP (`http://<LB_IP>/`) or a NodePort fallback
(`http://<node-ip>:<nodePort>/`).

> An alternative entry — an external load balancer targeting a **fixed node IP
> and NodePorts** (no MetalLB, no virtual IP) — is described in
> [the next section](#alternative-entry-external-load-balancer-on-a-fixed-node-ip-no-metallb).

## Alternative entry: external load balancer on a fixed node IP (no MetalLB)

The default entry is the MetalLB LoadBalancer VIP on the
`ingress-nginx-controller` Service. Environments whose firewall policy cannot
cover a virtual IP, or that must route through an existing external load
balancer (F5 / hardware LB) that only targets real node IPs, can skip MetalLB
entirely and expose ingress-nginx through **fixed NodePorts on a pinned node**:

```
external LB ──> <pinned-node-IP>:30080 (HTTP) / 30443 (HTTPS)
                  └─> ingress-nginx-controller Pod (pinned to that node)
                        └─> OpenAN backends (same Ingress rules as before)
```

The bundled manifest (`deps/manifests/ingress-nginx.yaml`, upstream cloud
variant) sets `externalTrafficPolicy: Local` on the Service: only nodes
running a controller Pod accept NodePort traffic — every other node drops it —
and the client source IP is preserved. **Pinning the controller to a known
node is therefore required**, not optional: the LB pool and the firewall rules
must list exactly the pinned node(s).

In this variant `METALLB_POOL` ([§2.3](docs/DEPENDENCIES.md#23-metallb-address-pool))
is not needed, and the firewall entry from §2.5–2.8 becomes
*LB source IP → pinned node IP(s), TCP 30080/30443* instead of VIP 80/443.

### A. Fresh install: edit the manifest first

`scripts/install.sh` applies `deps/manifests/ingress-nginx.yaml` verbatim
(apart from rewriting image references) and only when the `ingress-nginx`
namespace does not exist yet — `uninstall.sh` never removes it.

If the cluster already runs ingress-nginx from a previous (default) install,
remove it before reinstalling, otherwise install.sh skips the manifest and
these edits never take effect. Delete the admission webhook configuration
first — it is registered with `failurePolicy: Fail` and rejects Ingress
create/update cluster-wide while its backing Service is gone (which would
block the chart's own Ingress creation further down the install):

```bash
kubectl delete validatingwebhookconfiguration ingress-nginx-admission
kubectl delete ns ingress-nginx
```

Deleting the namespace leaves the cluster-scoped objects (ClusterRoles,
IngressClass) behind; the re-applied manifest recreates them — nothing to
clean up by hand. Only do this on a cluster dedicated to OpenAN: any other
application sharing this ingress-nginx loses its entry point for the duration
of the reinstall. The non-destructive alternative on a live cluster is the
patch path in [section B](#b-existing-installation-patch-instead).

Edit the file in the bundle **before** the first install onto a cluster:

```bash
cd openan-offline-v1.0.0

# 1) Service: type LoadBalancer -> NodePort, fix the nodePorts.
#    Anchor on targetPort: `name: http` also matches the Deployment's
#    container ports, and `appProtocol: https` also matches the admission
#    Service (ClusterIP — a nodePort there fails validation).
sed -i 's/type: LoadBalancer/type: NodePort/' deps/manifests/ingress-nginx.yaml
sed -i '/targetPort: http$/a\    nodePort: 30080' deps/manifests/ingress-nginx.yaml
sed -i '/targetPort: https$/a\    nodePort: 30443' deps/manifests/ingress-nginx.yaml
```

The Service should now read:

```yaml
  type: NodePort
  ports:
  - appProtocol: http
    name: http
    port: 80
    protocol: TCP
    targetPort: http
    nodePort: 30080
  - appProtocol: https
    name: https
    port: 443
    protocol: TCP
    targetPort: https
    nodePort: 30443
```

```bash
# 2) Deployment: pin the controller Pod to a node — edit by hand. The
#    admission Jobs carry the same kubernetes.io/os selector, so a blind sed
#    would pin them too. In the ingress-nginx-controller Deployment only:
```

```yaml
      nodeSelector:
        kubernetes.io/os: linux
        kubernetes.io/hostname: worker-1   # exact name from `kubectl get nodes`
```

```bash
# 3) Disable the MetalLB branch, otherwise install.sh switches the Service
#    back to LoadBalancer and waits for a VIP that never comes
vi config.env          # INSTALL_METALLB="false"

# 4) Install as usual
sudo scripts/install.sh --config config.env
```

Any free port inside the API server's `--service-node-port-range`
(default 30000–32767) works — **30500 is the in-cluster registry**, avoid it.

### B. Existing installation: patch instead

```bash
# Service: NodePort with fixed ports (add replaces an allocated nodePort)
kubectl -n ingress-nginx patch svc ingress-nginx-controller --type json -p '[
  {"op":"replace","path":"/spec/type","value":"NodePort"},
  {"op":"add","path":"/spec/ports/0/nodePort","value":30080},
  {"op":"add","path":"/spec/ports/1/nodePort","value":30443}]'

# Deployment: pin the node (strategic merge keeps kubernetes.io/os: linux)
kubectl -n ingress-nginx patch deploy ingress-nginx-controller -p '
{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-1"}}}}}'

kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller
```

Patching the nodeSelector restarts the controller (single replica — expect a
short ingress outage).

### C. External LB and firewall

| Item | Value |
|---|---|
| LB backend pool | `<pinned-node-IP>:30080` (HTTP) and/or `:30443` (HTTPS) — only the pinned node(s) |
| Health check | `GET /healthz` on port 30080, expect HTTP 200 (served by ingress-nginx itself; no backend involved) |
| Scheduling | round-robin; no session persistence needed |
| Firewall | LB source IP → pinned node IP(s), TCP 30080/30443 |

- With `externalTrafficPolicy: Local` (manifest default) all other nodes
  deliberately drop NodePort traffic — that is expected; keep the LB pool to
  the pinned node(s) and let the health check do the rest.
- If `INGRESS_HOST` is set, the LB must pass the `Host` header through
  (L4 pass-through does; L7 proxies need it configured explicitly).
- Switching the Service to `externalTrafficPolicy: Cluster` would let *any*
  node forward NodePort traffic (LB pool could then list all nodes, no pinning
  needed) at the cost of the client source IP (SNAT). Use only when pinning is
  impossible.

### D. Optional: two-node HA

A single pinned node is a single point of failure. For HA, label two nodes,
spread two controller replicas across them and put both in the LB pool:

```bash
kubectl label node worker-1 openan-ingress=true
kubectl label node worker-2 openan-ingress=true
```

```yaml
      # ingress-nginx-controller Deployment
      replicas: 2
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app.kubernetes.io/component: controller
            topologyKey: kubernetes.io/hostname
      nodeSelector:
        kubernetes.io/os: linux
        openan-ingress: "true"
```

On an existing cluster the same changes go through
`kubectl -n ingress-nginx patch deploy ingress-nginx-controller`.

### E. Verify

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller
#   80:30080/TCP,443:30443/TCP   EXTERNAL-IP: <none>
kubectl -n ingress-nginx get pod -l app.kubernetes.io/component=controller -o wide
#   controller Pod running on the pinned node

curl -s -o /dev/null -w '%{http_code}\n' http://<pinned-node-IP>:30080/healthz
#   200
curl -s -o /dev/null -w '%{http_code}\n' \
  http://<pinned-node-IP>:30080/registry/rest/v1/registry-center/agent-cards
```

## In-cluster HTTPS (default on)

`HTTPS_ENABLED` defaults to `"true"`: registry-center and orchestration-center
are served over TLS inside the cluster. By default the installer generates a
self-signed CA plus per-service certificates with `tool/gen_certs.py` (openssl;
needs `openssl` and `python3` on the install node) and stores them as Secrets
`openan-rc-tls` / `openan-oc-tls` / `openan-ingress-client` — and
`openan-public-tls` when `INGRESS_HOST` is set, which also enables public
HTTPS on the ingress. The ingress always verifies backend server certificates
against the shared CA (`proxy-ssl-verify` on). Probes, the frontend upstream
and the ingress backend protocol switch automatically.

To use your own certificates instead, pre-create the Secrets and set
`RC_TLS_SECRET`, `OC_TLS_SECRET` and `INGRESS_CLIENT_SECRET` in `config.env`
(all three together; keys: `server.cer`, `server_key.pem`, `trust.cer`,
`cert_pwd` for the services and `tls.crt`, `tls.key`, `ca.crt` for the ingress
client). `HTTPS_VERIFY_CLIENT="true"` additionally requires client
certificates (mTLS) on the registry listener — note that kubelet httpGet
probes present no client certificate, so this stays opt-in.

### Disabling in-cluster HTTPS (plain HTTP backends)

Everything TLS-related keys off the single switch `HTTPS_ENABLED` — the
per-service `REGISTRY_ENABLE_HTTPS` / `ORCH_ENABLE_HTTPS` env vars are
derived from it by the chart; there is no separate per-service knob.

```bash
# Fresh install: config.env
HTTPS_ENABLED="false"
#   (check-env.sh then prints an expected warning:
#    "HTTPS_ENABLED is not true — in-cluster traffic stays plain HTTP")

# Existing installation
helm upgrade openan ./chart -n openan --reuse-values --set https.enabled=false
```

That one switch re-points the whole chain — nothing else to edit:

| Item | Switches to |
|---|---|
| App env | `REGISTRY/ORCH_ENABLE_HTTPS`, `VERIFY_CLIENT` → `false` |
| RC/OC pods | no `tls-certs` volume mounts |
| RC probes | scheme HTTP |
| Portal upstream | `http://registry-center:5000` / `http://orchestration-center:5001` |
| Ingress backends | `backend-protocol`/`proxy-ssl-*` annotations removed → HTTP |
| OC→RC client TLS | not rendered |
| Installer (fresh) | skips `gen_certs.py` and all TLS Secret creation |

Notes:

- **The OC admin credential is mandatory over HTTP** — orchestration-center
  refuses to start without it. The installer already enforces
  `OC_ADMIN_PASSWORD`; pure-Helm deployments must set
  `orchestration.admin.initialPassword` or `admin.existingSecret`.
- **ingress-nginx itself needs no changes.** Backend protocol is decided by
  the chart's Ingress annotations; ingress-nginx picks the change up with an
  automatic nginx reload (no restart). A few seconds of 502s are possible
  while the Deployment rollout and the annotation removal converge.
- TLS Secrets from a previous HTTPS install (`openan-rc-tls` etc.) remain in
  the namespace, unreferenced — delete them by hand for a clean state.
- The external entry is independent: the NodePort/LB entry is plain HTTP
  anyway, and `INGRESS_HOST` + public TLS terminate at the ingress edge.
- Portal login credentials and LLM API keys then travel in cleartext inside
  the cluster network — acceptable on an isolated offline network, but a
  policy decision.

## Frontend selection

`FRONTEND_TYPE` selects the unified web entry: `portal` (openan-portal,
default — log in with the OC admin account (`OC_ADMIN_PASSWORD` in
`config.env`, required)) or `workflow-designer` (legacy).
The bundle ships both frontend images, so the choice is install-time.

## Uninstall

```bash
scripts/uninstall.sh --config config.env
```

Removes the Helm release, the in-cluster registry, and optionally the
persistent volumes and namespace.

---

## Troubleshooting

- **check-env.sh failures** — it prints the exact fix for every item; see
  [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).
- **`http: server gave HTTP response to HTTPS client`** — a node's containerd
  does not trust the in-cluster registry yet; apply the `certs.d` config from
  [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) §2.2 on every node.
- **Switching the services to plain HTTP** — one switch re-points everything;
  see [Disabling in-cluster HTTPS](#disabling-in-cluster-https-plain-http-backends).
- **Re-running install** — infrastructure steps are idempotent, but if the Helm
  release `openan` already exists the installer aborts; run `uninstall.sh`
  first (this version does not support upgrades).
