# 2026-10-07 实现决策与收尾交接

## 1. 范围与状态

接续 AGENTS、AI_CONTEXT/REQUIREMENT/DESIGN 和 2026-10-06 可靠性记录，核对当前未提交实现。本记录只说明用户已批准的两项决策、落盘方案、验收与迁移风险，不把代码阅读视为测试。代码已落盘并完成源码复核，轻量实跑结果已记入 `docs/VALIDATION.md`；代码测试、CI和实机验收未执行，后续按实际执行补充结果。

**当前：已批准，代码已落盘并完成源码复核，测试/验收未执行，不是生产可用。** 本机缺 Flutter、Dart、Go、gofmt、Docker、psql。新增 Flutter/Go/真实PG16测试与CI均尚未跑，旧CI及历史脚本通过不代表本轮工作区通过。

## 2. 已批准决策一：提醒策略

| 项目 | 决策/实现口径 |
| --- | --- |
| 默认 | 新策略默认30天；无策略按 enabled=true/30天处理 |
| 继承 | 商品→家庭→默认；可空低库存阈值按商品→家庭→本地商品值回退 |
| 兼容 | 显式7天及其他合法窗口保留，已有旧值不被新默认替换；旧threshold-only覆盖沿用enabled/30天行为 |
| 禁用 | enabled=false仅停止有效策略对应提醒候选、摘要与通知；不改quantity、expiryDate、过期/低库存事实或FEFO可用性 |
| 不支持 | 开封后提醒暂不支持，非空opened_warning_days即使在禁用策略下也显式失败 |
| 输入/隔离 | enabled布尔、天数非负整数、可空阈值为正整数；重复策略/非法字段fail closed；scope隔离；删除覆盖恢复继承 |
| UI | 仅首页和提醒详情两处标题“临期提醒”及通知正文使用实际窗口；无新增设置编辑UI或布局重设计 |

主要落盘位置：`lib/domain/models/inventory_models.dart`、`lib/domain/inventory/expiry_rules.dart`、`lib/domain/inventory/reminder_rules.dart`、`lib/data/repositories/reminder_repository.dart`、`lib/data/repositories/inventory_repository.dart`、`lib/services/local_notification_service.dart`。复用现有 app_settings overlay，不新增本地 schema/依赖。窗口参与效期提醒指纹；稳定ID、确认过滤、低库存恢复后新周期继续保留。提醒关闭不等于库存事实消失，不通过改日期/数量制造“关闭”效果。

## 3. 已批准决策二：NAS 库存权威

- NAS同步模式的数量以NAS权威库存为准；离线操作仍记录本地业务写入与outbox，不允许远端快照吞掉未解决本地意图。
- 快照应用前要求整个scope静默：无pending、in-flight、blocked、rejected、outbox conflict和open/deferred冲突。保护按scope而非仅按快照entityId，拒绝/阻塞不等于丢弃许可。
- 预检与Drift事务内复检；权威quantity、version、相关元数据、pending bootstrap完成与安全cursor同事务提交。相同version权威snapshot可纠偏，更旧version不回退；阻塞时不允许只抬version留旧quantity。
- bootstrap需推送本地操作时，网络前持久化refresh_required；push获得确定accepted/replayed且scope静默后重新fetch，再确认checkpoint，最后应用。maxPush截断/冲突/拒绝/未知结果/刷新失败均不得消费推送前snapshot；进程恢复仍须刷新。
- 未知网络结果重试原operationID/changeId/idempotency key，不能新建同一库存操作；receipt和安全游标的幂等/原子规则不放宽。增量普通实体更新不是库存增减命令，历史追加也不能再次扣库存。

主要落盘位置：`lib/application/sync_business_adapter.dart`、`lib/application/sync_engine.dart`、`lib/data/repositories/sync_outbox_repository.dart`、`lib/data/repositories/inventory_repository.dart`。两项决策不再NEEDS_CONFIRMATION，但未通过测试/端到端验收。

## 4. 快照边界保护与 checkpoint 最终设计

### 4.1 批次状态与事实映射

