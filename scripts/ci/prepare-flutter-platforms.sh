#!/usr/bin/env bash
set -euo pipefail

# The repository intentionally does not commit Flutter's generated platform
# directories. CI and release jobs call this script before dependency setup so
# the generated shell is always reproducible.
flutter create --platforms=android,ios --project-name momo_box .

# `flutter create` restores its template widget test when this repository has
# no file at that path. That template references `MyApp`, which this app does
# not define, so keep CI focused on the repository's maintained test suite.
rm -f test/widget_test.dart

# Android 16 is the minimum supported OS (API 36). Compile and target
# Android 17 (API 37) so CI catches Android 17 behavior changes as well.
# iOS uses the deployment-target version directly.
export MOMO_ANDROID_MIN_SDK=36
export MOMO_ANDROID_COMPILE_SDK=37
export MOMO_ANDROID_TARGET_SDK=37
export MOMO_IOS_DEPLOYMENT_TARGET=27.0

python3 - <<'PY'
from pathlib import Path
import os
import re

ANDROID_MIN_SDK = os.environ['MOMO_ANDROID_MIN_SDK']
ANDROID_COMPILE_SDK = os.environ['MOMO_ANDROID_COMPILE_SDK']
ANDROID_TARGET_SDK = os.environ['MOMO_ANDROID_TARGET_SDK']
IOS_DEPLOYMENT_TARGET = os.environ['MOMO_IOS_DEPLOYMENT_TARGET']

manifest = Path('android/app/src/main/AndroidManifest.xml')
if manifest.exists():
    text = manifest.read_text()
    permissions = (
        '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />\n'
        '    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />\n'
        '    <uses-permission android:name="android.permission.CAMERA" />\n'
    )
    missing_permissions = ''.join(
        line for line in permissions.splitlines(keepends=True)
        if line.strip() not in text
    )
    if missing_permissions:
        text, replacements = re.subn(
            r'(?m)^([ \t]*<application\b)',
            missing_permissions + r'\1',
            text,
            count=1,
        )
        if replacements != 1:
            raise SystemExit('Unable to locate Android <application> in generated manifest.')

    receivers = '''
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON" />
            </intent-filter>
        </receiver>'''
    if 'ScheduledNotificationReceiver' not in text:
        text, replacements = re.subn(
            r'(?m)^[ \t]*</application>',
            receivers + '\n    </application>',
            text,
            count=1,
        )
        if replacements != 1:
            raise SystemExit('Unable to locate Android </application> in generated manifest.')
    manifest.write_text(text)

keep = Path('android/app/src/main/res/values/keep.xml')
keep.parent.mkdir(parents=True, exist_ok=True)
if not keep.exists():
    keep.write_text('''<resources xmlns:tools="http://schemas.android.com/tools">
    <keep tools:keep="@mipmap/ic_launcher" />
</resources>
''')

