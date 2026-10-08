# 2026-10-06 可靠性复核与续修

## 范围与基线

本次可靠性检查与加强覆盖同步、核心备份、HA 控制，以及调度竞态、集成复核和验证记录。

- 接续 `docs/IMPLEMENTATION_BATCH_2026-10-03.md` 的未提交工作区，不重置、不覆盖无关改动。
- 不新增依赖、数据库 schema 或后端协议；不调整已确认页面布局和主题。**历史范围说明（superseded，2026-10-07）**：后续补修新增 NAS migration `0005`；没有新增本地 schema/依赖/设置编辑 UI，具体范围见下方接续记录。
- 代码修改不等于验收通过；本机没有 Flutter/Dart/Go/Docker，未安装工具链，未提交或推送。

## 调度竞态修复

启动网络查询与网络事件可能乱序返回。原实现会让旧查询覆盖较新的 online/offline 事件，导致断网继续调度或联网恢复计时被取消。现在按网络事件修订号丢弃过期初始结果；重复事件也标记初始查询已过期，但不会重设 debounce。

新增四个回归场景：旧 online 不能覆盖新 offline、旧 offline 不能取消新 online 恢复、启动排队后断网不执行、启动排队后进入后台不执行且前台恢复可执行。测试源码已加入，尚未运行。

## 复核发现与处理范围

| 工作包 | 已确认问题 | 本轮处理约束 |
| --- | --- | --- |
| 同步 | 多批次命令忽略各 allocation 的权威数量/版本；后批次失败可能留下前批次写入；提醒策略 tombstone/upsert 顺序导致替换失败 | 使用现有 DTO，不扩协议；命令原子处理与回归；提醒同实体删除优先 |
| 核心备份 | URL 的 auth/sig/signature 参数可能随备份迁移；软删除记录丢失删除标记，恢复后复活 | 双向净化；保留可选业务删除标记及旧 v1–v3 兼容，不迁移身份/同步版本 |
| HA | member 被管理连接测试接口挡住；家居测试缺房间；零亮度滑块越界；弹窗错误与设备消失未完整反馈 | 复用现有角色权限与实体读取接口；不放宽后端权限；不重设计 UI |

以下为代码实现状态，不代表 Flutter 或真实环境验收通过。

### 同步完成的续修

- 逐批读取现有后端 `final_quantity`/兼容数量别名与 `after_version`，不使用主批次版本更新所有批次；缺失批次、重复 batch、缺权威字段和非法结构/数值在写入前拒绝。
- 整条库存命令的业务写入、applied receipt 和安全游标同事务提交。后批次、receipt 或游标失败均回滚；故障解除后可重试，已提交命令重放不再次增减。保留事务外冲突预检、事务内复检和回滚后记录；依赖 blocked 的本地编辑也受保护。
- 提醒 snapshot 先处理 tombstone 再处理替换策略，合法记录顺序不再决定能否替换。
- 引擎已存在 receipt 时避免再次写入；页面完成不回退已提交安全游标，失败与冲突不越过阻塞变化。
- 补多批次版本、非法 allocation、写故障/receipt 故障/游标故障、幂等重试、冲突留存、提醒替换回滚和分页安全游标测试。主要文件：`lib/application/sync_business_adapter.dart`、`lib/application/sync_engine.dart`及各自的 `test/application/` 测试。源码已复核，未运行。
- 本地 Drift 生成文件落后于 schema，现有 CI 必须先跑既有 `build_runner` 步骤。本轮未手改生成文件，未把文件引用存在性当成类型检查。

### 核心备份完成的续修

