# NAS / Home Assistant 收尾任务与验收入口

日期：2026-10-22。源码基线：`ee70ffd`。本文件是可审阅的任务方案，不是 HA 实机验收或新能力完成记录。

用户要求拆分不同任务并行推进。当前批次修复已接入能力的缺陷，并在用户确认后实施 D-03 当前库存与独立历史归档、D-04 日历日期及默认家庭时区、新 Compose 运维适配。HA 事件来源、场景结果语义及完整灾备继续保留 `NEEDS_CONFIRMATION`。不执行发布、真实设备操作或数据库恢复。

## 1. 已核实的实现边界

| 能力 | 源码入口 | 当前事实 |
| --- | --- | --- |
| HA 连接、发现、实体和权限 | `backend/internal/homeassistant/service.go`、`backend/internal/httpapi/homeassistant.go`、`lib/data/nas/nas_homeassistant_api.dart` | 后端及 App 网络边界已有实现；不能据此证明现场授权、网络与回执有效 |
| typed 场景/脚本命令 | `backend/internal/homeassistant/model.go`、`validation.go`、`backend/internal/store/hahttp/client.go` | 后端已有 `activate_scene` / `run_script` 到固定服务调用的映射，App NAS 枚举也已定义；不能把它们写成后端全部未实现 |
| App 场景/脚本执行 | `lib/presentation/controllers/smart_home_controller.dart`、`lib/presentation/screens/smart_home_screen.dart`、`home_screen.dart` | scenes 保持为空；既有场景入口只提示未接入；控制器仅允许现有设备域，不支持场景执行 |
| 配方、规则、建议 | `backend/internal/homeassistant/automation.go`、`backend/internal/store/hapostgres/automation.go`、`NasHomeAssistantApi` | 保存/读取及建议确认 API 已有；App 控制器已有建议展示和确认路径，不能当作全部待从零实现 |
| 真实事件接入 | `backend/internal/httpapi/handler.go`、`homeassistant.go`、`backend/internal/homeassistant/events.go` | 已有认证的事件 POST 与稳定运行 ID 校验；当前 HA HTTP 适配器只有 REST 连接、发现、状态及控制，没有常驻事件订阅生产者 |
| 首版执行策略 | `backend/internal/homeassistant/automation.go` 的 `validateRule` | 明确拒绝 `requires_confirmation=false`；本轮不把自动扣减开关提前开放 |
| HA凭据来源 | `NasSmartHomeRepository`、`NasAuthService`、NAS account/provider | 检查发现生产 HA 仓库曾独立调用无 endpoint 限制的凭据读取/保存；本批修复按既有 AC-015 处理，具体结果见本批交接记录 |

## 2. 可独立实施的工作包

### HA-1：既有会话边界修复（本批实施）

生产 HA 仓库复用 NAS 账号会话及其 endpoint 绑定、刷新、失效保护；兼容入口不得复活无绑定凭据。仓库关闭、退出、换 endpoint / 账号 / 家庭后，旧请求不得保存迟到凭据、清除新凭据或继续复用新身份发起请求。关闭功能仓库不能关闭共享账号 transport。

验收：同 endpoint 规范化绑定恢复；不同 host/scheme/port/path 不恢复；旧无 binding 不恢复；刷新保留绑定；关闭后的迟到响应不覆盖新会话；账号登录/退出/家庭切换时旧客户端失效。Mock 验证仅证明客户端规则，真实 secure storage 和 NAS 联调单独记录。

### HA-2：场景/脚本手动执行（方案待确认）

推荐范围：复用既有场景卡片/确认弹窗，只展示用户明确授权且有对应 typed command 权限的真实实体；场景与设备列表分开映射，绝不把场景当电源开关。不扩展 AI、自动执行、任意 service_data 或高风险实体权限。

需要确认的结果语义：HA REST 成功可能只有 `accepted=true`，没有对应实体 state；脚本也可能在请求返回后继续运行。推荐显示“请求已接受，最终效果待核实”，不能用 HTTP 200、旧 timestamp 或一次状态读取宣称场景中全部设备动作完成。确认后 NAS 重新检查家庭/实体/角色/command；超时结果未知时不自动换 request ID 重试物理动作。

实施入口：控制器中新增独立的场景准备/提交/回执状态，不放宽现有设备 `_supportsCommand`；复用首页与家居既有卡片和项目确认组件。后端已有调用保持原语义，如需增加执行结果协议另立契约，不复用“已达到目标状态”的设备确认逻辑。

验收：场景/脚本类型对应、白名单与角色拒绝、取消零请求、确认期间权限变化、连续点击、跨会话迟到结果、HA 拒绝/超时/空 state、请求接受与最终效果文案区分。最后用一个用户允许的低风险场景/脚本做真实联调。

