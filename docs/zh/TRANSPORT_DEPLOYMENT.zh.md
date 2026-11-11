# HTTP/HTTPS与数据库部署契约

English: [Deployment contract](TRANSPORT_DEPLOYMENT.md).

离线Kubernetes Chart与安装器在 `offline-install` 线上持续维护：它们使用独立模板，现已为离线部署实现账号（OC管理员初始化）、模型（完整models.yaml挂载）与前端（openan-portal）契约。参见 [offline-install/QUICKSTART.md](offline-install/QUICKSTART.md)。

本次范围为 `online-install` 在线Chart、共享镜像构建脚本，以及新增整改的单机 `offline-install-compose`；`offline-install` 离线Kubernetes线按上段所述另行维护。下文Helm字段针对在线Chart；Compose使用独立的 [部署指南](offline-install-compose/README.md) 和配置模板。

本版本Chart必须配合包含本次部署整改的RC/OC镜像。不能将旧v1.0.0镜像视作已包含新功能。先构建并明确指定镜像tag，再部署；源码Git ref与镜像tag分开。

## 术语约定

- RC（Registry Center，注册中心）
- OC（Orchestration Center，编排中心）
- JWS（JSON Web Signature）
- SSE（Server-Sent Events）
- HPA（Horizontal Pod Autoscaler）
- PreFlow（预置工作流）
- PSOP（按需补充定义）

## 配置职责

- database.type：`postgresql`是唯一内置后端；其余任何类型（mysql、gauss、oracle…）均为外部SQL，类型原样透传给服务（PERSISTENCE_MODE）。postgresql.enabled只决定是否创建内置PostgreSQL。服务侧必须支持该类型（registry-center：file、sqlite、postgresql、gauss、mysql；orchestration-center 当前：file、postgresql、mysql）。
- database.registry / database.orchestration分别配置库名、用户和密码Secret。两个服务不要共用业务库。
- 内置PostgreSQL当前用postgresql.existingSecret的postgres-password同时初始化业务用户；独立业务密码Secret仅用于外部数据库，不能配置成与初始化密码不同。生产推荐外部数据库和独立用户凭据。
- registry.tls / orchestration.tls分别控制各自侦听协议及客户端证书校验。
- 认证与TLS独立。RC的token身份复用已有static_bearer/oauth2_jwt/oauth2_introspection/custom provider；主端口实例与第三方接入端口实例不共用异步客户端。OC公开接口使用与网页登录相同的账号：POST /api/v1/auth/token获取Token，业务请求显式携带账号Bearer，Cookie单独携带不授权公开API。
- registry.signing独立控制AgentCard标准JWS签名。off是明确禁用，非“自动生成”。auto仅用于演示；生产使用secret。
- 模型定义通过完整models.yaml ConfigMap注入，秘密通过runtimeSecret或各能力existingSecret注入。自定义provider/auth字段请使用modelsConfigMap，内置llm快捷配置仅用于OpenAI-compatible。
- frontend.type选择统一网页入口：portal（默认）或workflow-designer；workflow-designer回退时通过frontend.backendTls校验OC后端。

`database.port` 仅作用于外部SQL，null/省略时按类型选择PostgreSQL 5432或MySQL 3306；其余外部类型必须显式指定1..65535整数端口（无默认端口）。内置PostgreSQL使用 `postgresql.port`。端口须为1..65535整数，两服务启用时拒绝同外部库名。`namespace` 必须与Helm `--namespace` 一致；应用镜像tag必填，不再默认旧v1.0.0。

默认模板不携带可用密码、机器Token或厂商密钥。缺失必要Secret、HTTP+客户端证书校验等错误组合会明确拒绝渲染/启动。

## 现网：外部MySQL + HTTPS + 不校验客户端证书

> ![输入图片说明](figures/icon-note.gif) **说明：**<br />示例只包含Secret名称，没有真实敏感值：

```yaml
postgresql:
  enabled: false
database:
  type: mysql
  host: mysql.example.internal
  port: 3306
  registry:
    name: registry_center
    username: registry
    existingSecret: rc-db
    passwordKey: db-password
  orchestration:
    name: orchestration_center
    username: orchestration
    existingSecret: oc-db
    passwordKey: db-password
registry:
  runtimeSecret: rc-runtime
  credentialSecret: rc-credentials
  identityMode: token
  authMode: static_bearer
  signing:
    mode: secret
    existingSecret: rc-signing
  tls:
    enabled: true
    verifyClient: false
    mode: secret
    existingSecret: rc-tls
  ingressClientSecret: rc-ingress-trust
orchestration:
  runtimeSecret: oc-runtime
  registryClientSecret: oc-registry-trust
  clientVerifyServer: true
  tls:
    enabled: true
    verifyClient: false
    mode: secret
    existingSecret: oc-tls
  ingressClientSecret: oc-ingress-trust
frontend:
  backendTls:
    verifyServer: true
    existingSecret: frontend-trust
```

