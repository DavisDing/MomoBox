# AI CONTEXT

## 1. 项目概览

- **名称**：MomoBox / 嬷嬷的小箱子
- **类型**：Flutter 手机应用
- **目的**：本地优先管理家庭物品库存、批次效期、消耗和采购。

## 2. 技术栈

- Frontend：Flutter / Dart
- NAS backend：Go 1.22 + PostgreSQL 16；独立 Go module 位于 `backend/`
- NAS deployment：生产 Compose 从公开 GHCR 拉取 `.env` 明确指定的固定版本标签或 digest；本地开发可通过 override 以 `backend/` 为独立 Docker build context；Compose 仅包含 `momo-backend` 与 `postgres`；生产入口为 `deploy/nas/docker-compose.yaml`，开发叠加文件为 `deploy/nas/docker-compose.local-build.yaml`
- State：flutter_riverpod
- Routing：go_router
- Local database：Drift + SQLite
- Local notifications：flutter_local_notifications + timezone
- Barcode / OCR：mobile_scanner + Google ML Kit（本地 OCR）
- Optional AI：用户自配兼容 OpenAI 的 Chat Completions / Responses 服务；API Key 使用系统安全存储
- Platform validation：GitHub Actions；仓库不提交 Flutter 自动生成的 Android/iOS 壳
- Compatibility baseline：最低 Android 16.0（API 36）和 iOS 27.0；平台壳由 CI 脚本生成后注入 Android API 36 minSdk、Android API 37 compile/target SDK 与 iOS 27.0 deployment target。

## 3. 当前结构

```text
lib/
├── app/                       # App、路由、主题
├── application/               # 用例编排与校验
├── core/database/             # Drift 表、数据库和迁移入口
├── data/repositories/         # 库存、采购、设置、备份数据访问
├── domain/                    # 日期、FEFO、提醒规则、领域模型
├── presentation/              # 页面、控制器和组件
└── services/                  # 平台能力适配（本地通知）

test/domain/                  # 可在 Flutter CI 中运行的领域测试
scripts/ci/                   # CI 平台壳生成、补丁回归测试
backend/                      # Go NAS 后端、migration、后端测试和独立 Dockerfile
deploy/nas/                   # GHCR 生产 Compose、本地构建 override、环境变量示例、备份恢复更新脚本
docs/nas/                     # NAS 领域、API、安全和部署契约
```

## 4. 长期架构

```text
Presentation (首页 / 库存 / AI中央助手 / 家居 / 我的)
  ↓
Application / Use Cases (库存管理 / 采买流 / HA设备适配 / 联动规则引擎 / AI意图调度)
  ↓
Domain rules (FEFO / 效期计算 / 耗材配方 / 幂等去重 / 状态指纹)
  ↓
Repositories & External Connectors
  ├─ Drift / SQLite (本地数据源，离线优先)
  ├─ NAS Sync Client (PostgreSQL 增量同步，可选增强)
  └─ Home Assistant Connector (NAS 侧托管令牌，局域网控制，可选增强)
```

单机模式不依赖 NAS、账号、网络或 HA。NAS 同步与 Home Assistant 控制作为独立可选模块实现，不能破坏本地数据源和离线基础操作。Home Assistant 管理 Token 只在 NAS 后端加密保存；家庭成员控制必须经过实体权限与 typed command 白名单。AI/Ollama 仍由 Flutter 直连用户配置的服务，NAS 不内置 Ollama，也不提供 AI Proxy。

## 5. 已确认业务规则

