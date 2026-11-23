# 两种独立 NAS Compose 模板

> PostgreSQL 19 的 Docker、UGOS、外部数据库及恢复演练尚未执行。发布流程已接入这两套模板，但未验证本次远端发布。这些模板不是 PostgreSQL 大版本升级工具。

## 选择一套，不要同时导入

| 文件夹 | 适用情况 | 本项目管理范围 |
| --- | --- | --- |
| `with-postgres` | 全新部署，尚无可复用 PostgreSQL | 后端 + PostgreSQL 19.0 + 新数据卷 |
| `external-postgres` | 已有 PostgreSQL，例如 LiteLLM 使用的实例 | 仅 MomoBox 后端；不创建、停止、升级或清理现有 PostgreSQL |

两套都是完整的 `docker-compose.yaml`，不是 overlay，不要用多个 `-f` 合并。`with-postgres` 与默认 Compose 使用相同的 PostgreSQL 镜像和卷配置；两套独立模板的运维命令均使用显式部署上下文。

截至 2026-11-23，官方 `postgres:latest` 指向 PostgreSQL **19.0**。自带模板将 `postgres:19.0-alpine3.24` 固定到多架构 digest，避免重新拉取时意外跨大版本。新的 `postgres19_data` 挂到 `/var/lib/postgresql`，不接入旧版本数据卷。需要保留旧数据时，另行备份并验证迁移；不要用 `down -v` 处理启动错误。

## 绿联 NAS 导入和环境配置

1. 把选中文件夹内的 `docker-compose.yaml` 和 `.env.example` 放进一个新的、固定的NAS项目目录；将后者复制为 `.env`。另一套不要导入同一个项目。
2. 使用已有发布的固定后端镜像和对应 `APP_VERSION`，不能照搬示例`v0.1.0`。替换数据库密码、JWT、refresh pepper及HA加密密钥；不把真实`.env`提交进Git。
3. 在UGOS Docker Projects导入Compose并填入对应变量。默认映射`18473:18473`，容器内固定监听18473，宿主端口有冲突时修改`MOMO_BACKEND_PORT`；现有`.env`中的旧端口需按目标配置同步调整。
4. 包含2026-11-10自动启动改动的镜像默认 `start`：专属空库自动初始化，已有库只执行缺失迁移，成功后监听 HTTP。无需在 Compose 再添加命令；升级已有数据前仍备份并停止其他同库后端。旧镜像不具备此入口，按下节人工步骤处理。UGOS、外部网络及变量文件支持仍需设备验收。

### 自带数据库版

新的 `.env.example` 先定义 `POSTGRES_DB/POSTGRES_USER/POSTGRES_PASSWORD`，`DATABASE_URL` 用 Compose 变量引用它们，只填写一次密码；推荐 `openssl rand -hex 32` 生成 URL 安全密码。已有部署必须保留现有凭据；更改环境变量不会修改已初始化数据库密码。UGOS 若不支持 `.env` 内变量展开，需人工生成编码后的完整 URL 并核对凭据一致，再执行初始化。该版本数据库不映射宿主5432端口，后端使用项目内`postgres:5432`。官方镜像的`POSTGRES_USER`是初始化管理账号；此全新专用实例沿用现有单应用模板，不应拿该管理员账号给LiteLLM共用。将来共享时创建独立应用角色并另定权限。

### 复用已有数据库版

- 请现有数据库管理员先创建 **MomoBox专属数据库和非超级用户账号**，例如`momobox`、`momobox_user`。该账号仅拥有MomoBox库及所需schema对象，不能复用LiteLLM库/账号，也不取得CREATEDB/CREATEROLE/REPLICATION或其他库角色成员权限。
- 现有migration使用`public` schema、`pgcrypto`扩展及触发器，核对专属库中创建/使用权限；扩展不可用时由管理员在MomoBox库中解决，不用给App超级用户兜底。真实migration权限回归待执行。
- `DATABASE_NETWORK`填写已存在的Docker网络名称，数据库容器须已连接该网络；`DATABASE_URL`的host填写该网络中数据库的唯一服务别名，例如`shared-postgres`。容器内`localhost`不是NAS/其他数据库容器。同名服务有歧义时由管理员设置唯一网络alias，模板不自动修改LiteLLM网络。
- 模板固定采用**同一Docker主机的现有共享网络**作为连接方案；不自动探测本机实例，也不会连接失败后创建新库。网络不存在、库不存在或密码/权限错误，须先修正，不会降级到新数据库。
- 当前部署和运维基线为 PostgreSQL 19，后端 CI 使用官方 `postgres:latest`。外部模板不控制镜像版本，也不会替你升级数据库；如果 `latest` 日后切换大版本，先验证并安排数据库升级，不要直接用新镜像启动旧数据卷。
- URL中的`sslmode=disable`仅是同机受控Docker网络示例。外部主机/TLS或证书挂载不在此模板方案内，另行配置来源控制和`verify-full`证书校验，不开放公网5432。

## 全新 MomoBox 数据库的初始化

