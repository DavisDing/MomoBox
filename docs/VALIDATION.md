# 验证基线

## 原则

本项目开发机不安装 Flutter。所有编译、代码生成、静态检查和测试由 GitHub Actions 执行，Android APK/AAB 下载后在真实设备上进行安装验收。

## CI 验证

### Pull Request / 分支推送

`.github/workflows/flutter-ci.yml` 执行：

- Flutter stable channel；
- 运行平台壳补丁回归测试；
- Ubuntu job 安装 Android 17 SDK platform；macOS iOS job 在构建前确认 iOS 27 SDK 可用；
- 生成 Android/iOS 平台壳；
- 注入 Android API 36（`minSdk`）、Android API 37（`compileSdk`/`targetSdk`）和 iOS 27.0 deployment target；
- 注入本地通知权限、重启恢复 receiver、flutter_local_notifications Java 8 desugaring、通知图标保留和 iOS delegate；
- `flutter pub get`；
- Drift 代码生成；
- `flutter analyze`；
- `flutter test`；
- Android debug build；
- macOS 上的 iOS unsigned build。

### 默认分支发布

`.github/workflows/release.yml` 在 Conventional Commit 触发发布时执行：

- 运行平台壳补丁回归测试；
- 安装 Android 17 SDK platform，再生成 Android/iOS 平台壳并注入 Android API 36 minSdk、Android API 37 compile/target SDK、iOS 27.0 及本地通知平台设置；iOS 27 SDK 的实际构建验证由 Pull Request / 分支推送中的 macOS job 执行；
- 生成 Drift 文件；
- analyze/test；
- 构建 APK/AAB；
- 上传 APK、AAB 和 SHA256SUMS 到 GitHub Release。

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
12. 切换三套主题和系统深色模式；
13. 在 Android 16 与 Android 17 上分别使用手势导航和三键导航：确认状态栏、底部导航、浮动入库按钮及带键盘的入库表单均不被系统栏遮挡；在横屏或至少 840dp 宽窗口确认切换为侧边导航且四个页面都可访问；
14. 在 iOS 27 真机/模拟器上确认状态栏、底部安全区、表单键盘避让和系统深色模式正常；授予/拒绝通知权限后，确认库存核心仍可使用，且已授权时提醒能注册。

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
