# 验证基线

## 原则

本项目开发机不安装 Flutter。所有编译、代码生成、静态检查和测试由 GitHub Actions 执行，Android APK/AAB 下载后在真实设备上进行安装验收。

## CI 验证

### Pull Request / 分支推送

`.github/workflows/flutter-ci.yml` 执行：

- Flutter 3.24.5；
- 运行平台壳补丁回归测试；
- 生成 Android/iOS 平台壳；
- 注入本地通知权限、重启恢复 receiver、Android desugaring、通知图标保留和 iOS delegate；
- `flutter pub get`；
- Drift 代码生成；
- `flutter analyze`；
- `flutter test`；
- Android debug build；
- macOS 上的 iOS unsigned build。

### 默认分支发布

`.github/workflows/release.yml` 在 Conventional Commit 触发发布时执行：

- 运行平台壳补丁回归测试；
- 生成 Android/iOS 平台壳并注入本地通知平台设置；
- 生成 Drift 文件；
- analyze/test；
- 构建 APK/AAB；
- 上传 APK、AAB 和 SHA256SUMS 到 GitHub Release。

## 安装验收清单

安装 Release APK 后按以下顺序验证：

1. 首次启动无需账号和网络；
2. 手动入库一件有到期日的物品；
3. 验证按天/月填写保质期后到期日正确；
4. 再次录入相同条码，确认形成同一商品的第二批次；
5. 打开商品详情，确认批次和变动历史可见；
6. 消耗库存，确认按 FEFO 扣减；
7. 补充、报废批次，确认库存和历史更新；
8. 添加采购项并勾选已购买，确认入库表单自动打开；
9. 授予通知权限，验证提醒计划可以注册；
10. 导出 JSON，在清空/新环境导入并检查数据；
11. 切换三套主题和系统深色模式。

## 结果记录规范

- CI 通过：`PASSED`，附 GitHub Actions run 链接；
- CI 失败：`FAILED`，记录失败步骤和日志摘要；
- 尚未执行：`NOT_EXECUTED`；
- 真机未验证：`DEVICE_VALIDATION_PENDING`。

## 当前本地验证记录（2026-09-01）

- `PASSED`：`bash -n scripts/ci/*.sh scripts/release/*.sh`；
- `PASSED`：`scripts/ci/test-prepare-flutter-platforms.sh`；
- `PASSED`：`scripts/release/test-next-version.sh`；
- `PASSED`：GitHub Actions YAML 可由 Ruby Psych 解析，且 `git diff --check` 无空白错误；
- `NOT_EXECUTED`：`flutter pub get`、Drift 代码生成、`flutter analyze`、`flutter test`、Android/iOS 构建（本机没有安装 Flutter/Dart）；
- `NOT_EXECUTED`：GitHub Actions 首次运行（变更尚未推送）；
- `DEVICE_VALIDATION_PENDING`：Release APK 真机安装验收。

首次推送后，应将 GitHub Actions run 链接和 APK 安装结果补充到本节，不能把未运行的 CI 或设备结果标记为通过。
