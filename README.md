# MomoBox / 嬷嬷的小箱子

本仓库是「嬷嬷的小箱子」的 Flutter 客户端源码。产品采用**本地优先**架构：单机模式由 SQLite（Drift）作为离线数据源，NAS 同步、OCR、扫码和 AI 均不阻塞本地库存核心流程。

## 当前范围

已实现单机 P0 核心：商品/批次入库、多批次库存、到期/临期/低库存提醒、FEFO 消耗、批次补充与报废、采购清单、主题设置、JSON 备份导入导出。

尚未实现：扫码/OCR、系统级本地通知、NAS/家庭账号同步、AI 与说明书能力。这些按 `docs/DESIGN.md` 的后续阶段接入。

## 本地开发

本机需安装 Flutter SDK。首次需要补齐原生工程壳：

```bash
flutter create --platforms=android,ios .
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test
```

> 当前仓库不提交默认 Android/iOS 模板；GitHub Actions 会在验证时生成相同的原生工程壳。开始修改原生权限、通知或相机配置前，应在本地生成并提交对应平台目录。

## CI 与自动发布

- `.github/workflows/flutter-ci.yml` 会在 Pull Request 和分支推送时固定 Flutter `3.24.5`，生成原生工程壳、执行 Drift 代码生成、静态检查、单元测试，以及 Android/iOS 无签名构建。
- `.github/workflows/release.yml` 会在**默认分支**上的每次推送后读取自最近一个 `vX.Y.Z` 标签以来的 Conventional Commit，自动计算版本、先执行 Drift 代码生成与 `flutter analyze` / `flutter test`，再构建 Android 安装包并创建 GitHub Release。它不硬编码 `main`，会使用仓库在 GitHub 中设置的默认分支；对同一版本重跑时会替换已存在 Release 的发布附件。
- `scripts/release/test-next-version.sh` 覆盖首次发布、patch/minor/major 优先级及非发布提交，Flutter CI 会执行该版本计算回归测试。

### 发布提交规范

发布工作流只会根据以下提交创建 Release：

| 提交示例 | 版本变更 |
| --- | --- |
| `feat: 支持批次快速录入` | minor，例如 `v0.1.0 → v0.2.0` |
| `fix: 修复临期日期计算`、`perf: 优化列表渲染`、`revert: 回退错误功能` | patch，例如 `v0.1.0 → v0.1.1` |
| `feat!: 调整备份文件格式` 或提交正文包含 `BREAKING CHANGE:` | major，例如 `v0.2.0 → v1.0.0` |

`docs:`、`chore:`、`style:`、`refactor:`、测试提交和非 Conventional Commit 不会触发发布。首次满足规则的发布使用 `pubspec.yaml` 中的基础版本（当前为 `v0.1.0`）；之后以最新 Git 标签为准。工作流把计算出的版本和 GitHub Actions 的运行序号传给 Flutter，因此 APK/AAB 内的版本与 Release 标签一致，无需由工作流回写提交。

### GitHub 仓库配置

1. 将目标发布分支设为 GitHub 仓库的默认分支。
2. 在仓库 **Settings → Actions → General → Workflow permissions** 中允许工作流拥有 **Read and write permissions**。`release.yml` 还显式声明了 `contents: write`，用于创建标签和 Release。
3. 将需要发布的变更以 Conventional Commit 合并/推送到默认分支。

发布成功后，Release 会附带：

- `MomoBox-vX.Y.Z.apk`：可安装的 Android APK；
- `MomoBox-vX.Y.Z.aab`：用于提交到 Google Play 等商店的 Android App Bundle；
- `SHA256SUMS.txt`：两个发布包的 SHA-256 校验和。

> 当前仓库未提交 Android 原生工程和正式签名密钥。工作流会临时生成 Flutter 默认 Android 工程，因此 APK/AAB 适用于内部测试与分发验证；在配置正式 Android 签名、应用 ID、图标和商店发布前，不应将其视为可上架的生产包。iOS 仍需要 Apple 签名与发布流程，未纳入 GitHub Release 自动上传。