### HA-3：设备事件 → 耗材建议（方案待确认）

推荐首阶段保持“只生成待确认建议”：配置耗材组/配方/规则，收到经过可信来源校验的开始/完成事件后生成一次建议；用户确认后由现有 NAS 事务扣减。库存不足明确失败/采购建议，手机不再做第二次本地扣减。

当前后端按 recipe → group 汇总其中全部商品并乘以数量，不支持把洗衣液/洗衣粉/洗衣凝珠视为“备选择一”。首期只执行用户已明确选定的确定配方；多个备选且无已确认优先级时必须询问，不能把备选全部相加消耗。候选选择规则/模型需要作为本工作包合同先确认。

当前建议确认按 recipe ID 重新读取最新配方；建议生成与确认之间可能变化。补齐时需冻结或关联配方版本、选中商品和数量，确认前复核；发生变化就重新展示审阅，禁止拿旧确认扣减新配方。需要的 schema/API 与兼容方案先冻结，不把已有确认 API 存在当成快照保护已完成。

先确定事件来源，不能直接把任意 `on → off` 认作洗衣完成。可选 HA 自动化主动推送（需要专门的凭据生命周期与来源控制）或 NAS 订阅 HA 事件（需要断线重连、运行状态持久化和重放规则）。现有普通家庭 bearer 的事件 POST 不代表来源已可信；不建议将个人 refresh token 放入 HA 配置充当长期事件凭据。

生产者必须跨重试复用稳定 `appliance_run_id`，并定义开始、完成、取消、失败、断电和未知结束。当前后端已要求“匹配的 running 才接受 completed”，但只有通用状态归一化，仍需设备/程序映射；取消或重连后的 `off` 不能被误解释为完成。

验收：重复开始/完成、乱序、无开始完成、同一运行多次投递、服务重启、HA断线恢复、规则停用/变化、跨家庭/集成/实体伪造、多个候选耗材、库存不足、确认重试、幂等扣减与审计/同步原子性。真实设备事件及数据库回归必须分别执行，不用手工 POST 成功替代事件生产者验收。

## 3. 部署与端到端验收队列

| 阶段 | 必须记录的证据 | 当前执行边界 |
| --- | --- | --- |
| 本批源码/脚本 | 文件差异、现有 shell 故障模拟、客户端针对性回归 | 依本批实际工具输出填写；没有 SDK 不写 Flutter PASS |
| 同提交 CI | analyze、完整 Flutter 测试、Android/iOS 构建、Go/真实 PG16 回归 | 用户授权提交/push后验证新 SHA；不能沿用 `ee70ffd` 或发布版证明修复后通过 |
| 指定 NAS 部署 | 选定 Compose、固定 image digest/架构、实际 PG 版本、初始化/schema、重建持久化、信号退出 | 无现场访问时 `NOT_EXECUTED`；不自动替换已有数据库或更新 PG 大版本 |
| 双手机同步 | 真实登录/家庭隔离、离线同时操作、未知回执复用键、分页/冲突、返回原身份恢复 | 首次基线/分类/独立历史已按用户确认范围实施；仍须真实双手机验收 |
| HA 手动设备 | owner/admin/member、白名单、状态过期/离线/权限变化、真实目标状态及失败反馈 | 只操作用户选定的低风险设备，不推定高风险实体可执行 |
| HA 场景与事件 | HA-2/3已确认语义及真实运行证据 | 当前仍未接入完整 App/真实事件闭环 |
| 备份与恢复 | 目标数据库/配套密钥、演练环境、恢复前后业务和权限、失败保持隔离 | 新运维适配与完整灾备分别验收，不以 dump-list/health 当安全重开许可 |

不要求用户在聊天中发送密码、Token 或真实 `.env`。现场信息只记录 NAS 架构、UGOS/Compose/PG/HA 版本、选定拓扑、非敏感对象标识及脱敏结果；密钥通过既有安全配置入口提供。

## 4. 并行顺序与停止点

1. CI 诊断修复、HA-1会话修复、同步方案、运维方案可以分配独立文件并行，汇总后统一复核。
2. 同步方案的分类/基线和历史契约由同一工作包冻结；不能让不同开发者分别修改 snapshot/push/history 形成不一致协议。
3. HA-2可以在确认结果语义后独立实施；HA-3需要选定事件来源/凭据后实施，随后与同步库存/历史路径集成验证。
4. D-03/04 在本会话已经确认，按批准范围推进；D-07、HA-2/3 或受保护 UI 的额外实质变化仍须另行确认。没有真实环境时停止在可验证的交付边界，不将模拟测试描述为 NAS/HA 验收。
