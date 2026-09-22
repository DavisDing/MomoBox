# MomoBox / 嬷嬷的小箱子

本仓库是「嬷嬷的小箱子」的 Flutter 客户端源码。产品采用**本地优先**架构：单机模式由 SQLite（Drift）作为离线数据源，NAS 同步、OCR、扫码和 AI 均不阻塞本地库存核心流程。

## 当前范围

已实现并进入测试的单机能力：商品/批次入库、多批次库存、到期/临期/低库存提醒计划、FEFO 消耗、批次补充与报废、变动历史、采购清单、主题设置、日期计算、JSON 备份导入导出和本地通知调度；实时相机、拍照和相册条码识别；可选外部条码查询及本地缓存；商品/说明书图片、本地 OCR；以及用户自行配置兼容 OpenAI 服务后的 OCR 文本入库草稿与库存问答。

条码查询和 AI 均不是本地核心流程的前置条件：外部查询失败、AI 未配置或请求失败时，仍可继续手动录入和管理库存。AI 草稿只会在用户确认后填入表单，正式入库仍需用户确认；OCR 文本发送前会再次征得确认，原图不会发送。发起库存问答时，问题、近期对话和当前本地库存/批次快照会发送至用户自己配置的 AI 服务，不包含原图。

尚未实现：Flutter 客户端的 NAS/家庭账号同步接入、说明书外部链接/检索式问答、统计图表和社区共享数据。Go NAS 后端、PostgreSQL migration、Docker Compose、备份恢复和 GHCR 镜像发布流程已落地；真实 NAS/HA/Flutter 端到端联调仍按部署文档单独验收。

## 开发与验证

本项目**不要求本地安装 Flutter**。仓库不提交 Flutter 自动生成的 Android/iOS 平台目录和 Drift 生成文件，统一由 GitHub Actions 生成并验证：

- 单一 Workflow：先并行完成 Flutter/Android、iOS 与 Go 后端验证，再进入发布包构建和发布节点；
- Release：仅在默认分支命中 Conventional Commit 发布规则后构建并上传 Android APK/AAB；
- 真机：下载 GitHub Release APK 后执行安装验收。

平台壳和通知配置由 `scripts/ci/prepare-flutter-platforms.sh` 注入；对应的无 Flutter 回归测试在 `scripts/ci/test-prepare-flutter-platforms.sh`。`.gitignore` 明确排除生成的 Android/iOS 目录和 Drift 文件，防止将 CI 产物误提交。完整流程、当前验证状态和安装清单见 `docs/VALIDATION.md`。

## CI 与自动发布

- `.github/workflows/pipeline.yml` 是唯一的 Actions 入口，在 Pull Request、分支推送和手动触发时依次执行 `prepare → Flutter/Android + iOS + Go 后端并行验证 → build-release-packages → publish`。发布节点通过 `needs` 串联，任何验证或打包失败都会阻止镜像和 GitHub Release 发布。
- 默认分支推送会读取自最近一个 `vX.Y.Z` 标签以来的 Conventional Commit；命中发布规则后先构建并上传工作流制品，再由最后的 `publish` job 创建或更新 GitHub Release。默认分支的后端变更会在同一条链路末端发布 `latest`/`sha-*` 镜像，正式版本同时发布 `vX.Y.Z` 镜像。
- 工作流不硬编码 `main`，使用仓库配置的默认分支；对同一版本重跑时会替换已存在 Release 的发布附件。`scripts/release/test-next-version.sh` 覆盖首次发布、patch/minor/major 优先级及非发布提交，并在 `prepare` job 中执行。

### 发布范围与预留项

当前自动发布范围包含 **Android APK/AAB** 与 NAS 后端 Docker 镜像。iOS 发布仍为后续工作：

- **iOS**：CI 保留无签名构建验证；待确定 Bundle ID，并配置 Apple 证书、Provisioning Profile 和 App Store Connect 凭据后，再增加签名 IPA / TestFlight 发布。
- **后端 Docker**：`backend/` 已提供实际 Go 后端与 Dockerfile。默认分支后端变更在通过 Go 测试、vet 与双架构 Buildx 构建后发布公开 GHCR 镜像 `ghcr.io/davisding/momobox-backend:latest`；正式产品 Release 同时发布 `vX.Y.Z` 标签。NAS 使用 `deploy/nas/scripts/update.sh` 按“备份 → 拉取 → migration → 启动”流程更新。

### 发布提交规范

发布工作流只会根据以下提交创建 Release：

| 提交示例 | 版本变更 |
| --- | --- |
| `feat: 支持批次快速录入` | minor，例如 `v0.1.0 → v0.2.0` |
| `fix: 修复临期日期计算`、`perf: 优化列表渲染`、`revert: 回退错误功能` | patch，例如 `v0.1.0 → v0.1.1` |
| `feat!: 调整备份文件格式` 或提交正文包含 `BREAKING CHANGE:` | major，例如 `v0.2.0 → v1.0.0` |

`docs:`、`chore:`、`style:`、`refactor:`、测试提交和非 Conventional Commit 不会触发发布。首次满足规则的发布使用 `pubspec.yaml` 中的基础版本（当前为 `v0.1.0`）；之后以最新 Git 标签为准。工作流把计算出的版本和 GitHub Actions 的运行序号传给 Flutter，因此 APK/AAB 内的版本与 Release 标签一致，无需由工作流回写提交。

“关于”页通过 `MOMO_APP_VERSION` / `MOMO_BUILD_NUMBER` 编译变量显示版本。统一工作流的发布包构建节点会将它们与 `--build-name` / `--build-number` 设为同一组值。本地手动打包自定义版本时也应同时传入，例如：

```sh
flutter build apk --build-name=0.2.0 --build-number=42 \
  --dart-define=MOMO_APP_VERSION=0.2.0 --dart-define=MOMO_BUILD_NUMBER=42
```

未传入编译变量的开发构建默认显示 `0.1.0` / `1`。

### GitHub 仓库配置

1. 将目标发布分支设为 GitHub 仓库的默认分支。
2. 在仓库 **Settings → Actions → General → Workflow permissions** 中允许工作流拥有 **Read and write permissions**。`pipeline.yml` 的 `publish` job 显式声明了 `contents: write` 和 `packages: write`，用于创建 Release 与推送 GHCR 镜像。
3. 将需要发布的变更以 Conventional Commit 合并/推送到默认分支。

发布成功后，Release 会附带：

- `MomoBox-vX.Y.Z.apk`：可安装的 Android APK；
- `MomoBox-vX.Y.Z.aab`：用于提交到 Google Play 等商店的 Android App Bundle；
- `SHA256SUMS.txt`：两个发布包的 SHA-256 校验和。

> 当前仓库未提交 Android 原生工程和正式签名密钥。工作流会临时生成 Flutter 默认 Android 工程，因此 APK/AAB 适用于内部测试与分发验证；在配置正式 Android 签名、应用 ID、图标和商店发布前，不应将其视为可上架的生产包。iOS 仍需要 Apple 签名与发布流程，未纳入 GitHub Release 自动上传。
