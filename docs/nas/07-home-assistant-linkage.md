# Home Assistant 事件联动与场景调用

先在 MomoBox 的「Home Assistant 连接配置」保存集成并发现实体。NAS 运行期间会用该集成的已保存凭据订阅指定实体的状态变化。HA 的 `subscribe_trigger` 需要 HA 管理员用户的令牌。用于配置联动规则的 MomoBox 家庭管理员是另一套身份。

## 夜间门磁通知

在 HA Companion 登录目标手机，先用 HA 的开发者工具调用对应的 `notify.mobile_app_…` 动作，确认手机能收到通知。然后给 NAS 容器添加以下可选环境变量并重新部署。使用管理账号请求 NAS 的 `GET /api/v1/home-assistant/integrations`，用返回的集成 `id` 替换示例 UUID。门磁实体须已被该集成发现。

```yaml
environment:
  MOMO_HA_NIGHT_DOORS: >-
    [{"integration_id":"11111111-1111-4111-8111-111111111111","entity_id":"binary_sensor.front_door",
    "notify_action":"notify.mobile_app_my_phone","start":"22:00","end":"07:00"}]
```

每个门磁配置一个 Companion 动作。时段使用 MomoBox 家庭时区，包含开始时间，结束时间不包含在内。HA 的门磁 `off → on` 表示开门。退出 MomoBox 后在通知时段内开门，检查 Companion 仅收到一次，再在时段外开门验证不发送。关门、状态恢复和重连快照均不会触发提醒。

NAS 在请求 HA 前写入持久去重记录。若 NAS 在记录后退出，或调用结果未知，同一事件不会重发。可从 NAS 日志检查 HA 调用失败。离线期间的事件没有补发。

## 洗衣完成的耗材建议

家庭创建者或管理员用 NAS API 保存一组耗材、一条配方和一个启用的联动规则。请求需要已登录的 MomoBox NAS Bearer Token，以及 `Content-Type: application/json`。下列示例 JSON 中的 ID 取自当前家庭已保存的商品、集成及前一步响应。

1. POST `/api/v1/home-assistant/consumable-groups`，保存每次用一颗的耗材组。使用响应中 `group.id`。

   ```json
   {"name":"洗衣凝珠","items":[{"product_id":"<商品 UUID>","quantity":1,"unit":"capsule"}]}
   ```

2. POST `/api/v1/home-assistant/consumable-recipes`，保存耗材配方。使用响应中 `recipe.id`。

   ```json
   {"name":"标准洗","groups":[{"group_id":"<耗材组 UUID>","quantity":1,"unit":"cycle"}]}
   ```

3. POST `/api/v1/home-assistant/linkage-rules`。每个被监视的实体启用一条规则。`appliance_domain` 与已发现实体的域一致。

   ```json
   {"name":"洗衣机完成","integration_id":"<集成 UUID>","entity_id":"sensor.washer_cycle",
    "appliance_domain":"sensor","recipe_id":"<配方 UUID>","start_state":"running",
    "complete_state":"completed","enabled":true,"requires_confirmation":true}
   ```

配置约十秒后生效。使用能保持 `running`（或 `on`、`active`）直到真实结束，再变为 `completed`（或 `finished`、`complete`、`off`）的实体。原始实体如果会在洗涤过程中切换多种状态，或暂停、取消也会变为 `off`，可在 HA 中创建模板传感器表达完整周期。NAS 要先观察到启动，再看到对应结束，才生成建议。

关掉 MomoBox，运行一次完整洗衣周期，然后打开「家居」并刷新，在「设备耗材联动与建议」检查只生成一条建议。耗材充足时可确认扣减，缺货时显示补货建议。生成建议本身不扣库存。可用 `PUT /api/v1/home-assistant/linkage-rules/{rule_id}` 更新规则或设为 `enabled: false`。

## 场景与脚本

在 HA 创建场景或无需输入参数的脚本。在 MomoBox 的「Home Assistant 连接配置」发现实体后，选择角色，对所需的 `scene.*` 或 `script.*` 打开查看和控制。对应的授权命令是 `activate_scene` 或 `run_script`。

可从「家居 → 场景与脚本」手动调用，也可在助手聊天里说「激活晚安场景」。确认后，MomoBox 发送该实体的 typed command。成功回执表示 HA 接受调用。下游设备的实际状态可在 HA 中核实。遇到结果未知时，先核实 HA 里的运行或设备状态，再决定是否重新调用。
