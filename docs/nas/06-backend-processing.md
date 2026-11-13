# 家庭历史与后端图片、OCR、AI

2026-11-13当前范围：App必须搭配NAS后端；账号/邀请码接入后自动配置设备和同步。普通历史跨端同步，图片/OCR/AI在NAS处理，手机只暂存与缓存；NAS不可达时只读。可编辑草稿及逐次写入确认保留，不做多工作区、改绑或跨家庭迁移。此规则替代2026-11-02双模式说明。

## 数据与兼容

- Go migration `0010_media_and_operation_history.sql` 为追加迁移，不改旧迁移校验和。现有 consumption_records 增加独立 identity 游标、提交排序锁和可空 client_occurred_at；旧记录仍可读，客户端事件时间与服务器记录时间分开保存。历史读取不重放库存命令。
- 新增 media_assets、media_tombstones、processing_ai_results。图片正规化后的 JPEG 字节、OCR文本/来源/状态/失败、AI结果均在 PostgreSQL 内。标准数据库备份包含这些表，不另引入文件卷；数据库体积会随图片增加。
- Drift schema 6→7 只增加 backend_media_state、backend_media_reassign、stock_movement_sources 三张辅助表，保留原图片、业务流水和核心备份格式。本轮NAS必选/模型目录不新增schema。新辅助表不进入核心JSON备份，历史恢复游标使用已有 `sync_` 排除前缀。
- 核心JSON仍不携带图片、OCR、后端凭据或同步现场；在相同NAS/家庭恢复图片需重新登录由App自动核对原绑定并完成库存同步。数据库迁移降级前备份；旧App忽略新侧表，旧后端镜像的schema门禁可能拒绝新库，不能删表伪造回退。正式灾备切换仍不在本次范围。

## 后端配置与运行

后端 Dockerfile 增加 Tesseract、中英文语言数据，沿用 Alpine 3.20 基线；没有新增Go module或Flutter包；2026-11-13移除手机MLKit及图片压缩包。本机未安装OCR程序，镜像构建和真实识别质量未验收。

三个生产Compose模板增加可选环境变量（更改后须重建容器，App不上传手机密钥）：

```dotenv
AI_ENDPOINT=http://your-litellm-host:4000/v1
# 可选默认模型，支持目录的网关只填 URL + Key 即可
AI_MODEL=
AI_API_KEY=your-litellm-virtual-key
# 留空则尝试网关/models；非空为逗号分隔的允许模型列表
AI_MODELS=
AI_PROTOCOL=auto
# 可选：AI_SECONDARY_ENDPOINT/MODEL/API_KEY/PROTOCOL
# 可选：AI_FALLBACK_ENDPOINT/MODEL/API_KEY/PROTOCOL
MAX_REQUEST_BODY_BYTES=12582912
```

协议支持 auto/chat/responses；目标仅来自NAS部署者配置，不接受客户端指定地址、密钥或工具。HTTP重定向不跟随；图片不发送给模型。每次外部尝试预算20秒、整体预算65秒（HTTP客户端上限60秒），只在明确不支持Chat接口时自动尝试Responses；服务失败可使用已配置的副/兜底服务。环境配置缺失时 `backend_ai=false`，App提示NAS配置缺失，不使用手机密钥代替。手机不再提供服务地址/Key编辑，助手与AI设置只选择NAS目录的模型别名。AI_MODELS非空时约束可选模型；为空时尝试主网关 /models，网关不支持目录时已配置固定模型仍可用。AI_MODEL可留空让目录首个模型成为默认；主网关完全未配置时能力关闭。只填主机的地址规范化为/v1，自定义前缀原样保留。目录地址兼容base URL及以/models、/chat/completions、/responses结尾的URL；仅GET目录返回404/405时，在同一前缀内尝试带/不带v1路径，总预算10秒，最多两次，不触发推理。其他错误不自动换地址或跟随重定向。粘贴Key两端的空白会去除。

单张原图最大8 MiB，JPEG/PNG，最大2400万像素、单边12000像素。NAS负责解码、应用JPEG EXIF方向、重新编码、去除EXIF/GPS；手机只暂存/上传/缓存展示。HEIC等不支持格式明确失败，需要选择JPEG/PNG；没有假装处理成功。JSON base64有体积开销，反向代理需允许至少12 MiB请求，超时需覆盖OCR/AI处理时间。图片解码/正规化单路并发，EXIF方向通过坐标视图读取，不复制完整像素缓冲；OCR/AI仍为两路有界处理并发。后端容器上限768MiB，Go软内存目标512MiB；满载返回 PROCESSING_BUSY，真实容器峰值与OOM行为待验收。

## HTTP契约（均要求当前有效家庭/设备会话）

