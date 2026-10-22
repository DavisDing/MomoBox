# NAS 运维入口（2026-10-22）

同一套脚本支持原 PG16 默认目录、新建 managed PG18 部署，以及同主机 Docker 网络中的 external 专属 PG16/PG18 数据库。本文对应本次源码实现及离线测试；真实 Docker、PG18、外部角色和 UGOS 验收均为 **NOT_EXECUTED**。不要把脚本检查通过当作现场部署通过。

## 取得同版本工具

发行资产 `MomoBox-v版本-nas-operations.tar.gz` 包含 `scripts/`、`operations/` 和本文。对照同版本 `SHA256SUMS.txt` 核对后解压到固定工具目录。它不包含真实 `.env`、数据库、备份、证明或锁。Compose 与版本化 `.env.example` 仍是独立资产，下载选中模式后分别重命名为 `docker-compose.yaml`、`.env`，放进固定部署目录。工具包的发布流程已接入源码；实际远端发布尚未验证。

宿主需有 POSIX sh、Docker CLI 与 Compose、`mktemp`、`date`、`sed`、`wc`、`tr`、`cut` 和 `sha256sum` 或 `shasum`。宿主不需安装 PostgreSQL 工具或 Python；Python 仅用于开发/CI 离线测试。新模式用固定官方 PostgreSQL client 容器，内含 awk、psql、pg_dump 和 pg_restore。

原模式继续从工具的 `scripts/..` 读取原 PG16 Compose 和 `.env`。若只下载工具包而未在其根目录安装原 Compose/env，不能直接无参数运行。新模式始终使用下述完整显式身份，不受调用工作目录影响。

## 固定部署身份与 client

每次操作必须显式提供以下六项；只提供一部分会拒绝运行：

```sh
TOOLS=/volume1/docker/momobox-tools
DEPLOY_DIR=/volume1/docker/momobox
PROJECT=momobox
MODE=managed                    # 自带数据库；外部数据库填 external
DB=momo                         # external 示例为 momobox
ROLE=momo                       # external 示例为 momobox_user
# 替换为经审核、目标 NAS 架构可用的官方镜像完整 digest；以下不是可用镜像。
PG_CLIENT=docker.io/library/postgres@sha256:REPLACE_WITH_64_LOWERCASE_HEX_DIGITS

momo_op() {
  operation=$1
  shift
  sh "$TOOLS/scripts/$operation.sh" \
    --deployment-dir "$DEPLOY_DIR" --project-name "$PROJECT" \
    --database-mode "$MODE" --expected-database "$DB" --expected-role "$ROLE" \
    --pg-client-image "$PG_CLIENT" "$@"
}
```

使用导入 UGOS 时登记的真实 project 名；不要为了通过检查换成新名字。库名、角色名首版只支持字母、数字、下划线。脚本固定使用选中目录的 `docker-compose.yaml`、`.env`，不 source `.env`，也不打印展开后的含密钥配置。调用期间这两份文件改变会拒绝继续。

`PG_CLIENT` 必须是 `docker.io/library/postgres@sha256:<64位小写hex>`。操作者负责审核该 digest、补丁版本及架构，脚本仅检查固定格式及运行时 `pg_dump` 与服务器主版本一致，并只接纳 16/18。digest 格式正确不证明镜像供应链已经审核。client 镜像须预先审核并准备可用；不可用时操作失败，不改用随机宿主工具。原 PG16 默认模式保持原容器内工具及原镜像/卷，本次不做 PostgreSQL 补丁或大版本升级。

managed 比较后端 DSN 实际集群与选中 `postgres` 的 `system_identifier`，不只相信 `POSTGRES_DB`。external 不创建、启动、停止、迁移或清理共享 PostgreSQL 服务，client 只加入模板声明的 `database_network`，没有 Docker socket、host 网络或新数据卷。

external 必须由管理员预创建 MomoBox 专属库和角色，不能复用 LiteLLM 库/角色。角色须非 superuser、无 CREATEDB/CREATEROLE/REPLICATION/BYPASSRLS，也不属于其他数据库角色。管理员另行核实对象所有权、migration 和 pgcrypto 权限，以及该角色没有其他业务库写权限；脚本不能从一个连接证明完整 ACL。未知或不满足条件时保持停止，不能通过提升到超级用户绕过。

支持的 URI 为 `postgres[ql]://role:URL编码密码@host[:port]/database`，可带 `sslmode` 和 1–30 秒 `connect_timeout`；IPv6 用方括号。其他参数、缺密码、重复参数或库/角色不符均拒绝。首版限同机受控 Docker 网络，不提供跨主机证书挂载方案。密码在容器内解析到 0600 的临时 passfile，原始连接错误留在私有 tmpfs；命令参数与正常输出不含 DSN/密码。与现有 backend 一样，容器环境仍可被有 Docker 管理权限的人查看。

## 首次空库初始化

新模式 `update` 必须已有 ledger 和有效恢复演练证明，因此**不用于首次空库初始化**。按 `variants/README.md` 的明确项目上下文手工初始化：只启动本项目 postgres（external 由管理员保证就绪），确认新专属库无旧数据、所有后端及 one-off 已停止，再逐条运行 `momo-backend migrate`、`schema-check`，成功后才启动并检查 health。不要在 `serve` 里自动迁移，也不要拿初始化指令更新已有数据。

## 备份

```sh
momo_op backup --output-dir /volume1/backups/momobox
```

