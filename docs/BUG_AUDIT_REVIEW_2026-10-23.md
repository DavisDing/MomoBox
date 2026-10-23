# 外部 Bug 审计复核（2026-10-23）

## 结论与证据边界

审查对象：`/Users/dinghao/Downloads/bug-audit-2026-10-22.md`。当前 HEAD 为 `c70be5c`，与原报告基线一致，开始复核时工作区干净。已读取 AGENTS、AI_CONTEXT、REQUIREMENT、DESIGN，并对照生产组装、调用者、协议、数据库约束和相关测试源码。

**报告有实质价值，但不能原样作为修复清单。** 它发现了真实的数据可见性、同步恢复和认证缺口，也存在遗漏完整调用链的误报、后果夸大、将产品扩展视为 Bug、修法违反现有协议等问题。尤其不接受“以下全部是现有测试覆盖不到的”这一概括：多批次权威结果已有专门回归用例，数据库探活也已有测试。

本次是源码复核；“成立”表示当前代码足以支持该缺陷判断，不等于已在真实环境复现。Flutter、Dart、Go、Docker 均未在当前 PATH 找到，未安装或下载工具。没有执行 analyze、Flutter/Go 测试、构建、数据库、NAS、HA、真机或读屏验收；没有独立确认原报告的 762/762 结果，也没有查询远端 CI。仅新增本复核文档，未修改业务代码或既有需求。

下文逐项覆盖原报告 16 条编号问题、24 条 P2、9 条流程意见和 9 条工程意见，共 58 个条目；重复事项仍保留原定位，不重复计算修复任务。

判定：**成立**＝有直接源码证据；**部分成立**＝问题存在，但前提、后果或修法须修正；**不成立**＝当前代码存在反证；**待验证**＝缺少可达场景或运行证据；**产品建议**＝需要需求决策，不直接认定实现缺陷。优先级均是本次建议，并非用户已批准的实施范围。

## 第一部分：原编号问题

