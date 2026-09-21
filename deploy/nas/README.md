# MomoBox NAS 部署

本目录只部署 `momo-backend` 和 PostgreSQL。生产 NAS 默认从 GitHub Container Registry（GHCR）拉取已通过后端 CI 的多架构 `latest` 镜像；Home Assistant 是外部服务，由后端通过家庭管理员配置的地址和加密 Token 访问；LLM/Ollama 不在 NAS Compose 中，Flutter 客户端直接连接用户配置的外部服务。

## 镜像与版本策略

默认镜像为：

```text
ghcr.io/davisding/momobox-backend:latest
```

`latest` 仅在 `main` 分支的后端变更通过 Go 测试、`go vet` 和双架构构建后更新。镜像同时支持 `linux/amd64` 与 `linux/arm64`，Docker 会按 NAS CPU 架构自动选择正确的镜像。

发布流程还保留版本标签，例如 `ghcr.io/davisding/momobox-backend:v0.1.0`。遇到问题时，可将 `.env` 中的 `MOMO_BACKEND_IMAGE` 改为已知版本标签，再运行更新脚本回退应用镜像。

GHCR 包需要在首次发布后由仓库管理员在 GitHub Packages 中设为 **Public**。公开包允许 NAS 匿名拉取，不需要 `docker login` 或 GitHub Token。镜像不包含 `.env`、数据库数据或 NAS Secret；这些内容仅保存在 NAS 本地。

## 首次部署

1. 将本目录复制到 NAS，例如 `/volume1/docker/momobox-nas`。生产 NAS 不需要克隆整个源码仓库，也不需要安装 Go 或 Flutter。

2. 复制 `.env.example` 为 `.env`，替换所有 `change-me`/`replace-with` 值。推荐生成方式：

```sh
openssl rand -hex 32  # JWT_SECRET
openssl rand -hex 32  # REFRESH_TOKEN_PEPPER
openssl rand -hex 16  # HA_TOKEN_ENCRYPTION_KEY：输出恰好 32 个 ASCII 字符
```

`POSTGRES_PASSWORD` 与 `DATABASE_URL` 中的密码必须一致；密码包含特殊字符时，需要在 `DATABASE_URL` 中进行 URL 编码。默认 `MOMO_BACKEND_IMAGE` 使用 GHCR `latest`；宿主机端口通过 `MOMO_BACKEND_PORT` 修改，容器内后端固定监听 `8080`。

3. 在 NAS 的部署目录执行：

```sh
docker compose -f compose.yaml pull momo-backend
docker compose -f compose.yaml up -d postgres
docker compose -f compose.yaml run --rm momo-backend migrate
docker compose -f compose.yaml up -d momo-backend
```

4. 访问 `GET /api/v1/health`，确认 HTTP 200 且 `database` 为 `ok`。

## 安全更新到最新镜像

每次后端 CI 发布新的 `latest` 后，在 NAS 执行：

```sh
./scripts/update.sh
```

该脚本会按顺序：备份 PostgreSQL、拉取 `MOMO_BACKEND_IMAGE`、停止旧后端、执行 migration、再启动新后端。它先完成拉取再停止现有服务；若 migration 失败，后端会保持停止状态，避免用新镜像运行在未确认 schema 上。脚本会输出备份文件路径。

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

恢复完成后脚本会重新启动此前正在运行的后端。执行恢复前仍应保留当前数据库的独立备份，并确认 dump 来源和目标 NAS 环境。

## 明确不包含的服务

- Ollama
- AI proxy
- barcode proxy
- Home Assistant

这些服务的生命周期和网络可达性由用户自行管理。