for gradle in (Path('android/app/build.gradle'), Path('android/app/build.gradle.kts')):
    if not gradle.exists():
        continue
    text = gradle.read_text()

    # Flutter templates have used both Groovy and Kotlin DSL spellings over
    # time. Pin all Android SDK levels so a generated shell cannot silently
    # fall back to the template's older defaults.
    replacements = (
        (r'(?m)^(\s*compileSdk(?:Version)?\s*(?:=\s*|\s+)).*$', r'\g<1>' + ANDROID_COMPILE_SDK),
        (r'(?m)^(\s*targetSdk(?:Version)?\s*(?:=\s*|\s+)).*$', r'\g<1>' + ANDROID_TARGET_SDK),
        (r'(?m)^(\s*minSdk(?:Version)?\s*(?:=\s*|\s+)).*$', r'\g<1>' + ANDROID_MIN_SDK),
    )
    for pattern, replacement in replacements:
        text = re.sub(pattern, replacement, text)
    # Keep desugaring because flutter_local_notifications uses Java 8 APIs
    # for scheduled notifications; this is a plugin build requirement, not an
    # Android 8 compatibility branch.
    if 'coreLibraryDesugaringEnabled' not in text and 'isCoreLibraryDesugaringEnabled' not in text:
        if gradle.suffix == '.kts':
            text = text.replace('compileOptions {', 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', 1)
            dependency = '    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.3")\n'
        else:
            text = text.replace('compileOptions {', 'compileOptions {\n        coreLibraryDesugaringEnabled true', 1)
            dependency = '    coreLibraryDesugaring "com.android.tools:desugar_jdk_libs:2.0.3"\n'
        text = text.replace('dependencies {', 'dependencies {\n' + dependency, 1)
    elif gradle.suffix != '.kts' and 'desugar_jdk_libs' not in text:
        dependency = '    coreLibraryDesugaring "com.android.tools:desugar_jdk_libs:2.0.3"\n'
        if 'dependencies {' in text:
            text = text.replace('dependencies {', 'dependencies {\n' + dependency, 1)
        else:
            text += '\n\ndependencies {\n' + dependency + '}\n'
    gradle.write_text(text)

# Keep iOS project, CocoaPods, and Flutter framework metadata aligned with the
# same minimum supported OS. These files are generated and therefore patched
# on every CI/release run rather than committed to the repository.
podfile = Path('ios/Podfile')
if podfile.exists():
    text = podfile.read_text()
    if re.search(r'(?m)^\s*platform :ios,', text):
        text = re.sub(
            r"(?m)^(\s*platform :ios,\s*)['\"][^'\"]+['\"](.*)$",
            r"\g<1>'" + IOS_DEPLOYMENT_TARGET + r"'\g<2>",
            text,
            count=1,
        )
    else:
        text = "platform :ios, '" + IOS_DEPLOYMENT_TARGET + "'\n" + text
    podfile.write_text(text)

for pbxproj in Path('ios').glob('**/*.pbxproj'):
    text = pbxproj.read_text()
    text = re.sub(
        r'(IPHONEOS_DEPLOYMENT_TARGET\s*=\s*)[^;]+;',
        r'\g<1>' + IOS_DEPLOYMENT_TARGET + ';',
        text,
    )
    pbxproj.write_text(text)

framework_plist = Path('ios/Flutter/AppFrameworkInfo.plist')
if framework_plist.exists():
    text = framework_plist.read_text()
    text = re.sub(
        r'(<key>MinimumOSVersion</key>\s*<string>)[^<]+(</string>)',
        r'\g<1>' + IOS_DEPLOYMENT_TARGET + r'\g<2>',
        text,
    )
    framework_plist.write_text(text)

app_delegate = Path('ios/Runner/AppDelegate.swift')
info_plist = Path('ios/Runner/Info.plist')
if info_plist.exists():
    text = info_plist.read_text()
    camera_key = '<key>NSCameraUsageDescription</key>\n\t<string>用于扫描商品条码和拍摄商品/说明书图片。</string>'
    photo_key = '<key>NSPhotoLibraryUsageDescription</key>\n\t<string>用于选择商品和说明书图片。</string>'
    missing_usage_descriptions = ''.join(
        f'\t{key}\n' for key, marker in (
            (camera_key, 'NSCameraUsageDescription'),
            (photo_key, 'NSPhotoLibraryUsageDescription'),
        ) if marker not in text
    )
    if missing_usage_descriptions:
        text = text.replace('</dict>', f'{missing_usage_descriptions}</dict>', 1)
    info_plist.write_text(text)

if app_delegate.exists():
    text = app_delegate.read_text()
    if 'import UserNotifications' not in text:
        text = text.replace('import UIKit\n', 'import UIKit\nimport UserNotifications\n', 1)
    if 'UNUserNotificationCenter.current().delegate' not in text:
        text = text.replace(
            'GeneratedPluginRegistrant.register(with: self)\n',
            'GeneratedPluginRegistrant.register(with: self)\n    UNUserNotificationCenter.current().delegate = self\n',
            1,
        )
    app_delegate.write_text(text)
PY