| 原编号 | 判定 / 建议优先级 | 复核结果与修改建议 |
|---|---|---|
| #1 HA key_version | **成立 / P1，HA 交付阻断** | [AESGCM:39](/Users/dinghao/Downloads/MomoBox/backend/internal/securetoken/aesgcm.go:39) 返回字符串，生产组装确实使用该实现；[parseKeyVersion:290](/Users/dinghao/Downloads/MomoBox/backend/internal/store/hapostgres/integration.go:290) 只接收正整数，初始 SQL 列也为 INTEGER。创建路径无法成功，读回整数也不满足 Decrypt 的版本检查。增加新 migration 对齐持久化表示；不要修改已应用的 0001。整数版本与算法拆列是可选架构方案，不是本次必需；若更改版本字符串，须同时考虑它参与 AES-GCM AAD 的兼容性。 |
| #2 合并墓碑商品 | **成立 / P1** | [候选查询:209](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/inventory_repository.dart:209) 未排除 deletedAt，[合并写入:246](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/inventory_repository.dart:246) 只判存在，[列表:100](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/inventory_repository.dart:100) 却过滤删除行。会产生不可见的新批次。候选过滤与写事务内复检都要做，不能只修查询而留下选择后删除的竞态。数据仍在库中，应称“业务不可见”，不称物理删除。 |
| #3 备份导入墓碑 | **部分成立 / P1** | [引用集合:254](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/backup_repository.dart:254) 接纳本地墓碑，且 [写入:124](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/backup_repository.dart:124) 可跳过父商品后导入活跃子批次，造成报告计数成功但库存不可见。另一方面，“已有同 ID 商品不恢复”符合 AC-007 默认不覆盖规则，本身不是 Bug。不能简单过滤全部墓碑：备份有意保留软删除信息，历史引用也不同于活跃业务引用。应区分活跃/墓碑父子关系，冲突整事务拒绝或明确报告；恢复/覆盖必须另定规则。 |
| #4 rejected 永久阻塞 | **成立 / P1** | [解析失败:685](/Users/dinghao/Downloads/MomoBox/lib/application/sync_engine.dart:685) 和远端 rejected 只终结 outbox，不创建可操作 conflict；[阻塞判断:230](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/sync_outbox_repository.dart:230) 又保留 rejected，[结算:929](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/sync_outbox_repository.dart:929) 必须有有效 NAS conflict receipt。引擎在 pull 前检查静默条件，确实可卡住整个 scope。设置页可能显示错误或计数，故“完全没有任何可见信息”过强，但没有逐条拒绝记录及恢复入口成立。补显式本地拒绝处理、审计与依赖重算；不能把结果未知的库存/HA 命令按“未执行”随意丢弃。 |
| #5 两条 conflict 卡死 | **成立，有路径前提 / P1** | [pull 保护:681](/Users/dinghao/Downloads/MomoBox/lib/application/sync_business_adapter.dart:681) 记录远端 changeId＋本地 outboxChangeId；该路径需要例如 pull 等待期间出现本地编辑，因为正常 pull 前引擎会先检查 scope 静默。后续 push 冲突 [markConflict:902](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/sync_outbox_repository.dart:902) 可新增本地 changeId 的另一行。[结算:1023](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/sync_outbox_repository.dart:1023) 只处理选中行，[检查:1121](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/sync_outbox_repository.dart:1121) 仍会发现另一行。**仅改调用 recordConflict 不够**：其现有去重键包含 changeId，两个不同 ID 仍不合并。须定义同一业务冲突组和回执覆盖范围，同事务处理已被该回执解决的关联记录；不可按 outbox ID 盲清所有不同远端冲突。 |
| #6 多批次只同步第一批 | **不成立** | [repository:856](/Users/dinghao/Downloads/MomoBox/backend/internal/store/syncpostgres/repository.go:856) 已将所有 allocation 的 final_quantity、before/after_version 放进同一 payload；[adapter:589](/Users/dinghao/Downloads/MomoBox/lib/application/sync_business_adapter.dart:589) 逐批按各自版本原子应用。原报告建议的“复合 payload”已存在。[现有测试:400](/Users/dinghao/Downloads/MomoBox/test/application/sync_business_adapter_test.dart:400) 明确检查非主批次数量、版本与后续更新。保留跨真实 PostgreSQL/HTTP 的验证即可，不应拆日志修复一个不存在的问题。 |
| #7 HA 联动扣库存 | **部分成立 / P1** | [联动写入:700](/Users/dinghao/Downloads/MomoBox/backend/internal/store/hapostgres/automation.go:700) 更新批次并写 deduction、consumption 和联动审计，但未写供设备增量接收的 change_log；这是实际同步缺陷。应复用库存规则或共用事务能力并补完整权威结果。member 可确认与 owner/admin 可配置规则是两种不同权限；[角色判断:260](/Users/dinghao/Downloads/MomoBox/backend/internal/homeassistant/automation.go:260) 的存在不能单独证明越权。是否限制“建议确认”为管理员应标 NEEDS_CONFIRMATION，不能顺手收紧产品权限。 |
| #8 零余量报废不出站 | **成立 / P2** | [discardBatch:578](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/inventory_repository.dart:578) 只在余量大于零时 enqueue。零余量报废仅改本地标记，后续权威 used_up/active 状态可覆盖它；这是状态丢失，并没有额外正库存因此丢失。**不能直接补普通 batch upsert**：[服务端保护:177](/Users/dinghao/Downloads/MomoBox/backend/internal/store/syncpostgres/entities.go:177) 禁止普通 upsert 修改 status/quantity，库存 discard 也要求正数。应先定义可幂等、带版本的零数量状态迁移。已有 scope 未结算保护应继续保留。 |
| #9 设备撤销后刷新/HA | **成立 / P1** | [Refresh:114](/Users/dinghao/Downloads/MomoBox/backend/internal/auth/service.go:114)、[Rotate:66](/Users/dinghao/Downloads/MomoBox/backend/internal/store/authpostgres/refresh_tokens.go:66) 未校验设备当前撤销状态；[Revoke:107](/Users/dinghao/Downloads/MomoBox/backend/internal/store/authpostgres/sync_devices.go:107) 只更新设备。[HA Actor:168](/Users/dinghao/Downloads/MomoBox/backend/internal/httpapi/handler.go:168) 丢弃 DeviceID，直接 HA 路由不校验其撤销。每次轮换重新计算 TTL，因此持续轮换风险不限于“撤销后的原 30 天”。旋转事务需与撤销保持一致，敏感请求需验证设备及当前成员状态；只在 Refresh 外层先查一次不足以处理竞态。 |
| #10 HA 在事务内 HTTP | **部分成立 / P1** | [HA 执行:876](/Users/dinghao/Downloads/MomoBox/backend/internal/store/syncpostgres/repository.go:876) 位于 serializable 事务内，外部效果不能随 PG 回滚；提交失败后重试可能再次发出操作。**“该 HA 请求持有全局 cursor 锁”无现有调用链支持**：GetIdempotency 获取的是 family/device/key 锁，HA 成功分支仅读 CurrentCursor，未 AppendChange；0005 的全局锁在 INSERT change_log 时取得。也不能用未开放的门锁控制举例。可设计命令持久状态/事务外执行，但异步 outbox 本身不提供物理动作恰好一次，仍需未知结果、查询对账和目标端幂等语义。全局 cursor 改锁范围应另行证明提交顺序安全及性能收益。 |
| #11 低库存含过期量 | **行为成立，业务口径待确认 / P2** | [totalStock/isLowStock:147](/Users/dinghao/Downloads/MomoBox/lib/domain/models/inventory_models.dart:147) 计算实存量，[availableQuantity:157](/Users/dinghao/Downloads/MomoBox/lib/domain/models/inventory_models.dart:157) 排除过期，两者确有差异。但 [DESIGN:637](/Users/dinghao/Downloads/MomoBox/docs/DESIGN.md:637) 的“有效批次总量”和现有“商品总量”口径需要统一，不能直接以 availableQuantity 替换所有库存展示。建议低库存/补货采用可用量，同时保留实存量和过期提醒；产品确认后联动修改排序、筛选、采购、确认周期。原文“预警全失声”不成立，过期提醒仍生成。 |
| #12 移除成员后同步 | **成立 / P1** | [ResolveDevice:19](/Users/dinghao/Downloads/MomoBox/backend/internal/store/syncpostgres/repository.go:19) LEFT JOIN 得到空 role，但 [Pull:157](/Users/dinghao/Downloads/MomoBox/backend/internal/sync/service.go:157)、Push、Bootstrap、ConfirmBootstrap 只判断设备撤销；HTTP 层只核对 token 与请求 deviceId。当前不存在完整移除成员业务入口，但成员关系失效后的鉴权缺口仍成立，不能只靠“目前无按钮”忽略。统一校验当前有效成员角色，并在事务边界复检；设备/refresh 联动撤销作补强，不代替每次授权。 |
| #13 部分报废整批失效 | **成立 / P1** | [plan:217](/Users/dinghao/Downloads/MomoBox/backend/internal/inventory/service.go:217) 仅拒绝 quantity 大于批次量，随后 [Execute:157](/Users/dinghao/Downloads/MomoBox/backend/internal/inventory/service.go:157) 无条件标 discarded；数据库无 discarded 必须 quantity=0 的联动 CHECK。可形成 discarded/正余量，且违反 AC-013。最小方案是整批报废要求相等；若支持部分损耗，应减少数量并让剩余批次保持可用，不必发明“部分报废”整批状态。正常 App 当前发送全部余量，不代表服务端可以不校验。 |
| #14 AI 草稿非法日期 | **成立 / P2** | [AiDraftParser:60](/Users/dinghao/Downloads/MomoBox/lib/domain/recognition/ai_draft_parser.dart:60) 未做年月日 roundtrip。应复用严格日历解析；优先考虑 [CalendarDate.decode:13](/Users/dinghao/Downloads/MomoBox/lib/domain/inventory/calendar_date.dart:13)。直接复用 AiInventoryAction.date 会同时引入其 2000–2100 年限制，这属于额外约束，需确认是否适用于所有 OCR/AI 草稿。 |
| #15 AI 允许 HTTP | **风险成立，强制策略待确认 / P2** | [URI 校验:24](/Users/dinghao/Downloads/MomoBox/lib/application/ai_client_helper.dart:24) 允许 HTTP，请求在这种配置下没有 TLS 保护。项目有用户自配局域网 AI/Ollama 场景，非 loopback 一律 HTTPS 会禁用常见 NAS/LAN 服务。建议远程地址要求 HTTPS，可信 LAN HTTP 明确告知并单独确认；结合实际密钥/上下文发送路径定义策略，不把自配 HTTP 直接等同于已发生泄漏。 |
| #16 用户态提交 HA 事件 | **成立，来源信任缺口 / P1（正式启用联动前）** | [ProcessHAEvent:251](/Users/dinghao/Downloads/MomoBox/backend/internal/homeassistant/automation.go:251) 接受普通家庭 actor，缺少可信 HA 来源证明。具有有效规则、设备及库存时可提交非真实设备事件；这不表示任意匿名调用或 member 配置规则。建议按 integration 绑定认证、来源验证、去重与重放保护，或由后端订阅 HA。单一全局 webhook 密钥不足以定义家庭/集成隔离；普通成员能否人工报告完成须作为独立功能确认。 |