必须同时覆盖registry/orchestration/frontend.image.tag为本次镜像版本。省略的llm配置仍是占位符，需改为实际模型或指定已有modelsConfigMap。

关闭对端校验有不同含义，不能混作一个开关：

- tls.verifyClient=false：服务端不要求调用方证书，应用Token鉴权仍有效。
- orchestration.clientVerifyServer=false：OC不校验RC的服务端证书。
- frontend.backendTls.verifyServer=false：前端nginx不校验OC的服务端证书。
- ingress.backendVerifyServer=false：ingress-nginx不校验后端证书。
- 关闭服务端校验并不会取消后端的客户端证书要求；启用mTLS时仍必须提供客户端证书。
- `orchestration.clientVerifyServer=false` 时Chart不注入 `REGISTRY_CA_FILE`，即使提供了含CA的registryClientSecret；客户端证书和密钥仍按RC的mTLS要求独立注入。不能把“关闭校验 + 仍指定CA”当成有效组合。

> ![输入图片说明](figures/icon-note.gif) **说明：**<br />推荐保留服务端校验并挂载CA。确需跳过时显式设置，不依赖隐藏默认值。

## Secret文件与环境变量

| Secret | 内容 |
|---|---|
| rc-db / oc-db | db-password |
| rc-runtime | INTEGRATION_FINGERPRINT_KEY；静态模式还需 INTEGRATION_TOKEN_HMAC_KEY；OAuth2 模式按 RC 公共模板提供凭据和配置引用 |
| rc-credentials | integration_credentials.conf，保存 Token 的 HMAC-SHA256 摘要、identity、role，不能保存明文 Token |
| oc-runtime | OC_ADMIN_INITIAL_PASSWORD（SQL 初次启动）；REGISTRY_ACCESS_TOKEN（访问 RC）；模型密钥变量 |
| rc-tls / oc-tls | server.cer、server_key.pem、cert_pwd、trust.cer；mTLS 探针还需 probe-client.cer、probe-client.key |
| rc-signing | sign.cer、sign_key.pem、cert_pwd |
| oc-registry-trust | trust.cer；RC mTLS 时还需 client.cer、client_key.pem（加密客户端私钥通过 REGISTRY_CLIENT_KEY_PASSWORD 提供口令） |
| frontend-trust | trust.cer；OC mTLS 时还需 client.cer、client_key.pem（nginx 客户端私钥需可直接加载） |
| rc/oc-ingress-trust | ingress-nginx 格式 ca.crt；mTLS 还需 tls.crt、tls.key |

签名私钥可以是未加密key + 空cert_pwd，服务会归一为None；TLS私钥要求遵循服务现有证书校验契约（加密私钥、非空合规口令、足够强度）。两者不能混用规则。

静态Token凭据文件示例（token_hash必须为以INTEGRATION_TOKEN_HMAC_KEY为密钥计算的HMAC-SHA256十六进制摘要）：

```properties
credential.oc.identity=orchestration
credential.oc.role=partner_service
credential.oc.token_hash=<64-character-HMAC-SHA256>
```

用于注册、更新和删除AgentCard的身份应配置vendor_agent，所有者取验证后的identity，不取归属说明owner。nms_oss可以进入管理接口，原有所有者校验仍保留。非管理身份在主端口仅开放公开发现与供应商自己的卡片写操作；订阅/审计等请使用已授权的integration操作。

## TLS与公开地址

生产证书由企业CA提供。演示可用两个服务自己的generate_selfsign_cert.py：serverAuth生成TLS bundle，dataSigning生成签名bundle，--issue-client生成客户端身份。不要再使用Helm的空口令TLS自动生成逻辑。

SAN应包含对应Service DNS，以及探针使用的127.0.0.1；或设置REGISTRY_HEALTHCHECK_HOST / ORCH_HEALTHCHECK_HOST为证书包含的专用探针DNS名（通常是对应服务名）。Chart会把此DNS名通过Pod hostAliases解析到本Pod的127.0.0.1，避免探针依赖尚未Ready的Service端点。该映射影响Pod内所有解析，不能复用远端模型、注册中心或SQL主机名；已知跨服务/SQL冲突会被拒绝。后端侦听0.0.0.0不是公开JWKS地址；可设置registry.publicBaseUrl为真正的HTTPS入口。HTTP使用预置可信公钥，不降低远程JWKS的HTTPS/SSRF约束。

