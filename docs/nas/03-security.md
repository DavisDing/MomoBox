# MomoBox NAS 安全与权限基线

- 文档版本：v0.1
- 更新时间：2026-09-20
- 适用范围：NAS 后端 MVP、PostgreSQL 和 Home Assistant 集成

## 1. 安全目标

NAS 服务面向家庭局域网自部署，但不能假设局域网天然可信。后端必须做到：

- 认证后才能访问家庭数据；
- 每条家庭数据在 SQL 查询和业务层双重校验 `family_id`；
- 家庭成员只能执行角色允许的操作；
- 库存操作由服务端事务校验；
- Home Assistant Token 不明文写入数据库或日志；
- AI/Ollama API Key 不进入 NAS 后端；
- HA 控制必须经过实体白名单和命令能力校验；
- 失败不泄漏密码、Token、内部堆栈或其他家庭数据。

## 2. 账号初始化与注册

配置项：

```text
REGISTRATION_MODE=first_setup|invite_only|open
```

默认值：`first_setup`。

### first_setup

- 数据库无用户时，只允许创建第一个 owner；
- 第一个 owner 必须同时创建家庭或在后续接口创建家庭；
- 已有用户后，普通注册关闭，使用家庭邀请码加入。

### invite_only

- 不允许自由注册；
- 由已授权 owner/admin 创建邀请；
- 被邀请用户注册后加入目标家庭。

### open

- 允许公开注册；
- 仍然不能自动加入任何家庭；
- 适合受信任的局域网临时测试，不建议公网使用。

第一版不依赖 SMTP、邮箱验证码或公网找回密码。忘记密码由 owner/admin 通过明确的管理员重置流程处理，并写入审计记录。

## 3. 密码与 Token

### 密码

- 使用 bcrypt，cost 12；
- 不保存明文密码；
- 密码长度 12-128 个字符；
- 登录错误返回统一的 `AUTH_INVALID_CREDENTIALS`，不能区分邮箱不存在或密码错误；
- 注册邮箱统一规范化后再做唯一性校验。

### Access Token

- JWT；
- 默认有效期 15 分钟；
- 签名密钥来自 `JWT_SECRET`；
- 不在日志中输出完整 Token；
- 只包含 user、family、role、device 和过期时间等最小声明。

### Refresh Token

- 使用高熵随机 opaque token；
- 默认有效期 30 天；
- 数据库只保存哈希和必要元数据；
- 支持单设备撤销、单用户撤销和全局撤销；
- 使用后可轮换；
- `REFRESH_TOKEN_PEPPER` 来自部署 Secret；
- 失效 Token 返回统一 `AUTH_REFRESH_REVOKED` 或 `AUTH_TOKEN_EXPIRED`。

## 4. 家庭角色

| 能力 | owner | admin | member |
|---|---:|---:|---:|
| 查看家庭数据 | 是 | 是 | 是 |
| 创建邀请码 | 是 | 是 | 否 |
| 移除成员 | 是 | 可按策略 | 否 |
| 修改家庭名称 | 是 | 否 | 否 |
| 管理同步设备 | 是 | 是 | 仅自己的设备 |
| 配置 HA 地址和 Token | 是 | 是 | 否 |
| 发现 HA 设备 | 是 | 是 | 否 |
| 修改 HA 实体权限 | 是 | 是 | 否 |
| 控制已授权 HA 实体 | 是 | 是 | 是 |
| 读取已授权 HA 状态 | 是 | 是 | 是 |
| 查看控制审计 | 是 | 是 | 默认否 |

所有授权判断必须同时检查：

```text
user_id + family_id + role + resource ownership + resource permission
```

## 5. 家庭数据隔离

- 所有家庭级表包含 `family_id`，或必须通过带 `family_id` 的父表关联；
- Repository 方法必须接收 `familyID`，禁止只按资源 ID 查询；
- HA 实体还必须同时使用 `integration_id + entity_id` 定位，防止家庭内多个 HA 实例出现同名实体时串用权限、Token 或控制目标；
- 任何由客户端提交的 `family_id` 只能作为提示，不能作为授权依据；
- 服务端从 access token、当前家庭和数据库成员关系确定实际家庭；
- 跨家庭资源访问统一返回资源不存在或无权限，避免泄漏资源存在性。

## 6. Home Assistant Token

MomoBox 后端需要代表家庭访问 HA，因此 HA Token 必须由后端保管，但不能明文保存。

数据库保存：

```text
base_url
access_token_ciphertext
key_version
```

部署提供：

```text
HA_TOKEN_ENCRYPTION_KEY
```

要求：

- 加密密钥不得提交 Git；
- Token 只在调用 HA 时短暂解密；
- Token 不写入普通日志、错误详情或审计 payload；
- 返回给 Flutter 的 `HAIntegration` 永远不包含 Token；
- 修改 Token 后旧密文立即失效；
- 没有配置 HA 时后端正常启动；
- HA 不可用不影响登录、库存和同步。

## 7. Home Assistant 控制安全

客户端不得提交任意 HA domain/service/service_data。后端只接受白名单命令：

```text
turn_on
turn_off
toggle
set_brightness
set_temperature
set_hvac_mode
play
pause
activate_scene
run_script
```

后端必须根据缓存的实体 domain 和 capabilities 校验命令。参数必须限制范围，例如：

- brightness：0-100；
- temperature：根据实体能力和配置范围校验；
- hvac_mode：只能使用发现到的支持值；
- scene/script：只能使用家庭 owner/admin 显式加入白名单的资源。

每次控制写入 `ha_command_logs`：

```text
family_id
integration_id
entity_id
requested_by
command
safe_parameters_summary
result
error_code
created_at
```

不得记录 Token 或完整 Authorization Header。

## 8. 网络与 HTTP

- 后端默认面向局域网监听；
- MomoBox 不内置证书申请或公网暴露；
- 公网访问必须由用户自行配置 HTTPS 反向代理或 VPN；
- 生产部署建议只允许可信反向代理或局域网来源访问；
- CORS 默认关闭或限制为明确的客户端来源；
- 请求体设置上限；
- 所有请求设置超时；
- HA 出站请求设置连接、响应和总超时；
- 不跟随不受信任的重定向到任意地址。

## 9. 限流与防滥用

至少对以下操作限流：

- 登录；
- 注册；
- refresh；
- 邀请码尝试；
- HA 连接测试；
- HA 发现；
- HA 控制命令；
- sync push。

重复幂等键必须返回原处理结果或明确 `IDEMPOTENCY_REPLAY`，不能重复扣库存或重复调用 HA。

## 10. 日志与错误

日志可以包含：

- request_id；
- 路由；
- 状态码；
- 耗时；
- 脱敏后的 user/device/family ID；
- 错误代码。

日志不得包含：

- 密码；
- access token；
- refresh token；
- HA Token；
- AI API Key；
- 完整邀请原文；
- 图片和 OCR 原文；
- 其他家庭的数据内容。

生产响应不得返回 Go 堆栈、SQL、连接串或 Secret。

## 11. AI/Ollama 边界

- Flutter 直连用户配置的 LLM 或外部 Ollama；
- API Key 使用 Android Keystore/iOS Keychain；
- NAS 不提供 AI proxy；
- NAS 不保存 AI API Key；
- NAS Compose 不启动 Ollama；
- 如果手机无法访问 Ollama 地址，用户自行通过 VPN、Tailscale 或反向代理解决网络可达性；
- MomoBox 不负责为 Ollama 打通网络。
