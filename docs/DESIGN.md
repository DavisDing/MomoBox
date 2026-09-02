# DESIGN

> Architecture Agent 维护。
> 本文基于 `docs/产品需求文档（PRD）核心摘要.md` V3.0（2026-09-01）整理。
> 单机 MVP 已落地在 `lib/`；本文的 Phase 2–4 仍是后续架构路线，不代表已实现。

---

# 1. 需求摘要与范围

## 1.1 产品目标

「嬷嬷的小箱子」是一款本地优先的家庭物品效期与库存管理工具，解决以下问题：

- 物品、药品容易遗忘到期时间；
- 家庭成员不知道当前已有库存；
- 物品消耗后容易忘记补货；
- 包装或说明书丢失后无法快速找回信息。

核心策略是：**单机模式保证独立可用，NAS 模式提供可选的家庭共享与多设备同步，AI 只做辅助并且必须可降级**。

## 1.2 目标用户

- 家庭主力采购者：快速入库、库存查看、补货提醒；
- 有老人/小孩的家庭：药品分类、效期提醒、说明书查询；
- 减少浪费的用户：临期提醒、消耗记录；
- NAS 用户：自部署、家庭共享、数据自主。

## 1.3 核心使用场景

1. 购买后连续扫码/拍照/手动录入多件物品；
2. 搜索库存，查看某商品及其多个批次的效期；
3. 消耗或补充库存，自动生成记录；
4. 收到临期、过期、开封后临期、低库存提醒；
5. 查看历史批次并快速带入相同商品信息；
6. 管理采购清单；
7. 可选地上传说明书照片、OCR、基于说明书问答；
8. 连接 NAS 后与家庭成员共享库存并同步多设备。

## 1.4 版本边界建议

PRD 当前同时包含 P0、P1、P2 和多个平台/后端能力，范围偏大。建议将第一个可交付版本限定为：

- 单机模式；
- 商品/批次手动录入；
- 到期日期计算；
- 库存列表、搜索、筛选；
- 消耗/补充；
- 本地通知；
- JSON 导入/导出；
- 默认主题和深色模式。

扫码、OCR、AI、NAS、说明书问答、AI 主题生成应在单机核心稳定后按里程碑增加，不应成为首个版本的发布阻塞项。

---

# 2. 现状审计

## 2.1 当前仓库状态

当前仓库已经包含 Flutter 单机 MVP：

```text
MomoBox/
├── lib/                       # Flutter 客户端、领域规则、Drift 数据层和页面
├── test/domain/               # 日期、FEFO、提醒规则测试
├── scripts/ci/                # CI 生成平台壳和通知平台配置
├── .github/workflows/         # CI、Android 发布
└── docs/                      # 需求、设计、上下文和验证基线
```

当前仍没有：

- NAS 后端工程；
- PostgreSQL 迁移；
- Dockerfile / docker-compose；
- 扫码、OCR、AI 和说明书模块。

Flutter 的 Android/iOS 原生壳和 Drift 生成文件不提交到仓库，由 GitHub Actions 在每次验证/发布时按脚本生成。

## 2.2 PRD 已明确的内容

- 双模式：本地 SQLite + 可选 NAS 后端；
- 商品、批次、消耗、采购、分类、提醒、历史、图片/OCR、AI 配置；
- NAS 侧包含账号、家庭组、角色权限和同步；
- 预期 Android 8+、iOS 13+、绿联 DX4600 Docker；
- 所有 AI 结果需要用户确认，且没有 AI 时仍可手动完成任务。

---

# 3. 需求问题、矛盾与建议

以下问题在正式编码前应解决。标记为 `NEEDS_CONFIRMATION` 的事项不能由实现人员自行猜测。

## 3.1 高优先级问题

### Q-001 数据库选型与部署示例矛盾（已决策）