- 库存单位为整数“件”；
- 数量和低库存阈值必须大于 0；
- 到期日当天仍有效，次日过期；
- 到期日期可以为空；无效期批次不进入效期提醒，但参与库存、搜索、消耗和采购；
- 保质期按月使用日历加月，月末超出日期取目标月最后一天；
- FEFO 只消耗未过期可用批次，无足够库存时拒绝操作；用户也可输入正整数并指定一个未过期、未报废且库存充足的批次消耗；批次补充也支持正整数输入，报废须在界面二次确认；
- 入库时同条码或无条码精确特征只生成相似商品候选；必须由用户确认合并，或选择新建独立商品，不能静默归并；
- 临期提醒默认窗口为 30 天；NAS 策略按商品 → 家庭 → 默认解析，显式 7 天等合法值保留，不能被新默认覆盖。`enabled=false` 只关闭该策略下的提醒候选、摘要和通知，不改变库存数量、到期事实、FEFO 可用性或低库存事实；开封后临期提醒暂不支持，非空 `opened_warning_days` 显式拒绝。
- NAS 同步模式下，已确认服务端库存为权威；只有整个 scope 无 pending/in-flight/blocked/rejected、outbox conflict 及 open/deferred 冲突时，才应用权威快照数量与 serverVersion。单机/离线操作仍以本地数据库记录并入 outbox，不能由远端快照静默覆盖未解决的本地操作。
- 本地提醒在 App 启动和库存变化后重算，使用稳定 ID 去重；提醒页支持单条/批量标记已处理，确认记录独立持久化在 `reminder_acknowledgments` 表，并通过 `reminder_key + fingerprint` 过滤，不能把库存或采购动作自动当作已处理；低库存恢复到阈值以上时清除旧确认，再次跌破阈值生成新的提醒周期；
- JSON 导入默认不覆盖已有主键记录；导入前验证备份头、版本、必需数据段、必填字段、字段类型和数量约束，格式错误不应写入部分数据；
- 扫码、OCR 和 AI 已纳入当前单机版本的辅助能力，但均不得成为库存核心流程的硬依赖；相机、图片、网络、外部条码 API 或 AI 不可用时，用户仍可手动完成操作。
- 条码查询结果只可经用户确认填入入库草稿；本地 OCR 图片和文本默认留在本机。发送 AI 前必须显示确认说明，只发送 OCR 文本而不发送原图；AI 草稿不可自动入库。
- AI 库存问答仅在用户自行配置服务后可用；调用时会发送问题、近期对话和本地库存/批次快照至该服务，不包含原图。它不应被用于医疗诊断、用法或剂量建议。
- 嬷嬷/哆啦A梦主题当前仅用于本人本地使用和私有设备安装验证；未来公开发布、上架、商用或第三方分发前，必须重新完成资源授权/合规审查。

## 6. 当前实现状态

已实现、验证待执行：商品/批次、库存列表和筛选、默认 FEFO 与指定批次消耗、自定义数量补充、报废二次确认、采购清单、历史、日期计算、主题、JSON 备份、本地提醒调度计划、提醒单条/批量确认及其备份恢复；实时相机/拍照/相册条码识别、可选外部条码查询与缓存、商品和说明书图片、本地 OCR、用户自配 AI 的 OCR 草稿解析、库存问答和本地用量记录。

交互与维护规则：Android 系统返回优先关闭弹窗/返回子页，其他一级页回首页；首页首次返回提示“再按一次退出软件”，2 秒内再次返回才退出。一键清理须确认，仅清理条码缓存、AI 用量日志和无用图片；保留业务数据、服务配置、备份、在用图片及 1 天内的临时入库图片。统一工作流的发布包节点将相同的版本/构建号同时注入原生包和“关于”页；默认分支每次推送递增 patch 版本，并发推送使用运行序号避免标签冲突，重跑同一提交复用已有标签；本地自定义版本的编译参数见 README。

NAS 阶段已实现 Go 后端基础能力：家庭账号与成员、同步设备、增量同步、库存命令、PostgreSQL migration、Home Assistant 外部连接/发现/实体权限/typed control，以及独立 Dockerfile、双服务 Compose、PostgreSQL 备份恢复与安全更新脚本。GitHub Actions 会在默认分支后端变更通过 Go 测试、vet 和双架构 Buildx 构建后发布公开 GHCR `latest`/`sha-<commit>` 镜像，并在正式产品 Release 发布 `vX.Y.Z` 镜像；NAS 生产部署必须在 `.env` 中固定到版本标签、`sha-<commit>` 或 digest，不使用 `latest` 作为默认部署值；首次发布后仍需在 GitHub Packages 将该包设为 Public。**历史基线记录（superseded，非 2026-10-07 工作区验收）**：此前记录 Go 测试、vet、Linux 二进制构建和静态契约检查通过；因本机无 Docker/PostgreSQL 客户端，镜像构建、Compose 启动、真实 migration/备份恢复、HA 实机联调及 Flutter 端到端联调仍为 `NOT_EXECUTED`。