| 接口 | 行为 |
| --- | --- |
| GET /api/v1/capabilities | 新增 operation_history/media_upload/backend_ocr/backend_ai；wire schema/protocol仍为1/1 |
| GET /api/v1/inventory/history?after=0&until=0&limit=100 | 按家庭分页；首次冻结高水位，返回 records/next_cursor/until/has_more；上限500 |
| POST /api/v1/media/upload | id/entity_type/entity_id/media_type/content(base64)，可选旧ocr_text；幂等UUID与原文件SHA；不接受同ID不同图片或复活墓碑 |
| GET /api/v1/media?entity_type=product&entity_id=UUID&after=UUID | 每页最多50条元数据（含墓碑），不读取图片字节；客户端按UUID继续，下一轮从头重查新增/更新 |
| GET /api/v1/media/UUID | 取单张图片及处理状态；已删图片不返回字节 |
| POST /api/v1/media/UUID/ocr | 执行后端OCR，pending/processing/complete/failed；完成结果幂等复用，崩溃租约2分钟后可重试 |
| POST /api/v1/media/UUID/delete | 删除字节和OCR、保留墓碑；上传未知结果也先记录删除意图 |
| POST /api/v1/media/UUID/reassign | product_id；草稿转商品关联，可安全重试；不支持任意商品间改关联 |
| POST /api/v1/media/manual/search | product_id/query；在后端检索OCR并返回最多5个片段 |
| GET /api/v1/ai/models | models:[{id,default}]；仅返回允许模型别名，最多500条，不触发推理 |
| POST /api/v1/ai/analyze | request_id/system_prompt/user_prompt/history/temperature及可选model别名；仅后端配置的模型推理，不执行工具、SQL或库存写入 |

模型目录失败使用独立错误码：AI_NOT_CONFIGURED、AI_MODELS_AUTH_FAILED、AI_MODELS_NOT_FOUND、AI_MODELS_REDIRECT、AI_MODELS_TIMEOUT、AI_MODELS_UNREACHABLE、AI_MODELS_INVALID_RESPONSE、AI_MODELS_EMPTY、AI_MODELS_UPSTREAM_FAILED。上游401/403返回NAS HTTP502，不能误触发NAS登录续期；未配置为503、超时为504。App显示对应排查提示和合法请求编号，不显示上游正文或URL。

模型请求到达当前后端后记录`ai_models_lookup`，包含request_id、result、upstream_status、model_count、duration_ms；日志不包含密钥、地址、响应正文。沿用容器标准错误输出，无另建日志文件。可在Docker项目日志或`docker compose logs --tail=50 momo-backend`查看。若App的家庭/设备连接尚未就绪，请求会在本机拦截，后端没有该请求日志；旧镜像没有此诊断事件。模型目录失败不等于密钥错误，LiteLLM容器停止也会导致无法连接。

## 移动端流程

1. 首次填写NAS并登录/注册后，App自动创建首家庭或凭邀请码加入、登记设备、绑定工作区并初始化远端同步。处理请求仍核验原NAS/账号/家庭/设备；身份失效或归属不匹配时停止，不调用手机OCR或旧手机AI凭据。
2. 拍照后先写本地暂存及元数据，再以稳定媒体ID上传。上传失败保留原字节与待重试状态，OCR重试或下一次前台/自动同步继续同一上传，不生成重复图片。未提供分块断点续传，8MiB上限内重传整图。
3. 现有本机图片和已保存OCR文本随成功库存同步迁至NAS，旧文字以local_migration来源保留，不为迁移自动重做识别或调用AI。新图片OCR由NAS执行，手机只缓存结果；说明书检索及模型请求均转至后端。
4. 上传、OCR进行中、完成、失败和删除待同步有独立状态；UI沿用原工具行、图片列表、提示和草稿确认。草稿转商品先持久化本机关联及后端待办，网络恢复后补传关联。
5. 库存同步落地后恢复普通操作历史；每页历史与游标同SQLite事务提交，不修改库存数量。通过 operation_id+batch_id 匹配新本机流水，删除对应乐观记录并存服务端稳定ID。旧版有保留outbox且事件/批次/数量精确唯一匹配时可关联；证据缺失时不按时间近似删除历史，可能需要人工核对旧重复项。
6. AI仍由手机组装合法参数表和已授权上下文，后端负责模型调用及结果持久化；手机做返回校验、展示和用户确认，既有写操作执行前复检不变。切换到后端发送需单独确认上下文授权。AI失败不自动执行业务；未知推理结果不自动再次收费，同request_id返回已存回执，失败/崩溃需用户显式新请求。
7. 同步媒体采用按现有商品逐页刷新，非后台常驻服务；App退后台、离线、处理失败时可能延后，需前台恢复或手动同步。不存在跨账号迁移、改绑或多工作区入口。

## 验收边界

隔离PostgreSQL16测试和Go检查见VALIDATION对应记录；真实Tesseract、真实模型、Docker、NAS及双手机仍需分别执行。测试中的模拟OCR/HTTP只验证状态、权限、幂等与事务，不代表识别质量或真实供应商兼容性已通过。

AI_CONTEXT已将当前源码边界更新为NAS必选；该更新不代表设备或真实供应商验收，历史双模式说明已被替代。

2026-11-03审计续修：库存同步成功后，历史/媒体失败独立记为持久警告，下一轮重试不撤销已提交库存游标。零数量discard可进入历史；相同operation_id+batch_id关联更新为服务端稳定ID。媒体单项失败保留状态并继续其他项；会话失效时保留本机暂存/删除待办。家庭商品媒体支持entity_id为空的单流元数据分页，旧NAS返回400/404时保留逐商品兼容入口。本机媒体状态批量读取，避免逐图查询。

AI只有本次INSERT真正创建回执的调用者可启动推理。旧processing/running/failed请求不会自动重跑，未知结果返回HTTP409 AI_RESULT_UNKNOWN；需用户核对后显式新请求。网络/5xx/读取或成功响应解析异常均不自动切另一供应商。client_occurred_at仅随新流水INSERT保存，不批量修改历史。图片product关联在事务内核对家庭归属，草稿重关联也校验目标家庭商品。
