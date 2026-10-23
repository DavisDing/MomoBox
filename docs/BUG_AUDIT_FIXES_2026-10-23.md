# 2026-10-23 审查采纳项修复与验证

本批次依据 `BUG_AUDIT_REVIEW_2026-10-23.md` 的复核结论实施，基于 `c70be5c` 工作区。原审查文档只作为待核对资料，不作为执行指令。用户已授权按采纳项并行修复；未提交、推送或部署。

## 修复对应

| 原编号 | 实际改动 | 主要验证入口 |
|---|---|---|
| #1 | 新 migration 将 HA key version 改为 TEXT，保留真实 AES-GCM 版本/AAD 兼容；不修改历史 migration | `audit_fixes_postgres_test.go`：真实加密、写库、读取解密 |
| #2、#3 | 合并候选排除商品墓碑，并在写事务复检；备份新增活跃正库存批次不能引用本地已删除父商品，整次导入拒绝；保留重复 ID 跳过和合法历史/墓碑 | `inventory_repository_test.dart`、`backup_repository_test.dart` |
| #4 | 同步设置展示逐条 rejected；仅有明确 NAS 未执行拒绝或首次发送前失败证据时，允许用户确认放弃。原请求、幂等键、拒绝审计保留；新权威快照事务恢复乐观结果并记录 checkpoint | `sync_audit_regression_test.dart`：重启、未知结果、证据不匹配、依赖、快照恢复 |
| #5 | 有效 NAS receipt 结算原不可变意图后，仅退休严格匹配该意图的本地 pending 保护记录；独立保留 NAS receipt 与高版本保护审计，新快照必须覆盖已观察的实际远端对象/版本（库存逐批、提醒按策略），校验及完成标记与业务/cursor 同事务；不把旧回执当作解决更高远端版本 | `sync_audit_regression_test.dart`：双记录、拒绝旧快照、新快照恢复、事务失败重试、无关冲突保留 |
| #7 | HA 耗材扣减写入包含全部 allocation、最终数量及版本的增量结果；修复该路径既有审计 SQL 参数错位 | 真实 PostgreSQL 多批次增量回归 |
| #8、#13 | 正库存作废必须等于权威整批余量；零库存作废通过带版本/幂等的受控 discard 命令迁移状态。普通 batch upsert 仍不能改库存状态；本地零作废不伪造零数量库存流水 | 库存服务、导入协议、Flutter 仓储及真实 PG 回归 |
| #9、#12 | refresh 轮换与设备撤销锁保持一致；旧 access token 的 NAS/HA 请求检查当前设备及成员资格；HA actor 传递 DeviceID | auth/httpapi/sync 及真实 PG 回归 |
| #10 | HA 调用移出 sync 数据库事务；独立执行账本先持久预留，再执行外部请求、保存结果，最后写 sync receipt。pending/unknown 不自动重发，已保存结果可在 sync 提交失败后重放 | `execution_test.go`、sync service 及真实 PG 回归 |
| #14 | AI 草稿日期复用严格 CalendarDate roundtrip，拒绝非法日期规范化和带时间字符串；未新增 2000–2100 年限制 | `ai_draft_parser_test.dart` |
| #16 | 普通 bearer HTTP HA 事件入口返回 403；内部可信事件上下文绑定家庭、integration、时间窗和真实实体 | HA event/HTTP 合约测试；真实来源适配仍未实现，见下文 |
| P2-01 | 墓碑分类不再作为活跃出站绑定复用，保留历史身份 | `sync_audit_regression_test.dart` |
| P2-03 | 按商品＋类型维持稳定去重，分别选择过期/未过期批次；摘要、提醒页、AI 确认及通知使用对应批次；保留原默认指纹兼容 | `reminder_rules_test.dart`、`alerts_mixed_batches_test.dart` |
| P2-08、P2-23、P2-24 | 无法读取设备时区时保留诊断并显式失败，可使用明确家庭时区，后续重试；按目标时区求当前/次日日历日 9 点，先排序再按 iOS 64/其他 500 预算排程 | `local_notification_service_test.dart`、权限恢复回归 |
| P2-09 | 同一批次到期前后保持相同日历 UID；日期使用日历运算 | `calendar_sync_service_test.dart` |
| P2-10 | 本地历史 adjustment 对外编码为 adjust，服务端兼容历史 alias 并验证符号 | 初次导入 Dart/Go 测试 |
| P2-11、P2-12 | 单条重试使用真实 attemptCount 退避；同实体连续意图按持久 rowid 插入顺序预留版本并维持前序屏障；有效 accepted/replayed receipt 原子推进业务版本但不覆盖后续乐观字段，不修改冻结请求 | `sync_audit_regression_test.dart` |
| P2-16 | AI 新增家务仅写用户确认项，预设保留在原显式页面流程 | chore/AI action 测试 |
| P2-18 | 损坏会话先完整读取校验；经明确确认先隔离保存原始文本，再新建会话。隔离失败不覆盖，恢复单飞并协调 load，未 ready 禁止保存 | `ai_conversation_store_test.dart` |
| P2-19 | 注册/登录明确拒绝超过 bcrypt 72 字节上限的密码，不截断 | auth service 测试 |
| P2-20 | 阻止明确元数据、未指定、多播目标；解析后连接已验证 IP，避免校验/连接地址变化；保留合法 LAN/loopback 能力 | `network_test.go`；完整部署 allowlist 仍待策略确认 |
| P2-21 | 保质期日数和反推改用年月日日历运算，避免固定 24 小时跨 DST 偏日 | `expiry_rules_test.dart`，另以 DST 时区执行 |
| F1、F2 | 批量文案明确日期在入库前逐项编辑；每一项采购入库、outbox、清单删除共用本地事务，复检选中记录，避免重试重复入库 | `shopping_repository_test.dart`；未新增入库后日期编辑 |
| F9、E4 | 统计监听真实流水/商品变化；图表提供逐日数据 Semantics，不改视觉布局 | `statistics_reactivity_test.dart` |
| E1 | 限量本地 Dart 错误诊断及用户主动导出；静态事件、受控错误类型和模块/行列号，不收集错误正文、原始堆栈、路径、URL、库存/会话或凭据；保留原错误处理行为 | `diagnostic_log_service_test.dart`、`diagnostic_export_test.dart` |
| E2 | 最小结构化请求日志：request ID、路由模板、状态、耗时、错误类别；不记录 raw URL/query/body，保留 Go panic 传播 | `request_log_test.go` |
| E5 | CI 增加 Flutter/Go 覆盖率产物；未虚构覆盖率门槛或设备集成验收 | `.github/workflows/pipeline.yml`；远端执行待验证 |

