# App / Docker 加强任务拆分与批次交接（2026-10-07）

## 范围与状态

用户已要求按审查结果拆分任务开始执行。本批采用主线程 + 三个并行实现任务，写范围互不重叠；保护原有未提交改动，不提交、不推送、不部署、不安装工具。

**第一批代码与测试源码已落盘，轻量检查通过；Flutter/Go/容器/真机验收未执行。不是全部加强事项已完成，也不是生产可用结论。**

本批不改变业务数据库、库存数量权威策略、同步冲突结算、日期规则或受保护页面布局；不新增依赖。大范围工作区隔离、首连迁移、灾备历史代次等另列任务，禁止直接清库或降低既有同步保护。

## 第一批：独立窄范围修复

### A1 NAS 会话与服务器凭据边界（主线程）

- 凭据增加安全存储的服务器绑定：规范化 API endpoint 的 scheme/host/port/path；域名、端口、协议、反代 path 变化不自动复用凭据。等价 API suffix/default port 规范化后可复用。
- 这只是 endpoint 身份，不是服务器证书固定或服务端稳定实例 UUID；相同 URL 指向被替换实例的灾备问题仍属 B4。
- 旧版没有绑定的信息不能推测其来源，自动恢复保持 signedOut，需要显式重新登录；保留业务数据及尚未覆盖的旧凭据，不自动上传、迁移或清空。
- NAS auth 使用会话代次，登出在首次 await 前失效，登录/恢复/刷新迟到响应不能写回旧会话。刷新在 auth service 层合并，避免 sibling clients 并发刷新。
- 凭据共享 service 串行读/写/删除，server binding 最后写作为提交标记；写入失败或失效的部分凭据不能用于自动恢复。
- controller 对恢复、刷新、家庭/设备请求添加代次保护；切换端点或销毁时 abandon 旧 auth。
- sync transport 捕获原 client 和原会话，不通过动态 controller 指针获取另一服务器 token；provider 返回 null 时不回退缓存 token，重试前重新校验会话。
- API transport 在清 token 后拒绝迟到的认证结果/刷新重试；logout 用捕获 token 发撤销请求，不恢复可用的内存登录态。

主要文件：`lib/application/nas_auth_service.dart`、`lib/services/nas_credentials_service.dart`、`lib/data/nas/nas_api_client.dart`、`lib/data/nas/nas_sync_api.dart`、`lib/presentation/controllers/nas_account_controller.dart`。

新增测试：`test/application/nas_auth_service_test.dart`、`test/presentation/nas_account_session_test.dart`。覆盖两个 fake endpoint、不绑定 legacy、等价/不等价 endpoint、单请求 refresh、迟到 refresh/login、写存储期间 logout、保存失败恢复、旧 controller restore 被新地址 restore 替代、缓存 token 不回退及重试会话门禁。测试未运行。

### A2 媒体文件与元数据一致性（并行任务）

- `MediaService` 的所有媒体变更/清理路径共用同 isolate 队列，跨 service 实例覆盖落文件→元数据提交、失败回滚、删除、OCR、草稿转移、reconcile 的全部分支。
- 保留一天草稿保留策略、清理计数和异常反馈；失败释放队列。
- 边界：不是跨进程/跨 isolate 文件锁；压缩/OCR 期间其他媒体操作等待。

主要文件：`lib/application/media_service.dart`；新增 `test/application/media_service_test.dart`。测试采用暂停点、真实临时文件、内存 Drift；未运行。

### A3 通知授权恢复与备份操作锁（并行任务）

- 授权成功、进入已授权设置页、从系统设置回到该页时，按最新库存与真实确认记录重排业务通知。
- 确认流不能用空列表代替，报错不能使用旧缓存；卸载后不发起迟到排程；等待出错可及时释放 busy。
- 本页发送测试通知后的检查不执行业务 cancelAll；后续独立业务更新仍沿用原通知服务行为。
- 备份导入/导出在首个 await 前获取 owner 锁，覆盖 picker、读取、确认、导入/报告、文件写入和系统分享，只有持有者释放。
- 页面卸载后迟到 picker 不弹窗、不导入。原数据库导入事务和合并规则保持不变。
- 边界：两个数据流均长期不出数据也不报错时仍等待；未新加 timeout。

主要文件：`lib/presentation/screens/settings_screen.dart`；新增 `test/presentation/notification_permission_recovery_test.dart`、`test/presentation/backup_operation_lock_test.dart`。测试未运行。

### A4 Docker/后端退出与配置预检（并行任务 + 主线程集成）