- 服务 URL 增加 auth/sig/signature 及常见签名参数过滤；规范化历史 camelCase 身份前缀，保留正常业务键、条码占位符及非敏感 query（包括重复值）。
- 商品、批次、采购可选 `deleted_at` 双向保留，并在写入前校验日期。未升级 JSON 版本，v1–v3 缺字段仍按旧默认；目标已有主键（包括已删除记录）不会被旧备份覆盖。流水仍引用原商品/批次，恢复不丢引用。同步版本及设备 metadata 仍不迁移。
- 补双向 URL 净化、软删除跨空库恢复、流水引用、同步版本隔离、旧版本缺/有标记、非法删除日期整批拒绝、目标软删除保护测试。源码已加入，尚未运行。
- 主要文件：`lib/domain/backup/backup_format.dart`、`lib/data/repositories/backup_repository.dart`、`test/domain/backup_migration_policy_test.dart`、`test/data/backup_migration_boundary_test.dart`。

### HA 完成的续修

- member 不调用 owner/admin 专用管理连接测试；除禁用集成外，历史状态不阻断授权实体读取，以实体 ID 匹配且新鲜的实际状态确认可用性。没有可见实体不伪报在线；不借用其他角色 grant。owner/admin 仍走原管理测试，不放宽后端权限。
- 两个家居电视 widget 夹具明确传客厅；真实零亮度保留 0% 文案，仅滑块展示限制到合法范围。
- 控制失败反馈置于原电源 subtitle，避免被弹窗遮住；设备移除、权限撤销、退出或控制器替换后弹窗关闭，迟到回执不污染新状态。
- 补角色管理权限、缓存恢复、禁用/错配/过期/403、零亮度、弹窗失败可见性、设备消失与控制器替换回归。未分区设备不展示在现有三房间卡片区域，维持当前 UI 现状并记录测试，未把该限制称为已解决。
- 主要文件：`lib/presentation/controllers/smart_home_controller.dart`、`lib/presentation/screens/smart_home_screen.dart`、`test/presentation/home_ha_quick_actions_test.dart`。测试未运行。

## 仍需确认或下一阶段处理

1. **superseded — 临期策略（2026-10-07 已批准）**：历史问题为 NAS 默认七天与本地固定三十天不兼容，曾选择安全拒绝；现已批准默认30、商品→家庭→默认、显式7保留、禁用不改变库存/过期事实、开封提醒暂不支持，不再待确认。实现与未验收状态见接续记录。
2. **superseded — 已有库存收敛（2026-10-07 已批准）**：历史问题为快照保留本地数量却提升 serverVersion；现已批准 NAS库存权威、整个scope无未解决操作/冲突才应用quantity/version、推送后重新fetch并确认checkpoint、未知结果复用原operationID，不再待确认。历史恢复仍未完成，不能据此视为整个同步闭环已验收。
3. **未完成 — 同步历史与出站分类**：消费历史 bootstrap/增量恢复、字符串分类到服务端 UUID 的创建/映射仍缺闭环；历史追加不能再次扣库存。
4. **需加强 — 升级兼容**：旧版商品已经保存分类 UUID 而没有新绑定时，同版本快照不会修复名称或绑定；需有针对性的升级兼容方案及回归，不直接覆盖本地更新。
5. **未完成 — 已有后续规划**：scene/script 执行闭环、AI 混合控制、联动配置/事件来源、完整媒体/OCR 文件归档、社区共享不在本轮可靠性修复范围。
6. **未验证 — 真实环境**：本批次 Flutter/Go CI、真实 PostgreSQL/NAS/HA、多设备、Android/iOS 真机仍未验收。

## 实际执行的验证

2026-10-06 本机执行：

- PASSED：逐文件 Shell 语法检查（CI/release/NAS）。
- PASSED：`bash scripts/ci/test-prepare-flutter-platforms.sh`。
- PASSED：`bash scripts/release/test-next-version.sh`。
- PASSED：`sh deploy/nas/scripts/self-test.sh`；仅语法、参数与 help 行为，不是 NAS 实机部署。
- PASSED：Ruby Psych 解析 workflow YAML；仅语法，不是 GitHub Actions 执行。
- PASSED：本地 Dart import/export/part 目标存在性检查（复核 508 个目标，无缺失）；不是 Dart 静态分析。
- PASSED：`git diff --check`。
- NOT_EXECUTED：Flutter analyze/unit/widget/integration、Drift 生成、Android/iOS 构建、Go test/vet、Docker/PostgreSQL 和真实 NAS/HA。
- NOT_EXECUTED：本批次新的 GitHub Actions；未推送，历史成功运行不代表当前工作区通过。