- `product_batches.status=discarded`映射`isDiscarded=true`；`active/used_up/expired`映射非报废，不能继承错误旧报废标记。
- `used_up/discarded`必须quantity=0；quantity为非负整数，不得超过有效initial_quantity。
- `expired`不授权制造虚假expiryDate；过期性仍按真实日期和“到期当天有效、次日过期”计算。开封状态字段不等于支持开封提醒。
- 未知状态/非法字段/状态与兼容字段矛盾fail closed，整批业务与version/cursor不部分推进。
- 批次Repository的状态映射、终态零数量与冲突检查已落盘并完成源码复核；相关回归用例源码已补充，测试/验收未执行。

### 4.2 checkpoint 与用户选择

最终设计口径：相同cursor复用已有有效checkpoint token；cursor改变生成新token、state=pending、清空confirmed_at并重新确认。缺失/无效token需生成有效token。该口径替代本轮中间“每次fetch无条件旋转”方案（superseded）；最新后端源码已见同cursor复用分支，但真实DB/并发未验证。

后端bootstrap业务行与cursor置于同一个repeatable-read transaction；设备/checkpoint锁协调fetch与confirm。远端同步确认要求保存的token/cursor匹配，不接受旧确认。keep_local_only完全忽略客户端快照token，并将请求副本的snapshot cursor归零用于保存/审计；不可信超前cursor不能阻止选择仅本地，回执仍返回真实服务端cursor。用户新选择必须受到保护。

refresh网络在途竞态保护：发请求前捕获pending/checkpoint/模式，返回后在本地事务比较最新值；用户重新选择、换checkpoint或清除pending时丢弃旧响应，尤其不能覆盖新keep_local_only，也不自动切回远端同步。确认在途及应用完成前同样必须校验基线。代码已落盘并完成源码复核，相关回归用例源码已补充，测试/验收未执行。

### 4.3 确认回执与刷新标记边界

- 远端同步模式确认只有在accepted、预期nextAction、checkpoint匹配且`serverCursor >= snapshotCursor`时有效；invalid/rejected receipt不得抬高pushAckCursor，不能用错误回执证明已收敛。
- 写入refresh_required前及fetch返回后的本地事务均比较请求基线pending/checkpoint与已确认mode，并保护keep_local_only；用户选择已改变则拒绝旧流程写回。
- 手动bootstrap保留已有refresh_required，并比较请求前后pending/mode；在刷新必需但响应缺少snapshot时显式失败，保留原pending/刷新标记，不能通过缺失snapshot清refresh。
- 回执游标过旧、错误回执不推进pushAckCursor、两处刷新选择竞态及手动bootstrap缺少snapshot的回归用例源码已补充。代码已落盘并完成源码复核，测试/验收未执行。

## 5. NAS migration 0005：数据兼容、排序与影响

文件：`backend/migrations/0005_reminder_defaults_and_cursor_order.sql`。

1. `reminder_settings.expiry_warning_days SET DEFAULT 30`仅影响新记录，不UPDATE旧值，已有7保留。后端同步insert缺字段默认也改30；部分update不覆盖原值。
2. `change_log`全局`BEFORE INSERT FOR EACH STATEMENT` trigger取得事务advisory lock，在任何行/default expression分配identity cursor之前执行；锁持有到commit/rollback。不能改为row trigger（拿锁晚于分配）或家庭锁（序列是全局）。sync和直接库存命令的change_log写入均应覆盖。
3. identity sequence设置`CACHE 1`，防止各连接缓存区间使后提交写入取得较低cursor。回滚可产生合法cursor空洞，不要求cursor连续。
4. 全局串行化会让不同家庭写入互相等待；吞吐、长事务延迟、锁顺序/死锁、超时与失败回滚需要真实压力/并发验证。没有实测数据，不承诺无性能影响。
5. 这是一项NAS数据库结构/行为迁移；没有本地Drift schema变更。不能把历史“无数据库schema变化”沿用到本轮，也不能声称修复了部署前已错过的变化。

### 部署门槛（待执行，不是部署结果）

