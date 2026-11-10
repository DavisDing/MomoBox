# V2 Flutter 页面渲染证据

2026-11-10，基于 `2f7ceb98e5ce1cbc6fb20d8061722f8a3274a41b` 之后的本地 UI 修正。尚未提交、推送或发布；这些图片不属于已安装的 `0.12.89`。

`light-*-fixture.png` / `dark-*-fixture.png` 是 `v2_visual_capture_test.dart` 挂载真实 `MomoBoxApp`、逐一切换生产路由后，由 Flutter `RenderRepaintBoundary.toImage` 导出的图片。逻辑视口390×844，导出倍率2；总览仅将助手、今日、家居三张原图排在一起，未重绘页面。深浅两套共10张页面、2张总览。

- 库存：临时内存 SQLite 中的4个测试商品，非用户库存；没有商品实图，所以显示生产代码的缺图占位。
- 家居：测试文件专用 NAS Repository 返回4个支持类型的实体，由真实 `SmartHomeController` 解析。发送命令会抛错，不触碰真实设备。
- 环境：独立的测试读数23.6°C / 48%、室外18°C / 体感17°C，非现场传感器或真实公共天气请求。
- 助手：未配置模型，不发送真实请求。生产端仍使用既有授权、会话和逐次写入确认。
- 字体：CI同款 Noto Sans CJK SC Regular；字体仅用于截图，不打入应用、不增加项目依赖。实际手机的系统字体/系统栏/键盘和渲染细节仍需安装验收。

复现：在项目已完成 `flutter pub get` 与 Drift 生成后，设置指向本地中文字体的 `MOMO_UI_FONT`：

```sh
MOMO_UI_FONT=/path/to/NotoSansCJKsc-Regular.otf \
MOMO_UI_CAPTURE_DIR=build/ui-v2 \
flutter test --no-pub --reporter expanded test/presentation/v2_visual_capture_test.dart
```

`source-sha256.json` 记录这些截图对应的源码哈希和临时字体哈希，`verification.txt` 摘录本地实际检查结果。完整流水线已增加相同渲染命令和 `momobox-ui-<commit>` artifact；本次尚未在远端执行。

这是一组可复核的 Flutter 渲染与业务回归证据，不是 APK、Android/iOS 真机、真实 AI/NAS/HA 或逐像素视觉自动验收。批准原型中的演示场景按钮没有伪装为已接入功能；真实商品照片和设备类型也不会被演示素材替换。