## 第一部分：24 条 P2 复核

| 定位 | 判定 | 复核与建议 |
|---|---|---|
| P2-01 分类墓碑身份映射 | **成立 / P1–P2** | [删除分支:330](/Users/dinghao/Downloads/MomoBox/lib/application/sync_business_adapter.dart:330) 未撤销 identity/binding，而 [出站:1035](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/inventory_repository.dart:1035) 优先复用该 ID。应使墓碑分类不可再被活跃商品引用，保留必要历史映射；与 #4 联动处理，不能只删辅助记录。 |
| P2-02 分类改名删除旧映射 | **原推断不成立** | [applyRemoteCategoryName:65](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/inventory_repository.dart:65) 同时更新绑定商品名称，[出站:1037](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/inventory_repository.dart:1037) 还有 remoteCategories 精确名称查找。旧名解绑是预期生命周期，不足以证明“同名重复”。旧名重新使用、未绑定商品、并发改名可另做验证，不据 rename 函数单独报错。 |
| P2-03 过期批次遮蔽其他临期 | **成立 / P2，方案需保持契约** | [提醒候选:134](/Users/dinghao/Downloads/MomoBox/lib/domain/inventory/reminder_rules.dart:134) 只看最近批次，过期后 continue，其他有效批次无单独临期候选。AC-005 当前按商品＋类型去重，不宜直接改成每批一条；可分别选择最近过期与最近未过期批次，在既有去重维度补齐候选。 |
| P2-04 合并丢字段 | **行为存在，产品建议** | [合并:270](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/inventory_repository.dart:270) 保留既有商品主档，只更新时间。修改新批次不自动覆盖既有位置/阈值可合理；按条码生成候选本就要求相同条码，原“随后扫码匹配不到”不是已证明的正常路径。建议合并确认明确哪些字段沿用，若要覆盖主档再定义规则。 |
| P2-05 点击对话框外关闭 | **不构成已证明 Bug / 体验建议** | [候选弹窗:234](/Users/dinghao/Downloads/MomoBox/lib/presentation/screens/shopping_screen.dart:234) 确实允许关闭，但所有候选都在写入前规划，取消时未提交任何一项，且有“取消本次入库”选项。是否禁止外部关闭是交互取舍，无需为此新增硬限制。 |
| P2-06 低库存 1→6→1 漏清确认 | **待验证 / P2** | [清理:168](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/reminder_repository.dart:168) 依赖观察到正常终态，指纹仅含 threshold，确有无法表达新周期的结构性风险。原文尚未提供“这些业务更新确实在同一事务且实际可达”的证据；需围绕真实仓储/Stream 调度构造跨路径回归，再决定把周期更新纳入库存事务或增加周期标识。 |
| P2-07 删除后 ack 保留 | **条件风险 / P2** | 清理只遍历当前活跃商品，删除对象不会被清掉；相同 ID/相同阈值复活可能匹配旧确认。新建不同 UUID 不受影响。应确认软删除/恢复是否开新提醒周期，保留备份内合法确认信息，不能全部清空。 |
| P2-08 时区失败 UTC 回退 | **部分成立 / P2** | [initialize:33](/Users/dinghao/Downloads/MomoBox/lib/services/local_notification_service.dart:33) 吞错误，没有可见诊断；但 [_nextNineAm:184](/Users/dinghao/Downloads/MomoBox/lib/services/local_notification_service.dart:184) 有 familyTimeZone 时直接选家庭时区，不走 tz.local。17:00 是无家庭时区且设备位于 UTC+8、初始化失败的条件后果，不是普遍现象。需用当前锁定插件版本和真实设备返回格式验证。 |
| P2-09 日历 UID 翻转 | **成立，影响依赖外部日历 / P2** | [过期 UID:113](/Users/dinghao/Downloads/MomoBox/lib/services/calendar_sync_service.dart:113) 与 [未过期 UID:147](/Users/dinghao/Downloads/MomoBox/lib/services/calendar_sync_service.dart:147) 不同，重新导入可能重复。建议同批次稳定 UID，另核对 SEQUENCE/更新策略；仅改 UID 不能保证所有日历客户端替换旧导入。 |
| P2-10 adjustment 导入拒绝 | **成立 / P1，首次导入阻断** | [补充写 adjustment:538](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/inventory_repository.dart:538)，[导入白名单:193](/Users/dinghao/Downloads/MomoBox/lib/application/initial_import_service.dart:193) 仅有 adjust。须对齐本地类型、manifest 与服务端历史白名单，保留原流水并校验符号，不能只放宽一个客户端条件。 |
| P2-11 重试无退避 | **部分成立 / P2** | [retryAt:677](/Users/dinghao/Downloads/MomoBox/lib/application/sync_engine.dart:677) 已有固定 _backoff(1)，[全局失败:956](/Users/dinghao/Downloads/MomoBox/lib/application/sync_engine.dart:956) 另有指数退避，故“无退避”错误。缺失单条结果路径没有利用 attemptCount 递增逐项退避与告警是真的；也不能称无延迟无限循环。 |
| P2-12 accepted 不写业务版本 | **成立，有并发/连续编辑前提 / P1** | [terminal:1355](/Users/dinghao/Downloads/MomoBox/lib/data/repositories/sync_outbox_repository.dart:1355) 只改 outbox，下一条同实体编辑可能在 pull 前仍引用旧 serverVersion；同轮 push 多条更易触发。正常 push 后 pull 可补齐，因此“否则必然冲突”过强。修复要原子应用回执且不越过本地未决编辑；已有冻结请求和 idempotency key 不可直接重写。 |
| P2-13 导入门禁依赖 NAS receipt | **现状成立，Bug 判定不成立** | [engine:360](/Users/dinghao/Downloads/MomoBox/lib/application/sync_engine.dart:360) 确在持久 completed receipt 后放行普通结算，这是 [DESIGN:1335](/Users/dinghao/Downloads/MomoBox/docs/DESIGN.md:1335) 已写明的行为；[_persistCompletedReceipt:353](/Users/dinghao/Downloads/MomoBox/lib/application/initial_import_service.dart:353) 同事务使旧快照失效。全部快照/历史应用前仍不报告导入完成。不能仅凭本地 awaitingSnapshot 就认定提前越权放行；应做恢复竞态测试。 |
| P2-14 confirmStarted 无放弃 | **产品/恢复设计问题，见 F7** | 未知提交结果必须保留原计划，不允许客户端单方面宣布未提交。与 F7 是同一事项，不重复安排修复。 |
| P2-15 7↔30 天旧确认复活 | **待确认语义 / P2** | [fingerprint:179](/Users/dinghao/Downloads/MomoBox/lib/domain/inventory/reminder_rules.dart:179) 的确在返回旧窗口时返回旧指纹。但只改策略、同一批次同一到期事实是否应强制新周期，当前需求不如低库存恢复规则明确。若产品确认每次策略变更需重提醒，再增加策略 revision 或废弃旧确认；不要先破坏已有确认兼容。 |
| P2-16 AI 首次新增家务附带预设 | **成立 / P2** | [AI add:308](/Users/dinghao/Downloads/MomoBox/lib/application/ai_inventory_action_service.dart:308) 调用 [addChore:63](/Users/dinghao/Downloads/MomoBox/lib/application/chore_service.dart:63)，后者 getChores 会初始化预设。确认一项动作却可能额外新增预设，违反确认范围。AI 写路径读取已保存列表，预设初始化保留在显式 UI 流程。 |
| P2-17 intake/open_page 无指纹 | **不构成当前契约违约** | [IntakeSheet:185](/Users/dinghao/Downloads/MomoBox/lib/presentation/widgets/ai_assistant_dialog.dart:185) 明确允许编辑草稿，提交前复检权限和会话，再由真实库存服务验证合并对象；open_page 只是导航，恢复/清理仍在目标页面确认。这两种操作按 [DESIGN:1298](/Users/dinghao/Downloads/MomoBox/docs/DESIGN.md:1298) 就不等价于预先冻结一个既有业务对象。实际写入的竞态保护可另查，不能以缺同一种指纹直接报错。 |
| P2-18 会话损坏永久 loading | **部分成立 / P2** | [load:104](/Users/dinghao/Downloads/MomoBox/lib/application/ai_conversation_store.dart:104) 任一字段损坏可令 ready=false，但 [UI:393](/Users/dinghao/Downloads/MomoBox/lib/presentation/widgets/ai_assistant_dialog.dart:393) 已有错误信息/重试，且错误时不显示加载动画。因此“永久 loading、没有错误入口”不实；确定性损坏重试仍失败，确实缺隔离坏记录、导出原始内容或显式重置恢复流程。不能为自愈静默覆盖原会话。 |
| P2-19 密码 rune/bcrypt 字节 | **成立 / P2** | [校验:259](/Users/dinghao/Downloads/MomoBox/backend/internal/auth/service.go:259) 允许最多128 rune，[hasher:14](/Users/dinghao/Downloads/MomoBox/backend/internal/auth/bcrypt.go:14) 使用有72字节限制的 bcrypt。长 ASCII 也受影响，不只中文。应明确字节上限并返回可理解的校验错误；不要截断密码，若改算法需考虑旧 hash 兼容。[外部依据 S4] |
| P2-20 HA URL SSRF | **风险成立，策略需适配 NAS / P1–P2** | [ValidateBaseURL:29](/Users/dinghao/Downloads/MomoBox/backend/internal/homeassistant/validation.go:29) 不限制目标 IP，[client:25](/Users/dinghao/Downloads/MomoBox/backend/internal/store/hahttp/client.go:25) 禁跳转但无专门 dial 策略。HA 本来需要 LAN，loopback 也可能是合法同主机配置，不能简单禁止全部内网。需明确 owner/admin 的信任边界、部署目标 allowlist、元数据/非预期地址保护及解析后连接校验。当前只能认定网络目标约束缺失，不能直接声称已读出云凭据。 |
| P2-21 DST 保质期日运算 | **成立 / P2** | [calculateExpiry:46](/Users/dinghao/Downloads/MomoBox/lib/domain/inventory/expiry_rules.dart:46) 和反推使用固定 duration；本机 DST 日期跨切换可能得到非午夜或错误日。适用性由日期实际表示/设备时区决定，不简单取决于“家庭在 DST 地区”。改用年月日的日历运算并回归 canonical 日期。 |
| P2-22 push cursor 跳过他人 | **不成立（当前客户端）** | [push:194](/Users/dinghao/Downloads/MomoBox/backend/internal/sync/service.go:194) 聚合的是请求 baseCursor 和各 outcome cursor，不是该段无条件查询家庭 MAX；[client:813](/Users/dinghao/Downloads/MomoBox/lib/application/sync_engine.dart:813) 写 pushAckCursor，[pull:845](/Users/dinghao/Downloads/MomoBox/lib/application/sync_engine.dart:845) 用独立 pullCursor。不存在报告假设的续拉跳跃。保持双游标契约回归即可。 |
| P2-23 _nextNineAm DST | **条件风险 / P2** | [next day:188](/Users/dinghao/Downloads/MomoBox/lib/services/local_notification_service.dart:188) 对 date 做固定24小时加法再取年月日；在本地 DST 值可能偏日，canonical UTC 日期不一定触发。应按目标 location 的日历日求次日9点，结合“今日时间已过/旧计划日期/切换时区”实测，不能声称所有家庭必现。 |
| P2-24 通知数量不裁剪 | **成立，超限场景待设备验收 / P2** | [schedule:156](/Users/dinghao/Downloads/MomoBox/lib/services/local_notification_service.dart:156) 无数量预算、按 items/candidates 原顺序调用。插件文档说明 iOS 待发通知64条限制。需先按触发时间排序、设置平台预算和补排策略；单纯截前64条会保留错误顺序，不能保证近期提醒。[外部依据 S5] |

