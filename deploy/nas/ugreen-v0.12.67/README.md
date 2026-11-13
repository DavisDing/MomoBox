# UGREEN NAS：复用现有 PostgreSQL 的单文件部署

只部署 MomoBox 后端，连接 NAS 上已经运行的 PostgreSQL 18。不部署、升级或停止 PostgreSQL，不挂载或修改现有 PostgreSQL 数据卷。不使用 .env，所有部署参数直接填在 docker-compose.yaml。

模板使用2026-11-03从公开GHCR解析的固定manifest digest；更新时需明确更换digest，不随latest漂移。发布流程会把实际构建版本写入二进制。**容器自动初始化需要包含 `start` 入口的新镜像；本次改动尚未发布，现有固定 digest 不会自动获得此能力。** 它基于项目已有 external-postgres 方案精简，不是正式发布资产的逐字副本。

## 直接填写 YAML

- DATABASE_URL：填写现有 PostgreSQL 的 Docker 网络别名、端口、MomoBox专属库、账号和URL编码后的密码。示例为 momobox / momobox_user；已有专属库时直接使用其实际名称。容器内 localhost 指向 MomoBox 容器，不能用来指代 PostgreSQL。
- networks.database_network.name：填写现有 PostgreSQL 容器所在的 Docker 网络名，该网络须已存在。此模板按同一 NAS 的已有 Docker 网络连接，sslmode=disable 只用于这种受控网络。

库存/账号基础部署填写以上两处；启用AI时还需填写下述URL和Key。容器内部和宿主映射默认均为 `18473`，完整映射为 `18473:18473`；有冲突时仅修改左侧宿主端口。模板中的固定 `HTTP_ADDR` 与映射右端一致，内置健康检查读取同一配置。应用版本由镜像构建时写入，Compose 不再填写 APP_VERSION；镜像内置 APP_ENV=production。更新现有项目时同步调整 NAS 保存的映射和旧 `HTTP_ADDR`，重建后端容器后生效。

已有 PG18 实例可直接复用，不要求更换 latest 标签或重新部署。MomoBox 需要自己的数据库和非超级用户角色，不与 LiteLLM 或其他业务共用同一数据库/账号。若专属库和角色已经存在，无需重复创建；若不存在，由管理员在现有实例中创建即可，不是重新部署数据库。迁移需要该库的对象创建权限和 pgcrypto 扩展，扩展权限不足时由管理员在该专属库处理。

## AI / LiteLLM配置

在同一YAML的environment中填写AI_ENDPOINT（NAS可达的网关base URL，如http://litellm:4000/v1）、AI_API_KEY（网关虚拟Key）即可。AI_MODEL可留空，自动获取模型并在App选择；需要固定默认模型时再填写。AI_MODELS可留空自动读取/models，也可填写逗号分隔的允许模型别名；AI_PROTOCOL默认auto。未使用AI时将AI_ENDPOINT、AI_API_KEY、AI_MODEL置空，不能保留CHANGE_ME示例。更改后重建后端容器；App助手中选择NAS提供的模型，不再填写手机AI密钥。

模型目录和强制NAS自动接入需要新App与新后端，当前模板固定的2026-11-03 digest未包含本次未发布改动，发布后须明确更新image。HA仍按需在App配置。首账号自动创建家庭，后续成员填NAS地址、邀请码和账号资料加入，设备和同步自动准备。

## 密钥自动管理

全新部署首次执行 `migrate` 或 `serve` 时，程序使用系统密码学随机源独立生成登录签名、刷新令牌摘要及 HA 凭据加密所需的三项密钥，并以权限 `0600` 原子保存为 `./data/secrets.json`。并发初始化只采用同一份完整文件，重启/更新复用；文件损坏、权限过宽或首次保存失败时报错，不覆盖旧文件。健康检查和 schema-check 只读，不会创建密钥文件。

保留登录和自动续期，使用者无需手动生成或填写这些密钥。2026-11-10 按用户要求，Dockerfile 默认以 root（UID 0）运行，无需在 Compose 中增加 `user`；此变更须构建并发布新镜像后生效，现有固定 digest 不会自动更新。`./data` 需要运行用户可读写，并支持同目录硬链接；新建目录权限为 `0700`，密钥文件权限为 `0600`。既有目录/密钥不自动修改所有权；模板的 `cap_drop: ALL` 下，root 也不能绕过其他所有者的私有文件权限，旧 UID 10001 创建的文件仍需按实际权限处理，不能承诺仅更换用户即可修复所有挂载问题。请随数据库备份妥善备份 `secrets.json`，不要删除、公开或提交 Git；丢失后不能解密原 HA 凭据，原有登录与刷新令牌也会失效。Compose 仍含数据库密码，同样不要公开。