PRD 第 1、5 节描述 NAS 使用 PostgreSQL，但第 6.5 节 compose 使用 `DB_PATH=/data/momo.db`，实际更像 SQLite，且 compose 没有 PostgreSQL 服务。

**决策**：NAS 正式版采用独立 PostgreSQL 服务；后端保持模块化单体容器，Ollama 作为可选独立容器。原因是家庭组、多设备并发写入、事务和同步游标更适合 PostgreSQL。部署复杂度通过 Docker Compose、健康检查、初始化迁移和备份说明控制。

V0.x 单机模式仍只使用手机本地 SQLite；不再规划“NAS 后端 SQLite 作为正式方案”，避免后续出现两套服务端数据库行为。

### Q-002 双模式连接后的数据合并规则缺失（已决策）

PRD 说明断开后本地数据保留、重新连接后增量同步，但首次连接时必须避免静默覆盖本地或家庭数据。

**决策**：首次连接由用户自主选择数据归属与合并方式，提供以下路径：

- 加入现有家庭：拉取家庭数据，并在确认后合并本机数据；
- 新增家庭：创建新的家庭组，将本机数据作为初始数据；
- 暂不合并：只保存连接配置，不改变现有本地数据。

默认展示“家庭/新增家庭”的选择入口；如果用户尚未加入任何家庭，默认推荐“新增家庭”，但不能代替用户确认。合并使用稳定 UUID、重复检测和冲突报告，禁止静默覆盖。

### Q-003 同步模型不够具体

`sync_meta(table_name, last_sync_at, last_sync_hash)` 不能可靠表达每条记录的新增、修改、删除，也无法解决同一条记录在多个设备上的并发更新。

**建议**：改为基于 UUID 的离线优先同步：

- 每条可同步记录包含 `id`、`created_at`、`updated_at`、`deleted_at`、`version`、`updated_by_device`；
- 客户端维护 outbox 变更队列；
- 服务端维护按游标递增的 change log；
- `push` 幂等，`pull` 使用 cursor 分页；
- 删除采用软删除，经过保留期后再清理；
- 消耗记录采用追加写入，避免直接覆盖历史。

PRD 的“服务端为准”可以作为 MVP 默认策略，但应返回冲突报告，不能让用户无感丢失修改。

### Q-004 过期日期字段与录入规则矛盾（已决策）

录入规则允许生产日期、到期日期都不填，但 `product_batches.expiry_date` 定义为 `NOT NULL`。同时“保质期天/月”的计算规则未说明月份如何计算、日期是否包含当天。

**决策**：允许无到期日期的商品入库。此类批次显示“未设置效期”，不参与临期/过期提醒，但仍参与库存、搜索、消耗和采购逻辑。`expiry_date` 必须改为可空。

同时补充以下规则：

- 日期使用用户本地时区的 date-only 值；
- “保质期 N 个月”使用日历加月，目标月份没有对应日期时取该月最后一天；
- 到期日当天视为最后有效日，从本地日期的下一天开始视为过期；
- 记录 `date_source`（manual / calculated / ai）和 `date_precision`（day / month / unknown），避免 AI 或包装只给月份时被强制伪造具体日期；
- 只有明确存在到期日的批次才进入临期/过期状态计算。

### Q-005 客户端凭据存储不安全

`backend_connection.password_hash` 不应存在于手机端；客户端不需要保存密码哈希。`api_configs.api_key` 和 `ai_configs.api_key` 也不应仅依赖 SQLite 明文存储。

**建议**：

- 登录后保存 access token/refresh token 到 iOS Keychain / Android Keystore；
- API Key 使用系统安全存储，SQLite 只保留配置元数据和引用标识；
- 后端只存 bcrypt/Argon2id 密码哈希；
- HTTP 连接只允许用户明确配置的局域网场景并给出风险提示，正式远程使用要求 HTTPS 或反向代理。

## 3.2 中优先级问题

### Q-006 商品归并规则存在碰撞