说明书外部搜索和基于本地 OCR 片段的问答已接入商品详情页；7/30/90 天统计服务与图表页面、采购建议基础、远端冲突 API 与最小解决 UI 已落地。社区共享数据仍未实现；snapshot 跨实体非全事务是 2026-09-27 基线，本批次原子写入改动见下方 2026-10-03 更新。部分实体同步与真实 NAS/HA/端到端联调仍需后续完成或验证。

## 7. 开发规则

- 先读取 docs 和当前代码，再修改；
- 小范围修改，保护已确认 UI；
- Controller 不堆业务，业务规则放 Application/Domain；
- 修改数据库结构必须增加 schemaVersion 和迁移；
- 不把 Mock 当真实能力，不伪造测试结果；
- 本机没有 Flutter 时不得声称已通过 analyze/test/build；应标记 `NOT_EXECUTED`，交给 GitHub Actions 验证。

## 8. 验证基线

GitHub Actions 使用单一 `.github/workflows/pipeline.yml` 链路，并执行：

1. 生成 Android/iOS 平台壳；
   - 注入 Android API 36（minSdk）、Android API 37（compileSdk/targetSdk）和 iOS 27.0 deployment target；
2. 安装 Android 17 SDK platform，并在 iOS runner 上确认 iOS 27 SDK 可用；运行平台壳补丁回归测试，并注入通知权限、重启恢复 receiver、flutter_local_notifications Java 8 desugaring、通知图标保留和 iOS 通知 delegate；
3. `flutter pub get`；
4. Drift `build_runner`；
5. `flutter analyze`；
6. `flutter test`；
7. Android debug build；
8. Flutter/iOS/后端验证全部通过后，发布包 job 才构建 APK/AAB 和 SHA256；最终 publish job 再推送 GHCR 镜像并创建或更新 GitHub Release。

本地安装验证以 GitHub Release 的 Android APK 为准，重点检查首次启动、入库、条码识别与失败回退、图片/本地 OCR、AI 发送确认与草稿确认、日期计算、消耗、提醒权限、采购勾选入库和备份恢复。

## 9. AI_CONTEXT Update Proposal

2026-09-20：NAS 后端已进入实现状态；确认 Go/PostgreSQL、`backend/` 独立 Docker 构建上下文、双服务 Compose、外部 Home Assistant typed control，以及“不内置 Ollama、不提供 AI Proxy”的长期边界。Docker/数据库/HA 实机验证尚未执行。后续只有技术栈、长期架构、核心业务决策或验证基线发生变化时才更新本文件。

2026-09-22 更新：GitHub Actions 已合并为单一链路 `prepare → Flutter/iOS/后端验证 → 发布包构建 → publish`；默认分支每次推送都会创建或更新 GitHub Release，PR/其他分支只验证；验证或打包失败会阻止发布。

2026-09-25 更新：AI 会话改为应用级状态并持久化至现有设置表，支持关闭弹窗后记录在途回复及重启恢复。AI 库存建议默认只读，可在模型配置页授权消耗/补充/报废，逐次确认后复用真实库存服务；不支持任意模型工具或自动执行。默认 AI 超时为 60 秒；配置新增独立可用性测试；用量明细支持分页（日志仍最多 500 条）。首页已合并为一个入库入口和右侧三行服务状态。NAS 认证、家庭/设备、同步网络层、Flutter 账号状态、同步业务适配/Provider 组装、HA 客户端 Repository 和 HA 页面真实接入已实现；本地业务写入与 outbox 原子组合、自动同步调度、同步设置/冲突最小 UI 已落地，网络状态监听、恢复 debounce 与自动重试调度已接入；远端冲突解决闭环及真实环境联调仍未完成。在真实请求联调前不得把页面显示为在线或把命令显示为已执行。

2026-09-26 更新：同步相关 Flutter 最小真实入口已落地，但仍处于未验证状态。`localWorkspaceIdProvider` 使用现有本地设置表中的 `sync_local_workspace_id` 持久化稳定的 local workspace ID；首次缺失时生成一次，后续启动复用，并由 `syncEngineProvider` 传入同步引擎，不能在每次同步时临时生成。同步状态、bootstrap 状态、outbox 与 open conflict 记录由现有本地数据库/repository 保存，冲突记录写入包含去重保护。

