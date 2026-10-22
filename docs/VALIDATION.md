# 验证基线

## 原则

本项目开发机不安装 Flutter。所有编译、代码生成、静态检查和测试由 GitHub Actions 执行，Android APK/AAB 下载后在真实设备上进行安装验收。

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

## 安装验收清单

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