“相同条码或相同名称”会把不同规格、品牌或口味错误合并，尤其是无条码商品。

**建议**：

- 有条码时以条码作为候选身份，但仍允许用户确认规格差异；
- 无条码时使用规范化名称 + 品牌 + 规格作为候选键；
- 候选归并只提示，不自动合并；
- 商品与批次严格分离，商品基本信息修改不应改写历史批次。

### Q-007 消耗、补充和状态转换不完整

当前只定义“每次消耗减 1”，但未说明批量消耗、撤销、部分单位、负库存和过期批次能否继续消耗。

**建议**：MVP 统一以整数件为单位，支持输入数量，禁止数量小于 0；消耗默认优先最早到期批次（FEFO），用户可改选批次；已过期批次默认禁止消耗但允许手动调整/丢弃。后续再扩展重量、毫升等单位。

### Q-008 提醒的后台执行边界不明确

“每天 9:00 检查”在 iOS/Android 上不能简单依赖 App 进程常驻，NAS 模式也明确使用本地通知。

**建议**：在批次新增/编辑、设置变更和 App 启动时计算未来提醒并注册本地通知；App 启动时再做一次 reconciliation。提醒需要去重键（批次 + 类型 + 目标日期），避免重复通知。后台能力受系统限制时，向用户说明并保证打开 App 可补检。

### Q-009 服务端领域数据表缺失

NAS 数据库只列出 users、families、family_members、sync_devices、sync_log，没有 products、batches、shopping_list、categories 等共享领域数据表。

**建议**：服务端需要同样的领域表（或等价的统一资源表），并通过 `family_id` 做租户隔离；客户端表不能直接替代服务端持久化。

### Q-010 图片字段和文件生命周期不明确

`image_url`、`manual_image` 不足以描述本地文件、NAS 文件和云端上传状态。

**建议**：增加 `media_assets` 资源元数据表，文件内容使用 App 沙盒路径或 NAS 数据卷对象键保存，数据库只保存 MIME、尺寸、哈希、来源、上传状态和关联实体。删除商品时明确图片是否级联删除。

### Q-011 AI 服务边界与安全约束不足

AI 解析输出可能格式错误、出现幻觉或包含说明书中的提示注入内容。医疗问答还涉及较高风险。

**建议**：

- 所有模型输出先做 JSON Schema 校验和字段范围校验；
- AI 结果只能填充草稿，用户确认后才写入正式数据；
- AI 不能决定药品用法、剂量或替代医生意见；回答需展示来源段落/“说明书未提及”；
- 视觉图片上传前显示授权和目的；
- 默认不上传原图，优先本地 OCR + 文本解析；
- provider adapter 统一不同厂商格式和超时/重试/取消逻辑。

### Q-012 主题版权与发布范围（产品策略已决策）

正式发布内置三个主题资源包：

- `default`：默认主题，首次安装后直接启用；
- `momo`：嬷嬷主题，随 App 一起提供，在主题中心作为备选；
- `doraemon`：哆啦A梦主题，随 App 一起提供，在主题中心作为备选。

主题资源不通过首屏强制展示，用户可在主题中心预览和切换。主题切换不能影响库存、提醒、同步等业务逻辑。

**发布门槛**：产品层面已确认随包提供，但嬷嬷/哆啦A梦具体形象、名称、文案和资源仍需在正式发布前完成授权确认；若授权未完成，必须替换为原创资源或下架对应主题包。

## 3.3 低优先级/产品决策问题

- `family_id`、`user_id` 在单机模式下的语义需要统一，建议使用 `local_workspace_id`；
- 系统分类、家庭分类、个人分类的可见性和删除规则需要写成明确的权限矩阵；
- CSV 导入字段映射、日期格式、时区和错误行报告尚未定义；
- SQLite 文件导出属于高级备份能力，应定义为“仅同版本/兼容版本恢复”，不要承诺跨平台直接打开；
- 外部说明书站点、条码 API 的服务条款、限流和可用性需在接入前确认；
- “AI 成本 1.5–3 元/月”是估算，不应作为产品承诺；不同模型、图片大小、上下文长度会显著影响费用。

