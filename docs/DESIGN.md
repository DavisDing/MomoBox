# DESIGN

> Architecture Agent 维护。
> 2026-10-08 完善版。需求与验收以 REQUIREMENT 为准，长期现状引用 AI_CONTEXT；本文记录技术方案、修改入口、限制与决策，不以代码落盘代替验收。
> 最初基于 PRD V3.0（2026-09-01）整理。第0节为当前入口；日期补充保留历史证据，同主题已批准的新决策优先。历史Phase/提案不自动构成下一期发布范围。

# 0. 当前设计基线与阅读入口

## 0.1 本次目标与范围

完善App与NAS/Docker的需求映射和技术边界，消除旧提案与已批准方案的矛盾，补齐已接入能力的异常/验收入口。不新增业务模块、依赖、表、API或UI，不执行migration、提交/推送、发布、恢复或部署。

本轮以main `0d52280`源码及已读取CI #25为诊断基线；这是证据快照，不是持续监测的最新流水线承诺。App analyze/iOS构建失败，后端PG配置下测试及vet通过；具体错误及修复见同日诊断节，尚未实施。设备、NAS/HA和灾备演练没有因此完成。

## 0.2 已批准选择、源码现状与提案

| 主题 | 已批准目标/边界 | 源码现状与限制 |
| --- | --- | --- |
| 核心模式 | Flutter+Drift本地优先，NAS可选，整数件、FEFO、当天有效 | 本地schema 5；网络故障不应阻断单机业务 |
| AI/HA | Flutter直连用户AI，HA凭据只在NAS；白名单/确认/真实回执 | 不内置Ollama、不提供AI/条码代理；手动电源接入，不是完整混合联动 |
| 提醒 | 商品→家庭→默认30天，关闭不改库存事实 | app_settings作用域覆盖；非空opened_warning_days仍拒绝 |
| 同步 | 幂等库存命令、不丢本地意图、scope静默才应用权威快照 | 队列/游标/checkpoint/冲突结算/有界前台调度有代码；首次基线、分类出站、完整历史未闭环 |
| 媒体/备份 | 原图/OCR本地，核心JSON不迁移身份/密钥/同步现场 | 本地media_assets/FTS；无NAS附件上传及完整媒体归档 |
| NAS部署 | Go+PG模块化单体，双服务、固定镜像、无AI服务容器 | docker-compose.yaml和local-build override；health只验证DB连接 |
| 灾备/工作区/时区 | 不假定已解决 | REQUIREMENT D-02～D-07与DR-01～07待确认；epoch/readiness/fencing未实现 |

本地Drift schema 5、PostgreSQL migration 0001～0006、wire schema/protocol 1/1分别版本化；capabilities版本不证明数据库migration完整或历史未回退。

## 0.3 文档职责与索引

| 文档 | 负责内容 | 使用方式 |
| --- | --- | --- |
| REQUIREMENT 第10～14节 | 当前范围、AC-015～022、门禁、D-01～08 | 未决项不能从代码反推批准 |
| 本文第5～9、15节 | 模块/存储/API/UI、数据流与验收映射 | 复用现有入口，不复制完整协议字段表 |
| AI_CONTEXT | 长期技术栈、业务与视觉保护 | 历史未验收按commit理解；更新建议见15.6 |
| docs/nas/01-domain-sync-model.md、03-security.md、04-deployment.md | NAS领域、安全及部署契约 | 与源码有差异时记录，需求变化先确认 |
| APP_NAS_HARDENING_2026-10-07.md、NAS_OPERATIONS_REVIEW_2026-10-07.md | 加强批次及剩余运维风险 | 源码检查不是事故复现或部署验收 |
| NAS_RECOVERY_PLAN_2026-10-07.md | DR提案、恢复/回滚与epoch | 仅设计，不是现有可执行流程 |
| VALIDATION、具体CI/设备记录 | 执行证据 | 按commit/run/环境记录PASS、FAIL、SKIPPED、NOT_EXECUTED |

待决建议集中在REQUIREMENT第13节，本设计不另设相互矛盾的默认选择。

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

> 本节为历史里程碑划分，不重新缩减已接入能力。当前收尾与待确认正式范围见REQUIREMENT第10/13节。

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
├── test/                      # 领域规则、备份校验和事务回滚测试
├── scripts/ci/                # CI 生成平台壳和通知平台配置
├── .github/workflows/         # 单一 CI、打包与发布链路
└── docs/                      # 需求、设计、上下文和验证基线
```

当前已包含 NAS 后端工程、PostgreSQL 迁移、Dockerfile 和 Compose；同步基础骨架、说明书外部搜索、基于本地 OCR 片段的问答、统计图表和 Home Assistant 耗材联动基础也已落地。

当前仍未完整接入或完成：

- 社区共享模块；
- 多设备冲突解决结果的真实传播验证；
- NAS/HA 实机和端到端联调。

当前代码已实现、验证待执行的辅助能力：实时相机/拍照/相册条码识别、可选外部条码查询及本地缓存、商品和说明书图片、本地 OCR、用户自配兼容 OpenAI 服务后的 OCR 草稿解析与库存问答。它们均必须保留手动回退，不得阻塞单机库存核心流程。

Flutter 的 Android/iOS 原生壳和 Drift 生成文件不提交到仓库，由 GitHub Actions 在每次验证/发布时按脚本生成。

平台壳生成后必须由 `scripts/ci/prepare-flutter-platforms.sh` 注入兼容性基线：Android `minSdk` 为 API 36（Android 16），`compileSdk`/`targetSdk` 为 API 37（Android 17），iOS deployment target 为 27.0；Android 16 强制 edge-to-edge 后的系统栏/输入法 inset 与大屏布局由 Flutter Scaffold、SafeArea 和宽屏 NavigationRail 共同处理；未完成 CI 和真机验证前，不得把兼容性标记为已验证。

## 2.2 PRD 已明确的内容

- 双模式：本地 SQLite + 可选 NAS 后端；
- 商品、批次、消耗、采购、分类、提醒、历史、图片/OCR、AI 配置；
- NAS 侧包含账号、家庭组、角色权限和同步；
- Android 16.0+（API 36+）、iOS 27.0+、绿联 DX4600 Docker；
- 所有 AI 结果需要用户确认，且没有 AI 时仍可手动完成任务。

---

# 3. 需求问题、矛盾与建议

本章保留早期问题与决策背景；已有实现以第0/7/8/15节及日期修订为准，不把“建议”全部当作本次拟新增。仍标为 `NEEDS_CONFIRMATION` 的事项不能由实施者猜测。

## 3.1 高优先级问题

### Q-001 数据库选型与部署示例矛盾（已决策）

PRD 第 1、5 节描述 NAS 使用 PostgreSQL，但第 6.5 节 compose 使用 `DB_PATH=/data/momo.db`，实际更像 SQLite，且 compose 没有 PostgreSQL 服务。

**决策**：NAS 正式版采用独立 PostgreSQL 服务；后端保持模块化单体容器。Ollama、LLM 厂商 API 和代理均不内置在 NAS 后端：Flutter 客户端直接连接用户配置的 LLM 服务或用户在其他位置部署的 Ollama。原因是家庭组、多设备并发写入、事务和同步游标更适合 PostgreSQL，同时避免 NAS 保存 AI Key 或承担 AI 代理职责。部署复杂度通过 Docker Compose、健康检查、初始化迁移和备份说明控制。

V0.x 单机模式仍只使用手机本地 SQLite；不再规划“NAS 后端 SQLite 作为正式方案”，避免后续出现两套服务端数据库行为。

### Q-002 双模式连接后的数据合并规则缺失（已决策）

PRD 说明断开后本地数据保留、重新连接后增量同步，但首次连接时必须避免静默覆盖本地或家庭数据。

**决策**：首次连接由用户自主选择数据归属与合并方式，提供以下路径：

- 加入现有家庭：拉取家庭数据，并在确认后合并本机数据；
- 新增家庭：创建新的家庭组，将本机数据作为初始数据；
- 暂不合并：只保存连接配置，不改变现有本地数据。

默认展示“家庭/新增家庭”的选择入口；如果用户尚未加入任何家庭，默认推荐“新增家庭”，但不能代替用户确认。合并使用稳定 UUID、重复检测和冲突报告，禁止静默覆盖。

### Q-003 同步模型（历史问题，当前已采用outbox/change log）

`sync_meta(table_name, last_sync_at, last_sync_hash)` 不能可靠表达每条记录的新增、修改、删除，也无法解决同一条记录在多个设备上的并发更新。

**当前方案**：采用基于UUID的离线优先同步；下述为目标契约，实际实体覆盖与首次迁移须按当前缺口核对：

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

- 本地业务日期按用户本地日历解释；NAS现有UTC传输与跨时区家庭规则尚需统一，见D-04，不因本条自动批准协议/旧数据转换；
- “保质期 N 个月”使用日历加月，目标月份没有对应日期时取该月最后一天；
- 到期日当天视为最后有效日，从本地日期的下一天开始视为过期；
- 记录 `date_source`（manual / calculated / ai）和 `date_precision`（day / month / unknown），避免 AI 或包装只给月份时被强制伪造具体日期；
- 只有明确存在到期日的批次才进入临期/过期状态计算。

### Q-005 凭据存储（历史问题，安全存储已接入，运行未验收）

`backend_connection.password_hash` 不应存在于手机端；客户端不需要保存密码哈希。`api_configs.api_key` 和 `ai_configs.api_key` 也不应仅依赖 SQLite 明文存储。

**建议**：

- NAS凭据和AI Key使用现有系统安全存储；NAS凭据绑定规范化endpoint、会话代次校验，旧无binding需重新登录；不保留客户端密码哈希；
- API Key 使用系统安全存储，SQLite 只保留配置元数据和引用标识；
- 后端使用现有bcrypt实现保存密码哈希，不因历史备选Argon2id描述引入算法迁移；
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

原始需求只定义“每次消耗减 1”，未说明批量消耗、撤销、部分单位、负库存和过期批次能否继续消耗。

**当前单机 MVP**：统一以整数件为单位，消耗和批次补充均支持输入正整数；消耗默认按最早到期优先（FEFO），也支持明确选择未过期、未报废且库存充足的批次；任何路径均禁止负库存，并写入变动历史。已过期批次禁止消耗但允许报废；报废在界面须二次确认。撤销、重量/毫升等非整数单位仍留待后续阶段。

### Q-008 提醒的后台执行边界不明确

“每天 9:00 检查”在 iOS/Android 上不能简单依赖 App 进程常驻，NAS 模式也明确使用本地通知。

**建议**：在批次新增/编辑、设置变更和 App 启动时计算未来提醒并注册本地通知；App 启动时再做一次 reconciliation。提醒使用现有商品+类型稳定key与状态fingerprint去重（不是另建批次key方案），避免重复通知。后台能力受系统限制时，向用户说明并保证打开 App 可补检。

### Q-009 服务端领域数据表缺失

NAS 数据库只列出 users、families、family_members、sync_devices、sync_log，没有 products、batches、shopping_list、categories 等共享领域数据表。

**建议**：服务端需要同样的领域表（或等价的统一资源表），并通过 `family_id` 做租户隔离；客户端表不能直接替代服务端持久化。

### Q-010 图片与文件生命周期（本地media_assets已存在，NAS上传未实现）

`image_url`、`manual_image` 不足以描述本地文件、NAS 文件和云端上传状态。

**当前方案**：本地media_assets保存沙盒路径、MIME/尺寸/hash/关联与OCR，MediaService协调保存/清理；具体字段见第7节。NAS对象上传/上传状态未实现，不因历史建议新增。删除关联及文件清理按现有生命周期处理并回归验证。

### Q-011 AI 服务边界与安全约束不足

AI 解析输出可能格式错误、出现幻觉或包含说明书中的提示注入内容。医疗问答还涉及较高风险。

**建议**：

- 所有模型输出先做 JSON Schema 校验和字段范围校验；
- AI 结果只能填充草稿，用户确认后才写入正式数据；
- AI 不能决定药品用法、剂量或替代医生意见；回答需展示来源段落/“说明书未提及”；
- 视觉图片上传前显示授权和目的；
- 默认不上传原图，优先本地 OCR + 文本解析；
- provider adapter 统一不同厂商格式和超时/重试/取消逻辑。

### Q-012 主题资源与当前分发边界（当前私有使用已确认）

当前单机 MVP 内置三个主题配置：

- `default`：默认主题，首次安装后直接启用；
- `momo`：嬷嬷主题，在主题中心作为备选；
- `doraemon`：哆啦A梦主题，在主题中心作为备选。

主题不通过首屏强制展示，用户可在主题中心预览和切换。主题切换不能影响库存、提醒、同步等业务逻辑。

**当前边界**：截至 2026-09-02，用户确认主题仅供本人本地使用和私有设备安装验证，不上架、不公开分发；该边界不阻塞当前开发。

**未来发布门槛**：若公开发布、上架、商用或向第三方分发，必须重新完成主题名称、形象、文案和资源的授权/合规审查；未满足条件时须替换为原创或已获授权资源。

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

- 一套代码最低覆盖 Android 16.0（API 36）和 iOS 27.0；Android 构建以 Android 17 API 37 编译并 target。
- 适合相机、扫码、本地通知和主题系统；
- 主题配置、页面结构和跨平台业务逻辑易于复用。

AI 服务策略（已确认）：AI 始终由客户自行配置服务商、API 地址、模型和 API Key；产品不内置默认 AI 服务，也不代付模型费用。未配置或调用失败时必须退回本地 OCR/手动填写，不影响单机核心功能。

已声明组件（具体依赖范围见 `pubspec.yaml`；声明不等于本次构建通过）：

- 状态管理：Riverpod；
- 路由：go_router；
- 本地数据库：SQLite + Drift；
- 扫码：mobile_scanner；
- 相机/图片：mobile_scanner、image_picker；
- OCR：Google ML Kit（平台能力可用时）；
- 本地通知：flutter_local_notifications；
- 安全存储：flutter_secure_storage。

不为完善文档另加依赖。SDK约束、锁文件与CI实际解析版本须共同记录，不以文档版本猜测运行结果。

## 4.2 NAS 后端（已决策）

采用 **Go + 标准 HTTP 路由/轻量路由库 + PostgreSQL**，做一个模块化单体服务：

- 单个后端镜像，部署和升级简单；
- Go 适合 NAS 的低资源、长期运行场景；
- PostgreSQL 提供事务、并发和索引能力；
- 数据访问使用参数化 SQL（可用 pgx/sqlc），不引入重型 ORM。

已存在目录入口（不补造media/importexport服务）：

```text
backend/cmd/momo-backend         # composition root、serve/migrate/healthcheck
backend/internal/
├── auth、family、syncdevice     # 认证、家庭与设备授权
├── inventory、sync             # 库存命令、push/pull、checkpoint/冲突
├── homeassistant、securetoken  # 外部HA及凭据加密
├── httpapi                     # HTTP解析/认证/业务路由
├── store                       # PostgreSQL repositories
└── platform                    # 配置、DB、migration、错误/健康检查
```

提醒/采购数据通过现有同步/持久化路径处理，不为形式完整拆新服务；客户端核心JSON不是后端全量备份接口。

---

## 4.3 部署

NAS 正式部署采用 PostgreSQL；AI 服务不作为 NAS 基础设施。Flutter 客户端只保存用户配置的 LLM/Ollama 连接信息，并直接访问对应服务；NAS 后端不保存 AI Key、不提供 AI 代理，也不编排 Ollama 生命周期。

推荐两类服务：

```text
手机 App
  ├─ 单机：Flutter UI → 本地领域服务 → SQLite/文件目录
  └─ NAS：Flutter UI → 本地领域服务 → Sync/API Client
                                      ↓ HTTPS/局域网 HTTP
                               momo-backend → PostgreSQL
                                      └→ Home Assistant（外部服务）
