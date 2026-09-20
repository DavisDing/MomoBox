# MomoBox NAS 领域与同步模型

- 文档版本：v0.1
- 更新时间：2026-09-20
- 适用范围：NAS 后端 MVP 与后续 Flutter NAS 客户端
- 状态：架构基线，后端实现必须遵守本文件；如需改变同步语义，必须先更新本文件和 API 契约

## 1. 目标与边界

NAS 模式提供家庭账号、家庭成员、跨设备库存共享和可选的 Home Assistant 控制。单机 Flutter 应用仍然以本地 SQLite 为离线数据源；NAS 不替代本地数据库，也不保存用户的 LLM/Ollama API Key。

AI 边界：Flutter 直接连接用户配置的 LLM 兼容服务或用户自行部署的 Ollama。NAS 后端不内置 Ollama、不提供 AI 代理、不保存 AI API Key。

Home Assistant 边界：HA 是家庭级外部服务。NAS 后端保存家庭 HA 集成配置、加密 Token、设备/实体元数据和控制权限，并代表已授权家庭成员调用 HA。HA 实时状态不进入普通 MomoBox 同步流。

## 2. ID、时间与版本

- 所有跨设备实体使用客户端或服务端生成的 UUID；同步后 ID 不变。
- 所有服务端时间使用 UTC 的 RFC3339 表示；客户端展示时转换为用户本地时区。
- 所有可同步实体包含 `created_at`、`updated_at`、可空 `deleted_at`、`version`、`updated_by_device`。
- `version` 是该实体在服务端的整数版本，从 1 开始，每次实体成功变更递增。
- 服务端维护家庭范围的单调递增 `change_cursor`；pull 只能按 cursor 读取，不能使用时间戳推断同步完成。
- 删除默认采用软删除，并进入 change log；物理清理必须晚于客户端保留期且单独设计。

## 3. 服务端实体

### 3.1 账号与家庭

- `users`：登录账号和密码哈希；不保存 AI API Key。
- `refresh_tokens`：refresh token 哈希、设备、过期和撤销信息。
- `families`：家庭组。
- `family_members`：用户在家庭中的角色：`owner`、`admin`、`member`。
- `family_invites`：邀请码哈希、有效期、使用次数和成员上限。
- `sync_devices`：登录 MomoBox 的手机、平板等客户端设备。它不是 Home Assistant 设备。

### 3.2 库存与采购

- `products`：商品基本信息。
- `product_batches`：批次、效期、位置、当前数量投影和状态。
- `consumption_records`：追加式库存操作记录，包括消耗、补充、报废和调整。
- `shopping_items`：采购清单条目。
- `categories`：家庭可见分类。
- `reminder_settings`：家庭或商品级提醒设置。

`product_batches.quantity` 是服务端事务维护的投影，不允许客户端使用普通实体 upsert 任意覆盖。

### 3.3 同步与冲突

- `change_log`：服务端提交成功的变更，按家庭分配 cursor。
- `conflict_records`：实体版本冲突、客户端命令拒绝或需要用户处理的冲突摘要。
- `sync_idempotency`：设备和幂等键的处理结果，防止网络重试重复执行。

### 3.4 Home Assistant

- `ha_integrations`：家庭配置的 HA 实例；Token 以密文保存，解密密钥来自部署 Secret/环境配置。
- `ha_devices`：从 HA 发现的设备元数据缓存。
- `ha_entities`：从 HA 发现的实体、领域、能力和状态缓存。
- `ha_entity_permissions`：家庭成员/角色对实体的查看和控制白名单。
- `ha_command_logs`：控制请求的审计记录。

HA 设备和实体属于 HA 的状态域，不作为 `sync_devices` 或普通库存实体同步。

家庭可配置多个 HA integration；HA 原生 `entity_id` 只在单个 integration 内唯一。因此状态读取、命令执行和权限配置必须始终使用 `(family_id, integration_id, entity_id)` 定位，不能只按 `family_id + entity_id` 查询。同步命令顶层的 `integration_id` 是执行目标的一部分，校验后不得丢弃。

## 4. 同步操作类型

普通资料变更使用实体同步：

```json
{
  "change_id": "uuid",
  "operation": "entity_upsert",
  "entity": "products",
  "entity_id": "uuid",
  "base_version": 3,
  "payload": {},
  "idempotency_key": "device-id:operation-id",
  "client_updated_at": "2026-09-20T10:00:00Z"
}
```

删除使用：