---

# 4. 技术栈建议

## 4.1 客户端（已确认）

采用 **Flutter + Dart**：

- 一套代码覆盖 Android 8+ 和 iOS 13+；
- 适合相机、扫码、本地通知和主题系统；
- 主题配置、页面结构和跨平台业务逻辑易于复用。

AI 服务策略（已确认）：AI 始终由客户自行配置服务商、API 地址、模型和 API Key；产品不内置默认 AI 服务，也不代付模型费用。未配置或调用失败时必须退回本地 OCR/手动填写，不影响单机核心功能。

建议组件（在工程初始化时确认具体版本）：

- 状态管理：Riverpod；
- 路由：go_router；
- 本地数据库：SQLite + Drift；
- 扫码：mobile_scanner；
- 相机/图片：camera 或 image_picker；
- OCR：Google ML Kit（平台能力可用时）；
- 本地通知：flutter_local_notifications；
- 安全存储：flutter_secure_storage。

这些依赖是建议，不代表仓库已经安装。

## 4.2 NAS 后端（已决策）

采用 **Go + 标准 HTTP 路由/轻量路由库 + PostgreSQL**，做一个模块化单体服务：

- 单个后端镜像，部署和升级简单；
- Go 适合 NAS 的低资源、长期运行场景；
- PostgreSQL 提供事务、并发和索引能力；
- 数据访问使用参数化 SQL（可用 pgx/sqlc），不引入重型 ORM。

后端模块建议：

```text
cmd/server
internal/
├── auth          # 注册、登录、token、密码策略
├── family        # 家庭组、邀请码、角色权限
├── inventory     # 商品、批次、消耗、库存规则
├── reminder      # 提醒查询和设置，不负责手机通知发送
├── shopping      # 采购清单
├── sync          # push/pull、cursor、冲突
├── media         # 图片元数据和文件访问
├── ai            # provider adapter、Ollama 代理、审计
├── importexport  # JSON/CSV 备份与恢复
└── platform      # 配置、数据库、日志、健康检查
```

## 4.3 部署

NAS 正式部署采用 PostgreSQL；AI 服务不作为必选基础设施，只有用户主动配置 Ollama 或其他服务时才启用。

推荐三类服务：

```text
手机 App
  ├─ 单机：Flutter UI → 本地领域服务 → SQLite/文件目录
  └─ NAS：Flutter UI → 本地领域服务 → Sync/API Client
                                      ↓ HTTPS/局域网 HTTP
                               momo-backend → PostgreSQL
                                      └→ Ollama（可选）
```

正式 compose 至少需要明确：

- `momo-backend`；
- `postgres` 及其持久化卷；
- `ollama` 可选；
- 网络、健康检查、数据库迁移、备份策略、环境变量和密钥注入。

该方案不使用 NAS 后端 SQLite；如未来需要改变数据库选型，必须单独设计数据迁移、并发控制和备份恢复方案。

---

# 5. 系统结构与模块设计

## 5.1 客户端分层

```text
Presentation
  ↓
Application / Use Cases
  ↓
Domain
  ↓
Data
  ├── Local SQLite (source of truth for offline work)
  ├── File Storage
  ├── Sync Client
  ├── Barcode Client
  └── AI/OCR Client
```

### Presentation

负责页面、组件、路由、用户交互和展示状态，不直接写 SQL 或处理同步细节。

### Application

编排“扫码入库”“消耗”“导入”“连接 NAS”等用例，组合领域规则与数据仓库。

### Domain

负责商品归并候选、批次状态、效期计算、FEFO 消耗、低库存判断、提醒条件和导入去重规则。

### Data

负责 Drift DAO、文件资源、API 调用、token、outbox、同步游标和第三方适配。

