# OpenAN Helm Chart

See [HTTP/HTTPS and database deployment contract](../../TRANSPORT_DEPLOYMENT.md) for the current supported configuration, Secret schemas and migration requirements.

- Select SQL type with database.type; postgresql.enabled controls in-cluster hosting, not the application provider. Any non-postgresql type is external SQL that passes through verbatim (PERSISTENCE_MODE) — the services must support it; unknown types need an explicit database.port.
- Supply runtimeSecret, database credentials and model definitions explicitly. No shared default passwords.
- HTTP and HTTPS-no-mTLS retain application authentication. TLS, signing and peer verification are independent controls.
- Supply TLS Secrets created by enterprise PKI or the development certificate tool. Helm auto TLS keys are no longer supported.
- Signing auto preserves deployed keys during upgrade; production uses an explicit signing Secret.
- Models are mounted as a complete file. Existing model Secrets override inline values. The Orchestration Center additionally supports the A2A-T SDK negotiation LLM via `orchestration.a2atLlm` (provider/model/baseUrl; the API key lives in `runtimeSecret` as `A2AT_LLM_API_KEY`), independent of models.yaml.
- `frontend.type` selects the unified entry: portal (default, listens on 8080) or workflow-designer (legacy, chart-managed nginx). `frontend.backendTls` and `frontend.nginxConfig` apply only to workflow-designer; both types deploy as openan-frontend resources (Deployment/Service/Ingress).
- RC and OC each use one replica: RC event listeners/dispatchers and OC sessions are process-local. Extra replicas — and enabling HPA — are rejected at render time (`validate.yaml`), not an HA option. Legacy vector-only RC mode cannot serve the complete SQL-backed API and is rejected.
- Independent retained runtime PVCs hold each service's data and logs, even with external SQL. Both services use Recreate upgrades to avoid overlapping file writers; plan a maintenance window. See the deployment contract for existing claims and pre-upgrade backup/restore.
- Storage fallback: on clusters without a StorageClass, `postgresql.storage.createStorageClass` + `createPV`/`useHostPath`/`nodeName` create the shared `openan-local` class and node-pinned hostPath PVs (postgres, `openan-rc-pv`, `openan-oc-pv`) so all claims bind — single-node evaluation only. `persistence.createPV` requires `storageClassName`; `uninstall.sh` cleans these PVs and their hostPath data.

```bash
helm lint . --namespace openan -f deployment.yaml
helm template openan . --namespace openan -f deployment.yaml
helm upgrade --install openan . -n openan --create-namespace -f deployment.yaml
```

Rebuild the matching service images before using this chart. Offline render/lint validates templates, not Secret contents or runtime/cluster behavior. Certificate Secret changes require a Pod rollout because file mounts use subPath.
