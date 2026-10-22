# NAS 两套 Compose 运维适配方案（2026-10-22）

状态：**O-1–O-4 已实现并完成离线验证；O-5 发布打包与指南已接入，真实现场验收 NOT_EXECUTED**。用户已批准按推荐方案实现；未授权或执行真实数据库/NAS操作。以下第1–8节保留实施前方案与核对记录（基线 `ee70ffd47c32a288fd75c61ef0cc7f6d8b92085b`），当前实现、差异和验证以第9节为准。其他并行任务的 App/后端改动不作为本文运维验收证据。

目标是让原 PG16、自带 PG18、复用外部 PostgreSQL 使用同一套运维实现，保留现有失败隔离和数据保护。首次空库仍走明确的手工 migration/schema-check；正式恢复切换与 D-07 灾备不在本次实现内。

## 1. 当前实现与直接缺口

| 源码依据 | 已有能力 | 本次需要补齐的部分 |
| --- | --- | --- |
| `deploy/nas/scripts/{update,backup,restore}.sh:7` | 从脚本位置推导原 NAS 目录，固定读取原 `docker-compose.yaml` | 无选择其他部署目录、项目名、env 或数据库模式的公共入口 |
| `backup.sh:140`、`update.sh:174`、`restore.sh:137` | 启动本项目 `postgres`，在其容器内调用 PG 工具 | 外部版没有该服务；不能指向 LiteLLM 项目冒充本项目服务 |
| `update.sh:160` 起 | 在线预备份、拉镜像、停后端、最终备份、migration、schema-check、健康启动 | 所选部署上下文必须传递至所有子调用，不能只让顶层读到新 Compose |
| `deployment-lock.sh:8`、`backend-isolation.sh` | mkdir 共享锁、restarting 检查、未知任务结果保留锁 | 锁与实例枚举须绑定所选部署；当前锁不隔离其他目录、项目或数据库写入者 |
| `restore.sh:149` 起 | 停后端后原库单事务恢复；成功、失败和中断均不重开服务 | 新外部模式不能复制 `--clean` 原库恢复；候选库与上线准入须分开 |
| `backend/internal/platform/schema_check.go` | 只读检查 migration ledger 的版本、名称和 checksum | 不证明业务完整、候选库安全、历史代次正确或 App 可继续同步 |
| `.github/workflows/pipeline.yml:338`、`:442` | 打包两套 Compose/env 与说明 | 资产存在不证明新脚本、外部库、PG18 或 UGOS 已验收；新脚本发布打包需单独接入 |

原 PG16 固定 `postgres:16.4-alpine`、原卷 `postgres_data` 与新增 PG18 卷 `postgres18_data` 均保持原状。不得因适配运维入口替换 PG 大版本、复用旧数据目录、删除卷或重写已应用 migration。

## 2. 推荐实现结构与明确接口

复用原三个脚本的流程，不给每套模板复制一份。建议新增两个内部 helper，原入口以兼容方式调用：

| 文件 / 入口 | 推荐职责 |
| --- | --- |
| `deploy/nas/scripts/deployment-context.sh`（待新增） | 一次解析并验证部署目录、Compose/env 绝对路径、project、模式、期望库/角色及 client 选择；提供唯一 `compose()` 与清理前的身份复核 |
| `deploy/nas/scripts/postgres-client.sh`（待新增） | 统一实现连接检查、身份/版本查询、dump、dump-list 和受控候选库 restore；不包含服务启动或 migration 策略 |
| `backup.sh` | 复用私有临时文件、非空检查、dump-list、同目录原子改名和共享锁；通过 client helper 访问数据库 |
| `update.sh` | 复用现有在线备份→停写→最终备份→migration→schema-check→健康启动的状态与 trap |
| `restore.sh` | 保留原模式行为；新增模式仅提供明确候选库验证入口，禁止自动切换数据库或启动生产后端 |
| `backend-isolation.sh`、`deployment-lock.sh` | 在已核验上下文中枚举项目容器和运维 one-off；不扩展为接管外部 PostgreSQL 生命周期 |

以下仅为**拟议 CLI 合同，当前脚本不支持**，不是可执行操作指令：