## 第二部分：流程意见

| 原项 | 判定 | 复核与建议 |
|---|---|---|
| F1 批量入库后无法补效期 | **部分成立 / 产品缺口，建议 P2** | 当前确无已存在批次的日期编辑；但 [购物行编辑入口:160](/Users/dinghao/Downloads/MomoBox/lib/presentation/screens/shopping_screen.dart:160) 就是确认文案所说的“逐项编辑入库”，用于入库前填日期，报告误读成事后编辑。无效期库存是已批准能力，且 [FEFO:51](/Users/dinghao/Downloads/MomoBox/lib/domain/inventory/fefo.dart:51) 仍接纳它、排在有日期批次之后，并未绕过 FEFO。建议把文案改为“需填写日期请取消批量，改用逐项入库”；新增事后批次编辑要覆盖校验、日期文本列、旧 DateTime 列、outbox/版本和提醒，不自动认定为 P1。 |
| F2 批量非事务不可恢复 | **部分成立 / P2** | [逐项提交:274](/Users/dinghao/Downloads/MomoBox/lib/presentation/screens/shopping_screen.dart:274) 与失败中断存在；第2项删除失败时第1项删除已成功，不会像报告举例那样两项都仍在清单。代码已有“已入库请勿重复”和“成功项目不回滚”提示，剩余项目也仍在清单。真正缺口是某项“入库＋删除清单”不原子、进程中断后缺少持久关联。优先复用同一本地数据库事务完成单项闭环或持久幂等标记；直接新增任务进度表不一定必要。 |
| F3 报废后不可查看 | **核心指控不成立** | [详情分组:66](/Users/dinghao/Downloads/MomoBox/lib/presentation/screens/product_detail_screen.dart:66) 遍历 item.batches，仓储只滤 deletedAt，不滤 isDiscarded；[_BatchCard:324](/Users/dinghao/Downloads/MomoBox/lib/presentation/screens/product_detail_screen.dart:324) 明示已报废，[确认:833](/Users/dinghao/Downloads/MomoBox/lib/presentation/screens/product_detail_screen.dart:833) 明示商品、余量及不能恢复。没有撤销能力属实，但不是“数据永久不可见”。24小时撤销是新增业务，须增加反向库存流水和同步命令，不能只把 bool 改回 false。 |
| F4 首页同步状态不可感知 | **部分成立 / P2 体验增强** | [首页:258](/Users/dinghao/Downloads/MomoBox/lib/presentation/screens/home_screen.dart:258) 已有 NAS、HA、AI 三种服务状态，不是只显示 HA；确实未展示 outbox 待办/拒绝及最近同步成功。NAS 连通不代表同步完成，建议复用现有服务区展示异常摘要、连接到设置详情；不能用重设计首页替代 #4 的逐条恢复能力。 |
| F5 低库存不能关闭 | **产品建议，原规则引用错误** | [AI_CONTEXT:62](/Users/dinghao/Downloads/MomoBox/docs/AI_CONTEXT.md:62) 明确数量/低库存阈值大于0，NAS enabled=false 策略已能关闭提醒且不改变低库存事实。“保留已有明确关闭偏好”在 AI 规则中指 AI 操作许可，不是阈值关闭。改成0关闭会碰到除法、约束、指纹等路径，需明确新增独立偏好或扩大策略编辑 UI；不能当成现有校验写错。 |
| F6 手动备份/导入无预览 | **产品建议，部分描述错误** | 确无定时备份和数量级 dry-run 摘要，但 [settings:1327](/Users/dinghao/Downloads/MomoBox/lib/presentation/screens/settings_screen.dart:1327) 已有导入前确认，仓储也先全量格式/引用校验再事务写入。自动备份和变更预览超出现有 AC-007/020 最低要求。可增加摘要；必须避免预览后数据变化造成“展示摘要”与实际写入不一致。 |
| F7 confirmStarted 不能退出 | **安全取舍明确，恢复能力可增强 / NEEDS_CONFIRMATION** | [DESIGN:1333](/Users/dinghao/Downloads/MomoBox/docs/DESIGN.md:1333) 和 [现有回归:229](/Users/dinghao/Downloads/MomoBox/test/application/initial_import_service_test.dart:229) 明确未知 confirm 结果不可放弃，继续原ID查回执。其目的是防止已在 NAS 提交后客户端错误重放。已有 completed receipt 时普通队列可按 P2-13 结算，因此不是“所有持续失败都会永久 skipped”。服务端权威取消仅能在尚未提交时原子阻止 confirm，并让迟到请求读到终态；已完成计划只能恢复/核对，不能伪造 abandoned。长期不可恢复情况可补诊断和人工处置协议，不能仅添加一个本地放弃按钮。 |
| F8 AI/手动确认不同 | **不成立为 Bug** | [AC-023 规则](/Users/dinghao/Downloads/MomoBox/docs/REQUIREMENT.md:177) 明确 AI 每次写入确认；直接点击确定数量与接受模型推断的可信度不同。手动快速＋/－入口和高风险报废确认可以并存。不要为“统一”取消 AI 的二次检查或给所有快捷操作叠加弹窗。 |
| F9 统计不随数据变化 | **成立 / P2，影响范围需改写** | [FutureProvider:258](/Users/dinghao/Downloads/MomoBox/lib/presentation/controllers/providers.dart:258) 不监听流水，打开页面期间本地变动也可能不刷新；现有手动刷新和 autoDispose 重进可恢复。远端命令目前 [测试:428](/Users/dinghao/Downloads/MomoBox/test/application/sync_business_adapter_test.dart:428) 明确不写 stock_movements；初始导入历史是独立归档，不能承诺加 watch 就能展示全部远端历史。先修真实数据源变化触发，跨设备历史统计另核对协议/范围。 |

