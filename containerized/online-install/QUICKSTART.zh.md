# OpenAN容器在线部署快速开始

English: [Quickstart](QUICKSTART.md) · [完整部署契约](../TRANSPORT_DEPLOYMENT.md)

本文档面向具备Kubernetes集群访问权限的集群运维/评估人员，适用于首次部署、在线快速评估阶段：通过一条交互式安装命令在线拉取应用镜像与固定版本的基础设施清单，最小化搭建一个可登录的OpenAN平台。面向生产环境与CI/CD自动化的完整部署（含网络、TLS、SQL、存储与安全基线）请遵循[完整部署契约](../TRANSPORT_DEPLOYMENT.md)。

## 前置条件

- 执行节点：一台可通过 `kubectl` 访问目标集群的运维工作机；执行用户：普通用户即可——向导自动安装工具到系统路径时会请求sudo；从源码构建镜像时需具备Docker守护进程权限（docker组）
- Linux或macOS，可访问互联网（应用镜像与固定版本的基础设施清单在线拉取）
- 可通过 `kubectl` 访问的Kubernetes集群（v1.25+）
- Helm 3.14+（3.14.2已验证，chart未使用更高版本特性）与python3
- 集群内SQL与运行时claim需要StorageClass——没有默认StorageClass时，可接受向导的本地hostPath回退（仅评估用途、单节点）
- 未经确认不安装任何主机工具：缺少kubectl/helm（以及Linux上源码构建所需的Docker）时，可在交互确认后用官方安装器自动安装；python3与Docker Desktop需手动安装
- 交互式向导从终端读取密钥（getpass），需在真实TTY中运行 `./install.sh`；CI/自动化请使用 `./install.sh --values` 并预先创建Secret

## 第1步：交互式安装

**预估耗时**：在线拉取基础设施清单与应用镜像并完成部署约需5~15分钟，具体时间与实际网络情况有关。

```bash
cd containerized/online-install
./install.sh
```

安装器按四个阶段编排（`./install.sh --help` 查看简要流程）。**预期成功回显**：安装器执行成功后打印「Install complete」横幅及「Platform: <scheme>://<host>/」访问地址；判断标准：出现该横幅即成功，否则按失败提示排查（可参见「验证与故障排查」节）。release与命名空间默认为 `openan`、不再交互询问（可用 `--release`/`--namespace` 覆盖）；从源码构建改为参数驱动（`--tag` 加 `--registry-release` 与 `--orchestration-release`，先 `docker login` 目标仓库），不再是提问。

- **[1/4] 预检** —— 检查kubectl、helm、python3，确认集群可达，打印kubectl客户端版本及所用的release/命名空间；缺少kubectl/helm时可确认后自动安装（官方安装器，python3仍需手动）。
- **[2/4] 基础设施** —— 同时检测到MetalLB与ingress-nginx时跳过；否则可安装固定版本的MetalLB v0.16.1与ingress-nginx controller-v1.15.1清单，随后在裸金属上提示输入MetalLB IP池（如 `192.168.1.200-192.168.1.250`，留空跳过）。
- **[3/4] 应用** —— 向导（configure.py）依次询问组件、应用镜像tag（必填无默认值：旧 `v1.0.0` 镜像与当前chart不兼容；可共用一个，也可为registry/orchestration/frontend分别指定）、模型（按对话式LLM答案生成并做连通性探测，每个组件还可选填 **embed/rerank模型**用于语义检索，orchestration另可选填 **A2A-T SDK协商模型** / 已有ConfigMap）、签名（自动演示 / 已有Secret）以及初始管理员密码（8+ 字符，含大小写/数字/特殊字符；选择部署orchestration时询问）与PostgreSQL密码（播种应用用户共用）；仅选择orchestration时，向导还会询问外部agent registry URL（http(s)://...）。SQL类型/主机、存储与Ingress主机名不再询问：评估模式固定使用集群内PostgreSQL；存储自动选用集群默认StorageClass，没有时自动回退为节点固定的本地hostPath PV（单节点）；Ingress固定空host（catch-all），直接用LB IP访问（基于域名的路由与HTTPS请使用审核过的values；Kubernetes拒绝IP主机）。秘密仅经kubectl stdin写入Kubernetes Secret；向导只生成非秘密的 `deployment.generated.json`，不覆盖已有文件或Secret；失败时打印具体原因（不含秘密值）。若中途失败，请核对已创建的Secret/ConfigMap，升级时改用 `--values` 继续。向导重跑且 `deployment.generated.json` 已存在时，会询问是否重新生成（默认保留文件并打印 `--values` 重部署命令）。
- **[4/4] 部署** —— 先打印非秘密的部署汇总（release/命名空间、组件、镜像tag、SQL、存储、模型、签名、Ingress host）并确认后，才执行 `helm upgrade --install --wait`；取消部署会保留生成的values与向导已创建的Secret/ConfigMap（向导非事务性，可用 `--values` 复用重部署）。选择部署orchestration时，还会询问是否在orchestration-center Pod内启动 **Agent示例服务**（演示用agent）：通过 `kubectl exec` 运行 `samples/start_agents_server.py`，健康检查端口8903，日志位于 `/tmp/agents-server.log`（回答no跳过；它仅为演示便利，不是chart资源，Pod重启后不保留）。使用向导中配置的管理员账户登录。

## 第2步：验证部署

```bash
kubectl -n openan get pods,svc,ingress
```

- Pod：`registry-center-*`、`orchestration-center-*`、`openan-frontend-*`（集群内SQL另有 `openan-postgres-0`）应达到 `Running`。
- Service：`openan-frontend`（NodePort）、`registry-center`、`orchestration-center`、`openan-postgres`。
- Ingress：`openan-frontend-ingress`、`openan-orchestration-ingress`、`openan-registry-ingress`，`ADDRESS` 列显示负载均衡地址。

