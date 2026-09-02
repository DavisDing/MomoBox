# AI CONTEXT

## 1. 项目概览

- **名称**：MomoBox / 嬷嬷的小箱子
- **类型**：Flutter 手机应用
- **目的**：本地优先管理家庭物品库存、批次效期、消耗和采购。

## 2. 技术栈

- Frontend：Flutter / Dart
- State：flutter_riverpod
- Routing：go_router
- Local database：Drift + SQLite
- Local notifications：flutter_local_notifications + timezone
- Platform validation：GitHub Actions；仓库不提交 Flutter 自动生成的 Android/iOS 壳
- Compatibility baseline：最低 Android 16.0（API 36）和 iOS 27.0；平台壳由 CI 脚本生成后注入 Android API 36 minSdk、Android API 37 compile/target SDK 与 iOS 27.0 deployment target。

## 3. 当前结构

```text
lib/
├── app/                       # App、路由、主题
├── application/               # 用例编排与校验
├── core/database/             # Drift 表、数据库和迁移入口
├── data/repositories/         # 库存、采购、设置、备份数据访问
├── domain/                    # 日期、FEFO、提醒规则、领域模型
├── presentation/              # 页面、控制器和组件
└── services/                  # 平台能力适配（本地通知）

test/domain/                  # 可在 Flutter CI 中运行的领域测试
scripts/ci/                   # CI 平台壳生成、补丁回归测试
```

## 4. 长期架构

```text
Presentation
  ↓
Application / Use Cases
  ↓
Domain rules
  ↓
Repositories
  ↓
Drift / SQLite
```

单机模式不依赖 NAS、账号或网络。未来 NAS 同步必须作为独立 Data/Sync 实现，不能破坏本地数据源和离线操作。

## 5. 已确认业务规则

- 库存单位为整数“件”；
- 数量和低库存阈值必须大于 0；
- 到期日当天仍有效，次日过期；
- 到期日期可以为空；无效期批次不进入效期提醒，但参与库存、搜索、消耗和采购；
- 保质期按月使用日历加月，月末超出日期取目标月最后一天；
- FEFO 只消耗未过期可用批次，无足够库存时拒绝操作；用户也可输入正整数并指定一个未过期、未报废且库存充足的批次消耗；批次补充也支持正整数输入，报废须在界面二次确认；
- 入库时同条码或无条码精确特征只生成相似商品候选；必须由用户确认合并，或选择新建独立商品，不能静默归并；
- 本地提醒在 App 启动和库存变化后重算，使用稳定 ID 去重；提醒页支持单条/批量标记已处理，确认记录独立持久化在 `reminder_acknowledgments` 表，并通过 `reminder_key + fingerprint` 过滤，不能把库存或采购动作自动当作已处理；低库存恢复到阈值以上时清除旧确认，再次跌破阈值生成新的提醒周期；
- JSON 导入默认不覆盖已有主键记录；导入前验证备份头、版本、必需数据段、必填字段、字段类型和数量约束，格式错误不应写入部分数据；
- AI、OCR、扫码、NAS 不得成为单机核心的硬依赖。
- 嬷嬷/哆啦A梦主题当前仅用于本人本地使用和私有设备安装验证；未来公开发布、上架、商用或第三方分发前，必须重新完成资源授权/合规审查。

## 6. 当前实现状态

已实现：商品/批次、库存列表和筛选、默认 FEFO 与指定批次消耗、自定义数量补充、报废二次确认、采购清单、历史、日期计算、主题、JSON 备份、本地提醒调度计划、提醒单条/批量确认及其备份恢复。

未实现：扫码/OCR、AI、说明书、NAS/家庭账号/同步、后端 PostgreSQL、Docker、统计图表。

## 7. 开发规则

- 先读取 docs 和当前代码，再修改；
- 小范围修改，保护已确认 UI；
- Controller 不堆业务，业务规则放 Application/Domain；
- 修改数据库结构必须增加 schemaVersion 和迁移；
- 不把 Mock 当真实能力，不伪造测试结果；
- 本机没有 Flutter 时不得声称已通过 analyze/test/build；应标记 `NOT_EXECUTED`，交给 GitHub Actions 验证。

## 8. 验证基线

CI 使用 Flutter stable channel，并执行：

1. 生成 Android/iOS 平台壳；
   - 注入 Android API 36（minSdk）、Android API 37（compileSdk/targetSdk）和 iOS 27.0 deployment target；
2. 安装 Android 17 SDK platform，并在 iOS runner 上确认 iOS 27 SDK 可用；运行平台壳补丁回归测试，并注入通知权限、重启恢复 receiver、flutter_local_notifications Java 8 desugaring、通知图标保留和 iOS 通知 delegate；
3. `flutter pub get`；
4. Drift `build_runner`；
5. `flutter analyze`；
6. `flutter test`；
7. Android debug build；
8. Release 工作流额外构建 APK/AAB 并上传 SHA256。

本地安装验证以 GitHub Release 的 Android APK 为准，重点检查首次启动、入库、日期计算、消耗、提醒权限、采购勾选入库和备份恢复。

## 9. AI_CONTEXT Update Proposal

本次已将历史模板更新为实际 Flutter 单机 MVP 架构。后续只有技术栈、长期架构、核心业务决策或验证基线发生变化时才更新本文件。
