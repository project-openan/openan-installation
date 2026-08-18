# OpenAN Platform Helm Chart

Helm Chart for deploying the OpenAN platform on Kubernetes.

## Components

| Component | Description | Port |
|-----------|-------------|------|
| **Registry Center** | Agent Card registration, discovery, and semantic search | 5000 |
| **Orchestration Center** | PSOP generation and workflow execution | 5001 |
| **Workflow Designer** | Visual workflow editing frontend (Nginx) | 80 |
| **PostgreSQL** | Shared database | 5432 |

## Prerequisites

- Kubernetes 1.25+
- Helm 3.10.0+
- Ingress Controller (Nginx) for external access

## File Structure

```
openan-chart/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl
    ├── ingress.yaml
    ├── NOTES.txt
    ├── postgres/
    │   ├── storage.yaml
    │   └── statefulset.yaml
    ├── registry-center/
    │   ├── configmap.yaml
    │   ├── deployment.yaml
    │   ├── secret.yaml
    │   ├── service.yaml
    │   ├── tls-secret.yaml
    │   └── signing-secret.yaml
    ├── orchestration-center/
    │   ├── configmap.yaml
    │   ├── deployment.yaml
    │   ├── secret.yaml
    │   ├── service.yaml
    │   └── hpa.yaml
    └── workflow-designer/
        ├── configmap.yaml
        ├── deployment.yaml
        ├── service.yaml
        └── hpa.yaml
```

## Quick Start

### Install

```bash
# Default configuration from values.yaml
helm install openan ./openan-chart -n openan --create-namespace

# Custom configuration
helm install openan ./openan-chart -n openan --create-namespace -f values-custom.yaml

# Command-line overrides
helm install openan ./openan-chart -n openan --create-namespace \
  --set postgresql.password=your-password \
  --set registry.llm.chat.apiKey=sk-xxx \
  --set orchestration.llm.chat.apiKey=sk-yyy

# Custom image registry
helm install openan ./openan-chart -n openan --create-namespace \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer
```

### Verify

```bash
helm status openan -n openan
kubectl get pods -n openan
kubectl get ingress -n openan
```

### Access Services

#### LoadBalancer (Recommended)

```bash
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "http://$INGRESS_IP/"
```

| Service | URL |
|---------|-----|
| Workflow Designer | `http://<INGRESS_IP>/` |
| Registry API | `http://<INGRESS_IP>/registry/rest/v1/registry-center/agent-cards` |
| Orchestration API | `http://<INGRESS_IP>/api/orchestrate/rest/v1/orchestrate/agent-cards` |

#### NodePort (Frontend Only)

```bash
NODE_PORT=$(kubectl get svc -n openan workflow-designer -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "http://$NODE_IP:$NODE_PORT/"
```

#### Port Forwarding

```bash
kubectl -n openan port-forward svc/registry-center 5000:5000
kubectl -n openan port-forward svc/orchestration-center 5001:5001
kubectl -n openan port-forward svc/workflow-designer 8080:80
```

## Configuration Parameters

### Global

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Kubernetes namespace | `openan` |
| `createNamespace` | Helm creates the namespace | `true` |

### PostgreSQL

| Parameter | Description | Default |
|-----------|-------------|---------|
| `postgresql.enabled` | Enable built-in PostgreSQL | `true` |
| `postgresql.externalHost` | External database address | `""` |
| `postgresql.port` | Database port | `5432` |
| `postgresql.password` | Database password | `openan-db-password` |
| `postgresql.existingSecret` | Reference existing Secret for password | `""` |
| `postgresql.storage.size` | Storage size | `20Gi` |
| `postgresql.storage.storageClassName` | StorageClass name (auto-detect if empty) | `""` |
| `postgresql.storage.createStorageClass` | Auto-create StorageClass | `false` |
| `postgresql.storage.createPV` | Auto-create PV | `false` |
| `postgresql.storage.useHostPath` | Use hostPath (single-node) | `false` |
| `postgresql.storage.hostPath` | hostPath directory | `/data/openan-postgres` |
| `postgresql.storage.reclaimPolicy` | Reclaim policy | `Retain` |
| `postgresql.storage.setDefault` | Set as default StorageClass | `false` |
| `postgresql.resources.requests` | Resource requests | `cpu: 250m, memory: 256Mi` |
| `postgresql.resources.limits` | Resource limits | `cpu: 500m, memory: 512Mi` |

### Registry Center

