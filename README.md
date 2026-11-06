# docker-zerotier-planet（安全加固版）

在 Docker 中自建 **ZeroTier 行星服务器（planet）** 和 **网络控制器（ztncui）**。
本项目是 [xubiaolin/docker-zerotier-planet](https://github.com/xubiaolin/docker-zerotier-planet)
的维护分支，已升级到 **ZeroTier One 1.16.2**（截至 2026-11-06 核查，上游最新稳定版仍是 1.16.2），并针对上游 issue 中的安全问题做了系统性加固。

> **许可证提醒（重要）**
> ZeroTier 1.16 起把 controller 移到了 `nonfree/`，采用 *ZeroTier SOURCE-AVAILABLE
> LICENSE*，**仅允许个人非商业用途**（以及学生教育/学术、30 天以内的评估）。
> 本镜像因此以 `ZT_NONFREE=1` 构建。公司、政府/军队、非营利组织或任何付费服务
> 场景**不得**使用本镜像中的 controller。详见 [NOTICE](NOTICE) 与
> `/usr/share/licenses/zerotier/`。

## 相比上游的改动

### 安全（对应 issue #215 的五项）

| 问题 | 处理方式 |
| --- | --- |
| 默认 `admin/password` 凭据 | 首次启动生成 24 字符随机密码，写入 `config/admin-password`（0600），首次登录强制改密，改密后自动删除该文件 |
| 文件服务器路径穿越 | 仅允许 `planet` 与 `*.moon`；`realpath` 必须仍位于 `dist/` 内；拒绝符号链接逃逸、`..`、编码穿越 |
| 下载密钥放在 URL query | 默认只接受 `Authorization: Bearer` / `X-Api-Key`；32 字节随机密钥持久化到 0600 文件；`?key=` 仅在显式设置 `ALLOW_QUERY_KEY=1` 时启用 |
| 依赖未锁版本 | ZeroTier 固定到 `1.16.2` + commit 校验；ztncui 固定 commit；npm 使用提交的 lockfile 与 `npm ci --omit=dev --ignore-scripts` |
| 管理界面/文件服务器明文 HTTP | 默认 TLS（自签 ECDSA P-256，SAN 含服务器 IP），TLS 1.2+、HSTS；可挂载自有证书 |

### 其他 issue

- **#213**：1.16 删除了 `attic/world`，旧 `mkworld` 无法编译。已按 `node/World.hpp` + `ECC` API 重写 `mkworld`，并用同一身份签名/校验生成的 planet。
- **#200**：`deploy.sh` 的端口提示不再被命令替换吞掉，端口严格校验 `1-65535`。
- **#180**：`docker run` 前先 `mkdir -p` 数据目录，兼容 podman。
- **#196**：镜像内提供 `/usr/sbin/zerotier-cli`、`zerotier-idtool`，可直接 `docker exec`；不再需要 `/bak` 模板。
- **#208**：`activeBridge`/`auth` 严格按布尔值处理，字符串 `"false"` 不再被当成真。
- **#185**：用带 TTL 的 `BoundedMemoryStore` 替代会告警的默认 MemoryStore。
- **#163**：不再自己生成 authtoken，而是等待 ZeroTier 生成后读取，避免 controller API 401。
- **#216**：提供 `build.sh` 多架构构建与本地 `Dockerfile`，不再依赖上游 Docker Hub 镜像；镜像可自行推送到 GHCR。
- **#157**：可设置 `HTTPS_HOST=::` 让管理界面同时监听 IPv6（默认 `0.0.0.0`）。
- **#205**：仅构建 `linux/amd64` 与 `linux/arm64`，不提供 armv7。

### 其他加固

- 容器内进程以 uid/gid 1000 运行；entrypoint 只在修正卷权限时短暂使用 root。
- 删除 `set -x`，日志不会出现 authtoken、controller token 或下载密钥。
- ztncui：CSP、HSTS、SameSite/HttpOnly/Secure Cookie、同源 Origin/Referer 校验、
  登录限流、开放重定向修复、原型链用户名 DoS 修复、会话固定修复、错误页不泄漏堆栈。
- 原生 `argon2` 改为纯 WASM `hash-wasm`，无需 node-gyp，并统一使用 Argon2id（64 MiB）。
- ztncui 前端与依赖整体重写（0.9.0）：移除 Bootstrap 3 / jQuery / got / ip-address /
  express-validator，改用 `node:net` 实现 IP/CIDR 校验、Node 24 原生 `fetch` 调用
  controller API，并适配 1.16 的 `POST /controller/network`；生产依赖 `npm audit`
  在 2026-11-06 为 0 告警。
- 管理界面重做为响应式卡片/表格布局，手机端（≤720px）表格自动变为带字段标签的卡片、导航折叠、工具栏横向滚动、触控目标 ≥42px；无内联脚本与样式（CSP 只允许 `'self'`），
  成员授权/桥接改为显式下拉框，保持 #208 的严格布尔语义。
- 密码文件原子写入、0600；已设置密码的账户只能由本人修改；管理员可为新建用户设置初始密码；不能删除自己或最后一个管理员。
- `docker-compose.yml` 默认 `read_only`、`no-new-privileges`、`tmpfs /tmp`。
- 增加 `SECURITY.md`、漏洞披露流程、依赖锁定和回归测试。

## 快速开始

### 要求

- Docker 24+ / Docker Compose v2；`amd64` 或 `arm64`
- 一台有公网 IPv4 的 Linux 主机（NAT 后需要端口映射）
- 放行 **UDP 9994**；管理界面 **TCP 3443**；planet 下载 **TCP 3000**
- 约 512 MiB 内存、1 GiB 磁盘

### 方式一：脚本

```bash
git clone https://github.com/ban-sky/docker-zerotier-planet.git
cd docker-zerotier-planet
./deploy.sh
```

脚本会询问公网 IP 和端口，创建 `data/` 目录；本地没有镜像时先构建，然后启动容器并等待健康检查。
已有同名容器时会先询问是否替换；数据目录不会被删除。

### 方式二：Compose

```bash
git clone https://github.com/ban-sky/docker-zerotier-planet.git
cd docker-zerotier-planet
cat > .env <<'EOF'
IP_ADDR4=203.0.113.10
# IP_ADDR6=2001:db8::10
EOF
# 首次使用本地构建
docker compose up -d --build
```

### 首次登录

```bash
sudo cat data/config/admin-password
```

打开 `https://<公网IP>:3443`，浏览器会提示自签证书，确认后使用
`admin` + 上述密码登录。系统会立即要求设置新密码；改密成功后
`admin-password` 文件会被删除。

### 分发 planet

最安全、最简单的方式是直接从宿主机复制（不需要下载密钥）：

```bash
cp data/dist/planet ./planet
```

或通过文件服务器下载（密钥在 `data/config/file_server.key`）：

```bash
curl -fsS \
  -H "Authorization: Bearer $(sudo cat data/config/file_server.key)" \
  https://<公网IP>:3000/planet -o planet
```

把 `planet` 放到客户端的数据目录并重启 ZeroTier：

| 系统 | 路径 |
| --- | --- |
| Linux | `/var/lib/zerotier-one/planet` |
| Windows | `C:\ProgramData\ZeroTier\One\planet` |
| macOS | `/Library/Application Support/ZeroTier/One/planet` |
| Android/iOS | 使用支持自定义 planet 的客户端导入 |

重启后执行 `zerotier-cli listpeers`，应能看到你的 planet 节点，而不是官方 planet。

### 使用 moon（可选）

`data/dist/` 下同时生成 `<moon-id>.moon`。将 moon 文件复制到客户端的
`moons.d/`，然后：

```bash
zerotier-cli orbit <moon-id> <moon-id>
```

### 创建网络并加入

1. 在 ztncui 的 **Networks → Add network** 创建网络，记下 16 位 network ID。
2. 客户端执行 `zerotier-cli join <network-id>`。
3. 回到 ztncui 勾选成员授权（Auth），必要时设置 IP、路由、规则。
4. 客户端 `zerotier-cli listnetworks` 应为 `OK PRIVATE`。

## 配置

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `IP_ADDR4` | 自动探测内网 IPv4 | **必须设为客户端可达的公网 IPv4 或域名**；写入 moon/planet |
| `IP_ADDR6` | 空 | 可选公网 IPv6 |
| `ZT_PORT` | `9994` | ZeroTier UDP 端口（容器内固定 9994） |
| `API_PORT` | `3443` | ztncui HTTPS 端口（容器内固定 3443） |
| `FILE_SERVER_PORT` | `3000` | planet 下载端口（容器内固定 3000） |
| `TLS_ENABLED` | `1` | `0` 关闭 TLS（**不推荐**，凭据会明文传输） |
| `TLS_CERT` / `TLS_KEY` | 自签证书 | 挂载自有证书的容器内路径 |
| `FILE_KEY` | 自动生成 | 至少 32 字符；设置后覆盖 key 文件 |
| `ALLOW_QUERY_KEY` | `0` | 允许旧的 `?key=` 下载方式 |
| `REGENERATE_PLANET` | `1` | 每次启动重新生成 planet（身份不变） |
| `APP_UID` / `APP_GID` | `1000` | 运行服务的 uid/gid |
| `HTTPS_HOST` | `0.0.0.0` | 设为 `::` 可同时监听 IPv6 |
| `TRUST_PROXY` | 空 | 反向代理层数，如 `1`；启用后按 `X-Forwarded-For` 限流 |

端口通过 `docker run -p` / Compose 映射；容器内部端口固定，便于文档与健康检查。

### 使用自有证书

```bash
mkdir -p data/config/tls
cp fullchain.pem data/config/tls/fullchain.pem
cp privkey.pem   data/config/tls/privkey.pem
docker compose restart
```

证书需包含 `IP:<公网IP>` 或客户端使用的域名 SAN。若用 Nginx/Caddy 反代，
建议只暴露反代端口，并设置 `TRUST_PROXY=1`；此时可把 `API_PORT`/`FILE_SERVER_PORT`
映射到 `127.0.0.1`。

### 数据与备份

| 路径 | 内容 |
| --- | --- |
| `data/one/` | ZeroTier 身份、controller 数据库、authtoken、moon |
| `data/config/` | ztncui 密码库、session secret、TLS 证书、下载密钥、初始密码 |
| `data/dist/` | 可公开分发的 `planet` 与 `.moon` |

**`data/one/identity.secret` 是 planet 的根身份**，丢失后所有客户端必须更换 planet；
请离线备份 `data/one/` 与 `data/config/`（其中含密钥，注意加密保存）。
升级镜像不会修改这些卷。

## 从上游版本迁移

如果当前运行的是 `xubiaolin/docker-zerotier-planet`，可以直接用迁移脚本升级到本分支。
脚本会保留 ZeroTier 身份、controller 数据库、authtoken、planet/moon 与 ztncui 账户，
并在新容器健康后才会删除旧容器；失败会自动恢复备份并重新启动旧容器。

```bash
# 先查看计划，不做任何修改
sudo ./scripts/migrate-from-upstream.sh --dry-run

# 正式迁移（默认容器名 myztplanet，自动从容器挂载推断数据目录）
sudo ./scripts/migrate-from-upstream.sh

# 容器名或数据目录不是默认值时
sudo ./scripts/migrate-from-upstream.sh --name myztplanet --data /path/to/data/zerotier

# 旧数据在 /root，新仓库在 /opt，并希望把数据也搬到新目录
sudo ./scripts/migrate-from-upstream.sh \
  --data /root/docker-zerotier-planet/data/zerotier \
  --target-data /opt/docker-zerotier-planet/data/zerotier
```

`--target-data` 会把旧 `config`、`dist`、`one` 复制到新目录，并让新容器使用新目录；
旧数据保持不动，确认新部署正常后再手工归档或删除。目标目录必须不存在或为空。

脚本会：
- 备份整个数据目录到 `backups/upstream-migration-<时间>.tar.gz`；
- 复用旧 `one/`（identity、controller.d、moons.d、authtoken.secret）；
- 把旧 `ztncui/src/etc/passwd` 复制为 `config/ztncui-passwd`，保留管理员；
- 迁移 ztncui 的成员显示名（`node-persist` storage）；
- 用当前分支构建镜像，启动临时容器，健康检查通过后替换旧容器；
- 保留旧 `config/file_server.key`（若长度足够），并重新生成 planet。

迁移后注意：
- 新 UI 默认使用 HTTPS 自签证书，旧 `http://` 地址不再可用；
- 文件下载改为 Header 认证，旧 `?key=` 默认被禁用；
- planet ID 不变，但 planet 内容会重建；若公网 IP 未变，客户端重新下载 planet 即可；
- 旧容器定义保存在 `backups/*-container.json`，备份可用于手工回滚。

新部署仍只需要三个卷：`config`、`dist`、`one`。旧布局里的 `ztncui` 目录不再挂载；
挂载 `/app/ztncui` 会覆盖不可变应用目录，阻止安全更新生效。

## 本地构建与测试

构建使用固定 digest 的 Debian bookworm-slim 与 Node.js 24 LTS slim 基础镜像；
升级基础镜像时修改 `Dockerfile` 顶部 ARG 并重新跑一遍测试。

apt 默认走中科大镜像（`APT_MIRROR=http://mirrors.ustc.edu.cn`），避免国内构建卡在
`deb.debian.org`。海外或使用其他镜像时可覆盖：

```bash
APT_MIRROR=http://deb.debian.org ./build.sh
```

Git clone 默认经 `https://ghfast.top/https://github.com` 代理，失败会自动回退到
`https://github.com`。镜像只是传输通道，ZeroTier 与 ztncui 仍按固定 SHA 校验；
不要使用无法访问 GitHub 且不提供 fallback 的代理。海外或改用其他代理：

```bash
GH_MIRROR=https://github.com ./build.sh
# 或
GH_MIRROR=https://gh-proxy.com/https://github.com ./build.sh
```

ZeroTier 的 `1.16.2` 同时存在同名 branch 与 annotated tag。构建脚本显式 fetch
tag 并校验 commit，避免误检出 branch tip。

```bash
# 本地单架构构建
./build.sh

# 多架构构建并推送（需先 docker login）
PUSH=1 IMAGE=ghcr.io/<你>/docker-zerotier-planet:latest ./build.sh

# 测试
cd patch/ztncui && npm ci --omit=dev --ignore-scripts
cd ../..
./tests/http-server.test.sh
node tests/ztncui-views.test.js
```

仓库提供 `tests/http-server.test.sh`（文件服务器安全回归）与 `tests/ztncui-views.test.js`
（全部 Pug 视图编译）；CI 工作流需由仓库所有者
自行添加（GitHub OAuth App 推送 workflow 文件需要额外的 `workflow` scope）。

### 升级上游版本

`scripts/upgrade-upstreams.sh` 用来检查并升级两个上游依赖，只修改 `Dockerfile`
顶部的 `ZT_VERSION`、`ZT_COMMIT` 与 `ZTNCUI_COMMIT`，不会合并
xubiaolin/docker-zerotier-planet（本分支已大幅重构），也不会自动提交：

```bash
# 只检查，不改文件（默认）
./scripts/upgrade-upstreams.sh

# 更新 Dockerfile 并跑本地回归测试；测试失败会自动恢复 Dockerfile
./scripts/upgrade-upstreams.sh --apply

# 只升级 ZeroTier / 只升级 ztncui
./scripts/upgrade-upstreams.sh --apply --zerotier-only
./scripts/upgrade-upstreams.sh --apply --ztncui-only

# 更新后直接构建（需要本机 docker）
./scripts/upgrade-upstreams.sh --apply --build
```

脚本依赖 `curl`、`git`、`node`（`--build` 另需 docker）；GitHub API 有匿名限流时可传 `GITHUB_TOKEN`。升级 ZeroTier 后应查看 release
notes 并重点验证 controller API；升级 ztncui 后应重新检查 `patch/ztncui` 的
controller/view 覆盖是否仍兼容。README/SECURITY 中的版本号与变更说明需要手动同步。

## 安全模型与限制

- 这是**单节点** controller，不提供 HA；controller 数据库就是 `data/one/controller.d`。
- 会话保存在内存中，容器重启后需要重新登录（不会持久化会话密钥到浏览器）。
- 自签证书只提供传输加密，不提供身份认证；生产环境建议使用受信任证书或反代。
- 管理界面应只对可信网络开放；不要直接把 3443 暴露到整个互联网而不设强密码。
- 容器内没有 `NET_ADMIN` 时 ZeroTier 不能创建 TUN，但 controller/planet 功能正常；
  仅当你要让容器本身作为 leaf 加入网络时才需要额外 capability。
- 本镜像的 controller 受 ZeroTier 非商业许可证约束；商业使用请购买授权或改用官方 controller。
- 本项目不托管任何中继/根服务器；planet 的可用性取决于你的主机与网络。

## 故障排查

- **客户端仍连官方 planet**：确认 planet 文件路径正确并已重启服务；`zerotier-cli listpeers`
  中应出现你的公网 IP；检查 UDP 9994 是否被防火墙/NAT 阻断。
- **管理界面 401/无法登录**：确认 `data/config/admin-password` 是否存在；删除
  `data/config/ztncui-passwd` 与 `admin-password` 后重启可重置（会丢失已建管理员）。
- **容器反复重启**：`docker logs <容器名>`；常见原因是公网 IP 未设置、端口占用、
  卷权限不是 uid 1000，或证书不可读。
- **浏览器证书错误**：自签证书属预期；导入证书或改用受信任证书。
- **下载 401**：使用 `Authorization: Bearer <key>`，不要再用 `?key=`；或直接从
  `data/dist/planet` 复制。

## 许可证

- 本项目原创代码：GPL-3.0-only，见 [LICENSE](LICENSE)。
- ztncui：GPL-3.0，见其仓库。
- ZeroTier One 核心：MPL-2.0；`nonfree/controller`：ZeroTier SOURCE-AVAILABLE
  LICENSE（仅非商业），见 [NOTICE](NOTICE)。

上游项目：<https://github.com/xubiaolin/docker-zerotier-planet>