- 三个入口共用 `--deployment-dir DIR`、`--project-name NAME`、`--database-mode managed|external`；目录确定后固定使用其 `docker-compose.yaml` 与 `.env`。首版不开放任意 `-f` 叠加或任意服务名，减少操作目标歧义。
- `--expected-database NAME`、`--expected-role NAME` 是显式断言，不是切库参数；连接后必须与 `current_database()`、`current_user` 一致，失败停止。
- external 另需 `--pg-client-image IMAGE@sha256:...`，仅接受经过审核且固定 digest 的官方 PG client 镜像。client 大版本与实际服务器相同；不允许缺工具后改用宿主随机版本。
- 原入口不传新参数时仍解析到原 PG16 目录与模式；新增目录必须显式指定完整部署身份，不从当前工作目录、同名容器或 `DATABASE_URL` host 猜项目。
- `backup --output-dir` 保留；update 新模式不允许 `--skip-backup`。原模式的既有选项保留兼容和警告，不能悄悄扩大到外部模式。
- `restore` 新模式必须指定独立候选部署上下文和预创建空候选库，验证目标不等于来源库；不把 `--yes` 当作覆盖目标库断言。
- 可新增只读 `--plan`，展示模式、project、文件身份、脱敏库/角色、client 与将执行的阶段；不得输出 DSN、展开后的全量 Compose 或密钥。plan 成功不代表连接、停写或升级验收。

不使用 `eval`、把 `.env` 作为 shell 脚本 source、命令行拼接密码或默认 `set -x`。内部子调用用明确参数传递同一已解析上下文；测试覆盖空格路径、拒绝重复/未知参数及父子上下文错配。

## 3. 数据库 client、网络与身份

### 3.1 managed：原 PG16 和新增 PG18

仍在所选项目的 `postgres` 容器内调用匹配工具；仅管理该项目的数据库服务。新目录选择不改变容器镜像、卷挂载和初始化账号。

开始前比较后端实际连接目标与本项目 PostgreSQL 的非敏感身份：主机/端口、库名、当前角色、服务器版本、必要时由管理员记录的集群身份。现有模板允许 `DATABASE_URL` 与 `POSTGRES_DB/USER` 分开配置，不能只备份 POSTGRES_DB 却让 migration 写另一个库。无法证明目标一致时拒绝升级。

首次空库初始化和已有库升级是不同入口：不得在 `serve` 内自动 migration。自动初始化如后续获准，只能在明确全新专属库、无 ledger 且无既有业务对象时继续；检查不通过转人工处理，不能靠清库实现“初始化”。

### 3.2 external：复用同主机 PostgreSQL

使用独立短生命周期 client 容器，只连接已批准的 `DATABASE_NETWORK` 和明确 DB alias，不使用 host 网络或 Docker socket，不发布端口、不新增持久卷，不停止或修改外部数据库/LiteLLM。

client 推荐由独立运维 override/service 定义，和所选 project 使用同一上下文及标签，便于信号后的枚举；此文件是后续实现范围，当前不创建。该 service 不参与日常 `up`，只允许显式 one-off 运行，不能挂到错误项目。基础模板的双服务/单服务合同保持，运维 override 不作为 UGOS 默认导入文件。

凭据通过权限受限的临时挂载文件传入 client，使用 libpq 支持的连接配置与 passfile；宿主只保留到任务清理，不把完整 DSN 放 argv。配置渲染若需读取环境，只处理白名单键，不记录完整 `compose config`。网络名、预期数据库和角色是非秘密配置；密码和 TLS 材料不写方案、报告或 Git。

连接后执行只读预检并断言：

1. `current_database()`、`current_user`、服务器主版本与显式目标一致；查询连接身份不等于 restore epoch。
2. MomoBox 专属库/角色已由管理员创建；非 superuser，无 CREATEDB/CREATEROLE/REPLICATION，所需 `public` 对象所有权与 `pgcrypto` 可用。不得拿 LiteLLM 库、角色或超级用户给失败兜底。
3. 运行环境的 client `pg_dump/pg_restore` 大版本与服务器相同，完整工具镜像固定 digest；客户端缺失、镜像不可拉、版本未知或不匹配均拒绝继续。
4. 网络属于已确认的同主机受控网络。跨主机/TLS/证书挂载与 ACL 是 D-05 后续方案，不能把样例 `sslmode=disable` 扩大到公网。
5. 专属应用角色与数据库的备份/恢复权限要在一次性环境实测。脚本不创建角色、不授予超级权限、不终止同实例其他库会话。

`pg_isready` 或 TCP 连接成功只能证明连接端点响应；必须实际执行上述身份与权限检查。新模式不得连接失败后自动选择另一库或另起一个 PostgreSQL。

## 4. 锁、停写、最终备份与失败隔离

