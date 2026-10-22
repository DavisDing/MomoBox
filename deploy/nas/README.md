# MomoBox NAS 部署

本目录只部署 `momo-backend` 和 PostgreSQL。生产 NAS 从 GitHub Container Registry（GHCR）拉取由 `.env` 明确指定的、可追溯的版本标签或 digest；不再默认使用可变的 `latest`。Home Assistant 是外部服务，由后端通过家庭管理员配置的地址和加密 Token 访问；LLM/Ollama 不在 NAS Compose 中，Flutter 客户端直接连接用户配置的外部服务。

## 镜像与版本策略

生产 Compose **不提供 `latest` 默认值**。必须在 `.env` 中显式设置镜像和应用版本，例如：

```dotenv
MOMO_BACKEND_IMAGE=ghcr.io/davisding/momobox-backend:v0.1.0
APP_VERSION=v0.1.0
```

也可以使用 CI 生成的不可变提交标签，或更严格地使用 digest：

```dotenv
MOMO_BACKEND_IMAGE=ghcr.io/davisding/momobox-backend:sha-abc1234
# 或 ghcr.io/davisding/momobox-backend@sha256:<完整摘要>
APP_VERSION=sha-abc1234
```

CI 仍可发布 `latest` 作为人工选择的便利别名，但生产部署必须在 `.env` 中固定到版本标签或 digest。镜像支持 `linux/amd64` 与 `linux/arm64`，Docker 会按 NAS CPU 架构自动选择正确的镜像。

正式发布会同时保留版本标签，例如 `ghcr.io/davisding/momobox-backend:v0.1.0`。遇到问题时，将 `.env` 中的 `MOMO_BACKEND_IMAGE` 和 `APP_VERSION` 一起改为已知版本，再运行更新脚本回退应用镜像。GHCR 包需要在首次发布后由仓库管理员在 GitHub Packages 中设为 **Public**，公开包允许 NAS 匿名拉取。

## 绿联 NAS（UGOS）Docker Compose

`docker-compose.yaml` 使用标准 Compose 规范，可直接在绿联 NAS 的 **Docker → 项目 → 创建项目** 中导入或粘贴。请将 `docker-compose.yaml` 与 `.env` 放在同一个项目目录；如果 UGOS 页面不自动读取 `.env`，就在项目的环境变量设置中逐项填写同名变量。不要把 `docker-compose.local-build.yaml` 导入 NAS，它只用于开发机本地构建。

导入前必须设置以下变量：

```dotenv
MOMO_BACKEND_IMAGE=ghcr.io/davisding/momobox-backend:vX.Y.Z
APP_VERSION=vX.Y.Z
POSTGRES_PASSWORD=替换为随机密码
DATABASE_URL=postgres://momo:替换为URL编码后的密码@postgres:5432/momo?sslmode=disable
JWT_SECRET=至少32字节随机值
REFRESH_TOKEN_PEPPER=至少32字节随机值
HA_TOKEN_ENCRYPTION_KEY=恰好32个ASCII字符
```

其中 `MOMO_BACKEND_IMAGE` 和 `APP_VERSION` 必须对应同一个已发布版本；生产环境不要使用 `latest`。绿联 NAS 需要能够访问 GHCR，且 `momo-backend` 镜像必须支持 NAS 的 CPU 架构（当前发布镜像为 `linux/amd64` 和 `linux/arm64`）。

创建项目后，先在 UGOS 的 Compose 编辑器中执行配置检查（或保存项目让 UGOS 校验）。**导入 Compose 不会自动执行数据库 migration**：使用同版本部署目录的 `scripts/update.sh` 完成首次迁移再启动后端，不能仅凭“项目已创建”认为初始化完成。后端启动前会只读核对 migration 记录与镜像文件，空库/不匹配时拒绝服务；健康检查通过后访问 `http://NAS地址:映射端口/api/v1/health`。

## 两种新增独立模板

如需全新PostgreSQL18部署或复用LiteLLM已有PostgreSQL，参见 `variants/README.md`：`variants/with-postgres/docker-compose.yaml`（自带PG18.6）与`variants/external-postgres/docker-compose.yaml`（仅后端、复用现有Docker网络及专属库）。每套有独立`.env.example`。

下文无参数命令仍指本目录原PG16 Compose。新增模板使用同一套`scripts/`，但必须按[OPERATIONS.md](OPERATIONS.md)传入完整部署目录、project、模式、库/角色和固定PG client digest；不能直接无参数运行。新增运维入口已完成源码实现与离线故障模拟，PG18/外部库/UGOS真实验收仍未执行；现有部署不会自动换数据库或升级大版本。

## 首次部署

1. 将本目录复制到 NAS，例如 `/volume1/docker/momobox-nas`。生产 NAS 不需要克隆整个源码仓库，也不需要安装 Go 或 Flutter。

2. 复制 `.env.example` 为 `.env`，替换所有 `change-me`/`replace-with` 值，并把模板中的 `MOMO_BACKEND_IMAGE`/`APP_VERSION` 改为要部署的同一版本（不能保留 `latest`）。推荐生成方式：

```sh
openssl rand -hex 32  # JWT_SECRET
openssl rand -hex 32  # REFRESH_TOKEN_PEPPER
openssl rand -hex 16  # HA_TOKEN_ENCRYPTION_KEY：输出恰好 32 个 ASCII 字符
```

