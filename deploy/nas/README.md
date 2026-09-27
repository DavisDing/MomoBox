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

该脚本会按顺序：获取部署互斥锁、备份 PostgreSQL、拉取 `MOMO_BACKEND_IMAGE`、停止旧后端、执行 migration、启动新后端并等待 healthcheck。它先完成拉取再停止现有服务；若 migration 或健康等待失败，脚本会返回失败，避免宣称部署成功。脚本会输出备份文件路径。`backup.sh`、`restore.sh` 与更新流程共享同一锁，不能并发操作数据库。

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
  -f deploy/nas/compose.yaml \
  -f deploy/nas/compose.local-build.yaml \
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

恢复完成后脚本会重新启动此前正在运行的后端。更新、备份、恢复均使用 `deploy/nas/.momobox-deployment.lock` 互斥；发现锁存在时不要直接删除，先确认没有其他操作，再按 NAS 运维流程处理。执行恢复前仍应保留当前数据库的独立备份，并确认 dump 来源和目标 NAS 环境。

## 明确不包含的服务

- Ollama
- AI proxy
- barcode proxy
- Home Assistant

这些服务的生命周期和网络可达性由用户自行管理。