Kubernetes TLS/签名文件使用只读subPath挂载，UID/fsGroup=10001，文件0440，镜像目录0700。Secret文件变化需滚动重启（subPath不会热更新），签名轮换还需同步可信公钥。auto签名升级使用lookup保留旧key，并兼容旧server.cer/server_key.pem名称；不要用离线template生成的随机Secret覆盖已有线上签名材料。

Chart自己生成的models.yaml和nginx配置带Pod checksum，Helm更新会触发滚动重启。外部modelsConfigMap内容更新不属于Helm输入，须由运维滚动重启；同样不能期待subPath文件热更新。

当前RC的legacy use_vectordb=true会切换成缺少权威SQL记录的向量专用模式，不能用于完整业务API。本Chart明确拒绝vectordb.enabled=true。SQL主存储加派生向量索引的完整实现是后续独立需求，本轮不宣称已提供该能力。

## HTTP模式

将两个tls.enabled改为false，verifyClient=false；RC保持token身份，OC保留用户和机器凭据。无需TLS Secret。签名与入站签名校验并不因HTTP自动关闭。HTTP仅适用于受信内网/演示，凭据会在链路明文传输。

Cookie的Secure以公共入口为准。前端/Ingress公共TLS启用时自动采用https；外部网关终止TLS时显式orchestration.publicScheme=https。应用不直接信任任意X-Forwarded-Proto。主机直连HTTPS而不使用该HTTP前端时也应显式配置publicScheme=https。

OC会话仍为进程内状态，当前仅支持replicas=1、HPA=false。RC的健康事件SSE listeners、事件唤醒及调度器同样是进程内的，共享SQL并不提供跨实例通知协调，所以RC也仅支持replicas=1。Chart对多副本配置失败关闭，不宣称支持服务级HA；不能通过直接kubectl scale绕开该边界。

## 运行态文件持久化与升级

MySQL/PostgreSQL只覆盖SQL数据。OC的PreFlow、沙箱报告/Stub模板和方案包仍写入 `data/`；RC的本地安全审计仍写入 `log/audit/`。两个服务分别拥有独立的runtime PVC，以 `data`、`log` 子目录挂载到 `/opt/<service>/data`、`/opt/<service>/log`。禁止把两服务指向同一个claim。

```yaml
registry:
  replicas: 1
  persistence:
    existingClaim: ""  # 空：创建 registry-center-runtime；已有卷则填写同 namespace 的 claim
    size: 5Gi
    storageClassName: "" # 空：集群默认；"-"：显式无 StorageClass；或指定支持 fsGroup 的类
orchestration:
  replicas: 1
  persistence:
    existingClaim: ""
    size: 10Gi
    storageClassName: ""
```

自动创建的卷为ReadWriteOnce，并带 `helm.sh/resource-policy: keep`；卸载保留卷，备份/销毁由运维显式管理。已有claim不由Chart创建或删除；应独立且可由UID/GID 10001写入。init container使用同一个应用镜像、非root用户创建两个子目录，不对已有业务数据递归chown。存储驱动需支持fsGroup；无默认provisioner时应预建claim或配置StorageClass，不能把Pending Pod当作已安装成功。

RC/OC Deployment使用 `Recreate`，升级期间会短暂停服并清空内存会话。目的是避免同一卷的多个应用进程并发写审计/文件，并避免RWO卷在跨节点升级时因旧Pod占用而无法挂载；这不是零停机HA。

> ![输入图片说明](figures/icon-warning.gif) **警告：**<br />旧部署升级不能仅新挂一个空PVC。在升级前停止业务写入，并在删除/替换旧Pod之前导出其 `data/`、`log/`；同时备份SQL、独立PKI和Secret。将导出文件按子目录恢复到新claim，确认UID 10001权限、大小和校验和，然后使用 `existingClaim` 部署。若旧Pod已被删除且没有备份，其容器层数据无法靠这次修复恢复。PVC容量扩展需遵循StorageClass能力；不要尝试用Helm缩小已有卷。

公共工作流模板改为镜像内 `samples/workflow_templates/` 的只读资源，不再放在运行态 `data/`。自定义旧模板应人工审查迁入发布资源目录、重建镜像；不要把整个本地data目录打包。

## 构建、部署与验证