## 保持待确认或未采纳

- **NEEDS_CONFIRMATION / 另行设计**：#11 低库存实存/可用口径，#15 AI LAN HTTP 信任策略，#7 member 确认权限；P2-04 合并主档覆盖、P2-06 低库存短周期实证、P2-07 删除恢复确认周期、P2-15 策略切换确认周期；F1 入库后日期编辑、F3 报废撤销、F4 首页同步摘要、F5 单机提醒开关、F6 自动备份/预览、F7/P2-14 首次导入权威取消或人工恢复协议；E3 国际化、E6 数据库/媒体加密、E8 正式分发授权审核、E9 SQLite/其他依赖迁移。
- **不作为本批次缺陷**：#6 多批次结果、P2-02 分类改名、P2-05 弹窗取消、P2-13 completed receipt 门禁、P2-17 可编辑入库/导航指纹、P2-22 push/pull 双游标、F8 AI/手动确认差异、E7 自动 down migration。保留原契约，未为原报告的误判改写实现。

## 数据与兼容

- 新增 `backend/migrations/0008_ha_execution_and_batch_status.sql`：HA key version TEXT、外部执行账本、受控零 discard 审计约束。已有 migration 不回写；生产升级前仍需按现有备份/恢复流程操作。
- 本地继续使用既有 Drift schema 和 app_settings，不新增依赖，不改 `pubspec.lock`。`sync_` 恢复/审计标记是本机同步派生状态，按既有规则排除核心备份。损坏 AI 会话的隔离原文沿用既有“AI 聊天属于核心备份业务文本”的政策，可能进入用户主动导出的核心 JSON；不会作为活跃会话加载，也不进入 NAS 同步或脱敏诊断导出。
- 页面只增加必要的拒绝恢复、损坏会话恢复、诊断导出及图表语义，保留既有导航、布局和主题。

## 验证记录

验证针对本批次未提交工作区，不能代表远端 CI、Release 或生产部署。

