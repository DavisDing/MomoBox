# NAS 运维剩余风险 Review（2026-10-07）

## 1. 范围与结论口径

- **交付范围**：只读审查 update / restore / backup / deployment-lock / Compose 及其必要后端调用链，仅新增本文；不修改脚本、配置、代码、数据库或既有文档。
- **依据**：已读取项目 AGENTS、AI_CONTEXT、REQUIREMENT、DESIGN，以及 NAS 安全/部署契约和灾难恢复设计。源码位置以本次工作区未提交版本为准，行号后续可能变化。
- **验证边界**：以下是源码可证的风险与条件化故障路径，不是已复现的 NAS 事故。未执行 Docker、backup/restore/update、migration、依赖安装、数据库/设备演练。运行验收全部 **NOT_EXECUTED**。
- **优先级**：P1 为满足所列前提即可影响数据完整性、隔离或凭据安全的高优先级问题；不是已确认发生或必然发生。
- **策略边界**：本文与 `/Users/dinghao/Downloads/MomoBox/docs/NAS_RECOVERY_PLAN_2026-10-07.md` 对齐。DR-01～DR-07 全部仍为 **NEEDS_CONFIRMATION**。窄修仅为建议，本文不授权停机、改恢复策略、轮换密钥、清库/游标/outbox 或放宽版本/checksum/冲突校验。

### 不重复列为未修的问题

- `/Users/dinghao/Downloads/MomoBox/deploy/nas/compose.yaml:19-20` 已设后端 `stop_grace_period: 15s`；`/Users/dinghao/Downloads/MomoBox/backend/cmd/momo-backend/http_lifecycle.go:11,35-45` 已使用独立上下文进行 10 秒 drain，超时有 Close fallback。不能再写为“尚未配置优雅退出”。这不等于已经有最终冻结备份或运维失败隔离。
- `/Users/dinghao/Downloads/MomoBox/backend/internal/platform/config.go:104-115` 已在 production 拒绝已知模板 JWT / refresh pepper / HA key。不能再写为“模板 Secret 可直接上线”。这不等于已解决恢复后旧会话或 HTTP 传输暴露。
- update 对**成功识别并停止的 running 后端**，migration 返回失败后不会主动重启，见 `/Users/dinghao/Downloads/MomoBox/deploy/nas/scripts/update.sh:154-167`。本文第 3 节只指出未纳入停机门禁的容器状态，不将该正常分支误报为自动回滚。

## 2. [P1] 升级备份不是冻结后的最终恢复点，最后写入窗口未封闭

**源码证据**

- `/Users/dinghao/Downloads/MomoBox/deploy/nas/scripts/update.sh:143-157`：先调用 backup，再 pull，最后才停止 running 后端。
- `/Users/dinghao/Downloads/MomoBox/deploy/nas/scripts/backup.sh:138-157`：在线 `pg_dump`，随后只检查 `pg_restore --list` 并原子改名；没有冻结业务写入口。
- `/Users/dinghao/Downloads/MomoBox/deploy/nas/scripts/deployment-lock.sh:8-35`：目录锁由运维脚本获取，业务后端不通过该锁执行写入。

**真实故障路径（未演练）**

在线 dump 的一致性点之后，用户提交一笔库存消耗、补充或权限撤销并收到成功；镜像拉取与停机前仍可有后续写入，停机 drain 也可能让已有请求完成。随后升级失败，运维以脚本输出的 dump 为“升级前完整备份”执行恢复，该成功操作不在恢复点中。即使 pg_dump 本身一致、共享锁正常、15 秒 stop 正常，也不能补进 dump 之后的已提交写入。

**现保护与缺口**

已有 dump 权限 600、列表校验、原子改名、脚本互斥，且拉取失败不先停服务；这些是有效保护。但列表校验不是完整恢复演练，脚本锁不是业务冻结，缺少“最后一笔可接受写入 → 排空 → 最终备份”的门禁。普通周期在线备份允许有已说明的 RPO，本项针对的是把同一包误当无损升级回退点。

**建议窄修 / 需确认边界**

保留停机前 pull 与预备备份；在维护窗口封闭所有写入者并确认 drain 后，再取单独标记的最终 dump，成功并验证后才 migration。最终备份失败应保持隔离、不迁移，不能拿旧预备包自动顶替；`--skip-backup` 也不能隐含保证零损失。停机时长、外部直连写入者、最终包/密钥配套与恢复方式需确认，与灾备设计第 3、4.3 节及 DR-01/02/06/07 对齐。不要将此窄修说成已经实现独立候选库灾备。

