#!/usr/bin/env bash
# Dependency-free regression test for the CI platform preparation script.
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

# Keep both GitHub workflows aligned with the Android 17 SDK package ID.
for workflow in "$script_dir/../../.github/workflows/flutter-ci.yml" \
                "$script_dir/../../.github/workflows/release.yml"; do
  grep -q 'platforms;android-37.0' "$workflow"
  if grep -q 'platforms;android-37"' "$workflow"; then
    printf 'FAIL: stale Android SDK package reference in %s\n' "$workflow" >&2
    exit 1
  fi
done

grep -q '^    runs-on: xcode-27$' "$script_dir/../../.github/workflows/flutter-ci.yml"
if grep -q '^    runs-on: macos-latest$' "$script_dir/../../.github/workflows/flutter-ci.yml"; then
  printf 'FAIL: iOS CI must use the Xcode 27 runner\n' >&2
  exit 1
fi

mkdir -p "$temporary_root/bin" "$temporary_root/project"
cat > "$temporary_root/bin/flutter" <<'FLUTTER'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p android/app/src/main/res/values ios/Runner ios/Flutter ios/Runner.xcodeproj
cat > android/app/src/main/AndroidManifest.xml <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="momo_box">
    </application>
</manifest>
XML
cat > android/app/build.gradle <<'GRADLE'
plugins { id 'com.android.application' }

android {
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_1_8
        targetCompatibility JavaVersion.VERSION_1_8
    }
}

dependencies {
}
GRADLE
cat > android/app/build.gradle.kts <<'KTS'
plugins { id("com.android.application") }

android {
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

dependencies {
}
KTS
cat > ios/Runner/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict></dict></plist>
PLIST
cat > ios/Runner/AppDelegate.swift <<'SWIFT'
import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
SWIFT
cat > ios/Podfile <<'POD'
platform :ios, '12.0'
POD
cat > ios/Runner.xcodeproj/project.pbxproj <<'PBX'
IPHONEOS_DEPLOYMENT_TARGET = 12.0;
PBX
cat > ios/Flutter/AppFrameworkInfo.plist <<'PLIST'
<key>MinimumOSVersion</key>
<string>12.0</string>
PLIST
FLUTTER
chmod +x "$temporary_root/bin/flutter"

cp "$script_dir/prepare-flutter-platforms.sh" "$temporary_root/project/prepare.sh"
(
  cd "$temporary_root/project"
  PATH="$temporary_root/bin:$PATH" bash ./prepare.sh
  PATH="$temporary_root/bin:$PATH" bash ./prepare.sh

  grep -q 'android.permission.POST_NOTIFICATIONS' android/app/src/main/AndroidManifest.xml
  grep -q 'android.permission.RECEIVE_BOOT_COMPLETED' android/app/src/main/AndroidManifest.xml
  grep -q 'android.permission.CAMERA' android/app/src/main/AndroidManifest.xml
  test "$(grep -c 'POST_NOTIFICATIONS' android/app/src/main/AndroidManifest.xml)" -eq 1
  test "$(grep -c 'android.permission.CAMERA' android/app/src/main/AndroidManifest.xml)" -eq 1
  test "$(grep -c 'ScheduledNotificationReceiver' android/app/src/main/AndroidManifest.xml)" -eq 1
  test "$(grep -c 'ScheduledNotificationBootReceiver' android/app/src/main/AndroidManifest.xml)" -eq 1
  grep -q 'compileSdk = 37' android/app/build.gradle
  grep -q 'minSdk = 36' android/app/build.gradle
  grep -q 'targetSdk = 37' android/app/build.gradle
  grep -q 'compileSdk = 37' android/app/build.gradle.kts
  grep -q 'minSdk = 36' android/app/build.gradle.kts
  grep -q 'targetSdk = 37' android/app/build.gradle.kts
  grep -q 'isCoreLibraryDesugaringEnabled = true' android/app/build.gradle.kts
  grep -q 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.3")' android/app/build.gradle.kts
  grep -q 'coreLibraryDesugaringEnabled true' android/app/build.gradle
  test "$(grep -c 'desugar_jdk_libs' android/app/build.gradle)" -eq 1
  grep -q 'tools:keep="@mipmap/ic_launcher"' android/app/src/main/res/values/keep.xml
  grep -q 'import UserNotifications' ios/Runner/AppDelegate.swift
  grep -q 'UNUserNotificationCenter.current().delegate = self' ios/Runner/AppDelegate.swift
  grep -q "platform :ios, '27.0'" ios/Podfile
  grep -q 'IPHONEOS_DEPLOYMENT_TARGET = 27.0;' ios/Runner.xcodeproj/project.pbxproj
  grep -q '<string>27.0</string>' ios/Flutter/AppFrameworkInfo.plist
  grep -q 'NSCameraUsageDescription' ios/Runner/Info.plist
  grep -q 'NSPhotoLibraryUsageDescription' ios/Runner/Info.plist
  test "$(grep -c 'NSCameraUsageDescription' ios/Runner/Info.plist)" -eq 1
  test "$(grep -c 'NSPhotoLibraryUsageDescription' ios/Runner/Info.plist)" -eq 1
)

printf 'PASS: platform preparation regression tests\n'