## 2026-10-07 接续记录（保留 2026-10-06 历史，不作为新验收结果）

- 上述两项待确认已由用户批准，历史“拒绝非30窗口”“只保留已有quantity却推进version”说明为 superseded。提醒有效策略与权威数量保护已在当前工作区接入；不是测试通过或可生产使用。
- 提醒复用 app_settings，默认30、商品→家庭→默认、显式7保留，禁用只影响提醒；开封提醒继续显式不支持。UI 限两处标题“临期提醒”和通知正文，无新增设置编辑 UI/本地 schema/依赖；不删除或归并既有 HA/UI 未提交改动。
- scope 无 pending/in-flight/blocked/rejected/outbox conflict/open或deferred冲突才应用权威quantity/version；同版本可纠偏，旧版不回退，snapshot与完成标记/安全游标同事务。先标记refresh_required再push，scope静默后重新fetch、确认checkpoint才应用；未知结果复用原operationID等幂等标识。
- checkpoint 最终拟定为相同cursor复用有效token，变cursor产生新token并重新确认；最新后端落盘源码已见相同cursor分支，但尚未验证。中间“每次fetch无条件旋转”方案 superseded；业务行/cursor从同一repeatable-read快照读取。
- 批次 `status` 到本地报废/数量的映射已补充：discarded→isDiscarded；active/used_up/expired非报废，used_up/discarded必须零quantity；expired按expiryDate事实判断，不伪造日期，未知状态/冲突字段fail closed。refresh网络期间比较pending/checkpoint/用户模式基线，旧响应不能覆盖新keep_local_only。代码已落盘并完成源码复核，相关回归用例源码已补充，测试/验收未执行。
- 远端同步确认新增serverCursor>=snapshotCursor校验，invalid/rejected receipt不抬pushAckCursor；写刷新标记前及fetch返回后的事务均比较pending/checkpoint与mode，手动bootstrap刷新必需但响应缺snapshot时保留pending/refresh并失败。代码已落盘并完成源码复核，相关回归用例源码已补充，测试/验收未执行。
- NAS新增 `0005`：只改新默认30、不UPDATE旧值；全局statement级事务advisory lock在identity分配前排序cursor、sequence CACHE1，持锁至提交/回滚。跨家庭吞吐/锁等待、排空旧连接与sequence缓存、备份部署和补偿回滚均待实机验证，不能认为历史漏读已被自动修复。
- CI已新增PG16 service及MOMO_TEST_DATABASE_URL，真实cursor测试opt-in、缺URL则skip；本轮尚未跑。Flutter/Dart/Go/gofmt/Docker/psql在本机缺失，测试/构建/真实环境/CI仍未验收；2026-10-07轻量实跑结果已记入VALIDATION，不复制历史PASSED作为本批代码通过。
- 未完成：消费历史bootstrap/增量恢复、出站分类创建/UUID映射及升级兼容、HA scene/script/AI混合控制/联动配置和事件来源闭环。完整决策、验收和部署补偿记录见 `docs/IMPLEMENTATION_DECISIONS_2026-10-07.md`。

### 2026-10-07 实跑补充（非代码验收）

- PASSED：CI/release脚本逐文件bash -n、NAS脚本逐文件sh -n；平台壳回归、版本计算回归、NAS参数/help自测；Ruby YAML.load_file读取pipeline.yml；git diff --check。
- PASSED（仅文件存在）：Python检查Dart import/export/part非package目标326条全部存在。上方2026-10-06的508是历史统计，可能包含不同包映射口径，未重核；不能与326混称，二者均不是编译/analyze。
- 工具发现：command -v检查flutter/dart/go/gofmt/docker/psql均无输出；Flutter/Go/PG16/CI/真机及真实环境仍NOT_EXECUTED或DEVICE_VALIDATION_PENDING。
- 未自动提交或推送，CI待跑；详项和证据边界见VALIDATION。