## 第三部分：工程意见

| 原项 | 判定 | 复核与建议 |
|---|---|---|
| E1 完全无崩溃观测且 P0 | **部分成立，建议 P2** | [main:11](/Users/dinghao/Downloads/MomoBox/lib/main.dart:11) 没有自定义错误采集、持久日志与导出入口，现场诊断确需加强；但 Flutter 默认已有 FlutterError.onError＝presentError，不能推断无任何堆栈。Dart handler 也不能替代原生进程崩溃/系统终止证据。日志须限量、脱敏，不存 token、库存正文或 AI 对话全文。不能凭泛化建议把它排在已证实的鉴权/数据一致性问题之前，也不能把“1天”视为有依据估时。[外部依据 S1] |
| E2 后端零观测/假探活 | **部分成立，探活论断不成立 / P2** | 缺请求结构化日志与指标属实；但 [CLI:388](/Users/dinghao/Downloads/MomoBox/backend/cmd/momo-backend/main.go:388) 真正请求 /api/v1/health，[healthHandler:58](/Users/dinghao/Downloads/MomoBox/backend/internal/platform/server.go:58) 用2秒超时 Ping 数据库，失败503，[现有测试:57](/Users/dinghao/Downloads/MomoBox/backend/internal/platform/health_test.go:57) 覆盖成功和失败。Go net/http 也已有请求 handler panic 恢复和错误堆栈日志，不等于任意 goroutine 都被保护。可补 requestId、耗时、状态码和受控恢复响应；无依据要求马上引入 Prometheus，CLI 也无需重复独立 PG 连接。[外部依据 S2] |
| E3 无 l10n 接近重写 | **产品/维护建议 / P3** | 无 ARB/业务本地化体系属实；本项目当前中文家庭使用，没有已确认多语言验收。3457处计数未复算，“接近重写”没有成本证据。若计划多语言先集中新增文案并按模块迁移，不占阻断修复批次。 |
| E4 零 Semantics＝读屏不可用 | **过度推断；图表缺口成立 / P2–P3** | 搜不到自定义 Semantics 不代表 Material/Text/Button 没有内建语义；项目存在多个 tooltip，官方说明其可供读屏播报。[_StatisticsChart:175](/Users/dinghao/Downloads/MomoBox/lib/presentation/screens/statistics_screen.dart:175) 无逐日数据替代是具体可修复点。读屏顺序、图标按钮、大字号和对比度需 TalkBack/VoiceOver 实测，不能静态宣称“基本不可用”。[外部依据 S3] |
| E5 CI 三缺 | **部分成立 / P2** | [workflow:157](/Users/dinghao/Downloads/MomoBox/.github/workflows/pipeline.yml:157) 无覆盖率产物/门槛、未调 integration_test 成立。iOS 除 config-only 外还有 [xcodebuild:223](/Users/dinghao/Downloads/MomoBox/.github/workflows/pipeline.yml:223) 真正 unsigned build；没有签名 ipa/设备执行不等于“历史上从未有人真机运行”，后者当前无证据。覆盖率阈值不证明路径正确；先补本次真实缺陷的跨层/状态机回归，再决定覆盖率门槛。存在一个 integration_test 文件也不表示它能覆盖 NAS/HA 全链路。 |
| E6 明文 SQLite 与本地优先矛盾 | **加固建议，矛盾不成立 / P3** | [DB 打开:337](/Users/dinghao/Downloads/MomoBox/lib/core/database/app_database.dart:337) 未用应用层加密，媒体亦无单独加密，这是现状；“不发送离开设备”与“应用自行加密存储”是不同承诺。应先定义丢失/解锁/root/备份导出的威胁模型、系统保护及密钥恢复，不能仅凭没有 PRAGMA key 认定失窃设备都能读库。SQLCipher 牵涉新依赖、旧库迁移与恢复，需单独设计；AC-020 已声明 JSON 不是加密文件。 |
| E7 没有 down migration | **已声明取舍，不作为 Bug** | 运维已选择备份/恢复与失败隔离，当前约束甚至要求失败保持 writer 停止。自动逆向 DDL 不保证保留迁移后业务数据，新增 downgrade 可能扩大风险。优先验证恢复证明、候选库、schema门禁和真实故障恢复；如确需回滚，再逐迁移设计补偿语义，不要求所有 SQL 必须有 down。 |
| E8 主题授权保护 | **已知分发边界 / 正式分发前门禁** | [AI_CONTEXT:77](/Users/dinghao/Downloads/MomoBox/docs/AI_CONTEXT.md:77) 已明确私有使用与正式分发前复核。代码没有“版权保护开关”并不能判定违规；建议在扩大分发范围前核对实际资产、授权证据及发布流程。不据报告直接作法律结论，也不能把未来正式分发审核永久列低优先级。 |
| E9 依赖陈旧/EOL | **迁移建议有价值，风险结论需纠正 / P2–P3** | lock 确为 sqlite3_flutter_libs 0.5.42、riverpod 2.6.1、share_plus 10.1.4；同时 [sqlite3:980](/Users/dinghao/Downloads/MomoBox/pubspec.lock:980) 已是3.5.2。维护者说明 sqlite3 3.x 后应移除旧 libs，0.6.0+eol 本身为空包；正确工作是清理旧构建路径并验证实际随包 SQLite，不是简单追逐该包最新版本。仅据旧 libs 版本不能判定实际 SQLite 安全更新已断。63个包和其他“最新版本”未独立重算；有新版本也不是漏洞证据，跨大版本应按兼容/安全需求分批。[外部依据 S6] |

