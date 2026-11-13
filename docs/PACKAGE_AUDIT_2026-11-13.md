# 2026-11-13：已发布 Android 包内容审查

本次只审查，不修改产品代码、依赖或发布流程，不删除文件、不重新构建、不安装或执行 APK。

核对对象为 GitHub Release **v0.12.98**，发布于2026-11-13 14:50:45（Asia/Shanghai），对应提交 `e02d85375bbbf7100cb4343d61f3e26fcc3e9d99`。与审查时本地 HEAD 一致；GitHub Actions run #98（43378674075）为成功。本地起始工作区干净。

实际下载 `MomoBox-v0.12.98.apk`，92,196,408字节，**87.93 MiB**。SHA256为 `aea5f919604b6a26264bd517f558c9b73edcae98689eefee94ddbdfad8aa395b`，与 Release 资产摘要一致，326个ZIP条目全部CRC校验通过。Manifest确认 versionName=0.12.98 / versionCode=98，无 debuggable=true。原始文件、清单及解析证据保存在 `/private/tmp/momobox-package-audit-20261113/`；临时目录不保证长期保存。

## 发现与处理建议

| 项目 | 已核实证据 | 判断 |
| --- | --- | --- |
| 通用APK中的多架构库 | ARM64 28.25 MiB；ARM32 24.58 MiB；x86_64 30.71 MiB。三套共83.54 MiB，占APK字节数95.01%。每套均含Flutter、业务AOT、扫码、SQLite及JNI库 | 最大精简机会。对于ARM64设备，另外两套共55.29 MiB无需使用；它们用于其他架构兼容，不是业务废功能。可按ABI分别发布，保留兼容选择。 |
| 旧手机AI授权分支 | `assistant_screen.dart:119`仍按NAS地址是否为空选择backend_v1/v2授权键；当前业务页已受强制NAS接入控制，AI执行器只请求NAS | 可后续收敛为NAS授权路径，保留已有授权兼容。属于少量历史逻辑，不能据此估算明显瘦身，也没有恢复手机直连AI能力。 |
| 旧单机集成测试 | `integration_test/app_test.dart:20`仍以单机首次启动、旧四入口及NavigationBar/Rail为预期；当前已改强制NAS接入与五入口 | 测试需要按现需求更新，但不属于APK内容。不能为减包直接删除集成测试。 |
| Cupertino图标字体 | pubspec仍声明cupertino_icons，业务Dart没有直接引用CupertinoIcons；实际字体848字节、ZIP内533字节，仅保留U+F3CF返回箭头字形 | 初筛曾列为无直接引用候选，字形核对后不能认定为安全可删。Flutter/路由的iOS路径仍包含相关代码；收益不足1KiB，优先保留，若清理需先验证平台返回入口。 |
| 发布模板标记 | 实际Manifest仍为label=momo_box、package=com.example.momo_box | 属于发布标记残留，几乎不影响体积。可另行统一显示名称；包名是安装/升级身份，不能为了清理直接更换。图标未确认是模板图，不作结论。 |

仅从现有APK减去非ARM64库估算，ARM64库加共享文件约 **32.64 MiB**。这是包内字节差值，不是新包构建结果；新构建的对齐、签名及资源处理可能有差异。

当前 `.github/workflows/pipeline.yml:359` 使用不分ABI的release APK构建。若改为多个APK，必须一起调整 `lib/application/update_service.dart:72`：当前更新器只取Release中第一个`.apk`，尚无ABI选择。不能仅增添多个APK后继续按首个文件下载；SHA256选择与首次兼容升级也需保持匹配。后续实施可使用Flutter已有的`--split-per-abi`或单独`--target-platform`能力，本次未改流程或产物。

## 已检查、仍应保留的内容

- **扫码模型与原生库**：`assets/mlkit_barcode_models/`共0.84 MiB，三架构`libbarhopper_v3.so`共13.45 MiB。对应实际使用的mobile_scanner实时扫码/图片识码，不是已停用的文字OCR或大语言模型。插件7.4.1默认使用内置条码识别；改为动态下载版会改变首次可用和Google Play服务依赖，不能作为无行为变化的删除项。
- **SQLite与Drift**：NativeAssetsManifest逐架构指向libsqlite3.so，每架构只有一份对应库；用于既定离线只读缓存、本地设置和同步元数据。NAS必选不意味着手机不需要缓存数据库。
- **图片选择、文件导入、分享、通知、时区、网络与安全存储**：均有现有功能调用。sqlite3_flutter_libs虽不靠业务Dart直接import启用，也提供实际SQLite原生库，不能按“无import”删除。
- **NOTICES、运行时资源和着色器**：Flutter许可证、渲染与平台资源。包内虽有774字节的DebugProbesKt.bin，此为依赖资源，不能据文件名判为调试APK。发布Manifest没有debuggable=true，包内是AOT libapp.so，没有kernel_blob.bin或VM/isolate调试快照。
- **旧归属/同步状态兼容**：keep_local_only解析仍用于识别旧安装数据，NasSetupController会自动重新确认join_and_merge。它不是可供用户选择的单机入口。旧AI密钥清理用于升级及敏感配置移除，保留业务数据，不应因名称含legacy就删除。

## 未发现被误装入的内容

实际ZIP清单未发现仓库设计稿/原型、测试图片、测试源码、README/docs、NAS Compose、Go后端、`.env`、密钥文件或备份数据。Flutter资源仅有manifest、通知/许可证、两份已裁剪图标字体、两份着色器；另有条码识别模型和性能基线资源。

当前锁文件及包内清单未发现已停用的google_mlkit_text_recognition/google_mlkit_commons文字OCR插件、flutter_image_compress或文字识别模型。DEX字符串核对未发现integration_test、flutter_driver或原文字识别插件包名；存在TYPE_TEXT_RECOGNITION通用枚举字符串，不构成文字OCR功能/模型仍在的证据。Flutter引擎Java层仍有VMService相关方法名，也不能仅凭方法名推断调试服务已开启。

lib/main.dart出发的import/export/part静态图覆盖当前129个Dart文件，没有发现整个Dart文件完全脱离入口；这不等于每个方法或运行分支都有效。所有直接功能依赖均需结合框架/native插件使用判断，不能按仓库中是否有一条import作删除清单。

## 验证范围

- PASS：实际发布元数据与提交核对、APK完整SHA256、全部ZIP CRC、文件/资源/架构体积分布、二进制Manifest解析、DEX相关字符串核对、Dart入口依赖图和具体调用核对。
- 下载过程中有两段范围传输被网络截断；仅补齐缺失字节，最终全包SHA256与全部CRC均通过。没有将未完整的下载作为审查结论。
- NOT_EXECUTED：原生重构建、拆分APK实测、安装运行、Android设备/架构及iOS返回操作验收；AAB内容、iOS包和实际NAS Docker镜像未解包审查。本次没有产品行为变化，因此未重复运行前序Flutter/Go业务回归；历史1010项测试不作为本次新运行结果。

本次审查只新增本报告，清理与发布方案尚未实施。
