# MomoBox / 嬷嬷的小箱子

本仓库是「嬷嬷的小箱子」的 Flutter 客户端源码。产品采用**本地优先**架构：单机模式由 SQLite（Drift）作为离线数据源，NAS 同步、OCR、扫码和 AI 均不阻塞本地库存核心流程。

## 当前范围

已实现单机 MVP：商品/批次入库、多批次库存、到期/临期/低库存提醒计划、FEFO 消耗、批次补充与报废、变动历史、采购清单、主题设置、日期计算、JSON 备份导入导出和本地通知调度。

尚未实现：扫码/OCR、NAS/家庭账号同步、AI 与说明书能力、统计图表。这些按 `docs/DESIGN.md` 的后续阶段接入。

## 开发与验证

本项目**不要求本地安装 Flutter**。仓库不提交 Flutter 自动生成的 Android/iOS 平台目录和 Drift 生成文件，统一由 GitHub Actions 生成并验证：

- CI：生成平台壳、依赖安装、Drift 代码生成、`flutter analyze`、`flutter test`、Android debug build、iOS unsigned build；
- Release：在默认分支按 Conventional Commit 构建并上传 Android APK/AAB；
- 真机：下载 GitHub Release APK 后执行安装验收。

平台壳和通知配置由 `scripts/ci/prepare-flutter-platforms.sh` 注入；对应的无 Flutter 回归测试在 `scripts/ci/test-prepare-flutter-platforms.sh`。`.gitignore` 明确排除生成的 Android/iOS 目录和 Drift 文件，防止将 CI 产物误提交。完整流程、当前验证状态和安装清单见 `docs/VALIDATION.md`。

## CI 与自动发布

- `.github/workflows/flutter-ci.yml` 会在 Pull Request 和分支推送时使用 Flutter stable channel，安装 Android 17 SDK、确认 iOS 27 SDK 可用，随后生成原生工程壳、执行 Drift 代码生成、静态检查、单元测试，以及 Android/iOS 无签名构建。
- `.github/workflows/release.yml` 会在**默认分支**上的每次推送后读取自最近一个 `vX.Y.Z` 标签以来的 Conventional Commit，自动计算版本、先执行 Drift 代码生成与 `flutter analyze` / `flutter test`，再构建 Android 安装包并创建 GitHub Release。它不硬编码 `main`，会使用仓库在 GitHub 中设置的默认分支；对同一版本重跑时会替换已存在 Release 的发布附件。
- `scripts/release/test-next-version.sh` 覆盖首次发布、patch/minor/major 优先级及非发布提交，Flutter CI 会执行该版本计算回归测试。

### 发布范围与预留项

当前自动发布范围仅包含 **Android APK/AAB**。iOS 和后端 Docker 发布已预留为后续工作，但当前不会创建 IPA、Docker 镜像或额外 GitHub Release 附件：

- **iOS**：CI 保留无签名构建验证；待确定 Bundle ID，并配置 Apple 证书、Provisioning Profile 和 App Store Connect 凭据后，再增加签名 IPA / TestFlight 发布。
- **后端 Docker**：待后端工程及 `Dockerfile` 落地后，再构建并发布镜像至 GitHub Container Registry（GHCR）；不创建没有实际服务内容的占位镜像。

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
