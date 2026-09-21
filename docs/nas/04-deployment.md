# MomoBox NAS Docker 部署契约

- 文档版本：v0.2
- 更新时间：2026-09-21
- 适用范围：Go NAS 后端和 PostgreSQL

## 1. 仓库目录隔离

后端和 Flutter 位于同一个 Git 仓库，但使用独立工具链：

```text
MomoBox/
├── backend/                 # Go module 和后端 Docker 构建上下文
│   ├── go.mod
│   ├── go.sum
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── cmd/
│   ├── internal/
│   ├── migrations/
│   └── tests/
├── deploy/
│   └── nas/
│       ├── compose.yaml              # 生产环境：拉取 GHCR 镜像
│       ├── compose.local-build.yaml  # 开发环境：本地构建 override
│       ├── .env.example
│       ├── README.md
│       └── scripts/
├── lib/                     # Flutter 客户端
├── test/                    # Flutter 测试
├── android/
├── ios/
└── pubspec.yaml
```

禁止在仓库根目录放后端 Dockerfile，禁止用仓库根目录作为后端镜像的构建上下文。

后端构建上下文固定为：

```text
/Users/dinghao/Downloads/MomoBox/backend
```

Compose 位于：

```text
/Users/dinghao/Downloads/MomoBox/deploy/nas/compose.yaml
```

生产 NAS 的 Compose 使用 GHCR 镜像，而非在 NAS 从源码构建：

```yaml
services:
  momo-backend:
    image: ${MOMO_BACKEND_IMAGE:-ghcr.io/davisding/momobox-backend:latest}
```

`MOMO_BACKEND_IMAGE` 默认指向公开的多架构 `latest`。版本化发布另有 `vX.Y.Z` 标签，供排障和回退。开发机如需本地构建，显式叠加 `compose.local-build.yaml`；该 override 的构建上下文固定为 `../../backend`。这样 Flutter、Android、iOS、`.dart_tool` 和本地资源不会进入后端镜像。

## 2. 服务拓扑

第一版 Compose 只包含：

```text
momo-backend
    │
    └── postgres
```

Home Assistant 是外部服务，不由 Compose 安装、升级或管理：

```text
momo-backend ──HTTP/HTTPS──> 用户自行部署的 Home Assistant
```

AI/Ollama 也属于外部服务：

```text
Flutter ──直连──> LLM 厂商或用户自行部署的 Ollama
```

Compose 不包含：

```text
ollama
ai-proxy
barcode-proxy
home-assistant
```

## 3. 服务职责

### momo-backend

负责：

- 认证和家庭成员；
- 同步设备；
- 商品、批次、库存和采购；
- PostgreSQL 迁移入口；
- Home Assistant 连接、发现、权限和控制；
- 健康检查和 API。

不负责：

- AI 代理；
- Ollama 生命周期；
- Home Assistant 安装；
- 移动端构建；
- PostgreSQL 自动备份的长期存储。

### postgres

负责服务端数据持久化。必须挂载命名卷：

```text
postgres_data:/var/lib/postgresql/data
```

## 4. 环境变量

`.env.example` 只包含变量名和安全示例，不包含真实 Secret：

```text
APP_ENV=production
MOMO_BACKEND_IMAGE=ghcr.io/davisding/momobox-backend:latest
APP_VERSION=latest
MOMO_BACKEND_PORT=8080
DATABASE_URL=postgres://momo:change-me@postgres:5432/momo?sslmode=disable
JWT_SECRET=replace-with-long-random-secret
REFRESH_TOKEN_PEPPER=replace-with-long-random-secret
HA_TOKEN_ENCRYPTION_KEY=change-this-key-to-exactly-32byt
REGISTRATION_MODE=first_setup
ACCESS_TOKEN_TTL=15m
REFRESH_TOKEN_TTL=720h
MAX_REQUEST_BODY_BYTES=1048576
LOG_LEVEL=info
```

生产环境必须替换：

- `DATABASE_URL` 中的密码；
- `JWT_SECRET`；
- `REFRESH_TOKEN_PEPPER`；
- `HA_TOKEN_ENCRYPTION_KEY`。

推荐使用 `openssl rand -hex 32` 生成 JWT Secret 和 Refresh Token Pepper，使用 `openssl rand -hex 16` 生成 HA Token 加密密钥。后者输出恰好 32 个 ASCII 字符，满足后端“32 bytes”校验；不要把换行或引号计入变量值。`POSTGRES_PASSWORD` 与 `DATABASE_URL` 中的密码必须一致，特殊字符必须进行 URL 编码。Compose 内服务固定监听 `0.0.0.0:8080`，宿主机映射端口只通过 `MOMO_BACKEND_PORT` 调整，避免端口映射与健康检查失配。

`MOMO_BACKEND_IMAGE` 默认使用 GHCR 的 `latest`，每次后端 CI 成功后更新。正常升级必须使用 `scripts/update.sh`，它会先备份、拉取镜像、运行 migration，再启动业务服务。若要回退应用镜像，将此变量改为 `ghcr.io/davisding/momobox-backend:vX.Y.Z`；镜像回退不会自动回退数据库 schema。

不提供以下后端变量：