**后续验收（NOT_EXECUTED）**：在在线 dump 一致性点之后提交并确认操作，验证最终冻结包包含它；测试 pull 慢、备份失败、在途请求及外部写入者，不默认接受静默丢失。

## 3. [P1] update 只停止 running 状态，重启中的旧容器可穿过 migration 失败隔离

**源码证据**

- `/Users/dinghao/Downloads/MomoBox/deploy/nas/scripts/update.sh:154-167`：`ps --status running` 命中才 stop；未命中即继续 migration，失败直接 exit。
- `/Users/dinghao/Downloads/MomoBox/deploy/nas/compose.yaml:18-22`：长期后端容器使用 `restart: unless-stopped`。
- `/Users/dinghao/Downloads/MomoBox/backend/internal/platform/migrate.go:126-130,191-198,264`：逐文件事务执行；后一个 migration 失败不撤销前面已提交的 migration。
- `/Users/dinghao/Downloads/MomoBox/backend/cmd/momo-backend/main.go:254-278,362-365`：serve 做连接检查后启动 HTTP，不调用 migration runner 或验证全部已应用 schema 身份。

**真实故障路径（未演练）**

旧后端因暂时数据库连接失败等原因处在 `restarting`，恰好不在 running 查询结果中；update 因此没有显式停止它。新镜像 migration 提交了前一个文件，后一个失败，脚本非零退出；未被 stop 的旧容器仍可按其重启策略恢复服务，连接已发生部分前向迁移的库。故障可表现为旧应用继续接受请求、部分接口失败或违反本次迁移所需的停写边界。

**现保护与缺口**

正确停止的容器不应被本项描述为必然自动重启；migration 自身已有 advisory lock、逐文件事务与 checksum 保护，且新后端的正常启动在 migration 成功之后。缺口是停机判定依赖瞬时 running 状态，且查询错误被重定向/管道处理后没有独立 fail-closed 分支；没有验证整个目标后端已静止。这里也不是指 `compose run --rm ... migrate` 必然继承重启策略、无限重试 migration。

**建议窄修 / 需确认边界**

对该 Compose project 的既存后端实例显式执行并核实 stop，包括 restarting 状态；枚举/检查失败就中止，不能当作“后端不存在”。迁移前确认无可写后端，失败保持停止并给出阶段/容器信息，不自动改回旧镜像或启动旧库。部署锁不能代替阻断其他 project/主机或人工 start；跨实例 fencing、独立恢复与补偿迁移按 DR-01/03/07 另行确认。保留 checksum、逐文件事务和既有前向迁移规则。

**后续验收（NOT_EXECUTED）**：分别覆盖 running/restarting/exited、不存在容器及 ps 查询失败；在连续 migration 的后一个失败时确认旧后端不能恢复接受写入。

## 4. [P1] EXIT/信号 trap 把“恢复进程退出”当作“允许恢复服务”，缺少阶段安全门禁

**源码证据**

- `/Users/dinghao/Downloads/MomoBox/deploy/nas/scripts/restore.sh:151-167`：EXIT handler 对此前被脚本停止的后端，在成功、失败或 HUP/INT/TERM 退出时均尝试 `compose start`；不检查恢复/验证阶段。
- `/Users/dinghao/Downloads/MomoBox/deploy/nas/scripts/restore.sh:177-193`：连接终止失败、pg_restore 失败都会进入该 handler；成功文字在退出 handler 启动后端之前打印。
- `/Users/dinghao/Downloads/MomoBox/deploy/nas/scripts/update.sh:76-85,169-173`：cleanup 只释放锁；启动后 health 等待失败没有 stop/fence，不能解释为“已保持停止”。
- `/Users/dinghao/Downloads/MomoBox/deploy/nas/scripts/deployment-lock.sh:14-24,47-54`：支持父 update/子 backup 复用且子不释放父锁；释放为 best-effort，并不核实数据库任务或容器已经结束。

**真实故障路径（未演练）**

恢复期间人为取消或收到 TERM，脚本以非零退出，但 handler 仍尝试启动原后端。另一种路径是数据库恢复已提交，尚未进行任何业务验证，退出即开放原服务。若连接终止失败，数据库操作是否结束的隔离条件同样未建立。update 则可能在 `up -d` 后 health 超时返回失败，而该后端仍运行、可接受部分请求。于是“操作失败/被取消”和“停止写入”的运维预期不一致。

**现保护与缺口**

