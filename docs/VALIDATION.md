# 验证基线

## 原则

长期工具链与本次临时SDK验证分开记录。2026-11-13本机使用已有隔离临时Flutter/Dart和Go工具链执行静态检查与测试；这些结果不作为Android/iOS构建、Release或NAS/设备验收。正式安装验收仍使用对应提交的发布制品。

## CI 与发布链路验证

`.github/workflows/pipeline.yml` 是唯一的 Actions Workflow，Pull Request、分支推送和手动触发均进入同一次运行：

1. `prepare`：运行版本计算与平台壳脚本回归测试，计算发布版本并检测后端变更；
2. 并行验证：
   - `flutter-verify` 使用 Flutter stable，安装 Android 17 SDK platform，生成平台壳和 Drift 文件，执行 `flutter analyze`、`flutter test` 与 Android debug build；
   - `ios-verify` 使用 `runs-on: xcode-27`，确认 iOS 27 SDK 可用，生成平台壳和 Drift 文件并执行 iOS unsigned build；
   - `backend-verify` 使用 Go 1.22.8；2026-10-07 落盘配置新增 PostgreSQL 16 service 和 `MOMO_TEST_DATABASE_URL`，执行 `go test -count=1 ./...` 和 `go vet ./...`（本轮尚未执行，不能将配置视为通过）；
3. `build-release-packages`：通过 `needs` 等待三项验证全部成功；默认分支每次推送都构建版本化 APK/AAB、生成 SHA256SUMS 并上传临时制品；
4. `publish`：通过 `needs` 等待打包节点成功后，才允许推送 GHCR 镜像和创建/更新 GitHub Release。

任一验证或打包节点失败时，后续发布不会执行。PR 和其他分支仍完成完整验证，但不构建正式安装包或创建 GitHub Release；默认分支的每次推送均创建或更新 Release，后端变更还会在同一链路末端发布 `latest`/`sha-*` 镜像。

## 兼容性验收

- Android 最低支持版本：Android 16.0（API 36）；构建以 Android 17 API 37 compile/target SDK 运行，安装验收至少覆盖 Android 16 与 Android 17 各一台设备，且设备不得低于 Android 16。
- iOS 最低支持版本：iOS 27.0；构建日志必须显示 deployment target 为 27.0，设备验收设备不得低于该版本。
- 平台壳配置由 `scripts/ci/prepare-flutter-platforms.sh` 注入；本地脚本回归测试只能证明注入逻辑，不能替代 GitHub Actions 构建或真机验证。

当前状态：`NOT_EXECUTED`（Flutter 构建未在本机执行）；`DEVICE_VALIDATION_PENDING`（Android/iOS 真机尚未验收）。

## 当前NAS必选流程的设备验收（2026-11-13，尚未执行）

1. 配套更新App与后端后，全新安装只能进入NAS连接；首账号注册后自动创建家庭、登记设备并同步进入业务页。注册无效输入不丢失。
2. 第二台手机填写同一NAS、邀请码和自身账号资料即可加入；无效/过期/已用尽邀请码不得产生半成品账号或消耗次数；不能只凭NAS地址读取家庭。
3. 局域网使用、外网恢复、后台再返回、NAS停止/重启；离线可查看原归属缓存且写入明确受阻，恢复后自动同步，今日页滚动位置保持。注销或换NAS/账号不能查看他人缓存。
4. LiteLLM在NAS配置地址/虚拟Key/默认模型；App展示目录并切换允许别名，不出现手机地址/Key输入。测试网关无目录、模型失效、NAS未配置、超时及未知推理结果。
5. HA可不配置；配置后验证家庭权限、发现实体及真实控制回执。离线缓存不能凭旧实体状态发命令。
6. 旧资料升级、含旧AI设置的JSON恢复、中断重试、真实冲突与工作区不匹配；保留原数据和回执，正常接入不需要人工同步选项。
7. 执行下述仍适用的库存/日期/采购/提醒/扫码/主题/布局回归；图片/OCR与AI按NAS路径验收。

## 历史单机安装验收清单（追溯用）

以下清单中的单机启动、手机AI配置及本地OCR已被AC-040～043替代，不能作为当前产品入口要求。

安装 Release APK 后按以下顺序验证：

1. 首次启动无需账号和网络；
2. 手动入库一件有到期日的物品；
3. 验证按天/月填写保质期后到期日正确；
4. 再次录入相同条码，确认先出现相似商品确认；分别验证“合并到已有商品”形成同一商品的第二批次、“新建独立商品”创建独立商品，以及“取消”不写入且保留入库表单；
5. 打开商品详情，确认批次和变动历史可见；
6. 输入多件数量，确认默认按 FEFO 扣减；再指定一个未过期批次消耗，确认仅该批次扣减并写入历史；
7. 输入数量补充一个未报废批次，确认库存和历史更新；报废另一个批次时先检查二次确认提示，再确认库存清零并写入历史；
8. 在库存卡片向左滑动，确认可快速消耗 1 件、补充 1 件或加入采购清单；多个批次补充时确认会先选择目标批次；
9. 添加采购项并勾选已购买，确认入库表单自动打开；
10. 在提醒页对临期、过期或低库存项目点击“加入采购”，确认采购清单新增或合并数量；分别点击单条“标记已处理”和分组“全部标记已处理”，确认提醒从待处理列表消失，消耗/报废/加入采购不会自动标记；重启 App 后确认已处理状态保持；改变阈值或最近效期批次后确认新的 fingerprint 对应提醒重新出现；将低库存恢复到阈值以上再消耗至阈值以下，确认新的低库存提醒周期重新出现；授予通知权限后验证提醒计划可以注册且已处理提醒不再重复调度；
11. 导出 JSON，在清空/新环境导入并检查数据；再导入格式错误、缺少必需数据段、缺少必填字段/字段类型错误或违反数量约束的 JSON，确认显示失败且没有部分数据写入；
12. 验证实时相机扫码、拍照识别和相册图片识别均可将有效条码填入入库草稿；拒绝相机权限、识别不到条码或相机异常时，确认可退出/重试并继续手动填写；
13. 启用可选外部条码接口后，确认候选信息必须经用户选择才填入草稿；关闭接口、网络超时、限流或返回异常时，确认条码仍保留在表单且不会阻塞入库；
14. 添加包装或说明书图片并执行本地 OCR，确认图片和 OCR 文本保存在本机；对 OCR 文本使用 AI 解析时，确认发送前出现只发送文本、不上传原图的提示；确认/取消发送、AI 未配置、超时和非法响应时均不自动写入库存；AI 草稿须可编辑且仍需手动确认入库；
15. 配置 AI 后查询当前库存、临期和补货建议；确认实际发送范围为问题、近期对话和当前库存/批次快照，且不包含原图；未配置或请求失败时，确认提示明确且库存、入库和其他本地功能保持可用；
16. 切换三套主题和系统深色模式；
17. 在 Android 16 与 Android 17 上分别使用手势导航和三键导航：确认状态栏、底部导航、浮动入库按钮及带键盘的入库表单均不被系统栏遮挡；在横屏或至少 840dp 宽窗口确认切换为侧边导航且四个页面都可访问；
18. 在 iOS 27 真机/模拟器上确认状态栏、底部安全区、表单键盘避让和系统深色模式正常；授予/拒绝通知权限后，确认库存核心仍可使用，且已授权时提醒能注册。

## 结果记录规范

- CI 通过：`PASSED`，附 GitHub Actions run 链接；
- CI 失败：`FAILED`，记录失败步骤和日志摘要；
- 尚未执行：`NOT_EXECUTED`；
- 真机未验证：`DEVICE_VALIDATION_PENDING`。

## 当前本地验证记录（2026-09-02）

- `PASSED`：`bash -n scripts/ci/*.sh scripts/release/*.sh`；
- `PASSED`：`scripts/ci/test-prepare-flutter-platforms.sh`；
- `PASSED`：`scripts/release/test-next-version.sh`；
- `PASSED`：GitHub Actions YAML 可由 Ruby Psych 解析，且 `git diff --check` 无空白错误；
- `NOT_EXECUTED`：新增的提醒确认相关测试、`test/domain/batch_consumption_test.dart`、`test/domain/backup_format_test.dart`、`test/data/backup_repository_test.dart`，以及既有 `flutter pub get`、Drift 代码生成、`flutter analyze`、`flutter test`、Android/iOS 构建（本机没有安装 Flutter/Dart）；
- `NOT_EXECUTED`：GitHub Actions 首次运行（变更尚未推送）；
- `DEVICE_VALIDATION_PENDING`：Release APK 真机安装验收。

首次推送后，应将 GitHub Actions run 链接和 APK 安装结果补充到本节，不能把未运行的 CI 或设备结果标记为通过。

## 2026-10-03：并行加强批次验证说明

详细范围和结果见 `docs/IMPLEMENTATION_BATCH_2026-10-03.md`。

- 本批次本地 Shell 语法、平台生成回归、版本计算回归、NAS 脚本自测、Workflow YAML 解析和空白检查已执行通过。
- 历史记录中的“GitHub Actions 首次运行尚未执行”不再描述仓库的当前历史：2026-09-29 的其他提交已有 Flutter/Android/iOS/Go 验证通过，但不能证明本次工作区改动通过。
- 本批次新增 Flutter/Dart 回归、构建及 Go 检查仍为 `NOT_EXECUTED`；本机未发现对应工具链，未安装软件或依赖，也未推送新的 CI。
- 真机与 NAS/HA、多设备真实环境验收仍未执行，不能标为可生产使用。

## 2026-10-06：可靠性续修验证

详见 `docs/RELIABILITY_REVIEW_2026-10-06.md`。本机再次通过逐文件 Shell 语法、平台壳回归、版本计算回归、NAS 脚本参数/help 自测、Workflow YAML 解析和空白检查。Dart 文件引用路径检查仅证明目标文件存在，不等于 analyze。

本机仍无 Flutter/Dart/Go/Docker，新增和既有测试、Drift 生成、构建、真实 PostgreSQL/NAS/HA、多设备与真机验证为 `NOT_EXECUTED`；未推送新 CI，不能引用历史成功运行充当本批次通过。


## 2026-10-07：已批准决策与未验收代码的验证交接

提醒策略和 NAS 库存权威决策已批准（见 REQUIREMENT AC-011～AC-014 和 `docs/IMPLEMENTATION_DECISIONS_2026-10-07.md`），不再待确认。本节区分实际执行记录、源码/配置核对与未执行代码验收。2026-10-06 及以前的 PASSED 保留为历史记录，但作为当前工作区验收证据已 superseded；不能替代本轮结果。下列为 2026-10-07 已执行的轻量检查结果，不等同代码编译或验收。

### 本轮状态

| 验证项 | 状态 | 原因/交接 |
| --- | --- | --- |
| Flutter/Dart analyze、unit/widget/integration、Drift 生成、Android/iOS build | NOT_EXECUTED | 本机缺 Flutter/Dart，禁止用源码阅读或 import 存在性代替类型检查/构建 |
| Go test/vet、gofmt 检查 | NOT_EXECUTED | 本机缺 Go/gofmt；新增 Go 测试尚未运行 |
| `0005` 真实 migration、PG16 并发 cursor/事务回滚回归 | NOT_EXECUTED | 本机缺 Docker/psql；已添加 opt-in 真实测试但尚未运行 |
| 本轮 GitHub Actions | NOT_EXECUTED | PG16 service 与测试 URL 已落盘，未提交/推送；历史 CI 成功无效于本工作区 |
| NAS/HA、多设备、迁移部署/恢复/补偿回滚、吞吐与锁等待 | NOT_EXECUTED | 真实环境与部署窗口尚未验收 |
| Android/iOS 通知、权限与设备回归 | DEVICE_VALIDATION_PENDING | 尚未真机验证 |

以上不是失败/成功结果；当前代码不得称为验收完成或生产可用。下方轻量检查已执行，编译/测试/真实环境验收仍待执行。

### 2026-10-07 实跑记录（轻量检查，非代码验收）

| 命令/检查 | 结果 | 证据边界 |
| --- | --- | --- |
| `scripts/ci/*.sh`、`scripts/release/*.sh` 逐文件 `bash -n` | PASSED | Shell 语法，不是 Flutter/发布构建 |
| `deploy/nas/scripts/*.sh` 逐文件 `sh -n` | PASSED | Shell 语法，不是 NAS 实机部署 |
| `bash scripts/ci/test-prepare-flutter-platforms.sh` | PASSED | 平台壳补丁脚本回归，不是 Android/iOS 编译 |
| `bash scripts/release/test-next-version.sh` | PASSED | 版本计算脚本回归，不是发布执行 |
| `sh deploy/nas/scripts/self-test.sh` | PASSED | 脚本参数/help 自测，不是 Docker/PostgreSQL/NAS 验收 |
| Ruby `YAML.load_file` 读取 `.github/workflows/pipeline.yml` | PASSED | YAML 可解析，不是 Actions run |
| `git diff --check` | PASSED | 当时工作区空白检查，不是代码测试 |
| Python 检查本地 Dart import/export/part 的非 `package:` 目标 | PASSED | **326 条目标全部存在**，只证明文件存在，不等于静态分析、编译或测试 |
| `command -v flutter/dart/go/gofmt/docker/psql`（逐工具） | 工具缺失 | 六项均无输出；相关代码验证 NOT_EXECUTED |

326 是本轮“非 package 本地目标”的统计口径。2026-10-06 的 508 保留为历史检查数字，其扫描/包映射口径可能不同，未重新核实；不将两者混称为同一统计、覆盖量变化或回归结果。两次检查均不能替代 Dart 类型检查。

本轮未自动提交/推送，CI 待跑；未运行的新 Flutter/Go/PG16 回归不得因上述 PASSED 改记通过。后续代码或文档改变时，相关检查仍应针对最终版本重新执行并补记录。

### 配置核实的验证入口（均未在本轮运行）

- 唯一 workflow 为 `.github/workflows/pipeline.yml`：Flutter 先 `flutter pub get`、`dart run build_runner build --delete-conflicting-outputs`，再 `flutter analyze`、`flutter test --reporter expanded` 和既有 Android/iOS 构建。
- 后端工作目录 `backend/`，CI 命令为 `go test -count=1 ./...`、`go vet ./...`；PG16 service 使用一次性测试库，将 URL 放入 `MOMO_TEST_DATABASE_URL`。不得将该 URL 指向生产库；真实测试会创建/清理隔离 schema。
- `backend/internal/store/syncpostgres/cursor_postgres_test.go` 的 `TestPostgresCursorCommitOrderAndReminderMigration` 是 opt-in；未设置 URL 会 `t.Skip`，应记 NOT_EXECUTED，不能记真实 PG 测试通过。文本契约测试/模拟事务测试也不能代替 PG16 双连接并发结果。

### 待验证矩阵（预期，不是通过断言）

| 对应验收 | 正常/边界/异常与回归场景 | 已落盘入口或待补验收 |
| --- | --- | --- |
| AC-005 / AC-011 | 无策略默认30、家庭→商品覆盖、显式7/0保留、删除回退、scope隔离、旧threshold-only兼容；禁用只影响提醒不改变库存/过期/FEFO；窗口指纹与正文一致 | `test/domain/reminder_policy_test.dart`、`test/data/reminder_policy_repository_test.dart`、既有通知测试；真机调度/拒绝权限待验 |
| AC-011 | 非空opened_warning_days（含禁用策略）、非法类型/阈值/天数、重复策略、替换顺序失败时整批回滚 | 提醒 Repository / adapter 测试及端到端待验 |
| AC-012 | 同版本quantity纠偏、旧version不回退；不同实体pending/inFlight/blocked/rejected/conflict及open/deferred阻止scope快照；写入/receipt/cursor失败原子回滚 | `test/data/inventory_authoritative_snapshot_test.dart`、`test/application/sync_business_adapter_test.dart` |
| AC-012 | push→fetch→confirm→apply；maxPush截断、未知结果用原operationID重试、刷新失败/崩溃恢复不消费旧snapshot、并发本地编辑重新阻塞 | `test/application/sync_engine_test.dart`、多设备真实NAS待验 |
| AC-013 | discarded映射、active/used_up/expired非报废、终态quantity=0、expired不伪造expiryDate；未知状态与冲突字段fail closed | 代码与回归用例源码已落盘并完成源码复核，批次/adapter测试待执行 |
| AC-013 | 相同cursor复用有效token并保留已有确认记录、变cursor新token并拒绝旧确认、缺失token、keep_local_only忽略乱token/超前cursor、repeatable-read一致快照；refresh/confirm迟到不得覆盖新pending或keep_local_only | `backend/internal/store/syncpostgres/bootstrap_snapshot_test.go`、引擎回归；真实并发与客户端竞态回归待验 |
| AC-013 | 确认回执serverCursor>=snapshotCursor；invalid/rejected receipt不抬pushAckCursor；写refresh标记前及fetch返回均比较pending/mode；手动bootstrap缺snapshot不能清refresh要求 | `test/application/sync_engine_test.dart`已补回归用例源码并完成源码复核，测试/验收未执行 |
| AC-014 | 0005保留旧7、新默认30；真实双连接持锁至commit/rollback、后写入不提前分配cursor、CACHE1、直接库存与sync路径均覆盖 | `cursor_migration_test.go`（仅契约）和`cursor_postgres_test.go`（真实PG16，未跑） |
| AC-014 | 排空旧连接/缓存后的部署、备份恢复、补偿migration、历史漏读完整重同步、跨家庭吞吐与锁等待/死锁 | 实机专项验收尚未执行；CI隔离schema回归不能替代生产部署演练 |

仍未实现的消费历史恢复、出站分类 UUID 映射/升级兼容与 HA scene/script/联动事件闭环不能被该矩阵勾为通过。本轮新增测试文件存在仅代表测试源码已加入。

## 2026-10-07 — code review 两项 P1 续修验证记录