同步设置入口已从设置页打开 `SyncSettingsScreen`，可展示同步范围、本地 workspace ID、bootstrap/同步状态、最近成功与错误，并提供手动同步。首次连接区会读取服务端返回的 bootstrap 结果和可选模式（加入并合并、创建新的家庭数据、仅保留本地数据等），用户明确选择后才推进对应状态；bootstrap snapshot 会暂存并在后续同步前应用，确认本身不伪装成已完成的数据合并。冲突区同时读取本地 open conflicts 和远端 open conflicts；“保留远端”以及普通实体的“保留本地”先调用远端 resolution API，只有服务端接受后才更新本地记录。库存与 Home Assistant 冲突不伪造普通 `manual_merge`/`keep_local`。远端失败时本地冲突保持不变。此段描述的是 2026-09-26 的基线，当前状态以 2026-09-27 更新为准。

2026-09-27 更新：按确认范围完成前四阶段主要代码接入。远端冲突最小解决 UI 已接入 NAS resolution API；普通实体支持 keep_local，库存与 Home Assistant 冲突不伪造普通 manual_merge/keep_local；bootstrap snapshot 暂存、延迟冲突游标、outbox 依赖变体、7/30/90 天统计图表、采购建议基础和 Home Assistant 耗材联动基础已补齐。社区共享数据仍未实现；本轮测试、构建、验收、Docker、PostgreSQL、NAS/HA 实机及端到端联调均跳过。

自动调度目前覆盖 App 启动、回到前台、同步引擎/provider 可用以及网络恢复时的 best-effort 触发，并合并并发请求；网络恢复使用开源 `connectivity_plus` 监听、去重和 debounce，`onNetworkAvailable()` 保留为手动/兼容触发入口。当前工作区未运行 Flutter 测试、`flutter analyze`、构建或真实 NAS/HA/端到端联调，因此不得把同步、bootstrap、冲突处理或在线状态标记为已验证成功。


2026-10-03 更新（代码已加强，未通过本批次 CI/真机验收）：快照按固定实体依赖顺序预校验，具体业务适配器将业务写入和 pending bootstrap 完成标记在同一 Drift transaction 提交；Repository 必须共用数据库。分类接收侧映射到本地名称，低库存阈值通过家庭作用域的 `reminder_sync_policy:*` 覆盖层被库存及提醒消费；绑定使用 `sync_category_binding:*`。**历史实现说明（superseded，2026-10-07）**：当时无法映射的七天/禁用/开封提醒与分类颜色/排序显式拒绝，已有批次不使用 snapshot 权威覆盖数量；七天/禁用策略和数量收敛现按已批准方案接入，开封提醒仍不支持。消费历史协议和出站分类映射仍未补齐。

JSON 为核心数据备份，导入/导出过滤设备身份、NAS/HA绑定、凭据与同步派生设置，保留 v1–v3 兼容及目标设备已有状态，附可选 coverage；图片/说明书/OCR不包含在其中。首页与家居既有电源入口复用 typed turn_on/turn_off，按当前角色和真实设备 capability/state 校验，回执前不翻转；场景/脚本仍未接入。新增调度、同步、备份和HA测试未在本机执行；详细验证及待办见 `docs/IMPLEMENTATION_BATCH_2026-10-03.md`。


2026-10-06 可靠性续修（代码状态，运行验收未完成）：库存命令逐批使用现有权威数量/版本，整条业务写入与 receipt/安全游标原子提交，保留 blocked/pending 冲突保护；提醒替换先处理 tombstone。启动网络查询不覆盖较新网络事件。核心 JSON 保留可选业务删除标记，避免空库恢复复活软删除记录；加强认证/签名 URL 净化，保持 v1–v3 兼容。HA member 不调用管理测试，以新鲜匹配实体状态确认可用性；既有控制弹窗补失败反馈和设备消失处理，零亮度不越界。无新增依赖或 schema，页面布局/主题未重设计。**历史待确认状态（superseded，2026-10-07）**：当时已有库存快照数量/版本推进和七天/三十天提醒差异待确认；现已批准，不再待确认，但不能称完整同步。本地生成文件需由既有 CI 的 build_runner 更新，Flutter/Go/真实环境仍未验收。详情见 `docs/RELIABILITY_REVIEW_2026-10-06.md`。


