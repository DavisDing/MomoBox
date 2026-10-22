# 两种独立 NAS Compose 模板（2026-10-11）

> 已生成配置文件并完成静态检查；Docker、PG18、UGOS、外部数据库及恢复演练 **NOT_EXECUTED**。发布流程已接入这两套模板及操作指南，但新提交的远端发布尚待验证；这些模板不是PostgreSQL大版本升级工具。

## 选择一套，不要同时导入

| 文件夹 | 适用情况 | 本项目管理范围 |
| --- | --- | --- |
| `with-postgres` | 全新部署，尚无可复用 PostgreSQL | 后端 + PostgreSQL 18.6 + 新数据卷 |
| `external-postgres` | 已有 PostgreSQL，例如 LiteLLM 使用的实例 | 仅 MomoBox 后端；不创建、停止、升级或清理现有 PostgreSQL |

两套都是完整的 `docker-compose.yaml`，不是 overlay，不要用多个 `-f` 合并。原 `deploy/nas/docker-compose.yaml` 的 PG16 镜像与数据卷保持不变；共享运维脚本已增加显式部署上下文，原无参数入口保留兼容。

“最新”指2026-10-11已核实稳定版本 **18.6**，固定镜像 `postgres:18.6-alpine3.24`，不使用浮动 `latest` 或19 beta。版本需定期审核，但不能随App升级自动跨PostgreSQL大版本。PG18官方镜像卷挂载 `/var/lib/postgresql`；本模板使用新命名卷 `postgres18_data`，不接旧的 `postgres_data`。既有PG16/17数据须另做经过验证的dump/restore或pg_upgrade，不能直接替换镜像/挂原数据目录，也不能用`down -v`处理启动错误。

## 绿联 NAS 导入和环境配置

1. 把选中文件夹内的 `docker-compose.yaml` 和 `.env.example` 放进一个新的、固定的NAS项目目录；将后者复制为 `.env`。另一套不要导入同一个项目。
2. 使用已有发布的固定后端镜像和对应 `APP_VERSION`，不能照搬示例`v0.1.0`。替换数据库密码、JWT、refresh pepper及HA加密密钥；不把真实`.env`提交进Git。
3. 在UGOS Docker Projects导入Compose并填入对应变量。保留后端固定容器内8080映射，宿主端口有冲突时修改`MOMO_BACKEND_PORT`。
4. **导入不执行迁移**。空库时`serve`的schema门禁会拒绝启动；先按下一节初始化，再启动并等待health。UGOS实现对一键`up`、外部网络及变量文件的支持需要在设备核实。

### 自带数据库版

`POSTGRES_PASSWORD`与`DATABASE_URL`密码一致；密码中的特殊字符在URL中编码。该版本数据库不映射宿主5432端口，后端使用项目内`postgres:5432`。官方镜像的`POSTGRES_USER`是初始化管理账号；此全新专用实例沿用现有单应用模板，不应拿该管理员账号给LiteLLM共用。将来共享时创建独立应用角色并另定权限。

### 复用已有数据库版

- 请现有数据库管理员先创建 **MomoBox专属数据库和非超级用户账号**，例如`momobox`、`momobox_user`。该账号仅拥有MomoBox库及所需schema对象，不能复用LiteLLM库/账号，也不取得CREATEDB/CREATEROLE/REPLICATION或其他库角色成员权限。
- 现有migration使用`public` schema、`pgcrypto`扩展及触发器，核对专属库中创建/使用权限；扩展不可用时由管理员在MomoBox库中解决，不用给App超级用户兜底。真实migration权限回归待执行。
- `DATABASE_NETWORK`填写已存在的Docker网络名称，数据库容器须已连接该网络；`DATABASE_URL`的host填写该网络中数据库的唯一服务别名，例如`shared-postgres`。容器内`localhost`不是NAS/其他数据库容器。同名服务有歧义时由管理员设置唯一网络alias，模板不自动修改LiteLLM网络。
- 模板固定采用**同一Docker主机的现有共享网络**作为连接方案；不自动探测本机实例，也不会连接失败后创建新库。网络不存在、库不存在或密码/权限错误，须先修正，不会降级到新数据库。
- 外部数据库版本不强制改为18.6；原源码/CI基线是PG16，PG18属于待验收的新部署版本。目标外部版本和补丁号需记录并实测migration/幂等/并发cursor；不能宣称所有版本已经兼容。
- URL中的`sslmode=disable`仅是同机受控Docker网络示例。外部主机/TLS或证书挂载不在此模板方案内，另行配置来源控制和`verify-full`证书校验，不开放公网5432。

## 全新 MomoBox 数据库的初始化

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

## 已有数据升级、备份与恢复

共享脚本已支持显式选择managed/external部署，完整参数、固定client digest、专属角色、备份sidecar、独立空候选库恢复演练证明、更新准入与隔离规则见[../OPERATIONS.md](../OPERATIONS.md)。新模式禁止`--skip-backup`，不可无参数调用原PG16默认入口。

这是源码实现与离线故障模拟状态，不是Docker/PG18/外部数据库或UGOS验收通过。上线前须完成真实权限、网络、备份、候选恢复与失败隔离矩阵；D-07正式灾备、restore epoch及生产切库仍未实现。

发布资产：每个版本分别提供 `MomoBox-v版本-with-postgres-docker-compose.yaml` / `-with-postgres.env.example`、`-external-postgres-docker-compose.yaml` / `-external-postgres.env.example` 和 `-nas-variants-README.md`；共享脚本及操作指南另打包为 `MomoBox-v版本-nas-operations.tar.gz`，统一纳入 SHA256SUMS。下载选中模式的 Compose/env 并重命名为 `docker-compose.yaml` / `.env`；不要同时导入两套。新提交实际发布仍待验证。

后续验收入口：真实PG16+PG18、外部专属角色、UGOS与远端发布；本次不修改现有数据库。

参考：PostgreSQL版本策略与18.6发布说明；Docker官方PostgreSQL镜像PG18卷路径；Compose启动顺序和网络契约。