```

正式 compose 至少需要明确：

- `momo-backend`；
- `postgres` 及其持久化卷；
- 不包含 `ollama`、AI proxy 或 barcode proxy；
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

### 提醒确认记录（单机 MVP）

提醒确认记录由本地 Drift 表 `reminder_acknowledgments` 持久化，字段为：

- `reminder_key`：稳定的商品 + 提醒类型标识，例如 `product-id:low-stock`；
- `fingerprint`：当前提醒状态指纹；低库存使用 `threshold:<阈值>`，效期提醒使用最近有效批次 ID + 到期日；低库存商品恢复到阈值以上时删除对应确认记录，使再次跌破阈值进入新的提醒周期；
- `acknowledged_at`：用户确认处理的时间。

提醒页支持单条和分组批量“标记已处理”。确认记录只影响提醒展示和本地通知调度，不会替代消耗、补充、报废或加入采购清单等库存/采购业务动作。重新计算提醒时必须同时匹配 `reminder_key` 和 `fingerprint`，状态指纹变化后重新显示；低库存从正常状态再次跌破阈值时必须进入新的提醒周期；同一 `reminder_key` 再次确认时更新原记录，避免无限增长。


## 5.2 领域模块

| 模块 | 职责 | P0/P1/P2 |
|---|---|---|
| Inventory | 商品、批次、库存搜索、状态 | P0 |
| Intake | 扫码、拍照、手动、连续录入草稿 | P0/P1 |
| Date Rules | 日期双向计算、日期精度 | P0 |
| Consumption | 消耗/补充/调整及审计记录 | P0 |
| Category | 系统/个人/家庭二级分类 | P0 |
| Reminder | 临期/过期/低库存；开封后规则当前不支持 | P0 |
| Shopping | 采购清单和来源 | P0 |
| History | 历史批次、常用商品 | P0 |
| Media/OCR | 图片压缩、OCR、资源生命周期 | P1 |
| Manual QA | 说明书 OCR 和问答 | P1 |
| Sync/Family | 账号、家庭成员、同步 | NAS P0 |
| Theme | 主题配置、文案和资源 | P0/P2 |
| AI | 日期解析、视觉识别、自然语言、建议 | P0-P2 |
| Import/Export | 核心JSON备份恢复；CSV为范围外 | P1 |

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
- 外部Home Assistant凭据、实体授权与typed control；
- 不运行/代理AI、Ollama或条码服务；NAS媒体上传未实现，capabilities明确为false；
- 健康检查、迁移、日志和备份说明。

## 6.3 必须由后端校验的内容

- JWT、家庭成员身份和角色；
- `family_id` 归属，禁止越权读写；
- 数量不能变为非法负数；
- 商品/批次关联存在；
- 邀请码有效期、使用次数和成员上限；
- 同步版本、幂等键和删除权限；
- 若未来批准文件上传，再设计类型/大小/授权；当前无上传接口，不能把预期校验当现有能力。

---

# 7. 数据设计：当前存储与未决迁移

## 7.1 本地已存在的存储

以 `lib/core/database/app_database.dart` 为结构来源，Drift schemaVersion为5；1→2提醒确认、→3媒体/条码缓存、→4同步字段及状态表、→5本地OCR FTS。实际升级需回归验证，不直接编辑生成的 `.g.dart`。

| 存储 | 当前职责 | 约束/边界 |
| --- | --- | --- |
| products / product_batches | 商品与批次；初始/剩余数量、日期来源/精度、报废与服务端版本 | UUID稳定；无expiry仍可参与库存；不预设已存在workspace_id分库隔离 |
| stock_movements | 本地入库/消耗/补充/报废历史 | NAS历史恢复未全覆盖，不能当成已完成的双向consumption_records |
| shopping_entries | 采购目标、完成状态与同步元数据 | 确认购买打开草稿，不直接伪造入库 |
| reminder_acknowledgments | key+fingerprint+确认时间 | 独立于库存动作，低库存新周期重新出现 |
| app_settings | 普通配置、稳定local_workspace_id、AI会话、分类绑定/提醒覆盖、pending bootstrap/冲突结算与刷新revision | 密钥不写此处；家庭scope仅是特定设置隔离，不能声称整库已隔离 |
| sync_states / sync_outbox | bootstrap、双cursor、版本/错误/退避；待发送内容、ID/key、状态与回执 | scope范围；业务写入+outbox、receipt+安全cursor应原子；失败审计不删除 |
| sync_conflicts / sync_applied_changes | 冲突及本地结算、已应用change去重 | scope+change_id去重；resolved证据不冒充原命令accepted |
| media_assets / media_ocr_fts | 本地文件位置/类型/hash、关联、OCR与本地检索 | 沙盒路径不是跨设备URL；无NAS upload_state/对象上传承诺 |
| barcode_lookup_cache / AI用量设置 | 可清理缓存/日志 | 不用缓存命中冒充实时上游可用 |
| 系统安全存储 | NASToken/来源binding、用户AI Key | 不导出至核心JSON；顺序写删与会话失效保护 |

本轮不新增本地表或schema。未来工作区/灾备审阅/日期协议改动须独立提供迁移、旧版本兼容和回滚方案，获批后才实施。

## 7.2 NAS已存在的数据与版本

`backend/migrations/0001`～`0006`和 `backend/internal/store/` 定义账号/家庭/设备、商品/批次/采购/分类/提醒、库存历史、change_log、幂等/冲突、HA连接/实体权限及耗材联动基础；后端查写以服务端认证的familyID限定，不能信任客户端提供的家庭归属。

- `0005`的新记录30天默认和全局change_log提交排序，`0006`的initial_quantity下界补修，遵守AC-014与后续决策记录；不改已应用checksum。
- 客户端收到权威quantity/serverVersion并不自动证明历史、分类和全部HA实体已完整映射。无法安全映射时失败并保留cursor。
- wire schema/protocol 1/1不是PG migration序号；capabilities配置和数据库已应用migration需分别验证，schema readiness尚未落地。

## 7.3 生命周期与备份范围

普通同步编辑/软删除保留稳定ID及版本；已接受/未知库存命令按原ID/key处理；冲突保存审计与精确结算证据，不清队列强行收敛。物理清理和跨设备保留期限未定，不新增默认删除任务。

核心JSON采用现有 `BackupFormat` v3、兼容v1/v2，先整体验证再事务补缺；coverage可选，不能改变旧格式解析。业务文本/AI会话可能含个人信息；凭据、NAS/HA绑定、outbox/cursor、媒体/OCR均排除，目标身份保留。媒体清理与保存仅同isolate协调，不构成跨进程保证。

NAS在线dump及现有restore不等于完整应用灾备。配套密钥、manifest、异地副本、epoch和隔离恢复仅按DR提案推进；不拿核心JSON代替完整本地恢复现场。

---

# 8. API契约与适配边界（已存在接口，非新增提案）

接口前缀固定 `/api/v1`。路由依据 `backend/internal/httpapi/handler.go` 和 `platform/server.go`；字段依据领域DTO和 `lib/domain/models/nas_*`，详细NAS契约引用 `docs/nas/`，不以历史示例覆盖源码。下述“有路由”不代表App端全部闭环或真实联调通过。

## 8.1 认证、家庭与设备

- `POST /auth/register`、`POST /auth/login`、`POST /auth/refresh`、`POST /auth/logout`；注册使用email/password/nickname，可携带device信息；Token只在安全存储按endpoint会话使用。
- `GET /me`读取用户/家庭membership/设备；`POST /families`、`GET /families/current`、`POST /families/invites`、`POST /families/join`、`GET /families/members`。
- `/devices`及`/devices/{device_id}`用于设备登记/列表/撤销，具体方法与角色按现有handler；不要因文档权限矩阵便假定已有成员删除/改名客户端入口。
- family/device归属由认证及后端资源校验决定。Token来源绑定不实现业务数据搬迁；成员/家庭切换见D-02。

## 8.2 同步操作与版本校验

| 方法与路径 | 关键契约 | 调用/落库边界 |
| --- | --- | --- |
| GET `/capabilities` | schema_version、sync_protocol_version；media_upload/ai_proxy/ollama_embedded为false | 不创建checkpoint；业务claim/push前验证1/1；非schema readiness |
| GET `/sync/bootstrap?device_id=…` | snapshot、server_cursor、checkpoint、available_modes、版本 | 一致读；暂存不是已合并，不因无snapshot清刷新要求 |
| POST `/sync/bootstrap/confirm` | mode/device_id/local_workspace_id/snapshot_cursor/checkpoint；accepted/next_action/回执cursor | 用户明确选择join_and_merge/create_new_family/keep_local_only；比较原checkpoint和模式 |
| POST `/sync/push` | device_id/base_cursor、1～100 changes；四种operation，change_id/idempotency_key等 | accepted/replayed/conflict/rejected逐条匹配；pushAckCursor不是pullCursor |
| GET `/sync/pull?device_id=…&cursor=…&limit=…` | 1～500 limit；changes/next_cursor/has_more | 先整页校验，再业务/receipt/安全cursor提交；失败变化之前停止 |
| GET `/sync/conflicts`、GET `/sync/conflicts/{id}` | device范围、status/limit/offset、原resolution证据 | 最近记录不是完整历史归档；超出可恢复证据时保守阻塞 |
| POST `/sync/conflicts/{id}/resolve` | action/device等、服务端版本/权限及真实回执 | 接受后才能本地结算；人工解决不重排原幂等命令，要求新快照 |

operation为entity_upsert、entity_delete、inventory_command、home_assistant_command，不使用通用entity_upsert伪装库存增减/HA物理动作。传输超时未知结果与业务rejected不同；未知重试原ID/key，失败不丢审计。当前协议没有server_instance_id/restore_epoch，不能检测同URL旧库恢复；D-07批准后需另做wire兼容方案。

## 8.3 平台与Home Assistant

- `GET /health`：DB连通200/503、2秒probe；`GET /version`：app/api/schema版本；不泄漏配置/密钥，不宣称迁移或业务就绪。
- `/home-assistant/integrations`及单integration的test/discover；entities列表、单实体state/commands；permissions。实体目标需integration_id+entity_id与家庭权限同时匹配，commands只接受typed白名单。
- 耗材组、配方、联动规则/建议/事件已有后端路由；scene/script与App配置、HA事件来源/监听和库存闭环仍按缺口追踪，路由存在不证明全链路完成。
- 当前无NAS `/barcode`、`/ai/chat`、`/ai/ollama/status`或media presign/complete；不实现代理，不把历史示例当待补接口。

## 8.4 错误、重试及隐私

现有错误包络使用error.code/message/details/request_id；App以 `NasApiError` 分辨网络、认证、权限、校验及非法响应。不展示上游原始Token/响应，request_id仅用于脱敏诊断；业务冲突可能是push回执的一部分，不能只以HTTP 2xx判断成功。

版本不兼容（SYNC_VERSION_INCOMPATIBLE）不自动claim/推送；无权限、业务拒绝、未支持字段/模式不应进入自动忙循环。可重试网络错误遵守引擎退避；认证刷新单飞、失效会话禁止回写。超时不能视为未执行，更不能给物理HA动作生成新key盲目重放。

---

# 9. 前端页面与状态

## 9.1 页面关系

> 本图包含后续产品方向；scene/script、混合联动等未闭环部分不表示已可操作。已接入操作的当前反馈与保护见15.3，不据本图重设计既有UI。

移动端采用“4 个核心入口 + 中央突出 AI 助手”主导航体系：

```text
App Shell (底部导航 / 大屏 NavigationRail)
├── 首页 (Home / Dashboard)
│   ├── 提醒摘要卡片 (已过期 / 临期 / 低库存) -> 待处理提醒详情页
│   ├── 采买速览卡片 (待买条目 / 建议) -> 采买清单详情页 (/shopping)
│   ├── 常用家居快捷操作
│   └── 扫码 / 拍照 / 手动入库快捷入口
├── 库存 (Inventory)
│   ├── 完整商品列表、搜索与多维筛选
│   ├── 商品详情与批次时间线 (/products/:id)
│   └── FEFO 消耗 / 补充 / 报废操作
├── [ AI 家庭助手 ] (中央突出圆形入口)
│   ├── 设备控制意图 (开电视/调空调/开制冰机)
│   ├── 物资查询与操作意图 (查库存/加采买)
│   └── 混合联动任务意图 (洗衣服耗材确认计划)
├── 家居 (Smart Home - Home Assistant 联动)
│   ├── 常用场景与脚本执行
│   ├── 房间分区设备控制 (客厅/厨房/阳台)
│   └── 设备耗材联动看板 (洗衣机完成 -> 扣减耗材确认)
└── 我的 (Profile & Settings)
    ├── NAS 增量同步与家庭组管理
    ├── Home Assistant 连接、设备白名单与联动规则
    ├── 主题切换中心 (经典 / 嬷嬷 / 哆啦A梦 / 深色)
    ├── API / AI 服务配置与用量审计
    └── 本地 JSON 备份与恢复
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