2026-10-07 长期事实更新（代码已落盘并完成源码复核，测试/验收未执行；决策详情见 `docs/IMPLEMENTATION_DECISIONS_2026-10-07.md`）：

- 提醒策略复用 `app_settings` 的 `reminder_sync_policy:<scope>:<entity>`，商品策略优先于家庭策略；可空低库存阈值逐级回退到家庭阈值/本地商品值。策略删除恢复继承，家庭之间隔离。规则、候选和通知共用有效策略，通知正文使用实际窗口；不新增本地 Drift schema、依赖或设置编辑 UI。
- 库存 snapshot 的 quantity/version 必须同事务收敛；相同 serverVersion 的权威快照可修正数量，旧版本不得回退。scope 静默条件在预检、事务内和完成前复检；业务数据、完成标记与安全游标原子提交。推送前持久化 `refresh_required`，推送后重新 fetch 并确认新快照 checkpoint，不能回用推送前快照。网络/回执未知结果复用原 operationID/changeId/idempotency key 重试。
- bootstrap 确认回执除 accepted/nextAction/checkpoint 匹配外，远端同步模式还要求 `serverCursor >= snapshotCursor`；invalid/rejected receipt 不抬高 `pushAckCursor`。写入 `refresh_required` 前及 fetch 返回后的事务均比较原 pending/checkpoint 与 mode，用户重选后不覆盖；手动 bootstrap 在刷新必需但响应缺少 snapshot 时显式失败，保留 pending/刷新标记，不能借缺失 snapshot 清除刷新要求。相关回归用例源码已补充，测试未执行。
- checkpoint 最终设计口径：相同 cursor 复用有效 token；cursor 改变生成新 token、清除旧确认并重新确认。最新后端源码已见该分支；不等于真实数据库验证通过。bootstrap 业务行和 cursor 使用同一 repeatable-read 快照，设备/checkpoint 锁用于协调 refresh 与确认。
- 批次状态与网络竞态保护：`discarded` 映射 `isDiscarded=true`，`active/used_up/expired` 不映射为报废；`used_up/discarded` 必须零 quantity；`expired` 的过期性按真实 expiryDate 判定，不伪造日期；未知状态或冲突字段 fail closed。refresh 网络返回后必须核对原 pending/checkpoint 与当前用户选择，不能覆盖新选择的 `keep_local_only`。代码已落盘并完成源码复核，回归测试/验收未执行，不作为已通过事实。
- NAS migration `0005_reminder_defaults_and_cursor_order.sql` 只将新提醒默认改为 30，不更新旧记录（包括已有 7）。`change_log` 使用全局 `BEFORE INSERT FOR EACH STATEMENT` 事务 advisory lock，在 identity cursor 分配前串行化并持锁至提交/回滚，sequence 为 `CACHE 1`。跨家庭写入也会竞争，吞吐/等待和部署窗口必须实测；部署、备份与补偿回滚约束见决策记录，不删除或修改已应用 migration 的 checksum。
- CI 后端 job 已配置 PostgreSQL 16 service 和 `MOMO_TEST_DATABASE_URL`，执行 `go test -count=1 ./...`、`go vet ./...`。真实 PG 回归为显式 URL opt-in，未设置会 skip；SQL 文本契约与模拟事务测试不能替代真实并发验证。当前工作区的该 CI/真实 PG 测试尚未运行。
- 本轮提醒/库存补修的 UI 范围仅首页及提醒详情两处标题改为“临期提醒”和通知正文；其余既有未提交 HA/UI 改动不归入这两项决策的 UI 变更。消费历史恢复、出站分类 UUID 创建/映射、旧分类升级兼容、HA scene/script 与联动事件闭环仍未完成。
- 2026-10-07 本机缺 Flutter、Dart、Go、gofmt、Docker、psql；本轮代码未验收，不声称测试通过或生产可用。2026-10-07 已执行的脚本/YAML/空白与 326 条非 package Dart 目标存在性检查已记入 `docs/VALIDATION.md`，这些不是代码验收；326 与历史 508 的扫描口径分开，历史成功不覆盖当前工作区。后续代码/CI/实机结果须依据实际执行补充。


