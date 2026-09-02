- # 「嬷嬷的小箱子」产品需求文档（PRD）

  **版本**：V3.0  
  **日期**：2026-09-01  
  **状态**：待评审  

  ---

  ## 目录

  1. 产品概述
  2. 目标用户与使用场景
  3. 功能需求
  4. UI设计与主题系统
  5. 数据库设计
  6. 后端服务设计（NAS Docker）
  7. 关键业务流程
  8. 非功能需求
  9. 开发里程碑
  10. 风险与开放问题
  11. AI能力设计

  ---

  ## 1. 产品概述

  ### 1.1 产品名称

  **嬷嬷的小箱子**

  ### 1.2 产品定位

  一款面向家庭用户的物品效期管理工具。以手机App为主要载体，支持完全本地单机使用，也可选择连接部署在NAS Docker中的后端服务，实现多设备同步与家庭共享。

  ### 1.3 双模式架构

  **模式A：单机模式（默认）**

  手机App独立运行，所有数据存储在手机本地SQLite数据库中，所有功能不依赖任何服务器。

  **模式B：NAS后端模式（可选）**

  用户可在NAS Docker中部署「嬷嬷的小箱子」后端容器，手机App手动配置连接后，数据自动同步到NAS，支持多设备同步与家庭成员共享。

  ```
  ┌────────────────────────────────────────────┐
  │             NAS（绿联DX4600）               │
  │                                            │
  │  Docker                                    │
  │  ├── momo-backend（本应用后端容器）           │
  │  │   ├── API服务                            │
  │  │   ├── 数据库（PostgreSQL）               │
  │  │   ├── 同步逻辑                            │
  │  │   └── AI代理（可选转发Ollama）            │
  │  │                                          │
  │  └── ollama（可选，独立容器）                 │
  │      └── 本地LLM                            │
  └────────────────────────────────────────────┘
                ↑ HTTP/HTTPS
                │ 用户手动配置
  ┌─────────────┴──────────────────────────────┐
  │              手机App                        │
  │                                            │
  │  ┌─────────────┐   ┌─────────────────────┐ │
  │  │  本地SQLite  │   │  本地OCR（ML Kit）   │ │
  │  └─────────────┘   └─────────────────────┘ │
  │                                            │
  │  模式A：单机模式（默认，不连后端）             │
  │  模式B：NAS后端模式（用户手动连接）            │
  └────────────────────────────────────────────┘
  ```

  ### 1.4 核心价值

  | 痛点                                   | 解决方案                                            |
  | :------------------------------------- | :-------------------------------------------------- |
  | 买回家的东西忘记过期时间，放到过期浪费 | 扫码/拍照/手动入库，自动计算到期日期，临期/过期提醒 |
  | 药品等关键物品过期后误用               | 分类管理+状态标识+推送提醒                          |
  | 家里多人各自买东西，不知道已有什么     | NAS模式下家庭组共享库存，多设备同步                 |
  | 包装丢了，不记得生产日期/保质期        | 历史记录沉淀，同款商品快速带入                      |
  | 快用完了忘记补货                       | 消耗记录+低库存阈值+采购清单+AI采购建议             |
  | 条码扫不出/无条码，录入麻烦            | AI拍照识别商品信息+日期自动解析                     |
  | 说明书看不懂/找不到重点                | 说明书OCR+智能问答                                  |

  ### 1.5 产品特色

  - **双模式架构**：单机永久可用，NAS后端可选增强，互不依赖
  - **主题系统**：多套完整皮肤一键切换，涵盖色彩、图标、吉祥物、文案语气、推送模板
  - **多批次管理**：同一商品支持多个批次独立追踪
  - **AI可插拔**：用户自配API Key，支持云端大模型与本地Ollama，不绑定任何服务商
  - **本地优先**：数据默认本地存储，用户主动授权后才上传
  - **历史沉淀**：同款商品历史录入信息自动带入

  ---

  ## 2. 目标用户与使用场景

  ### 2.1 目标用户

  | 用户画像             | 特征                               | 核心需求                       |
  | :------------------- | :--------------------------------- | :----------------------------- |
  | 家庭主力采购者       | 负责家中物品采购，常忘记已有的东西 | 快速入库、库存查看、采购提醒   |
  | 有老人/小孩的家庭    | 药品多，担心过期误用               | 药品分类、到期提醒、说明书问答 |
  | 注重减少浪费的人     | 不喜欢东西放到过期扔掉             | 临期提醒、消耗统计             |
  | 多成员共同生活的家庭 | 多人各自购买，信息不互通           | 家庭组共享（NAS模式）          |
  | NAS玩家              | 拥有绿联DX4600等设备               | 自部署后端、本地AI、数据自主   |

  ### 2.2 核心使用场景

  | 场景                   | 描述                               | 对应功能            | 模式     |
  | :--------------------- | :--------------------------------- | :------------------ | :------- |
  | 买完回家批量入库       | 从超市/药店回家，连续扫码录入      | 连续扫码模式        | 单机/NAS |
  | 无条码商品录入         | 散装食品、分装药品                 | AI拍照识别          | 单机/NAS |
  | 翻东西时查效期         | 在柜子里找到一盒药，不确定是否过期 | 扫码/搜索查询       | 单机/NAS |
  | 收到临期提醒           | 系统推送"有3件物品快过期了"        | 每日定时提醒        | 单机/NAS |
  | 用完一件物品           | 用掉最后一粒药/最后一瓶酱油        | 消耗操作            | 单机/NAS |
  | 看到快用完，准备采购   | 发现某物品数量不足                 | 低库存提醒+采购清单 | 单机/NAS |
  | 包装丢了想查日期       | 不记得上次买的生产日期             | 历史记录查询        | 单机/NAS |
  | 说明书查询             | 不确定药品用法用量                 | 说明书智能问答      | 单机/NAS |
  | 家人各自入库，实时共享 | 家人扫描入库，其他人同步看到       | 家庭组共享          | 仅NAS    |
  | 换手机数据迁移         | 从旧手机导入数据到新手机           | 导入导出            | 单机/NAS |

  ---

  ## 3. 功能需求

  ### 3.1 功能总览

  | 模块         | 功能                                                         | 优先级 | 单机模式 | NAS模式 |
  | :----------- | :----------------------------------------------------------- | :----- | :------- | :------ |
  | 商品管理     | 扫码入库、拍照入库、手动录入、多批次管理、消耗/补充          | P0     | ✅        | ✅       |
  | 识别系统     | 条码扫描、本地缓存匹配、API查询、AI拍照识别、手动补充        | P0     | ✅        | ✅       |
  | 日期管理     | 生产/到期/保质期双向计算、开封后保质期、AI日期解析           | P0     | ✅        | ✅       |
  | 库存管理     | 数量管理、低库存阈值、待采购清单、消耗记录                   | P0     | ✅        | ✅       |
  | 分类体系     | 二级分类、用户自定义                                         | P0     | ✅        | ✅       |
  | 历史记录     | 同款商品历史批次查询、常用商品快速录入                       | P0     | ✅        | ✅       |
  | 提醒系统     | 临期/过期/开封后临期/缺货提醒、每日定时推送                  | P0     | ✅        | ✅       |
  | 主题系统     | 多主题切换、文案语气随主题变化、AI主题生成                   | P0/P2  | ✅        | ✅       |
  | 图片管理     | 拍照保存（压缩）、OCR文字提取                                | P1     | ✅        | ✅       |
  | 说明书管理   | 拍照上传+OCR、外部链接跳转、智能问答                         | P1     | ✅        | ✅       |
  | 数据管理     | 导入/导出、去重、冲突处理                                    | P1     | ✅        | ✅       |
  | 账号系统     | 邮箱注册、家庭组邀请码                                       | P0     | ❌        | ✅       |
  | 多设备同步   | 自动同步、冲突处理                                           | P0     | ❌        | ✅       |
  | 后端连接管理 | 手动配置NAS地址、连接测试、断开/重连                         | P0     | ❌        | ✅       |
  | API配置      | 自定义条码API和AI API地址/Key、优先级调整                    | P1     | ✅        | ✅       |
  | AI能力       | 拍照识别、日期解析、自然语言录入、说明书问答、采购建议、主题生成 | P0-P2  | ✅        | ✅       |

  ### 3.2 商品管理

  #### 3.2.1 入库方式

  三种入库方式，用户可随时切换：

  **方式一：扫码入库（主入口）**

  1. 打开扫码页面
  2. 扫描商品条形码
  3. 系统按以下顺序查询商品信息：
     - 本地商品缓存表（`local_product_cache`）
     - 本地已录入商品（`products`）
     - 按优先级调用配置的条码API（Open Food Facts → 自定义API）
  4. 命中则自动填充商品信息；未命中则提示"未识别到商品，可选择拍照识别或手动填写"
  5. 填写批次信息
  6. 保存，完成入库

  **方式二：拍照入库（AI辅助）**

  1. 点击"拍照识别"
  2. 拍摄商品包装照片
  3. 本地OCR提取文字
  4. 调用用户配置的LLM解析商品信息
  5. 自动填充到录入表单
  6. 用户确认/修正
  7. 保存，完成入库

  **方式三：手动录入（兜底）**

  用户手动填写以下字段：

  | 字段         | 必填 | 说明                      |
  | :----------- | :--- | :------------------------ |
  | 商品名称     | ✅    |                           |
  | 条形码       | ❌    | 手动录入时可无条码        |
  | 品牌         | ❌    |                           |
  | 规格         | ❌    | 如"10片/盒"               |
  | 分类         | ❌    | 默认"未分类"              |
  | 生产日期     | ❌    | 与到期日期至少填一个      |
  | 到期日期     | ❌    | 与生产日期至少填一个      |
  | 保质期       | ❌    | 填了生产+保质期自动算到期 |
  | 购买日期     | ❌    |                           |
  | 数量         | ✅    | 默认1                     |
  | 存放位置     | ❌    |                           |
  | 购买渠道     | ❌    |                           |
  | 价格         | ❌    |                           |
  | 低库存阈值   | ❌    | 默认1                     |
  | 开封日期     | ❌    |                           |
  | 开封后保质期 | ❌    | 填了自动算开封后到期日    |
  | 备注         | ❌    |                           |
  | 标签         | ❌    | 自定义标签                |
  | 照片         | ❌    | 拍照保存                  |

  **连续录入模式**

  保存后自动进入下一个录入（扫码或拍照），减少重复操作。

  #### 3.2.2 多批次管理

  - 同一商品（相同条码或相同名称）可存在多个批次
  - 每个批次独立记录：生产日期、到期日期、数量、状态
  - 商品详情页按到期日期升序排列批次
  - 批次状态：`active`（在库）、`used_up`（已用完）、`expired`（已过期）、`discarded`（已丢弃）

  #### 3.2.3 消耗/补充操作

  - 每个批次卡片提供"消耗"按钮，点击数量减1
  - 数量减到0时，批次状态自动变为`used_up`
  - 提供"补充"按钮，可增加数量
  - 每次操作生成消耗记录，记录类型：`consume`（消耗）、`restock`（补充）、`adjust`（调整）

  #### 3.2.4 商品编辑/删除

  - 编辑：修改商品基本信息
  - 删除：删除整个商品及其所有批次（需二次确认）
  - 删除批次：单独删除某个批次

  ### 3.3 分类体系

  - 支持**二级分类**
  - 系统预设分类（所有用户可见）：

  ```
  📦 药品
    ├── 感冒药
    ├── 消炎药
    ├── 儿童药
    └── 处方药
  📦 食品
    ├── 零食
    ├── 调味品
    ├── 冷冻食品
    ├── 饮料
    └── 粮油干货
  📦 日用品
    ├── 清洁用品
    ├── 个人护理
    └── 纸品
  📦 化妆品
    ├── 护肤品
    ├── 彩妆
    └── 洗护
  ```

  - **用户自定义分类**：
    - 用户可新增/修改/删除自己的分类
    - 自定义分类仅该用户可见，不影响其他家庭成员
    - 一级分类下可添加二级分类
    - 分类支持排序

  ### 3.4 历史记录与常用商品

  - 当用户扫描/录入一个已存在条码的商品时，展示该商品的历史批次信息
  - 历史记录包含：历次录入的生产日期、到期日期、购买日期、数量、录入时间
  - 可用于包装丢失时参考
  - 商品可标记为"常用"，手动录入时优先展示，快速带入

  ### 3.5 提醒系统

  #### 3.5.1 提醒类型

  | 类型           | 触发条件                         | 默认阈值      |
  | :------------- | :------------------------------- | :------------ |
  | 临期提醒       | 到期日期 - 今天 ≤ 提前天数       | 7天（可配置） |
  | 过期提醒       | 到期日期 < 今天                  | -             |
  | 开封后临期提醒 | 开封后到期日期 - 今天 ≤ 提前天数 | 7天（可配置） |
  | 缺货提醒       | 当前数量 ≤ 低库存阈值            | 阈值默认1     |

  #### 3.5.2 提醒时机

  - 每日固定时间检查（默认9:00，可配置）
  - App打开时即时检查
  - 推送通知汇总所有提醒项

  #### 3.5.3 提醒方式

  | 阶段     | 方式                 |
  | :------- | :------------------- |
  | 单机模式 | 本地通知（系统推送） |
  | NAS模式  | 本地通知（系统推送） |

  #### 3.5.4 提醒文案（随主题变化）

  | 场景 | 默认主题            | 嬷嬷主题                          | 哆啦A梦主题                            |
  | :--- | :------------------ | :-------------------------------- | :------------------------------------- |
  | 汇总 | 您有3件物品即将过期 | 嬷嬷提醒您，箱中有3件物品时效将至 | 哆啦A梦提醒你：口袋里有3件东西快过期了 |
  | 过期 | 有1件物品已过期     | 有1件物品已过时效，请勿再用       | 有1件东西已经消失啦                    |
  | 缺货 | 有2件物品需要补货   | 箱中告急，有2件物品需补货         | 口袋快空了，需要补充2件道具            |

  ### 3.6 采购清单

  - 独立页面展示待采购物品
  - 自动来源：低库存触发的商品
  - AI来源：AI采购建议
  - 手动来源：用户手动添加
  - 支持勾选完成、删除、备注
  - 来源标记：`manual` / `low_stock` / `ai_suggestion`

  ### 3.7 说明书管理

  - **拍照上传**：用户拍摄说明书照片，自动压缩存储（宽度1080px，JPEG 80%质量）
  - **OCR提取**：提取说明书文字，存入数据库，支持搜索
  - **智能问答**：基于说明书OCR文字，用户自然语言提问，LLM生成回答
  - **外部链接跳转**：内置说明书搜索入口，跳转至外部网站（如用药助手、ManualsLib）

  ### 3.8 数据导入/导出

  #### 3.8.1 导出格式

  | 格式       | 用途                             |
  | :--------- | :------------------------------- |
  | JSON       | 完整备份，包含所有字段和关联关系 |
  | CSV        | 用户可读，用Excel打开            |
  | SQLite文件 | 完整数据库备份（高级）           |

  #### 3.8.2 导入规则

  - 支持导入JSON/CSV
  - **去重逻辑**：条码 + 生产日期 + 到期日期 三者相同 → 视为重复
  - **冲突处理**：默认跳过重复项，导入完成后显示报告（"成功导入X条，跳过Y条重复"）

  ### 3.9 账号系统与家庭组（仅NAS模式）

  #### 3.9.1 账号

  - 邮箱 + 密码注册/登录
  - 无需手机验证码
  - 密码bcrypt哈希存储

  #### 3.9.2 家庭组

  - 用户可创建家庭组，成为`owner`
  - 生成邀请码，其他成员输入邀请码加入
  - 角色：`owner`（拥有者）、`admin`（管理员）、`member`（普通成员）
  - 成员上限：10人
  - 权限区分：
    - `owner`：所有权限
    - `admin`：可编辑/删除商品，管理成员
    - `member`：可录入/消耗，不可删除

  ### 3.10 后端连接管理（仅NAS模式）

  - App内设置页提供"后端连接"入口
  - 填写项：
    - NAS IP地址（如 `192.168.1.100`）
    - 端口（默认 `8080`）
    - 邮箱
    - 密码
  - 提供"连接测试"按钮
  - 连接成功后标记为"已连接"
  - 可随时断开，自动回到单机模式
  - 断开后本地数据保留
  - 重新连接后自动增量同步
  - 首页顶部显示连接状态：
    - 单机模式：灰色图标"本机"
    - NAS模式：绿色图标"已连接"
    - 连接失败：黄色警告，点击查看详情

  ### 3.11 API配置

  #### 3.11.1 条码查询API

  - 用户可自定义API地址和Key
  - API优先级可调整（数字越小越优先）
  - 默认API列表：
    - Open Food Facts（免费，无需Key）
  - 查询顺序：本地缓存 → 已录入商品 → 自定义API（按优先级）→ 手动/拍照

  #### 3.11.2 AI服务API

  - 用户可自定义AI提供商、API地址、Key、模型名称
  - 支持的服务商见第11章

  ### 3.12 图片与OCR

  - 商品图片：拍照后自动压缩（宽度1080px，JPEG 80%质量，约100-200KB）
  - 说明书图片：同上
  - 本地OCR：Google ML Kit（免费、离线、支持中文）
  - OCR文字存入数据库，支持搜索
  - 图片允许上传云端（用于AI视觉识别），用户可授权

  ---

  ## 4. UI设计与主题系统

  ### 4.1 设计原则

  - **主题可插拔**：主题是皮肤，核心功能不变
  - **文案随主题**：同一操作在不同主题下文案不同
  - **视觉一致性**：色彩、图标、吉祥物、装饰元素统一

  ### 4.2 主题系统架构

  ```
  主题（Theme）
  ├── 基础层（所有主题共用）
  │   ├── 布局结构
  │   ├── 交互逻辑
  │   ├── 功能图标（基础线框）
  │   └── 状态色语义（绿=正常，黄=临期，红=过期）
  ├── 视觉层（主题切换）
  │   ├── 色彩方案
  │   ├── 装饰元素
  │   ├── 空状态插画
  │   └── 启动画面
  ├── 角色层（主题切换）
  │   ├── 吉祥物形象
  │   ├── 出现场景
  │   └── 动作库
  └── 文案层（主题切换）
      ├── 界面文案
      ├── 推送通知模板
      └── 提醒语气
  ```

  ### 4.3 主题清单

  | 主题ID      | 名称          | 风格         | 吉祥物    | 优先级 |
  | :---------- | :------------ | :----------- | :-------- | :----- |
  | `default`   | 简约生活      | 中性现代     | 无        | P0     |
  | `momo`      | 嬷嬷的小箱子  | 古风宫廷     | Q版嬷嬷   | P0     |
  | `doraemon`  | 哆啦A梦的口袋 | 未来蓝白     | 铃铛/蓝胖 | P1     |
  | `dark`      | 深夜模式      | 暗色简约     | 无        | P0     |
  | `ai_custom` | AI生成主题    | 用户描述生成 | AI生成    | P2     |

  ### 4.4 默认主题：简约生活

  | 维度     | 规范                                       |
  | :------- | :----------------------------------------- |
  | 主色     | `#4A90D9`                                  |
  | 背景色   | `#F7F8FA`                                  |
  | 卡片色   | `#FFFFFF`                                  |
  | 文字主色 | `#2C3E50`                                  |
  | 文字次色 | `#8C9BA5`                                  |
  | 状态色   | 绿 `#52C41A` / 黄 `#FAAD14` / 红 `#FF4D4F` |
  | 图标风格 | 线性圆角，现代简洁                         |
  | 吉祥物   | 无                                         |
  | 文案     | "添加物品""即将过期""库存不足""待采购"     |
  | 推送文案 | "您有3件物品即将过期，请及时处理。"        |

  ### 4.5 嬷嬷主题：嬷嬷的小箱子

  | 维度     | 规范                                              |
  | :------- | :------------------------------------------------ |
  | 主色     | 宫墙红 `#A63A3A`                                  |
  | 背景色   | 旧纸黄 `#F5EBDD`                                  |
  | 卡片色   | 暖白 `#FFFBF2`，木纹描边                          |
  | 文字主色 | 墨色 `#3C3C3C`                                    |
  | 文字次色 | 灰褐 `#8B7355`                                    |
  | 状态色   | 正常 `#6B8E5A` / 临期 `#D9A13B` / 过期 `#B84C4C`  |
  | 图标风格 | 线性+古风元素（药葫芦、食盒、扫帚、铜镜）         |
  | 吉祥物   | Q版嬷嬷（盘发、古装、和蔼），有表情包和动作库     |
  | 文案     | "呈入箱中""时效将至""箱中告急""内务府采买单"      |
  | 推送文案 | "嬷嬷提醒您，箱中有3件物品时效将至，请及时查看～" |
  | 装饰     | 箱角花纹、印章感标签、云纹分隔线                  |
  | 空状态   | 嬷嬷站在空箱子旁边，配文"箱中空空，嬷嬷等您呈入"  |

  ### 4.6 哆啦A梦主题：哆啦A梦的口袋

  | 维度     | 规范                                                 |
  | :------- | :--------------------------------------------------- |
  | 主色     | 哆啦蓝 `#1E90D2`                                     |
  | 背景色   | 天空白 `#F0F7FC`                                     |
  | 卡片色   | 白色，大圆角                                         |
  | 文字主色 | 深蓝灰 `#2A3B4C`                                     |
  | 文字次色 | `#7A8FA3`                                            |
  | 状态色   | 正常 `#4CAF50` / 临期 `#FFB300` / 过期 `#F44336`     |
  | 图标风格 | 圆润面性                                             |
  | 吉祥物   | 铃铛/蓝胖形象（版权风险提示）                        |
  | 文案     | "放进四次元口袋""即将消失""口袋快空了""未来采买清单" |
  | 推送文案 | "哆啦A梦提醒你：口袋里有3件东西快过期了！"           |
  | 装饰     | 四次元口袋、铃铛、竹蜻蜓元素                         |
  | 空状态   | 口袋图案，配文"四次元口袋空空的"                     |

  ### 4.7 深夜模式

  | 维度     | 规范                                       |
  | :------- | :----------------------------------------- |
  | 主色     | `#3A7BD5`                                  |
  | 背景色   | `#1E1E1E`                                  |
  | 卡片色   | `#2A2A2A`                                  |
  | 文字主色 | `#E0E0E0`                                  |
  | 文字次色 | `#8A8A8A`                                  |
  | 状态色   | 绿 `#4CAF50` / 黄 `#FFC107` / 红 `#EF5350` |
  | 图标风格 | 同默认主题                                 |
  | 吉祥物   | 无                                         |
  | 文案     | 同默认主题                                 |

  ### 4.8 AI生成主题

  - 用户描述想要的主题风格
  - LLM生成主题JSON配置
  - 可选文生图生成吉祥物/装饰图
  - 预览后保存为主题

  ### 4.9 主题切换机制

  - 设置页提供主题列表和预览图
  - 切换即时生效，无需重启
  - 主题配置存储在用户级设置，不影响其他家庭成员
  - 支持跟随系统深色模式自动切换（可选）

  ### 4.10 主题扩展能力

  - 主题以JSON配置+资源包形式定义
  - 预留"导入自定义主题"能力
  - 主题资源包含：色彩值、图标集、吉祥物图集、文案映射表

  ### 4.11 页面结构（主题无关）

  ```
  底部导航（4个Tab）
  ├── 库存（首页）
  ├── 采买单
  ├── 提醒
  └── 我的
  ```

  #### 4.11.1 库存页

  - 顶部：搜索栏（提示文案随主题变化）+ 后端连接状态图标
  - 筛选区：分类（横向滚动）+ 状态（全部/临期/过期/缺货）
  - 列表卡片：物品名称+规格、分类标签、数量、到期日期（状态色）、存放位置
  - 悬浮按钮：扫码入库（长按或旁边小按钮切换拍照入库）
  - 排序：默认按到期日期升序

  #### 4.11.2 扫码/拍照入库页

  - 标题随主题变化
  - 取景框样式随主题变化
  - 底部："手动填写"按钮 + 切换扫码/拍照
  - 保存后自动进入下一个录入

  #### 4.11.3 商品详情页

  - 商品基本信息区
  - 批次卡片列表（按到期日升序）
  - 每张批次卡片：生产日期→到期日期、数量、消耗按钮、开封后到期日期
  - 历史记录区
  - 底部操作：编辑 / 消耗 / 补充 / 删除

  #### 4.11.4 提醒页

  - 吉祥物 + 汇总语（随主题变化）
  - 分类标签：临期 / 过期 / 开封后临期 / 缺货
  - 列表按紧急程度排序

  #### 4.11.5 采买单页

  - 待采购列表：物品名+需购数量+备注
  - 已购记录：可勾选完成
  - 手动添加采购项
  - AI采购建议入口

  #### 4.11.6 我的页

  - 用户信息
  - 后端连接管理（NAS模式）
  - 家庭组管理（NAS模式）
  - 数据导入/导出
  - 说明书库
  - 主题设置（含AI主题生成入口）
  - API设置（条码API + AI API）
  - 关于

  ---

  ## 5. 数据库设计（建议）

  ### 5.1 本地数据库（App端 SQLite）

  以下表在手机本地始终存在，单机模式和NAS模式均使用：

  #### 5.1.1 products（商品表）

  ```sql
  CREATE TABLE products (
      id              TEXT PRIMARY KEY,
      family_id       TEXT,
      barcode         TEXT,
      name            TEXT NOT NULL,
      brand           TEXT,
      specification   TEXT,
      category_id     TEXT,
      image_url       TEXT,
      image_ocr_text  TEXT,
      manual_url      TEXT,
      manual_image    TEXT,
      manual_ocr_text TEXT,
      notes           TEXT,
      tags            TEXT,
      is_favorite     INTEGER DEFAULT 0,
      created_by      TEXT,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      sync_status     TEXT DEFAULT 'synced'
  );
  
  CREATE INDEX idx_products_barcode ON products(barcode);
  CREATE INDEX idx_products_name ON products(name);
  CREATE INDEX idx_products_category ON products(category_id);
  ```

  #### 5.1.2 product_batches（商品批次表）

  ```sql
  CREATE TABLE product_batches (
      id                          TEXT PRIMARY KEY,
      product_id                  TEXT,
      family_id                   TEXT,
      production_date             DATE,
      expiry_date                 DATE NOT NULL,
      shelf_life_days             INTEGER,
      shelf_life_months           INTEGER,
      purchase_date               DATE,
      opened_date                 DATE,
      shelf_life_after_opening_days INTEGER,
      expiry_after_opening        DATE,
      quantity                    INTEGER DEFAULT 1,
      initial_quantity            INTEGER DEFAULT 1,
      low_stock_threshold         INTEGER DEFAULT 1,
      storage_location            TEXT,
      supplier                    TEXT,
      price                       DECIMAL(10,2),
      status                      TEXT DEFAULT 'active',
      barcode                     TEXT,
      created_by                  TEXT,
      created_at                  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at                  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      sync_status                 TEXT DEFAULT 'synced'
  );
  
  CREATE INDEX idx_batches_expiry ON product_batches(expiry_date);
  CREATE INDEX idx_batches_status ON product_batches(status);
  CREATE INDEX idx_batches_product ON product_batches(product_id);
  ```

  #### 5.1.3 consumption_records（消耗记录表）

  ```sql
  CREATE TABLE consumption_records (
      id              TEXT PRIMARY KEY,
      batch_id        TEXT,
      family_id       TEXT,
      quantity_change INTEGER NOT NULL,
      record_type     TEXT NOT NULL,
      notes           TEXT,
      created_by      TEXT,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      sync_status     TEXT DEFAULT 'synced'
  );
  ```

  #### 5.1.4 shopping_list（采购清单表）

  ```sql
  CREATE TABLE shopping_list (
      id              TEXT PRIMARY KEY,
      family_id       TEXT,
      product_id      TEXT,
      item_name       TEXT,
      quantity_needed INTEGER DEFAULT 1,
      is_purchased    INTEGER DEFAULT 0,
      source          TEXT DEFAULT 'manual',
      notes           TEXT,
      created_by      TEXT,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      purchased_at    TIMESTAMP,
      sync_status     TEXT DEFAULT 'synced'
  );
  ```

  #### 5.1.5 categories（分类表）

  ```sql
  CREATE TABLE categories (
      id              TEXT PRIMARY KEY,
      family_id       TEXT,
      user_id         TEXT,
      parent_id       TEXT,
      name            TEXT NOT NULL,
      icon            TEXT,
      sort_order      INTEGER DEFAULT 0,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      sync_status     TEXT DEFAULT 'synced'
  );
  ```

  #### 5.1.6 reminder_settings（提醒设置表）

  ```sql
  CREATE TABLE reminder_settings (
      id              TEXT PRIMARY KEY,
      user_id         TEXT,
      family_id       TEXT,
      reminder_type   TEXT NOT NULL,
      advance_days    INTEGER DEFAULT 7,
      is_enabled      INTEGER DEFAULT 1,
      notify_time     TEXT DEFAULT '09:00',
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.1.7 local_product_cache（本地商品缓存表）

  ```sql
  CREATE TABLE local_product_cache (
      id              TEXT PRIMARY KEY,
      barcode         TEXT UNIQUE NOT NULL,
      name            TEXT,
      brand           TEXT,
      specification   TEXT,
      category_hint   TEXT,
      source          TEXT,
      data_source_api TEXT,
      extra_data      TEXT,
      usage_count     INTEGER DEFAULT 0,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.1.8 api_configs（条码API配置表）

  ```sql
  CREATE TABLE api_configs (
      id              TEXT PRIMARY KEY,
      user_id         TEXT,
      family_id       TEXT,
      api_name        TEXT NOT NULL,
      api_url         TEXT NOT NULL,
      api_key         TEXT,
      priority        INTEGER DEFAULT 100,
      is_enabled      INTEGER DEFAULT 1,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.1.9 theme_settings（主题设置表）

  ```sql
  CREATE TABLE theme_settings (
      id              TEXT PRIMARY KEY,
      user_id         TEXT,
      theme_id        TEXT NOT NULL DEFAULT 'default',
      custom_config   TEXT,
      updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.1.10 ai_configs（AI配置表）

  ```sql
  CREATE TABLE ai_configs (
      id              TEXT PRIMARY KEY,
      user_id         TEXT,
      provider        TEXT NOT NULL,
      api_url         TEXT,
      api_key         TEXT,
      model_name      TEXT,
      is_enabled      INTEGER DEFAULT 1,
      is_default      INTEGER DEFAULT 0,
      usage_count     INTEGER DEFAULT 0,
      total_cost      REAL DEFAULT 0,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.1.11 ai_parse_logs（AI解析日志表）

  ```sql
  CREATE TABLE ai_parse_logs (
      id              TEXT PRIMARY KEY,
      user_id         TEXT,
      input_type      TEXT NOT NULL,
      input_text      TEXT,
      output_json     TEXT,
      confidence      REAL,
      user_confirmed  INTEGER DEFAULT 0,
      user_corrected  INTEGER DEFAULT 0,
      provider        TEXT,
      model_name      TEXT,
      cost            REAL DEFAULT 0,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.1.12 ai_qa_history（AI问答历史表）

  ```sql
  CREATE TABLE ai_qa_history (
      id              TEXT PRIMARY KEY,
      user_id         TEXT,
      product_id      TEXT,
      question        TEXT NOT NULL,
      answer          TEXT NOT NULL,
      context_text    TEXT,
      provider        TEXT,
      cost            REAL DEFAULT 0,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.1.13 backend_connection（后端连接配置表）

  ```sql
  CREATE TABLE backend_connection (
      id              TEXT PRIMARY KEY,
      server_url      TEXT NOT NULL,
      port            INTEGER DEFAULT 8080,
      email           TEXT,
      password_hash   TEXT,
      is_connected    INTEGER DEFAULT 0,
      last_connected_at TIMESTAMP,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.1.14 sync_meta（同步元数据表）

  ```sql
  CREATE TABLE sync_meta (
      id              TEXT PRIMARY KEY,
      table_name      TEXT NOT NULL,
      last_sync_at    TIMESTAMP,
      last_sync_hash  TEXT,
      pending_changes INTEGER DEFAULT 0
  );
  ```

  ### 5.2 后端数据库（NAS PostgreSQL）

  以下表仅在NAS后端存在：

  #### 5.2.1 users（用户表）

  ```sql
  CREATE TABLE users (
      id              TEXT PRIMARY KEY,
      email           TEXT UNIQUE NOT NULL,
      password_hash   TEXT NOT NULL,
      nickname        TEXT,
      avatar_url      TEXT,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.2.2 families（家庭组表）

  ```sql
  CREATE TABLE families (
      id              TEXT PRIMARY KEY,
      name            TEXT NOT NULL,
      invite_code     TEXT UNIQUE NOT NULL,
      owner_id        TEXT REFERENCES users(id),
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.2.3 family_members（家庭成员表）

  ```sql
  CREATE TABLE family_members (
      id              TEXT PRIMARY KEY,
      family_id       TEXT REFERENCES families(id),
      user_id         TEXT REFERENCES users(id),
      role            TEXT DEFAULT 'member',
      joined_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      UNIQUE(family_id, user_id)
  );
  ```

  #### 5.2.4 sync_devices（同步设备表）

  ```sql
  CREATE TABLE sync_devices (
      id              TEXT PRIMARY KEY,
      user_id         TEXT REFERENCES users(id),
      device_name     TEXT,
      device_id       TEXT UNIQUE,
      last_seen_at    TIMESTAMP,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  #### 5.2.5 sync_log（同步日志表）

  ```sql
  CREATE TABLE sync_log (
      id              TEXT PRIMARY KEY,
      family_id       TEXT,
      device_id       TEXT,
      sync_type       TEXT,
      records_synced  INTEGER,
      status          TEXT,
      error_message   TEXT,
      created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ```

  ---

  ## 6. 后端服务设计（NAS Docker）

  ### 6.1 容器信息

  | 项目     | 内容                           |
  | :------- | :----------------------------- |
  | 容器名   | `momo-backend`                 |
  | 镜像     | 待定（Go/Node/Python）         |
  | 端口     | 默认 `8080`（可配置）          |
  | 数据卷   | `./data:/data`                 |
  | 依赖     | 仅需Docker                     |
  | 可选依赖 | Ollama容器                     |
  | 部署方式 | Docker Compose / 绿联Docker UI |

  ### 6.2 后端职责

  | 职责        | 说明                         |
  | :---------- | :--------------------------- |
  | 用户认证    | 注册/登录/JWT签发            |
  | 家庭组管理  | 创建/邀请码加入/权限管理     |
  | 数据同步    | 接收客户端推送，下发增量数据 |
  | 数据存储    | PostgreSQL持久化             |
  | AI代理      | 可选转发请求到Ollama         |
  | 条码API代理 | 可选，减少客户端直连         |

  ### 6.3 API设计

  | 方法 | 路径                    | 说明                   |
  | :--- | :---------------------- | :--------------------- |
  | POST | `/api/auth/register`    | 注册                   |
  | POST | `/api/auth/login`       | 登录                   |
  | POST | `/api/family/create`    | 创建家庭组             |
  | POST | `/api/family/join`      | 邀请码加入             |
  | GET  | `/api/sync/pull`        | 拉取增量数据           |
  | POST | `/api/sync/push`        | 推送本地变更           |
  | POST | `/api/sync/conflict`    | 冲突处理               |
  | GET  | `/api/ai/ollama/status` | 检查Ollama可用性       |
  | POST | `/api/ai/ollama/chat`   | 代理Ollama请求（可选） |

  ### 6.4 Ollama集成（可选）

  - 后端容器**不内置**Ollama
  - 用户可另行部署Ollama容器
  - 后端通过环境变量配置Ollama地址：
    ```
    OLLAMA_HOST=http://ollama:11434
    ```
  - 若未配置，AI代理功能关闭，不影响其他功能

  ### 6.5 部署示例（docker-compose.yml）

  ```yaml
  version: '3.8'
  
  services:
    momo-backend:
      image: momo-backend:latest
      container_name: momo-backend
      ports:
        - "8080:8080"
      volumes:
        - ./data:/data
      environment:
        - DB_PATH=/data/momo.db
        - OLLAMA_HOST=http://ollama:11434
      restart: unless-stopped
  
    ollama:
      image: ollama/ollama:latest
      container_name: ollama
      ports:
        - "11434:11434"
      volumes:
        - ./ollama:/root/.ollama
      restart: unless-stopped
  ```

  ### 6.6 后端技术选型建议

  | 方案             | 优点                     | 缺点         | 推荐度 |
  | :--------------- | :----------------------- | :----------- | :----- |
  | Go               | 单二进制部署，资源占用小 | 学习曲线中等 | ⭐⭐⭐⭐⭐  |
  | Node.js (NestJS) | JS生态，与前端同语言     | 内存占用稍高 | ⭐⭐⭐⭐   |
  | Python (FastAPI) | 开发快                   | 部署稍复杂   | ⭐⭐⭐⭐   |

  ---

  ## 7. 关键业务流程

  ### 7.1 单机模式（默认）

  所有操作直接读写本地SQLite，无网络依赖，永久可用。

  ### 7.2 扫码入库流程

  ```
  用户点击"扫码入库"
      ↓
  扫描条码
      ↓
  ① 查 local_product_cache
      ├── 命中 → 自动填充 → 进入批次填写
      └── 未命中 ↓
  ② 查 products（本地已录入）
      ├── 命中 → 提示已有 → 自动填充 → 展示历史批次 → 进入批次填写
      └── 未命中 ↓
  ③ 按优先级调用条码API
      ├── 命中 → 填充 → 存入 local_product_cache → 进入批次填写
      └── 未命中 ↓
  ④ 提示："未识别到商品，可选择拍照识别或手动填写"
      ├── 拍照识别 → 走AI拍照流程
      └── 手动填写 → 存入 local_product_cache
      ↓
  填写批次信息
      ↓
  保存 → 完成入库 → 自动进入下一录入
  ```

  ### 7.3 AI拍照识别流程

  ```
  用户点击"拍照识别"
      ↓
  拍摄商品包装照片
      ↓
  本地OCR（ML Kit）提取文字
      ↓
  检查用户是否已配置AI服务
      ├── 未配置 → 提示配置API Key，或仅使用OCR文字手动填写
      └── 已配置 ↓
      ├── 仅OCR文字足以解析（文本型LLM）
      │   → 发送OCR文字给LLM
      │   → 解析出商品名称/品牌/规格/日期
      └── OCR置信度低或需要视觉理解
          → 发送图片给视觉LLM
          → 解析商品信息
      ↓
  返回结构化JSON
      ↓
  自动填充录入表单
      ↓
  用户确认/修正
      ↓
  保存入库
      ↓
  记录 ai_parse_logs
  ```

  ### 7.4 日期双向计算

  ```
  输入生产日期 + 保质期（天/月） → 自动计算到期日期
  输入到期日期 + 保质期 → 反推生产日期
  输入开封日期 + 开封后保质期 → 自动计算开封后到期日期
  AI解析日期 → 自动填入对应字段 → 用户确认
  ```

  ### 7.5 每日提醒流程

  ```
  到达用户设定的提醒时间（如9:00）
      ↓
  检查所有 active 状态的批次
      ├── 到期日期 - 今天 ≤ 提醒天数 → 加入临期列表
      ├── 到期日期 < 今天 → 加入过期列表
      ├── 开封后到期日期 - 今天 ≤ 提醒天数 → 加入开封临期列表
      └── 数量 ≤ 低库存阈值 → 加入缺货列表
      ↓
  汇总为一条推送通知（文案随主题）
      ↓
  用户点击 → 打开App提醒页
  ```

  ### 7.6 消耗流程

  ```
  商品详情页 → 选择批次 → 点击"消耗"
      ↓
  数量 -1
      ↓
  生成消耗记录
      ↓
  数量 = 0？
      ├── 是 → 批次状态变为 used_up
      └── 否 → 检查是否 ≤ 低库存阈值
                └── 是 → 加入采购清单 + 触发缺货提醒
  ```

  ### 7.7 NAS模式连接流程

  ```
  设置页 → 后端连接
      ↓
  填写 NAS IP + 端口 + 邮箱 + 密码
      ↓
  点击"连接测试"
      ↓
  成功 → 保存配置 → 标记为已连接
      ↓
  触发首次同步（增量或全量）
      ↓
  同步完成 → 显示"已连接"
  ```

  ### 7.8 双向同步流程

  ```
  手机本地有变更 → 记录到 sync_meta（pending_changes=1）
      ↓
  触发同步时机：
    - App启动时
    - 每次数据变更后（防抖5秒）
    - 手动下拉刷新
      ↓
  POST /api/sync/push（推送本地变更）
      ↓
  GET /api/sync/pull（拉取服务端新数据）
      ↓
  合并策略：以服务端为准（家庭共享场景）
      ↓
  更新 sync_meta（last_sync_at, last_sync_hash）
  ```

  ### 7.9 断开NAS连接

  ```
  设置页 → 断开连接
      ↓
  停止同步
      ↓
  本地数据保留
      ↓
  回到单机模式
  ```

  ### 7.10 重新连接

  ```
  重新连接成功
      ↓
  对比 sync_meta
      ↓
  拉取服务端最新数据
      ↓
  合并本地未同步变更（如有冲突按策略处理）
  ```

  ### 7.11 说明书智能问答流程

  ```
  用户打开商品详情页 → 说明书区域 → 点击问答入口
      ↓
  输入问题（文字或语音）
      ↓
  检索该商品的 manual_ocr_text
      ↓
  将说明书文字 + 用户问题 发送给LLM
      ↓
  LLM生成回答
      ↓
  展示回答 + 免责声明："仅供参考，请遵医嘱"
      ↓
  记录 ai_qa_history
  ```

  ### 7.12 AI采购建议流程

  ```
  用户打开采买单 → 点击"AI采购建议"
      ↓
  系统分析消耗记录（近30天/90天）
      ↓
  计算每件物品的消耗速度
      ↓
  预测需要补货的时间
      ↓
  结合当前库存，生成建议清单
      ↓
  用户确认 → 加入采购清单（source='ai_suggestion'）
  ```

  ### 7.13 AI主题生成流程

  ```
  设置页 → 主题设置 → "AI生成主题"
      ↓
  用户输入描述："我想要一个太空主题，紫色和深蓝色，科幻感"
      ↓
  LLM生成主题JSON（色彩方案+文案风格）
      ↓
  （可选）文生图模型生成吉祥物/装饰图
      ↓
  预览效果
      ↓
  用户确认 → 保存为主题
  ```

  ### 7.14 主题切换流程

  ```
  设置页 → 主题设置
      ↓
  展示主题列表（带预览图）
      ↓
  用户选择主题
      ↓
  更新 theme_settings 表
      ↓
  全局UI即时刷新（色彩/图标/吉祥物/文案）
      ↓
  推送通知文案模板同步更新
  ```

  ---

  ## 8. 非功能需求

  ### 8.1 性能

  | 指标             | 单机模式             | NAS模式             |
  | :--------------- | :------------------- | :------------------ |
  | 首页加载         | <1秒（1000条数据内） | <1秒（本地缓存）    |
  | 扫码识别         | <2秒                 | <2秒                |
  | 本地搜索         | <500ms               | <500ms              |
  | 图片压缩         | <1秒                 | <1秒                |
  | AI文本解析       | <3秒                 | <3秒                |
  | AI图片解析       | <5秒                 | <5秒                |
  | 同步耗时（增量） | -                    | <5秒                |
  | 首次全量同步     | -                    | <30秒（1000条数据） |

  ### 8.2 可靠性

  - 单机模式：无网络依赖，永久可用
  - NAS模式：后端不可用时自动降级为单机模式，不阻塞本地操作
  - 同步失败自动重试（指数退避，最多5次）
  - 同步冲突以服务端为准

  ### 8.3 安全

  - 密码bcrypt哈希存储
  - 后端JWT认证
  - 家庭组数据隔离
  - 邀请码加密
  - 本地数据库加密（可选）
  - API Key加密存储
  - HTTPS可选（用户可配置反代）

  ### 8.4 隐私

  - 数据默认本地存储
  - 用户主动授权后才上传云端
  - AI请求内容仅用于解析，不用于训练
  - 可随时清除AI日志和问答历史

  ### 8.5 兼容性

  - Android 16.0+
  - iOS 27.0+
  - 绿联DX4600 Docker
  - Ollama（可选，不绑定）

  ---

  ## 9. 开发里程碑

  ### V0.1 单机MVP

  - [ ] 手动录入商品+批次
  - [ ] 到期日期计算
  - [ ] 本地SQLite数据库
  - [ ] 库存列表展示
  - [ ] 默认主题（简约生活）

  ### V0.2 扫码版

  - [ ] 条形码扫描
  - [ ] 本地缓存匹配
  - [ ] Open Food Facts API接入
  - [ ] 手动填写兜底

  ### V0.3 提醒版

  - [ ] 本地通知
  - [ ] 提醒设置
  - [ ] 提醒页

  ### V0.4 完善版

  - [ ] 图片+本地OCR（ML Kit）
  - [ ] 消耗管理
  - [ ] 采购清单
  - [ ] 导入/导出（JSON/CSV）
  - [ ] 历史记录

  ### V0.5 主题版

  - [ ] 主题系统架构
  - [ ] 默认主题（简约生活）
  - [ ] 嬷嬷主题
  - [ ] 深夜模式
  - [ ] 文案随主题切换

  ### V0.6 AI基础版

  - [ ] AI配置模块（用户自配API Key）
  - [ ] LLM日期解析（OCR文字 → 结构化日期）
  - [ ] 自然语言录入
  - [ ] AI解析日志与用户修正追踪

  ### V0.7 AI视觉版

  - [ ] 拍照识别商品信息（视觉LLM）
  - [ ] 图片上传授权
  - [ ] AI分类建议

  ### V0.8 后端服务版（NAS）

  - [ ] momo-backend容器开发
  - [ ] 用户认证（注册/登录/JWT）
  - [ ] 家庭组管理（创建/邀请/权限）
  - [ ] 双向同步（push/pull）
  - [ ] Docker Compose部署
  - [ ] 后端连接管理（App端）

  ### V0.9 说明书AI版

  - [ ] 说明书OCR入库
  - [ ] 说明书智能问答
  - [ ] 问答历史

  ### V1.0 NAS完整版

  - [ ] 多设备同步完善
  - [ ] 冲突处理优化
  - [ ] Ollama代理接口
  - [ ] 条码API代理
  - [ ] 同步日志

  ### V1.1 扩展主题

  - [ ] 哆啦A梦主题
  - [ ] 自定义主题导入

  ### V1.2 AI增强版

  - [ ] AI采购建议
  - [ ] AI主题生成
  - [ ] 消耗速度统计与预测

  ---

  ## 10. 风险与开放问题

  ### 10.1 风险

  | 风险                     | 影响                 | 应对                               |
  | :----------------------- | :------------------- | :--------------------------------- |
  | 条形码API覆盖率不足      | 扫码识别率低         | 本地缓存+AI拍照+手动录入兜底       |
  | 免费API不稳定            | 查询失败             | 多API备用+手动录入                 |
  | AI幻觉/识别错误          | 入库数据错误         | 所有AI结果需用户确认，记录修正日志 |
  | IP版权（容嬷嬷/哆啦A梦） | 上架风险             | 可替换形象或取得授权               |
  | 本地通知受限（iOS）      | 提醒不及时           | 打开时检查+后期可接入推送服务      |
  | 同步冲突                 | 数据不一致           | 服务端优先+冲突报告                |
  | NAS部署门槛              | 部分用户无法使用同步 | 单机模式不受影响                   |
  | AI成本                   | 用户使用量过大       | 用户自配Key，成本自担              |
  | Ollama本地推理慢         | 体验差               | 仅做可选，推荐云端API              |
  | 隐私合规                 | 图片上传涉及隐私     | 明确授权流程，隐私政策，数据可删除 |

  ### 10.2 开放问题

  - [ ] 技术栈最终选型（Flutter/RN/uni-app）
  - [ ] 后端语言（Go/Node.js/Python）
  - [ ] 是否加入消耗速度统计图表可视化
  - [ ] 是否做社区共享数据库
  - [ ] App图标最终设计
  - [ ] 说明书外部跳转的具体站点选择
  - [ ] AI默认提供商是否内置（用户不配Key时的降级方案）
  - [ ] OCR是否需要在NAS端跑更重的模型（如PaddleOCR）

  ---

  ## 11. AI能力设计

  ### 11.1 AI设计原则

  | 原则                | 说明                                          |
  | :------------------ | :-------------------------------------------- |
  | **AI可插拔**        | 用户可完全不启用AI，核心功能不受影响          |
  | **用户自配Key优先** | 用户填入自己的API Key，成本自担，隐私自主     |
  | **本地优先**        | 能本地OCR解决的，不上云；能文本解决的，不传图 |
  | **人工确认**        | AI识别结果必须用户确认后才入库                |
  | **隐私保护**        | 图片/文字仅在用户授权下上传，敏感信息脱敏     |
  | **不绑定服务商**    | 支持OpenAI/Claude/通义/智谱/DeepSeek/Ollama等 |
  | **NAS友好**         | 预留Ollama接口，本地AI零成本方案              |

  ### 11.2 AI能力总览

  | 能力           | 优先级 | 输入              | 输出                | 技术方案         |
  | :------------- | :----- | :---------------- | :------------------ | :--------------- |
  | 日期文字解析   | P0     | OCR文字           | 结构化日期JSON      | 文本LLM          |
  | 拍照识别商品   | P0     | 商品照片          | 名称/品牌/规格/日期 | 视觉LLM          |
  | 自然语言录入   | P1     | 用户描述文字/语音 | 结构化商品信息      | 文本LLM          |
  | 说明书智能问答 | P1     | 用户问题          | 回答                | 文本LLM          |
  | AI采购建议     | P2     | 消耗记录          | 采购建议            | 统计规则+LLM可选 |
  | AI主题生成     | P2     | 用户风格描述      | 主题JSON+图片       | LLM+文生图       |

  ### 11.3 支持的服务商

  | 服务商           | 类型 | API地址                          | 备注                  |
  | :--------------- | :--- | :------------------------------- | :-------------------- |
  | OpenAI           | 云端 | `https://api.openai.com/v1`      | GPT-4o支持视觉        |
  | Anthropic Claude | 云端 | `https://api.anthropic.com`      | Claude Sonnet支持视觉 |
  | 通义千问         | 云端 | `https://dashscope.aliyuncs.com` | qwen-vl支持视觉       |
  | 智谱GLM          | 云端 | `https://open.bigmodel.cn`       | glm-4v支持视觉        |
  | DeepSeek         | 云端 | `https://api.deepseek.com`       | 文本为主，性价比高    |
  | Ollama           | 本地 | `http://{NAS_IP}:11434`          | 免费，需NAS支持       |
  | 自定义           | 任意 | 用户填写                         | 兼容OpenAI格式        |

  ### 11.4 日期文字解析（P0）

  **场景**：拍照OCR后，得到日期相关文字，需要解析成结构化数据。

  **输入示例**：
  ```
  "EXP 2025/06"
  "有效期至2026.01.15"
  "MFG 20240101 EXP 20251231"
  "保质期：24个月"
  "请在2025年6月前使用"
  ```

  **LLM Prompt模板**：
  ```
  你是商品日期解析助手。请从以下OCR文字中提取日期信息。
  OCR文字：{ocr_text}
  请返回JSON格式：
  {
    "production_date": "YYYY-MM-DD或null",
    "expiry_date": "YYYY-MM-DD或null",
    "shelf_life_months": 数字或null,
    "shelf_life_days": 数字或null,
    "confidence": 0-1的置信度
  }
  只返回JSON，不要其他文字。
  ```

  **输出示例**：
  ```json
  {
    "production_date": "2024-01-01",
    "expiry_date": "2025-12-31",
    "shelf_life_months": 24,
    "shelf_life_days": null,
    "confidence": 0.95
  }
  ```

  **流程**：
  1. 本地OCR提取文字
  2. 检测文字中是否含日期关键词（MFG/EXP/有效期/保质期等）
  3. 若有，发送给LLM解析
  4. 自动填入表单对应字段
  5. 用户确认

  **成本**：约0.001-0.005元/次（文本LLM）

  ### 11.5 拍照识别商品信息（P0）

  **场景**：无条码商品或扫码未命中，通过拍照识别商品。

  **流程**：
  1. 用户拍摄商品包装照片
  2. 本地OCR提取文字（ML Kit）
  3. 评估OCR文字是否足以解析：
     - 足够 → 发送OCR文字给文本LLM
     - 不足 → 发送图片给视觉LLM
  4. LLM返回结构化商品信息
  5. 自动填充表单
  6. 用户确认/修正

  **LLM Prompt模板（文本模式）**：
  ```
  你是商品信息提取助手。请从以下包装OCR文字中提取信息。
  OCR文字：{ocr_text}
  请返回JSON格式：
  {
    "name": "商品名称",
    "brand": "品牌或null",
    "specification": "规格或null",
    "category_suggestion": "建议分类（药品/食品/日用品/化妆品）",
    "production_date": "YYYY-MM-DD或null",
    "expiry_date": "YYYY-MM-DD或null",
    "shelf_life": "保质期描述或null",
    "confidence": 0-1
  }
  只返回JSON。
  ```

  **LLM Prompt模板（视觉模式）**：
  ```
  [图片]
  你是商品信息提取助手。请识别图片中的商品，提取信息。
  请返回JSON格式：
  {
    "name": "商品名称",
    "brand": "品牌或null",
    "specification": "规格或null",
    "category_suggestion": "建议分类",
    "production_date": "YYYY-MM-DD或null",
    "expiry_date": "YYYY-MM-DD或null",
    "shelf_life": "保质期描述或null",
    "confidence": 0-1
  }
  只返回JSON。
  ```

  **成本**：文本模式约0.002-0.01元/次，视觉模式约0.01-0.05元/次

  ### 11.6 自然语言录入（P1）

  **场景**：用户用一句话描述要录入的物品，AI解析成结构化数据。

  **输入示例**：
  > "刚在京东买了三盒泰诺，生产日期2026年1月，保质期两年，放在客厅药箱"

  **LLM Prompt模板**：
  ```
  你是家庭物品管理助手。请从用户描述中提取物品信息。
  用户描述：{user_input}
  请返回JSON格式：
  {
    "name": "商品名称",
    "brand": "品牌或null",
    "quantity": 数字,
    "supplier": "购买渠道或null",
    "production_date": "YYYY-MM-DD或null",
    "expiry_date": "YYYY-MM-DD或null",
    "shelf_life_months": 数字或null,
    "storage_location": "存放位置或null",
    "category_suggestion": "建议分类或null",
    "notes": "其他备注或null"
  }
  只返回JSON。
  ```

  **支持语音输入**：语音转文字用系统自带能力（iOS Siri / Android SpeechRecognizer），转文字后走文本LLM。

  ### 11.7 说明书智能问答（P1）

  **场景**：用户拍了说明书，直接提问。

  **流程**：
  1. 说明书OCR文字已存入`products.manual_ocr_text`
  2. 用户输入问题
  3. 系统将说明书文字+问题发送给LLM
  4. LLM基于说明书内容回答
  5. 展示回答+免责声明

  **LLM Prompt模板**：
  ```
  你是药品/商品说明书助手。请根据以下说明书内容回答用户问题。
  说明书内容：{manual_text}
  用户问题：{question}
  请基于说明书内容准确回答。如果说明书中没有相关信息，请明确说"说明书中未提及"。
  回答要求简洁、准确。
  ```

  **注意事项**：
  - 药品问答必须加免责声明："以上信息仅供参考，具体用药请遵医嘱。"
  - 若说明书文字过长，截取相关段落或分块处理

  ### 11.8 AI采购建议（P2）

  **场景**：系统根据消耗速度，预测何时需要补货。

  **方案**：
  1. 分析`consumption_records`中近30/60/90天的消耗数据
  2. 计算每件物品的平均日消耗速度
  3. 结合当前库存，预测可用天数
  4. 若预测可用天数 ≤ 阈值（如7天），生成采购建议

  **示例输出**：
  > "酱油：当前1瓶，根据您的消耗速度，预计5天后用完，建议加入采买单。"

  **LLM可选**：基础版用规则+统计实现，LLM用于生成更自然的建议文案。

  ### 11.9 AI主题生成（P2）

  **场景**：用户描述想要的主题风格，AI生成主题配置。

  **流程**：
  1. 用户输入描述："太空主题，紫色深蓝，科幻感"
  2. LLM生成主题JSON：
  ```json
  {
    "theme_id": "ai_custom_space",
    "theme_name": "星际箱",
    "colors": {
      "primary": "#6C5CE7",
      "background": "#0A0A1A",
      "card": "#1A1A2E",
      "text_primary": "#E0E0E0",
      "text_secondary": "#8A8AA0",
      "success": "#00B894",
      "warning": "#FDCB6E",
      "danger": "#D63031"
    },
    "icon_style": "rounded-linear",
    "copy_style": {
      "add": "送入星际舱",
      "expiring": "即将进入黑洞",
      "expired": "已被黑洞吞噬",
      "low_stock": "星际物资告急",
      "shopping_list": "星际补给清单"
    }
  }
  ```
  3. （可选）文生图模型生成吉祥物/装饰图
  4. 预览效果
  5. 用户确认保存

  ### 11.10 Ollama预留接口

  **设计原则**：不绑定，可插拔。

  **预留内容**：
  - `ai_configs`表支持`provider='ollama'`
  - API地址可填NAS IP（如`http://192.168.1.100:11434`）
  - 无需API Key
  - 模型名称用户可填（如`llama3.2-vision`、`qwen2.5vl`）
  - 接口格式兼容OpenAI风格（Ollama原生支持）
  - 连接测试按钮
  - 超时设置（本地模型推理可能较慢）

  **DX4600性能参考**：
  - 16G内存，无独显
  - 可运行7B-8B量化模型（如qwen2.5:7b-instruct-q4）
  - 推理速度：约5-20秒/次（视模型和输入长度）
  - 视觉模型较吃力，文本模型可用

  **建议**：
  - DX4600上跑文本LLM做日期解析/自然语言录入（可行）
  - 视觉任务建议用云端API（本地太慢）
  - 说明书问答用文本LLM可以

  ### 11.11 AI降级策略

  | 场景         | 降级方案                                |
  | :----------- | :-------------------------------------- |
  | 用户未配置AI | 提示配置，或使用本地OCR文字手动填写     |
  | API调用失败  | 提示错误，退回手动填写                  |
  | API超时      | 提示重试，或退回手动填写                |
  | OCR置信度低  | 建议用户手动确认或重拍                  |
  | Ollama未运行 | 提示检查NAS服务，自动切换其他已配置服务 |

  ### 11.12 AI日志与优化

  - 所有AI解析记录存入`ai_parse_logs`
  - 记录`user_corrected`字段，用于发现AI常见错误
  - 后续可基于修正数据优化Prompt
  - 用户可在设置中清除AI日志
  - 隐私：日志默认本地存储，仅在用户授权下上传

  ### 11.13 AI成本预估（个人用户）

  | AI能力       | 调用频率（假设） | 单次成本（文本LLM） | 单次成本（视觉LLM） | 月成本           |
  | :----------- | :--------------- | :------------------ | :------------------ | :--------------- |
  | 日期解析     | 100次/月         | 0.002元             | -                   | 0.2元            |
  | 拍照识别     | 30次/月          | -                   | 0.03元              | 0.9元            |
  | 自然语言录入 | 50次/月          | 0.002元             | -                   | 0.1元            |
  | 说明书问答   | 20次/月          | 0.005元             | -                   | 0.1元            |
  | AI采购建议   | 10次/月          | 0.002元             | -                   | 0.02元           |
  | AI主题生成   | 1次/月           | 0.01元              | 0.05元（文生图）    | 0.06元           |
  | **合计**     |                  |                     |                     | **约1.5-3元/月** |

  **说明**：

  - 用户自配API Key，费用由用户自担
  - 使用DeepSeek等国产低价模型，成本可再降50-70%
  - NAS部署Ollama后，可完全零成本（效果取决于本地模型能力）

  ---

  *文档结束*
