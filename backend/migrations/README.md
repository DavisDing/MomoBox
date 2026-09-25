# MomoBox NAS PostgreSQL migrations

本目录只包含 NAS 后端 PostgreSQL 的 SQL 迁移契约；不包含 Go 代码，也不负责 Flutter/SQLite 迁移。

## 文件与执行语义

- `0001_initial_schema.sql` 创建 NAS MVP 所需的全部表、约束、索引、更新时间触发器和 `schema_migrations` 版本记录。
- 文件使用 `CREATE ... IF NOT EXISTS`、幂等索引和 `ON CONFLICT DO NOTHING`，可重复执行；重复执行不会重复扣库存、覆盖数据或重复写入版本记录。
- 生产环境应通过 Go migration runner 执行迁移。runner 在 PostgreSQL 事务中获取 advisory transaction lock，维护 `schema_migrations`，按数字版本顺序只执行未应用文件，并校验 `version/name/checksum`。并发启动的后端不会同时执行迁移；失败会回滚并以非零退出码结束。
- runner 负责事务边界，因此会去除迁移文件最外层的 `BEGIN;`/`COMMIT;`，避免嵌套事务。迁移文件中的 advisory lock 仍可保留，以兼容直接 bootstrap。
- 已应用的版本必须视为不可变。后续结构变化新增 `0002_*.sql`，不要改写已经记录的 SQL。发现同版本 name 或 checksum 不一致时，runner 拒绝启动。checksum 使用迁移文件原始字节的 `sha256:<hex>`。
- 该 SQL 文件包含历史 SQL-only bootstrap 的版本记录。runner 会在首次接管这个 legacy marker 时将其原子升级为文件实际 checksum；之后修改已应用文件会被拒绝。生产环境不要再直接用 `psql` 绕过 runner 执行迁移。

生产执行示例（在已启动的 PostgreSQL 上）：

```bash
momo-backend migrate
```

仅用于 SQL bootstrap/故障排查时，才直接执行迁移文件；直接执行会保留 SQL 文件中的 legacy checksum，首次由 runner 接管时会完成 checksum 标准化。

验证版本记录：

```bash
psql "$DATABASE_URL" --set ON_ERROR_STOP=1 \
  --command "SELECT version, name, checksum, applied_at FROM schema_migrations ORDER BY version;"
```

## Schema 契约

### UUID、时间和版本

- 跨设备 ID 全部使用 PostgreSQL `uuid`；未由客户端显式提供时使用 `gen_random_uuid()`。
- 服务端时间全部使用 `timestamptz`，迁移事务设置 UTC；应用层输入/输出必须使用 UTC RFC3339。
- 可同步实体含 `created_at`、`updated_at`、可空 `deleted_at`、`version` 和（有设备语义时）`updated_by_device`。`version` 从 1 开始，由服务端每次成功实体变更递增。
- `change_log.cursor` 使用 `BIGINT GENERATED ALWAYS AS IDENTITY`，是家庭范围同步游标的持久化基础；pull 不得用时间戳代替 cursor。

### 软删除与追加记录

- `users`、家庭成员/邀请/设备、商品/批次/采购/分类/提醒，以及 HA 配置/发现/权限使用 `deleted_at` 软删除字段。
- `consumption_records`、`change_log`、`conflict_records`、`sync_idempotency`、`ha_command_logs` 是追加式/幂等/审计数据，不提供普通删除路径。
- 业务层不得用普通 entity upsert 直接覆盖 `product_batches.quantity`；库存只能在事务中锁定批次、校验规则、追加 `consumption_records` 并更新数量投影，同时写入 `change_log`。
- 商品 `barcode` 与 `identity_key` 没有唯一约束；相似记录只能作为候选，不能由数据库或同步逻辑静默合并。

### 家庭隔离与安全

- 所有家庭级表都有 `family_id`，并对父子资源使用 `(resource_id, family_id)` 复合外键，避免把一个家庭的资源挂到另一个家庭。
- 后端每条查询和写入仍必须显式带 `family_id`，并同时检查 `user_id + family_id + role + resource permission`；数据库外键不是认证授权的替代品。
- `refresh_tokens` 只保存 token hash；`family_invites` 只保存邀请码 hash；`ha_integrations.access_token_ciphertext` 只保存应用层加密后的密文。SQL 不保存原始 secret，也不把 secret 写入 payload 或日志。
- HA 控制命令在表约束中限定为安全白名单；参数范围、实体能力和角色白名单由后端在事务/调用 HA 前校验，`ha_command_logs` 只允许安全参数摘要。

## 验收检查

本次 SQL-only 变更建议执行：

```bash
# 生产 runner 验证（需要已构建的后端和可连接的 PostgreSQL）
momo-backend migrate
momo-backend migrate

# SQL bootstrap/语法验证（仅在明确绕过 runner 时使用）
psql "$DATABASE_URL" --set ON_ERROR_STOP=1 --file backend/migrations/0001_initial_schema.sql
psql "$DATABASE_URL" --set ON_ERROR_STOP=1 --file backend/migrations/0001_initial_schema.sql

# 检查所有要求的表、核心列、约束、索引和版本记录
psql "$DATABASE_URL" --set ON_ERROR_STOP=1 --command "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;"
psql "$DATABASE_URL" --set ON_ERROR_STOP=1 --command "SELECT version, name, checksum FROM schema_migrations ORDER BY version;"
```

如果本机没有 PostgreSQL 客户端/服务，必须把上述命令标记为 `NOT_EXECUTED`，不能把静态检查当成数据库执行验证。