## 5.2 领域模块

| 模块 | 职责 | P0/P1/P2 |
|---|---|---|
| Inventory | 商品、批次、库存搜索、状态 | P0 |
| Intake | 扫码、拍照、手动、连续录入草稿 | P0/P1 |
| Date Rules | 日期双向计算、日期精度 | P0 |
| Consumption | 消耗/补充/调整及审计记录 | P0 |
| Category | 系统/个人/家庭二级分类 | P0 |
| Reminder | 临期/过期/开封后/低库存 | P0 |
| Shopping | 采购清单和来源 | P0 |
| History | 历史批次、常用商品 | P0 |
| Media/OCR | 图片压缩、OCR、资源生命周期 | P1 |
| Manual QA | 说明书 OCR 和问答 | P1 |
| Sync/Family | 账号、家庭成员、同步 | NAS P0 |
| Theme | 主题配置、文案和资源 | P0/P2 |
| AI | 日期解析、视觉识别、自然语言、建议 | P0-P2 |
| Import/Export | JSON/CSV 备份恢复 | P1 |

### 5.3 主题资源策略

主题采用“资源包 + 配置”的形式，核心业务只依赖语义 token，不依赖具体 IP：

- 安装包内置 `default`、`momo`、`doraemon` 三个主题资源包；
- `default` 为首次安装默认主题；
- `momo` 和 `doraemon` 在主题中心展示为可选主题，支持预览、启用和恢复默认；
- 主题包包含色彩、图标、空状态插画、吉祥物资源、文案映射和通知模板；
- 资源加载失败时回退到 `default`，不能阻塞主业务；
- 主题资源应带版本号，便于后续替换、授权更新或移除。

---

# 6. 前后端职责

## 6.1 前端负责

- 页面和交互；
- 本地 SQLite 读写和离线可用；
- 相机、扫码、图片压缩、可用的本地 OCR；
- 本地通知注册、去重和 App 启动补检；
- 表单即时校验、AI 草稿展示和用户确认；
- 本地安全存储 token/API Key；
- 同步状态、离线队列、重试和用户可见的冲突提示；
- 主题切换和主题资源加载。

## 6.2 后端负责

- 账号认证、refresh token 和家庭组权限；
- 家庭数据隔离和服务端参数校验；
- 领域数据持久化、事务和同步 change log；
- 同步幂等、游标、冲突记录、设备管理；
- NAS 文件元数据及授权访问；
- 可选的 Ollama/条码 API 代理；
- 健康检查、迁移、日志和备份说明。

## 6.3 必须由后端校验的内容

- JWT、家庭成员身份和角色；
- `family_id` 归属，禁止越权读写；
- 数量不能变为非法负数；
- 商品/批次关联存在；
- 邀请码有效期、使用次数和成员上限；
- 同步版本、幂等键和删除权限；
- 上传文件类型、大小和访问授权。

---

# 7. 数据设计

## 7.1 客户端核心实体

保留 PRD 的 `products`、`product_batches`、`consumption_records`、`shopping_list`、`categories`、`reminder_settings`、`local_product_cache`、`ai_*` 等实体，但建议做以下调整：

### products

- `id`：客户端生成 UUID，NAS 模式下保持不变；
- `barcode` 可空；
- `name` 必填；
- `brand`、`specification`、`category_id`、`notes`；
- `identity_key`：用于无条码候选匹配，不作为绝对唯一约束；
- `workspace_id`/`family_id`；
- `created_by`、`updated_by_device`、时间戳；
- `deleted_at`、`sync_state`、`version`。

### product_batches

- `product_id` 外键；
- 日期字段允许按确认后的规则为空；
- `date_source`、`date_precision`；
- `quantity`、`initial_quantity`、`unit`；
- `opened_date`、`expiry_after_opening`；
- `status`：active / used_up / expired / discarded；
- `storage_location`、`supplier`、`price`；
- 同步字段同上。

