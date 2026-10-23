# 首次导入合同 v1

2026-10-22 用户批准 D-03 当前库存与独立历史归档、D-04 日历日期及默认家庭时区。首期采用有界原子导入：总记录数最多 1000，HTTP JSON 请求最多 1 MiB；超限明确拒绝，不能分批绕过重叠检查。实现与验收状态另记，不以本合同宣称完成。

## 路径与身份

以下路径都在 `/api/v1` 下。必须使用当前已认证设备，服务端重查有效用户、当前家庭、成员和设备；不相信客户端 family/user。导入预检与确认仅 owner/admin；同家庭成员可读历史。计划与回执限定同家庭、同导入账号，换设备仍须该账号。UUID 跨家庭碰撞只报告 `UUID_OVERLAP`，不返回别家内容。

- `GET /sync/import/capabilities?device_id=...`：`{import_format_version:1, atomic_import:true, max_records:1000, max_request_bytes:1048576, history_archive:true, calendar_dates:true, family_time_zone:"Asia/Shanghai"}`。不变更既有 sync schema/protocol 1/1；旧客户端不会收到未知 history snapshot entity。
- `POST /sync/import/preflight`：下述完整请求。只保存可确认的冻结计划，不修改业务数据。返回 `200 {import_id,status:"prepared"|"blocked"|"completed",ready,checkpoint,fingerprint,counts,blockers,family_time_zone,server_cursor,history_cursor}`。`blockers` 为 `{code,entity?,entity_id?,message}` 数组。blocked 不保留可确认计划；若同 ID 之前已有 prepared，阻塞重检将其撤销。completed 为同身份同 manifest 的原回执。
- `POST /sync/import/{import_id}/confirm`：`{device_id,checkpoint,fingerprint,unsettled_outbox_count:0}`。首次在单个数据库事务中再次验证、插入所有实体与库存基线、归档历史、写正常 change log、永久回执。响应 `200` completed receipt。必须先给用户展示 preflight 并明确确认，再调用。
- `GET /sync/import/{import_id}?device_id=...`：查询 prepared/completed receipt，用于超时、重启后恢复。不存在为 404；不能据 404 换 ID 重新执行，先以原 manifest 重做预检。prepared 回执包括 checkpoint/fingerprint/counts。completed 包括 `server_cursor,history_cursor,completed_at`，不重复执行。
- `GET /sync/import/history?device_id=...&after=0&until=0&limit=100`：归档独立分页。首请求 until=0 固定返回当前高水位；续页必须沿用它。返回 `{records:[{cursor,import_id,local_workspace_id,id,product_id,batch_id,type,quantity,note,occurred_at,source_time_zone,received_at}],next_cursor,until,has_more}`。limit 1..500；after/until 非负，after<=until。按 cursor 升序；原来源 UUID 去重。最终页 `has_more=false` 时 `next_cursor=until`，即使没有记录或游标存在空洞。读取和应用历史绝不能执行库存动作。

## Preflight 请求

```json
{
  "format_version": 1,
  "device_id": "uuid",
  "import_id": "uuid generated once and persisted",
  "local_workspace_id": "nonempty stable workspace identity",
  "unsettled_outbox_count": 0,
  "categories": [],
  "products": [],
  "product_batches": [],
  "shopping_items": [],
  "reminder_settings": [],
  "history": []
}
```

数组每项为对象；`id` 均为保留的稳定 UUID，同实体数组内不能重复。分类 UUID 映射在 App 计划中持久化。下表列出全部允许字段；未知字段和无效类型拒绝，不能静默丢弃。除注明外可空/可省略字段在首次写入时为 null。每条实体可带原始 `created_at`、`updated_at`（带偏移 RFC3339 instant）；不接受 deleted_at，软删除仅本地保留且须报告排除。

| 数组 | 字段 |
| --- | --- |
| categories | id, name(1..120), color, sort_order(默认0), reuse_existing(默认false) |
| products | id, name(1..255), barcode, brand, specification, category_id, identity_key, notes, location, unit(默认件), low_stock_threshold(默认1，正整数) |
| product_batches | id, product_id, produced_date, expiry_date, date_source(manual/barcode/ocr/ai_draft/import/sync，默认import), date_precision(day/month/year/unknown，默认day), initial_quantity, quantity, unit(默认piece), batch_no, is_opened(默认false), opened_date, expiry_after_opening_days, status(active/used_up/expired/discarded), storage_location, supplier, price |
| shopping_items | id, product_id, name, desired_quantity(默认1，正整数), checked(默认false), checked_at, notes, category, reason(默认手动添加) |
| reminder_settings | id, product_id, enabled(默认true), expiry_warning_days(默认30，非负), low_stock_threshold(空或正整数), opened_warning_days(本期仅null) |
| history | id, product_id, batch_id(可空), type(intake/restock/consume/discard/adjust，兼容旧值adjustment并规范为adjust), quantity(有符号整数，只有discard允许零), note, occurred_at(必填，带偏移RFC3339), source_time_zone(可空，IANA) |

