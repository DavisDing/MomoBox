import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory cache;
  const channel = MethodChannel('com.example.momo_box/update');

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('momobox-update-test-');
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await cache.delete(recursive: true);
  });

  AppRelease release({String? checksum}) => AppRelease(
    tagName: 'v1.2.3',
    name: 'Test release',
    htmlUrl: 'https://example.com/releases/1.2.3',
    publishedAt: null,
    body: '',
    apkUrl: 'https://example.com/app.apk',
    apkSha256: checksum,
  );

  UpdateService service(http.Client client) {
    final service = UpdateService(
      client: client,
      downloadDirectory: () async => cache,
    );
    addTearDown(service.close);
    return service;
  }

  test('下载校验后保存到可共享缓存目录，安装桥接收到完整 APK', () async {
    final bytes = utf8.encode('test-apk-bytes');
    final updater = service(MockClient((_) async => http.Response.bytes(bytes, 200)));
    final progress = <int>[];
    final file = await updater.downloadApk(
      release(checksum: sha256.convert(bytes).toString()),
      onProgress: (received, total) => progress.add(received),
    );
    expect(file.parent.path, '${cache.path}/updates');
    expect(await file.readAsBytes(), bytes);
    expect(await File('${file.path}.part').exists(), isFalse);
    expect(progress.last, bytes.length);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'installApk');
          expect(call.arguments, {'path': file.path});
          return 'installer_opened';
        });
    expect(await updater.installApk(file), ApkInstallResult.installerOpened);
  });

  test('校验失败删除残留包，不留下可安装的最终文件', () async {
    final updater = service(MockClient((_) async => http.Response('wrong-bytes', 200)));
    await expectLater(
      updater.downloadApk(release(checksum: sha256.convert([1, 2, 3]).toString())),
      throwsA(isA<FormatException>()),
    );
    expect(await Directory('${cache.path}/updates').list().toList(), isEmpty);
  });

  test('响应长度不符及空包不进入安装阶段', () async {
    for (final bytes in [<int>[1, 2, 3], <int>[]]) {
      final updater = service(MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.value(bytes),
          200,
          contentLength: bytes.isEmpty ? 0 : 100,
        );
      }));
      await expectLater(updater.downloadApk(release()), throwsA(isA<FormatException>()));
      expect(await Directory('${cache.path}/updates').list().toList(), isEmpty);
    }
  });

  test('中断传输清理部分文件，重试能够重新下载', () async {
    var requests = 0;
    final updater = service(MockClient.streaming((request, _) async {
      requests++;
      return http.StreamedResponse(
        requests == 1 ? _interruptedStream() : Stream.value([1, 2, 3]),
        200,
        contentLength: 3,
      );
    }));
    await expectLater(updater.downloadApk(release()), throwsA(isA<SocketException>()));
    expect(await Directory('${cache.path}/updates').list().toList(), isEmpty);
    final file = await updater.downloadApk(release());
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(requests, 2);
  });

  test('安装权限提示不算失败，授权后可直接重试同一文件', () async {
    var downloads = 0;
    var installs = 0;
    final updater = service(MockClient((_) async {
      downloads++;
      return http.Response.bytes([1, 2, 3], 200);
    }));
    final file = await updater.downloadApk(release());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.arguments, {'path': file.path});
          return ++installs == 1 ? 'permission_required' : 'installer_opened';
        });
    expect(await updater.installApk(file), ApkInstallResult.permissionRequired);
    expect(await file.exists(), isTrue);
    expect(await updater.installApk(file), ApkInstallResult.installerOpened);
    expect(downloads, 1);
  });

  test('安装器异常保留已下载文件，错误交给页面独立反馈', () async {
    final updater = service(MockClient((_) async => http.Response.bytes([1, 2, 3], 200)));
    final file = await updater.downloadApk(release());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'INSTALL_FAILED', message: 'No installer');
        });
    await expectLater(updater.installApk(file), throwsA(isA<PlatformException>()));
    expect(await file.readAsBytes(), [1, 2, 3]);
  });
}

Stream<List<int>> _interruptedStream() async* {
  yield [1];
  throw const SocketException('connection interrupted');
}