### consumption_records

- 作为追加记录；
- `quantity_change` 允许正负，但通过 record_type 约束语义；
- `idempotency_key` 防止重试重复记账；
- `batch_id`、`created_by`、`device_id`。

### media_assets（建议新增）

| 字段 | 说明 |
|---|---|
| id | UUID |
| owner_scope | local / family |
| entity_type/entity_id | 关联商品或说明书 |
| local_path/object_key | 文件位置，不存大文件本体 |
| mime_type/size_bytes/width/height | 文件元数据 |
| sha256 | 去重与完整性校验 |
| upload_state | local_only / pending / uploaded / failed |
| created_at/deleted_at | 生命周期 |

### outbox_changes（建议新增）

保存待上传的实体变更、操作类型、幂等键、重试次数和最后错误。与 `sync_meta` 配合或替代其职责，不能只依赖整表 hash。

## 7.2 服务端实体

除 PRD 已有的 users、families、family_members、sync_devices、sync_log 外，至少需要：

- products；
- product_batches；
- consumption_records；
- shopping_list；
- categories；
- reminder_settings；
- media_assets；
- change_log；
- conflict_records（建议）。

所有家庭级业务表必须有 `family_id` 和合适索引，服务端查询必须在 SQL 层带上家庭范围条件。

## 7.3 数据生命周期

- 普通编辑：更新版本和时间戳；
- 删除：软删除并进入同步队列；
- 同步确认：客户端标记已同步；
- 冲突：保留服务端版本与客户端版本摘要；
- 媒体删除：先删除元数据引用，文件异步清理；
- AI 日志：用户可清除，默认不上传；
- 数据库备份：NAS 必须说明 PostgreSQL dump/恢复和文件卷备份的配对关系。

---

# 8. API 设计（建议）

API 为提案，后续需由后端实现时固定版本前缀，例如 `/api/v1`。

## 8.1 认证与家庭

### `POST /api/v1/auth/register`

Request：`{ "email": "...", "password": "...", "nickname": "..." }`

Response：用户摘要、access token、refresh token。

### `POST /api/v1/auth/login`

Request：邮箱和密码。Response：token 对。

### `POST /api/v1/auth/refresh`

Request：refresh token。Response：新的 token 对。

### `GET /api/v1/me`

返回当前用户、当前家庭和设备信息。

### `POST /api/v1/families`

创建家庭组并返回 owner 身份。

### `POST /api/v1/families/join`

Request：邀请码。后端校验有效期、使用次数、成员上限。

### `GET /api/v1/families/members`

需要家庭成员权限；增删改成员需要 owner/admin 权限。

## 8.2 同步

### `POST /api/v1/sync/push`

Request：设备 ID、客户端 cursor、变更数组、每条变更的 idempotency key、entity、operation、version、payload。

Response：接受结果、冲突数组、服务端 cursor。

### `GET /api/v1/sync/pull?cursor=...&limit=...`

Response：变更数组、新 cursor、是否还有下一页。客户端按 cursor 持久化，不能按时间戳猜测是否同步完成。

### `GET /api/v1/sync/bootstrap`

首次连接获取家庭数据快照、服务端 cursor、schema 版本和合并提示信息。

不建议把 `/sync/conflict` 设计成客户端随意调用的独立接口；冲突应在 push 响应中返回，若需要人工选择，再提供带权限和版本校验的 resolution 接口。

## 8.3 辅助接口

- `GET /api/v1/health`：健康检查，不泄漏敏感信息；
- `GET /api/v1/barcode/{barcode}`：可选后端条码代理；
- `GET /api/v1/ai/ollama/status`：可选 Ollama 状态；
- `POST /api/v1/ai/chat`：可选代理，必须有超时、大小限制和审计；
- `POST /api/v1/media/presign` / `POST /api/v1/media/complete`：若 NAS 文件上传采用分步流程。

## 8.4 统一错误格式