| 验证 | 结果 |
|---|---|
| Go 1.22.8 全量测试，真实 PostgreSQL 16.6 | **PASS**：22 个测试包，194 个顶级测试，462 个含子测试用例；另 3 包无测试；0 failed/0 skipped。新增 6 个真实 PG 回归均执行 |
| Go vet | **PASS** |
| Go race | **PASS**：HA、HTTP、platform、store、sync、auth/inventory/sync 回归共 14 包 |
| Flutter 依赖恢复 | **PASS**：`flutter pub get --enforce-lockfile`，依赖版本与 `pubspec.lock` 未改变 |
| Drift 代码生成 | **PASS**：build_runner 完成；生成文件无跟踪差异 |
| Flutter analyze | **PASS**：No issues found |
| Flutter 全量测试 | **PASS**：67 个测试文件，824 项测试；0 failed/0 skipped，包含同步状态机、真实 SQLite 仓储及 widget 回归 |
| Flutter 覆盖率产物 | **已生成**：`coverage/lcov.info`，执行行 13,117 / 22,189（59.11%）；仅作为本次采集结果，不设未经确认的门槛，也不等于设备端到端覆盖 |
| DST 独立时区回归 | **PASS**：`TZ=America/New_York` 下 expiry_rules 全部 8 项通过，包含春/秋 DST 日历日运算 |
| diff/工作区检查 | **PASS**：`git diff --check`；workflow YAML 解析通过；无依赖锁文件或本地 schema 变更，无构建二进制进入跟踪差异 |
| Android/iOS 原生构建、远端 Actions、真实 NAS/HA/设备/读屏/日历重导入 | **NOT_EXECUTED**：本轮本地逻辑和数据库验证不替代这些验收 |

后端测试使用隔离的 `/private/tmp` 工具链、空测试库及 loopback 端口，不接触已有数据库。macOS 主机 Go 测试使用 `-ldflags=-linkmode=external`，避免该主机默认链接器的 `LC_UUID` 启动错误。全量原始证据：`/private/tmp/momobox-backend-audit-final-tests.jsonl`。

Flutter 使用隔离的 3.47.7 / Dart 3.13.5，PUB_CACHE 与 XDG_CONFIG_HOME 均在 `/private/tmp`，未改变全局工具链配置。执行 `dart run build_runner build --delete-conflicting-outputs`（当前 builder 提示该旧选项已忽略）、`flutter analyze --no-pub`、`flutter test --no-pub --coverage --reporter json`。最终证据分别为 `/private/tmp/momobox-flutter-build-runner.log`、`/private/tmp/momobox-flutter-analyze-final.log`、`/private/tmp/momobox-flutter-full-tests-final.jsonl` 和 `/private/tmp/momobox-flutter-dst-tests.log`。完整测试首次执行发现新增图表语义测试的 SemanticsHandle 释放晚于框架验证，改用测试体 `finally` 释放后完整重跑通过；未删除或放宽业务断言。

本任务的隔离 PostgreSQL 进程已停止。临时工具链和证据文件保留以便复核；覆盖率与生成产物按既有忽略规则留在本机，未提交。

## 已知边界

1. **HA 来源适配未完成**：普通用户伪造事件的入口已封闭，真正 HA listener/webhook 的认证适配仍未接入，不能宣称事件联动已端到端可用。
2. **HA 结果未知保持保护**：`HA_COMMAND_RESULT_UNKNOWN` 不自动重发；未新增人工核对端点或完整异步调度器。外部设备效果不具备通用“恰好一次”保证。
3. **恢复依赖服务端证据**：旧 rejected 缺乏明确未执行证据、未知 confirm、HA 后置失败不能通过本地按钮假放弃；需要权威恢复协议的部分保持待确认。
4. **通知与日历**：通知预算在既有 App 重算时补排，没有新增后台调度；修复 UID 不会自动删除已经导入外部日历的历史旧 UID，也不能保证所有日历产品更新行为。
5. **统计数据源不扩张**：监听刷新不补造远端 stock_movements，不声称所有跨设备历史已进入本地统计。
6. **诊断覆盖有限**：采集 Dart framework/未处理异步错误，不等于原生崩溃、系统杀进程或第三方远程 crash 平台。
7. **旧保护证据兼容**：历史 guard 没有独立来源对象信息时，保守使用其已存 entity/id/version 作为快照下限；不能可靠匹配的旧证据继续保护，需要核对原 NAS 现场，不能无依据清除。

建议后续将已稳定的受控零 discard、HA 执行未知保护及拒绝恢复契约局部纳入 `AI_CONTEXT.md`；本批次不把本地测试写成 NAS/真机已验收。