商品/批次/采购字段通过 additive migration 保留并进入现有实体快照/增量。`created_at/updated_at` 是旧资料时间，导入人、设备、接收时间另记计划/归档，不冒充旧操作执行人。原提醒确认、媒体/OCR、账号凭据和运行现场不在导入内；App 明示仅留本机，不可声称全部迁移。

`initial_quantity` 与 `quantity` 均必填整数，`0 <= quantity <= initial_quantity <= 2147483647`。discarded/used_up 必须quantity=0；active必须quantity>0；expired允许正/零量。导入例如12/5直接保留12/5，不补12后扣7，不生成普通补货/消费记录。商品/批次/采购引用必须指向同计划内或同家庭已有活跃对象；history product_id/batch_id 是来源标识，不要求当前实体存在，不虚构缺失批次。

intake/restock quantity>0；consume quantity<0；discard quantity<=0；adjust quantity!=0。零 discard 仅表示来源数据中零库存批次的作废状态审计，不代表扣减数量。history 独立追加式保存，不写 consumption_records，不增加 batch version，不参与今日入库/消耗统计；导入和后续读取均不重新执行作废或其他库存动作。

日期字段必须严格 `YYYY-MM-DD`，保留原年月日，拒绝时间戳与非法日期。事件时间使用带偏移 instant。`families.time_zone` 默认 `Asia/Shanghai`；创建家庭可传 `time_zone` 并按 IANA 校验，家庭读取/bootstrap/capabilities均返回。App 检测到非午夜等旧日期歧义时阻塞，审阅弹窗逐批列出当前保存年月日供对照原始资料；原时区/日期来源已丢失时不能保证自动识别整日偏差或还原原值，不据当前午夜值声称来源已验证。

## 重叠、前置检查与恢复

业务实体的全局 UUID（含软删除）重叠均阻塞；独立历史按 family_id + 原来源 id 去重，不查询或暴露其他家庭的档案，同一历史 UUID 可在不同家庭独立存在。同家庭历史 UUID 重叠也阻塞。不自动覆盖/累加。分类可显式 `reuse_existing:true`，仅同家庭已有活跃同 UUID、精确相同 name 可复用，禁止修改其 color/sort_order；该项不得传非默认 color/sort_order。同名不同 UUID 分类阻塞，必须重新审阅后固定映射。远端任何 open conflict、该设备仍有 processing 幂等状态、未确认 bootstrap 或非 join_and_merge/create_new_family checkpoint 均阻塞。历史 rejected/conflict 幂等回执本身是已结算结果，不据此永久禁止导入；尚未解决的本地 rejected/blocked/未知回执仍必须阻塞。客户端声明 unsettled_outbox_count=0 只是必要条件，不能证明实际本地队列为空；App 必须自行检查 pending/inflight/blocked/rejected/未知回执，且不删除/伪造完成。

服务端 canonical JSON 摘要覆盖完整 manifest（包括 import_id/workspace，各数组顺序），排除 device_id/unsettled_outbox_count，使同账号换设备恢复可验证。同 import_id 同摘要返回原 prepared/completed；内容变化为 `IMPORT_ID_REUSED`。confirm 必须匹配 checkpoint/fingerprint；完成后的重复 confirm 也校验原摘要及身份，再返回原回执。不同 import_id 即使来自第二台手机同备份，也会因 UUID 重叠阻塞；不重复数量或历史。预检后任何目标变化均在确认时复检，冲突则整体回滚且无部分业务写入。

响应丢失时查原 receipt 或原 key 重试。completed 后 App 先按固定 history until 拉完历史，再拉取新鲜 bootstrap；在原 scope 静默保护内，将权威快照与本地导入完成标记置于同一事务提交，全部完成后才显示库存和历史完成。新设备历史可独立分页恢复。不能清游标/outbox，不能用未知结果新建 restock。源数据在预检后改变时 App 必须使计划过期，不能自动替换已确认 manifest。

错误：`IMPORT_UNSUPPORTED_FORMAT`/`IMPORT_LIMIT_EXCEEDED`/`VALIDATION_FAILED` 为400；`FORBIDDEN`403；`NOT_FOUND`404；`IMPORT_ID_REUSED`/`IMPORT_CHECKPOINT_STALE`/`IMPORT_BLOCKED`409；数据库/提交未知失败500必须保留原计划查询。preflight业务阻塞通过200 ready=false和逐条blockers表达，不留可确认计划。

同 URL 换服务实例、旧 dump恢复与 restore epoch仍属于D-07；本合同不提供该情况下的自动续传保证。