## 不能照搬的修法

1. **墓碑恢复不能靠查询过滤替代语义。** 新活跃子记录不可挂在已删除父对象；合法历史和备份 tombstone 必须保留。重复 ID 跳过仍是当前契约。
2. **冲突统一入口还需要统一身份。** recordConflict 原去重键包含 changeId；先定义冲突组与回执能证明的解决范围，修复已有双行数据，保留原 outbox/idempotency 审计。
3. **零余量报废不能用普通 upsert。** 服务端故意保护库存 quantity/status，需合法库存状态命令或受控协议扩展。
4. **首次导入不能本地假放弃。** 未知 confirm 必须先核对服务端；取消需与 confirm 互斥、永久回执和迟到请求处理，已完成结果必须恢复。
5. **HA outbox 不是恰好一次保证。** 需要执行前持久化、执行后回执与结果未知处理；禁止无依据自动重发可能重复的外部动作。
6. **不能将 LAN 接入一并禁掉。** AI HTTP 与 HA 目标地址都需按已确认的 NAS/本地服务场景定义信任策略，保留合法 LAN 能力。
7. **提醒按批次改造要兼容已确认去重。** 可以在商品＋类型维度补齐候选，不必直接增加每批一条通知或全面改 UI。

## 建议的实际顺序

### 第一批：鉴权、不可见数据与同步恢复