```json
{
  "change_id": "uuid",
  "operation": "entity_delete",
  "entity": "shopping_items",
  "entity_id": "uuid",
  "base_version": 2,
  "idempotency_key": "device-id:operation-id"
}
```

库存动作使用业务命令，不允许直接上传最终库存数量：

```json
{
  "change_id": "uuid",
  "operation": "inventory_command",
  "command": "consume_allocated",
  "operation_id": "uuid",
  "allocations": [
    {"batch_id": "uuid", "quantity": 2}
  ],
  "idempotency_key": "device-id:operation-id"
}
```

支持的库存命令：

- `consume_fefo`：服务端根据当前库存执行 FEFO，并返回实际分配。
- `consume_allocated`：客户端指定批次，服务端校验后执行。
- `restock`：向指定批次补充正整数数量。
- `discard`：报废指定批次或指定数量，需符合状态规则。

Home Assistant 控制命令不进入库存同步流。字段位于变更顶层，`change_id` 同时作为 HA 命令审计 `request_id`；不得把命令包装进 `payload`，也不得混用 `entity`、`base_version`、`operation_id` 或 `allocations`：

```json
{
  "change_id": "uuid",
  "operation": "home_assistant_command",
  "integration_id": "uuid",
  "entity_id": "light.kitchen",
  "command": "set_brightness",
  "parameters": {"brightness": 80},
  "idempotency_key": "device-id:operation-id"
}
```

## 5. Push 处理规则

服务端在一个数据库事务中处理每条可写变更：

1. 验证 access token、家庭成员关系和设备归属；
2. 校验实体归属的 `family_id`；
3. 以 `(device_id, idempotency_key)` 查重；
4. `entity_upsert` 校验 `base_version`；
5. `inventory_command` 锁定相关批次并校验库存、效期和状态；
6. 写入实体或追加操作记录；
7. 更新库存投影；
8. 写入 `change_log`；
9. 记录幂等结果；
10. 提交事务并返回 server cursor。

重复幂等键必须返回第一次处理的等价结果，不得再次修改数据。

## 6. 冲突语义

### 6.1 普通实体冲突

实体 `base_version` 不等于当前服务端版本时，拒绝该变更并返回：

- `VERSION_CONFLICT`；
- 服务端版本和 payload 摘要；
- 客户端版本和 payload 摘要；
- 当前 cursor。

第一版不自动合并，也不静默覆盖。

### 6.2 库存命令拒绝

库存命令不使用普通字段覆盖冲突。以下情况返回业务错误：

- `INSUFFICIENT_STOCK`：库存不足；
- `BATCH_EXPIRED`：批次已过期；
- `BATCH_DISCARDED`：批次已报废；
- `BATCH_NOT_FOUND`：批次不存在；
- `INVALID_QUANTITY`：数量非正整数。

客户端应拉取最新快照或 change log 后刷新本地状态。

## 7. 首次连接与数据合并

首次启用 NAS 时，认证与家庭建立顺序固定为：

1. `Register` 创建账号，此时不注册同步设备；
2. 创建家庭或使用邀请码加入家庭；
3. 携带 `device` 再次 `Login`；
4. 服务端签发包含 `family_id`、`role`、`device_id` 的访问令牌；
5. 之后才允许调用 Sync 与 Home Assistant 家庭接口。

`bootstrap` 只读取服务端家庭快照、cursor、协议版本和合并提示，不自动覆盖本地数据。

客户端必须在用户确认后提交以下模式之一：

- `join_and_merge`：加入现有家庭并提交本地数据合并。
- `create_new_family`：创建家庭并将本地数据作为初始数据。
- `keep_local_only`：仅保存连接配置，不改变本地数据。

首次合并必须按稳定 UUID、重复检测和冲突报告处理，禁止静默覆盖。

## 8. 本地 SQLite 映射约束

- 本地商品/批次 ID 在 NAS 模式下保持不变。
- 本地 outbox 负责保存待提交操作；服务端不要求客户端先放弃本地数据。
- 本地 `product_batches.quantity` 只能由本地领域操作和服务端同步结果更新。
- API Key、refresh token、HA 连接 Token 不进入普通同步 payload。
- 本地图片第一版只同步元数据或保留本机；二进制媒体上传是后续能力。

## 9. 非目标

本模型第一版不包含：

- AI/Ollama 服务端代理；
- Ollama 容器；
- HA 实时 WebSocket 推送到 Flutter；
- 任意 HA 原始 service 调用；
- 复杂的自动冲突合并 UI；
- 公网账号运营后台。
