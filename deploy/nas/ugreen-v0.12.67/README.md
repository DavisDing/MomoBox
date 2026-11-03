# UGREEN NAS：复用现有 PostgreSQL 的单文件部署

只部署 MomoBox 后端，连接 NAS 上已经运行的 PostgreSQL 18。不部署、升级或停止 PostgreSQL，不挂载或修改现有 PostgreSQL 数据卷。不使用 .env，所有部署参数直接填在 docker-compose.yaml。

模板使用 GHCR 的 `latest` 后端镜像；发布流程会把实际构建版本写入二进制。**此精简模板依赖本次新增的密钥自动持久化功能，必须先构建并发布包含该改动的镜像；当前工作区代码尚未发布，不能直接假定线上 latest 已支持。** 它基于项目已有 external-postgres 方案精简，不是正式发布资产的逐字副本。

## 直接填写 YAML

- DATABASE_URL：填写现有 PostgreSQL 的 Docker 网络别名、端口、MomoBox专属库、账号和URL编码后的密码。示例为 momobox / momobox_user；已有专属库时直接使用其实际名称。容器内 localhost 指向 MomoBox 容器，不能用来指代 PostgreSQL。
- networks.database_network.name：填写现有 PostgreSQL 容器所在的 Docker 网络名，该网络须已存在。此模板按同一 NAS 的已有 Docker 网络连接，sslmode=disable 只用于这种受控网络。

只需填写以上两处。端口默认 `18473`，容器内部仍监听 `8080`；有冲突时仅修改 `18473:8080` 左侧。应用版本由镜像构建时写入，Compose 不再填写 APP_VERSION；镜像内置 APP_ENV=production。

已有 PG18 实例可直接复用，不要求更换 latest 标签或重新部署。MomoBox 需要自己的数据库和非超级用户角色，不与 LiteLLM 或其他业务共用同一数据库/账号。若专属库和角色已经存在，无需重复创建；若不存在，由管理员在现有实例中创建即可，不是重新部署数据库。迁移需要该库的对象创建权限和 pgcrypto 扩展，扩展权限不足时由管理员在该专属库处理。

## 密钥自动管理

全新部署首次执行 `migrate` 或 `serve` 时，程序使用系统密码学随机源独立生成登录签名、刷新令牌摘要及 HA 凭据加密所需的三项密钥，并以权限 `0600` 原子保存为 `./data/secrets.json`。并发初始化只采用同一份完整文件，重启/更新复用；文件损坏、权限过宽或首次保存失败时报错，不覆盖旧文件。健康检查和 schema-check 只读，不会创建密钥文件。

保留登录和自动续期，使用者无需手动生成或填写这些密钥。`./data` 需要容器 UID 10001 可读写，并支持同目录硬链接；新建的目录权限为 `0700`，已有目录权限由 NAS 管理。请随数据库备份妥善备份 `secrets.json`，不要删除、公开或提交 Git；丢失后不能解密原 HA 凭据，原有登录与刷新令牌也会失效。Compose 仍含数据库密码，同样不要公开。

**已有 MomoBox 数据的部署继续保留原 JWT_SECRET、REFRESH_TOKEN_PEPPER、HA_TOKEN_ENCRYPTION_KEY 环境变量，不可直接删除后换用此全新安装模板。** 三项均显式提供时沿用旧行为，不读写密钥文件。部分环境变量存在时，仅在首次创建文件时将其原值与补齐的新值一起保存；已有文件时环境变量优先，但不回写或轮换文件。移除环境变量前必须确认文件中的对应值与原值一致，不能把自动生成当作旧密钥迁移。

源码运行或特殊部署可用 `MOMO_DATA_DIR` 改变默认 `/data` 路径；本模板无需设置。

## 首次初始化 MomoBox 专属空库

UGOS 创建项目时选择本 YAML，项目名为 momobox，暂不启动后端。在NAS项目目录中定义以下命令入口：

```sh
dc() { docker compose -p momobox -f docker-compose.yaml "$@"; }
dc config --quiet
dc pull momo-backend
dc stop momo-backend
dc ps --all
```

确认现有 PostgreSQL 可达、MomoBox 专属库和角色已就绪，且专属库尚无旧 MomoBox 数据、没有其他 MomoBox 写入者或未完成任务。逐条执行，任一步失败立即停止：

```sh
dc run --rm --no-deps momo-backend migrate
dc run --rm --no-deps momo-backend schema-check
dc up -d momo-backend
dc ps
```

迁移只连接 DATABASE_URL 指定的 MomoBox 专属库；不应指向现有其他应用库。无需停止 PostgreSQL 或其他使用该实例的应用。已有 MomoBox 业务数据应按备份和安全升级流程处理，不使用首次空库初始化步骤替代升级。

等后端 healthy 后，访问 `http://NAS地址:18473/api/v1/health`（改过映射端口时使用新端口）。健康接口不代表完整业务验收。

## 初始化页面与运维边界

当前后端提供 API，没有 Web 管理或初始化页面。账号、家庭、成员和 HA 连接使用手机 App 现有入口；数据库连接先填在 YAML，三项内部密钥自动管理。Compose 不自动执行数据库迁移；其他可选功能配置遵循各自现有部署说明，不能假定都可在 Web 中填写。

原发布运维脚本存在.env前提，未放入此单文件模板，不能声称已适配该模板的升级/备份恢复。需要运维时应按项目外部数据库方案核对固定部署身份、匹配服务器主版本的PG client、备份和恢复证明。

后端退出逻辑已在程序内保留有限时长的优雅收尾，Compose 不再设置 stop_grace_period；临时文件使用持久化的 `./data:/data`，不使用内存 tmpfs。请在 NAS 上创建 data 目录并确保容器 UID 10001 可读写。

本机验证结果见 `docs/VALIDATION.md` 对应的密钥自动管理记录。没有访问你的 NAS、改变 PostgreSQL 或执行迁移；实际镜像构建、PG18 权限/迁移、同步、UGOS 运行和备份恢复验收仍为 NOT_EXECUTED。