已有信号映射退出码、锁释放以及“只重启本脚本确实停止过的后端”；restore 的单事务能防止该恢复事务部分提交。但事务原子性不证明恢复内容与应用兼容，非零 shell 状态也不是服务 fencing。对于 Docker daemon 管理的任务，不能仅凭 shell 收到信号就声称远端任务已停止或已回滚；本次未测试具体 shell/Compose 的信号转发行为。SIGKILL 留下陈旧锁的 fail-closed 设计不是应自动删锁的缺陷。

**建议窄修 / 需确认边界**

退出清理分开记录“释放资源”和“是否允许启动”；按阶段保存 stop/restore/validation 状态。修改库之后遇失败、信号或远端任务结果不确定，应保持后端隔离并报告人工恢复步骤，不自动启动。update 的 health 失败同样应阻断服务，不自动回滚数据库。确认活跃任务结束之前不轻率释放锁；不能自动清陈旧锁。将旧 restore 的“失败也重启”改为 fail-closed 是可用性/运维语义变更，须确认（DR-01/07），本轮不实施。跨主机锁与 fencing 仍是另一层设计，不扩展现有目录锁承诺。

**后续验收（NOT_EXECUTED）**：在 stop、连接终止、restore 事务、提交后/验证前、start、health 等阶段注入失败与信号，检查退出码、服务可达性、锁归属、活跃数据库任务；不以“trap 已执行”代替安全退出。

## 5. [P1] restore 成功后无 schema/会话/历史门禁，旧 dump 可被直接重新开放

**源码证据**

- `/Users/dinghao/Downloads/MomoBox/deploy/nas/scripts/restore.sh:130-135,185-193,151-161`：恢复前只列 dump 目录；原库 clean + 单事务恢复后，没有匹配当前镜像的 schema/name/checksum 或业务校验，退出即尝试 start。
- `/Users/dinghao/Downloads/MomoBox/backend/internal/platform/server.go:58-75,88-97`：health 只验证 DB 连接，capabilities 版本来自配置；二者不是数据库 migration 完整性/历史身份检查。
- `/Users/dinghao/Downloads/MomoBox/backend/internal/auth/service.go:120-143` 与 `/Users/dinghao/Downloads/MomoBox/backend/internal/store/authpostgres/refresh_tokens.go:18-27`：refresh 依据恢复库中的 token hash、revoked_at、有效期与用户/家庭状态判断。
- `/Users/dinghao/Downloads/MomoBox/backend/internal/sync/dto.go:170-196`：bootstrap/确认携带版本、cursor、checkpoint，但没有 restore epoch 或 server instance 身份字段；原脚本也不分配该身份。

**真实故障路径（未演练）**

将较旧但格式正确的 dump 恢复到原 URL：当前镜像要求的新结构可能缺失，连接健康仍可能为 ok，业务接口随后才失败。若配套签名/pepper 未变，且备份包含尚未过期、当时未撤销的 refresh 记录及可用账号/设备，备份后撤销的 token 可能重新有效。同一 URL、同 wire 版本不代表同数据库历史；App 保存的 cursor/幂等回执可能属于另一分支，近期已执行操作的回执丢失可能导致错误重放或无法收敛。不是断言每个旧 token 都能恢复，也不是断言现有 cursor/version/冲突保护完全无效。

**现保护与缺口**

有 dump 可读性、确认输入、停后端、终止连接、单事务与既有认证/版本/冲突校验。但恢复不运行匹配镜像的迁移身份门禁、不撤销旧会话、不识别历史代次；当前 endpoint 绑定与 session generation 保护换服务器/账号，不能识别同 URL 的旧库恢复。直接恢复进非空原库的 clean 只覆盖 dump 表示的对象，不能作为“空库、无残留对象”的证明。

**建议窄修 / 需确认边界**

最小门禁：恢复后先保持入口关闭，检查完整 migration 身份与目标镜像匹配、关键业务约束和配套 HA 解密能力；失败不 start、不伪造成功。schema check 应为明确的只读校验，不能把运行会改数据的 migrate 当成无副作用检查，不能删除记录/改 checksum 绕过。完整处置沿灾备设计第 4～7 节：独立空库候选、验证后切换、主动失效旧会话及管理员复核、外部耐久 epoch + App 意图审阅。DR-01/02/03/04/05/07 全部仍待确认；不要仅改 JWT、清 cursor/outbox、强制 bootstrap 或重登录就宣称解决历史分叉。未有 epoch 门禁前遵守该文第 6.4 节，旧 dump 恢复后同步/HA 写入口保持关闭或限定隔离验证。

**后续验收（NOT_EXECUTED）**：旧 schema/错 checksum、错误 HA key、撤权后恢复、同 URL 不同历史且 cursor 小于/等于/大于 App 的组合；检查数据与离线意图保留、无未授权访问/重复库存和 HA 动作。