- 当前分类：临期、过期、库存偏低；开封后仅为后续方向，不提供虚假规则；
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
6. 效期提醒排除已用完、已丢弃和未设置效期批次；无效期批次仍参与库存与低库存计算。确认只写独立记录，过滤匹配key和fingerprint；
7. 低库存按商品维度汇总所有有效批次的总量触发，不按单个批次触发；
8. AI入库提取只能进入草稿；授权库存建议须显示真实计划逐次确认，复用业务服务，不执行模型任意工具；
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
- 临期、过期、低库存与策略继承/关闭；开封后输入按未支持拒绝；
- 核心JSON v1～v3兼容、身份净化和SQL失败回滚；CSV为范围外；
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
- 未来公开发布时，哆啦A梦/容嬷嬷等主题的版权/商标风险；
- 用户自建AI的可达性、费用和性能；NAS不托管Ollama，不将其资源指标作为NAS承诺。

## 12.2 NEEDS_CONFIRMATION

统一以REQUIREMENT第13节D-01～D-08及灾备DR表为准。说明书检索/统计已接入，不再笼统列为未开发；来源责任、社区共享与发布范围仍待确认。工作区/首次迁移/时区/网络/readiness/恢复方案不得从代码反推批准。

嬷嬷/哆啦A梦主题在当前个人本地使用与私有设备验证边界内已确认；未来公开发布前仍须按 Q-012 重新审查。

---

# 13. 历史实施顺序与后续能力（当前入口见15.5）

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

## Phase 2：识别与图片（代码已实现，验证待执行）

- 条码扫描；
- 本地缓存和可选条码 API（预配免费 Open Food Facts 主服务，可选副服务和兜底服务）；
- 图片压缩、本地 OCR；
- AI 解析草稿和用户确认。