- HTTP 服务在主流程等待 Shutdown 完成，再关闭数据库；信号取消后使用独立 10 秒退出 context。
- 监听异常主动进入退出清理；退出失败执行 Close，保留错误及有界监听等待。
- production 拒绝部署示例中已知 JWT/pepper/HA key 占位值，错误不返回密钥原文；合法密钥原字节及原长度规则不变。
- Compose 后端设置 `stop_grace_period: 15s`，与 10 秒应用退出预算留出余量。不改端口绑定、共享权限或持久数据。

主要文件：`backend/cmd/momo-backend/main.go`、新增 `http_lifecycle.go` / `http_lifecycle_test.go`、`backend/internal/platform/config.go`、新增 `config_test.go`、`deploy/nas/docker-compose.yaml`。Go/容器测试未运行。

## 后续任务与依赖（第二批前基线；当前进展见后文）

| ID | 范围 | 依赖/决策边界 | 验收重点 |
| --- | --- | --- | --- |
| B0 | 已有权威库存/冲突修复 + 本批运行验收 | 有 SDK 的 CI/环境；真实 PG16 opt-in 测试不得连生产 | 新旧测试/analyze/vet/build、双设备回归、SIGTERM 在途写、原生权限/picker/分享 |
| B1 | 明确本地工作区归属、切换保护 | 建议短期单设备单工作区；已有业务数据归属/迁移/回滚方案先确认 | A/B 家庭和 A/B NAS 数据不混用，离线意图保留，不登出清库 |
| B2 | 首次单机数据接 NAS 的迁移计划 | B1；使用已有 UUID，禁止默认上传所有残留数据 | 预览/重复检测/依赖排序/数量命令/幂等/断点/用户取消 |
| B3 | 分类与同步字段往返闭环 | 字段支持矩阵；本地字符串分类→UUID 兼容方案需确认 | 两手机录入→上传→恢复→编辑，未知/仅本机字段显式提示 |
| B4 | 灾备数据历史代次与受保护重初始化 | 必须与 B5 协作；代次不能随旧 dump 回退 | 两手机离线+恢复旧备份+重连；未提交操作审阅重放，不清零绕过保护 |
| B5 | 升级/回退预检、空库恢复、密钥配套备份 | B4；确认 RPO/RTO、密钥保管/新库切换方式 | 新旧镜像/schema 组合、旧 dump→新版、换机及 restore drill |
| B6 | 同步调度/协议兼容/历史恢复 | 保留 scope 静默、原 key 和 cursor 原子性 | 多批队列排空、手动自动 single-flight、不兼容版本提示、历史追加不二次扣量 |
| B7 | 就绪检查、安全部署、资源/可观测性 | 暴露边界、反代、NAS 压测预算依据实环境确定 | 初始化保护、登录限流、schema readiness、轮转/连接池、容量及故障诊断 |
| B8 | 时区契约、完整附件迁移、HA 实机闭环 | 不覆盖已确认 date-only/本机附件边界；涉及范围变化先确认 | 跨日/跨时区、附件归档恢复、真实事件/权限/去重/失败 |

B1～B5 可拆为数据归属/迁移与运维灾备两条设计流，但有耦合的协议和迁移必须统一后才编码。未解决的重要业务决策标 `NEEDS_CONFIRMATION`，不是拿占位设计当已确认实现。

## 本轮验证

实际执行通过：

- `bash scripts/ci/test-prepare-flutter-platforms.sh`
- `bash scripts/release/test-next-version.sh`
- `sh deploy/nas/scripts/self-test.sh`
- CI/release Shell `bash -n` 与 NAS scripts `sh -n`
- Ruby YAML 解析 workflow/Compose，并核对 `stop_grace_period: 15s`
- 330 条非 package/Dart SDK 的 Dart import/export/part 路径存在性
- `git diff --check`

未执行：Flutter/Dart 测试、analyze、格式化、构建；Go 测试/vet/gofmt/构建；Docker、PostgreSQL、NAS/HA、移动真机。原因：本机 PATH 未发现相关工具。轻量检查不证明代码编译或运行通过；没有安装依赖、触发新 CI、commit、push 或部署。


## 第二批：同步闭环与灾备方案（2026-10-07）

**状态：代码和回归测试源码已落盘，轻量检查通过；Flutter/Dart 编译、测试和设备验收未执行。灾备仅完成设计文档，相关功能未实现。** 本批延续中断前写集，采用主线程与三个并行任务，未重置原有工作区。

### C1 前台调度、已提交队列与手动同步

