import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';

void main() {
  test('about version uses the release build defines', () {
    const version = String.fromEnvironment(
      'MOMO_APP_VERSION',
      defaultValue: '0.1.0',
    );
    const build = String.fromEnvironment(
      'MOMO_BUILD_NUMBER',
      defaultValue: '1',
    );
    expect(MomoAppInfo.versionDisplay, '$version（构建 $build）');
  });
}
