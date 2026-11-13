# MomoBox / 嬷嬷的小箱子

MomoBox 是一款搭配自部署 NAS Docker 后端使用的 Flutter 家庭库存管理应用。首次填写 NAS 地址并注册/登录，首位使用者自动创建家庭，后续成员凭邀请码加入；设备登记与同步初始化自动完成。手机使用 Drift 缓存家庭数据，NAS 暂不可达时可查看缓存，恢复连接后自动同步。

> 本仓库有已接入但尚未完成全环境验收的功能。源码、静态检查或历史 CI 记录不能替代当前提交的 Flutter 构建、真机、Docker、PostgreSQL、NAS 与多设备验收。各项证据和未执行项见 [验证基线](docs/VALIDATION.md)。

## 能力与边界

- 家庭库存：商品与多批次库存、效期与低库存提醒、FEFO 消耗、补充/报废、变动历史、采购清单、JSON 备份恢复和本地通知计划。
- 辅助能力：扫码、可选条码查询，以及 NAS 处理的图片、OCR、AI 草稿和问答。AI 地址、密钥和模型目录在 NAS Compose 配置，可接 LiteLLM；App 助手选择 NAS 提供的模型。AI 未配置或失败时仍可在 NAS 连接正常时手动入库。
- 自动连接：保留家庭账号和权限，自动登记设备、绑定原工作区、接入家庭数据并同步。HA 按需配置；断网仅查看缓存，不继续库存、采购、家务或家居写操作。历史、图片、OCR 和 AI 契约见 [后端处理说明](docs/nas/06-backend-processing.md)。
- 安全与确认：AI 结果只可作为可编辑草稿，任何库存或设备写入都需要用户逐次确认；NAS 只调用部署者配置的 AI 网关，不内置模型运行器或条码代理。

业务规则、已确认范围和待决事项以 [需求文档](docs/REQUIREMENT.md) 为准；当前技术方案以 [设计文档](docs/DESIGN.md) 为准。运行主题使用中性名称、通用 emoji 和 Material 图标，第三方组件与字体保留各自许可。

## 快速入口

| 你要做什么 | 从这里开始 |
| --- | --- |
| 了解长期架构、代码结构和已核实的项目事实 | [AI_CONTEXT](docs/AI_CONTEXT.md) |
| 查需求、验收条件和待确认事项 | [REQUIREMENT](docs/REQUIREMENT.md) |
| 查技术设计、数据/同步/API 方案 | [DESIGN](docs/DESIGN.md) |
| 查当前验证证据、CI 与真机清单 | [VALIDATION](docs/VALIDATION.md) |
| 配置 Android 正式发布签名 | [Android 签名说明](docs/ANDROID_RELEASE_SIGNING.md) |
| 部署标准 NAS 方案或执行备份/更新 | [NAS 部署说明](deploy/nas/README.md) |

## 开发与验证

仓库不提交 Flutter 自动生成的 Android/iOS 平台壳及 Drift 生成文件。CI 会先运行 `scripts/ci/prepare-flutter-platforms.sh`，再生成 Drift 代码、执行分析/测试，并构建 Android 与 iOS；完整命令、环境版本和验收边界以 [验证基线](docs/VALIDATION.md) 和 [pipeline.yml](.github/workflows/pipeline.yml) 为准。

具备 Flutter、Dart 与 Go 工具链的开发环境，可按 CI 的同一顺序执行：

```sh
scripts/ci/prepare-flutter-platforms.sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter analyze
flutter test
(cd backend && go test -count=1 ./... && go vet ./...)
```

这些命令会生成未提交的平台/Drift 文件；PostgreSQL 回归必须使用一次性测试库，不能指向生产数据库。没有相应工具链时，不应把未运行的检查记作通过。

## CI 与发布

唯一工作流是 [`.github/workflows/pipeline.yml`](.github/workflows/pipeline.yml)：PR、分支推送和手动触发均会进入验证；默认分支的成功推送才会构建版本化 Android 安装包并创建/更新 GitHub Release。后端变更的发布镜像可用于 NAS 部署，但生产部署必须固定版本标签或 digest，不能以 `latest` 作为默认值。

发布需要 GitHub Actions 具备仓库内容与包写权限，并按 [Android 签名说明](docs/ANDROID_RELEASE_SIGNING.md) 配置正式 Android 签名。CI 配置存在不等于某个提交已经发布成功；请以对应 Actions run 与 Release 为准。

## NAS 部署

先选择一种模板，再阅读其初始化、更新、备份与恢复说明；包含 `start` 入口的新镜像可自动准备专属数据库，但仍需分别验证镜像和 NAS 环境。

| 场景 | 入口 |
| --- | --- |
| 既有的标准双服务部署（后端 + PostgreSQL 16） | [NAS 部署说明](deploy/nas/README.md) |
| 新建独立 PostgreSQL 18，或复用已有 PostgreSQL 实例 | [NAS 变体说明](deploy/nas/variants/README.md) |
| 绿联 NAS 上复用现有 PG18、无需 `.env` 的单文件模板 | [UGREEN 外部 PostgreSQL 模板](deploy/nas/ugreen-v0.12.67/README.md) |

复用已有 PostgreSQL 时，为 MomoBox 创建专属数据库和非超级用户角色；容器内不能用 `localhost` 指向另一个数据库容器。UGREEN 单文件模板会首次生成并持久化内部密钥到 `data/secrets.json`，应与数据库一起备份；该模板要求使用包含该功能的已发布镜像，实际 NAS/PG18/Docker 验收仍待执行。NAS 必选与模型目录接口需要同时更新 App 和后端镜像；模板中旧的固定 digest 不会获得未发布的新代码。

## 目录概览

```text
lib/          Flutter 客户端、领域规则、Drift 数据和界面
backend/      Go NAS 后端、PostgreSQL migration、Dockerfile 与后端测试
deploy/nas/   Compose 模板、环境变量示例、更新/备份/恢复脚本
docs/         需求、设计、验证记录和 NAS 契约
test/         Flutter 单元、数据与界面测试
scripts/ci/   平台壳生成和 CI 辅助脚本
```

## 贡献约定

修改前先阅读 [AGENTS.md](AGENTS.md) 与 `docs/` 中的相关权威文档。保护已有未提交改动；数据库结构变化需要兼容性与迁移方案；不要把 mock、脚本语法检查或文档审查当作设备、部署或端到端验收。