- `syncSchedulerProvider` 是 App 与手动页面共用的稳定调度器；构造不启动，App mount/start 与 unmount/stop 分离，provider disposal 最终释放。engine/provider 重建不产生各自定时器。
- scoped outbox 的已提交请求内容变化以 300ms debounce 唤醒同步；status/claim/retry/receipt 变化及没有 outbox 写入的 remote apply 不构成新请求信号。订阅者各自维护内容基线，重新订阅可发现既有 pending。
- 前台默认约一分钟 best-effort 同步；后台、明确 offline、stop/dispose 取消定时器。未知网络不等于无网；网络 hint 不保证 NAS 可达。不是移动 OS 后台常驻能力。
- 手动 `runNow()` 与自动尝试共享 single-flight，错误返回 UI；可忽略生命周期/连通性 hint，但不绕过 engine backoff。替换会话的迟到报告/错误不用于新会话；同 engine 的后台完成保留报告但不恢复定时器。
- 仅非 skipped 且 `hasMorePending` 才按 250ms 间隔续跑，默认最多追加八轮；之后仍有队列由下一前台周期/外部事件继续。`deferred` 单独不是续跑信号，未结算 conflict/rejected/blocked 继续阻塞。
- 新 engine 的同数据库实例/scope run/bootstrap 用同 isolate 队列串行化；不同 scope 独立。`confirmBootstrap` 不进该队列，使用户可在快照等待期间选择 `keep_local_only`，避免自等待死锁。
- UI 沿用原布局；分批结果显示“尚未完成同步”，冲突显示暂停；旧 engine 的迟到结果不更新新页面会话。用户选择仅本地后不继续 drain，ordinary pull 的迟到 page 不应用或推进 cursor。

主要文件：`lib/application/sync_scheduler.dart`、新增 `sync_execution_coordinator.dart`、`sync_engine.dart`、`lib/data/repositories/sync_outbox_repository.dart`、`lib/presentation/controllers/providers.dart`、`lib/app/momo_box_app.dart`、`lib/presentation/screens/sync_settings_screen.dart`。

测试源码：扩展 `test/application/sync_scheduler_test.dart`、`sync_outbox_repository_test.dart`、`sync_engine_test.dart`、`test/presentation/sync_settings_screen_test.dart`；新增 `test/app/sync_scheduler_wiring_test.dart`。均 NOT_EXECUTED。

### C2 wire 版本检查与传输边界补测

- 新增 `NasSyncVersions` 与 `NasSyncApi.capabilities()`，复用现有 JSON/认证/401 refresh transport，GET `/capabilities` 不旋转 bootstrap checkpoint。
- 已就绪 run、bootstrap 与确认在必要网络操作前检查 wire 1/1；ready run 在 claim/push 前检查，确认还检查已记录的 snapshot contract。缺版本的 legacy state 以原 wire 1/1 处理，不把数据库 migration 0006 当 wire schema 6。
- 初次/刷新 bootstrap response 版本都复核。版本不兼容保留业务、原 pending 操作、key、snapshot 与 pull cursor；不设版本错误 backoff，便于兼容端恢复后重试。若此前 push 已被接受，保留 accepted 回执及 pushAckCursor，不伪装整轮未发生写入。
- 显式获取新的兼容 bootstrap 可以替换旧不兼容的暂存快照，但仍要求用户模式确认，不自动放宽冲突/权威数据保护。
- sync transport 在 clear token/close/session 变化后拒绝迟到成功和 refresh 重试；token provider 空值不回退缓存。旧 refresh 完成不清除新 single-flight。
- 通用 `requestJson` 拒绝配置 API scheme/host/port/path 之外的目标，避免将 bearer 用作跨服务器代理。

主要文件：`lib/data/nas/nas_sync_api.dart`、`nas_api_client.dart`、`lib/domain/models/nas_sync_models.dart`、`lib/application/sync_engine.dart`。新增 `test/data/nas_sync_api_test.dart`、`nas_api_client_test.dart`；既有 auth/account 会话测试与 engine 版本/协调测试需一起执行。

### C3 Docker 灾备设计交付（未编码）

新增 `docs/NAS_RECOVERY_PLAN_2026-10-07.md`。覆盖停旧服务前的 image/schema 兼容预检、独立空库恢复和验证、受控切换及有写入后的回滚限制、加密配套密钥/manifest、不可随旧 dump 回退的 restore epoch、App 保护性重初始化及离线意图审阅。

DR-01～DR-07 全部 NEEDS_CONFIRMATION。建议先采用独立空库恢复、加密配套恢复包、外部耐久 epoch；RPO 24h（可选 6h）、核心 RTO 4h 只是待确认目标，不是实测承诺。本批未修改恢复/升级脚本、协议数据库或部署，未执行恢复演练。

### 第二批验证与仍未解决的边界