本节只覆盖 initial_quantity 和 conflict settlement/fresh snapshot 续修，不替代之前未提交工作的验收。源码已改，不等于运行验证通过。

### 已执行通过（轻量检查）

- `for script in scripts/ci/*.sh scripts/release/*.sh; do bash -n "$script"; done`：脚本语法检查通过。
- `for script in deploy/nas/scripts/*.sh; do sh -n "$script"; done`：部署脚本语法检查通过。
- `bash scripts/ci/test-prepare-flutter-platforms.sh`：`PASS: platform preparation regression tests`。
- `bash scripts/release/test-next-version.sh`：`PASS: next-version.sh release calculation tests`。
- `sh deploy/nas/scripts/self-test.sh`：`All shell syntax and help/argument behavior checks passed.`。
- Ruby 标准 YAML 解析 `.github/workflows/pipeline.yml` 通过；不能代替 GitHub Actions 的执行或语义验收。
- Python 扫描 `lib/`、`test/`、`integration_test/` 的非 `package:`/`dart:` import、export、part：329 个目标全部存在；该口径不是历史 508，也不是 Dart 解析/编译。
- `git diff --check`：通过；保留所有已有未提交改动，无 commit/push/deploy。

### 新增/扩展回归源码（NOT_EXECUTED）

- `backend/internal/store/inventorypostgres/initial_quantity_postgres_test.go`：实际 Service/Repository cumulative initial、restock/consume/discard、幂等延迟重放、history/change_log/receipt/commit 失败整体回滚。
- `backend/internal/store/syncpostgres/initial_quantity_migration_test.go`：actual 0006 独立 schema、旧值/当前量/正 restock 下界、家庭隔离、软删除/已有大值保护、完整日志、二次迁移无增量、写入和 COMMIT 故障回滚。fixture 不覆盖完整生产 FK/权限/启动或部署锁等待验收。
- `test/data/inventory_authoritative_snapshot_test.dart`：修复后完整 NAS 行通过严格 initial 校验；旧坏行依然拒绝且不推进版本。
- `test/application/sync_outbox_repository_test.dart`、`test/presentation/sync_settings_screen_test.dart`：NAS 回执匹配、原 outbox/key 审计保留、显式结算、未解决保护、依赖释放、失败反馈与页面生命周期。
- `test/data/conflict_authoritative_snapshot_test.dart`：scope 静默全快照同版本恢复商品/采购乐观值与 tombstone，旧版本/普通增量行为不放宽，失败回滚。
- `test/application/sync_engine_test.dart`：已完成 bootstrap 无 pending/空 pull 仍 fresh fetch+confirm；不重发原命令；offline/restart、confirm 失败、fetch/confirm/application 期间新 revision、keep_local_only 和 legacy 缺 mode、其他未结算 rejected 保护。

### 未执行及发布门槛

`command -v flutter dart go gofmt docker psql` 无输出，本机缺对应工具；未安装新依赖或改变系统环境。Drift 生成、Flutter analyze/test/build、Go test/vet/gofmt、真实 PG16、NAS 双机/离线重连与迁移维护窗口验证均未执行；真实测试源码缺 `MOMO_TEST_DATABASE_URL` 时会 skip，本轮也没有执行这个 skip。CI 配置已有显式一次性 PostgreSQL URL，不代表当前未提交源码已跑 CI。

在具备项目工具链且使用一次性测试数据库的环境，先执行现有 Flutter `build_runner` 生成入口、`flutter analyze`、`flutter test` 及 `backend/` 的 `go test -count=1 ./...`、`go vet ./...`，再验证真实 NAS 冲突解决→fresh checkpoint→数量/元数据收敛、进程退出后的恢复，以及 0006 备份/事务回滚与锁等待。部署及补偿约束见决策记录第 8 节；当前两项 P1 不标记为已验收或生产可用。

续修源码复核补充：已接入 NAS `getConflict()` 回执恢复，覆盖 accepted 后本地写失败、丢回执/已解决错误、原动作不匹配、legacy 本地已关闭但 outbox 未结算。原页面新增“按原动作恢复本地结算”入口，不重设计布局。open/resolved 列表各最近 200 条的既有边界仍保留，更早 resolved 回执重启后可能无法自动匹配；未匹配条目继续阻塞，完整历史分页恢复不在本次范围。另补实际 0006 累计 integer 越界整体回滚、revision 清理失败同事务回滚和 ordinary pull 在途收到 resolution 回归源码，全部 NOT_EXECUTED。

## 2026-10-07：App / Docker 第一批并行加强

任务范围、兼容性与后续拆分见 `docs/APP_NAS_HARDENING_2026-10-07.md`。不覆盖本节以上历史记录或将其视作本批运行验收。

- `PASSED`：本轮重新运行平台壳生成脚本回归、版本计算脚本回归、NAS help/参数脚本自测、逐文件 Shell 语法检查。
- `PASSED`：workflow/Compose YAML 解析，后端 15 秒容器退出宽限与源码 10 秒退出预算静态核对，330 条本地 Dart 引用路径存在性，`git diff --check`。
- `NOT_EXECUTED`：新增 NAS auth/controller 会话、媒体竞态、通知权限恢复、备份入口锁 Flutter 测试，以及 Go HTTP 生命周期/production 配置测试；既有测试/analyze/vet/格式化/构建同样未执行。本机无 Flutter/Dart/Go/gofmt，未安装工具。
- `NOT_EXECUTED` / `DEVICE_VALIDATION_PENDING`：Docker SIGTERM 在途请求、真实 PostgreSQL/NAS/HA、原生通知权限/文件选择/分享及手机生命周期验收；本机无 Docker/PG 客户端，未推送新 CI。
- 代码已落盘与轻量检查通过不等于验收或可生产使用。旧未绑定 NAS endpoint 的凭据需重新登录，业务数据保留；本批无业务 schema/migration、新增依赖或页面布局重设计。


## 2026-10-07：App / Docker 第二批收尾

实施范围见 `docs/APP_NAS_HARDENING_2026-10-07.md` 第二批；不覆盖历史验证记录，也不把此前 CI 当作当前未提交源码通过。

### 实际执行

- PASSED：`bash scripts/ci/test-prepare-flutter-platforms.sh` → `PASS: platform preparation regression tests`。
- PASSED：`bash scripts/release/test-next-version.sh` → `PASS: next-version.sh release calculation tests`。
- PASSED：`sh deploy/nas/scripts/self-test.sh` → `All shell syntax and help/argument behavior checks passed.`。
- PASSED：`scripts/ci/*.sh`、`scripts/release/*.sh` 的 `bash -n` 与 `deploy/nas/scripts/*.sh` 的 `sh -n`。
- PASSED：Ruby 标准 YAML 解析 workflow/Compose；`services.momo-backend.stop_grace_period == 15s`。初次检查误写服务名 `backend` 得到 KeyError，依据现有 Compose 修正检查命令后通过，没有修改被检查配置。
- PASSED：本地 Dart 引用目标存在性及 `git diff --check`；共 333 条目标全部存在；前者不是 Dart 语法/analyzer/编译检查。
- PASSED（文档检查，不是恢复验收）：灾备方案章节/源码引用与 NEEDS_CONFIRMATION 状态保留。

### 新增或扩展测试源码（全部 NOT_EXECUTED）

- scheduler/outbox/App wiring：committed 请求 debounce、status/remote apply 不反馈、每订阅独立基线、手动自动共用 flight、周期 pull、有界 drain、backoff、background/offline/dispose、provider/session 替换和迟到报告/错误。
- engine：版本不兼容 pre-claim 保留操作/key/cursor、capability 失败、bootstrap response/记录版本兼容、post-push 不兼容保留已接受回执与旧快照、同/重建 engine 协调、不同 scope、失败释放、无效 batch limit、keep_local_only 中断 push/pull、未结算 rejected 不续跑。
- sync API/通用 API：有效/畸形 capability、反代 path、401 单次 refresh、失效 session/clear token/close/provider、旧 refresh completion 与新会话隔离、拒绝配置 API 外的 bearer 目标。
- 同步设置页：分批不显示完成、deferred 显示暂停、backoff 反馈；既有冲突回执/本地原子结算测试保留。

### 未执行与剩余门槛

本机 `command -v flutter dart go gofmt docker psql` 无输出；工具链缺失，未安装或修改环境。Flutter/Dart analyze/test/format/build、Go test/vet/gofmt/build、真实 PG/NAS/Docker/HA、设备与灾备演练均 NOT_EXECUTED。当前测试源码尚不能据此认定编译、运行通过。灾备仅完成方案文档；epoch、空库恢复/切换、加密恢复包与 App 意图审阅未实现。

下一验证入口仍为既有 CI 配置的 Drift 生成 → Flutter analyze/test/build、`backend/` Go test/vet/build 与一次性 PG16；再进行 NAS 双机/离线/重连/keep_local_only 和容器 SIGTERM 场景。不得连接生产测试库、清本地数据/cursor 或削弱冲突保护以制造通过。本批无 commit/push/deploy。


## 2026-10-07：App / Docker 第三批复查

### PASSED（本轮实际执行）

- `bash scripts/ci/test-prepare-flutter-platforms.sh`、`bash scripts/release/test-next-version.sh`、`sh deploy/nas/scripts/self-test.sh` 再次通过。
- `scripts/ci/*.sh`、`scripts/release/*.sh` 的 `bash -n`，NAS scripts 的 `sh -n`；workflow/Compose YAML 解析；后端 grace 15s 和容器 health timeout 5s 核对通过。
- 333 条本地 Dart 引用目标存在性；`git diff --check`；新增 health Go 测试空白检查通过。不是语法/编译/测试执行。

### NOT_EXECUTED（新增回归源码）

- engine：101 页跨两轮续拉、完整成功时间只在尾页更新、非前进/空继续页/越界/乱序/重复 ID 在本页写入前拒绝、后续坏页保留此前安全 cursor/receipt、deferred 不续跑。
- scheduler/UI：远端页 remainder 复用有限续跑预算，conflict 不放行，页面不显示已全部完成。
- health：DB nil/可达/失败、独立 2s deadline、更短 request deadline、请求前/中取消、非 GET 与敏感错误保护。

工具链与设备检查仍未执行：PATH 与常见工具目录未找到 Flutter/Dart/Go/gofmt/Docker；没有安装、生成依赖或运行生产数据操作。Go 子任务尝试 test/vet 返回 `go: command not found`。当前健康检查仍只代表 DB connectivity，不能代表 schema readiness；升级脚本 migration 失败不启动与直接 `serve` 缺迁移预检的路径必须分开看。

运维复查仅源码证据与方案，见 `docs/NAS_OPERATIONS_REVIEW_2026-10-07.md`；真实部署/备份/恢复/切换演练均 NOT_EXECUTED。没有 commit/push/deploy。


## 2026-10-08：本地主线合并与旧分支清理

- 本次起点：干净的本地 `main` 为 `1ad1cc8`，远端 `main` 为 `071a030`，双方各有独有提交。先获取主线/标签，并保留本地备份 `backup/main-before-merge-20261008`；不 reset、不 rebase、不强制推送。
- 三个冲突位于 auth service、sync scheduler 和 sync settings。远端对应增量为旧 CI await/nullable promotion/RadioGroup 等修复，源码核对确认新版本地已包含；保留新版会话/调度/原子结算实现，不回退保护。
- 接入绿联 NAS 的 `docker-compose.yaml` / `docker-compose.local-build.yaml` 改名、脚本入口、Release 附件及部署说明。保留本地 `stop_grace_period: 15s`，只更新相应现状/审查文档路径。
- `codex/fix-ci-build` 的文件树与远端已并入主线的 `7028f6e` 完全相同（tree `31cb15d`），但历史不同；计划以不改变当前文件树的历史合并保留其提交，再安全删除旧本地功能分支。其余两个旧分支已是远端主线祖先。
- PASSED（实际执行）：平台准备脚本回归、版本计算脚本回归、NAS shell 自测；全部相关 bash/sh 语法检查；workflow/两个 Compose YAML 解析及 15 秒退出宽限核对；333 条本地 Dart 引用路径；冲突文件新版内容保持；空白/残留冲突检查。
- NOT_EXECUTED：Flutter/Dart analyze/test/format/build、Go test/vet/gofmt/build、容器/真实 PG/NAS/设备。PATH 无相关工具，不安装依赖。轻量检查不证明编译或运行通过。
- 操作范围为本地 merge 和旧分支清理；不自动 push、不部署，不将本地新代码说成已经进入 GitHub 主线。GitHub 上旧功能分支此前已删除，本次以远端实际 refs 复核。


## 2026-10-09：run #26 App 编译阻塞最小修复（已改源码，运行待验证）

### 起点与范围

- 起点HEAD为 `02513dd6018aba9ab45b5d5ebda27f3437b2f3a1`，已有未提交修改仅为DESIGN中的run #26复核记录，已完整保留。
- 历史CI run #26（2026-10-08，ID `37755341512`）的App静态分析/无签名iOS失败，后端/PG/vet通过，测试、Android及Release/镜像发布跳过。它不是本次修复后的验证。
- 用户明确授权修复：修正scheduler参数语法和engine显式nullable guard，五个测试Drift导入的matcher歧义、一个必填时间fixture，以及日志中的13处花括号/7个super参数/1个重复导入。保留原测试断言、同步与冲突安全边界，不改依赖、schema、页面布局、后端、Compose或CI门禁。
- 新增四组同步回归：空值/非法mode × 有/无待推送命令，覆盖无网络业务mutation/快照应用/游标前进以及原请求、幂等key、attempt count保留；测试源码落盘不等于执行通过。

### PASSED（实际执行）

- `bash scripts/ci/test-prepare-flutter-platforms.sh`：平台壳准备脚本回归通过。
- `bash scripts/release/test-next-version.sh`：发布版本计算回归通过。
- `sh deploy/nas/scripts/self-test.sh`：NAS脚本语法与help/参数行为自测通过；不是真实容器备份恢复验证。
- `bash -n`：CI/Release脚本；`sh -n`：NAS全部脚本，通过。
- Ruby YAML解析：workflow及两个Compose，通过；配置本身未改动。
- 332条 `lib/`、`test/` 本地Dart引用目标存在性（排除URI及生成的 `.g.dart`）；针对性签名/guard和matcher导入源码检查通过。不是Dart编译/分析。
- 所有修改测试中的原 `expect/expectLater` 断言行按原顺序保留；未删除测试或排除目录。
- `git diff --check` 通过；diff确认后端、CI、依赖、数据库定义与部署文件未修改。

### NOT_EXECUTED / 后续门禁

- Flutter/Dart SDK在PATH及所检查常见位置不可用：Dart format、`flutter analyze`、新增/相关/全套 `flutter test`、Android debug/release与iOS unsigned构建均未运行。未安装工具或依赖。
- Go/真实PG/容器/NAS/真机验证未在本机执行。历史后端CI通过不能替代新提交验证；本次未改后端也不能证明镜像发布成功。
- 未commit/push、未触发或重跑CI、未生成或发布安装包/镜像。下一步在具备SDK的环境或提交后的同commit CI运行生成Drift、analyze、全套tests及Android/iOS构建，再核对Release/镜像实际产出；新增错误继续定位，不关闭检查。


## 2026-10-10：run #27 剩余静态检查阻塞修复

