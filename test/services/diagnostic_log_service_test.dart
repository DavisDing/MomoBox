import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/services/diagnostic_log_service.dart';

class _SensitiveError implements Exception {
  @override
  String toString() => throw StateError('error text must never be read');
}

void main() {
  late Directory directory;
  late DiagnosticLogService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('momo-diagnostics-test-');
    service = DiagnosticLogService(
      directoryProvider: () async => directory,
      now: () => DateTime.utc(2026, 10, 23, 8),
    );
  });
  tearDown(() async {
    await service.flush();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('仅导出事件、异常类型与静态项目帧，不读取异常消息', () async {
    const secret = 'private-token-9876';
    await service.record(
      DiagnosticEvent.frameworkError,
      StateError('库存和 AI 文本 $secret https://host.invalid/key'),
      stackTrace: StackTrace.fromString('''
#0 someFunction (package:momo_box/application/inventory_service.dart:23:5)
#1 remote ($secret https://host.invalid/token /Users/private/file.txt:10:3)
#2 external (package:other_package/private.dart:4:3)
#3 app (package:momo_box/main.dart:12:7)
'''),
    );
    await service.record(
      DiagnosticEvent.unhandledAsyncError,
      _SensitiveError(),
    );
    final output = await service.exportJson();
    final decoded = jsonDecode(output) as Map<String, dynamic>;
    final events = decoded['events'] as List;
    expect(events, hasLength(2));
    expect((events.first as Map)['error_type'], 'StateError');
    expect((events.first as Map)['frames'], [
      {'source': 'inventory-service', 'line': 23, 'column': 5},
      {'source': 'main', 'line': 12, 'column': 7},
    ]);
    expect((events.last as Map)['error_type'], 'OtherError');
    for (final value in [
      secret,
      '库存',
      'AI 文本',
      'https://',
      '/Users/',
      'package:',
      'someFunction',
    ]) {
      expect(output, isNot(contains(value)));
    }
  });

  test('串行并发追加保持完整 JSON 行，轮转后文件数量与字节有界', () async {
    var sequence = 0;
    service = DiagnosticLogService(
      directoryProvider: () async => directory,
      maxFileBytes: 1024,
      retainedFiles: 3,
      now: () => DateTime.utc(2026, 10, 23).add(Duration(seconds: sequence++)),
    );
    await Future.wait(
      List.generate(
        60,
        (_) => service.record(
          DiagnosticEvent.frameworkError,
          StateError('excluded-message'),
        ),
      ),
    );
    final files = (await directory.list().toList()).whereType<File>().toList();
    expect(files, hasLength(3));
    var rows = 0;
    for (final file in files) {
      expect(await file.length(), lessThanOrEqualTo(1024));
      for (final line in await file.readAsLines()) {
        expect(jsonDecode(line), isA<Map>());
        rows++;
      }
    }
    final events =
        (jsonDecode(await service.exportJson()) as Map)['events'] as List;
    expect(events, hasLength(rows));
    expect(events.length, lessThan(60));
    expect(
      (events.last as Map)['time'],
      DateTime.utc(2026, 10, 23, 0, 0, 59).toIso8601String(),
    );
  });

  test('导出重新筛选已损坏或掺入敏感字段的日志', () async {
    await File('${directory.path}/events-0.jsonl').writeAsString(
      [
        'not-json-sensitive-text',
        jsonEncode({
          'time': '2026-10-23T00:00:00Z',
          'event': 'frameworkError',
          'error_type': 'StateError',
          'frames': [
            {'source': 'main', 'line': 3, 'column': 2, 'path': '/secret/file'},
            {'source': '/secret/file', 'line': 2, 'column': 4},
          ],
          'message': 'secret-token',
        }),
        jsonEncode({
          'time': '2026-10-23T00:00:00Z',
          'event': 'secret-event',
          'error_type': 'StateError',
          'frames': [],
        }),
      ].join('\n'),
    );
    final output = await service.exportJson();
    expect(output, isNot(contains('secret')));
    final events = (jsonDecode(output) as Map)['events'] as List;
    expect(events, hasLength(1));
    expect((events.single as Map)['frames'], [
      {'source': 'main', 'line': 3, 'column': 2},
    ]);
  });

  test('未完成的旧日志行不吞掉后续成功记录', () async {
    await File(
      '${directory.path}/events-0.jsonl',
    ).writeAsString('{partial-sensitive-text');
    await service.record(
      DiagnosticEvent.frameworkError,
      StateError('excluded'),
    );
    final output = await service.exportJson();
    expect(output, isNot(contains('sensitive')));
    expect((jsonDecode(output) as Map)['events'], hasLength(1));
  });

  test('写盘失败不会抛错或毒化后续记录队列', () async {
    var available = false;
    service = DiagnosticLogService(
      directoryProvider: () async {
        if (!available) throw FileSystemException('private-path');
        return directory;
      },
    );
    await service.record(DiagnosticEvent.frameworkError, StateError('first'));
    available = true;
    await service.record(DiagnosticEvent.frameworkError, StateError('second'));
    final events =
        (jsonDecode(await service.exportJson()) as Map)['events'] as List;
    expect(events, hasLength(1));
  });

  test('Flutter 和异步错误调用原 handler，保留 dispatcher 传播结果', () async {
    final originalFramework = FlutterError.onError;
    final originalDispatcher = PlatformDispatcher.instance.onError;
    var frameworkCalls = 0;
    var dispatcherCalls = 0;
    try {
      FlutterError.onError = (_) => frameworkCalls++;
      PlatformDispatcher.instance.onError = (_, __) {
        dispatcherCalls++;
        return false;
      };
      service.installErrorHandlers();
      service.installErrorHandlers();
      FlutterError.onError!(
        FlutterErrorDetails(exception: StateError('secret')),
      );
      final handled = PlatformDispatcher.instance.onError!(
        StateError('secret'),
        StackTrace.empty,
      );
      expect(frameworkCalls, 1);
      expect(dispatcherCalls, 1);
      expect(handled, isFalse);
      await service.flush();
      final events =
          (jsonDecode(await service.exportJson()) as Map)['events'] as List;
      expect(events, hasLength(2));
    } finally {
      FlutterError.onError = originalFramework;
      PlatformDispatcher.instance.onError = originalDispatcher;
    }
  });

  test('没有 dispatcher handler 时仍返回 false，不吞原异常', () async {
    final originalFramework = FlutterError.onError;
    final originalDispatcher = PlatformDispatcher.instance.onError;
    try {
      PlatformDispatcher.instance.onError = null;
      service.installErrorHandlers();
      expect(
        PlatformDispatcher.instance.onError!(
          StateError('private'),
          StackTrace.empty,
        ),
        isFalse,
      );
      await service.flush();
    } finally {
      FlutterError.onError = originalFramework;
      PlatformDispatcher.instance.onError = originalDispatcher;
    }
  });
}