```json
{
  "error": {
    "code": "SYNC_CONFLICT",
    "message": "数据版本冲突",
    "details": {},
    "request_id": "..."
  }
}
```

错误码至少覆盖：认证失败、无权限、参数校验失败、资源不存在、版本冲突、服务暂不可用、AI 未配置、外部 API 超时、导入部分失败。

---

# 9. 前端页面与状态

## 9.1 页面关系

```text
App Shell
├── 库存（首页）
│   ├── 商品详情
│   └── 扫码/拍照/手动入库
├── 采买单
├── 提醒
└── 我的
    ├── 后端连接
    ├── 家庭组
    ├── 数据导入/导出
    ├── 说明书库
    ├── 主题设置
    └── API/AI 设置
```

## 9.2 页面行为和状态

### 库存页

- 数据：商品卡片、批次汇总、连接状态；
- 操作：搜索、分类/状态筛选、排序、扫码入库；
- Loading：首屏骨架或局部加载；
- Empty：首次使用引导手动录入/扫码；
- Error：本地数据库异常或同步错误，不阻塞已缓存内容；
- Success：保存后刷新列表并显示同步状态。

### 入库页

- 模式：扫码、拍照、手动、连续录入；
- 状态：相机权限、扫描中、查询中、OCR 中、AI 解析中、草稿待确认、保存中、失败可重试；
- AI 结果必须以可编辑草稿呈现，不能直接入库；
- 外部 API 失败时可直接进入手动填写。

### 商品详情页

- 展示基本信息、批次列表、历史记录、说明书入口；
- 批次按到期日升序；无效期批次单独归类；
- 消耗/补充要求数量确认，失败时保留页面状态并提示原因；
- 删除商品/批次需要二次确认，并说明级联影响。

### 提醒页

- 分类：临期、过期、开封后临期、缺货；
- 排序：紧急程度、到期日期；
- Empty：明确“当前无待处理提醒”；
- 通知权限未开时提供设置引导。

### 采买单页

- 待采购、已购记录、手动新增、来源标记、备注；
- 同一商品自动触发项要去重或合并数量；
- AI 建议必须可解释、可拒绝、可手动加入。

### 我的页

- 单机状态和 NAS 状态明显区分；
- 连接、登录、首次合并、同步失败、断开后的本地保留都要有明确反馈；
- API Key 不回显完整值；
- 主题预览失败应回退默认主题。

---

# 10. 关键业务规则

1. 商品和批次分离：同一商品可以有多个独立批次；
2. 无条码归并只做候选，不静默合并；
3. 批次数量不得小于 0；MVP 支持整数件，不支持小数单位；
4. 消耗默认采用 FEFO（最早到期优先），允许用户改选；
5. `used_up` 由数量为 0 触发；`expired` 由日期计算产生，但已用完/已丢弃状态优先保留；
6. 提醒必须排除已用完、已丢弃和未设置效期的批次；
7. 低库存按商品维度汇总所有有效批次的总量触发，不按单个批次触发；
8. 任何 AI 结果先进入草稿，用户确认后才落库；
9. 本地模式所有核心功能不依赖网络；
10. NAS 不可用时，本地写入继续成功，变更进入 outbox，恢复后自动重试；
11. 家庭成员删除权限由后端强制执行，不能只靠前端隐藏按钮；
12. 导入默认不覆盖已有记录，输出成功、跳过、失败明细。

---

# 11. 测试关注点

## 11.1 正常流程

- 手动新增商品和多批次；
- 生产日期 + 保质期、到期日期 + 保质期的双向计算；
- 连续扫码/拍照录入；
- 消耗、补充、用完状态转换；
- 临期、过期、低库存和开封后提醒；
- JSON/CSV 导入导出；
- NAS 注册、建家庭、邀请码加入、push/pull 同步。

## 11.2 边界与异常