实现边界：条码查询仅为候选填充；图片和 OCR 默认留在本机；调用 AI 前只发送经用户确认的 OCR 文本，不发送原图，模型输出只可填入可编辑草稿。当前库存问答可基于本地库存快照调用用户自配 AI；说明书外部搜索与基于本地 OCR 片段的问答已接入商品详情页，7/30/90 天统计图表和采购建议基础也已接入。

## Phase 3：NAS 同步（代码已实现，验证待执行）

- 后端认证和家庭组；
- PostgreSQL schema 与迁移；
- bootstrap/snapshot、push/pull、outbox/change log；
- 冲突报告、远端 keep_local/keep_remote 最小闭环、设备管理、Docker Compose；
- NAS 不可用时离线继续工作；
- 网络恢复 debounce、自动重试和依赖阻塞排序。


### 13.1 AI三级降级机制（历史方案，当前配置测试/超时规则优先）

为保障 AI 能力（入库草稿提取与智能库存问答）在各种复杂网络与上游波动下的可用性，系统支持「主 API → 副 API → 兜底模型」三级自动降级机制：

1. **调用链链路**：
   - 优先尝试主 API（Primary）；
   - 主 API 失败时，无缝切换到副 API（Secondary）；
   - 主、副均不可用时，自动降级到轻量/备用兜底模型（Fallback）；
   - 降级流程对业务上层调用方（如 `AiDraftService`、`AiAssistantService`）透明，统一交付标准响应。
2. **失败判定标准**：
   - 网络异常/连接超时；当前默认单请求60秒（9月22日决策优先），不是整条降级链的固定总预算或5秒承诺；
   - HTTP 状态码非 2xx（如 429 限流、500/502/503 服务异常）；
   - 返回内容为空、格式解析失败或缺少必需字段；
   - 触发敏感/异常关键词校验。
3. **审计与容灾日志**：
   - 每次调用均在 `AiExecutionAttemptLog` 中记录：所用级别、生效模型、耗时（ms）与失败原因；
   - 若三级 API 均告失败，输出 error 级别日志并统一抛出 `AiFallbackException` 标准错误结构。

### 13.2 通用外部服务降级

- AI 与条码查询共用通用降级执行器，统一处理非空配置筛选、主 → 副 → 兜底的顺序、单次耗时及全链路失败；协议构造、响应解析和业务校验仍保留在各自服务内。
- 条码查询预配免费的 Open Food Facts 第三方接口，但默认关闭；启用后才发送条码。副服务和兜底服务均为可选项；确认“查无此商品”不是故障，不再继续切换服务。

## Phase 4：说明书与 AI 增强（代码已实现，验证待执行）

- 说明书 OCR 库与本地 FTS5 检索；
- 基于检索片段的问答；
- 采购建议和库存统计基础；
- Home Assistant 耗材组、配方、联动规则、事件和采购建议基础；
- AI 主题生成仍不实现，需先解决版权和资源安全问题，且不影响内置主题。

---

# 14. 结论

产品核心闭环为：**录入 → 管理批次 → 提醒 → 消耗 → 补货**。Flutter/PG、本地日期规则、整数件、用户自配AI和安全存储已有既定边界；当前阻塞是App编译/测试、同步覆盖与跨工作区/时区缺口、运维恢复门禁及真实验收，不能再笼统写为所有基础决策未收敛。

Flutter、NAS PostgreSQL、允许无到期日期商品入库、首次连接由用户选择家庭/新增家庭、整数件库存、按商品总量触发低库存、AI 始终由客户自行配置 Key，以及“default 默认启用、momo/doraemon 随包提供并在主题中心作为备选”均已确认。当前单机核心、条码扫描、图片/本地 OCR、说明书外部搜索/本地 OCR 问答、用户自配 AI 辅助能力、统计图表、采购建议基础、HA 耗材联动基础与 NAS 同步主要代码均已落地；社区共享数据、部分实体同步覆盖和真实环境联调仍需后续完成或验证。**superseded（snapshot 历史状态）**：当时跨实体全事务未完成，现已落盘事务应用/完成标记方案但尚未验收，不能认定完整同步完成。当前主题仅限个人本地使用和私有设备验证，未来公开发布前仍需重新完成授权/合规审查。

**历史状态（superseded）**：`implementation-complete-for-confirmed-scope`（当时按要求跳过测试、构建、验收和真实环境联调）。2026-10-07 工作区以文末“已批准，代码已落盘并完成源码复核，测试/验收未执行”为准，不能将该历史标记解读为当前完成或可发布。

## 14.1 CI 回归约束

- AI 会话请求必须绑定一次性请求令牌；删除或清空对应会话时立即使令牌失效，迟到的成功/失败结果均不得写回已重置的会话，也不得覆盖后续请求的 Loading 状态。
- 首页未接入能力的 SnackBar 采用“最新操作立即替换旧提示”，避免旧提示退出动画阻塞新提示，同时不得修改智能家居示例状态或伪报执行成功。

## 2026-09-22：AI 与首页实现修订

此节优先于历史只读助手与 5 秒超时方案：

- `AiConversationStore` 为应用级 Provider，使用现有 `app_settings` 的 `ai_conversations_v1` JSON 保存会话与当前选择；串行写入，发送前保存用户消息，弹窗关闭不销毁请求。无数据库 schema 变更，旧安装无历史记录时创建首个会话；损坏存档不覆盖。
- 模型只生成白名单库存建议。`AiInventoryActionService` 解析和校验真实 ID、正整数数量及权限，UI 展示真实库存生成的确认内容后调用既有 `InventoryService`。操作回执先保存“执行中”再写库存，成功后保存完成状态；进程中断的不确定结果不允许同一建议自动重试，须核实库存。
- 设置页连接测试使用当前编辑值及安全存储的已保存密钥，只尝试该配置，不借助副/兜底掩盖失败。测试可能产生少量费用并在界面说明。
- AI 默认请求 60 秒；不发送非必要的 temperature 参数以兼容限制采样参数的服务；Responses 遍历所有 message/text，Chat 支持文本片段数组；HTTP 正文按 UTF-8 解析，日志只保留脱敏错误分类。
- 用量存储保留既有最多 500 条上限；渲染仅构建当前页，不扩大日志存储或新增数据表。
- 条码独立测试绕过缓存与启用开关（仅用户主动点击发送）；Open Food Facts 请求限制返回字段，HTTP 404 且明确 status=0/found=false 作为未收录，其余 404 仍为故障。
- 首页整合重复入口，右侧按三行展示 NAS/HA 未接入、AI 未配置或已配置待验证；不使用 Mock 在线状态。
- NAS 认证、家庭/设备、同步网络层、Flutter 账号状态、同步业务 Repository 适配/Provider 组装、HA 客户端 Repository 和 HA 页面真实接入已按既定契约实现；应用启动/前台恢复/同步引擎可用时的 best-effort 调度骨架、手动同步入口与冲突记录去重已实现；本地业务写入与 outbox 原子组合、同步设置、bootstrap snapshot、冲突延迟游标和远端冲突最小解决 UI 已落地，网络状态监听、恢复 debounce、自动重试和依赖阻塞排序已接入。测试、构建、验收、Docker、PostgreSQL、NAS/HA 实机及端到端联调本轮未执行，未联调状态不得显示为在线/成功。

## 2026-09-26：同步设置与冲突入口修订

- **稳定本地工作区标识**：`sync_local_workspace_id` 保存在现有本地设置表中，由 `localWorkspaceIdProvider` 缺失时生成一次并跨重启复用；`syncEngineProvider` 将其传入 `SyncEngine`。该值不是每次同步临时生成的运行时 ID。
- **最小真实同步 UI**：设置页新增 `SyncSettingsScreen` 入口，展示 NAS 同步是否就绪、同步范围、local workspace ID、bootstrap/同步状态、最近成功与错误，并支持手动同步。bootstrap 区展示服务端返回的首次连接结果与可选模式，用户确认后才更新本地 bootstrap 状态；确认动作不等同于已完成快照合并。
- **冲突 UI 的能力边界**：页面同时读取本地和远端 open conflicts；“保留远端”以及普通实体的“保留本地”先调用远端 resolution API，服务端接受后才更新本地 `rejected`/`resolved` 记录。库存与 Home Assistant 冲突不伪造普通 `manual_merge`/`keep_local`。远端失败时不删除本地冲突。bootstrap 模式要求用户明确选择，不默认替用户选项。
- **调度与网络**：`SyncScheduler` 已监听应用启动/恢复、provider/引擎可用和网络恢复事件，负责 best-effort、合并重入请求，并使用开源 `connectivity_plus` 做网络状态去重、恢复 debounce 与自动重试；`onNetworkAvailable()` 保留为手动/兼容触发入口。
- **验证状态**：本轮按用户要求跳过 Flutter 测试、`flutter analyze`、构建、Go 检查、Docker、PostgreSQL、NAS/HA 实机和端到端联调。上述项目未执行前，不得把页面状态、bootstrap 结果、冲突本地标记或同步调度描述为在线、远端已成功或生产可用。


## 2026-10-03：并行可靠性加强

- Snapshot 改为固定依赖顺序预校验；business adapter 通过现有 Drift 全事务写入，pending bootstrap 清理在同一提交，冲突记录在回滚后仍可追踪。库存、采购、outbox repositories 必须共享数据库。
- 分类绑定与提醒低库存策略复用 app_settings；不新增 schema。无法安全映射字段显式失败，不默默存元数据当成业务已生效。**历史说明（superseded，2026-10-07）**：当时默认七天与本地三十天规则冲突、已有批次数量收敛仍待决策；现已批准并进入未验收实现，见下节。消费历史和出站分类映射仍未完成。
- 核心 JSON 备份过滤身份/同步状态并净化服务配置，coverage 为兼容的可选元数据。完整媒体归档未实现，页面不再标“全量备份”。
- 首页及家居既有电源控件使用明确 turn_on/turn_off；当前成员角色授权、capability和新鲜状态共同预检，NAS仍是最终权限校验方。控制面板用自身 Consumer订阅真实回执；未支持音量/静音只提示未发送。没有重设计卡片/主题，也没有开放高风险控制或客户端保存HA管理Token。
- 无新增依赖或数据库迁移。全部新Dart测试、构建、Go及真实环境验收均未执行；不能把历史CI成功当作本批次通过。详情见 `docs/IMPLEMENTATION_BATCH_2026-10-03.md`。