- PASSED：平台壳生成回归、版本计算回归、NAS shell 自测、逐文件 Shell 语法、workflow/Compose YAML 解析与 `momo-backend` 15s grace 检查、本地 Dart 引用存在性、`git diff --check`。检查 Compose grace 的初次命令误用服务名 `backend` 失败，按实际 `momo-backend` 修正后通过；未为此修改 Compose。
- NOT_EXECUTED：Flutter/Dart analyze/test/format/build、Go test/vet/gofmt/build、真实 PostgreSQL、Docker/NAS/HA、双设备/前后台与原生流程。本机 PATH 无相应工具，未安装依赖、触发 CI、提交、推送或部署。
- 协调仅同 isolate/同 AppDatabase 对象；不是跨进程锁。停 timer 不撤销已发出的服务端副作用；已接受操作仍记账，App 同一业务事务/完整历史代次保护不能由调度器代替。
- outbox 监听保留整个 scope 的内容基线；大型历史数据集性能待测。B6 只落实调度/兼容/执行协调，历史恢复仍未完成。
- B1/B2/B3 工作区归属、首次接入迁移、分类字段闭环；B4/B5 epoch/灾备实现；B7 readiness/安全部署/资源压测；B8 时区/完整附件/HA 实机闭环仍待后续。不得称全部加强完成或可生产发布。


## 第三批：分页完成语义与健康探测（2026-10-07）

用户继续执行后，主线程复查上一批同步边界，两个并行任务分别实现健康探测限时和只读运维复查。没有新增依赖、schema/migration、部署或改变恢复策略。

### D1 远端分页上限与异常页面保护

- 原 `_pullChanges` 达到一轮 100 页上限后，只返回已拉取数；尚有远端页也被页面显示“同步完成”，且调度器只能依据本地 pending 续跑。本批增加独立 `SyncRunReport.hasMoreRemote`。
- 达到页上限且服务端 `has_more` 为真时，保留已提交 cursor/receipt，不更新整轮 `lastSuccessAt`，UI 提示远端仍有数据/尚未完成；调度器复用原有延迟、八轮预算与前台条件。最终尾页完成后才更新完整成功时间。
- `deferred`/skipped 仍阻止远端续跑，不把冲突当队列耗尽问题；本地 pending 分批续跑行为保持。
- 每页在业务 callback 前核对继续页非空且 cursor 前进、change cursor 不大于 next cursor、页内 cursor 严格递增及 change ID 不重复。异常页面 fail closed，不应用本页或跨过本页游标；之前已提交的安全页面保留。
- 普通 terminal 旧页的既有幂等重放和 cursor 不回退测试保留；此检查不是服务端实例/restore epoch 验证，不能据此保证同 cursor 分叉安全。

主要文件：`lib/application/sync_engine.dart`、`sync_scheduler.dart`、`lib/presentation/screens/sync_settings_screen.dart`。测试扩展：`test/application/sync_engine_test.dart`、`sync_scheduler_test.dart`、`test/presentation/sync_settings_screen_test.dart`。新增边界/异常/回归测试源码，NOT_EXECUTED。

### D2 Docker 健康检查的数据库探测预算

- `backend/internal/platform/server.go` 的 GET health 将 DB PingContext 放入继承请求 context 的独立 2 秒预算，成功或失败都释放 context。
- 原 GET、200/503、`status`/`database` JSON 和 405 行为保留，不把数据库错误或连接串返回给客户端。
- Compose 后端 healthcheck 当前 timeout 为 5 秒，2 秒 DB 探测留有余量；未修改 Compose health 配置。
- 新增 `backend/internal/platform/health_test.go`，覆盖 nil/正常/错误、deadline/取消、方法与敏感信息保护，NOT_EXECUTED。
- 边界：需驱动响应 context；不是探测并发限流、连接池预算或 schema readiness。`serve` 只检查 DB 可连接，独立 `migrate`/update 成功门禁不能覆盖直接启动服务的路径。schema readiness 仍未实现，不将健康 200 当完整可用验收。

### D3 运维剩余问题与建议（只读复查）

见 `docs/NAS_OPERATIONS_REVIEW_2026-10-07.md`。与灾备设计共用 NEEDS_CONFIRMATION 边界；本批不执行空库恢复、切换、密钥轮换，也不直接改变失败后重启或服务暴露策略。下一优先项建议为启动/schema 只读预检及隔离环境运行验收，冻结最终备份/空库切换/epoch 等仍按灾备方案确认后实施。

### 第三批实际验证

PASSED：重新运行平台壳脚本回归、版本计算回归、NAS shell 自测、逐文件 bash/sh 语法、workflow/Compose YAML 解析（grace 15s、health timeout 5s）、333 条本地 Dart 引用路径、`git diff --check` 与新健康测试空白检查。

NOT_EXECUTED：Flutter/Dart analyze/test/format/build、Go test/vet/gofmt/build、Docker/真实 PostgreSQL/NAS/HA/手机验证。本机缺相应工具链；未安装依赖、触发 CI、提交、推送、部署。以上通过项不能证明代码编译或运行通过。
