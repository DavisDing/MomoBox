# 移动端间距调整

用户反馈实际今日页纵向排版过松。本轮只调整共享家庭栏、页标题和今日页留白，保留配色、字号、系统/应用文字缩放、导航与业务入口。四个已有未提交的部署/README 修改未纳入本轮。

## 实际页面对比

`today-comparison.png` 左为调整前、右为紧凑版，由同一 Flutter 测试导出的原图等比拼合；没有重绘界面。独立的 `light/dark-today-before/after.png` 与坐标 JSON 保留原始结果。视口390×844dp，原图导出倍率2，使用与用户截图相同的 momo 红色主题。

| 区域 | 调整前 | 紧凑版 |
| --- | ---: | ---: |
| 家庭栏高度（含留白） | 68dp | 56dp |
| 页标题区高度（含留白） | 118dp | 96dp |
| 提醒卡高度 | 209dp | 177dp |
| 入库快捷按钮高度（含边框） | 61dp | 49dp |
| “最近需要关注”标题顶部 | 534.5dp | 442.5dp |

关注区上移92dp；提醒卡缩短约15%。模块间距24→16dp，提醒卡到快捷入口18→12dp。主要快捷按钮以48dp最小高度包住内容，文字增大后自然长高；标题使用现有统一行高，不缩小字体。

## 验证

- Flutter analyze --no-pub：通过，无问题。
- 六个相关测试文件：166项通过。包括320/390/430dp竖屏、844dp横屏，1/1.3/3.4倍文字，深浅色页面、设置返回、库存/首页业务、HA快捷操作、环境摘要与Dock回归。
- v2_visual_capture_test.dart：2项通过，深浅色各渲染五个生产路由，逐张检查今日及受共享布局影响的物品、家居和设置页。
- git diff --check：通过。

坐标由实际控件RenderBox读取。截图使用内存库存、隔离的测试NAS实体和环境读数；不向实际设备、天气服务或模型发请求。中文字体只用于测试，不随产品打包。此目录证明Flutter页面渲染，不代表Android/iOS安装、系统字体或现场设备验收；未构建、推送或发布安装包。

在已有Flutter依赖与中文字体的环境复现：

```sh
MOMO_UI_THEME=momo \
MOMO_UI_FONT=/path/to/NotoSansCJKsc-Regular.otf \
MOMO_UI_CAPTURE_DIR=build/ui-density-after \
flutter test --no-pub --reporter expanded test/presentation/v2_visual_capture_test.dart

flutter analyze --no-pub
flutter test --no-pub --reporter expanded \
  test/presentation/mobile_redesign_test.dart \
  test/presentation/widget_flows_test.dart \
  test/presentation/home_ha_quick_actions_test.dart \
  test/presentation/settings_hierarchy_test.dart \
  test/presentation/momo_floating_dock_test.dart \
  test/presentation/home_environment_card_test.dart
```

本机使用上一轮的临时Flutter/Dart工具链及包缓存；`XDG_CONFIG_HOME` 指向临时目录，未修改系统Flutter配置。`source-sha256.json` 记录对应源码与字体哈希。之前的 `2026-11-10-ui-v2/` 证据保持原样，不作为本轮代码的结果。
