# OpenAN Platform Quick Start

One-click installation guide using the automated setup script.

## Prerequisites

Before running the setup script, ensure you have:

- **Linux or macOS** system (Windows not yet supported for automated setup)
- **Kubernetes cluster** (v1.25+) with `kubectl` configured
- **Helm 3.10.0+** (will be auto-installed if missing)
- **Internet connection** for downloading dependencies and images

The setup script will automatically install missing tools (Docker, kubectl, Helm, Ingress Controller).

## Step 1: Install OpenAN Platform

```bash
# Clone the repository
git clone https://github.com/project-openan/openan-installation.git
cd openan-installation/containerized

# Run the interactive installation script
./install.sh
```

The script will guide you through an interactive setup:

1. **[1/5] Environment Check** - Detects and auto-installs missing dependencies:
   - Docker (Linux only, auto-install)
   - kubectl (auto-install)
   - Helm (auto-install)
   - Nginx Ingress Controller (auto-install)
   - MetalLB LoadBalancer (auto-install on bare-metal, skipped on cloud)

2. **[2/5] Component Selection** - Choose what to deploy:
   - All components (default): Registry Center + Orchestration Center + Workflow Designer
   - Registry Center only
   - Orchestration Center + Workflow Designer only

3. **[3/5] Registry Center LLM Configuration** - Configure LLM for Registry Center:
   - Chat Model (required, e.g., `gpt-4`, `claude-3-opus`, `qwen-max`)
   - API URL (required, e.g., `https://api.openai.com/v1/chat/completions`)
   - API Key (required, input is hidden)

4. **[4/5] Orchestration Center LLM Configuration** - Configure LLM for Orchestration Center:
   - Chat Model (required, e.g., `gpt-4`, `claude-3-opus`, `qwen-max`)
   - Chat API URL (required, e.g., `https://api.openai.com/v1/chat/completions`)
   - Chat API Key (required, input is hidden)

5. **[5/5] Agent Examples Configuration** - Start demo agents server:
   - Start agent examples server (default: Yes)
   - Required for testing demo workflows

**Storage Configuration:**
- If cluster has default StorageClass → uses existing storage
- If no default StorageClass → automatically creates PV with hostPath (`/data/openan-postgres`)

**Deploy** - Automatically deploys with Helm and starts agents server (if enabled)

## Step 2: Verify Deployment

After setup completes, verify the deployment:
> note: It may take a few minutes for all Pods to reach `Running` state. Please access the platform only after all Pods are running.

```bash
# Check Pod status (wait for all Pods to be Running)
kubectl -n openan get pods

# Expected output:
# NAME                                    READY   STATUS    RESTARTS   AGE
# openan-postgres-0                       1/1     Running   0          2m
# registry-center-xxx                     1/1     Running   0          2m
# orchestration-center-xxx                1/1     Running   0          2m
# workflow-designer-xxx                   1/1     Running   0          2m

# Check services
kubectl -n openan get svc

# Check Ingress
kubectl -n openan get ingress
```

## Step 3: Access Platform

### Get Access URL

The setup script displays the access URL after deployment. Two access methods are available:

#### Method 1: LoadBalancer (Recommended)

If your cluster has a LoadBalancer (MetalLB or cloud provider):

```bash
# Get the LoadBalancer IP
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ -n "$INGRESS_IP" ]; then
  echo "Access URL: http://$INGRESS_IP/"
else
  echo "LoadBalancer IP not assigned yet. Wait a few minutes and try again."
fi
```

#### Method 2: NodePort

If LoadBalancer is not available, use NodePort to access the frontend:

```bash
# Get NodePort
NODE_PORT=$(kubectl get svc -n openan workflow-designer -o jsonpath='{.spec.ports[0].nodePort}')

# Get any node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "Access URL: http://$NODE_IP:$NODE_PORT/"
```

> **Note:** NodePort only provides access to the frontend. API access requires LoadBalancer or port-forwarding.