- #9 设备撤销与 token/HA 授权、#12 当前成员资格校验；正式启用联动前同时解决 #16 的来源信任。
- #2 软删除合并事务保护、#3 活跃父子导入冲突、#13 部分报废服务端约束。
- #4 rejected 可见与可恢复、#5 冲突组结算；连带检查分类墓碑 P2-01。
- #1 HA 密钥持久化兼容；#7 联动结果进入增量同步。
- P2-10 adjustment 首次导入阻断、P2-12 连续编辑版本收敛。

这些可以按产品启用范围缩小，但不建议把诊断基础设施的泛化 P0 排在全部真实缺陷之前。原 #6、push cursor 假设应从修复列表删除。

### 第二批：状态与日期、提醒、已存在流程闭环

- #8 零余量报废协议；#14 严格草稿日期；P2-03 临期遮蔽；P2-21/23 DST；P2-24 通知预算。
- #10 外部命令的持久执行状态；F2 单项入库/清单闭环；F9 数据变更刷新；AI 家务副作用与会话损坏恢复。
- 最小结构化错误/请求日志、关键同步异常摘要，同时补隐私脱敏与容量边界。

### 第三批：需要产品确认的扩展

- 批次日期编辑、报废撤销、单机提醒开关、备份数量预览/自动备份、首页同步摘要、策略切换确认周期。
- 国际化、应用层数据库/媒体加密、主题分发门禁与依赖迁移分别按实际发布范围评估。
- F7 的服务端安全取消/人工恢复协议、#11 低库存可用量口径、#7 member 确认权限均应标 **NEEDS_CONFIRMATION** 后实施。

