# HTTP/HTTPS, Authentication and Database Deployment Contract

[中文](TRANSPORT_DEPLOYMENT.zh.md) · [Quickstart](online-install/QUICKSTART.md) · [Offline Compose](offline-install-compose/README.md)

## Supported scope and source baseline

This contract covers the maintained online Helm chart, shared image builder and single-host offline Compose.
The offline Compose line selects its frontend with `FRONTEND_TYPE` (portal default); the portal image is
pending publication (openan-portal#11), and bundles built without it carry only the workflow-designer frontend.
The offline Kubernetes chart and installer are maintained on the offline-install line: they carry their own
templates and now implement the account (OC admin seeding), model (full models.yaml mount) and frontend
(openan-portal) contracts for offline deployments. See offline-install/QUICKSTART.md.

CI builds accepted organization revisions, not personal forks:

| Component | Source | Fixed revision |
| --- | --- | --- |
| Registry | project-openan/registry-center | `49d9c2463c2d4d3a369db295b6d0b87ef244a27e` |
| Orchestration and designer | project-openan/orchestration-center | `77ee99e485c4b1d3de76bef975cb6f0ef7a517a1` |

Old v1.0.0 images are not compatible-contract evidence. Build and explicitly set enabled
`registry/orchestration/frontend.image.tag` values; the chart has no usable default.
Image tags and source revisions are independent. OCI source labels use repository URLs,
with a Git revision when available (otherwise unknown).

## Configuration responsibilities

- `database.type`: postgresql/mysql. `postgresql.enabled` controls only bundled PostgreSQL; Helm MySQL is external.
- External `database.host/port`: null/omitted port selects PostgreSQL 5432 or MySQL 3306; integer 1..65535.
  Bundled PostgreSQL instead uses `postgresql.port`.
- `database.registry/orchestration`: separate names/users/password Secret references.
  Both services cannot use the same external database name at the shared host.
- Bundled PostgreSQL initializes its users with the shared `postgresql.existingSecret/postgres-password`;
  independent external password Secrets cannot be mixed into that initialization. Production should use separate credentials.
- `modelsConfigMap`: complete models.yaml; secret environment variables come from runtime/per-capability Secrets.
  The `llm` shortcut supports OpenAI-compatible profiles only; other provider/auth profiles need complete ConfigMaps.
- `namespace` must equal Helm `--namespace`. Release is selectable, but resource names are fixed: one stack per namespace.
- `frontend.type` selects the unified web entry: portal (default) or workflow-designer; the workflow-designer
  fallback verifies the OC backend through `frontend.backendTls`.

## Authentication is independent of TLS

Registry Token identity reuses static_bearer, OAuth2 JWT/introspection or custom providers.
Main and integration listeners own separate async clients. Static credential files contain HMAC-SHA256 digests,
identities, roles and enabled entries, not plaintext Tokens. Missing/unusable selected materials reject startup.
Ordinary roles discover public cards; vendors write their own cards; administrative/integration policy remains separate.

Orchestration uses the same account as web login in HTTP/HTTPS/mTLS:

1. Empty SQL users: supply `OC_ADMIN_INITIAL_PASSWORD` from a Secret; existing accounts are not reset.
2. Log in to the UI, change the initial password and log in again.
3. `POST /api/v1/auth/token` returns top-level `access_token`, `token_type`, `expires_in`.
4. Use an explicit Bearer header on public APIs; cookies alone and query Tokens do not authorize them.
5. Logout, password change and account deletion revoke sessions. Expiry/restart requires re-login.

Helm/Compose explicitly choose `ORCH_EXTERNAL_AUTH_MODE=user`; no fixed ORCH_API_TOKEN is required.
Gateway certificates identify proxies, not anonymous users. Internal browser APIs keep cookie/Bearer authentication;
shipped proxies mark browser traffic without replacing caller authentication.

| False setting | Effect | Still required |
| --- | --- | --- |
| tls.verifyClient | No inbound client certificate | Application authentication |
| orchestration.clientVerifyServer | OC skips RC server verification | Client identity if RC requires mTLS |
| frontend.backendTls.verifyServer | Designer skips OC server verification | User login/Token |
| ingress.backendVerifyServer | Ingress skips backend server verification | Upstream client identity if required |

Prefer verification with trusted CA material. Explicit OC verification-off does not inject REGISTRY_CA_FILE,
but still loads client identity when RC requires it. HTTPS-no-mTLS plus client verify=False can communicate
with a valid Token; absent/invalid Tokens remain rejected. Configure public_scheme/publicScheme from the
browser entrance: public HTTPS uses Secure cookies even over a private HTTP backend hop.

## Secrets, signing and permissions

| Secret role | Contents |
| --- | --- |
| RC/OC database | db-password or configured passwordKey |
| RC runtime | INTEGRATION_FINGERPRINT_KEY; static mode also INTEGRATION_TOKEN_HMAC_KEY; selected OAuth/model variables |
| RC credentials | integration_credentials.conf: token digests, identity, role, enabled |
| OC runtime | OC_ADMIN_INITIAL_PASSWORD on first boot, REGISTRY_ACCESS_TOKEN, model secret variables |
| Backend TLS | server.cer, server_key.pem, cert_pwd, trust.cer; mTLS probe-client.cer/probe-client.key |
| Signing | sign.cer, sign_key.pem, cert_pwd |
| OC registry client | trust.cer; mTLS client.cer/client_key.pem; encrypted key password via REGISTRY_CLIENT_KEY_PASSWORD |
| Designer backend | trust.cer; mTLS client.cer/client_key.pem loadable by Nginx |
| Ingress upstream | ca.crt; mTLS tls.crt/tls.key |

Signing and TLS material are independent. signing.mode=off explicitly disables signing, not certificate generation.
auto is evaluation-only and preserves online material via lookup; production uses secret.
Enabled signing with missing/invalid material refuses service, never silently emits unsigned cards.
Use service certificate tools only for development, managed PKI for production. Do not replace an online signing
Secret with random offline helm-template output; rotation also requires updating trusted public keys.

Prefer existing Secrets or the wizard's stdin creation. Never put secrets in generated values, --set, shell history
or logs. Disable tracing and protect Secret RBAC/etcd. The wizard never overwrites Secrets and is not transactional:
after a partial failure reconcile already-created objects explicitly rather than rerunning or deleting credentials.
Kubernetes Secret files use subPath, UID/fsGroup 10001 and mode 0440 in restricted image directories.
SubPath changes require restart. Compose binds actual files, never creates missing files as directories;
use owner 10001 with directory 0700/file 0600 or read-only service-group access.

## HTTP/HTTPS and probes

Start with [deployment.yaml.example](online-install/deployment.yaml.example) for external MySQL + HTTPS-no-mTLS.
Specify complete models, compatible tags and all prepared Secrets. HTTP disables backend TLS, not authentication/signing.
HTTPS probes validate the server CA; mTLS probes also present client identity. SANs must match actual proxy/probe names:

```yaml
registry:
  extraEnv:
    REGISTRY_HEALTHCHECK_HOST: registry-center
orchestration:
  extraEnv:
    ORCH_HEALTHCHECK_HOST: orchestration-center
```

These overrides work via extraEnv. For DNS names, the chart adds a Pod-local loopback hostAlias so startup/readiness never depends on a Service's not-yet-ready endpoints. Use a dedicated probe/SAN name (normally the component's own Service name), not a shared remote model, registry or SQL hostname: the alias affects all DNS lookups in that Pod. Known cross-service/SQL collisions are rejected. Do not duplicate managed listener/authentication settings.
/health is minimal readiness, not proof of every business/model operation.