| Parameter | Description | Default |
|-----------|-------------|---------|
| `registry.enabled` | Enable Registry Center | `true` |
| `registry.replicas` | Replica count | `2` |
| `registry.image.repository` | Image repository | `ghcr.io/project-openan/registry-center` |
| `registry.image.tag` | Image tag | `v1.0.0` |
| `registry.image.pullPolicy` | Image pull policy | `Always` |
| `registry.port` | Service port | `5000` |
| `registry.llm.chat.model` | Chat model | `your-chat-model` |
| `registry.llm.chat.url` | Chat API URL | `https://your-llm-provider.com/v1/chat/completions` |
| `registry.llm.chat.apiKey` | Chat API Key | `your-api-key` |
| `registry.llm.chat.existingSecret` | Reference existing Secret | `""` |
| `registry.llm.embed.model` | Embed model | `your-embed-model` |
| `registry.llm.embed.url` | Embed API URL | `https://your-llm-provider.com/v1/embeddings` |
| `registry.llm.embed.apiKey` | Embed API Key | `your-api-key` |
| `registry.llm.rerank.model` | Rerank model | `your-rerank-model` |
| `registry.llm.rerank.url` | Rerank API URL | `https://your-llm-provider.com/v1/rerank` |
| `registry.llm.rerank.apiKey` | Rerank API Key | `your-api-key` |
| `registry.vectordb.enabled` | Enable VectorDB (Milvus) | `false` |
| `registry.vectordb.host` | VectorDB address | `""` |
| `registry.vectordb.port` | VectorDB port | `19530` |
| `registry.tls.mode` | TLS mode: `auto` / `secret` / `off` | `auto` |
| `registry.tls.existingSecret` | TLS Secret name | `""` |
| `registry.signing.mode` | Signing cert mode: `auto` / `secret` / `off` | `auto` |
| `registry.signing.existingSecret` | Signing cert Secret name | `""` |
| `registry.resources.requests` | Resource requests | `cpu: 250m, memory: 256Mi` |
| `registry.resources.limits` | Resource limits | `cpu: 500m, memory: 512Mi` |

### Orchestration Center

| Parameter | Description | Default |
|-----------|-------------|---------|
| `orchestration.enabled` | Enable Orchestration Center | `true` |
| `orchestration.replicas` | Replica count | `1` |
| `orchestration.image.repository` | Image repository | `ghcr.io/project-openan/orchestration-center` |
| `orchestration.image.tag` | Image tag | `v1.0.0` |
| `orchestration.image.pullPolicy` | Image pull policy | `Always` |
| `orchestration.port` | Service port | `5001` |
| `orchestration.agentRegistryUrl` | Registry Center URL | `""` (auto-discovered) |
| `orchestration.llm.chat.model` | Chat model | `your-chat-model` |
| `orchestration.llm.chat.url` | Chat API URL | `https://your-llm-provider.com/v1/chat/completions` |
| `orchestration.llm.chat.apiKey` | Chat API Key | `your-api-key` |
| `orchestration.llm.chat.existingSecret` | Reference existing Secret | `""` |
| `orchestration.hpa.enabled` | Enable HPA | `false` |
| `orchestration.hpa.minReplicas` | Minimum replicas | `1` |
| `orchestration.hpa.maxReplicas` | Maximum replicas | `10` |
| `orchestration.resources.requests` | Resource requests | `cpu: 250m, memory: 512Mi` |
| `orchestration.resources.limits` | Resource limits | `cpu: 1000m, memory: 1Gi` |

### Workflow Designer

| Parameter | Description | Default |
|-----------|-------------|---------|
| `frontend.enabled` | Enable Workflow Designer | `true` |
| `frontend.replicas` | Replica count | `2` |
| `frontend.image.repository` | Image repository | `ghcr.io/project-openan/workflow-designer` |
| `frontend.image.tag` | Image tag | `v1.0.0` |
| `frontend.image.pullPolicy` | Image pull policy | `Always` |
| `frontend.port` | Service port | `80` |
| `frontend.nodePort` | NodePort | `30191` |
| `frontend.nginxConfig` | Nginx configuration (ConfigMap) | See values.yaml |
| `frontend.hpa.enabled` | Enable HPA | `true` |
| `frontend.hpa.minReplicas` | Minimum replicas | `2` |
| `frontend.hpa.maxReplicas` | Maximum replicas | `10` |
| `frontend.resources.requests` | Resource requests | `cpu: 100m, memory: 128Mi` |
| `frontend.resources.limits` | Resource limits | `cpu: 500m, memory: 256Mi` |

### Ingress

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ingress.enabled` | Enable Ingress | `true` |
| `ingress.className` | Ingress Class | `nginx` |
| `ingress.host` | Domain (empty for IP-based access) | `""` |
| `ingress.tls.enabled` | Enable TLS | `false` |
| `ingress.tls.secretName` | TLS Secret name | `openan-tls` |

## Deployment Scenarios

### Production

```bash
helm install openan-prod ./openan-chart --namespace openan-prod --create-namespace -f values-prod.yaml
```

### Registry Only

```bash
helm install openan ./openan-chart -n openan --create-namespace \
  --set orchestration.enabled=false --set frontend.enabled=false