- 先验证本轮CI和真实PG16回归；备份业务数据库及相关卷，确认备份恢复可用，记录迁移版本/checksum、镜像固定标签/digest和现有cursor/checkpoint。
- 为排序保证安排写入维护窗口，暂停会写change_log的所有路径，等待未结束事务并排空/重建既有DB连接。CACHE1不能被视为已清除旧连接缓存的证明；并发旧连接与旧事务的部署转换必须专项验证。
- 通过现有migration runner应用0005，保留迁移锁/checksum约束；不手工改已应用文件或删除migration记录。确认默认、trigger、sequence/cache、服务启动，再恢复写入与同步。
- 观察跨家庭吞吐、锁等待、长事务/死锁和超时重试；在测试环境演练失败回滚与恢复。历史cursor漏读需评估并使用受保护的完整snapshot/重同步修复，不能只推进cursor。

### 补偿回滚（方案，尚未演练）

- 尚未落地的migration失败按现有事务回滚处理并保留诊断；不能靠删除schema_migrations记录或改checksum强行成功。
- 已应用后变更使用新编号补偿migration，不重写/删除0005。若恢复旧SQL默认，仅影响后续缺值insert；保留所有已有显式值，不批量30→7，也不删除业务数据。
- 撤除cursor锁/恢复sequence缓存会重新引入乱序风险，不能在线静默回退；先暂停写入/同步，复核已部署客户端与checkpoint，制订安全重同步和数据修复。优先保留排序保证只回退必要应用行为。
- 如必须恢复备份，须明确恢复点之后的数据损失/补偿、配套版本与设备cursor/checkpoint重置或重新bootstrap流程，履行必要确认；没有本轮“已成功回滚”的结论。

## 6. 测试入口与验收交接

- Flutter新增提醒策略Repository/领域、权威库存snapshot、adapter、引擎回归源码；CI须先生成Drift，源码存在性不是analyze/test通过。
- 后端新增 `cursor_migration_test.go`（SQL文本/insert默认契约）、`bootstrap_snapshot_test.go`（模拟事务契约）与 `cursor_postgres_test.go`（真实PG16并发）。前两者不能证明真实数据库排序。
- `.github/workflows/pipeline.yml`后端job配置PostgreSQL16 service、`MOMO_TEST_DATABASE_URL`、`go test -count=1 ./...`和`go vet ./...`。真实测试opt-in，缺URL会skip；CI配置有URL不代表CI已执行。真实测试用隔离schema，测试URL不得指向生产数据库。
- 待验证：旧7/新30、商品/家庭优先级与禁用事实隔离；scope所有阻塞状态；同版本数量修正；未知结果原ID重试；push/fetch/confirm/application失败恢复；相同/变化cursor token；状态非法/终态零数量；refresh/confirm期间用户keep_local_only；真实PG双连接commit/rollback排序、部署排空旧连接、吞吐、补偿回滚。
- 状态与验收细项见VALIDATION及REQUIREMENT AC-011～AC-014。验证记录须包含实际命令、run/日志及成功/失败/未执行原因；本记录不新增代码验收PASSED。2026-10-07脚本语法/回归、自测、YAML解析和空白检查已执行通过；Python非package Dart目标326条全部存在，不能与历史508口径混称，也不等于编译。完整记录与限制见VALIDATION。

## 7. 明确未完成与历史记录规则

消费历史bootstrap/增量恢复、出站分类创建/UUID映射和旧分类升级兼容仍未做；HA scene/script、AI混合控制、联动配置/事件来源闭环仍未做。完整媒体/OCR归档、社区共享仍不在本次范围。

AI_CONTEXT记录长期事实，REQUIREMENT定义验收，DESIGN说明当前方案，VALIDATION只记录可追溯验证；2026-10-06记录保留原复核与实跑历史并将两项旧待确认标superseded。不删除其他未提交文档，不将部分实现写成完整同步/HA闭环，也不把历史PASSED当作本轮结果。


## 8. Code review 两项 P1 续修（2026-10-07，代码状态，未验收）

### 8.1 NAS initial_quantity 兼容修复