### Access Services

**Via LoadBalancer:**

| Service | URL |
|---------|-----|
| **Workflow Designer** (Frontend) | `http://<INGRESS_IP>/` |
| **Registry API** | `http://<INGRESS_IP>/registry/rest/v1/registry-center/agent-cards` |
| **Orchestration API** | `http://<INGRESS_IP>/api/orchestrate/rest/v1/orchestrate/agent-cards` |

**Via NodePort:**

| Service | URL |
|---------|-----|
| **Workflow Designer** (Frontend) | `http://<NODE_IP>:<NODE_PORT>/` |

### Test APIs

```bash
# Test Registry API (via LoadBalancer)
curl http://<INGRESS_IP>/registry/rest/v1/registry-center/agent-cards

# Test Orchestration API (via LoadBalancer)
curl http://<INGRESS_IP>/api/orchestrate/rest/v1/orchestrate/agent-cards
```

> **Note:** If no agent-cards are registered in the Registry Center, the API may return an error or empty response. This is expected behavior for a fresh installation. You can register agents through the Workflow Designer UI or via the Registry API.


## Cleanup

### One-click Uninstall

Use the automated uninstall script:

```bash
cd containerized
./uninstall.sh
```

The script will:
- Detect all OpenAN resources (Helm release, PVCs, PVs, MetalLB config)
- Detect hostPath storage location and target node
- Ask whether to remove persistent data (PVCs, PV, StorageClass, hostPath)
- Ask whether to delete the namespace
- Automatically clean up MetalLB configuration (if exists)
- Auto-clean hostPath data using a privileged Job (falls back to manual instructions)

**Options:**
- **Preserve data**: Keep PVCs/PV for reinstallation or backup
- **Remove data**: Delete all persistent storage (database data will be lost)


## Troubleshooting

### Pod stuck in Pending state

```bash
kubectl -n openan describe pod <pod-name>
# Common cause: PVC not bound
kubectl -n openan get pvc
kubectl get pv

# If PVC is Pending and PV is Available, check:
# - Storage capacity matches (both should be 20Gi)
# - Access modes match (both should be ReadWriteOnce)
# - No storageClassName mismatch
```

### Agents server not starting

```bash
# Check agents server logs
kubectl exec -n openan $(kubectl get pods -n openan -l app=orchestration-center -o jsonpath='{.items[0].metadata.name}') -- cat /tmp/agents-server.log

# Manually start agents server (requires registry-center to be ready first)
kubectl exec -n openan $(kubectl get pods -n openan -l app=orchestration-center -o jsonpath='{.items[0].metadata.name}') -- /bin/sh -c "cd /opt/orchestration-center && PYTHONPATH=/opt/orchestration-center nohup python3 samples/start_agents_server.py > /tmp/agents-server.log 2>&1 &"

# Verify agents server is running
kubectl exec -n openan $(kubectl get pods -n openan -l app=orchestration-center -o jsonpath='{.items[0].metadata.name}') -- curl -s http://127.0.0.1:8903/health
```

### Image pull failed

```bash
# Check if image name and tag are correct
kubectl -n openan describe pod <pod-name> | grep -A5 Events

# For private registry, configure imagePullSecrets
kubectl -n openan create secret docker-registry harbor-cred \
  --docker-server=harbor.example.com \
  --docker-username=admin \
  --docker-password=your-password
```

### Database connection failed

```bash
# Check PostgreSQL Pod status
kubectl -n openan get pods -l app=openan-postgres

# Check PostgreSQL logs
kubectl -n openan logs -l app=openan-postgres
```

### Ingress not accessible

```bash
# Check Ingress resources
kubectl -n openan get ingress

# Check Ingress Controller logs
kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller
```

## Related Documentation

- [Helm Chart Configuration](./openan-chart/README.md) - Detailed Helm values
- [Image Build Guide](./build/README.md) - Manual image building