- 无条码、同名不同规格、重复批次；
- 空日期、只填月份、闰年、月末加月、时区切换；
- 数量为 0、批量消耗、重复点击、离线重试；
- 相机/OCR/通知权限被拒绝；
- 条码 API 限流、超时、返回脏数据；
- AI 返回非法 JSON、低置信度、超时、取消、无 API Key；
- NAS 不可达、token 过期、首次合并、同步冲突、删除同步；
- 多设备同时修改同一批次；
- 导入文件过大、字段缺失、部分行失败；
- 图片损坏、超大图片、删除商品后的孤儿文件；
- 未授权用户访问其他家庭数据。

## 11.3 回归重点

- 单机模式不能依赖 NAS 或账号；
- 主题切换不能改变业务规则；
- 同步失败不能丢失本地已确认操作；
- 数据迁移必须兼容已发布的数据库 schema；
- 通知去重不能导致过期提醒完全消失；
- 药品问答不能被 UI 文案包装成医疗诊断。

---

# 12. 风险与待确认事项

## 12.1 真实风险

- 条码库覆盖率、免费 API 可用性和服务条款；
- iOS/Android 本地通知后台限制；
- NAS 用户部署 PostgreSQL 和反向代理的门槛；
- 离线同步冲突可能造成用户误解或数据丢失；
- API Key、商品图片和药品说明书的隐私风险；
- AI 幻觉、提示注入和医疗安全风险；
- 哆啦A梦/容嬷嬷等主题的版权/商标风险；
- Ollama 在 DX4600 上的内存和推理速度限制。

## 12.2 NEEDS_CONFIRMATION

以下事项仍需在编码前确认：

1. 嬷嬷/哆啦A梦主题正式发布前的授权确认；
2. 说明书外部链接站点和内容责任边界；
3. 是否需要消耗统计图表和社区共享数据库。

---

# 13. 推荐实施顺序

## Phase 0：工程基线

- 初始化 Flutter 工程、环境、路由、主题契约；
- 初始化本地 SQLite/Drift 和迁移机制；
- 建立领域模型、Repository、测试骨架；
- 暂不接入后端和 AI。

## Phase 1：单机核心（首个可发布版本）

- 手动录入、商品/批次、日期计算；
- 库存、搜索、分类、商品详情；
- 消耗/补充、历史、采购清单；
- 本地通知和导入导出；
- 默认主题、深色模式；
- 内置嬷嬷和哆啦A梦主题资源，并在主题中心作为备选。

## Phase 2：识别与图片

- 条码扫描；
- 本地缓存和可选条码 API；
- 图片压缩、本地 OCR；
- AI 解析草稿和用户确认。

## Phase 3：NAS 同步

- 后端认证和家庭组；
- PostgreSQL schema 与迁移；
- bootstrap、push/pull、outbox/change log；
- 冲突报告、设备管理、Docker Compose；
- NAS 不可用时离线继续工作。

## Phase 4：说明书与 AI 增强

- 说明书 OCR 库；
- 基于检索片段的问答；
- 采购建议；
- AI 主题生成（需先解决版权和资源安全问题，且不影响内置主题）。

---

# 14. 结论

PRD 的产品方向清晰，核心闭环也成立：**录入 → 管理批次 → 提醒 → 消耗 → 补货**。当前最大问题不是功能缺失，而是范围过大，以及数据同步、日期规则、凭据安全、数据库部署四个基础决策尚未收敛。

Flutter、NAS PostgreSQL、允许无到期日期商品入库、首次连接由用户选择家庭/新增家庭、整数件库存、按商品总量触发低库存、首版先做单机 MVP、AI 始终由客户自行配置 Key，以及“default 默认启用、momo/doraemon 随包提供并在主题中心作为备选”均已确认。建议先实现单机核心，再按阶段接入 OCR、AI、Ollama 和 NAS 同步；嬷嬷/哆啦A梦主题仍需完成正式发布授权确认。

状态：`designing`