## 2026-10-07：提醒策略与 NAS 权威库存实现修订

两项业务决策均获用户批准，不再待确认。区分已批准目标、当前落盘代码和未运行验收；细节/部署与补偿回滚见 `docs/IMPLEMENTATION_DECISIONS_2026-10-07.md`，验收见 REQUIREMENT 的 AC-011～AC-014。

### 提醒策略（不改变库存事实）

- `ReminderRepository` 校验并将 NAS 设置保存为现有 app_settings 作用域覆盖；`InventoryRepository` 组合 `ReminderPolicy`：商品策略 → 家庭策略 → enabled=true/30 天默认，可空阈值 → 家庭阈值 → 本地商品阈值。旧 threshold-only 覆盖按 enabled/30 天兼容，显式 7 天不覆盖，tombstone 恢复继承。
- `InventoryItem`、`ExpiryRules`、`ReminderRules` 和通知读取同一有效策略窗口。关闭策略停止该策略提醒候选/摘要/通知，不抹去 expiryDate、过期/低库存事实、不改数量或 FEFO。去重与确认指纹仍有效；策略窗口变化参与效期指纹。
- 非空 `opened_warning_days` 一律显式拒绝（包括关闭策略），未知或非法输入不伪装成支持；重复有效商品/家庭策略和错误字段整批拒绝。
- 提醒/库存补修只将首页和提醒详情标题改为“临期提醒”，通知正文显示实际天数；没有新增设置编辑 UI、依赖或本地 Drift schema。工作区其他 HA/UI 改动属于既有未提交工作，不借此重设计。

### 权威 snapshot 与安全提交

- `SyncOutboxRepository.hasSnapshotBlockingChanges` 按完整 scope 检查 pending/inFlight/blocked/conflict/rejected 与 open/deferred 冲突。引擎和业务适配器都使用该保护；事务外预检、事务内写入前与完成前复检，不能只保护快照涉及的 entityId。
- `SyncBusinessAdapter.applyRemoteSnapshot` 先按依赖顺序预校验完整 snapshot，再在共享 Drift transaction 通过 `authoritativeSnapshot=true/applyQuantity=true` 应用批次数量及 version；同版本可纠偏，更低版本拒绝回退。业务写入与 pending 完成、安全 cursor 同事务，不用“只升 version、留旧数量”假装收敛。普通增量 entity upsert 不转化为库存增减，库存仍走幂等权威命令。
- `SyncEngine` 推送前持久化 `refresh_required`，以原 outbox identity 发送/重试；只有 scope 静默才重新 bootstrap fetch 并确认当前 checkpoint，再应用快照。被 maxPush 截断、拒绝、冲突或未知结果时不消费旧 snapshot；崩溃恢复保留刷新要求。
- 未知推送结果使用原 operationID/changeId/idempotency key，accepted/replayed 回执按原条目结算；receipt 与安全 cursor 保持原子/幂等约束。历史恢复和出站分类映射没有因此自动完成。

### 批次状态与网络竞态保护（源码已复核，未验收）

- `discarded` → `isDiscarded=true`；`active/used_up/expired` → false，避免已有本地报废标记错误保留。`used_up/discarded` 要求 quantity=0；`expired` 不生成虚假日期，真实 expiryDate 决定本地过期事实。未知状态、冲突状态/兼容字段或非法数量 fail closed，事务回滚。
- refresh 请求前保留 pending/checkpoint/模式基线，网络返回后的本地事务再次比较；用户已重新选择或替换 pending 时，丢弃旧响应，不覆盖新 `keep_local_only`。确认回执同样不能写回不同的 pending；代码已落盘并完成源码复核，相关回归用例源码已补充，测试/验收未执行。

- `_confirmBootstrap` 的远端同步模式回执要求 accepted、预期 nextAction、checkpoint 一致及 `response.serverCursor >= snapshotCursor`；只有有效确认才允许单调提升 pushAckCursor。invalid/rejected receipt 保留原 pushAckCursor，记录 blocked/error，不消费 pending snapshot。
- 写入 `refresh_required` 前先在事务中比较原 pending 与已确认 mode/keepLocalOnly 状态；fetch 返回后再次比较 pending/checkpoint 与 mode，拒绝迟到覆盖。手动 `bootstrap()` 同样比较请求前后 pending/mode，保留已有 refresh_required；刷新必需但响应缺少 snapshot 时失败并保留 pending/刷新标记，不用缺失 snapshot 清除刷新要求。
- 确认游标过旧、错误回执不抬 pushAckCursor、刷新标记写入/网络返回的选择竞态及手动 bootstrap 缺少 snapshot 的回归用例源码已加入。代码已落盘并完成源码复核，测试/验收未执行。

### 后端一致快照、checkpoint 与 cursor 排序

- `ReadBootstrap` / `ReadBootstrapForDevice` 在 repeatable-read transaction 内读取所有业务行和 cursor，设备锁/checkpoint 锁与确认协调，避免业务行与 cursor 分离读取。
- checkpoint 最终口径为相同 cursor 复用有效 token；cursor 改变则生成新 token、state=pending、清空 confirmed_at 并重新确认。当前后端源码已见该实现分支但未验证；“每次 fetch 无条件旋转 token”是本轮中间方案，superseded。确认必须匹配保存的 token/cursor；keep_local_only 忽略客户端 snapshot token，并将请求副本的 snapshot cursor 归零用于保存/审计，不可信超前 cursor 不能阻止关闭同步；回执仍返回真实 server cursor，用户选择不能被迟到请求覆盖。
- `0005` 将新提醒 SQL DEFAULT 和同步 insert 缺值默认统一为 30，不执行旧值 UPDATE，部分 update 保留旧值。该 NAS migration 是数据库结构/行为变更，不影响本地 schemaVersion。
- `change_log` 全局 `BEFORE INSERT FOR EACH STATEMENT` trigger 在 identity 分配之前取得事务 advisory lock，持锁至 commit/rollback；identity sequence 强制 `CACHE 1`，防止跨连接缓存区间打乱 cursor 顺序。所有家庭共用序列，因此不能改成家庭级锁；直接库存写入和 sync 写入都走 change_log。不能推断该措施已修复部署前的历史漏读。
- 部署前备份、暂停相关写入并排空/重建旧连接，避免旧事务与已缓存 sequence 值绕过新保证；按现有 migration runner/checksum 机制执行。全局串行化降低写吞吐并可能增加等待/死锁压力，必须在真实 PG16/NAS 测量。补偿回滚使用新的 migration，不删除历史或直接篡改 `0005`；禁用排序措施需暂停同步并评估完整重同步，不静默退回有漏读风险的旧行为。

### 验证与边界

后端 CI 已加入 PG16 service，配置 `MOMO_TEST_DATABASE_URL`，运行入口为 `go test -count=1 ./...`/`go vet ./...`；真实 PostgreSQL 测试是 opt-in（URL 缺失则 skip），源码契约和模拟 DB 测试不是真实并发测试。本机缺 Flutter/Dart/Go/gofmt/Docker/psql，本轮 Flutter/Go/PG/CI/设备验证尚未运行。当前状态：**已批准，代码已落盘并完成源码复核，测试/验收未执行，不可据此声称生产可用**。历史、分类与 HA 联动缺口保持原范围，已执行的脚本/YAML/空白与326条非package目标存在性结果已记入VALIDATION，代码/CI/实机结果仍待补充。


## 2026-10-07 code review P1 实现补充（未运行验收）

NAS 初始量定义为累计入库的安全下界：restock 在锁定旧行上增加 initial，consume/discard 不减少；0006 以保留历史的方式补修偏小下界并发布版本化完整日志，客户端保持 `quantity <= initial_quantity` 校验。
冲突 resolution 回执不是原 outbox command 的 accepted 回执：保留旧失败记录，用 app_settings 匹配结算证据解除特定阻塞；同事务持久 scope 刷新 revision。原幂等命令不再发送。完成 bootstrap 后也须 fetch 新快照并确认，不能靠 keep_remote 后的空 pull 收敛乐观库存。完成业务事务比较精确 revision、checkpoint、mode 和 scope 静默，再原子提交 cursor 与清理标记。权威 snapshot 允许商品/采购与 tombstone 同版本纠正，普通增量不放宽。迁移、兼容、回滚与测试限制详见 `docs/IMPLEMENTATION_DECISIONS_2026-10-07.md` 第 8 节；保留现有 UI，只接原按钮与错误/待刷新反馈。

## 2026-10-08：打包失败诊断与最小修复设计（未实施）

### 目标、证据与范围

目标：恢复 AC-008 的分析、测试、Android/iOS 构建及后续发布链路，不撤销既有会话隔离、同步冲突和快照保护。本节为诊断及拟实施方案，不代表代码已修复。