```bash
# 为每个组件使用准确的源码 SHA；两个仓库的 SHA 不相同。
bash build/build.sh registry --source-ref <RC_SHA> --tag <IMAGE_TAG> --platforms linux/amd64 --no-push
bash build/build.sh orchestration --source-ref <OC_SHA> --tag <IMAGE_TAG> --platforms linux/amd64 --no-push
# 需要多架构时显式推送；多架构 --no-push 会拒绝，不会偷偷 --push。
bash online-install/install.sh --skip-build --skip-infra --values /path/to/deployment.yaml
helm lint online-install/openan-chart -f /path/to/deployment.yaml
helm template openan online-install/openan-chart -f /path/to/deployment.yaml
```

install.sh恢复可跳过的构建、审核后的本地基础设施Chart与交互引导阶段；--values跳过交互，--skip-build/--skip-infra使用已准备环境。秘密静默输入并经stdin创建Secret，不写入生成的values；生产推荐预备Secret + 原生Helm路径。不会在业务镜像启动samples。镜像中保留公共solution_packages示例数据，但不携带样例账户和Agent服务。数据库不存在时按服务已有创建权限/迁移策略处理，生产推荐DBA预建。

CI分别验证Helm矩阵、错误配置和构建失败退出；RC已有Linux容器smoke，OC的真实启动/API回归可独立执行。上线验收必须另外运行真实镜像+MySQL+nginx/Ingress，覆盖登录Cookie、AgentCard CRUD/JWS、工作流CRUD/SSE、证书缺失/错误密码、无/错Token、断连和重启。Helm渲染通过不是集群实测。

## 单机离线Compose

浏览器入口不应借用Nginx的上游证书获得用户权限。在线Chart和Compose代理转发 `/api/orchestrate/api/v1/*`，保留Authorization，并覆盖 `X-OpenAN-Browser-Gateway: 1`；后端只把它作为限制标记，不作为身份。公开API必须携带原账号Bearer；网页内部接口保持HttpOnly Cookie。在线Chart编排服务Ingress的直连入口同样验证账号Bearer。自定义frontend.nginxConfig必须保留标记覆盖与原始Authorization；未配用户认证时代理返回503。

关闭对端证书校验与关闭业务鉴权不同：后端HTTPS + verifyClient=false配合调用方verify=False可以建立TLS；合法Token/用户会话仍必需。后端verifyClient=true时，调用方verify=False不会取消客户端证书要求。生产推荐配置可信CA。

在线Chart与Compose显式设置 `ORCH_EXTERNAL_AUTH_MODE=user`，包括后端开启mTLS的场景；无需固定ORCH_API_TOKEN。Ingress证书只证明代理，不能代替原始账号Token。改密、删除账号撤销该账号所有会话，重启后需重新登录；SQL初始化账号必须先在网页完成强制改密。配套镜像必须包含 /api/v1/auth/token和user认证模式；旧镜像需先升级，不能只升级安装模板。

使用 `offline-install-compose/build/build-offline.sh` 将匹配服务源码构建的镜像、前端静态文件与公共模板打成白名单发布包；不会复制本地config.env、runtime、PKI或业务数据。离线端不拉镜像，校验失败阻止安装，配置按字面解析而不执行shell。

前端由 `FRONTEND_TYPE` 选择（portal默认）；portal镜像待openan-portal#11发布，未包含该镜像的发布包仅携带workflow-designer前端。

数据库可选外部/内置MySQL或PostgreSQL，两个服务使用独立业务库和凭据。应用各单实例，Nginx是唯一公开入口，公共协议、两个后端协议与客户端证书校验分别配置。TLS、签名和Token身份保持独立。全量models.yaml只读挂载，密钥由私有runtime env注入。生成的runtime/compose.json含敏感值，不应提交或上传。

Linux CI构建真实镜像与离线发布包，验收脚本包含十组MySQL/PostgreSQL、HTTP/HTTPS、公共TLS终止、RC/OC混合协议及mTLS场景。检查返回的AgentCard/PSOP关键内容、更新读回、删除确实不存在，并在后端IP替换后验证SQL、PreFlow、沙箱报告/Stub模板、方案包和旧审计字节保留。文件、目录由真实存储组件生成，不冒称完成真实模型/工作流执行。只有对应提交的容器job通过，才能认定这些场景已验证；该结果不替代离线Kubernetes、外部IAM/模型、arm64或完整工作流/SSE的验收。卸载保留SQL卷和应用数据，旧目录数据需显式备份/恢复迁移。
