# Android 固定发布签名

本批次提供配置与失败关闭门禁，不生成密钥、不替仓库配置Secrets、不证明已安装设备可以升级。无UI/应用ID/主题变更，debug验证和iOS unsigned链路不受签名密钥缺失影响。

## 管理员需配置

在仓库Actions Secrets中配置以下5项（不要发到聊天、日志或提交到Git）：

| Secret | 内容 |
| --- | --- |
| `ANDROID_SIGNING_KEYSTORE_BASE64` | 固定JKS/PKCS12文件的单行标准base64，无前缀或换行；最大解码4MiB |
| `ANDROID_SIGNING_STORE_PASSWORD` | keystore密码 |
| `ANDROID_SIGNING_KEY_PASSWORD` | 指定私钥密码，PKCS12通常与store密码一致 |
| `ANDROID_SIGNING_KEY_ALIAS` | 固定私钥alias |
| `ANDROID_SIGNING_CERT_SHA256` | 对该alias导出DER证书计算的SHA-256，64位hex，可带冒号 |

证书必须独立核对，不能仅从待上传文件盲目复制一个值作为可信依据。该key用于当前直接APK分发及AAB上传；未来Play App Signing的上传证书与商店实际分发证书需另行管理，不能混用升级验收口径。

**NEEDS_CONFIRMATION**：先核对既有安装APK的签名证书、applicationId与拟配置key是否一致。之前Flutter默认debug key不代表已有可复用的正式key。若不一致，先做业务备份和有保护的换签名迁移设计，不以卸载清数据解决；不自动生成新key掩盖这个决定。离线备份key、alias和密码及恢复演练是管理员责任。

## 当前链路与保护

1. 生成Android平台后执行 `scripts/ci/android-release-signing.py prepare`。检查5项完整、base64及指纹格式，用keytool导出证书并核对pin，然后仅替换已识别的release签名块。模板改变则失败，不猜测、不回退debug。
2. keystore仅临时存在于忽略的Android目录 `.momo-release-signing`，目录0700、文件0600；密码通过环境变量传给Gradle/工具，不写入key.properties或命令参数、不输出底层错误或秘密。
3. APK用apksigner验证签名及单一证书；AAB用jarsigner strict验证（信任已核对的key/alias，非零结果全部拒绝）并再次核对单一证书SHA-256。两者成功后才复制发布包、计算校验和和上传制品。
4. job收尾的always步骤清理密钥并还原Gradle签名补丁，prepare失败也清理；硬终止runner不保证执行收尾，依赖临时runner销毁，勿在持久自托管runner直接启用而没有独立清理措施。

未配置key的正式发布会明确FAIL，不是签名已验收，也不能用旧run #31成功替代新配置验证。原自动发布分支、Release可见性及资源授权政策未改变；私用主题资源的公开分发决定仍需另行确认。

## Actions缺失配置排查（2026-10-11实测）

run #33（`38120748993`，SHA `dfffb506358f4df391432d181f984583714a7beb`）正式包job在prepare步骤报告上述5项全部缺失；日志中对应环境变量均为空。App分析/测试/Android debug、iOS unsigned及backend/PG/vet已经通过。这只能证明本次job未取得配置，不能通过日志推断其他environment或组织中不存在密钥。

管理员处理顺序：

1. 先确认可复用的固定私钥及独立核对的证书指纹；旧APK只有公钥证书，无法从APK恢复私钥。无原密钥时先决定换签名/升级方案，不自动生成新key，不建议卸载清数据。
2. 在仓库 `Settings → Secrets and variables → Actions` 配置表中的5个**Repository secrets**，名称须完全一致；不要误配成普通Variables。当前`build-release-packages`未声明environment，单独放在某个Environment中的secret不会被该job读取；组织secret则需授予该仓库访问。仅配置非秘密alias/指纹也不能解除其他缺项。
3. 在GitHub管理界面或可信本机工具完成配置，不把base64、密码或私钥发到聊天、提交进Git或打印到日志。保留独立离线备份；不要复用一次性runner的debug keystore。
4. 配置完成后重跑run #33失败的jobs，检查prepare实际完成、APK/AAB构建和verify成功、临时材料清理，以及同SHA的上传/发布结果。原运行会仍保留失败记录；重跑成功才是配置修复证据。尚未配置时反复重跑无助于解决缺项。

本次未更改签名保护或workflow，也未写入Secrets、提交、触发重跑或发布；当前连接器不提供Secrets管理能力。缺失配置由管理员补齐之前，正式发布仍阻塞。

## 验证入口

- 无JDK/Docker依赖的配置与控制流回归：`python3 scripts/ci/test-android-release-signing.py`，不等于真实签名或Android构建。
- 有JDK/Android SDK及批准的固定key：实际prepare→APK/AAB构建→verify→cleanup，检查失败路径及产物没有密钥。按同一SHA记录结果。
- 设备：同证书从上一版本升级，确认库存/媒体/设置保留，版本正确；不同证书应在安装前明确识别，先解决迁移方案。新安装、签名iOS、商店与NAS验收分别记录，不合并成“全平台通过”。
