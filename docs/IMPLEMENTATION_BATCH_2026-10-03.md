# 2026-10-03 并行加强批次

## 范围

用户要求将检查结果拆分并同时推进。本批次优先修复已有能力的可靠性，不把后续规划当作全部必须实现的需求。

| 工作包 | 写入范围 | 本批次验收目标 |
| --- | --- | --- |
| A 同步完整性 | 同步适配/引擎及库存、提醒、outbox repository；对应新测试 | 快照依赖排序、完整事务回滚、增量辅助实体明确处理、不可映射能力不伪成功 |
| B 核心备份边界 | 备份格式/repository及对应测试 | 保留旧备份兼容；导入导出隔离设备身份、凭据和同步派生状态；公开覆盖范围 |
| C 首页 HA 快捷操作 | 首页、家居页既有电源接线、HA controller及新测试 | 复用 NAS typed command；真实状态；失败/离线/无权限不翻转或伪报成功 |
| 主线程 集成/验证 | 基线补丁、同步调度、备份文案、旧 integration 导航、CI/文档 | 修复未配置引擎时的调度锁；补调度回归；明确未执行项 |

## 基线

- 开始时工作区干净，本地 HEAD 为 `7b7c0b11dcc12bb3086b33da948f61e012f1d5dd`。
- 已从本地存在的 `origin/main` (`7028f6ec213676519c6073487d16a07d87734c09`) 审阅并应用差异补丁，不重置分支、不改写提交、不联网拉取。
- 上述基线修复涉及编译/分析兼容、HA family/integration 权限、依赖类型校验、现有测试按真实行为更新及 unsigned iOS 配置等，不是本批次新增业务能力。
- 2026-09-29 分支提交 `672f4399434e73e7956fa34661d9aa588eebbec2` 的历史 CI 通过，不能等同于本批次未提交工作区通过。

## 暂不实现

- 社区共享（NEEDS_CONFIRMATION：是否纳入下一期）。
- AI 设备控制、采购写入及混合任务执行。
- 耗材组/配方/联动规则完整配置 UI，以及 HA 实时事件订阅适配。
- 新增后端消费历史 snapshot 协议和库存/HA 冲突的“保留本地”执行策略。
- 图片、说明书和 OCR 的完整文件迁移归档。当前 JSON 是核心数据备份，不能以绝对路径或媒体元数据伪装成跨设备恢复。
- 真实 NAS/HA、多设备、PostgreSQL、Android/iOS 真机联调。

这些条目仍然是待办，不能因本批次完成而标为完成。

## 已落地的改动与剩余限制

- 同步：快照预校验、依赖排序、业务和完成标记原子提交，数据库故障回滚；分类名称和低库存策略真实投影；同版本/删除记录保护；显式无法映射的字段报告 `sync_mapping_unsupported`。
- 同步调度：引擎尚未配置时不保留已完成的 in-flight 锁；请求执行前复核生命周期；亚秒级重试时长不再被截成零。
- 核心备份：导入/导出双向过滤设备和 NAS/HA 身份、同步派生状态、配置凭据；损坏的服务配置拒绝处理；一致性事务导出；新增可选 coverage、隐私说明和过滤计数，保持 v1–v3 格式兼容。
- HA：首页按当前角色授权、实体 capability、在线与新鲜状态发出明确 power 命令，只根据匹配回执更新。主线程同步调整家居页卡片/弹窗的电源接线，弹窗改为 Consumer 跟随回执更新；音量/静音协议未开放时明确未发送，不再伪报已发送。布局与主题保持不变。
- 测试/CI：补同步、调度、备份、HA边界及UI说明测试；旧 integration 改为当前四个主页面和提醒/采购二级入口；NAS脚本自测纳入 prepare。

### 仍不能称为完整同步的原因

1. NAS 默认七天临期设置与本地固定三十天冲突，本轮不擅改已确认业务规则；七天、禁用、开封提醒会明确拒绝，bootstrap 可能保持 pending。
2. 新批次从快照读取数量，已有批次仍遵循 `applyQuantity=false`，不权威覆盖数量；无法保证已有差异的多设备库存收敛。
3. 消费历史尚未纳入 bootstrap，远端 inventory command 的本地历史恢复仍缺协议。后续需稳定 ID、record_type、signed quantity_change、reason、created_at、operation_id 和分页/checkpoint 约定，追加历史不能重复扣库存。
4. 分类完成接收侧 UUID→名称映射；出站字符串分类→服务端UUID的创建/映射未补。分类颜色和自定义排序当前明确未支持。
5. 场景/脚本仍没有已确认的页面执行闭环，不伪造 scenes，也不作为开关；AI混合控制与联动配置/事件来源继续待办。
6. 增量所有字段的完整 schema 校验、真实数据迁移、多设备/HA设备验收尚未完成。

## 验证记录

### PASSED（本机执行）

- `for script in scripts/ci/*.sh scripts/release/*.sh deploy/nas/scripts/*.sh; do bash -n "$script"; done`
- `bash scripts/ci/test-prepare-flutter-platforms.sh`
- `bash scripts/release/test-next-version.sh`
- `sh deploy/nas/scripts/self-test.sh`
- Ruby Psych 解析 `.github/workflows/pipeline.yml`
- `git diff --check`
- 本地 Dart import/export/part 路径存在性检查（仅文件路径检查，不是 Dart analyze）

### NOT_EXECUTED

- Drift 代码生成、`flutter analyze`、`flutter test`、Android/iOS 构建、设备 integration test、`go test ./...`、`go vet ./...`。
- 原因：当前本机没有可用 Flutter/Dart/Go 工具链；没有安装软件或依赖。
- 新增 7 个 Dart 测试文件，同步适配/引擎/调度共 36 条源码级测试声明，另有备份/HA/UI测试。数量只代表已编写，不能标成通过。新工作区尚未提交或推送/触发 CI。

### DEVICE_VALIDATION_PENDING / REAL_ENVIRONMENT_PENDING

- Android/iOS 真机、真实 PostgreSQL、NAS/HA及多设备端到端验证。
- 原因：本轮未连接对应环境；脚本自测不依赖 Docker，也不能代替容器备份恢复验收。

## 下一步验证入口

保留现有 Actions 的代码生成→Flutter分析/测试/Android构建、iOS unsigned构建、Go test/vet 流程，并在 prepare 中补 NAS 脚本自测。设备测试需要单独选择真实设备/模拟器执行：

```sh
flutter test integration_test/app_test.dart -d <device-id>
```

当前仓库中存在临时本地平台壳不代表它们是配置源；平台配置仍以 CI 脚本为准。