## 6. [P1] 默认 API 端口无宿主地址限制且为 HTTP，HTTPS 代理不能自动封住直连旁路

**源码证据**

- `/Users/dinghao/Downloads/MomoBox/deploy/nas/compose.yaml:33,38,46-47`：容器 HTTP 监听所有地址；端口映射仅指定端口，未限定宿主绑定地址；注册默认 first_setup。
- `/Users/dinghao/Downloads/MomoBox/backend/cmd/momo-backend/http_lifecycle.go:14,24`：使用 `ListenAndServe` 而非内建 TLS。
- `/Users/dinghao/Downloads/MomoBox/backend/internal/auth/service.go:48-59`：first_setup 在无用户时允许注册。
- `/Users/dinghao/Downloads/MomoBox/docs/nas/04-deployment.md:280-286`：明确无内置公网证书，公网 HTTPS 反代/VPN 由用户提供；`/Users/dinghao/Downloads/MomoBox/docs/nas/03-security.md:179-182` 要求来源受控。

**真实故障路径（未演练）**

NAS 的已发布端口在不可信 LAN 接口或端口转发规则下可达，手机/其他客户端直接通过 HTTP 登录或刷新，凭据与 bearer 无该链路的 TLS 保护；即使另设 HTTPS 反代，直连宿主 API 端口仍可能绕过它。首次部署或错误地开放空库候选时，first_setup 入口也可能被非预期来源抢先使用。是否实际公网可达取决于 NAS 网络、Docker 和防火墙配置，本次没有现场证据，不能报告为“已暴露公网”。

**现保护与缺口**

PostgreSQL 未发布宿主端口，后端非 root、只读、drop caps/no-new-privileges；认证与模板 Secret 拒绝均已存在。部署契约也要求用户配置 HTTPS/VPN，因此“不内置证书”本身不是需求遗漏。缺口是默认配置没有可审查的宿主地址/来源限制，也没有确保反代后的原 HTTP 端口不对非可信来源开放；HTTP 健康检查正常不能验收 TLS 或来源隔离。

**建议窄修 / 需确认边界**

新增明确宿主绑定地址配置与部署检查：同机反代优先仅 loopback 绑定；跨主机反代/VPN 则绑定指定私网接口并配来源 ACL，避免盲目 loopback 破坏手机或容器代理连通。公网入口只能使用已批准 HTTPS/VPN，原 HTTP API 不应保留公网旁路；首次注册/恢复候选保持入口受控。不擅自新增代理服务、证书依赖或改变现有双服务拓扑。NAS 代理位置、直连 LAN 是否保留、可信来源、证书/续期职责为 **NEEDS_CONFIRMATION**；恢复时与灾备设计第 4.3、5 节和 DR-01/05 对齐。

**后续验收（NOT_EXECUTED）**：从可信/非可信 LAN、宿主 loopback、代理容器、VPN 与公网分别检查可达性；验证 TLS 证书和原端口旁路、首次注册隔离，不只 curl health。

## 7. 对齐与验证记录

| 本文项 | 灾难恢复设计对应 | 本次处理 |
| --- | --- | --- |
| 2 最终备份点 | 第 3、4.3 节；DR-01/02/06/07 | 只记录窗口与建议，不改变 RPO/恢复损失政策 |
| 3 migration 失败隔离 | 第 3、4.3、4.4 节；DR-01/03/07 | 区分已停 running 分支与漏停 restarting 分支，不提自动降级 |
| 4 退出安全 | 第 4.1、4.3、4.4 节；DR-01/07 | 提案改变失败重启语义，需批准；不动锁/脚本 |
| 5 恢复后门禁 | 第 4～7 节；DR-01～05/07 | epoch、会话、候选库均未实现；既有方案未转批准 |
| 6 网络/TLS | 第 4.3、5 节；DR-01/05 + NAS 网络契约 | 不要求内建证书/新增服务，拓扑和来源待确认 |

本文只列上述 **5 个**确凿的高价值剩余风险，不追加泛化清单。备份加密/密钥包、异地留存、RPO/RTO、完整恢复演练等完整策略已由灾备设计覆盖，不重复另列为第六项。

本次检查口径：源码/文档交叉核对与本文路径/行号、结构、空白检查；实际检查结果由本次交付回复报告。Docker、PostgreSQL、脚本故障注入、TLS/设备/恢复演练均 **NOT_EXECUTED**，本文不是生产验收报告，也不把历史自测结果当作本次执行结果。