```text
AI_API_KEY
AI_BASE_URL
OLLAMA_BASE_URL
OLLAMA_MODEL
AI_PROXY_URL
```

## 5. 镜像要求

`backend/Dockerfile` 必须：

- 使用多阶段构建；
- 最终镜像不包含 Go 工具链；
- 使用非 root 用户运行；
- 不复制 Flutter、Android、iOS 或仓库根目录内容；
- 使用固定 Go 基础镜像版本；
- 构建产物支持 `linux/amd64` 和 `linux/arm64`；
- 不使用 `latest` 作为生产基础镜像标签；
- 使用 `backend/.dockerignore` 排除测试缓存和本地构建产物；
- 由 GitHub Actions 构建并推送至 `ghcr.io/davisding/momobox-backend`；
- 每次默认分支的后端变更通过 `go test ./...`、`go vet ./...` 和 Buildx 构建后更新 `latest` 与 `sha-<commit>` 标签；
- 正式产品 Release 额外发布不可变的 `vX.Y.Z` 标签；
- 首次发布后必须在 GitHub Packages 将镜像包显式设为 Public，公开 NAS 才能匿名拉取。

`latest` 是 NAS 的部署标签，不得作为 Dockerfile 的基础镜像标签。Compose 中的 `momo-backend` 使用只读根文件系统，删除全部 Linux capabilities，启用 `no-new-privileges`，并只提供受限的 `/tmp` tmpfs。

## 6. 启动与迁移

后端必须提供明确的迁移命令：

```text
momo-backend migrate
momo-backend serve
```

首次启动流程：

```text
docker compose pull momo-backend
docker compose up -d postgres
docker compose run --rm momo-backend migrate
docker compose up -d momo-backend
```

日常升级流程固定为：

```text
scripts/update.sh
# backup → pull MOMO_BACKEND_IMAGE → stop backend → migrate → start backend
```

不得使用自动重启型镜像更新器绕过 migration。迁移执行必须：

- 使用 PostgreSQL advisory lock 或等价锁；
- 记录已执行迁移；
- 失败时返回非零退出码；
- 不在每个 HTTP 请求中执行迁移；
- 迁移失败时不启动可写业务服务。

## 7. 健康检查

后端提供：

```http
GET /api/v1/health
```

健康响应至少区分：

```json
{
  "status": "ok",
  "database": "ok"
}
```

数据库不可用时返回 HTTP 503，但不泄漏连接串、用户名或内部错误堆栈。

Compose healthcheck 必须检查后端端口和 PostgreSQL 健康状态。后端依赖 PostgreSQL healthy 后再启动业务服务。

## 8. Home Assistant 外部连接

HA 配置由家庭 owner/admin 通过 API 写入数据库。其 Token 使用 `HA_TOKEN_ENCRYPTION_KEY` 加密后保存。

Compose 不需要知道具体的：

```text
HA_BASE_URL
HA_ACCESS_TOKEN
```

如果没有家庭配置 HA：

- 后端正常启动；
- `/api/v1/health` 仍可健康；
- HA API 返回 `HOME_ASSISTANT_NOT_CONFIGURED`；
- 认证、库存和同步不受影响。

## 9. 备份与恢复

第一版使用 PostgreSQL custom-format 逻辑备份。部署脚本通过 Compose 内的 PostgreSQL 工具执行 `pg_dump` / `pg_restore`，避免要求 NAS 宿主机单独安装 PostgreSQL 客户端：

```bash
./deploy/nas/scripts/backup.sh --output-dir /volume1/backups/momobox
./deploy/nas/scripts/restore.sh /volume1/backups/momobox/momobox-postgres-YYYYMMDDTHHMMSSZ-PID.dump
```

恢复默认要求交互确认，自动化环境必须显式传入 `--yes`；恢复期间停止后端，完成后只在其原本运行时重新启动。备份使用临时文件并在成功后原子重命名，失败时不能留下看似成功的 dump。

备份脚本位于：

```text
deploy/nas/scripts/backup.sh
deploy/nas/scripts/restore.sh
```

第一版没有媒体二进制上传，因此只需要备份 PostgreSQL。未来启用媒体卷后，数据库 dump 和媒体卷备份必须配对执行。

## 10. 网络与公网

- 默认监听 NAS 局域网端口；
- 不内置公网证书和域名服务；
- 公网使用由用户自行配置 HTTPS 反向代理或 VPN；
- Compose 不自动暴露 PostgreSQL 到宿主机公网；
- 只暴露后端 API 端口；
- 外部 HA 地址必须由 NAS 后端可达；
- 手机直连 Ollama 时，Ollama 地址必须由手机可达；MomoBox 不负责打通该网络。

## 11. 验收命令

在后端和部署文件完成后至少执行：

```bash
go test ./...
go vet ./...
docker build --platform linux/amd64 -t momo-backend:test backend/
docker build --platform linux/arm64 -t momo-backend:test-arm64 backend/
docker compose -f deploy/nas/compose.yaml config
./deploy/nas/scripts/self-test.sh
```

如果本机未安装 Go 或 Docker，必须标记为 `NOT_EXECUTED`，不能声称镜像或 NAS 部署已经验证通过。