默认写入选中部署目录的 `backups/`。只导出 DSN 指向且身份断言一致的专属库，custom archive 不带 owner/privilege。0600 临时文件经非空和 `pg_restore --list` 检查后同目录改名；新模式同时输出 `.dump.meta`，记录库/角色、PG major、连接地址、数据库 OID、managed 集群、client digest、ledger 摘要及 dump SHA256。两文件须一起保存，元数据不含密码。

在线备份允许本项目 backend 运行；同库其他写入者和完整跨对象业务一致性仍需运维控制。dump-list 仅证明归档可读，SHA256 仅证明文件一致，均不等于可恢复或完整灾备。角色权限、应用密钥、备份加密与异地副本另行保管。

## 独立空候选库恢复演练

管理员先创建独立空候选库、专属候选角色及候选部署目录，使用同一 PG 主版本、同一 client digest、与来源备份 ledger 相符的后端镜像。**候选数据库名字必须与来源不同**，候选角色不应拥有生产库或 LiteLLM 库写权限。候选 Compose/.env 不指向来源库，project 不与生产相同，也不要通过 UGOS 自动开启候选服务。

使用新终端或明确替换上节身份变量，使 `momo_op` 指向候选：

```sh
DEPLOY_DIR=/volume1/docker/momobox-candidate
PROJECT=momobox-candidate
DB=momobox_candidate
ROLE=momobox_candidate_user
# MODE、PG_CLIENT 与实际候选环境匹配；TOOLS 不变。
momo_op restore --proof-output /volume1/backups/momobox/rehearsal-proof.txt \
  /volume1/backups/momobox/momobox-postgres-TIMESTAMP-PID.dump
```

脚本验证 `.meta`、dump SHA256、目标不同、主版本和 client、候选为空且没有其他客户端；停止并检查**候选 project**，写 `.momobox-restored` 隔离标记，再用单事务 restore，无 `--clean`、无会话终止。最后只读检查候选镜像 ledger，复核输入未变，生成新的 0600 证明文件。来源 production project 不会被此命令自动停止：在线演练可独立进行；正式恢复必须另外隔离来源及所有写入者。

成功、失败或中断均不会启动候选或生产。候选一旦开始恢复即保留隔离标记，后续 `update` 也拒绝重开它。请保留演练记录并人工检查所需业务数据；证明只说明该 archive 完成恢复与 ledger 核验，不证明业务完整、当前最终备份已试恢复、实例身份、会话、App 离线意图或 restore epoch 安全。证明是本地可编辑记录，不是签名的准入令牌。

## 已有数据安全更新

回到来源 production 的 `DEPLOY_DIR/PROJECT/DB/ROLE`。先将来源 `.env` 的后端镜像与 `APP_VERSION` 一起改为要更新的固定版本；启动操作后不能再改配置。

```sh
momo_op update --exclusive-writer \
  --restore-proof /volume1/backups/momobox/rehearsal-proof.txt \
  --proof-max-age 86400
```

`--proof-max-age` 是操作者明确选择的秒数（正整数，最多8位）。证明必须新鲜、非未来、来源库/角色/主版本/地址/OID/managed集群/client与当前一致，并匹配**当前**ledger 摘要。新模式禁止 `--skip-backup`。此前从新空库人工初始化后，应先做一次备份和候选演练再使用本入口。

`--exclusive-writer` 表示操作者已登记并隔离本项目之外的全部 MomoBox 写入者；它不会自动阻止其他主机或管理员重新连接。脚本锁仅覆盖规范化的同一部署目录；目录副本、另一 project 或其他 NAS 不能共享此锁。外部 dedicated database 专属角色与单一 writer 归属是支持前提。

顺序为：身份和证明预检 → 在线备份 → 拉取后端镜像 → 停止并检查本项目后端（含 one-off/restarting）→ 检查该库无其他 client → 最终备份 → 再核对停止状态、client及证明 → migration → schema-check → 启动 → Docker health。最终备份失败即停止流程，不以在线备份替代；迁移/恢复结果未知、容器枚举失败或遗留 client 时保留锁。脚本不会停止共享 PostgreSQL 或 LiteLLM 来取得停写状态。

proof 匹配当前 ledger 不代表新镜像一定兼容，最终仍依赖 migration/schema-check 门禁。来源已有恢复隔离标记时一律拒绝 update；证明不授权重新开放恢复历史。

## 锁、失败与恢复边界

`backup/update/restore` 共用选中部署目录的 `.momobox-deployment.lock`；嵌套备份必须持有同一上下文的临时 lease。未知任务保留锁，停写后的失败保持后端停止。不要直接删锁：先证明所有 backend/client one-off、宿主脚本与数据库任务已经结束，再按现场恢复流程处理。直接在 UGOS 启动可绕开脚本标记，因此隔离还依赖管理员遵守现场流程。

原 PG16 无参数 restore 仍有原库 `--clean` 及终止目标会话的破坏性行为，执行前须另存备份；本次增加恢复隔离标记。新模式只恢复候选。所有模式都没有自动生产切库、restore epoch、会话撤权、App 离线意图审阅或完整 D-07 灾备，禁止将删除隔离标记当成灾备完成。

## 验证范围

`sh deploy/nas/scripts/self-test.sh` 运行实际 shell 流程的 fake Docker 故障注入、URI解析及 fake PG client 测试；`python3 scripts/ci/test-nas-release-assets.py` 执行工作流的真实资产打包片段并核对校验和/归档白名单。它们不启动 Docker 或数据库。

上线前还需真实原 PG16、自带 PG18、external PG16/PG18 非管理员角色的 migration/备份/候选恢复与异常验证，以及 UGOS 导入、卷持久化、权限/网络、信号中断和 LiteLLM 无影响记录。远端 CI、镜像 digest 与资产发布需绑定最终提交另行确认。