新镜像的默认 `start` 已负责以下 migrate→schema-check→serve 的启动准备；专属库/角色及网络就绪后可直接启动后端。以下显式命令保留用于旧镜像和人工维护，不是新镜像首次部署的必需操作。自动判断以数据库记录为准；有业务对象却缺迁移记录、版本缺口、未知新版本及checksum不符均停止，不通过删除数据或台账重新初始化。

以下操作必须固定为UGOS登记的同一项目名和部署目录。**仅用于全新MomoBox库**，不可拿来在运行中的旧库替代安全升级流程：

```sh
DEPLOY_DIR=/volume1/docker/momobox
PROJECT=momobox  # 必须与UGOS登记的项目名一致
# 固定选择.env，避免调用shell中的同名变量覆盖它。不source .env。
dc() (
  unset DATABASE_URL DATABASE_NETWORK POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD MOMO_BACKEND_IMAGE APP_VERSION APP_ENV MOMO_BACKEND_PORT JWT_SECRET REFRESH_TOKEN_PEPPER HA_TOKEN_ENCRYPTION_KEY REGISTRATION_MODE ACCESS_TOKEN_TTL REFRESH_TOKEN_TTL MAX_REQUEST_BODY_BYTES LOG_LEVEL COMPOSE_PROFILES
  docker compose --project-directory "$DEPLOY_DIR" --project-name "$PROJECT" \
    --env-file "$DEPLOY_DIR/.env" -f "$DEPLOY_DIR/docker-compose.yaml" "$@"
)
# --quiet避免将含密码的展开配置打印到日志。
dc config --quiet
dc pull momo-backend
```

自带版另执行：

```sh
dc pull postgres
dc up -d postgres
dc ps postgres
# 等postgres健康后再继续；不要只以容器running判定就绪。
```

复用版由管理员证明已有数据库就绪、专属MomoBox库无旧现场、无其他MomoBox写入者。两套随后执行：

```sh
# 如果导入时已自动启动了后端，先停止并核对全部后端实例。
dc stop momo-backend
dc ps --all
# 确认无running/restarting及未完成one-off任务后，逐条执行；失败立即停止。
dc run --rm --no-deps momo-backend migrate
dc run --rm --no-deps momo-backend schema-check
# 只有以上全部成功且确认无旧恢复现场，才能开始serve。
dc up -d momo-backend
dc ps
```

命令仅为操作入口，未在本机执行；migration连接启动检查有界，外部数据库未就绪时会失败，不承诺无限等待。失败/任务结果未知需保持停止并检查；不能跳过schema-check或反复执行恢复解决。

## 运维 client 是首次升级的前置条件

external 模板只启动后端，不含 PostgreSQL 工具。首次升级前下载同版本 operations 包；直接运行无参数 `update.sh` 会选择默认部署，不能用于这两套模板。

两套 `.env.example` 的 `PG_CLIENT_IMAGE` 都使用官方 PostgreSQL 19.0 Alpine 多架构 digest（`docker.io/library/postgres@sha256:8b0ff4cdf221f0c53d7fcda681d3b461be725c492cd881c5ec9c0ad25023f188`）。客户端和服务器必须同为 19，即使外部服务器使用 Debian 版 `latest`。脚本只读取该单一键，不执行 `.env`；也可用 `--pg-client-image IMAGE` 指定审核过的 PG19 digest。仍须明确 project、deployment-dir、database-mode、库和角色。先执行备份和候选空库恢复演练，再带证明执行更新。

## 容器加固与容量

三套模板及 one-off client 均用 `json-file` 日志轮转，每容器 `10m × 3`。自带 PostgreSQL 根文件系统只读，数据库卷保持可写；`/tmp` 与 `/var/run/postgresql` 为有界 tmpfs，禁止提权，删除默认 capabilities 后仅留官方入口初始化卷及降权所需的 CHOWN/DAC_OVERRIDE/FOWNER/SETGID/SETUID。入口最初以 root 修正卷权限后降权到 postgres，不能声称整个启动阶段都非 root。未强制覆盖 user，避免破坏既有卷所有权；真实容器空卷/旧卷启动、备份及重启还需验收。

## 已有数据升级、备份与恢复

共享脚本支持显式选择 managed/external 部署，参数、备份与恢复隔离规则见 [运维说明](../OPERATIONS.md)。显式模式禁止 `--skip-backup`，不能以无参数的默认入口替代。

上线前须完成真实 PG19、外部专属角色权限、网络、备份、候选恢复和失败隔离验收；D-07 正式灾备、restore epoch 及生产切库仍未实现。

发布资产：每个版本分别提供 `MomoBox-v版本-with-postgres-docker-compose.yaml` / `-with-postgres.env.example`、`-external-postgres-docker-compose.yaml` / `-external-postgres.env.example` 和 `-nas-variants-README.md`；共享脚本及操作指南另打包为 `MomoBox-v版本-nas-operations.tar.gz`，统一纳入 SHA256SUMS。下载选中模式的 Compose/env 并重命名为 `docker-compose.yaml` / `.env`；不要同时导入两套。新提交实际发布仍待验证。