锁根目录固定在规范化部署目录，同一部署 backup/update/restore 共用；锁元数据记录 project、模式和非敏感目标摘要。父 update 调用 backup 只能复用其持有、身份一致的锁；外部传入 `MOMOBOX_DEPLOYMENT_LOCK_HELD=1` 不能单凭环境变量跳过检查。已有锁不自动删除，保留人工核验入口。

**该文件锁不能阻止同库其他 Compose 项目、目录副本、管理员或其他 NAS 写入。** 首版推荐只支持一个已登记的 MomoBox writer 项目；外部库管理员确认专属角色及全部 writer 归属。无法列举/隔离其他 MomoBox writer 时拒绝升级，不能用停止 PostgreSQL/LiteLLM 作为隔离捷径。后续跨主机操作锁若需要，须独立设计数据库级长会话锁与连接中断语义。

update 状态流建议维持：

1. 配置/身份/版本/权限只读预检，确认最终备份输出位置及目标归属；获取共享部署锁。
2. 在线预备份并校验；拉取固定后端镜像。失败时现有后端不停止。
3. 停止所选项目所有 MomoBox 后端，枚举 `running/restarting/paused` 等状态并核验 one-off。外部模式完全不启动/停止数据库。
4. 检查其他 writer 的隔离依据，创建停止后端后的最终备份。失败不以在线旧 dump 替代，立即保持停机。
5. 再查后端仍停止、目标未变，执行 migration，再执行 schema-check；保留原 checksum/旧版本/rollback 门禁。
6. 仅正常升级且未发生恢复历史分叉时启动后端并等待实际 health；health 不能代替业务和 App 验收。
7. 信号、停机/枚举失败、migration/client 结果未知或遗留 one-off 未终止时保留锁和隔离状态。不能仅因 shell 子进程退出就推断 daemon 容器及数据库事务已经结束。

dump 保留 `custom-format`、`--no-owner --no-privileges`、0600 临时文件、非空、dump-list 和原子改名。建议增加脱敏 sidecar：数据库/角色断言、PG/client 版本、后端 image ID、migration 集合摘要、时间、文件 SHA256 与完成阶段；sidecar 不含密钥，也不是 D-07 的完整灾备 manifest。

dump-list 只验证归档可读性。上线前必须有相同工具/目标版本的独立空库恢复演练，按明确有效期引用；未做、过期或校验不匹配时新模式 update 拒绝放行。保留周期、异地副本和加密备份包由运维/灾备方案分别确认，不在本批次暗中承诺 RPO/RTO。

## 5. 恢复范围：保持停机，候选验证与切换分开

原 PG16 restore 的既有原库行为不因兼容适配扩大适用面；其任何结果仍不自动启动后端。新增模式不提供直接覆盖生产库的默认路径。

推荐新模式仅支持**恢复至管理员预创建、身份已验证、独立的空 MomoBox 候选库**：

- 来源库和目标库的身份必须不同；候选角色只拥有候选库，无权写 LiteLLM 或原 MomoBox 库。不存在、非空、身份不可确认、权限不足或工具版本不匹配直接失败。
- 原应用保持停写；如要在线演练副本，必须作为明确的隔离演练任务，不以其结果替代最终停写点备份。
- 新候选库恢复不使用原库的 `--clean`；依旧单事务、遇错退出、不导入全实例角色/其他库，不自动终止共享实例全部会话。
- schema-check 指向候选部署与候选 DSN，不能用源部署 `.env` 误检原库；验证后端不得发布原端口或承担真实写入。
- 恢复成功只报告 dump 恢复与 ledger 核验完成，保留生产服务隔离。失败/中断保持候选证据和原库，结果未知保留锁。
- 不自动改生产 `DATABASE_URL`、切流、清 cursor/outbox、重置幂等回执或重开用户会话。实例/restore epoch、撤权、App 离线意图审阅和正式切换属于 D-07，仍 **NEEDS_CONFIRMATION / 未实现**。

## 6. 工作包、依赖与验收

