# MomoBox NAS 部署

本目录只部署 `momo-backend` 和 PostgreSQL。Home Assistant 是外部服务，由后端通过家庭管理员配置的地址和加密 Token 访问；LLM/Ollama 不在 NAS Compose 中，Flutter 客户端直接连接用户配置的外部服务。

## 首次部署

1. 复制 `.env.example` 为 `.env`，替换所有 `change-me`/`replace-with` 值。推荐生成方式：

```sh
openssl rand -hex 32  # JWT_SECRET
openssl rand -hex 32  # REFRESH_TOKEN_PEPPER
openssl rand -hex 16  # HA_TOKEN_ENCRYPTION_KEY：输出恰好 32 个 ASCII 字符
```

`POSTGRES_PASSWORD` 与 `DATABASE_URL` 中的密码必须一致；密码包含特殊字符时，需要在 `DATABASE_URL` 中进行 URL 编码。宿主机端口通过 `MOMO_BACKEND_PORT` 修改，容器内后端固定监听 `8080`，避免端口映射与健康检查失配。

2. 在仓库根目录执行：

```sh
docker compose -f deploy/nas/compose.yaml up -d postgres
docker compose -f deploy/nas/compose.yaml run --rm momo-backend migrate
docker compose -f deploy/nas/compose.yaml up -d momo-backend
```

3. 访问 `GET /api/v1/health`，确认 HTTP 200 且 `database` 为 `ok`。

后端镜像的构建上下文固定为 `backend/`，不会把 Flutter、Android、iOS 或仓库根目录文件打进镜像。

## 停止与升级

```sh
docker compose -f deploy/nas/compose.yaml pull postgres
docker compose -f deploy/nas/compose.yaml build momo-backend
docker compose -f deploy/nas/compose.yaml run --rm momo-backend migrate
docker compose -f deploy/nas/compose.yaml up -d momo-backend
```

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
