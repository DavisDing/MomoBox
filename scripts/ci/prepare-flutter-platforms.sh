#!/usr/bin/env bash
set -euo pipefail

# The repository intentionally does not commit Flutter's generated platform
# directories. CI and release jobs call this script before dependency setup so
# the generated shell is always reproducible.
flutter create --platforms=android,ios --project-name momo_box .

python3 - <<'PY'
from pathlib import Path
import re

manifest = Path('android/app/src/main/AndroidManifest.xml')
if manifest.exists():
    text = manifest.read_text()
    permissions = (
        '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />\n'
        '    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />\n'
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

app_delegate = Path('ios/Runner/AppDelegate.swift')
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
