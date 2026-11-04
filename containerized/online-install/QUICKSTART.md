# OpenAN Online Container Quickstart

[中文](QUICKSTART.zh.md) · [Full deployment contract](../TRANSPORT_DEPLOYMENT.md)

## Prerequisites

- Linux or macOS with internet access (application images and the pinned infrastructure manifests are fetched online)
- A Kubernetes cluster (v1.25+) reachable with `kubectl`
- Helm 3.14+ (verified with 3.14.2; the chart uses no newer features) and python3
- A default StorageClass for the in-cluster SQL and runtime claims — clusters without one can accept the wizard's local hostPath fallback (evaluation, single-node)
- No host tool is installed without asking: missing kubectl/helm (and Docker for source builds on Linux) can be auto-installed after an explicit interactive confirmation using the official installers; python3 and Docker Desktop stay manual
- The interactive wizard reads secrets from the terminal (getpass); run `./install.sh` from a real TTY. CI and automation use `./install.sh --values` with pre-created Secrets

## Step 1: Interactive install

```bash
cd containerized/online-install
./install.sh
```

The installer orchestrates four phases (`./install.sh --help` shows the short
flow). Release and namespace default to `openan` without prompts (override
with `--release`/`--namespace`); building from source is flag-driven, not a
prompt (`--tag` with `--registry-release` and `--orchestration-release`,
`docker login` to the target registry first).