2026-10-07 review P1 续修（代码已落盘，Flutter/Go/PG 未验收）：
- NAS restock 维护累计 initial_quantity；新增 0006 非删除批次下界修复迁移（原 initial/当前 quantity/同家庭已记录正 restock 总量取最大），版本与完整 change_log 同事务写入，不放宽客户端 initial 校验、不猜缺失历史、不改旧迁移。部署前须备份、维护窗口与真实 PG 验证；越界 fail closed，补偿不能降低已修复值。
- NAS accepted 冲突回执通过 `settleOutboxConflict` 原子保存结算证据及 scope 刷新 revision；原 outbox/key/失败审计保留，不能 requeue 原幂等键，也不伪装原命令成功。仅有效已结算条目退出 scope/dependency blocker，未解决失败条目继续保护。
- 已完成 bootstrap 无 pending 的冲突也强制 fresh fetch + checkpoint confirm，精确 revision 与业务/cursor 同事务清理，offline/restart/竞态保留刷新。keep_local_only 不自动启用，缺已确认 mode 的旧状态需明确选择。scope 静默权威 snapshot 可修复商品/采购同版本乐观值和批次 tombstone，普通增量/旧版本保护不变。
- 无新增依赖、本地 Drift schema 或界面重设计；新增 PG/Flutter 回归仅源码，未执行，详见决策记录第 8 节和 VALIDATION。
- 已解决远端冲突的本地失败恢复使用现有 GET conflict 验证原动作，不再次 mutation；兼容 legacy 本地已关闭/outbox 未结算。原页补恢复入口与反馈，不重设计布局。open/resolved 各最近 200 条限制保留，早于此的 resolved 回执重启后未必自动匹配，仍保守阻塞，不宣称完整历史恢复。

2026-10-07 App/NAS 安全边界补充（代码已落盘，运行未验收）：NAS 凭据自动恢复只接受安全存储内与规范化 API endpoint 相匹配的 server binding；旧版无 binding 需显式重新登录，不据配置推测来源、不清业务库。Auth/controller/transport 采用会话代次阻止登出、切换 endpoint 或销毁后的迟到响应接受；endpoint 绑定不是服务端实例 UUID，业务工作区隔离及灾备历史代次仍未实现。媒体写/清理通过同 isolate 的共享队列协调；Compose 后端退出宽限为15秒，源码等待最多10秒的 HTTP graceful shutdown，并在 production 拒绝已知密钥占位值。具体范围与未验收边界见 `docs/APP_NAS_HARDENING_2026-10-07.md`，不可当作 Flutter/Go/容器或实机通过记录。


2026-10-07 同步调度/兼容边界补充（源码落盘，运行未验收）：App 与同步设置页共用被动构造的 `syncSchedulerProvider`，App mount/start、unmount/stop；scoped 已提交 pending 请求内容 debounce、前台约一分钟 best-effort 同步、明确 `hasMorePending` 的八轮有界续跑，不以 conflict/deferred 触发忙循环。engine 的同数据库实例/scope run/bootstrap 同 isolate 串行化，确认保留中断快照的能力。NAS capabilities 与 bootstrap 按 wire schema/protocol 1/1 检查；PostgreSQL migration 0006 不等于 wire schema 6。旧会话迟到结果及 keep_local_only 后迟到 pull 均受保护；没有跨进程锁或后台常驻保证。无业务 schema/migration、依赖或页面布局变更。灾备方案位于 `docs/NAS_RECOVERY_PLAN_2026-10-07.md`，全部关键方案仍 NEEDS_CONFIRMATION，功能未实现/演练未执行。批次边界与检查见 `docs/APP_NAS_HARDENING_2026-10-07.md` 和 `docs/VALIDATION.md`。


2026-10-07 分页/健康边界补充（源码实现，未运行验收）：同步报告增加远端页剩余标志 `hasMoreRemote`，100 页单轮上限后复用有界前台续跑，冲突不自动续跑，尾页前不记整轮成功；异常页在本页业务写入前检查 cursor/排序/重复 ID，既有安全 cursor 和 receipt 保留。GET health DB PingContext 增加继承请求 context 的独立 2 秒预算，JSON/200/503 契约保持；仍只代表 DB connectivity，不验证 migration/schema。直接 `serve` 启动没有迁移 readiness 门禁，现有 update 的 migration 成功检查不能覆盖该路径。详情与未验收状态见 hardening/validation 及 `docs/NAS_OPERATIONS_REVIEW_2026-10-07.md`，不改变此前灾备待确认边界。
