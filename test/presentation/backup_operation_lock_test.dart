import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/backup_service.dart';
import 'package:momo_box/data/repositories/backup_repository.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Widget tests do not execute the native plugin registrant. Register the
  // existing method-channel implementation before saving/restoring platform.
  FilePickerIO.registerWith();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
  FilePicker? originalPicker;
  late _ControlledPicker picker;
  late _ControlledBackupService service;
  late Directory temporaryDirectory;
  Directory? directoryToClean;
  late Completer<String> shareGate;
  late int shareCalls;
  late Completer<void> shareEntered;

  setUp(() async {
    directoryToClean = null;
    originalPicker = null;
    originalPicker = FilePicker.platform;
    temporaryDirectory = await Directory.systemTemp.createTemp('momobox-backup-lock-');
    directoryToClean = temporaryDirectory;
    shareGate = Completer<String>();
    shareCalls = 0;
    shareEntered = Completer<void>();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getTemporaryDirectory') return temporaryDirectory.path;
      throw PlatformException(code: 'unexpected_path_call');
    });
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shareCalls++;
      if (!shareEntered.isCompleted) shareEntered.complete();
      return shareGate.future;
    });
  });

  tearDown(() async {
    final previousPicker = originalPicker;
    if (previousPicker != null) FilePicker.platform = previousPicker;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(shareChannel, null);
    final directory = directoryToClean;
    if (directory != null) await directory.delete(recursive: true);
  });

  Future<void> pumpTransitions(WidgetTester tester) async {
    // The busy indicator animates indefinitely; pump dialog transitions with
    // a bounded clock advance instead of pumpAndSettle while locked.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<_Entries> mount(WidgetTester tester) async {
    // Create controlled futures inside the Widget test's fake async zone.
    picker = _ControlledPicker();
    FilePicker.platform = picker;
    service = _ControlledBackupService();
    await tester.binding.setSurfaceSize(const Size(400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [backupServiceProvider.overrideWithValue(service)],
      child: const MaterialApp(home: BackupSettingsScreen()),
    ));
    await tester.pump();
    return _Entries(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '导入数据备份')).onTap! as Future<void> Function(),
      tester.widget<ListTile>(find.widgetWithText(ListTile, '导出核心数据备份 (JSON)')).onTap! as Future<void> Function(),
    );
  }

  void expectLocked(WidgetTester tester, bool locked) {
    final importTile = tester.widget<ListTile>(find.widgetWithText(ListTile, '导入数据备份'));
    final exportTile = tester.widget<ListTile>(find.widgetWithText(ListTile, '导出核心数据备份 (JSON)'));
    expect(importTile.onTap == null, locked);
    expect(exportTile.onTap == null, locked);
  }

  Future<void> rejectStaleEntries(_Entries entries) async {
    await entries.startImport();
    await entries.startExport();
  }

  testWidgets('picker 前同步加锁，旧回调重复/交叉进入不能释放 owner 锁，取消可重试', (tester) async {
    final entries = await mount(tester);
    final owner = entries.startImport();
    await rejectStaleEntries(entries);
    expect(picker.calls, 1);
    expect(service.exportCalls, 0);
    await tester.pump();
    expectLocked(tester, true);
    // A rejected invocation's finally must not unlock the pending picker.
    await rejectStaleEntries(entries);
    await tester.pump();
    expectLocked(tester, true);
    expect(picker.calls, 1);
    picker.result.complete(null);
    await pumpTransitions(tester);
    await owner;
    await tester.pump();
    expectLocked(tester, false);
    picker.result = Completer<FilePickerResult?>();
    final retry = entries.startImport();
    expect(picker.calls, 2);
    picker.result.complete(null);
    await pumpTransitions(tester);
    await retry;
    await tester.pump();
    expectLocked(tester, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('确认对话框取消之前一直持锁，不启动导入事务', (tester) async {
    final entries = await mount(tester);
    final owner = entries.startImport();
    picker.result.complete(_selection('{}'));
    await pumpTransitions(tester);
    expect(find.text('确认导入备份？'), findsOneWidget);
    expectLocked(tester, true);
    await rejectStaleEntries(entries);
    expect(picker.calls, 1);
    expect(service.importCalls, 0);
    expect(service.exportCalls, 0);
    await tester.tap(find.text('取消'));
    await pumpTransitions(tester);
    await owner;
    await pumpTransitions(tester);
    expectLocked(tester, false);
    expect(service.importCalls, 0);
  });

  testWidgets('确认、业务导入和结果展示均保持同一 owner，确认只写入一次', (tester) async {
    final entries = await mount(tester);
    final owner = entries.startImport();
    picker.result.complete(_selection('{"backup":"content"}'));
    await pumpTransitions(tester);
    await tester.tap(find.text('开始导入'));
    await pumpTransitions(tester);
    expect(service.importCalls, 1);
    expect(service.importedContent, '{"backup":"content"}');
    expectLocked(tester, true);
    await rejectStaleEntries(entries);
    service.importGate.complete(const ImportReport(imported: 2, skipped: 0));
    await pumpTransitions(tester);
    expect(find.text('数据导入完成'), findsOneWidget);
    expectLocked(tester, true);
    await rejectStaleEntries(entries);
    expect(picker.calls, 1);
    expect(service.importCalls, 1);
    expect(service.exportCalls, 0);
    await tester.tap(find.text('确定'));
    await pumpTransitions(tester);
    await owner;
    await pumpTransitions(tester);
    expectLocked(tester, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picker 失败释放锁，读取失败也释放锁且不进入事务', (tester) async {
    final entries = await mount(tester);
    final failedPick = entries.startImport();
    picker.result.completeError(PlatformException(code: 'picker_failed'));
    await pumpTransitions(tester);
    await failedPick;
    await pumpTransitions(tester);
    expectLocked(tester, false);
    picker.result = Completer<FilePickerResult?>();
    // File has no in-memory bytes, so the real filesystem read path is used.
    // Start UI continuations in the fake zone, yielding only filesystem IO to
    // the real event loop. Snackbar dismissal must not outlive the Widget.
    var readCompleted = false;
    final failedRead = entries.startImport().whenComplete(() => readCompleted = true);
    picker.result.complete(FilePickerResult([
      PlatformFile(name: 'missing.json', size: 0, path: '${temporaryDirectory.path}/missing.json'),
    ]));
    for (var attempt = 0; attempt < 100 && !readCompleted; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration.zero);
    }
    expect(readCompleted, isTrue, reason: 'Missing-file import did not release its owner');
    await failedRead;
    await pumpTransitions(tester);
    expectLocked(tester, false);
    expect(service.importCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('非法 UTF-8 释放锁，不出现确认或调用业务导入', (tester) async {
    final entries = await mount(tester);
    final owner = entries.startImport();
    picker.result.complete(FilePickerResult([
      PlatformFile(name: 'invalid.json', size: 1, bytes: Uint8List.fromList([0xff])),
    ]));
    await pumpTransitions(tester);
    await owner;
    await pumpTransitions(tester);
    expect(find.text('文件不是有效的 UTF-8 JSON 备份。'), findsOneWidget);
    expect(find.text('确认导入备份？'), findsNothing);
    expectLocked(tester, false);
    expect(service.importCalls, 0);
  });

  testWidgets('导入校验失败保留原失败报告流程，关闭报告后释放锁', (tester) async {
    final entries = await mount(tester);
    final owner = entries.startImport();
    picker.result.complete(_selection('{}'));
    await pumpTransitions(tester);
    await tester.tap(find.text('开始导入'));
    await pumpTransitions(tester);
    service.importGate.completeError(const BackupImportException([
      ImportFailure(section: 'products', index: 1, message: 'invalid quantity'),
    ]));
    await pumpTransitions(tester);
    expect(find.text('备份文件未导入'), findsOneWidget);
    expectLocked(tester, true);
    await rejectStaleEntries(entries);
    expect(service.importCalls, 1);
    expect(picker.calls, 1);
    await tester.tap(find.text('确定'));
    await pumpTransitions(tester);
    await owner;
    await pumpTransitions(tester);
    expectLocked(tester, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出入口同步锁定，拒绝旧回调，业务失败后可再进入', (tester) async {
    final entries = await mount(tester);
    final owner = entries.startExport();
    await rejectStaleEntries(entries);
    await tester.pump();
    expectLocked(tester, true);
    expect(service.exportCalls, 1);
    expect(picker.calls, 0);
    service.exportGate.completeError(StateError('export failed'));
    await pumpTransitions(tester);
    await owner;
    await pumpTransitions(tester);
    expectLocked(tester, false);
    picker.result = Completer<FilePickerResult?>();
    final retry = entries.startImport();
    expect(picker.calls, 1);
    picker.result.complete(null);
    await pumpTransitions(tester);
    await retry;
    await tester.pump();
    expectLocked(tester, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出锁覆盖写文件与系统分享完成，分享返回后才释放', (tester) async {
    final entries = await mount(tester);
    // Start the IO flow in the real async zone, waiting for the share boundary
    // rather than sleeping or assuming the write completed.
    late Future<void> owner;
    await tester.runAsync(() async {
      owner = entries.startExport();
      service.exportGate.complete('{"exported":true}');
      await shareEntered.future.timeout(const Duration(seconds: 5));
    });
    await tester.pump();
    expectLocked(tester, true);
    await rejectStaleEntries(entries);
    expect(service.exportCalls, 1);
    expect(picker.calls, 0);
    expect(shareCalls, 1);
    await tester.runAsync(() async {
      final files = await temporaryDirectory.list().toList();
      expect(files, hasLength(1));
      expect(await File(files.single.path).readAsString(), '{"exported":true}');
      shareGate.complete('');
      await owner;
    });
    await pumpTransitions(tester);
    expectLocked(tester, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picker 等待时退出页面，迟到结果不弹窗或写入', (tester) async {
    final entries = await mount(tester);
    final owner = entries.startImport();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    picker.result.complete(_selection('{}'));
    await pumpTransitions(tester);
    await owner;
    await pumpTransitions(tester);
    expect(service.importCalls, 0);
    expect(tester.takeException(), isNull);
  });
}

class _Entries {
  const _Entries(this.startImport, this.startExport);
  final Future<void> Function() startImport;
  final Future<void> Function() startExport;
}

FilePickerResult _selection(String content) {
  final bytes = Uint8List.fromList(utf8.encode(content));
  return FilePickerResult([PlatformFile(name: 'backup.json', size: bytes.length, bytes: bytes)]);
}

class _ControlledPicker extends FilePicker {
  int calls = 0;
  Completer<FilePickerResult?> result = Completer<FilePickerResult?>();

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) {
    calls++;
    return result.future;
  }
}

class _ControlledBackupService implements BackupService {
  int exportCalls = 0;
  int importCalls = 0;
  String? importedContent;
  final exportGate = Completer<String>();
  final importGate = Completer<ImportReport>();

  @override
  Future<String> exportJson() {
    exportCalls++;
    return exportGate.future;
  }

  @override
  Future<ImportReport> importJson(String content) {
    importCalls++;
    importedContent = content;
    return importGate.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
