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