## Persistence and migration

RC/OC are single-instance Recreate, without OC HPA: events, schedulers and account sessions are process-local.
Upgrades interrupt service and revoke in-memory sessions. SQL does not make these services HA.
Separate retained ReadWriteOnce runtime PVCs hold data/log subdirectories. OC PreFlow, sandbox reports,
Stub templates and solution packages, and RC local audit records, remain files even in SQL mode.
Non-root init creates directories without recursively chowning old data; storage must support fsGroup.
Use existing writable claims or StorageClass when there is no provisioner; Pending Pods are not successful installs.

Before replacing old ephemeral Pods, stop writes and export data/log; back up SQL and PKI/Secrets.
Restore into separate claims and check UID permissions/checksums before deploying. Attaching an empty PVC is not migration.
Uninstall retains claims; deletion is operator-controlled. Follow CSI expansion rules; do not shrink volumes via Helm.

## Acceptance and troubleshooting

CI builds matching sources and runs real Compose combinations separately from render tests. Verify UI login,
change-password/re-login, public Token/logout/expiry, ownership/JWS/JWKS, workflow CRUD, sandbox/templates, audit,
SSE and file retention after replacement. Cover both SQL types and public/backend HTTP/HTTPS/mTLS/verify settings.
Compose passes cannot prove real Kubernetes PVC, non-root Secret permissions, SAN probes or migration.

- Render failures: missing references/tags, invalid port, namespace mismatch, replicas or identical database names.
- Startup failures/503: selected provider, signing material, SQL bootstrap secret; never disable authentication to hide failure.
- TLS failures: distinguish CA/hostname verification from required client identity; verify=false does not supply a certificate.
- Pending PVC: inspect provisioner/capacity/fsGroup, not an ephemeral workaround.
- 401 after change-password/restart: login again; 403 is permission, not refresh. Never replay writes blindly.
- UI caching: index.html is no-store; only content-hashed assets are immutable. API/SSE compression stays off.
  X-XSS-Protection is intentionally absent because the legacy filter is deprecated.