- 核实的失败运行：[GitHub Actions #25](https://github.com/DavisDing/MomoBox/actions/runs/37746191082)，2026-10-08 15:52:55（Asia/Shanghai）启动，attempt 1，main 提交 `0d52280c4f7d65af2c8c9077a9a57aec78be7cc9`；本地 HEAD 与其一致。
- [Flutter job](https://github.com/DavisDing/MomoBox/actions/runs/37746191082/job/113208174224) 在 `flutter analyze` 失败：30 个 error、21 个 info，共 51 项。单元测试及 Android debug build 未执行。
- [iOS job](https://github.com/DavisDing/MomoBox/actions/runs/37746191082/job/113208174092) 完成 SDK 选择、依赖解析、Drift 生成和 config-only；实际构建在 Dart kernel 编译阶段因下述两处业务源码错误失败，随后 Xcode 退出码 65。现有证据不支持将该错误归因于签名、CocoaPods 或 Xcode SDK。
- [后端 job](https://github.com/DavisDing/MomoBox/actions/runs/37746191082/job/113208174102) 的 Go 测试（配置 PG16 测试 URL）及 vet 通过；Prepare pipeline 也通过。Release 包和镜像/Release 发布被前置失败阻断，均 skipped，不是 Docker 构建失败。
- 两处编译错误在合并前的 `1ad1cc8` 已存在；这些文件与合并后的 HEAD 无内容差异。因此不能把本次失败认定为合并丢失修复。

范围外：业务/UI 重设计、依赖升级、数据库迁移或清理、放宽权限/版本/cursor 校验、修改 CI 门禁、提交/推送或部署。当前仅更新本设计文档。

### 拟拆分修复任务与入口

1. **同步编译阻塞（P0；两个 App 平台共同根因）**
   - `lib/application/sync_scheduler.dart:219`：`_execute` 的命名参数组关闭 `}` 后还有逗号，触发 `expected_token`。按正常多行形参格式保留 `automatic` 必填项和调用契约，逗号放在命名参数组内，不改调度行为。
   - `lib/application/sync_engine.dart:395`：`mode` 为 `String?`，现有字符串白名单判定不足以令分析器在该调用点提升为 `String`。在既有拒绝分支显式检查 `mode == null`，然后保留 `join_and_merge/create_new_family` 白名单，非空后才推送/刷新。不得默认为某个同步模式，也不放宽 `_refreshSnapshotAfterPush(String mode)` 的接口。
   - 保留 push 前刷新标记、事务内模式复核、网络返回后的 checkpoint/revision 比较、keep_local_only 的中断能力；不为通过编译移除竞态保护。
2. **测试编译阻塞（P0；不涉及业务模型变更）**
   - 27 个 `ambiguous_import` 来自 Drift 和 flutter_test 同时导出的 `isNull/isNotNull`。涉及 `test/application/media_service_test.dart`、`test/application/sync_outbox_repository_test.dart`、`test/data/backup_migration_boundary_test.dart`、`test/data/conflict_authoritative_snapshot_test.dart`、`test/data/inventory_authoritative_snapshot_test.dart`。
   - 建议仅在这些测试的 Drift 导入使用 `hide isNull, isNotNull`，保留 matcher 断言；逐文件检查 SQL 表达式调用，必要时采用前缀，不能删断言或排除测试文件。
   - `test/data/backup_migration_boundary_test.dart:523` 创建 `SyncStatesCompanion.insert` 缺少必填 `updatedAt`。使用固定 UTC 测试时间补齐 fixture；`SyncStates.updatedAt` 在现有表定义中无默认值，不修改 schema 或生成文件来适配测试。
3. **现有 lint 清理（P1；随同修复，保持 analyze 门禁）**
   - 13 个 `curly_braces_in_flow_control_structures`：为日志指定的 scheduler、outbox repository、NAS account controller、home/smart home/sync settings screen 分支补花括号，保持 early return 和回执保留条件完全不变，不改页面布局。
   - 7 个 `use_super_parameters`：仅调整 media/sync business adapter/sync engine/home HA 测试子类的构造器转发，保留附加构造参数。
   - 1 个 `unnecessary_import`：删除 `test/presentation/backup_operation_lock_test.dart` 已由 Flutter services 提供的重复 typed_data 导入。
   - 不通过 `--no-fatal-infos`、ignore、排除目录或关闭测试门禁掩盖问题。

任务 1、2、3 可按文件所有权拆分；任务 1 和任务 3 都涉及 scheduler，宜交同一实施者以免互相覆盖。不新增模块、依赖、数据契约或页面状态。

### 验收与下一阶段入口

实施后先执行平台壳生成、`flutter pub get`、`dart run build_runner build --delete-conflicting-outputs`，再执行以下顺序；SDK 缺失时须由 CI 验证，不能将源码复核当成功：

1. 使用与本次 CI 对齐的 Flutter SDK（日志为 stable 3.47.6），检查变更文件格式并运行 `flutter analyze`：退出码 0，已知 51 项消除，不增加 ignore。
2. 运行相关同步、outbox、快照、备份回滚、媒体、账号会话、HA 和备份锁回归，再运行 `flutter test --reporter expanded` 全套，保持原有测试断言。重点确保 null/非法模式不推送、不自动确认、不推进 cursor，合法模式仍能刷新；运行中 keep_local_only 不死锁。
3. 运行 `flutter build apk --debug` 和现有 iOS unsigned xcodebuild（保留 Xcode 27/iOS 27 下限）；两者必须实际成功，不以 config-only 代替构建。iOS 无签名构建通过也不等于真机安装验收。
4. 新提交须全套 CI 通过，再核实版本化 APK/AAB、NAS Compose/env、校验和及双架构镜像实际产出；当前后端 job 的成功不能替代新提交或发布验证。

当前诊断与修复入口明确，无新增业务决策待确认；**进入业务代码实施仍需用户明确要求**。本轮未修改业务代码、未重跑 CI、未提交/推送。建议在新 CI 通过后为 AI_CONTEXT/VALIDATION 增补按 commit/run 标识的验证记录，不把历史“未验收”整段改成“全部通过”。


### 2026-10-09 复核：run #26 仍失败，修复尚未实施

- 证据：[GitHub Actions run #26](https://github.com/DavisDing/MomoBox/actions/runs/37755341512)，main commit `02513dd6018aba9ab45b5d5ebda27f3437b2f3a1`；运行发生于 **2026-10-08 17:15:04～17:22:47（Asia/Shanghai）**，不是10月9日新触发的构建。10月9日查询时仍为最新一轮。
- 本地同一commit与上一轮 `0d52280` 的差异仅为 REQUIREMENT/DESIGN 文档；`lib/`、`test/`、`backend/`、CI和部署配置未变化。因此本轮不是文档改动引入了新编译错误，而是上述最小修复设计尚未实施。
- iOS日志仍定位到 `lib/application/sync_scheduler.dart:219` 的命名参数组结束后多余逗号，以及 `lib/application/sync_engine.dart:395` 的 nullable mode 参数；静态分析仍报告51项。保留上述源码guard、测试导入/fixture及lint修复方案，不通过改SDK、放宽检查或删除用例绕过。

| 当前证据范围 | run #26 状态 | 不能据此推断 |
| --- | --- | --- |
| Prepare pipeline | PASS | 不等于App可编译 |
| Flutter static analysis | FAIL（51项） | 不等于单元测试已运行 |
| iOS unsigned build | FAIL（Dart编译） | 不能认定为签名或SDK缺失问题 |
| Backend test / PostgreSQL regression / vet | PASS | 不等于Docker镜像已构建或NAS部署验收通过 |
| Flutter unit tests / Android debug build | SKIPPED | 不能记作通过或已打包 |
| Build release packages / Publish image and GitHub Release | SKIPPED | 没有本轮成功发布证据 |

本次只复核并记录诊断，未修改业务代码、未重跑CI、未提交或推送。下一阶段需用户明确要求实施最小修复包；本机SDK仍缺失，实施后的运行验证以同一修复commit的CI结果为准，发现后续错误需继续定位，不能承诺消除当前51项后全部构建必然通过。


### 2026-10-09 实施补充：用户已授权最小修复，待运行验证

用户本轮明确要求“修复”，现已从上述设计进入最小代码修复；此前“未实施”与run #26失败状态保留为历史证据，不代表修复后的运行结论。

- `_execute` 使用合法的命名参数声明，消除结束参数组后的多余逗号；同步刷新分支明确拒绝 `mode == null`，仍仅接受 join/create。确认流程不进入执行队列，keep_local_only中断、checkpoint/revision、事务及cursor保护均保留。
- 五个测试文件仅隐藏Drift的顶层 `isNull/isNotNull`，保留matcher断言；备份回滚fixture补固定UTC `updatedAt`，不改schema/生成文件。对13处多行控制语句补花括号、7个测试构造器使用super参数，移除一个重复导入，保持控制条件/回执判断不变。
- `test/application/sync_engine_test.dart` 新增四组参数化回归：空值/非法mode × 有/无pending命令；断言不push/bootstrap-confirm/pull、不应用暂存快照、不推进cursor、不改变pending原请求/幂等key/尝试次数。原合法join/create、keep_local_only迟到快照及并发中断用例保留。
- 本次未改页面布局、依赖、数据库定义、后端、部署配置或CI门禁，也未修改D-01～08/DR待决边界。

已实际通过平台准备、发布版本计算及NAS脚本回归、相关shell语法、workflow/Compose YAML解析、332条非package/non-generated本地Dart引用路径与差异空白检查；原测试断言行保留及针对性源码检查通过。这些轻量检查不能证明Dart语法、类型、测试或打包通过。

**NOT_EXECUTED**：Dart format/analyze、Flutter全套及新增四组测试、Android/iOS打包、Go/容器运行验证。本机PATH与所检查常见SDK位置未找到Flutter/Dart；未安装依赖、未提交/推送、未重跑CI。下一步按上述验收顺序验证同一修复commit，不能沿用旧run #26或后端PASS证明本次App修复已通过。详见 `docs/VALIDATION.md` 同日记录。

# 15. 当前App/NAS收尾设计与验收映射（2026-10-08）

## 15.1 模块责任与修改入口

复用现有分层，不添加“恢复中心/通用任务总线”等架构层。下面是当前代码职责及后续修复入口，不表示这些入口已经通过编译和运行验收。

| 模块/入口 | 责任 | 禁止承担的隐含责任 |
| --- | --- | --- |
| `lib/application/inventory_service.dart`、`data/repositories/inventory_repository.dart` | 校验数量/FEFO，提交业务及outbox，适配权威库存 | 不从UI或AI直接写数量，不以远端snapshot覆盖未解决本地意图 |
| `lib/application/nas_auth_service.dart`、`services/nas_credentials_service.dart`、`data/nas/nas_api_client.dart`、`presentation/controllers/nas_account_controller.dart` | endpoint/session生命周期、刷新单飞、安全存储及账号反馈 | 不清业务库；不将Token来源绑定当业务工作区/灾备身份 |
| `lib/presentation/controllers/providers.dart`、`lib/app/momo_box_app.dart` | 同数据库装配、被动构造scheduler、App start/stop与会话/队列重绑 | provider构造不偷偷发请求；测试独立override不能触发无意自动同步 |
| `lib/application/sync_scheduler.dart`、`sync_execution_coordinator.dart` | 前台触发/合并/延迟与有界续跑；同DB实例/scope串行run/bootstrap | 不重新排队rejected，不以deferred自触发，不宣称跨进程锁/常驻后台 |
| `lib/application/sync_engine.dart`、`sync_business_adapter.dart`、`data/repositories/sync_outbox_repository.dart` | 兼容、claim/push/pull、checkpoint、结算/快照及cursor安全 | 不绕过mode/冲突、不把resolved冒充原命令成功，不跨历史盲重放 |
| `lib/data/nas/nas_sync_api.dart` | DTO/HTTP/超时与会话有效性检查 | 无调度/业务库写入；Token provider返回null不回退旧Token |
| `lib/presentation/screens/sync_settings_screen.dart` | 手动同步、模式确认、冲突处理及真实进度/错误 | 不直接另起独立runOnce，不将partial报告标完成，不替用户选bootstrap |
| `lib/application/media_service.dart`、`data/repositories/media_repository.dart`、`services/media_storage_service.dart` | 文件+元数据、OCR/重关联/清理序列化 | 不上传原图/搬迁附件，不把一天草稿保护当长期归档 |
| `lib/presentation/screens/settings_screen.dart`、`application/backup_service.dart`、`data/repositories/backup_repository.dart` | 通知恢复、备份owner锁、验证/净化与事务导入 | 不在备份中携带身份/队列，不用测试通知状态刷新清业务通知 |
| `backend/cmd/momo-backend/`、`internal/platform/` | 配置/组装、HTTP drain、DB/健康探测、migration | serve/health目前不证明schema readiness，不能按健康自动批准恢复开放 |
| `deploy/nas/docker-compose.yaml`、`deploy/nas/scripts/` | 双服务/固定镜像、备份/恢复/更新和目录锁 | 目录锁不冻结业务写入，不提供跨主机fencing或无损恢复保证 |

## 15.2 关键数据流与一致性边界

### A. 本地操作 → 幂等推送 → 权威收敛

1. 用户/已授权AI计划经业务服务校验，Drift业务写入与需要的outbox同事务提交；单机无NAS仍可完成库存，原有数据不会因连接失败消失。
2. scoped已提交pending请求变化触发300ms debounce；启动/恢复、750ms网络恢复debounce及前台约1分钟检查复用scheduler。计时是当前源码参数，不是产品SLA。
3. 同DB实例/scope的runOnce与bootstrap通过coordinator串行；同引擎重入合并。confirm保留中断能力，不能放进同一排队锁造成keep_local_only与悬挂bootstrap死锁。
4. 引擎检查就绪/退避、capabilities 1/1、当前会话和已选mode后才claim/push；每批最多100，未知回执保留原operation/change ID和key。
5. 需权威快照时先事务持久化refresh_required，再推送；scope静默后fetch一致快照并confirm当前checkpoint。事务内前/后复核mode、pending、冲突刷新revision，业务/数量/version/完成标记/cursor原子提交。
6. maxPush截断、失败审计、未解决冲突保护scope；只有`hasMorePending`或无deferred且`hasMoreRemote`才250ms有界续跑（最多8轮），后台/offline/dispose停计时。达到边界保留队列，不伪造完成。

### B. 增量拉取与页面错误

先整页结构验证，确认排序、ID唯一与nextCursor进度后才调用业务适配；应用变化与相应receipt/安全cursor按既有事务边界提交。已安全应用的前序变化可保留，后续冲突/未支持变化必须停止在安全cursor，不跳过它，不声称整页/整轮成功。

单run至多100页，剩余页返回hasMoreRemote并有界续跑；尾页前不更新整轮lastSuccessAt。scope未静默时不以普通pull规避snapshot保护；普通实体upsert不转成库存命令。epoch尚未实现，该流程只适用于既有同历史会话。

### C. 登录/切服务器/退出

规范化endpoint（scheme/host/port/path）匹配安全存储binding；凭据写入有序并以binding作为提交标记。请求与页面均绑定session generation，切换/登出立即失效；旧传输实例只读取原会话，不借新服务器Token执行旧请求。存储失败和晚到刷新也不重新启用旧会话。

这只保护网络/凭据边界。当前商品/批次并非按workspaces分库，切家庭后如何处理已有业务是D-02；同URL旧dump恢复是D-07。两者不能靠清Token、清cursor或自动bootstrap替代设计。

### D. 媒体、通知与核心JSON

媒体操作在同isolate共享队列内完成保存、metadata/关联、OCR或删除/reconcile；异常按现有补偿处理，保留草稿与失败证据。通知授权/恢复读取最新真实库存和确认记录后重算，业务操作不依赖系统权限成功。

JSON导入：owner锁覆盖picker→确认→校验→事务→报告/分享，退出仅由owner释放；先格式/数量/净化检查再整批事务补缺，SQL异常回滚并保留目标身份。导出不是媒体打包/灾备加密，聊天文本隐私提醒必须保留。

## 15.3 UI操作与必要状态（不改既有视觉）

本表定义状态语义，不要求新增页面或改变enum/布局；优先用既有状态栏、消息、按钮忙态和冲突入口呈现。

| 场景 | 用户可做什么 | 必需反馈/保护 |
| --- | --- | --- |
| 未配置/未登录 | 配置、显式登录；继续单机 | 不宣称NAS在线；旧凭据无binding提示重新登录 |
| bootstrap待选择 | 查看可选模式并确认；可保持本地 | 不默认选项；“确认成功”不等于“数据已合并” |
| 同步执行中/有余量 | 手动尝试合并当前请求；看进度 | 防重复；partial、hasMore与deferred区别显示，旧会话报告丢弃 |
| 不兼容/认证失败/退避 | 看原因、重新认证/换兼容版本/待退避后重试 | 不清队列，不以手动按钮绕过安全条件 |
| 冲突/结算待刷新 | 服务端接受后本地结算/恢复原回执；拉新快照 | 保留失败审计；库存/HA不伪造通用manual_merge/keep_local |
| 权限拒绝/恢复 | 打开系统设置，返回后补检 | 用最新数据重算；通知失败不妨碍库存 |
| 备份忙/取消/失败 | 取消、看范围/隐私/结果；结束后重试 | owner互斥与mounted检查，取消不留锁，格式/SQL失败不部分导入 |
| HA无权限/离线/不支持/在途 | 可用typed手动操作或明确未发送 | 不用Mock翻转设备，不让迟到旧controller结果覆盖新设备状态 |
| NAS灾备恢复 | 当前只读保留现场并按独立处置计划操作 | epoch审阅UI未实现；不可用设计稿假称已有恢复功能 |

原有导航、卡片、电源控件、主题受保护；scene/script/联动看板在第9节是方向结构，未接通部分只能说明不可用。任何灾备新UI需随D-07单独批准视觉例外。

## 15.4 需求—设计—验证映射

测试路径是源码入口，不是已通过证据；编译阻塞修复前不要将“有测试”记为PASS。

| 验收 | 主要设计入口 | 回归入口/额外证据 |
| --- | --- | --- |
| AC-001～004、006、009～010 | Inventory/Intake、日期与本地辅助服务 | domain/application既有测试及Android16/17、iOS27首次/升级安装与断网回退 |
| AC-005/011/018 | 提醒有效策略、确认指纹、settings授权恢复 | reminder_policy/repository/rules、notification_permission_recovery、local_notification_service测试；权限/时区实机 |
| AC-007/020 | BackupFormat/Repository与owner锁 | backup_format、backup_migration_boundary、backup_operation_lock、backup_scope；真机picker/分享取消及SQL故障 |
| AC-012～013 | SyncBusinessAdapter/Engine与精确revision提交 | sync_business_adapter/engine/outbox及快照专用回归；两个设备并发离线/冲突/迟到选择 |
| AC-014 | PG 0005/0006与migration runner | backend store/platform测试，PG16配置执行；NAS存量库升级、连接缓存、锁等待/失败演练 |
| AC-015 | NAS auth/credentials/transport/controller | nas_auth_service、nas_account_session、nas_api_client、nas_sync_api；换endpoint/登出晚到/安全存储失败 |
| AC-016～017 | scheduler/coordinator/capabilities/pull | sync_scheduler、sync_engine、sync_scheduler_wiring及sync_settings_screen；连续余页、后台/断网、provider重建 |
| AC-019 | MediaService同isolate序列化 | media_service、intake_draft_media；真实文件/元数据故障与清理重入 |
| AC-021 | NAS typed control与当前controller/权限 | home_ha_quick_actions及backend HA契约；真实成员/实体、离线/超时，无高风险副作用 |
| AC-022 | config/http_lifecycle/health与Compose | Go config/lifecycle/health测试；容器SIGTERM、长请求、慢DB及模板密钥拒绝 |
| AC-008 / REQUIREMENT第12节 | pipeline与平台脚本 | 同commit全部CI、APK/AAB/镜像/附件校验和；安装签名/设备记录独立 |
| D-02～D-07（未批准） | 独立工作区/首次导入/时区/运维/DR设计 | 先确认与细化迁移，再实施/故障注入；不列为现已通过AC |

## 15.5 拆分与先后关系

1. **编译修复包**：同步源码语法/nullable guard、测试导入/fixture、lint，按同日诊断拆分；共享scheduler由同一owner改。严格不改变mode/回滚保护，先恢复全量CI。
2. **App验收包**：单机/媒体/通知/JSON/会话/调度回归与设备验收；测试故障不删用例，针对真实原因小修。
3. **NAS验收包**：当前PG测试与多设备、权限/HAtyped control验收；首次基线/工作区/时区范围先确认D-02～04，不混入编译修复。
4. **运维/灾备设计包**：D-05～07定案后才细化停写、readiness、恢复阶段和epoch协议。当前5项运维风险详见NAS_OPERATIONS_REVIEW，当前仅设计，不自行改脚本、secret或数据库。

包2/3可按独立环境并行，但正式交付都依赖包1和D-01；D-07还依赖D-02/03及配套密钥/历史策略，不能先开放自动重初始化。建议优先单机与已接入窄增强，不以赶Release绕过未决隔离问题。

## 15.6 重要风险、待决及AI_CONTEXT更新建议

- **高价值阻塞**：未编译的源码无法进入设备验收；全库未按工作区隔离可能把原家庭数据带到新scope；首次基线/分类出站/历史缺口不能用清cursor“补齐”；UTC转换可能改变date-only含义。分别按诊断和D-02～04处理。
- **运维边界**：在线dump后仍可有成功写入、restarting旧容器可能漏停、restore退出trap无条件重启、旧schema/会话/历史可能被恢复开放、HTTP原端口可能绕过代理。均是源码条件化风险，不是现场事故结论；最终备份/停写与失败隔离/候选库/epoch/TLS拓扑按D-05～07确认。
- **性能与可用性**：全局cursor锁跨家庭竞争，health不等于migration readiness；连接池、请求体/日志/附件与实际备份容量预算应在目标NAS测量后定案（D-08），不编造吞吐、内存和RPO/RTO承诺。
- **分发**：D-01需核对自动GitHub Release可见性及私有主题资源，构建通过不代表允许公开分发。本文不自动停/改流水线或批准授权资源替换。
- **长期上下文建议**：AI_CONTEXT中“未验收”须按范围保留；可在实际确认后补“main 0d52280 / run #25 后端PG配置下测试+vet通过、App失败、发布skipped”的证据索引，并强调endpoint binding不隔离业务工作区、health不验证schema/epoch。该证据是临时进度，优先进VALIDATION，不大改长期事实。

本次文档完成到“范围、职责、数据流、验收入口与建议明确”；D-01～08/DR方案尚未定案，不能称全部实施就绪。下一阶段仅在用户明确要求后开始对应实现，并在确认的数据/运维边界内工作。


## 16. 2026-10-10：run #28 测试阻塞诊断与最小修复设计（未实施）

### 16.1 目标、证据与本轮边界

目标是恢复现有测试门禁，使同一修复提交能进入 Android 打包与正式发布；不是增加产品功能。本轮按架构设计角色仅更新设计和验证记录，不修改 lib/test、依赖、数据库、UI、CI 或部署资产，不提交、推送、重跑或发布。

本轮查询最新返回的 [run #28](https://github.com/DavisDing/MomoBox/actions/runs/38010226751) 对应 main `c304100216427c18e771fd86247d2a6fef20a32e`，运行时间为 **2026-10-10 08:42:53～08:55:58（Asia/Shanghai）**，本地 HEAD 同 SHA，调查开始时工作区干净。run #27 的重复导入修复已经包含在该提交，不能再以旧静态分析错误解释本轮失败。

| 阶段 | run #28 实际结果 | 解释边界 |
| --- | --- | --- |
| Prepare pipeline | PASS | 平台/发布版本/NAS 脚本检查通过，不是部署验收 |
| Flutter static analysis | PASS | 日志显示 No issues found；SDK stable 3.47.7 |
| Flutter unit tests | FAIL | 出现失败用例，10 分钟后步骤超时终止；无全套完成结果 |
| iOS unsigned build（Xcode 27） | PASS | 不等于签名、安装或真机验收 |
| Backend test / PostgreSQL regression / vet | PASS | 不等于镜像发布或真实 NAS 验收 |
| Android debug / release packages / publish | SKIPPED | 被测试失败阻断，不能归因为已发生的 Android/Docker 构建错误 |

### 16.2 已确认错误与调查限制

1. **HA Widget 测试退出残留定时器（已确认）**：日志定位 `test/presentation/home_ha_quick_actions_test.dart` 的“真实状态和 typed turn_on；命令完成前不翻转”，退出调用在第 710 行。零时长、非周期 FakeTimer 的创建栈是 `StreamQueryStore.markAsClosed → QueryStream cancel → StreamProviderElement.dispose → ProviderContainer.dispose → ProviderScope unmount`。因此这条日志直接指向 Drift 查询流取消后的异步清理，不是 SyncScheduler 一分钟周期定时器的证据。源码 `_pumpHome` 创建真实内存数据库，并将关闭注册为 tearDown；用例最后卸载 Widget，但没有再推进一轮清理。
2. **备份测试清理阶段未初始化变量（已确认，原始触发原因待补证）**：日志还显示 `LateInitializationError: Local 'originalPicker' has not been initialized`。`test/presentation/backup_operation_lock_test.dart` 在 setUp 第一条读取 `FilePicker.platform`，随后才赋值 `originalPicker`，tearDown 无条件恢复它及删除临时目录。初始化失败可导致清理再抛异常并掩盖首错；但当前日志不能确认 FilePicker 注册失败就是首错。
3. **其他失败及总超时（未完成归因）**：可见进度到 `+345 -23` 后最终触发 10 分钟超时；这不是全套汇总，也不是 23 个独立根因。连接器返回内容中段明确含 `86373 chars truncated`，其中可能包含其他失败。公开日志下载 API 返回 403，未登录浏览器要求登录才能读取日志；未获取凭证或绕过限制。不得将上面两项当作所有失败原因，也不得断言 Drift 清理就是 10 分钟挂起的原因。

### 16.3 拟实施工作包及修改入口

| 工作包 | 独占修改入口 | 建议方案及保护条件 |
| --- | --- | --- |
| T-01 HA 测试资源生命周期 | `test/presentation/home_ha_quick_actions_test.dart` | 先单文件复现；把卸载、流取消后的有界 pump、资源关闭集中到现有测试辅助入口。只刷新已取消订阅产生的清理任务，不对未完成 HA 命令或持续动画无限 pumpAndSettle。失败路径也必须执行清理，数据库在消费者卸载后关闭；保留真实回执/无提前翻转/权限断言。 |
| T-02 备份测试初始化与失败清理 | `test/presentation/backup_operation_lock_test.dart` | 先恢复首错日志，再判断是否需要在测试入口按锁定插件 API 注册平台实现。对实际取得的旧 picker、实际创建的目录与已安装 mock 分别记录初始化状态，条件清理并可靠恢复；禁止以捕获异常、skip 或删除断言隐藏未注册问题。未完成 share/picker gate 在测试收尾显式完成或按可控取消语义释放。 |
| T-03 全套失败/挂起归因 | 完整 CI 日志及剩余失败文件，范围待列明 | 在具备同 SDK 的环境先逐文件复现；输出每条失败的文件、名称、首个异常和终止状态。对 Completer 未释放、fake clock/真实 I/O 等待、provider teardown 分别验证，不能仅增加 CI 超时。与 T-01/T-02 不交叉改文件；新增业务源码修改须有对应错误与回归证据。 |

T-01、T-02可独立实施；统一验收依赖 T-03 完整失败清单。优先修测试夹具和清理契约，不为测试更改业务语义。如果复现证明确有生产生命周期错误，单独记录修改入口与影响后再实施，不能从当前清理栈直接推导生产数据丢失。

本方案不引入新模块、表、API 或依赖；保留真实业务数据读取、backup owner lock、HA typed command/服务端回执、同步 checkpoint/revision/cursor 与 keep_local_only 中断保护。需求 AC-008、AC-020、AC-021 和 REQUIREMENT 第12节仍适用，不降低验收门槛。

### 16.4 验收顺序、异常与停止条件

1. 获得完整失败日志或在 Flutter stable 3.47.7 环境重现全部首错；不得仅依据截断输出批量改代码。
2. T-01/T-02单文件退出成功、所有原断言保留，无 pending timer、未初始化清理或悬挂 gate。验证失败中途退出也能释放资源，不能只测成功路径。无需网络、真实文件选择器或真实 HA 设备。
3. 相关 Widget/调度/备份/会话回归及 `flutter analyze` 全部成功，再运行现有 `flutter test --reporter expanded`；全套应在既有10分钟门限内正常结束，不能关闭计时器断言、跳过失败测试或增加全局 ignore。
4. 同一修复提交的 CI 要实际完成 Android debug、iOS unsigned、后端验证；正式交付再检查 APK/AAB、SHA256、Compose/env 附件及双架构镜像的实际产出。iOS/backend 的当前成功仅属于 `c304100`。
5. 设计交付后停止；本轮运行验证为 NOT_EXECUTED，本机 PATH 无 Flutter/Dart/Go，不安装依赖。需要用户明确进入实施阶段后才改测试/源码。完整日志或可复现 SDK 环境是验收依赖，不是产品需求变更；D-01～08不在本次决定范围。

AI_CONTEXT 更新建议：长期验证门禁无需变化；本次按 SHA/run 的进度记入 VALIDATION。只有修复验证后再补对应证据索引，不把单次 iOS/backend 通过写成 App/NAS 全部已验收。


### 16.5 2026-10-10 实施补充：用户授权修复，待 Flutter 验证

用户明确要求“修复问题”后实施 T-01/T-02 的最小测试夹具修改；16.1～16.4 的“未实施”保留为先前设计阶段记录，不作为当前修改状态。

- 备份锁测试在 suite 入口调用现有 `FilePickerIO.registerWith()`，再保存/替换 FilePicker.platform。核对 file_picker 8.3.7 发布源码确认 platform 是 late 静态实例，Widget 测试未注册时直接读取会抛错；registerWith 仅安装已有 method-channel 实例，不执行真实文件选择。原实例和临时目录按实际初始化状态清理，避免 setUp 失败后 tearDown 再抛未初始化错误。
- 首页/家居 Widget 测试统一调用 `_unmountHome`：卸载后有界 pump 处理 Drift 的零时长流清理任务；在辅助入口注册失败路径清理，按逆序先卸载消费者，再在 runAsync 的真实异步区域等待数据库关闭。新增重复卸载清理回归，保留所有原测试名称与断言，不替换真实回执和权限检查。
- 未改 lib、业务语义、数据库定义、UI、依赖、后端、部署资产或 CI。T-03 其他失败/整套超时仍待完整日志或同 SDK 复现，不能以这些改动宣称全套已修复。
- 本地轻量检查实际通过，运行证据见 VALIDATION。本机无可用 Flutter/Dart；.dart_tool 仅残留已不存在的临时 SDK/cache 路径，不代表工具可执行。Flutter analyze、单文件/全套 tests、Android/iOS 和发布均 NOT_EXECUTED；未提交、推送、重跑或发布。


### 16.6 run #29 补充修复与验证依赖

本地/远端 `d18f87d` 已包含16.5，但run #29测试仍失败。新增证据指向认证测试http.Response中文默认Latin1编码，以及slow-pull周期timer和App卸载的Drift清理timer；本轮仅修对应三份测试夹具并增加UTF-8往返回归，保留生产业务逻辑和CI门禁。认证gate超时先消除响应构造异常，未证明另有生产死锁；备份锁第一用例的停止位置尚需运行复现。

临时官方Flutter3.47.7已可用，但enforce-lockfile失败，现有配置与锁文件缺少7项依赖。普通pub get会按现有约束解析缺项并写锁文件，必须先取得明确依赖变更许可；当前不通过间接配置修改绕过该限制。验证细节见VALIDATION，未达到全套Actions恢复条件。