## 验证要求

保留原报告提出的墓碑矩阵、状态机终态可达性和日期矩阵，但补足跨层契约，避免只统计测试数量或覆盖率：

- 真实 cipher → PostgreSQL repository → 读取解密；新增 migration 升级旧库，不用 fake cipher 的整数版本替代。
- 查候选后发生删除、备份活跃子记录碰到本地墓碑，断言原子性、计数与 UI 可见数据一致。
- 本地解析失败、远端 rejected、依赖 rejected、pull 冲突后 push 冲突，重启后仍可恢复且不会重发原库存/HA 操作。
- 实际多批次 payload 全链路；保留现有复合 allocation 契约，另验证 HA 联动也产生可拉取结果。
- 设备撤销/refresh 轮换并发、成员失效、未到期旧 access token，断言 NAS/HA 的当前授权一致。
- 一轮多条同实体编辑与 push/pull 间本地编辑；不改冻结请求冒充原幂等操作。
- confirm 超时后服务端已完成/尚未完成、晚到响应、恢复失败、已有未结算队列，断言未知结果保留、完成后不重复增量。
- 提醒恢复与新周期、过期＋临期混合批次、UTC/canonical/本地 DST、通知超限，分别断言领域规则、平台排程及真实送达；单元测试不替代真机。

本复核未改变长期事实，无需据此把 AI_CONTEXT 改成“已修复/已验收”。后续真正实施并取得对应证据后，再局部更新长期规则和验证状态。

## 外部技术依据（2026-10-23 在线核对）

仅使用维护者/官方文档；下列地址保留为可核对来源，不代表本项目的运行验收。

- S1 FlutterError.onError：默认 presentError。`https://api.flutter.dev/flutter/foundation/FlutterError/onError.html`
- S2 Go net/http Handler、Server.ErrorLog：请求 handler panic 的恢复及默认日志行为。`https://pkg.go.dev/net/http`
- S3 Flutter Tooltip：内建 tooltip 可提供读屏文本。`https://api.flutter.dev/flutter/material/Tooltip-class.html`
- S4 golang.org/x/crypto/bcrypt：GenerateFromPassword 的72字节上限。`https://pkg.go.dev/golang.org/x/crypto/bcrypt`
- S5 flutter_local_notifications：iOS pending notification limit。`https://pub.dev/packages/flutter_local_notifications`
- S6 sqlite3_flutter_libs：sqlite3 3.x 迁移与0.6.0空包说明。`https://pub.dev/packages/sqlite3_flutter_libs`
