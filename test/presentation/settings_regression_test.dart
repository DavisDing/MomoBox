import '../support/memory_settings_repository.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/application/storage_management_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:momo_box/domain/models/recognition_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/ai_usage_screen.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';
import 'package:momo_box/presentation/widgets/ai_assistant_dialog.dart';

void main() {
  testWidgets('窄屏 AI 周期选择不显示勾选，不发生溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          themeNameProvider.overrideWith((ref) => Stream.value('default')),
          aiUsageLogsProvider.overrideWith((ref) => Stream.value([])),
        ],
        child: MaterialApp(
          theme: buildMomoTheme(MomoPalette.defaultPalette, Brightness.light),
          home: const AiUsageScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in ['近7天', '近30天', '全部', '当日']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<int>>(find.byType(SegmentedButton<int>))
            .showSelectedIcon,
        isFalse,
      );
      expect(find.byIcon(Icons.check), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('AI 助手跟随系统深色模式，没有浅色面板和快捷按钮', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    final darkTheme = buildMomoTheme(
      MomoPalette.defaultPalette,
      Brightness.dark,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          themeNameProvider.overrideWith((ref) => Stream.value('default')),
        ],
        child: MaterialApp(
          theme: buildMomoTheme(MomoPalette.defaultPalette, Brightness.light),
          darkTheme: darkTheme,
          home: const Scaffold(body: AiAssistantDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final assistant = find.byType(AiAssistantDialog);
    expect(Theme.of(tester.element(assistant)).brightness, Brightness.dark);
    for (final container in tester.widgetList<Container>(
      find.descendant(of: assistant, matching: find.byType(Container)),
    )) {
      final decoration = container.decoration;
      if (decoration is BoxDecoration && decoration.color != null) {
        final color = decoration.color!;
        if (color.a > 0.8) expect(color.computeLuminance(), lessThan(0.5));
      }
    }
    for (final chip in tester.widgetList<ActionChip>(find.byType(ActionChip))) {
      expect(chip.backgroundColor, darkTheme.colorScheme.surface);
    }
    expect(tester.takeException(), isNull);
  });

  for (final ai in [false, true]) {
    testWidgets('${ai ? 'AI' : '条码'}配置窄屏下拉菜单不超过输入框宽度', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsServiceProvider.overrideWithValue(_MemorySettings()),
          ],
          child: MaterialApp(
            theme: buildMomoTheme(MomoPalette.defaultPalette, Brightness.dark),
            home: ai ? const AiSettingsScreen() : const BarcodeSettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '配置列表页面');
      await tester.tap(find.text('添加配置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '添加配置弹窗');
      final fields = find.byType(DropdownButtonFormField<String>);
      for (var index = 0; index < fields.evaluate().length; index++) {
        final field = fields.at(index);
        await tester.ensureVisible(field);
        final fieldWidth = tester.getSize(field).width;
        await tester.tap(field);
        await tester.pumpAndSettle();
        final items = find.byType(DropdownMenuItem<String>).hitTestable();
        expect(items, findsWidgets);
        for (final item in items.evaluate()) {
          expect(
            (item.renderObject! as RenderBox).size.width,
            lessThanOrEqualTo(fieldWidth),
          );
        }
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('一键清理需确认、执行中禁止重复、完成后刷新', (tester) async {
    final storage = _ControlledStorage();
    await _pumpStorage(tester, storage);
    await tester.tap(find.text('一键清理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(storage.cleanCalls, 0);
    await tester.tap(find.text('一键清理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认清理'));
    await tester.pump();
    expect(storage.cleanCalls, 1);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '正在处理…'))
          .onPressed,
      isNull,
    );
    storage.result.complete(
      const StorageCleanupReport(
        barcodeEntries: 2,
        media: MediaCleanupReport(deletedFiles: 1, deletedMetadata: 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('清理完成：2 条条码缓存'), findsOneWidget);
    expect(storage.loadCalls, 2);
  });

  testWidgets('一键清理失败不虚报成功且允许重试', (tester) async {
    final storage = _ControlledStorage();
    await _pumpStorage(tester, storage);
    await tester.tap(find.text('一键清理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认清理'));
    await tester.pump();
    storage.result.completeError(StateError('disk unavailable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('清理未全部完成'), findsOneWidget);
    expect(find.textContaining('清理完成：'), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    expect(storage.loadCalls, 2);
  });
}

Future<void> _pumpStorage(
  WidgetTester tester,
  _ControlledStorage storage,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storageManagementServiceProvider.overrideWithValue(storage)],
      child: const MaterialApp(home: StorageManagementScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

class _ControlledStorage implements StorageManagementService {
  final result = Completer<StorageCleanupReport>();
  int cleanCalls = 0;
  int loadCalls = 0;

  @override
  Future<StorageCleanupReport> cleanAll() {
    cleanCalls++;
    return result.future;
  }

  @override
  Future<StorageUsage> loadUsage() async {
    loadCalls++;
    return const StorageUsage(
      databaseBytes: 100,
      mediaBytes: 50,
      barcodeCacheBytes: 10,
      barcodeCacheEntries: 2,
      aiUsageLogBytes: 20,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemorySettings implements SettingsService {
  final values = <String, String>{};

  @override
  Future<String?> getValue(String key) async => values[key];

  @override
  Future<void> setValue(String key, String value) async {
    values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