| 工作包 | 写入范围（待实施） | 验收目标 | 依赖 |
| --- | --- | --- | --- |
| O-1 部署上下文与原版兼容 | 新 context helper；原三个入口参数解析；上下文 fixture | 默认原路径行为不变；显式选目录/env/project；身份不一致拒绝；特殊路径/参数/子调用无秘密泄漏 | 本方案实现范围批准 |
| O-2 PG client 抽象与备份 | 新 client helper/运维 override；backup适配；版本/身份夹具 | 原PG16、PG18和外部专属库分别正确 dump；只读预检失败无写入；不影响其他库 | O-1；外部版本与责任确认 |
| O-3 更新流程与故障隔离 | update/isolation/lock适配；扩展 test-safety | 最终备份失败不迁移；错 project/同库其他 writer 阻断；信号/未知任务保锁；不停止外部PG或LiteLLM | O-2；有效独立恢复演练 |
| O-4 候选库恢复验证 | restore新增模式、隔离候选context和测试 | 目标必须空/不同；误指来源或LiteLLM拒绝；成功/失败都不重开生产，不自动切换 | O-2；候选库权限及范围确认 |
| O-5 打包与现场验收 | 操作指南、版本资产/CI验证入口；设备记录 | 同版本脚本与helpers可取得；三模式真实回归、UGOS导入、权限/网络失败、数据卷保留、停止/恢复流程有证据 | 前四包收敛；明确设备环境 |

O-1 完成公共接口后，O-2 的 client/备份与 O-4 的候选验证测试设计可分离；O-3 与 O-4 都改共享入口/锁，不应无 owner 地同时改同文件。每包提交前做集成，不以单包模拟通过代表真实数据库或 NAS 通过。

真实验收矩阵至少包含：原 PG16 回归、自带 PG18 新空库/持久化、外部 PG16 与 PG18 专属非管理员角色、错库/错用户/不存在网络/无 pgcrypto/权限不足、client 大版本不符、pull失败、最终备份失败、restarting/枚举失败、one-off遗留、migration/schema/health失败、信号中断、无效dump、候选非空/误指源库，以及 LiteLLM 服务与其数据保持不变。跨主机、其他主版本和未登记 writer 不自动列为支持。

## 7. 版本核对与本次验证

2026-10-22只读核对 PostgreSQL 官方版本策略与18.6发布说明，18.6 的发布日为 **2026-08-13**；Docker 官方 `official-images` 的 postgres 清单列出 `18.6-alpine3.24`。因此当前模板标签并非仅凭名称就应判错，本次不替换镜像。官方清单不能证明用户NAS可拉取、目标架构可运行或当前registry digest；这些仍需实际验证。原PG16的16.4不是本次批准的补丁升级，后续应单独核对补丁安全与兼容，不与本适配混改。

实施前方案核对阶段执行：

| 检查 | 结果 | 限制 |
| --- | --- | --- |
| 源码/部署合同交叉核对 | 已完成 | 只确定当前文件行为及方案，不是功能验收 |
| `sh deploy/nas/scripts/self-test.sh` | **PASS** | shell语法/help/参数及12项fake Docker故障模拟，17.852秒；不验证新增模式 |
| 本文空白检查 | **PASS** | 对新增文件逐行检查尾随空白与末尾换行；不代表可执行脚本或真实数据库通过 |
| Docker/Compose/Go/psql运行 | **NOT_EXECUTED** | 本机PATH未发现这些工具；未安装工具/依赖 |
| PG18/外部角色/UGOS/升级/恢复 | **NOT_EXECUTED** | 无真实环境运行，不从旧CI或模拟推导通过 |

官方只读参考：

- PostgreSQL版本策略：<https://www.postgresql.org/support/versioning/>
- PostgreSQL18.6发布说明：<https://www.postgresql.org/docs/release/18.6/>
- Docker官方postgres镜像清单：<https://github.com/docker-library/official-images/blob/master/library/postgres>
- pg_dump版本限制：<https://www.postgresql.org/docs/current/app-pgdump.html>

## 8. 最少待确认事项

1. **实现范围**：是否采用本方案的共享 helper、三模式备份/升级适配和新增模式“仅候选库恢复验证”；保留正式切换/epoch独立待决。批准实现不等于授权对真实NAS执行。
2. **外部数据库现场**：目标主版本、已存在Docker网络/唯一alias、专属库与非管理员角色、全部MomoBox writer归属，以及由谁保管角色/密钥并负责独立恢复验证。只需非秘密身份与责任，不在聊天中发送密码。
3. **设备验收范围**：选定自带版、复用版或两者，确定可用UGOS/测试数据库环境；新模式不支持的跨主机/TLS等范围先保持不变。

D-07完整灾备、备份加密工具/配套密钥包、正式切换与 RPO/RTO 无需在开始 O-1 前一次性批准；但未经单独设计/批准不得越过恢复后的停机边界。长期事实验证完成后可建议局部更新 AI_CONTEXT，本文不覆盖历史证据。


