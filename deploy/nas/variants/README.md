# 两种独立 NAS Compose 模板（2026-10-11）

> 已生成配置文件并完成静态检查；Docker、PG18、UGOS、外部数据库及恢复演练 **NOT_EXECUTED**。发布流程已接入这两套模板及操作指南，但新提交的远端发布尚待验证；这不是已有数据库升级工具。

## 选择一套，不要同时导入

| 文件夹 | 适用情况 | 本项目管理范围 |
| --- | --- | --- |
| `with-postgres` | 全新部署，尚无可复用 PostgreSQL | 后端 + PostgreSQL 18.6 + 新数据卷 |
| `external-postgres` | 已有 PostgreSQL，例如 LiteLLM 使用的实例 | 仅 MomoBox 后端；不创建、停止、升级或清理现有 PostgreSQL |

两套都是完整的 `docker-compose.yaml`，不是 overlay，不要用多个 `-f` 合并。原 `deploy/nas/docker-compose.yaml` 与其 PG16 运维脚本未改动，以保护已有用户数据。

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

以下操作必须在选中部署目录执行，固定项目名/目录不变。**仅用于全新MomoBox库**，不可拿来在运行中的旧库替代安全升级流程：

```sh
# 先校验配置；--quiet避免将含密码的展开配置打印到日志。
docker compose --env-file .env -f docker-compose.yaml config --quiet
docker compose --env-file .env -f docker-compose.yaml pull momo-backend
```

自带版另执行：

```sh
docker compose --env-file .env -f docker-compose.yaml pull postgres
docker compose --env-file .env -f docker-compose.yaml up -d postgres
docker compose --env-file .env -f docker-compose.yaml ps postgres
# 等postgres健康后再继续；不要只以容器running判定就绪。
```

复用版由管理员证明已有数据库就绪、专属MomoBox库无旧现场、无其他MomoBox写入者。两套随后执行：

```sh
# 如果导入时已自动启动了后端，先停止并核对全部后端实例。
docker compose --env-file .env -f docker-compose.yaml stop momo-backend
docker compose --env-file .env -f docker-compose.yaml ps --all
# 确认无running/restarting及未完成one-off任务后，逐条执行；失败立即停止。
docker compose --env-file .env -f docker-compose.yaml run --rm --no-deps momo-backend migrate
docker compose --env-file .env -f docker-compose.yaml run --rm --no-deps momo-backend schema-check
# 只有以上全部成功且确认无旧恢复现场，才能开始serve。
docker compose --env-file .env -f docker-compose.yaml up -d momo-backend
docker compose --env-file .env -f docker-compose.yaml ps
```

命令仅为操作入口，未在本机执行；migration连接启动检查有界，外部数据库未就绪时会失败，不承诺无限等待。失败/任务结果未知需保持停止并检查；不能跳过schema-check或反复执行恢复解决。

## 已有数据升级、备份与恢复：不要用错脚本

**原 `deploy/nas/scripts/update.sh`、`backup.sh`、`restore.sh` 写死原Compose路径和自带`postgres`服务，不适用于这两个新增目录，尤其不能用于外部LiteLLM库。** 目前不提供新模板的一键安全运维脚本；切勿复制原脚本然后直接执行，也不要替换原Compose来假装适配完成。

上线含真实数据前，需完成以下独立运维验收：

- 固定选中Compose、project及数据库身份；锁定本项目全部后端与one-off任务，不停止其他LiteLLM进程/数据库。在线预备份、拉取、停写核验、最终备份、migration、schema-check、健康启动顺序不放宽。
- 备份只导出MomoBox专属库；`pg_dump`/`pg_restore`客户端使用与目标服务器匹配的主版本和受审补丁，原backend镜像没有这些工具。外部管理员另备份角色权限及应用配套密钥，不以数据库dump代表完整灾备。
- 恢复到独立MomoBox候选库验证，绝不对LiteLLM库`--clean`；恢复任何结果不自动重新开启MomoBox。实例/restore epoch、App离线意图仍按现有灾备未决项处理。
- 无容器/客户端、权限不足、备份不可验证、其他MomoBox写入者不能隔离时拒绝升级，不使用`--skip-backup`作为外部版默认方案。

发布资产：每个版本分别提供 `MomoBox-v版本-with-postgres-docker-compose.yaml` / `-with-postgres.env.example`、`-external-postgres-docker-compose.yaml` / `-external-postgres.env.example` 和 `-nas-variants-README.md`，统一纳入 SHA256SUMS。下载选中模式的 Compose/env 并重命名为 `docker-compose.yaml` / `.env`；不要同时导入两套。新提交实际发布仍待验证。

后续实施入口：选定模式的运维脚本及故障注入、PG16+PG18回归；本次不修改现有数据库。

参考：PostgreSQL版本策略与18.6发布说明；Docker官方PostgreSQL镜像PG18卷路径；Compose启动顺序和网络契约。