`POSTGRES_PASSWORD` 与 `DATABASE_URL` 中的密码必须一致；密码包含特殊字符时，需要在 `DATABASE_URL` 中进行 URL 编码。生产 Compose 要求显式设置 `MOMO_BACKEND_IMAGE` 和 `APP_VERSION`，不得留空；宿主机端口通过 `MOMO_BACKEND_PORT` 修改，容器内后端固定监听 `8080`。

3. 在 NAS 的部署目录执行：

```sh
./scripts/update.sh
```

4. 脚本会等待 `momo-backend` Docker healthcheck 变为 `healthy` 后才报告成功；也可再访问 `GET /api/v1/health`，确认 HTTP 200 且 `database` 为 `ok`。

## 安全更新到指定镜像

每次要部署新的已审核版本时，先在 `.env` 更新 `MOMO_BACKEND_IMAGE` 与 `APP_VERSION`，再在 NAS 执行：

```sh
./scripts/update.sh
```

该脚本会按顺序：获取部署互斥锁、在线预备份、拉取 `MOMO_BACKEND_IMAGE`、停止并核对本项目全部后端容器（含 restarting）、**停写后最终备份**、migration、只读 `schema-check`、启动新后端并等待全部容器 healthcheck。先拉取再停机，拉取失败不影响原服务；最终备份失败不回退到在线 dump 继续迁移。输出的最终备份才是本项目停写后的升级恢复点，NAS 上其他项目、手工进程或外部数据库写入者仍须单独隔离。

停机后的任何失败都保持后端隔离；容器状态无法确认、迁移失败或信号打断导致数据库任务结果未知时，**保留部署锁**等待人工核对。脚本与镜像必须来自支持 `schema-check` 的同版本；旧镜像不支持该命令时拒绝启动，不跳过检查。`backup.sh`、`restore.sh` 与更新流程共享同一锁，不能并发操作数据库。

仅当你已在部署目录外保留了当前且已验证的备份时，才可跳过自动备份：

```sh
./scripts/update.sh --skip-backup
```

### 回退到版本化镜像

编辑 `.env`：

```dotenv
MOMO_BACKEND_IMAGE=ghcr.io/davisding/momobox-backend:v0.1.0
APP_VERSION=v0.1.0
```

然后再次执行：

```sh
./scripts/update.sh
```

数据库 migration 必须保持向前兼容。涉及不可逆 migration 时，先确认备份可以恢复；镜像回退不自动回退数据库结构。

## 本地源码构建（仅开发）

生产 NAS 不使用源码构建。若在开发机调试后端，可叠加本地 override：

```sh
docker compose \
  -f deploy/nas/docker-compose.yaml \
  -f deploy/nas/docker-compose.local-build.yaml \
  up --build
```

这会以 `backend/` 作为独立 Docker 构建上下文，并使用本地镜像 `momo-backend:local`；不会影响生产 Compose 的 GHCR 镜像配置。

## 备份与恢复

脚本可从任意工作目录调用，默认将 PostgreSQL custom-format dump 写入 `deploy/nas/backups/`（已由该目录的 `.gitignore` 排除）：

```sh
./deploy/nas/scripts/backup.sh
./deploy/nas/scripts/backup.sh --output-dir /volume1/backups/momobox
```

恢复会覆盖目标数据库中的现有对象。脚本默认要求交互确认，并在恢复期间停止 `momo-backend`：

```sh
./deploy/nas/scripts/restore.sh /volume1/backups/momobox/momobox-postgres-YYYYMMDDTHHMMSSZ-PID.dump
# 自动化环境必须显式确认：
./deploy/nas/scripts/restore.sh --yes /path/to/momobox.dump
```

**恢复成功、失败或中断后都不会自动重启后端。** 成功仅代表原库单事务恢复及镜像 migration 身份核对完成，不是安全重开服务的许可。旧 dump 可能恢复旧账号权限、会话、cursor和库存历史；外部 restore epoch、App 离线意图审阅、配套密钥及独立候选库切换尚未实现。不要直接运行更新脚本或在 UGOS 点击启动来绕过恢复后的隔离；需先按 `docs/NAS_RECOVERY_PLAN_2026-10-07.md` 单独制定并验证恢复准入方案。

恢复会写入`.momobox-restored`隔离标记，后续`update`拒绝自动重开；删除标记不代表灾备已完成。新模式只支持独立空候选库恢复，详见[OPERATIONS.md](OPERATIONS.md)。

更新、备份、恢复使用 `deploy/nas/.momobox-deployment.lock` 互斥。发现锁存在时不要直接删除：先检查 owner 元信息、本项目所有容器（含 one-off）、PostgreSQL 活动及仍可能运行的迁移/恢复进程，证明任务已终止后再按运维流程处理；删除锁不代表数据库或同步历史已安全。恢复仍是破坏性原库操作，执行前必须另存当前库备份、验证来源与目标；本脚本不等于完整灾备方案。

后端 `schema-check` 和 `serve` 启动门禁只验证 ledger 的版本、名称、checksum（保留限定 legacy 兼容），不修复记录、不验证物理表结构或数据/历史完整性；`/api/v1/health` 仍仅报告数据库连接，不是 restore epoch 或完整 readiness 接口。

## 明确不包含的服务

- Ollama
- AI proxy
- barcode proxy
- Home Assistant

这些服务的生命周期和网络可达性由用户自行管理。