**已有 MomoBox 数据的部署继续保留原 JWT_SECRET、REFRESH_TOKEN_PEPPER、HA_TOKEN_ENCRYPTION_KEY 环境变量，不可直接删除后换用此全新安装模板。** 三项均显式提供时沿用旧行为，不读写密钥文件。部分环境变量存在时，仅在首次创建文件时将其原值与补齐的新值一起保存；已有文件时环境变量优先，但不回写或轮换文件。移除环境变量前必须确认文件中的对应值与原值一致，不能把自动生成当作旧密钥迁移。

源码运行或特殊部署可用 `MOMO_DATA_DIR` 改变默认 `/data` 路径；本模板无需设置。

## 容器自动初始化与后续启动

包含本次改动的镜像默认执行 `start`：连接已创建的 MomoBox 专属库，首次空库自动建表并记录迁移；后续启动保留数据和密钥，只执行新增迁移，完成只读校验后才监听 HTTP。无需在 Compose 添加 `command`、初始化服务或手工运行 `migrate`。检测以数据库迁移记录为准，删除或重建后端容器不会重置数据库。

UGOS 创建项目时选择本 YAML；使用已发布且包含此入口的固定镜像后可直接启动。在原 NAS 项目目录也可执行以下命令（项目名需与 UGOS 登记一致）：

```sh
dc() { docker compose -p momobox -f docker-compose.yaml "$@"; }
dc config --quiet
dc pull momo-backend
dc up -d momo-backend
dc ps
```

PostgreSQL 实例、专属库、账号和网络仍需预先存在。自动启动不创建 PostgreSQL 实例、数据库或账号，不改密码，不切换连接目标。首次只接受应用 schema 中没有业务对象的空库（允许管理员预装 pgcrypto）；已有表但迁移记录缺失或为空、记录有缺口、校验值不符、出现当前镜像不认识的新版本时拒绝启动。迁移失败回滚当前版本并退出，已完成版本保留，下次从未完成版本继续；数据库锁防止同版本并发重复执行。

人工维护入口继续可用：

```sh
dc run --rm --no-deps momo-backend migrate
dc run --rm --no-deps momo-backend schema-check
```

迁移只连接 DATABASE_URL 指定的 MomoBox 专属库；不应指向其他应用库。已有业务数据升级前仍先备份数据库和 `data/secrets.json`，停止其他使用同一 MomoBox 库的后端，不进行不同镜像版本的滚动升级。备份、恢复隔离及准入流程保持有效，自动启动不代表旧备份恢复可以直接重新开放。

等后端 healthy 后，访问 `http://NAS地址:18473/api/v1/health`（改过映射端口时使用新端口）。健康接口不代表完整业务验收。

## 初始化页面与运维边界

当前后端提供 API，没有 Web 管理或初始化页面。账号、家庭、成员和 HA 连接使用手机 App 现有入口；数据库连接先填在 YAML，三项内部密钥自动管理，镜像默认入口负责数据库准备。其他可选功能配置遵循现有部署说明，不能假定都可在 Web 中填写。

原发布运维脚本存在.env前提，未放入此单文件模板，不能声称已适配该模板的升级/备份恢复。需要运维时应按项目外部数据库方案核对固定部署身份、匹配服务器主版本的PG client、备份和恢复证明。

后端退出逻辑及Compose保留15秒优雅收尾。临时文件使用镜像内的 `/tmp`，持久化密钥继续使用 `./data:/data`；后端内存上限768MiB、Go软内存目标512MiB，日志按10m×3轮转。按本次审计修复要求，模板恢复只读根文件系统、64MiB临时目录、cap_drop及禁止提权；持久化密钥仍保存在可写data挂载中。请在 NAS 上创建 data 目录并确保镜像的运行用户可读写。

本机验证结果见 `docs/VALIDATION.md` 对应的密钥自动管理记录。没有访问你的 NAS、改变 PostgreSQL 或执行迁移；实际镜像构建、PG18 权限/迁移、同步、UGOS 运行和备份恢复验收仍为 NOT_EXECUTED。