- **[1/4] Preflight** — checks kubectl, helm and python3, verifies the cluster is reachable, prints the kubectl client version and the release/namespace in use. Missing kubectl/helm are offered for automatic installation (official installers, explicit confirmation only; python3 stays manual).
- **[2/4] Infrastructure** — when MetalLB and ingress-nginx are both detected, the phase is skipped; otherwise it can install the pinned MetalLB v0.16.1 and ingress-nginx controller-v1.15.1 manifests, then prompt for a MetalLB IP pool on bare metal (e.g. `192.168.1.200-192.168.1.250`, leave empty to skip).
- **[3/4] Application** — the guided wizard (configure.py) asks for components, the application image tag (no default: old `v1.0.0` images are not compatible with the current chart; one shared tag, or per-component registry/orchestration/frontend tags), models (generated from chat LLM answers with a connectivity probe, plus **optional embed/rerank models** per component for semantic search/retrieval and an optional **A2A-T SDK negotiation model** for orchestration / existing ConfigMaps), signing (auto demo / existing Secret) and the initial admin password (8+ characters with lower/upper/digit/special classes; asked when orchestration is selected) and the PostgreSQL password (shared by the seeded app users); when only orchestration is selected, the wizard additionally asks for the external agent registry URL (http(s)://...). SQL type/host, storage and the Ingress host are not asked: evaluation always uses in-cluster PostgreSQL; storage picks the cluster's default StorageClass and falls back automatically to node-pinned local hostPath PVs (single-node) when none exists; the Ingress host is the empty catch-all for direct LB-IP access (host-based routing and HTTPS require reviewed values; Kubernetes rejects IP hosts). Secrets go only to Kubernetes Secrets via kubectl stdin; the wizard writes just the non-secret `deployment.generated.json` and never overwrites existing files or Secrets. Failures print the concrete reason (never secret values). If a run fails halfway, reconcile the created Secrets/ConfigMaps and continue with `--values` for upgrades. Re-running the wizard when `deployment.generated.json` already exists asks whether to regenerate it (default keeps the file and prints the `--values` re-deploy command).
- **[4/4] Deploy** — prints a non-secret deployment summary (release/namespace, components, image tags, SQL, storage, models, signing, ingress host) and asks for confirmation before running `helm upgrade --install --wait`; cancelling keeps the generated values and the Secrets/ConfigMaps the wizard already created (it is not transactional). When orchestration is selected, the installer also offers to start the **agent examples server** (demo agents) inside the orchestration-center pod: `samples/start_agents_server.py` via `kubectl exec`, health-checked on port 8903, log at `/tmp/agents-server.log` (answer no to skip; it is a demo convenience, not a chart resource, and does not survive pod restarts). Log in with the admin account configured in the wizard.

## Step 2: Verify deployment

```bash
kubectl -n openan get pods,svc,ingress
```

- Pods: `registry-center-*`, `orchestration-center-*`, `openan-frontend-*` (plus `openan-postgres-0` for in-cluster SQL) should reach `Running`.
- Services: `openan-frontend` (NodePort), `registry-center`, `orchestration-center`, `openan-postgres`.
- Ingresses: `openan-frontend-ingress`, `openan-orchestration-ingress`, `openan-registry-ingress` with the LoadBalancer address in `ADDRESS`.

## Step 3: Access the platform

The LoadBalancer IP is preferred:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller   # EXTERNAL-IP
```

Open `http://<EXTERNAL-IP>/` (the wizard fixes the Ingress host to the empty catch-all, so no DNS setup is needed; host-based routing requires reviewed values). Without a LoadBalancer IP the installer prints the NodePort fallback:

```bash
NODE_PORT=$(kubectl -n openan get svc openan-frontend -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "http://${NODE_IP}:${NODE_PORT}/"
```

Log in with the admin account configured in the wizard and change the password in the web UI before API use.

## HTTPS deployment

1. **MetalLB pool first**: a routable IP range must exist (the same IPAddressPool offered in phase [2/4]) so the ingress gets a stable IP; point DNS or an `/etc/hosts` entry at it.
2. **Generate certificates** with the in-repo tool (requires a registry-center source checkout and the Python `cryptography` package):

   ```bash
   pip install cryptography    # one-time, on the machine running the tool
   python3 tool/gen_certs.py --registry-center-src <registry-center-src> \
       --out ./certs --namespace openan \
       --ingress-host openan.example.com [--ingress-ip <LB-IP> ...]
   # Output tree:
   #   certs/ca/{ca.cer, ca_key.pem, cert_pwd}
   #   certs/registry-center/{server.cer, server_key.pem, trust.cer, cert_pwd}
   #   certs/orchestration-center/{server.cer, server_key.pem, trust.cer, cert_pwd}
   #   certs/ingress/{tls.crt, tls.key, trust.cer}
   ```

   `--ingress-ip` is repeatable — add every address clients will type (MetalLB VIP, node IPs for a NodePort entry). For a bare-IP entry (`https://<IP>` direct) drop `--ingress-host` and pass `--ingress-ip <IP>` (the `openan.test` default is only a placeholder).

3. **Certificate Secrets**:

   ```bash
   kubectl create namespace openan 2>/dev/null || true
   kubectl -n openan create secret tls openan-tls \
       --cert=certs/ingress/tls.crt --key=certs/ingress/tls.key
   # For in-cluster service TLS additionally:
   kubectl -n openan create secret generic openan-rc-tls \
       --from-file=server.cer=certs/registry-center/server.cer \
       --from-file=server_key.pem=certs/registry-center/server_key.pem \
       --from-file=trust.cer=certs/registry-center/trust.cer \
       --from-file=cert_pwd=certs/registry-center/cert_pwd
   kubectl -n openan create secret generic openan-oc-tls \
       --from-file=server.cer=certs/orchestration-center/server.cer \
       --from-file=server_key.pem=certs/orchestration-center/server_key.pem \
       --from-file=trust.cer=certs/orchestration-center/trust.cer \
       --from-file=cert_pwd=certs/orchestration-center/cert_pwd
   ```

4. **Enable in values**: `ingress.host: openan.example.com` — or a bare IP for direct `https://<IP>` access — plus `ingress.tls.enabled: true`, `ingress.tls.secretName: openan-tls`, and `registry.tls.existingSecret: openan-rc-tls` / `orchestration.tls.existingSecret: openan-oc-tls` when in-cluster service TLS is on.
5. **ingress-nginx default certificate** (optional, serves non-matching hosts): create a Secret in the `ingress-nginx` namespace and set the controller argument `--default-ssl-certificate=ingress-nginx/<secret>`:

   ```bash
   kubectl -n ingress-nginx create secret tls default-tls --cert=tls.crt --key=tls.key
   kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json \
       -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-ssl-certificate=ingress-nginx/default-tls"}]'
   ```

6. **In-cluster service TLS / mTLS**: see the [full deployment contract](../TRANSPORT_DEPLOYMENT.md).

## Automation / production (helm-native)

Prepare Kubernetes, Helm, ingress/storage, SQL databases and model/credential/PKI references from the contract.
Copy [deployment.yaml.example](deployment.yaml.example), set all tags and non-secret fields:

```bash
helm lint openan-chart --namespace openan -f deployment.yaml
helm template openan openan-chart --namespace openan -f deployment.yaml > rendered.yaml
helm upgrade --install openan openan-chart --namespace openan --create-namespace -f deployment.yaml --wait --timeout 10m
```

Namespace must match values. Never put secrets in values/--set; if legacy inline fields were intentionally used,
rendered output may contain them, so protect it. Verify APIs at the actual public entrance, not only probes.

`install.sh --values` is the non-interactive variant for prepared environments and CI
(`--skip-build` / `--skip-infra` / `--values ...` / `--release` / `--namespace`); for infrastructure it requires
reviewed local MetalLB/ingress-nginx chart packages and values instead of the online pinned manifests.

## Verification and troubleshooting

With Python/PyYAML/pytest, Helm and Bash installed, run `python -m pytest tests/ -q` **from the repository root** (`tests/` sits next to `containerized/`, not inside it).
Missing tools explicitly skip related tests; render passes are not container/cluster passes.
CI separately builds the real Compose matrix. See [acceptance and troubleshooting](../TRANSPORT_DEPLOYMENT.md#acceptance-and-troubleshooting)
for auth/TLS/SQL/PVC and frontend diagnosis. Single-instance upgrades briefly interrupt service.

Reinstalling over leftover local storage keeps old data: a retained `openan-postgres-pv`
with stale `pgdata` makes in-cluster SQL keep the OLD database passwords (the postgres
socket still connects, but TCP fails with `password authentication failed`). Answer yes
to "Remove persistent data" in `uninstall.sh` — it detects and cleans every OpenAN PV's
hostPath data — or manually remove `/data/openan-*` on the node. The wizard also warns
about leftover PVs before you configure storage.