- 根因：新批次实体 insert 不暴露数量字段，SQL 默认 initial_quantity=0；旧 restock 只增长 quantity，完整快照因此可能是 quantity=3/initial=0，被客户端严格校验拒绝。不能为此放宽 `quantity <= initial_quantity`。
- 后端库存命令在锁定批次旧值上采用 `GREATEST(initial_quantity, quantity) + GREATEST(delta, 0)`；补货增加累计初始量，消耗/报废不降低它，已有偏小值先修复为当前数量下界。原幂等回执路径不变，未知结果继续复用原 operationID/key。
- 新增 NAS 数据迁移 `0006_repair_batch_initial_quantity.sql`，不重写旧迁移或 schema_migrations。只修改非软删除且 initial 偏小的批次，取原 initial、当前 quantity、同家庭同批次已记录正向 restock 总量的最大值，不猜测缺失历史。保留数量、历史和原设备归属，版本+1，更新时间与完整 entity_upsert change_log 同事务提交。
- 汇总使用 bigint，回填 integer 越界、版本溢出或日志写入失败均应整事务失败，不能截断或跳过错误。数据量大时聚合、批次表写锁及 change_log 全局锁可能产生等待；须先在备份副本测耗时与容量。
- 部署前备份且演练恢复，安排写入维护窗口、排空库存/同步写事务，确认 0005 排序锁已生效，再由现有 runner 按编号应用 0006；未执行部署。失败保留诊断并事务回滚，已应用后如需补偿使用新编号迁移，不能把 initial 批量归零、降低修复值或删除修复日志。回退旧 restock 会复现故障，不可静默回退应用语义。

### 8.2 冲突结算与权威刷新

- 根因：NAS keep_remote/keep_local 被接受后只改变本地 conflict 状态，旧 outbox 仍为 conflict/rejected；scope 静默检查永久阻止后续快照与 pull。
- 新增 `settleOutboxConflict`：严格核对 accepted、resolved、远端冲突/change/entity/action 与原家庭/原 outbox，原子保存本地处理结果、app_settings 结算证据与 scope 刷新 revision。原 outbox 保留失败状态、原 request/key 和审计，不伪装 accepted、不重新排队原幂等键。NAS keep_local 已实际写实体和 change_log，不能再发同一原命令。
- 只有完整匹配的显式结算才解除旧 conflict/rejected 的 scope/dependency 阻塞；未解决、无证据、证据损坏或不匹配仍保护本地意图。库存/HA 不新增 keep_local 支持。
- 引擎对已完成 bootstrap 且没有 pending snapshot 的 scope 也消费刷新 revision：先排空当前待推送操作，scope 静默后 fetch 完整新 snapshot、确认新 checkpoint，再同事务提交业务/安全 cursor/清理 pending/清理精确 revision。keep_remote 不一定追加 change_log，不能用空 pull 代替新快照。
- offline、失败、restart 保留 revision；fetch/confirm/application 期间出现新的解决动作，旧快照不能清除新 revision，完成事务检查失败时回滚。用户 keep_local_only 不自动恢复远端同步；旧完成状态若缺确认模式，保留刷新要求并提示先明确选择。
- NAS 已 resolved 但本地写入失败或网络丢回执时，使用现有 GET conflict 重新核对原 action/identity，再恢复结算，不再次远端 mutation。恢复筛选包含旧版本本地已 resolved/rejected、关联 outbox 仍未结算的存量。原冲突页增加待恢复回执和按原动作恢复入口，不重设计布局；open/resolved 各保留最近 200 条列表边界，更早 resolved 回执在重启后可能无法自动匹配，页面提示并继续保护，不算完整历史恢复。
- 同版本权威 snapshot 可恢复商品、采购条目和批次 tombstone/乐观数据；普通增量仍跳过同版本，旧版本仍不回退。上述覆盖仅在 scope 静默与原子完成协议内使用。页面布局/主题不变，只连接原冲突按钮与状态反馈。

### 8.3 验证边界

- 新增 initial_quantity actual Repository/Service 真实 PG 测试与 actual 0006 隔离 schema 测试；覆盖累计、重放、消耗/报废、历史下界、软删除/家庭隔离、重复迁移、写入/COMMIT 失败回滚。显式 `MOMO_TEST_DATABASE_URL` opt-in，不设时 skip，测试地址不得指向生产。
- Flutter 新增冲突结算凭据/原 key 保留、依赖释放、同版本权威恢复、完整刷新/restart/revision 竞态回归源码；保留客户端严格 initial 校验，添加迁移后完整行 fixture。
- 本机无 Go/gofmt、Flutter/Dart、Docker/psql；这些测试与 analyze/build/vet 未执行。源码审阅和脚本轻量验证不是 P1 已验收或生产可用的证明。