- 已核实[run #27](https://github.com/DavisDing/MomoBox/actions/runs/37905903196)，main commit `f3ae9f1f18330a2ac41943ec7655e3f2ba5d0676`，2026-10-09 16:35:33～16:45:10（Asia/Shanghai）；本轮开始时本地HEAD一致且工作区干净，包含10月9日全部最小修复。
- [Flutter job](https://github.com/DavisDing/MomoBox/actions/runs/37905903196/job/113739207618) 使用stable 3.47.7，静态分析只报告1项info：`test/application/sync_outbox_repository_test.dart:1:8` 的 `dart:async` 为 `unnecessary_import`，相关元素已由flutter_test导出。`flutter analyze` 退出码1，门禁保持不变。
- run #27实际PASS：Prepare pipeline、iOS unsigned build（Xcode 27）、Backend test/PostgreSQL regression/vet。SKIPPED：Flutter unit tests、Android debug build、Build release packages、Publish image and GitHub Release。iOS通过不是签名安装验收，镜像发布被跳过不是Docker构建报错。
- 本次代码仅删除该重复导入，保留所有测试与断言，不修改业务逻辑、依赖、数据库、页面、后端或CI设置。
- PASSED（本地实际执行）：`git diff --check`；与HEAD逐字比较确认测试文件仅减少一行导入，其余内容完全一致。
- NOT_EXECUTED：本次修改后的Flutter analyze/test/Android/iOS构建及发布；本机PATH仍无Flutter/Dart，未安装工具/依赖。run #27的PASS与FAIL属于修复前commit，不是本次修改后成功证据。
- 未提交、推送或重跑旧CI。后续需验证包含本次一行修复的新commit；先通过analyze及全套tests/Android/iOS，再核对安装包和镜像实际发布，不能承诺后续步骤无新错误。


## 2026-10-10：run #28 测试失败复核（设计阶段，未实施）

- 最新查询返回 run `38010226751`（#28，attempt 1），main SHA `c304100216427c18e771fd86247d2a6fef20a32e`，2026-10-10 08:42:53～08:55:58（Asia/Shanghai）；本地 HEAD 一致、调查开始时工作区干净。上一轮一行导入修复已提交到该 SHA。
- REMOTE PASS：Prepare pipeline、Flutter analyze（No issues found，stable 3.47.7）、iOS unsigned（Xcode 27）、Backend test/PostgreSQL regression/vet。
- REMOTE FAIL：Flutter Unit tests，既有10分钟门限超时；可见进度 `+345 -23`，不是全套终态汇总。SKIPPED：Android debug、正式包构建及发布；无本轮 Android/Docker 打包失败证据。
- 已读首错片段：HA首页 Widget 卸载后 Drift StreamQueryStore 创建零时长清理 FakeTimer，触发 pending timer 断言；备份锁测试 tearDown 报 originalPicker 未初始化。日志中段被连接器截断，其他失败与最终挂起尚未完整归因；不声称两项修复即可全套通过。公开 API 下载返回403，未登录浏览器要求登录；未获取凭证或绕过限制。
- 设计与修改入口见 DESIGN 第16节。仅更新 docs/DESIGN.md 与本记录；不修改业务代码/测试/依赖/CI/数据库/页面/部署配置，不提交推送、不重跑或发布。保护所有原断言与10分钟门禁。
- NOT_EXECUTED：任何新代码修复及其 Flutter analyze/test/build；本机 PATH 无 Flutter/Dart/Go。当前远端PASS仅属于上述SHA；需完整日志/同SDK复现和用户实施授权后继续。


## 2026-10-10：run #28 已定位测试夹具修复（未运行 Flutter）

- 用户授权“修复问题”。修改 `test/presentation/backup_operation_lock_test.dart` 与 `test/presentation/home_ha_quick_actions_test.dart`，保留上一轮文档改动，不改生产源码/CI/依赖/数据库/页面。
- 备份测试显式注册现有 FilePickerIO，解决未注册 late platform 的读取入口；对实际保存的旧 picker 和已创建目录条件清理。核实 file_picker 8.3.7 发布源码的 platform/registerWith/export API，源码仅下载至临时目录用于阅读，未安装依赖。
- HA Widget 测试统一卸载并推进一轮查询流清理，辅助入口的 tearDown 在消费者卸载后用 runAsync 关闭数据库，新增“首页卸载释放查询流，清理可重复执行”。原回执/禁用/权限/错误断言全部保留。
- PASS（实际本地）：平台准备回归、发布版本计算回归、NAS脚本self-test、CI/release/NAS shell语法、workflow及两份Compose YAML解析、332条本地非生成Dart引用路径、原测试名称与expect断言行保留检查、文档围栏、git diff --check。
- NOT_EXECUTED：Flutter format/analyze、两个单文件测试及全套测试、Android/iOS构建和正式发布。PATH无Flutter/Dart/Go，缓存配置所指的 `/private/tmp/momobox-verify-flutter` 与 pub-cache 均已不存在；未安装SDK/依赖，不使用旧缓存记录充当验证。
- 未提交/推送/重跑CI。其他被截断的失败与总超时尚未全部归因；需包含这些修改的新commit验证。先运行两个修改文件，再运行全套测试与现有构建链路；不得放宽10分钟门禁、关闭timer断言或skip用例。


## 2026-10-10：run #29 新失败定位与验证环境准备（仍未完成）

- 最新查询 run `38036063512`（#29，attempt 1），main SHA `d18f87df3b8202488a89e695d38336c40e874949`，2026-10-10 15:54:56～16:07:30（Asia/Shanghai），本地HEAD同SHA且调查开始时干净，已包含run #28夹具修改。
- REMOTE PASS：prepare、Flutter analyze、iOS unsigned、backend/PG/vet。REMOTE FAIL：unit tests；仍10分钟超时。Android debug、release/publish SKIPPED，不能称已打包或镜像错误。
- 新日志显示认证夹具的中文昵称在无Content-Type的http.Response默认Latin1编码时报Invalid argument，引发网络包装异常、gate未触达及后续超时；修复两个响应辅助函数为JSON UTF-8，新增中文往返回归，不删除竞态断言。
- 新日志显示SyncScheduler slow-pull周期测试结束残留1分钟timer，以及App wiring卸载产生Drift零时长清理timer；前者在测试body结束前显式dispose并验证2分钟无新run，后者卸载后追加有界pump，保留原有次数/并发断言。
- 测试日志中段仍截断，已显示13项失败，最后可见备份锁第一条用例随后总超时；不能将当前三文件修复视为全套已恢复。
- 经许可将官方Flutter tag 3.47.7下载/初始化至 `/private/tmp/momobox-actions-flutter`；实际version为Flutter3.47.7、Dart3.13.5，未改系统安装。临时PUB_CACHE仅用于验证。
- `flutter pub get --enforce-lockfile` 实际FAIL：pubspec.lock缺少现有pubspec所需7项依赖（connectivity_plus及其platform interface、nm、url_launcher及android/ios/macos实现）。锁未改写、build_runner尚未执行。后续按CI流程普通pub get解析会修改锁文件，审批拒绝，停止该动作，待用户明确批准；不通过包配置或其他方式绕过。
- PASS：Dart format --output=none语法解析（未写格式，缺失旧flutter_lints路径告警，非analyze证据）、原expect断言行保留、git diff --check。NOT_EXECUTED：本次代码Flutter analyze/test/build，未提交推送/重跑CI。


## 2026-10-10：批准锁文件补齐、测试夹具续修与全套本地验证

### 基线与远端边界
- 修改基于本地HEAD `244174c5da2f2f56528592e9921615091880648c`。本轮结束查询main最新Actions仍为run #30 `38040706118`，2026-10-10 17:14:51～17:27:48（Asia/Shanghai），conclusion=failure；job查询确认unit tests失败、Android debug/release/publish跳过，analyze和iOS unsigned成功，后端job成功。这不是本次未提交修改的验证结果。
- 用户“更新吧”明确批准普通pub get补缺项。临时官方Flutter3.47.7 / Dart3.13.5、独立PUB_CACHE继续用于本地验证；先前“无SDK/未执行”的记录仅属于先前阶段，不覆盖当前实跑证据。未修改系统安装。
- pubspec.lock新增7条，其余原package完整条目和SDK约束逐项不变，pubspec.yaml不变；`flutter pub get --enforce-lockfile` PASS，日志 `/private/tmp/momobox-lock-enforced.log`。新增条目及职责见DESIGN16.7。

### 实际修复与诊断记录
- 9份测试修改；无生产源码、schema、UI、部署或CI改动。修复跨real/fake zone等待、Drift Timer.run清理、中文JSON编码、动态夹具类型和数据库timestamp时区断言；同步页恢复回执卡片重新展开后沿用原断言。
- 首轮完整诊断日志 `/private/tmp/momobox-full-tests-20261010.log` 出现23项失败且不再推进，约3分38秒人工中断；不能当成完整结束或PASS，停机时sink错误为中断产物。中间逐组诊断也曾因初始化等待被人工停止；不隐藏失败，也不修改10分钟CI门限。
- App wiring+备份锁：12项PASS，`/private/tmp/momobox-zone-regression.log`。
- 通知恢复：15项PASS，`/private/tmp/momobox-notification-regression.log`；包含读取失败、迟到错误、卸载后回执和真实排程过滤。
- 同步设置页：17项PASS，`/private/tmp/momobox-sync-ui-regression-final.log`；包含本地结算失败、原动作恢复、回执不匹配及退出页后的持久化。

### 最终本地结果
| 检查 | 结果 | 证据/边界 |
|---|---|---|
| Drift build_runner生成 | PASS | 287 outputs；生成文件忽略，无tracked生成差异 |
| flutter analyze --no-pub | PASS | 零问题，10.5秒；`/private/tmp/momobox-analyze-final-20261010.log` |
| flutter test --no-pub --reporter expanded | PASS | 全套687项，19秒；`/private/tmp/momobox-full-tests-final-20261010.log` |
| TZ=UTC同一全套测试 | PASS | 全套687项，14秒；`/private/tmp/momobox-full-tests-utc-20261010.log` |
| 严格锁文件解析/旧条目比较 | PASS | 新增恰好7项，已有package/SDK约束不变 |
| 原测试名称与expect数量 | PASS | 原用例声明名称保留、断言数量不减少；两个异步辅助路径增加有界完成断言；未skip |
| 平台准备/版本计算/NAS shell self-test | PASS | 实际运行；不代表原生构建或容器运行 |
| git diff --check | PASS | 实际工作区检查 |
| 本次修复Android/iOS构建、Go/PG、Docker/NAS/设备、正式发布 | NOT_EXECUTED | 本地测试不替代包含本次修改的新SHA的CI/原生/实机验收 |

未提交、推送、重跑Actions或发布。下一入口：将修复提交后，在同一SHA核对完整测试、Android debug、iOS unsigned、后端及最终发布产物；不能重跑旧244174c就宣称新修改已验证。AI_CONTEXT更新建议：保留长期门禁，当前进度引用本记录即可，不把临时SDK或本地687项通过写成全平台发布验收。

## 2026-10-10：run #31 远端完整链路成功（核对补记）

此前等待提交的阻塞已解除：修复已进入main提交 `f2d9fea61ee1ecb4f0f6dc08d62e087ce68694c8`。本次调查起始本地工作区干净，HEAD、GitHub main、Release目标及v0.12.31标签均为同一SHA；不是旧244174c的重跑。

- Actions run #31：`38060561355`，attempt 1，push，2026-10-10 22:40:41～23:01:28（Asia/Shanghai），status=completed、conclusion=success。
- 已逐job/step核对：prepare、Flutter analyze/test/Android debug、iOS unsigned Xcode27、backend/真实PostgreSQL regression/vet、release packages、publish均成功；关键构建、测试与发布步骤未跳过。
- Flutter job日志确认687项全部通过（49秒），并构建/上传Android debug APK；不能以本地通过替代该远端证据。
- Release v0.12.31已公开发布，draft=false、prerelease=false；附件5项均uploaded且非空：APK 122547319字节、AAB 93354717字节、Compose 1913字节、NAS env模板844字节、SHA256SUMS 396字节。元数据具有sha256 digest；本次未下载大包逐字节复核或执行设备安装。
- 发布job日志确认linux/amd64和linux/arm64均构建，manifest list `sha256:664f4613914a67d8ca5c7aff7bdb74ed0410313f2603d43284b75e2d75b51438` 已成功推送为 `ghcr.io/davisding/momobox-backend:v0.12.31` 与 `sha-f2d9fea`。没有在NAS拉取、启动或演练恢复；镜像发布成功不等于实机部署验收。
- workflow artifacts包含同SHA debug包、`momobox-v0.12.31`发布包及dockerbuild记录，均未expired。

证据入口：GitHub Actions run `https://github.com/DavisDing/MomoBox/actions/runs/38060561355`；Release `https://github.com/DavisDing/MomoBox/releases/tag/v0.12.31`；jobs `114237823227`（Flutter）、`114237823301`（backend）、`114237823352`（iOS）、`114239769307`（release）、`114241198241`（publish）。

结论：本次“修复Actions报错”的目标已由包含修复的新SHA完整成功链路证实。不扩展为设备、NAS、HA、签名iOS或全部产品需求已验收。本次仅本地追加验证证据，没有再次提交、推送、重跑或发布。

## 2026-10-11：既有能力安全补齐第一批（本地工作区，未发布）

### 范围与实际修改

- 起点HEAD `f2d9fea61ee1ecb4f0f6dc08d62e087ce68694c8`，保留上节原有未提交验证补记；本批次无提交/推送/远端CI/部署/真实恢复。run #31和v0.12.31仅证明此前SHA，不能验证本批次。
- 后端新增`schema-check`及`serve`监听前migration身份门禁：有界read-only repeatable-read，只校验ledger版本/名称/checksum，保留限定legacy兼容，不migration、不修复、不证明物理schema或恢复历史。
- NAS update停机核验包括restarting容器，最终备份在停写后执行，不以早先在线dump兜底继续；迁移/核验/health失败保持停止，未知任务或无法核验时保留锁。restore预检和确认后才停机，任何完成状态都不自动启动；原库单事务恢复仍非完整DR方案。
- 发布job注入固定key配置，验证证书pin及APK/AAB实际签名后才上传；缺配置不降级debug。密码仅通过env，临时key限制权限并在失败/always收尾清理。并未配置仓库真实key，未生成生产key；旧安装签名一致性/迁移与资源公开分发仍待确认。
- 无lib、业务模型、依赖、migration文件或UI变更；新增测试均保留既有门禁，未删测试或放宽超时。设计见DESIGN第17节，操作变化同步至NAS部署文档，签名配置见ANDROID_RELEASE_SIGNING。

### 本次实际执行

| 检查 | 结果 | 证据/限制 |
| --- | --- | --- |
| `bash scripts/ci/test-prepare-flutter-platforms.sh` | PASS | 现有平台生成回归；不等于原生构建 |
| `bash scripts/release/test-next-version.sh` | PASS | 现有版本计算回归 |
| `sh deploy/nas/scripts/self-test.sh` | PASS | 全部shell语法/help/参数及12项故障模拟；后者16.491秒，无Docker/PG，仅控制流验收 |
| `python3 scripts/ci/test-android-release-signing.py` | PASS / SKIPPED | 11项中10项配置/保密/清理/签名核验控制流通过，1项真实临时JDK签名JAR与篡改回归因无Java runtime跳过；不是APK/AAB正式签名验收 |
| Python AST解析、shell语法、workflow/两Compose Ruby YAML解析 | PASS | 未安装新依赖；YAML解析不证明GitHub执行或Compose运行 |
| Flutter3.47.7 `analyze --no-pub` | PASS | 零问题，5.8秒；`/private/tmp/momobox-gap-analyze-20261011.log` |
| 同SDK `test --no-pub --reporter expanded` | PASS | 全套687项，15秒，退出0；`/private/tmp/momobox-gap-tests-final-20261011.log`；没有运行pub get或改变锁文件 |
| `git diff --check` | PASS | 本地实际检查，非构建 |
| Go单元/新PG read-only回归/vet/gofmt | NOT_EXECUTED | 无Go/PG/Docker；新增PG回归只通过显式MOMO_TEST_DATABASE_URL启用，使用随机隔离schema，无生产DSN回退；需新SHA的CI执行 |
| JDK真实签名、Android/iOS构建/签名升级、Docker/NAS/HA演练 | NOT_EXECUTED | Java入口仅为无runtime系统wrapper；不安装运行时、配置仓库密钥或使用Mock代替实机验收 |

环境失败如实保留：首次Flutter调用无法写沙箱外tool_state，改用允许的临时XDG配置目录（未改系统权限）；沙箱内test因无法绑定127.0.0.1端口产生52个文件加载失败，执行了0项测试，不是业务断言失败（`/private/tmp/momobox-gap-tests-20261011.log`）。经审批允许测试回环端口后重跑，首轮日志687项成功但外围zsh使用只读变量status导致命令失败；修正为rc后重新全套运行，最终实际退出0。未通过其他路径绕过端口审批或安装依赖。

### 仍不能宣称完成的事项

正式签名key与旧安装证书/升级迁移、真实Go/PG/容器/NAS及设备验收未完成；首次Compose导入仍须执行同版本migration流程，不等于自动初始化。工作区数据归属、首次既有库存全量导入/分类出站/完整历史、date-only跨时区、TLS来源隔离、候选库/restore epoch/配套密钥等仍需后续决策与实施。当前批次仅补安全门禁，不把这些缺口记为已完成；恢复后的停机隔离不可用update/UGOS手动启动绕过。


## 2026-10-11：单工作区保护——已有改动核对与设计收口

### 身份、授权与范围

- 用户明确确认“采用单工作区保护（推荐）”：换NAS/账号/家庭保留原数据、暂停同步，不自动迁移。D-03/04/07及多工作区/迁移仍未批准。
- 当前基线HEAD为`5258a2b877784508ce777d09069f1257840b49ad`；本节验证对应已有未提交工作区改动，不是该提交或远端CI结果。既有修改涉及同步绑定、Provider/API门禁、原归属离线队列、迟到响应事务回滚及测试，见DESIGN第18节。
- 本次按架构设计角色收口，仅核对已有源码/日志、等待已启动验证完成及补设计/证据；未继续改业务代码，未安装依赖、迁移、提交、推送、部署或执行恢复。AI_CONTEXT仅提出局部更新建议。

### 最终实际执行证据

| 检查 | 结果 | 证据及限制 |
| --- | --- | --- |
| Flutter3.47.7 / Dart3.13.5 `analyze --no-pub` | PASS | 零问题、5.8秒；`/private/tmp/momobox-workspace-analyze-final.log` |
| 同SDK `test --no-pub --reporter expanded` | PASS | 已启动会话22402完成，实际退出0；全套706项、15秒，`/private/tmp/momobox-workspace-full-verified.log`；内存库/受控会话验证不替代真机/NAS |
| 平台准备回归 | PASS | 收口时重新执行`bash scripts/ci/test-prepare-flutter-platforms.sh`，不等于原生构建 |
| 发布版本计算回归 | PASS | 收口时重新执行`bash scripts/release/test-next-version.sh` |
| NAS脚本自检 | PASS | 收口时重新执行`sh deploy/nas/scripts/self-test.sh`；语法/help/参数检查及12项模拟成功，15.559秒，无Docker/PG |
| Android签名配置测试 | PASS / SKIPPED | 收口时重新执行`python3 scripts/ci/test-android-release-signing.py`；10项成功、1项因无JDK跳过，不等于正式包签名验证 |
| `git diff --check` | PASS | 收口时实际执行；新增文档后再次检查 |
| 新SHA远端CI/Android与iOS包/设备升级/NAS与HA/Go与PG/真实灾备 | NOT_EXECUTED | 没有发布、安装、运行容器或恢复；历史run #31和v0.12.31不得作为本次改动证据 |

测试诊断不隐藏：先前夹具使用错误getter`.totalQuantity`，已改为`.totalStock`；新库存用例首次使用错误consumeBatch参数，导致文件编译加载失败，日志`/private/tmp/momobox-workspace-full-final.log`，不能算运行断言通过。既有修正采用`consumeBatch(batch.productId, batch.id, 1)`，最终上述706项完整重跑成功；中间705项成功仅属于新增库存用例之前。未减少断言、跳过失败用例或放宽CI超时。本次收口没有再次修改测试。

### 验收边界与下一入口

- 已确认：方案选择；本地分析及706项回归通过。未完成：真实身份切换、重启、离线队列恢复、在途请求回执及安装升级验收。
- 同URL的服务端替换/旧dump恢复不能由endpoint识别；发送前的暂停与迟到本地回滚不能撤销原NAS已接受命令，仍须复用原幂等键处理未知回执。不把单工作区绑定称为完整恢复或数据迁移能力。
- 设计收口后停止；建议下一阶段先做已确认范围的实机/新SHA门禁验收，再单独确定首次基线导入（D-03）设计。多库、改绑、清库、重置cursor、自动搬迁均不属于本次授权。


## 2026-10-11：Actions run #33固定签名配置失败（外部配置阻塞）

- 起始工作区干净；本地HEAD和实时GitHub main均为`dfffb506358f4df391432d181f984583714a7beb`。通过GitHub连接器查询repository runs集合（commit-workflow wrapper仅查PR，返回空不是无push运行），最新run为#33 `38120748993`、attempt1、push、completed/failure，2026-10-11 15:15:22～15:25:12（Asia/Shanghai）。
- 逐job/step核对：prepare、Flutter analyze/unit tests/Android debug/上传debug、iOS unsigned、backend真实PG配置下test/vet全部success。正式包job `114416293514` 在步骤7“Configure fixed Android release signing (no debug fallback)”failure；后续依赖解析/构建/上传skipped，清理success，publish skipped。不将未发生的APK/AAB构建称为编译错误。
- 实际job日志2026-10-11 15:25:08显示5项ANDROID_SIGNING环境变量为空，明确错误为`Missing required signing configuration`，逐项是KEYSTORE_BASE64、STORE_PASSWORD、KEY_PASSWORD、KEY_ALIAS、CERT_SHA256（均带ANDROID_SIGNING_前缀），退出1。未输出或读取真实私钥/密码；只说明此job未取得配置，不推断其他environment/组织没有密钥。
- run #32 `38118640934`（SHA `5258a2b877784508ce777d09069f1257840b49ad`）也已核对job/step，同一签名prepare步骤failure；其他验证success，publish skipped。#32未读取全job日志，不将#33具体报错无证据地套到#32。
- 本地重跑`python3 scripts/ci/test-android-release-signing.py`：11项中10项PASS、1项真实JDK签名夹具因无runtime SKIPPED，0.048秒。空配置调用config精确复现相同5项缺失错误，不生成key、不写Android目录。`git diff --check` PASS。未重跑Flutter或实际原生构建，远端success依据本次连接器核实，不依据旧本地706项。
- 本次仅补DESIGN第19节、ANDROID_RELEASE_SIGNING排查及本记录，无业务代码/workflow/依赖更改；无Secrets配置、密钥生成、提交、推送、重跑或发布。管理员须在仓库Actions Secrets补齐固定密钥相关配置；当前job未声明environment，不会自动读取其他environment的Secrets。是否有原私钥及旧安装证书一致性仍NEEDS_CONFIRMATION，不用临时/debug签名绕过。
- 配置修复后入口：重跑#33失败jobs，逐项核实APK/AAB实际签名、上传、镜像及Release产出；当前正式发布仍阻塞。真实设备/NAS/HA/恢复验收未由这些CI成功替代。
- 证据：`https://github.com/DavisDing/MomoBox/actions/runs/38120748993`；正式包job `https://github.com/DavisDing/MomoBox/actions/runs/38120748993/job/114416293514`；run #32 `https://github.com/DavisDing/MomoBox/actions/runs/38118640934`。


## 2026-10-11：无固定签名key及无旧数据——设计确认补记

- 用户说明没有固定签名密钥，并确认未安装旧版或旧版没有需要保留的数据。本次仅设计本人无旧数据场景，不推断其他设备无数据，不授权卸载/清库/生成key。
- 起始工作区干净，HEAD `9bd37f1b75265f5d690baf2c622ccebf25d3fbf0` 已含上一阶段排查文档；未实时查询该SHA的新Actions结果，不称run #33是本次最新状态。
- 读取平台生成入口、已有签名配置/门禁及BackupFormat.coverage，确认JSON明确不支持媒体/OCR/身份/同步现场恢复。核对Android官方签名与App专属存储文档，作为设计依据而非项目实机证据。
- 交付：DESIGN19.1～19.4及签名文档建议新长期key、首次安装、后续同签名升级、私有保管/备份与Secrets入口；参数PROPOSED，创建/配置待授权。不增加迁移功能、依赖、workflow或业务代码。
- 文档空白检查PASS；真实key创建/备份恢复/Secrets配置/签名构建/首次安装/覆盖升级/新SHA CI均NOT_EXECUTED；没有运行Flutter/Go测试或安装JDK，没有提交、推送、发布或设备操作。设计结束停止，不把方案存在记为Actions已修复。


## 2026-10-11：新增两套独立Compose模板（静态交付，未部署）

- 用户明确要求自带最新稳定PostgreSQL与复用已有PostgreSQL两种完整配置。保留本轮前签名文档未提交改动；新增variants/with-postgres、external-postgres的docker-compose.yaml及.env.example、独立使用说明、真实.env忽略规则；局部更新部署入口/需求/设计。
- 读取官方版本策略、18.6实际发布日期及Docker镜像标签：2026-10-11当前稳定18.6，2026-08-13发布，18.5未发布、19beta4不选。自带版固定postgres:18.6-alpine3.24，新的postgres18_data挂载/var/lib/postgresql；不改原PG16镜像/卷，不迁移已有实例。没有Docker registry pull/manifest或NAS运行证据，网页标签核实不代表拉取实测。
- Ruby YAML实际解析与断言PASS：自带服务仅postgres/momo-backend、外部仅momo-backend、外部无数据库volume/depends_on、external网络存在、PG18卷路径正确，两套后端environment/read_only/tmpfs/cap_drop/security_opt/stop_grace_period/ports/healthcheck与原模板一致；原PG16配置仍不变。
- Python纯文本必填变量/对应env完整性断言PASS，外部模板无POSTGRES_PASSWORD初始化项；git check-ignore证明两套真实.env被排除；git diff --check PASS。变量文本检查非Docker Compose插值/config验证，不打印秘密。
- 原NAS self-test实际PASS：全部shell语法/help/参数检查及12项故障模拟，16.351秒；原运维脚本没有改动。git diff核对原Compose、scripts、backend、workflow均无本次差异，不以旧脚本测试证明新模板运行/外部升级安全。
- Docker/Compose config与拉取、PG18真实migration/并发、外部专属库/角色/TLS/网络、UGOS导入、数据重建保留、备份恢复及升级均NOT_EXECUTED；本机无docker/go/psql。没有安装工具、启动服务、创建库/角色、切换LiteLLM网络、数据迁移、提交推送或发布。
- 差距显式保留：原脚本固定原文件/自带postgres服务，不能用于两个新增目录；README提供新空库人工migrate/schema-check入口，已有真实库安全升级/版本匹配客户端备份恢复待适配与验收。正式Release仍只打包原模板，不声称两套已发布或生产可用。详见DESIGN20及variants/README。


## 2026-10-12：Actions run #34 attempt2——签名输出兼容修复及NAS资产接入

### 实时调查与范围

- 用户明确授权修复当前Actions并提交；本地main与GitHub main起始SHA均为`9bd37f1b75265f5d690baf2c622ccebf25d3fbf0`。最新run为#34 `38147596818` attempt2，2026-10-11 23:34:56～23:43:51（Asia/Shanghai），completed/failure；查询runs集合、最新jobs及正式包job `114506821551`完整日志，不套用历史#33缺Secrets结论。
- 签名prepare success；日志APK构建success（122.6MB）、AAB构建success（93.4MB），23:43:48报`APK signer does not match the single pinned certificate.`，退出1；cleanup success，上传/publish skipped。prepare、Flutter analyze/tests/debug、iOS unsigned、backend/PG/vet均success。KGP未来兼容和watching-path提示未使本次构建失败，不借此扩大依赖升级范围。
- 原始apksigner证书输出未记录，旧错误同时覆盖格式解析失败及真正pin不匹配；因此具体单一根因仍未证实。读取Android官方ApkSignerTool源码，确认v3.1输出SDK-range标签，而原解析只识别Signer编号，这是已证实的兼容缺陷。修复两种已知标签并区分无证书/格式/数量/错pin诊断；保持工具非零拒绝、恰好一个有效signer、全部应用证书同pin、AAB strict及always清理。没有读生产key文件/密码、修改Secrets、更换pin或fallback debug。
- CI新增debug APK临时副本的真实隔离签名回归，不触碰生产key/上传debug包；新回归仍需新SHA远端执行。纳入前一批已请求的两套完整Compose/env/操作指南及SHA256/Release资产，不更改原PG16部署、业务、依赖、数据库、运维升级/恢复脚本。

### 本轮实际执行

| 检查 | 结果 | 证据及限制 |
| --- | --- | --- |
| `python3 scripts/ci/test-android-release-signing.py` | PASS / SKIPPED | 13项中12项成功、1项真实JDK/可选APK夹具因无Java runtime跳过，最终0.052秒；标签/CRLF/SDK范围/错pin/未知格式/多签名/Source Stamp、旧保密/清理断言保留 |
| `python3 scripts/ci/test-nas-release-assets.py` | PASS | 1项，0.054秒；实际执行workflow打包段到临时目录，10个资产、3套env固定镜像/版本、Compose原字节、9项SHA256、publish列表一致；APK/AAB仅占位字节，不是签名验证 |
| 平台准备回归 | PASS | `bash scripts/ci/test-prepare-flutter-platforms.sh`；不是Android/iOS原生构建 |
| 发布版本回归 | PASS | `bash scripts/release/test-next-version.sh` |
| NAS脚本自检 | PASS | `sh deploy/nas/scripts/self-test.sh`；shell语法/help/参数及12项故障模拟，16.530秒；不等于新模板运行 |
| workflow YAML及全部run段shell语法 | PASS | Ruby YAML解析、逐步`bash -n`；非GitHub端执行 |
| Compose结构/环境与安全保护、真实env忽略、Python AST、空白 | PASS | Ruby断言两套服务/卷/网络和后端保护与原版一致，`.env`忽略确认、`git diff --check`；不是Compose插值/运行 |
| 本机真实JDK/apksigner/Android/iOS、新SHA远端CI/签名发布/设备升级 | NOT_EXECUTED | 无本机运行环境，不安装依赖；旧SHA的success不作为修复后验证 |
| PG18/外部库/UGOS、数据持久化/迁移/备份恢复 | NOT_EXECUTED | 无Docker/Go/psql，不启动服务或改LiteLLM |

过程中诊断保留：新增CRLF用例首次暴露signer-count行解析未兼容CRLF，出现3个子用例错误；改为splitlines后完整13项重跑成功，未删用例。首次文档编辑命令因stdin编码声明缺失停止，补编码后重新成功；没有把后续shell退出0当作文档已经写入。官方源码只读网络请求在沙箱内DNS失败，经审批读取官方公开源码成功；未安装软件、无秘密传输。

交付入口见DESIGN21及ANDROID_RELEASE_SIGNING补充。按用户授权本地提交前检查明确文件清单和秘密；不自动push/重跑/发布。必须在新SHA上确认正式校验、制品和发布成功才可称“Actions问题已关闭”；若明确出现真正pin不匹配，继续调查实际签名选择，不能换pin或绕过校验。原新增模板升级/备份脚本及现场验收缺口继续保留。

证据：`https://github.com/DavisDing/MomoBox/actions/runs/38147596818`，job `https://github.com/DavisDing/MomoBox/actions/runs/38147596818/job/114506821551`；官方源码 `https://android.googlesource.com/platform/tools/apksig/+/refs/heads/main/src/apksigner/java/com/android/apksigner/ApkSignerTool.java`。


## 2026-10-22：NAS 并行实现与本地收口（未提交、未运行验收）

### 范围、基线与实际交付

- 起始 `main` / HEAD `ee70ffd47c32a288fd75c61ef0cc7f6d8b92085b`，工作区初始干净；本批修改仍未提交，没有 push、发布、真实库/设备操作。此 SHA 是起始基线，不能代表新代码已经进入该提交。
- 用户明确批准当前库存＋独立历史归档、保留日历年月日并以家庭时区（默认 Asia/Shanghai）判断今天、三模式共用运维和新模式独立空候选库恢复。实现对应 REQUIREMENT AC-025～027、DESIGN 第 23 节及本日三个分项方案。
- 后端新增导入预检/确认/永久回执/独立历史分页，PostgreSQL additive 0007、家庭时区与严格日期；App 新增冻结计划/原 ID 恢复/分类身份/日历文本列、Drift 5→6 和现有同步设置页的审阅/进度/归档入口。NAS 三模式脚本与 operations release 工具包已接入。
- 另修复已核对的 run #41 Flutter analyze 诊断，以及 HA 生产 repository 未共享账号 endpoint/session 保护的问题。新会话检查覆盖请求/响应/refresh/retry。没有删除测试、放宽门禁、清业务库/outbox/cursor或引入依赖。

### 本次实际执行并通过

| 检查 | 结果 | 证据范围 |
| --- | --- | --- |
| `sh deploy/nas/scripts/self-test.sh` | PASS | shell 语法/help/参数；原安全 12 项、变体 17 项、PG client/URI 9 项，共 38 项。执行的是实际脚本与 awk，但 Docker/PG 是 fake；不能推导真实数据库通过 |
| `python3 scripts/ci/test-nas-release-assets.py` | PASS | 实际执行 workflow NAS 打包段，核对 11 资产、10 SHA256、operations 归档 12 文件白名单/内容/权限及发布列表；无真实发布 |
| workflow 和 2 个 operations YAML 解析；33 个 workflow run 块 `bash -n` | PASS | Ruby YAML 与 shell 语法，不执行里面的构建/上传/部署 |
| 新增 SQLite 原始 DDL smoke | PASS | Python sqlite3 执行当前 initialImportSchema 的 4 条原始 DDL 和新增 nullable 日历列；检查旧数量/时间戳未改、canonical 日期重开后保留、FK/重复来源与 cursor 约束、事务回滚、integrity_check/foreign_key_check。仅为 SQLite SQL 证据，不是 Dart/Drift migration 执行 |
| 代码/合同交叉复核 | 完成静态核对 | 分类实际 auxiliary payload 解包及负 sort_order 兼容、服务端连续 SQL 参数、未知回执原 ID 恢复、导入 marker 与旧 outbox 结算、receipt/旧快照失效标记原子保存、固定历史高水位与末页、会话迟到响应保护 |
| `git diff --check` 和新增文件逐行空白/末尾换行 | PASS | 同时检查 git 未跟踪的新源码/测试/文档，不把 diff 对未跟踪文件的遗漏当通过 |
| 4 个变更 Python 文件 AST | PASS | 语法解析，不等于所有执行分支测试 |
| migration 0001～0006 及依赖清单/锁文件与 HEAD 字节核对 | PASS | 旧迁移不变；pubspec.yaml/pubspec.lock、backend/go.mod/go.sum 无新增依赖或改写 |

### 已补充的回归源码（未运行）

- 后端 `internal/sync/import_test.go`、`internal/httpapi/import_test.go` 与 `internal/store/syncpostgres/import_postgres_test.go`：有界字段合同、认证设备/真实权限、12/5 基线、独立历史、重复/并发/换设备回执、目标重叠与撤销 prepared、receipt 写入/COMMIT 故障整体回滚、普通实体 insert/update 的连续参数绑定。真实 PG 仅显式 MOMO_TEST_DATABASE_URL 启用，随机隔离 schema 无 public fallback，跑新旧 migration。
- 原库存真实 PG fixture 补齐 families.time_zone 的实际契约，新增上海/洛杉矶到期当日/次日和两种消费命令回归；没有通过删除生产时区检查回避 fixture 缺表。
- App `initial_import_service_test.dart`：预览只读、独立确认、12/5 与归档不重放、回执丢失重启恢复、源数据/canonical 日期改变、暂停和切会话迟到响应、摘要不一致、旧快照失效、非法历史分页不推进 cursor、接受后新增 outbox 用原 key 结算、分类出站依赖。
- `initial_import_repository_test.dart`、`calendar_date_test.dart`、`sync_business_adapter_test.dart`：v5→6、旧日期不猜测回填、辅助 category envelope/负排序、canonical JSON v3 备份兼容与归档排除、跨日期线/夏令时及到期日有效。
- UI `initial_import_review_dialog_test.dart`、`initial_import_history_dialog_test.dart`：目标与覆盖、逐批日期核对、两次确认、阻塞无法勾掉、固定高水位、失败重试原页、拒绝变化水位和会话迟到响应。
- HA `nas_smart_home_repository_test.dart`、`nas_ha_session_test.dart`：endpoint 绑定、共享认证/refresh 生命周期，close/logout/family/refresh 竞态与旧会话重试保护。

### 未执行、剩余事项与交付边界

| 验证 | 状态 | 原因/限制 |
| --- | --- | --- |
| Dart format / Flutter analyze、test、Drift build_runner、Android/iOS build | NOT_EXECUTED | 当前 PATH 无 Flutter/Dart，已有临时 SDK 不完整；未安装、继续下载或调用隐式下载入口 |
| Go test / vet / gofmt、Linux build | NOT_EXECUTED | 当前无 Go/gofmt 工具链；没有以静态阅读代替编译或格式化 |
| 真 PG16/PG18 migration/权限/并发/幂等/事务回滚/历史分页 | NOT_EXECUTED | 当前无 psql/Docker 或已授权测试库连接；新增真实 PG 测试源码未运行 |
| 实际 Docker/Compose、managed/external、UGOS、升级/候选恢复及 HA | NOT_EXECUTED | 没有目标环境运行；fake daemon 不作为设备证据 |
| 新改动同提交 Actions、镜像与 release operations 资产发布 | NOT_EXECUTED | 修改仍未提交/推送；历史远端通过不能证明当前代码 |
| UI 截图/真机、双设备断网/重启/第二份备份重复导入 | NOT_EXECUTED | 无真机运行；UI 与恢复行为需后续联合验收 |

本批实现有限制：1000 条/1 MiB 超限整批阻塞；旧日期/分类歧义与同 UUID（包括重复历史）重叠保留人工核对；旧日期来源已丢失时，非午夜检测不保证识别整日偏差或还原原值，审阅需对照原始资料；普通后续库存命令历史尚未统一跨端查询/去重。完整灾备切换、restore epoch/服务实例变更、改绑/多工作区、媒体迁移仍不在本批；HA scene/script 的 App 接入与真实事件来源方案仍待确认。NAS 当前不能称为全部完成验收。

长期事实更新建议：取得同 SHA CI、真实 PG/NAS 与设备证据后，再局部补充 AI_CONTEXT 的 schema6/0007、首次导入、分类/日期、HA 会话与三模式运维支持矩阵。本批不覆盖旧验收记录。


## 2026-10-22：run #42 NAS 自检临时路径修复

- GitHub 连接器实时核对：本地与远端 main 同为 `40f7d146cb8e0b69010a3bf18820631a99a4aca2`，开始时工作区干净。run #42 `39739379172` attempt 1，于 2026-10-22 15:16:40～15:17:05（Asia/Shanghai）失败，Prepare job `119692628327` 的 Validate NAS deployment scripts 报 3 failures / 1 error；后续 Flutter/iOS/backend/发布均 skipped，不能当作已执行成功。
- 根因：`test-pg-client.py` 先将容器 awk 路径替换为本机绝对路径，再全局替换 `/tmp/`。Ubuntu 的临时目录本身位于 `/tmp`，故 parser 路径被再次展开成 `/tmp/<fixture>/<fixture>/pg-connection.awk`。macOS 默认临时目录未包含 `/tmp/`，此前检查未覆盖该布局。
- 修复：先重定位生产脚本中的容器私有 `/tmp/` 路径，再注入 parser 路径；所有该套件夹具固定创建在独立 `/tmp` 子目录，使 macOS 本地也覆盖 Linux 路径布局。测试仍执行实际 awk/client shell，保留权限、错误私有化、凭据和候选恢复断言；未改生产脚本或降低 CI 门禁。
- 原 HEAD 回归复现：读取原测试源码并强制 `/tmp` 布局，probe 用例按预期失败，错误为重复目录的 awk 文件不存在。该预期失败用于根因证据，不计入修复后通过结果。
- 修复后实际结果：`python3 deploy/nas/scripts/test-pg-client.py` PASS（9 项）；`sh deploy/nas/scripts/self-test.sh` PASS（12+17+9=38 项，分别 15.781 / 20.404 / 8.250 秒）；`python3 scripts/ci/test-nas-release-assets.py` PASS（1 项，0.066 秒）；`git diff --check` PASS。
- 上述验证为本机 POSIX shell/awk/Python 和 fake PG/Docker，不是 Ubuntu 原生执行、真实 PostgreSQL/Compose/NAS 验收。当前尚未提交/推送/重跑远端；run #42 仍是原失败状态，新提交的后续 Flutter/Go/设备验证均需独立证据。
- 证据：`https://github.com/DavisDing/MomoBox/actions/runs/39739379172`；job `https://github.com/DavisDing/MomoBox/actions/runs/39739379172/job/119692628327`。

## 2026-10-22：run #43 Flutter 编译与 analyze 修复（本地修改，运行待验证）

- 基线：本地 HEAD 与 run #43 均为 `f7c9617449f39bd8d88c809a883d7b37aefb88d1`，开始时工作区干净。run `39743266476` attempt 1 于 2026-10-22 15:49:54（Asia/Shanghai）触发，最终失败；本节修改尚未提交/推送，不能用该 run 代表修改后通过。
- 远端已通过：Prepare job `119705445434` 的 NAS 脚本和发布资产检查通过，确认上轮临时路径修复通过 Ubuntu 检查；Backend job `119705657697` 的 Go 测试与 vet 通过，日志有真实 `postgres:16` service、显式测试数据库 URL 及 `internal/store/syncpostgres` 测试通过。证据仅绑定上述 SHA，不替代 NAS/PG18/外部库/HA/设备验收。
- Flutter job `119705657797` 的 analyze 报 6 项：`sync_engine.dart:615` 的 `String?` 参数、`initial_import_service_test.dart:132` 缺少必需 `results`，以及账号控制器/历史弹窗的 2 处 if braces 和导入卡片的 2 处异步 context lint。iOS job `119705657831` 也因同一个 `String?` 参数失败；没有 Xcode 配置修复证据或需求。
- 修复：首次导入恢复在既有模式白名单上显式拒绝 null，让局部变量提升为非空 String；保留异步后模式复检、scope/session/checkpoint 校验。测试 API 从同一 accepted 列表生成逐条 `NasSyncPushResult(status: 'accepted', accepted: entry)`，与真实回执合同及引擎优先消费 results 的路径一致。预览/继续在 await 后显式检查 mounted，并保留原 service 身份检查；另外两处只补分支花括号。
- 源码复核：既有“接受后新增 outbox 按原 key 结算再恢复”测试仍检查 pushed=1、accepted 状态、原 idempotency key 和余量 5，未删除或放宽断言。无 UI 布局、依赖、数据库、workflow 或 lint 门禁变更。
- 本机实际执行：`git diff --check` PASS；对照全部 6 项日志和当前 diff 完成静态复核。这些检查不构成 Dart 编译或运行验证。
- 本机 `flutter`/`dart` 不在 PATH，残缺临时 SDK 也无 Dart executable/analysis snapshot；未安装或下载工具。`flutter analyze`、`flutter test`、Android debug 与 iOS unsigned build 均为 `NOT_EXECUTED`。原 run 的 Flutter tests/debug build、正式打包和发布均为 `SKIPPED`；需后续新提交的完整 CI 确认。
- 证据：`https://github.com/DavisDing/MomoBox/actions/runs/39743266476`；失败 jobs `119705657797`、`119705657831`；后端 job `119705657697`。

## 2026-10-22：run #44 采购确认、日期夹具与工作区测试等待修复（运行待验证）

- 基线：本地 HEAD 与 run #44 均为 `7f019c3e7c7199a1e4a2ecdde59c49d789324b9c`，开始时工作区干净。run `39749735487` attempt 1 于 2026-10-22 16:42:20（Asia/Shanghai）触发；本节修改尚未提交/推送，不能算该 run 已通过。
- 同 SHA 远端结果：Prepare `119726987994`、Backend test/PostgreSQL regression/vet `119727167670`、Flutter analyze（job `119727167709` 的 Static analysis）和 iOS unsigned build `119727167713` 均为 PASS，确认上轮 6 项 analyze/编译修复已通过对应门禁。Flutter Unit tests 已输出 `+755 -6`，但仍有测试未结束，随后在 16:54:47 触发 10 分钟超时；此计数不是完整测试完成结果。Android debug、正式打包及发布均 SKIPPED。
- 采购确认的 3 项失败：`ai_app_actions_test.dart:96` 的 add/complete/delete 在仅分类或原因被 raw SQL 修改后仍执行成功。完整快照本已包含这些字段，但 `watchEntries().first` 可读取尚未失效的 Drift 流缓存。Repository 新增直接 `select.get()` 的 `readEntries`，与原 watch 共用过滤、排序及映射；Service 透传，AI 描述/上下文/执行前指纹使用新鲜查询，原 UI stream 不变。保留 raw SQL 和旧确认必须抛错断言，另验证数据未被旧确认写入，重新审阅确认后才成功。
- 导入阻塞夹具的 1 项失败：`initial_import_service_test.dart` 使用 10 字符 `stable-key`，先于目标场景触发现有 16～255 字符合同。仅改为合法稳定键 `stable-pending-operation-key`，保留 pending 阻塞、禁止 prepare 和没有上传预检的断言，不放宽生产校验。
- 日期的 2 项失败：AI 入库测试将纯日历字段与 local DateTime instant 比较，现严格校验 `YYYY-MM-DD` 及实际持久 canonical 值；提醒测试只修改 legacy expiry_date，未更新已优先采用的 expiry_date_calendar，现经真实 `applyRemoteProductBatch` 构造过期批次，并按家庭 Asia/Shanghai 取今天。新增禁用前过期/有提醒的前置断言，保留禁用后库存、过期事实、可用量及无通知候选的原断言。未修改生产日期语义。
- 超时源码诊断与修复：最后活动的是 `sync_workspace_provider_test.dart` 的身份变化/重新确认 Widget 测试。原固定 15 次零时钟推进不能保证 UI 发起的 Drift 事务完成，随后 runAsync 内 readOwner 可能等待尚需 fake zone 推进的事务。改为有界交替真实事件循环和 16ms pump，等待事务提交后才显示的绑定成功消息（旧确认则等失败消息），再读取 owner；不再无条件 pumpAndSettle 等待页面所有 loading 动画。保留身份拒绝、归属和引擎断言，未延长 CI 超时。具体挂起位置与修复效果仍需运行确认。
- 本机验证：`git diff --check` PASS；完成回执/查询合同、日期写入路径、测试断言及 import 目标的静态复核。无 UI 布局、依赖、schema、workflow、生产绑定或同步门禁变更。源码复核不能替代测试执行。
- 环境限制：`flutter`/`dart` 不在 PATH，残缺临时 SDK 无 Dart executable；未安装工具。修改后 `flutter analyze`、受影响 5 个测试文件、完整 `flutter test`、Android debug/iOS unsigned build 均 `NOT_EXECUTED`，需新提交的完整 CI 验证。
- 证据：`https://github.com/DavisDing/MomoBox/actions/runs/39749735487`；Flutter 测试 job `119727167709`；iOS job `119727167713`。

## 2026-10-22：run #45 工作区 Widget 可点击状态与清理生命周期修复（运行待验证）

- 基线：本地 HEAD 与 run #45 均为 `d3a509411cbbba8094fea9fa0091ab7d3716530b`，开始时工作区干净。run `39759449117` attempt 1 于 2026-10-22 17:57:47（Asia/Shanghai）触发；本节修改尚未提交/推送。
- 同 SHA 远端：Prepare `119759679095`、Backend test/PostgreSQL regression/vet `119759833285`、Flutter analyze（job `119759833019`）及 iOS unsigned build `119759833073` PASS。上轮 6 项测试失败未再出现；本轮输出 `+760 -1`，但测试仍未完整结束，于 18:10:10 触发 10 分钟超时。Android debug、正式打包及发布均 SKIPPED，不能称全量测试或发布通过。
- 本轮明确失败：`sync_workspace_provider_test.dart:173` 第二次点击“确认本机数据归属”时日志有未命中控件的 warning，随后 `:175` 找不到“确认属于此身份”弹窗按钮。上轮只等文字存在，未保证按钮已启用、可命中、归属 provider 已加载或旧弹窗退出，因此第二次弹窗没有打开。
- 点击修复仅在测试：通过 ButtonStyleButton 的非空 onPressed 和 hitTestable finder 确认能真实点击；归属入口还要求 access 非 loading、canBind 和没有旧 AlertDialog。弹窗内容出现后也经同样控件就绪检查再点击。最终成功还须 access 刷新完成、canSync、owner 匹配当前身份及原入口/弹窗标题消失，才读取数据库。仍执行真实 tap，不直接调用回调、不忽略命中 warning，不改生产 UI/绑定/身份规则。
- 收尾修复：两个 Widget 测试的 finally 负责卸载树、关闭 subscription/container，并在 fake zone 仍可推进时启动 db.close，有界交替真实事件循环与 pump 等待关闭。关闭错误按原错误/栈抛出，未完成则明确断言失败；共享 tearDown 不再对已由 Widget 接管的 pending close 重复无界等待。普通非 Widget 测试仍执行原有完整清理，surface size 始终恢复。
- 生命周期依据：核对现有临时 Flutter 源码的 `flutter_test/lib/src/widget_tester.dart`、`binding.dart` 和 `finders.dart`。testWidgets 注册 binding.postTest；fake async 仅在运行阶段推进，postTest 清除当前 fake zone；故在普通 tearDown 才等待 Widget 创建的流取消/查询有挂起风险。原 run 没有具体 db.close 堆栈，精确挂起位置及修改效果仍需新 CI 确认。
- 本机 `git diff --check` PASS，并完成控件类型/API、所有原业务断言、成功/异常清理与共享 tearDown 的静态复核。只修改该测试文件和本记录，无依赖、schema、workflow、生产代码或超时设置变化。
- 本机 Flutter/Dart executable 仍不可用，未安装工具。修改后的 `flutter analyze`、该文件测试、完整 Flutter 测试、Android debug/iOS unsigned build 均 `NOT_EXECUTED`。
- 证据：`https://github.com/DavisDing/MomoBox/actions/runs/39759449117`；Flutter job `119759833019`；iOS job `119759833073`。

## 2026-11-02：日历跨日刷新续修（本地源码，运行待验证）

- 基线 HEAD `76d6b62`，开始时工作区干净；本批对应 AC-026 和 AC-018 读取保护，不新增业务范围。修改未提交、推送或发布。
- 已新增独立前台日历调度，连接App生命周期和当前库存所属家庭时区；跨日或单机时区变化时刷新库存及统计，再沿原路径重算提醒/通知。普通分钟检查及同日权限弹窗返回不触发数据库读取/通知重排，后台与卸载停止定时器。
- 通知重排要求库存和提醒确认同时成功就绪，不使用加载/错误状态中保留的旧值，不把未读取确认当作空列表。失败时保留原计划，数据恢复后原监听继续。
- 新增9项回归源码（领域2、调度5、App接线2），覆盖上海午夜、日期线、纽约夏令时23/25小时日、单机UTC instant、时钟跳变、时区切换、后台跨日/同日返回、重复挂载、Provider替换、卸载与加载/错误数据保护。测试源码尚未执行。

| 检查 | 状态 | 证据及边界 |
| --- | --- | --- |
| 本批7个Dart文件tree-sitter解析 | PASS | 复用已有 `/private/tmp/momobox-dart-syntax-314` 与系统已有Python3.14，0语法错误；包括新增未跟踪文件，不是Dart类型/API检查 |
| 本批引用、空白、末尾换行与 `git diff --check` | PASS | 本地静态检查；不代表Flutter布局/生命周期/数据库运行通过 |
| Flutter analyze、9项新增回归及既有通知/调度回归 | NOT_EXECUTED | PATH未发现Flutter/Dart，package_config所指临时SDK已不存在；未安装工具或依赖 |
| Drift生成、Android/iOS构建、同SHA CI、设备视觉/权限/时区联调 | NOT_EXECUTED | 无可用SDK/设备，本批未提交或运行远端CI；历史提交结果不覆盖本批 |

建议可用SDK环境先执行：

```sh
flutter test test/domain/calendar_date_test.dart test/application/calendar_refresh_scheduler_test.dart test/app/calendar_refresh_wiring_test.dart test/app/sync_scheduler_wiring_test.dart test/presentation/notification_permission_recovery_test.dart test/services/local_notification_service_test.dart
flutter analyze
flutter test
```

随后按现有CI完成同SHA Android debug/iOS unsigned build，并在设备上分别检查家庭午夜、单机旅行/系统时区变更、后台跨日、通知设置授权和测试通知。不得把语法解析当作这些验证已通过。

会话过程中另出现 `settings_screen.dart`、`mobile_redesign_test.dart`、`widget_flows_test.dart`、`settings_hierarchy_test.dart` 及相关需求/设计的改动；这些不属于本批写入范围，已保留，不计入本批7文件语法结果或功能交付。无数据迁移、依赖或视觉设计变更。长期AI_CONTEXT更新建议见DESIGN同日“日历跨日与提醒刷新续修”一节，待运行证据后再确认。

## 2026-11-02：普通操作历史与后端图片/OCR/AI（本地实现，设备验收待执行）

用户明确授权普通操作历史跨端同步、已有图片/OCR迁移，以及连接并确认后端同步后将图片处理、OCR和AI分析迁至NAS；AI包括入库草稿、助手和说明书问答。不做多工作区、改绑或跨家庭迁移。工作区已有且会话期间继续出现其他设置、采购、日历刷新和后端/运维修改，均保留；本记录不将这些其他修改归为本批交付。未提交、推送、部署或发布。

### 实现与兼容边界

- 后端追加migration 0010：普通consumption_records增加提交有序历史游标和客户端发生时间；新增媒体字节/状态、删除墓碑及AI结果回执。历史拉取只落流水，不重放库存；新本机事件用operation_id+batch_id与服务端记录关联，分页和游标同SQLite事务提交。旧流水只在原outbox与批次/数量/时间有精确唯一证据时关联，无证据不近似删除，旧重复项仍可能需要核对。
- Drift schema6→7只新增三个原生辅助表，保留原图、OCR、库存及已有流水；核心JSON格式和媒体排除边界不变。已有OCR迁移保留文字及local_migration来源，不自动重新识别。新拍摄原字节暂存，NAS完成方向处理、JPEG正规化、存储和OCR；上传超时保留同ID/内容重试，墓碑防止迟到上传/识别复活，草稿确认关联有持久待办。
- AI目标/模型/密钥从NAS环境读取，兼容chat/responses与配置的主/副/兜底服务；不接受手机指定endpoint/key/tools。说明书检索也移至NAS，模型只收到获授权文字。手机继续结果校验、可编辑草稿和逐次写入确认。已选择后端时不可静默回退至本机OCR或手机AI密钥。
- 图片、OCR和AI请求复用既有家庭/设备认证及refresh；处理模式在首次发送、401刷新后的重试前及响应后复检，拒绝切换到仅本地/其他endpoint后的迟到结果。收尾源码复核修正入库媒体状态文字的组件位置，避免通用按钮引用不存在的assets/theme。
- 现有页面布局/主题保留，更新路径说明、发送确认、OCR操作及状态反馈。镜像增加Tesseract和中英文语言数据，无新增Go module或Dart包。NAS AI环境变量与接口说明见 `nas/06-backend-processing.md`。

### 已执行验证

| 检查 | 结果 | 证据与限制 |
| --- | --- | --- |
| Go全套测试与真实PostgreSQL16回归 | PASS | 复用已有临时Go1.22.8、缓存依赖及隔离PG16.2；`go test -count=1 -ldflags=-linkmode=external ./...`，显式MOMO_TEST_DATABASE_URL指向本轮临时库，各测试创建/清理随机schema；覆盖迁移、图片/OCR状态、重试/墓碑/关联、历史只读分页/排序锁、AI回执和现有后端回归 |
| 最后中文说明书检索修改后的受影响Go包 | PASS | `go test -count=1 -ldflags=-linkmode=external ./internal/processing ./internal/httpapi ./internal/store/syncpostgres`，仍使用同一隔离PG16；OCR和模型使用可控替身，非真实识别/推理 |
| `go vet ./...` | PASS | 本轮后端工作区静态检查 |
| Linux amd64/arm64编译 | PASS | CGO关闭的两个后端产物存于 `/private/tmp/momobox-processing-linux-amd64` 和 `/private/tmp/momobox-processing-linux-arm64`；只证明编译，不是Linux运行或镜像构建 |
| NAS发布资产检查 | PASS | `python3 scripts/ci/test-nas-release-assets.py`，1项 |
| NAS部署变体检查 | PASS | `python3 deploy/nas/scripts/test-variants.py`，19项；本机脚本/fake环境，不是实际Compose |
| NAS脚本安全回归 | PASS | `python3 deploy/nas/scripts/test-safety.py`，14项；本机脚本/fake环境，不是NAS运行 |
| Dart tree-sitter语法解析 | PASS | 最终工作区33个存在的修改/新增Dart文件，0语法错误；包含本轮新增回归源码及并行会话文件，未计删除文件；不是Dart类型/API检查 |
| SQLite辅助schema创建/重复执行 | PASS | 读取实际backend_processing_schema.dart三条DDL，在SQLite内存库连续执行两次并核对表名；不等于Drift升级/手机运行 |
| `git diff --check`及新增源码/文档空白与末尾换行 | PASS | 包含未跟踪源码/测试/SQL/文档检查；不以diff忽略新文件代替验证 |

Go初始环境不在PATH，已使用现存临时工具和缓存解决；macOS Go1.22默认链接生成的测试程序曾因LC_UUID问题无法运行，最终使用外部链接完成上述测试，不将初始环境失败当作最终测试结果。未安装或修改系统工具链。

### 未执行与后续验收

| 检查 | 状态 | 原因/所需证据 |
| --- | --- | --- |
| Flutter analyze、Flutter tests、Drift build_runner、Android/iOS构建 | NOT_EXECUTED | PATH无Flutter/Dart，package_config指向的临时SDK不存在；没有可用Dart编译器，源码与语法复核不替代运行 |
| 真实Tesseract与中英文识别质量 | NOT_EXECUTED | 本机无OCR程序；后端回归使用OCR替身，镜像所需系统包仍需实际构建验证 |
| 真实模型、网络/协议与费用行为 | NOT_EXECUTED | 未配置或调用真实供应商；HTTP替身只验证合同、回执和限制 |
| Docker/Compose、NAS升级/备份恢复、双手机联调 | NOT_EXECUTED | 无目标环境执行；须核对真实图片/OCR迁移、第二设备展示、断网/重启/会话切换、逐次确认及历史不重复/数量不变 |
| 当前改动对应的远端CI/镜像/Release | NOT_EXECUTED | 修改未提交/推送，历史CI和既有版本资产不覆盖本轮 |

可用SDK环境先执行 `flutter test test/application/backend_processing_service_test.dart test/application/media_service_test.dart test/data/nas_sync_api_test.dart test/domain/ai_fallback_executor_test.dart`，再执行 `flutter analyze` 和既有完整CI。新增回归源码覆盖历史消重/重放/数量不变、异常页不推进、上传回执丢失保持ID/内容、本机OCR不调用、AI不读取手机配置或静默回退、模式切换响应/refresh重试保护；这些Flutter测试尚未运行，不记为PASS。本轮隔离临时PostgreSQL已正常停止，保留测试目录供复核，没有清理业务数据。

AI_CONTEXT长期更新建议：设备验收后局部记录双模式的图片/OCR/AI边界、schema7和普通历史同步，替代旧“NAS不提供AI Proxy”的描述；本轮仅提出建议，不把源码状态升级为设备验收。


## 2026-11-02：NAS 内部密钥自动管理与精简 Compose

本批按用户确认实现首次自动生成并持久化 JWT_SECRET、REFRESH_TOKEN_PEPPER、HA_TOKEN_ENCRYPTION_KEY，保持登录/刷新与原显式环境变量兼容。主要改动为 backend/internal/platform/config.go、secrets.go、secrets_test.go，及命令层 healthcheck/schema-check 只读加载和 config_secrets_test.go。单文件模板 deploy/nas/ugreen-v0.12.67/docker-compose.yaml 删除三项手填密钥，仅需改数据库连接/外部网络；配套 README 明示既有密钥保留、发布前提与数据目录权限。未修改本批范围之外的并行会话功能。

### 已通过

- Go1.22.8受影响回归：internal/platform、cmd/momo-backend、internal/securetoken、tests/auth、tests/homeassistant，使用 `go test -race -ldflags=-linkmode=external -count=1`；均PASS。命令层真实优雅退出测试使用本机随机回环端口，未访问NAS或数据库。
- 新增覆盖：24路并发初始化同一身份、重启复用、实际JWT验签/refresh摘要/HA解密连续性、完整显式配置无文件依赖、部分配置保留原始字节、环境覆盖不回写、损坏/缺字段/版本/尾随数据/宽权限/链接/目录/超大文件拒绝且不覆盖、不可写目录失败、无效配置不落盘、read-only命令不初始化。非密钥配置错误保持准确字段提示。
- `go vet ./internal/platform ./cmd/momo-backend`：PASS。
- CGO关闭的Linux amd64/arm64后端编译：PASS，构建版本注入v0.99.1-check仅用于验证；输出位于/private/tmp/momobox-compose-linux-{amd64,arm64}，不是发布产物或Linux运行证据。
- Ruby YAML解析与本次精简模板静态断言：PASS，核对单服务/latest/仅DATABASE_URL/18473/数据挂载/外部网络/无.env及用户排除字段。
- `python3 scripts/ci/test-nas-release-assets.py`：PASS（1项，现有发布资产打包回归）。此次精简模板另外以显式文件列表刷新本地交付包，不表示已纳入远端Release。
- 最终 `git diff --check`、新增文件空白/末尾换行检查及本地交付包逐文件内容核对：PASS；交付包仅含Compose、README和.gitignore，不含运行data或secrets.json。

工具复用已有临时Go与依赖缓存，GOPROXY=off、GOSUMDB=off；MOMO_TEST_DATABASE_URL明确移除。macOS测试使用外部链接避开现有Go1.22 LC_UUID问题，未安装依赖、修改系统环境或接触业务数据库。没有UI、依赖或数据库schema变化。

### 未执行

Docker/Compose运行与镜像构建、实际PG18/NAS初始化和重启/升级、备份恢复及设备联调为NOT_EXECUTED（本机无Docker及目标设备访问）；本地Go/文件系统测试不能代替这些验收。工作区未提交/推送/发布，线上latest是否含本批功能未核实；必须发布对应镜像后才使用无手填密钥模板。

全显式旧部署继续沿用原环境变量，不自动写入密钥文件，也不能删除后对旧库重新生成。新部署的./data/secrets.json须与数据库配套备份；现有.env运维脚本并未在本批扩展成该单文件模板的完整灾备流程。AI_CONTEXT长期事实建议在发布/设备验证后补充此部署约定。

## 2026-11-09：五入口重构与紧凑家居环境

范围：用户已确认V2原型与紧凑环境摘要，授权实现。工作区开始只有本会话两版未跟踪的mockups，无其他业务未提交修改。未连接用户真实库存/NAS/HA/模型，未提交推送或发布。

### 已执行

- `git diff --check`：PASS。
- 临时 `tree-sitter==0.25.2` + `tree-sitter-dart==0.1.0`，安装于 `/private/tmp/momobox-implementation-syntax`，未加入项目依赖；对 `lib/` 与 `test/` 全部206个Dart文件语法解析：PASS，0解析错误。
- 相对import/export路径检查：PASS，0缺失路径。
- 源码接线复核：默认`/`、`/assistant`独立页、五入口/宽屏侧栏一致；原库存/采购/AI确认与typed HA控制复用，实体仍经NAS授权；公共天气从城市选择显式启用，室内不使用天气回退；配置沿用ha_备份排除，未增加schema/依赖。

### NOT_EXECUTED

- `flutter analyze`、`flutter test`、Android/iOS构建、Flutter实际渲染/截图：本机无Flutter/Dart；旧临时SDK与pub缓存已丢失。官方存储和Flutter中国镜像发布清单curl均返回404；官方git浅克隆持续无完成进展后停止，ls-remote出现RPC/partial transfer失败。没有系统安装或变更项目依赖来绕过。
- 新增service/card测试、现有移动端/AI/库存/导航/设置回归尚未运行。后续入口为 `flutter test test/application/home_environment_service_test.dart test/presentation/home_environment_card_test.dart test/presentation/` 与 `flutter analyze`；应先按CI入口`flutter pub get`、Drift build_runner，再验证。
- Open-Meteo城市/天气真实响应、HA传感器/混合来源/权限变更/离线恢复、真实触屏与读屏：未联调。
- 本会话HTML效果图是已确认设计参考，不能用作本次Flutter代码运行截图或设备验收。

实现已经落盘，运行验收仍待完成。临时解析器只证明语法，不能证明Flutter API兼容、布局无溢出或业务用例通过。

## 2026-11-09：旧 UI 删除与引用迁移

范围：用户明确要求删除无引用的旧 UI，并将有引用的旧代码迁到当前设计后删除。开始时 `HEAD=9c7e7c1`，工作区干净；本记录仅针对本轮未提交改动，不代表远端 CI 或安装包结果。

已完成源码调整：独立 `AssistantScreen` 取代旧弹层与展示分支；删除不可达混合计划卡片、`/profile` 重复路由、演示场景状态/卡片及旧模拟家居仓库；页面和测试迁至 `momo_components.dart`，去掉卡片磨砂/皮肤覆盖分支。页面颜色统一使用 Theme，皮肤色样与用户偏好保留。没有数据库、后端 API 或依赖变化。

### 已执行

- Dart tree-sitter语法解析：PASS，`lib/`、`test/` 共205个文件，0解析错误。
- 项目内相对及 `package:momo_box/` 的 import/export/part 目标检查：PASS，共955处，0缺失。
- 从 `lib/main.dart` 按导入/导出/part 扫描：32个 presentation 文件均可达；私有 Widget 方法未发现仅有声明的符号。文件可达不等于每个运行分支都经过实机验证。
- 对 `lib/`、`test/` 搜索已删除的助手类型/文件、混合计划类型/状态/回调、`fullPage`、旧共享组件类型/文件、`frosted`、`SmartScene`/场景字段、旧模拟仓库、`/profile` 和 `inventoryIcon`：0残留引用。
- 差异复核与 `git diff --check`：PASS。历史设计稿和审计材料保留，不作为运行代码。

### NOT_EXECUTED

- Flutter analyze、Widget测试、Android/iOS构建、运行截图和真机视觉验收：本机Flutter/Dart不在PATH；已配置的 `/private/tmp/momobox-audit-toolchains/flutter` 及此前临时Flutter目录均没有SDK可执行文件。本轮未安装工具链或新增依赖。
- 已迁移会话/在途回复/库存确认/导航/深色/视口测试；离页重开用例增加会话ID与数量不变断言，场景边界改用真实控制器覆盖今日/家居的scene/script，卡片测试检查Theme颜色、语义及不叠加模糊。这些是测试源码变更，尚未运行，不能称测试通过。
- 后续按CI先执行 `flutter pub get`、`dart run build_runner build --delete-conflicting-outputs`，再执行 `flutter analyze`、`flutter test test/presentation/`。本轮没有提交、推送或发布。

## 2026-11-09：修复 GitHub 构建 #87 的静态检查阻塞

通过 GitHub 插件读取工作流 run `42589831158`（#87，提交 `a2b9a85246e03086eeda2cb6469b9db989cbdc14`）及 job `129068655894` 日志。当前本地HEAD与该提交一致，开始时工作区干净。失败步骤为 `flutter analyze`，报告4处 `curly_braces_in_flow_control_structures` 和1处 `deprecated_member_use`；Unit tests、Android debug、release打包与发布均跳过。该提交的iOS unsigned build和后端检查通过，不代表本轮修改的验证结果。

- 修复：`home_environment_service.dart` 两处、`home_environment.dart` 一处及 `providers.dart` 一处多行if补显式块；`environment_settings_screen.dart` 的 `DropdownButtonFormField` 改用 `initialValue`，保留原选择值、key与回调。不改业务条件、UI布局、依赖或检查门禁。
- 已执行：全205个Dart文件tree-sitter语法解析PASS，955处本地import/export/part目标检查PASS；4处诊断对应if均已核对为块结构，弃用参数已替换；`git diff --check` PASS。
- NOT_EXECUTED：本机Flutter/Dart不在PATH，未执行Flutter analyze/test/build，未重新运行GitHub工作流；不能据此宣称安装包已通过。本轮未提交、推送或发布。

## 2026-11-10：修复 GitHub 构建 #88 的测试阻塞

通过 GitHub 插件读取 run `42591532343`（#88，提交 `a7226950198e57f94f15e9c34eeb8cc51a0dcc29`）及 Flutter job `129074245829` 日志。当前本地HEAD与该提交一致，开始时工作区干净。此提交静态分析已通过，测试结果为989通过、19失败；Android debug、release打包与发布均跳过。iOS unsigned与后端检查通过，仅代表该提交。

| 失败组 | 数量 | 根因与本轮调整 |
| --- | --- | --- |
| 公共天气缓存/失败保留 | 2 | mock响应以String构造且没有JSON UTF-8编码信息，`°C`成为Latin-1字节，被生产端严格UTF-8解析拒绝。测试改用显式UTF-8 bytes与JSON header；生产解析和失败语义不放宽 |
| 助手离页在途回复 | 1 | 系统返回及单次大步pump未可靠完成页面退出。测试直接pop页面并等待逆向转场，明确断言页面消失前后请求仍在途，会话ID/数量与持久回复断言保留；系统返回规则仍由独立回归负责 |
| 宽屏导航语义 | 1 | 旧测试强制原生NavigationRail具有button标志，与当前Flutter原生语义不符。改检验真实tap语义动作，保留目的地序号/选中态与布局占位断言 |
| 未分区设备 | 1 | 旧三房间布局要求不显示该设备，已被AC-036的真实房间分组替代。改验卡片存在并发送typed turn_on、以匹配回执刷新状态 |
| 设备详细控制入口 | 11 | 测试helper点击已删除的tune按钮，新版由卡片本身打开。改为真实点击卡片名称并检查可命中，仍执行原零亮度、权限/超时/错配、撤权/登出/控制器替换与真实回执断言 |
| scene/script错误投影 | 2 | 实际实现缺陷：只排除了sensor/weather，仍把scene/script变成disabled开关。设备投影改为已支持类型白名单（light/switch/climate/media_player/washer）；原实体/权限/环境读取保留。相关测试增加投影为空检查，控制白名单不扩展 |
| 首页入库入口 | 1 | 展开服务状态后，点击坐标在屏幕上方。明确使用首页主ScrollView向上滚动、等待布局帧并检查hitTestable，再真实点击入库；保留唯一入口与原库存流程断言 |

已执行：205个Dart文件tree-sitter语法解析PASS，955处项目内import/export/part目标存在性检查PASS，`git diff --check` PASS。未增加项目依赖、配置键或数据迁移；界面调整仅为剔除不支持的实体开关，没有恢复旧布局/按钮或移除业务断言。复核CI所用Flutter提交的NavigationRail源码，其目的地Semantics设置selected并由InkResponse提供tap，不强制button标志。

NOT_EXECUTED：本机Flutter/Dart不可用，CI同版本 `3.47.9` macOS arm64官方归档探测返回404，未安装工具链；未运行Flutter analyze、相关测试或Android打包，未触发新远端运行。因此本条是日志定位与源码修复记录，不是19项回归已通过的证明。后续按现有CI运行 `flutter analyze`、`flutter test --coverage --reporter expanded`，通过后继续Android构建。本轮未提交、推送或发布。

## 2026-11-10：V2实际页面修正与Flutter渲染

基于 `2f7ceb98e5ce1cbc6fb20d8061722f8a3274a41b` 之后的未提交修改。设计差异和实际修正见DESIGN第39节；以下只覆盖当前本地源码，不扩展成已安装0.12.89或远端Actions的结果。

官方SDK归档仍不可达，改为从Flutter官方stable源码及其engine pin下载Dart/测试引擎，全部置于 `/private/tmp/momobox-v2-toolchain/`，依赖缓存为 `/private/tmp/momobox-v2-pub-cache`。临时源码SDK的Git引导记录不是上游commit。使用官方Flutter工具入口及 `--no-version-check` 直接执行，绕过可选远端更新检查。工具显示Flutter3.47.9、Dart3.13.7；未新增产品依赖，pubspec/lock无变化，未修改系统PATH。

| 检查 | 本地结果 | 证据边界 |
| --- | --- | --- |
| `flutter pub get` | PASS | 现有锁定依赖解析成功，未升级锁文件 |
| `dart run build_runner build --delete-conflicting-outputs` | PASS | 400个生成输出；当前builder提示该旧选项已移除并忽略，不影响生成结果 |
| `flutter analyze --no-pub` | PASS | No issues found |
| `flutter test --no-pub --reporter expanded` | PASS | 1011项通过；包含库存/批次/提醒/AI会话/权限/回执及同步回归 |
| 手机视口与字号 | PASS | 320/390/430竖屏、844横屏，1/1.3/3.4字，深浅色；末项避让和逐级返回保留 |
| 五页Flutter实际渲染 | PASS | 10张生产页面截图+2张总览，测试数据、Noto CJK字体，非HTML原型；不是安装包/现场设备截图 |
| 差异空白与workflow YAML | PASS | `git diff --check`、Ruby YAML读取通过；不是远端CI执行 |
| Android/iOS构建与安装 | NOT_EXECUTED | 本机无Android SDK/完整Xcode；没有新APK |
| 新增远端CI截图步骤、发布 | NOT_EXECUTED | 未提交/推送/发布 |
| 真实NAS/HA/公共天气/AI、系统键盘/读屏 | NOT_EXECUTED | 不用测试fixture或本地渲染替代 |

运行中发现并修正：环境来源按钮大字号溢出、原型只包图标的Dock选中态、关注行说明拥挤，以及旧测试用图标定位发送按钮/旧提醒文案/旧设置层级/滚动后未等待新布局的问题。新增真实房间筛选回归；保留库存数量、真实控制回执、会话归属、发送失败和操作确认断言。最终全量运行为1011通过，无剩余失败。

可复核文件：`validation/2026-11-10-ui-v2/README.md`、全部PNG、`source-sha256.json` 和 `verification.txt`。源码哈希记录UI/测试/workflow对应状态；截图中读数、商品和HA连接状态均来自明确隔离fixture。新增CI在测试之后、Android打包之前渲染并上传 `momobox-ui-<commit>`，仍需在实际新提交上确认远端结果；截图artifact本身也不是视觉相似度自动验收。
## 2026-11-10：容器自动初始化与后续迁移

基于 `0e06485d50a2f4353a7bce428a33c992d8e849bf`，启动时工作区干净。用户要求镜像内部自动判断首次部署并初始化，后续沿用数据。新增默认 `start` 入口（Dockerfile CMD），继续保留root、现有ENTRYPOINT及人工维护命令；Compose没有新增命令或服务。对应 REQUIREMENT AC-039 / DESIGN 第41节。

实现：持久化密钥沿用现有逻辑；数据库准备复用原迁移器、advisory transaction lock和单版本事务，成功后才进入serve及其只读校验。自动模式拒绝非空无台账库、空台账掩盖旧表、迁移历史缺口/未知版本/名称或checksum异常。真实回归发现并修正outer-transaction处理遗漏行注释后的空行，防止SQL内部COMMIT提前结束runner事务；既有SQL文件及checksum未修改。

| 验证 | 结果 | 范围与证据 |
| --- | --- | --- |
| 全量Go + 真实PG16.4回归 | PASS | 237个顶层测试，含子测试525项通过；0失败、0测试跳过。显式MOMO_TEST_DATABASE_URL指向本机随机端口、隔离临时实例，新增回归在随机新库执行原始10个迁移；包含并发初始化、数据保留、预装pgcrypto、search_path覆盖、无台账拒绝、失败事务回滚/恢复和异常checksum |
| CLI start端到端烟测 | PASS | PostgreSQL非超级用户（无CREATEDB/CREATEROLE）拥有专属空库，production模式首次start→10条迁移记录→HTTP health 200；SIGTERM后重启仍保留测试用户及完全相同的secrets.json字节，权限0600；台账checksum损坏后非零退出且未监听HTTP |
| go vet ./... | PASS | 使用项目go.mod既有依赖，没有新增依赖或锁文件变化 |
| Linux构建 | PASS | Go1.22.8，CGO_ENABLED=0，linux/amd64和linux/arm64，实际后端二进制构建；不等于容器运行 |
| NAS发布资产回归 | PASS | python3 scripts/ci/test-nas-release-assets.py，1项通过 |
| gofmt及差异空白 | PASS | 本次修改Go文件已gofmt；git diff --check通过 |
| Docker镜像构建/运行、PG18、UGOS/NAS现场 | NOT_EXECUTED | 本机没有Docker；临时PG16.4验证不能替代用户现有PG18和NAS挂载权限验收 |
| 本批次远端CI、推送与发布 | NOT_EXECUTED | 本次代码未提交/推送，已发布v0.12.91不包含本次start入口；固定旧digest不会自动更新 |

本机工具链：官方Go1.22.8归档经官方SHA256校验后解压到 `/private/tmp/momobox-go1.22.8`，既有模块缓存放 `/private/tmp/momobox-go-work`；当前macOS拒绝该旧版Go内部链接器生成的Mach-O（missing LC_UUID），本机测试使用 `go test -ldflags=-linkmode=external -count=1 -json ./...`。未改项目CI或Linux链接方式。初次沙箱内HTTP测试因禁止bind失败，放开本机测试监听后全量通过，不删除相关测试。

PostgreSQL16.4源码经官方SHA256校验，编译到 `/private/tmp/momobox-pg16` 并启用pgcrypto；临时cluster只监听127.0.0.1随机端口，测试结束已经停止，没有安装系统服务或连接NAS。完整Go/PG JSON事件日志 `/private/tmp/momobox-autostart-postgres-tests.jsonl`，CLI/PG启动日志及临时数据目录 `/private/tmp/momobox-autostart-pg-rremn1p8`；临时证据不视为长期存档。没有修改真实数据库、现有密钥或应用UI。
## 2026-11-11：统一默认端口18473

基于 `067f2993ae3b2b9634b79cbcc91c32c9b5fd10d1` 干净工作区，按用户要求将后端默认监听地址及Docker EXPOSE改为18473，四套Compose的HTTP_ADDR、映射右端及默认宿主端口同步调整为18473；三套.env示例、部署指南和手机NAS地址示例同步更新。健康检查沿用同一HTTP_ADDR，没有新增产品依赖、数据迁移或密钥变更。

- PASS：`go test -ldflags=-linkmode=external -count=1 ./internal/platform ./tests/platform ./cmd/momo-backend`（Go1.22.8，临时工具链/缓存）；相关配置、服务及HTTP生命周期回归通过。此轮未设置MOMO_TEST_DATABASE_URL，Go套件内PG回归为skip，不称全量真实PG通过。
- PASS：`go vet ./...`；macOS后端可执行文件构建。
- PASS：独立PG16.4实例和非超级用户专属空库烟测：不设置HTTP_ADDR，实际start日志监听 `0.0.0.0:18473`，访问该端口health返回200，内置healthcheck退出0。测试后后端及临时PG均已停止；证据 `/private/tmp/momobox-port18473-pg-x7bufasy`，未连接NAS数据库。
- PASS：四套Compose经Ruby YAML解析并核对HTTP_ADDR、映射目标端口、内置healthcheck一致；`python3 scripts/ci/test-nas-release-assets.py` 1项通过；`git diff --check`。
- PASS：两处修改的Dart文件使用现有SDK分别执行 `dart analyze`，均No issues found。初次分析器缓存目录写入被沙箱拒绝，改用官方支持的ANALYZER_STATE_LOCATION_OVERRIDE放入/private/tmp后成功；未修改系统HOME或安装工具。Flutter包装入口卡在工具自身pub解析后已停止，不作为Flutter全量analyze/test通过。
- NOT_EXECUTED：Docker镜像构建/运行、PG18与NAS现场、Flutter测试/打包、远端CI/推送/发布。本轮代码尚未发布；已发布镜像可通过HTTP_ADDR显式覆盖端口，但更新现有NAS项目仍需同步调整映射并重建容器。既有App连接URL不自动改写。

## 2026-11-11：NAS 注册反馈与 HA 家庭身份

用户反馈注册密码不合要求后弹窗退出且需重填，以及HA提示需要已认证家庭成员。本轮修复仅移动端注册/登录表单、家庭令牌更新、HA配置前置引导和错误说明；没有后端、数据库、依赖或现有密码变更。需求/设计见REQUIREMENT第25节和DESIGN第43节。

- PASS：`flutter analyze --no-pub`，全项目No issues found。修正新增测试三处花括号lint后最终通过。
- PASS：`flutter test --no-pub --reporter expanded` 指定10个相关测试文件，176项全部通过：nas_auth_dialog_test、nas_setup_flow_test、nas_ha_session_test、nas_account_session_test、nas_api_client_test、nas_auth_service_test、nas_smart_home_repository_test、ai_assistant_review_test、home_ha_quick_actions_test、settings_hierarchy_test。
- 覆盖：12字符/72字节、中文/emoji边界、昵称限制及登录不套用注册长度；提交前显示要求、本地校验不发请求、服务端/异常失败保留输入、显示密码状态保留、重试成功关闭、请求中禁用重复提交及返回；创建/加入家庭的刷新成功和失败、刷新前阻断HA、更新后的令牌用于成员/设备/HA、旧会话迟到响应拒绝；未加入家庭时零HA请求、前往NAS设置、member禁用配置、owner可配置，以及原设备权限/控制回执/设置层级回归。
- PASS：`git diff --check`。
- 工具：复用 `/private/tmp/momobox-v2-toolchain/flutter-stable` 的Flutter3.47.9 / Dart3.13.7和既有pub缓存，直接运行flutter_tools.dart及其已有package_config，绕过包装入口的工具pub解析。工具临时配置使用XDG_CONFIG_HOME=/private/tmp/momobox-auth-config，分析缓存放/private/tmp。首次沙箱执行被工具缓存写入及127.0.0.1测试监听权限阻止；允许工具正常运行后取得上述结果，没有修改产品依赖或系统PATH。完整日志 `/private/tmp/momobox-auth-final-tests.log` 与 `/private/tmp/momobox-auth-analyze.log`。
- NOT_EXECUTED：Android/iOS打包与安装、系统键盘/读屏、真实NAS注册及HA联调、远端CI/推送/发布。MockClient只验证协议和状态，不能证明现场连接成功；现有安装包仍需后续更新。

## 2026-11-12：同步初始化401刷新循环与设备令牌绑定

从main 780fa12干净工作区修复用户现场conflicts 401→refresh 200循环。设备注册未写入JWT DeviceID，以及整份account观察导致token刷新销毁同步组件，是本次源码定位与回归复现的两个问题。范围见REQUIREMENT第26节、DESIGN第44节及NAS API/安全契约。

- PASS：Flutter3.47.9下 flutter analyze --no-pub 全项目No issues found；修正新增多行分支花括号后通过，未关闭lint。日志 /private/tmp/momobox-sync-analyze347-final.log。
- PASS：Flutter3.47.9下9个相关测试文件共137项全部通过：nas_device_session_test、sync_workspace_provider_test、nas_auth_service_test、nas_account_session_test、nas_ha_session_test、nas_setup_flow_test、nas_sync_api_test、sync_settings_screen_test、sync_scheduler_test。日志 /private/tmp/momobox-sync-tests347-final.log。
- 覆盖：新注册/已保存设备等待绑定刷新才ready；绑定拒绝清除无效会话；显式绑定排在已有刷新后使用轮换后的token；一次401只刷新一次，重试成功或再次401均不重建workspace identity/API/engine/import service；真实同步设置Widget在持续401后额外通知/多帧仍只有2次conflict请求和1次refresh；切NAS/账号/家庭使旧会话失效，原冲突结算、游标、数据归属及调度回归保留。测试HTTP是隔离MockClient，不是现场NAS证据。
- PASS：Go1.22.8下 go test -ldflags=-linkmode=external -count=1 ./... 全量后端回归；go vet ./...。全量运行未配置MOMO_TEST_DATABASE_URL，既有PG opt-in测试skip，不能称全量真实PG通过。日志 /private/tmp/momobox-sync-go-all.log、/private/tmp/momobox-sync-vet.log。
- PASS：真实PostgreSQL16.4下 go test -ldflags=-linkmode=external -count=1 -v ./internal/store/authpostgres，5个顶层测试通过，含新增真实SQL回归。随机schema执行原始0001 migration（仅改search_path并省略共享pgcrypto安装），首次无device刷新记录→合法当前设备绑定→普通轮换成功；SQL列表排除其他账号/家庭设备，轮换拒绝外部/未知设备；设备撤销后绑定失败回滚，原未绑定session不被消费，无替代token落库。随机schema已删除，临时实例仅监听127.0.0.1随机端口且已停止；未访问NAS/正式库。日志 /private/tmp/momobox-sync-device-pg-final.log。
- PASS：新增Go文件与修改的生产Go源gofmt、git diff --check，OpenAPI YAML可解析。没有新增产品依赖、schema、migration或既有业务数据变更。
- 工具边界：原/private/tmp工具链已清理，临时重建官方源码/engine。先用当前stable源码（engine371f772）复现，137项通过但其新Material废弃提示不计入最终基线；最终改用官方3.47.9标签源码、engine89c39edf及Dart3.13.7。归档无Git元数据，临时SDK内创建仅供工具启动的本地Git/tag标记，不是官方framework commit或业务提交。Go与PG归档已校验官方SHA256；未安装系统软件或修改系统PATH。
- 恢复工具链期间临时解析曾选择vector_math2.4.4；补齐原2.4.2缓存后，最终离线解析保持原pubspec.lock无差异，并按原锁文件组合重跑137项测试及全项目analyze通过。没有产品依赖升级。
- NOT_EXECUTED：Android/iOS打包与安装、真实NAS/PG18同步、实际App与后端联调、远端CI/提交/推送/镜像及APK发布。本修复需更新App和NAS后端；旧后端不接受新增device_id时App显示更新提示，不把设备标为同步ready。

## 2026-11-12：NAS AI 诊断与 HA 首次实体授权

基于含前序未提交 NAS 注册、家庭身份和设备刷新修复的工作区，新增NAS处理模式的AI可操作错误分类，并修复HA保存后未发现实体及管理员无法查看未授权实体来配置白名单的问题。新增 owner/admin 专用家庭实体目录接口；目录省略状态/时间且不授予任何权限。实体查看和typed command仍经过原服务端授权。需求/设计见REQUIREMENT第27节和DESIGN第45节。

- PASS：Flutter 3.47.9 `flutter analyze --no-pub` 全项目无问题，日志 `/private/tmp/momobox-aiha-analyze-final.log`。
- PASS：8个AI/HA相关Flutter测试文件共154项通过，涵盖NAS模式无AI配置提示、NAS错误分类与敏感信息剔除、未知结果不重试、HA保存后自动发现/发现失败重试、首次目录只读且无状态、显式权限授予前无状态读取、按角色授权、关闭查看时同时撤销控制与命令、角色切换及既有AI工作流/HA命令权限回归。合并回归日志 `/private/tmp/momobox-aiha-tests-final.log`，新增授权Widget回归 `/private/tmp/momobox-aiha-permissions-widget2.log`。
- PASS：`go test -ldflags=-linkmode=external -count=1 ./...` 全量Go后端测试；新增目录服务、HTTP路由和权限不隐式授予回归。日志 `/private/tmp/momobox-aiha-go.log`。针对HA包、HTTP与入口的再次运行也通过，见 `/private/tmp/momobox-aiha-go2.log`。运行未提供 `MOMO_TEST_DATABASE_URL`，opt-in真实PG用例不代表PG验收。
- PASS：`go vet ./...`、`git diff --check`、OpenAPI YAML解析。
- NOT_EXECUTED：Android/iOS构建安装、0.12.94或新包设备验证、真实NAS/HA发现及权限操作、部署新后端镜像、NAS环境AI提供商测试、远端CI/发布。新HA目录端点需要更新NAS后端；本地Mock和编译测试不证明现场设备/模型连通。

## 2026-11-12：修复 GitHub run 95 的 Flutter 打包门禁

通过 GitHub 插件读取 run `43171543730`（run #95，提交 `60b0ddd3d0d8d12476436ed8b084a645cb418670`）的 Flutter job `131025957971`。GitHub Actions 的 `stable` 已自动解析到 Flutter 3.50.0；`flutter analyze` 把全项目 67 处旧 `package:flutter/material.dart` 等迁移提示列为 `info`，严格 lint 失败。测试、UI截图和 Android debug / release APK/AAB 构建因此没有执行；截图上传又因前置渲染被跳过、文件不存在而产生次生失败。run #94（提交 `780fa12`）同一 workflow 成功，当时使用 Flutter stable 3.47.9。

- 修复：分析、iOS及release构建三个Flutter job均固定Flutter 3.47.9，匹配最近完整成功的Actions基线及本机工具链。截图上传仅在截图生成成功后执行，避免未生成文件的次生失败。没有屏蔽 analyzer 诊断、改 lint 级别或尝试迁移67处全局Material API。
- PASS：Flutter 3.47.9 `flutter analyze --no-pub` 全项目无问题；`scripts/ci/test-prepare-flutter-platforms.sh`；workflow YAML解析；`git diff --check`。
- NOT_EXECUTED：本次修改后的 GitHub Actions、Android debug/release APK/AAB和 iOS build 均未运行。需要新 commit 触发 CI 后确认正式构建；上一次失败 run 内 APK构建步骤是 skipped，不是原生打包器报错。

## 2026-11-13：同步200忙循环、今日页滚动与环境刷新

基于HEAD `8c2b907`，继续本会话未提交的同步修复，并纳入今日页频闪/跳顶、HA环境来源、公共天气地名和刷新反馈。实现与边界见REQUIREMENT第28节、DESIGN第46节。本次只改App与文档，没有后端协议、产品依赖或数据库迁移。

- PASS：Flutter3.47.9 / Dart3.13.7 `flutter analyze --no-pub`，最终全项目No issues found，日志 `/private/tmp/momobox-sync-env-analyze-final.log`。
- PASS：`flutter test --no-pub --reporter expanded` 全套1054项通过，退出0，日志 `/private/tmp/momobox-sync-env-all-tests.log`。复用现有临时SDK和锁文件缓存，使用flutter_tools.dart入口；没有安装工具或修改pubspec.lock。工具需要临时缓存写入与127.0.0.1测试监听，按现有验证方式在允许环境运行。
- 覆盖同步：真实Drift内存库内部设置写入后归属/API/engine/首次导入服务不替换；真实engine两轮成功pull不误报会话失效；一次401刷新重试界限、切NAS/账号/家庭旧API阻断、原冲突结算/游标/库存/退避保护；新同步入口自动准备设备、仍显示归属确认和空家庭三种模式且不自动选择。原9文件相关回归197项通过后，再纳入最新设置去重/今日页测试完成全套1054项。
- 覆盖今日页：真实HomeScreen、真实库存Provider/内存库、MockClient NAS成功请求，先向下滚动再连续三轮同步并写内部告警及轮换token；断言ScrollState身份、滚动位置、库存Repository、模块顺序、engine不变，pull恰三次且API仅创建一次。单文件最终复验日志 `/private/tmp/momobox-today-scroll-test3.log`，也包含在完整回归中。无真实NAS或手机访问。
- 覆盖环境：已授权无device_class模板温度可选择/读取；电量百分比、不兼容类型、未授权实体不冒充温湿度；分钟刷新同城保留旧读数、城市切换立即清旧、HA权限撤销清读数、前台HA刷新与后台跳过；10分钟自然到期重取、并发合并、原数据时间保留、失败旧数据明确过期；精确重复地名消重，成都市/吉安市/达州市/阿坝州可区分，坐标及类型可见；原窄屏/大字与HA typed control回归保留。视觉fixture仅适配Provider类型，没有降低断言。
- 初始新增测试曾因UTF-8夹具错误、缺少NAS处理guard配置、Widget/Drift不同事件循环等待及pump回调内expect冲突失败或中断；逐项修正夹具/等待方式后全套通过，没有屏蔽诊断、放宽超时或删除生产能力。
- PASS：`git diff --check`。公开地名接口只读核对成功，仅发送“成都”；未发送用户账号/令牌、手机定位或请求用户NAS。地名接口记录不构成行政地理真实性证明。
- NOT_EXECUTED：Android/iOS构建安装、真实NAS/HA/PG18联调、设备滚动/生命周期验收、镜像/APK发布及新远端CI。本轮未提交、推送或部署；当前已安装版本不含这些改动。修复不要求清库、重建家庭或更换用户密钥。

## 2026-11-13：NAS必选、自动接入与服务端模型目录

基于本轮开始时的HEAD `fb9a590`，按用户确认取消独立单机运行；首位使用者创建家庭、后续成员凭邀请码加入，NAS不可达时查看原归属缓存，恢复自动同步。需求/设计见REQUIREMENT第29节、DESIGN第47节。当前为未提交源码实现，无现场部署或发布。

- PASS：Flutter 3.47.9 / Dart 3.13.7 全项目 `analyze --no-pub` 无问题；完整 `test --no-pub --reporter expanded` **997项全部通过，退出0**。日志 `/private/tmp/momobox-nas-required-final-analyze.log`、`/private/tmp/momobox-nas-required-final-tests.log`。复用现有隔离临时SDK及缓存，未安装系统工具；移除本地OCR/压缩包后离线pub解析成功，没有新增产品依赖。
- 覆盖NAS接入：首次自动建家庭/设备/工作区/远端模式；受邀成员不再建家庭；无邀请码止步；归属错误不改绑；会话切换的迟到任务不能写完成标记；退避/冲突/未完成分页不冒充首轮完成。设置通知/令牌续期不重建同步链路的既有回归继续保留。
- 覆盖缓存与UI：强制连接页在实际MaterialApp.builder层级拥有登录/恢复导航；320px和2倍文字下长错误可滚动并进入诊断；连接/缓存切换保留业务滚动状态。缓存读取校验安全存储用户、endpoint、原家庭及完成标记；登出不再放行。持有的旧库存Repository、采购/家务/附件/备份导入及HA命令均有即时写入检查；离线不初始化家务预设。设备列表暂时503后自动重查并登记，被撤销设备不重新激活。
- 覆盖AI/备份：手机仅发送NAS认证、文字及所选模型别名，无直连地址/Key/工具；返回格式及错误分类、未知结果不重试、模型选择隔离；一次性清理已停用手机AI配置/Key，业务资料和聊天保留。JSON导出和v1-v3历史导入过滤已停用配置，保留条码配置脱敏、引用校验、全事务回滚和目标身份。恢复完成接回自动同步。删除的测试仅对应已停用本地OCR、手机服务编辑器/协议降级及手动初始化确认，新增NAS路径回归；没有skip、屏蔽lint或降低冲突/权限断言。
- PASS：后端 `go test -ldflags=-linkmode=external -count=1 ./...` 全量基础回归，新增网关目录/别名允许列表/默认模型，以及HTTP目录的匿名、缺家庭、缺设备和授权访问、敏感配置不下发。日志 `/private/tmp/momobox-nas-only-final-go-unit2.log`；运行未设置MOMO_TEST_DATABASE_URL，既有真实PG opt-in不计为数据库通过。
- PASS：真实隔离PostgreSQL16.4下 `go test -ldflags=-linkmode=external -count=1 -v ./internal/store/familypostgres ./internal/store/authpostgres`。8个顶层用例通过，其中新增真实家庭/注册事务及既有设备刷新SQL回归。覆盖并发首家庭幂等、首账号限制、后续非成员拒绝无邀请码初始化、邀请注册member归属、重复邮箱不消耗次数、无效邀请不残留账号；原刷新设备授权回滚保护保留。随机schema清理，临时服务已停止，无NAS/正式库访问。日志 `/private/tmp/momobox-nas-only-final-pg-onboarding.log`。该夹具仅复用初始schema并补所需time_zone，不是全量迁移验收。
- PASS：`go vet ./...`、Linux amd64后端编译；`scripts/ci/test-prepare-flutter-platforms.sh`（移除MLKit注入后）；NAS发布附件1项与变体19项脚本回归；9份YAML解析、OpenAPI本地ref解析及 `git diff --check`。日志分别在 `/private/tmp/momobox-nas-required-final-vet.log`、`momobox-nas-only-final-linux-build.log`、`momobox-nas-only-final-platform.log`、`momobox-nas-only-final-assets.log`、`momobox-nas-only-final-variants.log`。
- 开发中失败与修正：早期Flutter用例在本机OCR/手机配置入口删除后迁移到NAS协议；Widget数据库关闭、清理设置枚举和初始化绑定通知先后顺序曾失败/中断，修正后通过。收尾全量曾有两处旧“手动注册设备”提示断言失败，按新自动连接文案更新，保留401次数和冲突断言；格式化导致的多行分支lint补花括号，没有关闭规则。
- 环境限制：曾向全后端测试提供临时PG URL，已有 `TestAutomaticStartupPostgresInitializesOnceAndPreservesData` 因该精简PG缺少pgcrypto扩展失败（SQLSTATE 0A000）。未安装扩展或修改测试掩盖失败；基础全量与本次真实PG事务分别通过，不能声称全量PG启动/迁移验收通过。系统Python没有PyYAML，改用已有Ruby YAML库完成配置解析，未安装依赖。
- NOT_EXECUTED：Android/iOS打包、安装与真机生命周期；Docker/UGOS、PG18完整部署迁移、真实LiteLLM/AI/OCR/HA、NAS断网重启与双手机端到端；远端CI、Git提交/推送、APK与镜像发布。UGREEN模板保留旧固定digest，必须发布并明确更新镜像后才能使用新接口。没有本地/后端schema迁移或业务删库，旧资料重叠/归属不一致仍保守阻塞，跨家庭迁移不在本次范围。

## 2026-11-13：HA 授权跳动、物品密度、助手定位与家居状态

在包含前序 NAS 必选接入改动的未提交工作区实现用户四项 UI 修复。范围见 REQUIREMENT 第30节与 DESIGN 第48节；主要修改 assistant_screen、home_assistant_settings_screen、inventory_screen、smart_home_screen，新增 page_navigation_regression_test 并扩展 nas_setup_flow_test。没有新增依赖、后端协议、数据库迁移或业务数据删除。

- PASS：Flutter 3.47.9 / Dart 3.13.7 全项目 `analyze --no-pub` 无问题，日志 `/private/tmp/momobox-ui-navigation-analyze-final.log`。
- PASS：完整 `test --no-pub --reporter expanded` **1010项全部通过，退出0**，日志 `/private/tmp/momobox-ui-navigation-all-tests.log`。此前6个相关文件共158项通过，日志 `/private/tmp/momobox-ui-navigation-targeted-final.log`；随后补空白会话大字说明、真实视口夹具及格式/lint修正，以完整1010项为最终结果。
- HA：先以18个实体、6个展开行复现权限保存成功/失败后实体State被替换，原State已defunct。稳定key保留展开后，反馈/状态高度仍移动操作位置378～424px；补开关锚点偏移后通过。最终覆盖成功、失败及请求中主动滚动，断言展开状态身份、开关值、未主动滚动时屏幕位置相差不超过1px，以及不覆盖用户主动滚动。复现日志 `/private/tmp/momobox-ui-permission-before.log`、仅key日志 `/private/tmp/momobox-ui-permission-after.log`；最终完整回归包含全部修复与三种情况。HTTP为隔离MockClient，不访问真实HA。
- 物品：真实320/390逻辑像素视口下，分别检查1、2、6个同内容物品的首张卡片尺寸一致；单列72×72缩略图、双列96高图片，正常字号卡片保持紧凑。原移动端窄屏/横屏、深浅主题及最大3.4倍字回归保留。初始夹具只改setSurfaceSize，MediaQuery仍采用默认窗口尺寸，导致390px测试错误选择单列；改为匹配physicalSize和devicePixelRatio后通过，未弱化尺寸断言或修改生产断点。
- 助手：40条变长存档、末条35行超过一屏，进入/离开再进入均显示最新消息结尾，存档及当前会话保留；迟到加载也定位最新端，320×600和2倍字下空会话说明从顶部可见。原AI授权、草稿及操作确认回归通过。
- 家居：online/offline/stale/syncing/unconfigured五类状态保留徽章，均无“连接设置”“打开连接配置”按钮；既有环境与HA控制回执/权限测试通过。配置路径统一为“我的 → 家庭与连接”。
- PASS：`git diff --check`。复用已有隔离Flutter SDK和pub缓存，没有安装软件、升级依赖或更改系统PATH。首次analyze发现4处新增多行分支缺花括号，补齐后复验无问题，没有屏蔽lint。
- NOT_EXECUTED：Android/iOS原生打包、安装与真机触摸/读屏验收，真实NAS/HA权限操作和设备控制，远端CI、Git提交/推送及APK/镜像发布。Go/PG未在本UI批次重复执行，本批次没有后端修改；前节后端证据不作为此次新增运行结果。当前已安装App仍需更新后验证。

## 2026-11-13：设置去重、填充布局与通知 TypeToken 发布问题

基于包含前序修复的HEAD `e02d853`，处理用户本轮三项反馈。起始仅有未跟踪的包审查报告，保持原样；本轮没有产品依赖升级、数据库迁移、后端协议/服务或业务资料变更。需求/设计见REQUIREMENT第31节、DESIGN第49节。

- PASS：Flutter3.47.9 / Dart3.13.7全项目`analyze --no-pub`无问题，日志`/private/tmp/momobox-settings-notification-analyze-final.log`。首次新增多行if有1条花括号lint，补齐后通过，未关闭规则。
- PASS：完整`test --no-pub --reporter expanded` **1023项全部通过，退出0**，日志`/private/tmp/momobox-settings-notification-all-tests.log`。3个直接相关文件先通过31项，日志`/private/tmp/momobox-settings-notification-targeted2.log`。复用现有临时SDK、pub缓存及数据库夹具，没有安装软件或新增依赖。
- 设置：一级无“家居连接”，进入“家庭与连接”后唯一HA设置项仍可达，NAS/自动同步入口保留；既有设置层级、返回位置、主题回归通过。
- 布局：新填充夹具含长设备名/房间/状态、现场完整权限提示、耗材及采购建议。320/390px、1/2/3.4倍字下标题和HA徽章至提示至少12dp，保留全部内容及设备控件；灯光/空调/电视长内容弹窗可滚动至末端。最初回归记录了标题/提示仅2.5～5px的间隔；修正测试等待滚动布局后，确实捕获空调数值行62px横向溢出，修复Flexible/Wrap后通过。大字标题因惰性列表出视口而未挂载时，将标题和提示作为同一稳定布局块处理，没有删除几何断言或降低字号。过程日志`/private/tmp/momobox-settings-notice-layout-before.log`、`/private/tmp/momobox-settings-notification-targeted.log`；前者弹窗场景一度因测试滚动后缺少pump而未点中，不算产品弹窗异常证据。
- 通知：模拟与现场同类PlatformException和40行Java详情，320px、1/2/3.4倍字下无TypeToken/Java原文和全屏SnackBar，权限仍显示“已允许”、失败不产生计划，重试成功才排程并清除提示；不重复申请授权，发送测试提醒仍可触达。原确认过滤、迟到数据、卸载保护、前台恢复、测试通知不被取消等回归保留。异常经现有诊断只记录脱敏类型/来源。
- PASS：`scripts/ci/test-prepare-flutter-platforms.sh`，日志`/private/tmp/momobox-settings-notification-platform-final.log`。校验Groovy/Kotlin引用、具体Gson规则、两次生成仅一个管理块、自定义规则保留、原通知接收器/图标及平台补丁；bash语法、workflow YAML解析、Python验证器语法和`git diff --check`通过。
- 已核实旧包缺陷：复用已校验SHA256和ZIP CRC的实际v0.12.98 APK，逐class解析DEX。包含现场错误字符串的TypeToken类为`Lqa1;`、子类`Lu20;`，两者均没有dalvik.annotation.Signature；NotificationDetails持久化字段本身仍在。证据`/private/tmp/momobox-notification-release-before.json`。结合固定通知插件18.0.1源码的匿名TypeToken恢复路径及Gson官方要求，确定需补release保留规则。新增`verify-notification-apk.py`拒绝这个旧包（预期退出1），CI已在实际release APK构建/验签后接入检查，不仅检查ProGuard源文本或DEX是否出现某段字符串。
- NOT_EXECUTED：本机无Android SDK/JDK，**新规则经R8生成的新APK及其验证器通过结果尚未取得**；系统通知投递、开机恢复、旧计划跨版本恢复、Android/iOS安装及真实HA设备布局/控制仍待原生及现场验收。旧包验证器失败和Widget通过不代表新release包已经修好并验收。AAB/新远端CI、Git提交/推送、APK/镜像发布均未执行；本轮无Go改动，不重复后端测试。

## 2026-11-13：AI 目录故障提示与中性主题替换

基于HEAD `e02d853`及前序未提交修复继续工作，保护既有设置/家居/通知改动。用户随后确认现场原因是LiteLLM容器停止，启动后AI已可用；现场恢复不归功于本轮源码修改。需求/设计见REQUIREMENT第32节、DESIGN第50节。

- PASS：Flutter3.47.9 / Dart3.13.7全项目`analyze --no-pub`无问题，日志`/private/tmp/momobox-ai-catalog-analyze.log`。完整`test --no-pub --reporter expanded` **1030项全部通过，退出0**，日志`/private/tmp/momobox-ai-catalog-flutter-all.log`；直接相关4个文件38项通过，日志`/private/tmp/momobox-ai-catalog-flutter-targeted.log`。
- Flutter覆盖模型目录错误：NAS初始化未完成、旧后端404、上游拒绝Key、目录为空/格式错误、网关停止连接失败。携带模拟敏感正文的错误只显示静态安全提示和合法请求UUID；刷新再次调用Provider并恢复模型列表，旧错误消失，无手机地址/Key表单。旧主题值/旧AI建议转成sky，新执行持久化sky，主题色样/吉祥物与深浅色导航回归通过。
- PASS：Go1.22.8 `go test -ldflags=-linkmode=external -count=1 ./...`全量基础回归与`go vet ./...`；最终测试日志`/private/tmp/momobox-ai-catalog-go-final.log`，vet退出0无输出。未设置MOMO_TEST_DATABASE_URL，已有真实PostgreSQL opt-in仍跳过，不计为数据库验收。
- Go覆盖base/完整models/chat/responses URL、反代前缀、仅404/405有界目录兼容、URL+Key无默认模型、Key空白、去重/允许列表/固定模型兼容；网关401/403/404/503、重定向、HTML/缺data/null/无效data/超限/空列表/非法ID、超时及网络拒绝均有分类。实际本机HTTP重定向测试确认自定义client也不向新目标转发Key；HTTP错误码502/503/504及日志中的请求号与响应一致，不泄露URL/Key/上游正文。既有未知付费请求不自动重试测试继续通过。首次受限沙箱内Go环回端口被拒绝、Flutter启动退出255；允许本机测试所需环回后重新运行通过，未调整产品断言或关闭测试。
- PASS：NAS发布附件脚本1项回归、修改的Compose/OpenAPI YAML解析、`git diff --check`。UGREEN单文件模板仅把默认模型改为可选空值，固定旧镜像digest保留，未访问用户NAS或修改数据库/网络。复用已有隔离工具链，无新增产品依赖、schema迁移或业务资料删除。
- 资源检查：pubspec仅启用Material图标，无自定义角色图片资源；运行源码中角色旧标识仅剩两个兼容解析位置。蓝色主题改为晴空流云/云朵小云，樱花吉祥物改为花芽；历史设计稿、业务聊天和第三方许可未删除。此项是源码资源替换，不是法律授权审查或新APK资源验收。
- NOT_EXECUTED：新Android/iOS安装包及原生运行、Docker镜像构建、真实LiteLLM目录/推理、NAS项目与容器日志界面差异的现场验证、真实数据库/HA/多设备验收、Git提交/推送、远端CI及发布。新增提示/日志需App和后端更新后才生效；不宣称用户当前容器已运行本轮代码。