## 9. 已批准实施结果（2026-10-22）

| 工作包 | 当前结果 | 验收界限 |
| --- | --- | --- |
| O-1 | 公共context/helper、显式目录/env/project/模式/库/角色/client；原默认PG16兼容 | 离线参数/空格路径/子调用/配置指纹/伪继承锁检查通过；真实Compose未运行 |
| O-2 | 原模式容器内PG工具；managed/external固定digest client、连接身份/主版本/外部非特权角色检查、dump与sidecar | 实际awk/client shell经fake PG验证；无真实SQL或角色权限验收 |
| O-3 | 原更新阶段复用；证明新鲜度与来源identity/ledger门禁、停写后最终备份、其他连接检查、未知client/迁移保锁、恢复隔离标记拒绝update | 故障注入通过；单writer归属依赖运维登记，目录锁不覆盖其他NAS/项目 |
| O-4 | 新模式仅不同名字、预创建空候选库；单事务无clean/会话终止；只读schema-check后生成本地证明，任何结果不启动 | 模拟通过；真实归档/业务数据恢复、正式生产切换、epoch与App历史验证未实现/未验收 |
| O-5 | OPERATIONS.md与两份README、operations工具包显式白名单、版本化release资产与SHA256回归 | 打包片段离线执行通过；远端CI/实际资产发布、UGOS/数据库设备验收待执行 |

当前共享入口详见 `deploy/nas/OPERATIONS.md`。新增工具包只包含12个明确列出的运行时脚本/helper/override/指南，不含真实.env、dump、proof、锁和测试。原PG16/PG18 Compose数据库镜像与卷未改动；无新增宿主依赖安装，也未变更App/UI或业务数据库结构。

与历史推荐方案的具体实现差异：

- 新managed与external复用同一固定digest one-off client，减少两份解析/凭据逻辑；managed另向本项目postgres查询system_identifier并交叉匹配DSN，原默认PG16仍使用原容器工具。client仅显式run，不参与日常serve。
- 沿用现有Compose的DATABASE_URL环境注入，在client私有tmpfs内转换成0600 libpq service/passfile；没有把.env作为shell source，也没有把秘密放argv。Docker管理员仍可inspect容器环境，此方式没有新增凭据保密边界。
- 首版不提供自动空库初始化或`--plan`。初始化仍用固定目录/project/env的手工入口，不能通过跳过备份/证明把空库当已有数据升级。
- 新模式restore只停止所选候选project，来源production需另行隔离。在线独立演练允许来源继续运行；证明不等于最终停写备份已演练，也不承担自动生产切换。
- 证明是本地未签名的演练记录，验证dump SHA256、来源identity与ledger匹配；并非全灾备manifest或授权令牌。标记只在工具内生效，UGOS手工启动须遵守现场隔离流程。

最终本地验证：

| 检查 | 结果 | 实际覆盖 |
| --- | --- | --- |
| `sh deploy/nas/scripts/self-test.sh` | PASS | shell语法/help/参数；12项原脚本安全、17项变体故障注入、9项真实awk/client shell（fake PG） |
| `python3 scripts/ci/test-nas-release-assets.py` | PASS | 执行工作流NAS打包段；11项总资产、10项SHA256、工具归档12文件白名单/字节/执行权限、无敏感夹具、发布列表一致 |
| operations YAML与workflow解析 | PASS | Ruby YAML语法解析；不等于Compose渲染/网络/卷行为 |
| workflow 33个run块 `bash -n` | PASS | shell语法，不调用Flutter/Docker或发布 |
| 本次文件空白检查 | PASS | 包括新增未跟踪文件，不依赖git diff覆盖新增内容 |
| Docker/Compose/PostgreSQL真实运行 | NOT_EXECUTED | 本机PATH无docker/psql/go；未安装或拉镜像 |
| PG16/PG18、external角色、UGOS、真实升级/恢复、远端CI/release | NOT_EXECUTED | 无现场验收，不以fake daemon或历史CI推导成功 |

尚需现场确认目标PG主版本/补丁、client digest/架构、实际project/network/唯一alias/专属库角色、全部writer、凭据备份责任及恢复演练有效期。D-07的正式切换、restore epoch、会话撤权、离线意图审阅、加密包、RPO/RTO继续独立待决。长期运维事实可在取得真实证据后由文档owner局部更新AI_CONTEXT；本文不覆盖旧验收记录。