## 第3步：访问平台

优先使用负载均衡IP：

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller   # EXTERNAL-IP
```

访问 `http://<EXTERNAL-IP>/`（向导固定使用空host的catch-all Ingress，无需配置DNS；基于域名的路由请使用审核过的values）。没有负载均衡IP时，安装器打印NodePort回退地址：

```bash
NODE_PORT=$(kubectl -n openan get svc openan-frontend -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "http://${NODE_IP}:${NODE_PORT}/"
```

使用向导中配置的管理员账户登录：默认管理员用户名为 `admin`（OC播种的初始管理员账号），密码为向导中设置的初始管理员密码；登录后请在Web界面修改密码，再调用API。

## HTTPS部署

1. **先配置MetalLB IP池**：必须存在可路由的IP段（即第 [2/4] 阶段提供的同一IPAddressPool），Ingress才能获得稳定IP；将DNS或 `/etc/hosts` 记录指向该IP。
2. **生成证书**（使用仓内工具；需要registry-center源码检出与Python `cryptography` 库）：

   ```bash
   pip install cryptography    # 一次性，安装在运行工具的机器上
   python3 tool/gen_certs.py --registry-center-src <registry-center-src> \
       --out ./certs --namespace openan \
       --ingress-host openan.example.com [--ingress-ip <LB-IP> ...]
   # 输出目录树：
   #   certs/ca/{ca.cer, ca_key.pem, cert_pwd}
   #   certs/registry-center/{server.cer, server_key.pem, trust.cer, cert_pwd}
   #   certs/orchestration-center/{server.cer, server_key.pem, trust.cer, cert_pwd}
   #   certs/ingress/{tls.crt, tls.key, trust.cer}
   ```

   `--ingress-ip` 可重复指定 —— 把客户端会访问的地址都签进去（MetalLB VIP、NodePort场景的节点IP）。纯IP入口（直连 `https://<IP>`）则去掉 `--ingress-host`，仅传 `--ingress-ip <IP>`（默认的 `openan.test` 只是占位）。

3. **创建证书Secret**：

   ```bash
   kubectl create namespace openan 2>/dev/null || true
   kubectl -n openan create secret tls openan-tls \
       --cert=certs/ingress/tls.crt --key=certs/ingress/tls.key
   # 集群内服务 TLS 还需：
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

4. **在values中启用**：`ingress.host: openan.example.com`（纯IP入口则填IP，直连 `https://<IP>`），以及 `ingress.tls.enabled: true`、`ingress.tls.secretName: openan-tls`；开启集群内服务TLS时再加 `registry.tls.existingSecret: openan-rc-tls` / `orchestration.tls.existingSecret: openan-oc-tls`。
5. **ingress-nginx默认证书**（可选，服务于未匹配的host）：在 `ingress-nginx` 命名空间创建Secret，并为控制器设置参数 `--default-ssl-certificate=ingress-nginx/<secret>`：

   ```bash
   kubectl -n ingress-nginx create secret tls default-tls --cert=tls.crt --key=tls.key
   kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json \
       -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-ssl-certificate=ingress-nginx/default-tls"}]'
   ```

6. **集群内服务TLS / mTLS**：参见[完整部署契约](../TRANSPORT_DEPLOYMENT.md)。

## 自动化 / 生产（原生Helm）

**预估耗时**：在线拉取基础设施清单与应用镜像并完成部署约需5~15分钟，具体时间与实际网络情况有关。

按部署契约准备Kubernetes、Helm、Ingress/存储、SQL数据库以及模型/凭据/PKI引用。
复制 [deployment.yaml.example](deployment.yaml.example)，填写全部镜像tag与非密钥字段：

```bash
helm lint openan-chart --namespace openan -f deployment.yaml
helm template openan openan-chart --namespace openan -f deployment.yaml > rendered.yaml
helm upgrade --install openan openan-chart --namespace openan --create-namespace -f deployment.yaml --wait --timeout 10m
```

判断标准：`helm lint` 无Error输出即为通过；`helm upgrade --install --wait` 返回0且Pod全部Ready为部署成功；失败时查看helm报错信息，并按「验证与故障排查」节处理。

namespace必须与values一致。不要把密钥写入values/--set；若刻意使用遗留内联字段，渲染输出可能包含密钥，须妥善保护。在真实公网入口验收API，而非仅探测。

`install.sh --values` 是面向已准备环境与CI的非交互变体
（`--skip-build` / `--skip-infra` / `--values ...` / `--release` / `--namespace`）；其基础设施阶段要求运维审核的本地MetalLB/ingress-nginx Chart包与values，而非在线固定版本清单。

## 验证与故障排查

安装Python/PyYAML/pytest、Helm与Bash后，在**仓库根目录**执行 `python -m pytest tests/ -q`（tests/ 与containerized/ 同级，不在其内部）。
缺少工具会明确跳过相关测试；渲染通过不等于容器/集群验收。
CI单独构建真实Compose矩阵。认证/TLS/SQL/PVC与前端诊断见[验收与故障排查](../TRANSPORT_DEPLOYMENT.md#acceptance-and-troubleshooting)。单实例升级会短暂中断服务。

在残留的本地存储上重装会保留旧数据：`openan-postgres-pv` 中残留的旧 `pgdata` 会让集群内SQL
沿用旧数据库密码（postgres socket仍可连接，但TCP报 `password authentication failed`）。请在
`uninstall.sh` 中对 "Remove persistent data" 回答yes——它会检测并清理所有OpenAN PV的hostPath
数据——或手工删除节点上的 `/data/openan-*`。向导在配置存储前也会提示检测到的残留PV。