```

### External Database

```bash
helm install openan ./openan-chart -n openan --create-namespace \
  --set postgresql.enabled=false \
  --set postgresql.externalHost=db.example.com \
  --set postgresql.password=your-password
```

## Common Operations

```bash
# Upgrade
helm upgrade openan ./openan-chart -n openan -f values.yaml

# Upgrade with --reuse-values (only override specified fields)
helm upgrade openan ./openan-chart -n openan --reuse-values \
  --set registry.llm.chat.apiKey="new-key"

# Rollback
helm history openan -n openan
helm rollback openan 1 -n openan

# Uninstall
helm uninstall openan -n openan
kubectl delete pvc -n openan --all  # optional: remove data

# Logs
kubectl logs -n openan -l app=registry-center -f
kubectl logs -n openan -l app=orchestration-center -f
```

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                       openan namespace                           │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐      ┌───────────────────────────────────┐   │
│  │   Ingress    │─────▶│  Workflow Designer (Frontend)     │   │
│  │  (Nginx)     │      │  - Deployment (2 pods)            │   │
│  │  / → :80     │      │  - Service :80 (NodePort: 30191)  │   │
│  │  /api/       │      │  - HPA                            │   │
│  │  orchestrate │      └───────────────────────────────────┘   │
│  │  → :5001     │                      │                       │
│  │  /registry   │                      │ (nginx proxy)         │
│  │  → :5000     │                      ▼                       │
│  └──────────────┘      ┌───────────────────────────────────┐  │
│                        │  Orchestration Center              │  │
│                        │  - Deployment (1 pod)              │  │
│                        │  - Service :5001                   │  │
│                        │  - HPA (optional)                  │  │
│                        └───────────────────────────────────┘  │
│                                  │                             │
│                                  ▼                             │
│                        ┌───────────────────────────────────┐  │
│                        │  Registry Center                   │  │
│                        │  - Deployment (2 pods)             │  │
│                        │  - Service :5000                   │  │
│                        └───────────────────────────────────┘  │
│                                  │                             │
│                                  ▼                             │
│                        ┌───────────────────────────────────┐  │
│                        │  PostgreSQL (Shared)               │  │
│                        │  - StatefulSet                     │  │
│                        │  - registry_center DB              │  │
│                        │  - orchestration_center DB         │  │
│                        │  - PVC 20Gi                        │  │
│                        └───────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Ingress Path Rewrite Rules:**

| External Path | Backend | Rewrite |
|---------------|---------|---------|
| `/` | `workflow-designer:80` | None |
| `/api/orchestrate/rest/v1/orchestrate/...` | `orchestration-center:5001/rest/v1/orchestrate/...` | Strip `/api/orchestrate` |
| `/registry/rest/v1/registry-center/...` | `registry-center:5000/rest/v1/registry-center/...` | Strip `/registry` |

## Certificate Management

Registry Center requires two types of certificates:

| Type | Purpose | Mount Path |
|------|---------|------------|
| TLS | HTTPS communication | `/opt/registry-center/etc/ssl` |
| JWS Signing | Agent Card signing | `/opt/registry-center/etc/sign_cert` |

| Mode | Description | Use Case |
|------|-------------|----------|
| `auto` (default) | Helm generates self-signed certs, stored in Secret, preserved across upgrades via `lookup` | Recommended |
| `secret` | User-provided K8S Secret | Production with official CA |
| `off` | Entrypoint generates per-pod, not persisted | Dev/debug only |

Custom certificates:

```bash
kubectl create secret generic registry-tls -n openan \
  --from-file=server.cer=./server.crt \
  --from-file=server_key.pem=./server.key \
  --from-file=trust.cer=./ca.crt

kubectl create secret generic registry-signing -n openan \
  --from-file=server.cer=./sign_cert/server.cer \
  --from-file=server_key.pem=./sign_cert/server_key.pem \
  --from-file=cert_pwd=./sign_cert/cert_pwd.txt
```

```yaml
registry:
  tls:
    mode: secret
    existingSecret: registry-tls
  signing:
    mode: secret
    existingSecret: registry-signing
```

## Troubleshooting

| Issue | Command |
|-------|---------|
| Namespace conflict | `kubectl delete namespace openan` then reinstall, or `--set createNamespace=false` |
| Pod cannot start | `kubectl -n openan describe pod <pod-name>` |
| Database connection | `kubectl -n openan logs -l app=openan-postgres` |
| Ingress not accessible | `kubectl -n openan describe ingress` |
| Certificate issues | `kubectl -n openan get secret registry-center-tls registry-center-signing` |

## Related Documentation

- [Quick Start](../QUICKSTART.md)
- [Image Build Guide](../build/README.md)

## License

Apache License 2.0
