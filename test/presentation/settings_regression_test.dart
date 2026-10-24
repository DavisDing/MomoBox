import '../support/memory_settings_repository.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/application/ai_draft_service.dart';
import 'package:momo_box/application/ai_fallback_executor.dart';
import 'package:momo_box/application/storage_management_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:momo_box/domain/models/recognition_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/ai_usage_screen.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';
import 'package:momo_box/presentation/widgets/ai_assistant_dialog.dart';
import 'package:momo_box/services/secure_settings_service.dart';

void main() {
  testWidgets('首次模型配置与新增服务默认自动适配，保存后仍为 auto', (tester) async {
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    await _pumpAiSettings(tester, settings, _ControlledAiExecutor());
    expect(find.text('OpenAI（自动适配）'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑配置'));
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).last).initialValue, 'auto');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(settings.values[AiDraftService.endpointTypeKey], 'auto');

    await tester.tap(find.text('添加配置'));
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).last).initialValue, 'auto');
    await tester.enterText(find.byType(TextField).first, '新增自动服务');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    final profiles = (jsonDecode(settings.values[AiDraftService.profilesKey]!) as List);
    expect(profiles.singleWhere((p) => p['name'] == '新增自动服务')['endpointType'], 'auto');
    expect(tester.takeException(), isNull);
  });

  for (final entry in <String?, String>{
    null: 'auto',
    '': 'auto',
    ' \t\n ': 'auto',
    'auto': 'auto',
    'chat': 'chat',
    'responses': 'responses',
    ' chat ': 'chat',
    'unexpected': 'auto',
  }.entries) {
    final protocol = entry.key;
    final expected = entry.value;
    testWidgets('已有模型协议 ${jsonEncode(protocol)} 读入编辑保存为 $expected', (tester) async {
      final settings = _aiSettings(protocol: protocol);
      addTearDown(settings.close);
      await _pumpAiSettings(tester, settings, _ControlledAiExecutor());
      final loadedProfiles = jsonDecode(settings.values[AiDraftService.profilesKey]!) as List;
      expect(loadedProfiles.single['endpointType'], expected);
      await tester.tap(find.byTooltip('编辑配置'));
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>).last).initialValue, expected);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(settings.values[AiDraftService.endpointTypeKey], expected);
      final profiles = jsonDecode(settings.values[AiDraftService.profilesKey]!) as List;
      expect(profiles.single['endpointType'], expected);
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in {'': 'auto', ' \t\n ': 'auto', 'chat': 'chat', 'responses': 'responses'}.entries) {
    testWidgets('旧版主副兜底协议 ${jsonEncode(entry.key)} 迁移编辑保存为 ${entry.value}', (tester) async {
      final settings = MemorySettingsRepository()..values.addAll({
        AiDraftService.endpointKey: 'https://model.example/v1',
        AiDraftService.modelKey: 'primary-model',
        AiDraftService.endpointTypeKey: entry.key,
        AiDraftService.secondaryEndpointKey: 'https://secondary.example/v1',
        AiDraftService.secondaryModelKey: 'secondary-model',
        AiDraftService.secondaryTypeKey: entry.key,
        AiDraftService.fallbackEndpointKey: 'https://fallback.example/v1',
        AiDraftService.fallbackModelKey: 'fallback-model',
        AiDraftService.fallbackTypeKey: entry.key,
      });
      addTearDown(settings.close);
      await _pumpAiSettings(tester, settings, _ControlledAiExecutor());
      final profiles = jsonDecode(settings.values[AiDraftService.profilesKey]!) as List;
      expect(profiles, hasLength(3));
      expect(profiles.map((profile) => profile['endpointType']), everyElement(entry.value));
      await tester.tap(find.byTooltip('编辑配置').first);
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>).last).initialValue, entry.value);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      for (final key in [AiDraftService.endpointTypeKey, AiDraftService.secondaryTypeKey, AiDraftService.fallbackTypeKey]) {
        expect(settings.values[key], entry.value);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('新增模型缺少密钥时就地提示失败，不发送请求', (tester) async {
    final settings = _aiSettings();
    final executor = _ControlledAiExecutor();
    addTearDown(settings.close);
    await _pumpAiSettings(tester, settings, executor);
    final before = Map<String, String>.of(settings.values);
    await tester.tap(find.text('添加配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试失败：请填写'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(executor.configs, isEmpty);
    expect(settings.values, before);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '测试')).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  for (final success in [true, false]) {
    testWidgets('模型测试${success ? '成功' : '失败'}在窄屏键盘上方固定反馈且不保存', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = _aiSettings();
      final executor = _ControlledAiExecutor();
      addTearDown(settings.close);
      await _pumpAiSettings(tester, settings, executor, textScale: 1.3);
      await tester.tap(find.byTooltip('编辑配置'));
      await tester.pumpAndSettle();
      final before = Map<String, String>.of(settings.values);
      final keysBefore = await const FlutterSecureStorage().readAll();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试'));
      await tester.pump();
      expect(executor.configs, hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确定')).onPressed, isNull);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '测试中…')).onPressed, isNull);
      final feedback = find.byKey(const ValueKey('ai-connection-test-feedback'));
      expect(find.ancestor(of: feedback, matching: find.byType(SingleChildScrollView)), findsNothing);
      _expectFeedbackAboveKeyboard(tester, feedback);
      // Scroll to the top while the request is pending. Feedback must stay
      // visible without any scroll-to-result side effect on completion.
      await tester.drag(find.descendant(of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView)).first, const Offset(0, 600));
      await tester.pump();
      executor.complete(0, success: success);
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining(success ? '测试通过' : '测试失败'), findsOneWidget);
      expect(find.byIcon(success ? Icons.check_circle_outline : Icons.error_outline), findsOneWidget);
      _expectFeedbackAboveKeyboard(tester, feedback);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确定')).onPressed, isNotNull);
      expect(settings.values, before);
      expect(await const FlutterSecureStorage().readAll(), keysBefore);
      expect(tester.takeException(), isNull);
    });
  }

  for (final oldSuccess in [true, false]) {
    testWidgets('修改后还原参数并重测，旧${oldSuccess ? '成功' : '失败'}不覆盖新请求', (tester) async {
      final settings = _aiSettings();
      final executor = _ControlledAiExecutor();
      addTearDown(settings.close);
      await _pumpAiSettings(tester, settings, executor);
      await tester.tap(find.byTooltip('编辑配置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试'));
      await tester.pump();
      final model = find.byType(TextField).at(2);
      await tester.enterText(model, 'changed-model');
      await tester.enterText(model, 'test-model');
      await tester.pump();
      expect(find.text('配置已变化，请重新测试。'), findsOneWidget);
      await tester.tap(find.text('测试'));
      await tester.pump();
      expect(executor.configs, hasLength(2));
      executor.complete(0, success: oldSuccess);
      await tester.pump();
      expect(find.text('正在测试当前配置…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('测试通过'), findsNothing);
      expect(find.textContaining('测试失败'), findsNothing);
      executor.complete(1, success: !oldSuccess);
      await tester.pumpAndSettle();
      expect(find.textContaining(oldSuccess ? '测试失败' : '测试通过'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('新测试完成后旧请求才返回，也不覆盖当前结果', (tester) async {
    final settings = _aiSettings();
    final executor = _ControlledAiExecutor();
    addTearDown(settings.close);
    await _pumpAiSettings(tester, settings, executor);
    await tester.tap(find.byTooltip('编辑配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(2), 'new-model');
    await tester.pump();
    await tester.tap(find.text('测试'));
    await tester.pump();
    executor.complete(1);
    await tester.pumpAndSettle();
    expect(find.textContaining('测试通过'), findsOneWidget);
    executor.complete(0, success: false);
    await tester.pumpAndSettle();
    expect(find.textContaining('测试通过'), findsOneWidget);
    expect(find.textContaining('测试失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭测试弹窗再打开，晚到结果不污染新弹窗', (tester) async {
    final settings = _aiSettings();
    final executor = _ControlledAiExecutor();
    addTearDown(settings.close);
    await _pumpAiSettings(tester, settings, executor);
    await tester.tap(find.byTooltip('编辑配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试'));
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑配置'));
    await tester.pumpAndSettle();
    executor.complete(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-connection-test-feedback')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('读取密钥期间关闭或修改配置，不再发送旧测试请求', (tester) async {
    final settings = _aiSettings();
    final executor = _ControlledAiExecutor();
    final secure = _DelayedProfileKeyService();
    addTearDown(settings.close);
    await _pumpAiSettings(tester, settings, executor, secure: secure);
    for (final close in [false, true]) {
      await tester.tap(find.byTooltip('编辑配置'));
      await tester.pumpAndSettle();
      secure.pendingRead = Completer<String?>();
      await tester.tap(find.text('测试'));
      await tester.pump();
      if (close) {
        await tester.tap(find.text('取消'));
      } else {
        await tester.enterText(find.byType(TextField).at(2), 'changed-model');
      }
      secure.pendingRead!.complete('test-key');
      await tester.pumpAndSettle();
      secure.pendingRead = null;
      expect(executor.configs, isEmpty);
      if (!close) {
        expect(find.text('配置已变化，请重新测试。'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    }
  });

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
    for (final element in find.byType(ActionChip).evaluate()) {
      final chip = element.widget as ActionChip;
      // Shared UI now supplies the same dark surface through ChipTheme.
      expect(chip.backgroundColor ?? ChipTheme.of(element).backgroundColor,
          darkTheme.colorScheme.surface);
    }
    expect(tester.takeException(), isNull);
  });

  for (final ai in [false, true]) {
    testWidgets('${ai ? 'AI' : '条码'}配置右滑先关闭弹窗，保留配置页', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final rootKey = GlobalKey<NavigatorState>();
      final settingsKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(ProviderScope(
        overrides: [settingsServiceProvider.overrideWithValue(_MemorySettings())],
        child: MaterialApp(
          navigatorKey: rootKey,
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Navigator(
            key: settingsKey,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => Scaffold(body: TextButton(
                onPressed: () => settingsKey.currentState!.push(MaterialPageRoute<void>(
                  builder: (_) => ai ? const AiSettingsScreen() : const BarcodeSettingsScreen(),
                )),
                child: const Text('打开配置页'),
              )),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开配置页'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加配置'));
      await tester.pumpAndSettle();
      final title = ai ? '添加 AI 模型服务' : '添加条码接口';
      expect(find.text(title), findsOneWidget);
      expect(rootKey.currentState!.canPop(), isFalse, reason: '弹窗不应挂在根导航器');
      expect(settingsKey.currentState!.canPop(), isTrue);
      final actions = tester.widget<AlertDialog>(find.byType(AlertDialog)).actions!;
      expect(actions.map((action) => ((action as ButtonStyleButton).child! as Text).data),
          ['测试', '取消', '确定']);
      await tester.dragFrom(const Offset(2, 400), const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(find.text(title), findsNothing);
      expect(find.text('添加配置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

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

MemorySettingsRepository _aiSettings({String? protocol}) {
  return MemorySettingsRepository()..values.addAll({
    AiDraftService.activeProfileKey: 'source',
    AiDraftService.endpointKey: 'https://model.example/v1',
    AiDraftService.modelKey: 'test-model',
    if (protocol != null) AiDraftService.endpointTypeKey: protocol,
    AiDraftService.profilesKey: jsonEncode([
      {
        'id': 'source',
        'name': '已配置模型',
        'endpoint': 'https://model.example/v1',
        'model': 'test-model',
        if (protocol != null) 'endpointType': protocol,
        AiDraftService.profileRoleKey: AiDraftService.primaryRole,
      },
    ]),
  });
}

Future<void> _pumpAiSettings(
  WidgetTester tester,
  MemorySettingsRepository settings,
  _ControlledAiExecutor executor, {
  double textScale = 1,
  SecureSettingsService? secure,
}) async {
  FlutterSecureStorage.setMockInitialValues({'ai_api_key_profile_source': 'test-key'});
  await tester.pumpWidget(ProviderScope(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(settings),
      aiConnectionTestExecutorProvider.overrideWithValue(executor),
      if (secure != null) secureSettingsServiceProvider.overrideWithValue(secure),
    ],
    child: MaterialApp(
      theme: buildMomoTheme(MomoPalette.defaultPalette, Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const AiSettingsScreen(),
    ),
  ));
  await tester.pumpAndSettle();
}

void _expectFeedbackAboveKeyboard(WidgetTester tester, Finder feedback) {
  final rect = tester.getRect(feedback);
  final keyboardTop = (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
      tester.view.devicePixelRatio;
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThan(keyboardTop));
  expect(feedback.hitTestable(), findsOneWidget);
}

class _ControlledAiExecutor implements AiFallbackExecutor {
  final configs = <AiEndpointConfig>[];
  final results = <Completer<AiFallbackResponse>>[];

  @override
  Future<AiFallbackResponse> execute({
    required List<AiEndpointConfig> configs,
    required String systemPrompt,
    required String userPrompt,
    List<Map<String, String>> chatHistory = const [],
    double temperature = 0.2,
  }) {
    this.configs.add(configs.single);
    final result = Completer<AiFallbackResponse>();
    results.add(result);
    return result.future;
  }

  void complete(int index, {bool success = true}) {
    if (!success) {
      results[index].completeError(TimeoutException('offline test failure'));
      return;
    }
    final config = configs[index];
    results[index].complete(AiFallbackResponse(
      content: 'OK',
      rawDecoded: const {},
      usedLevel: config.level,
      usedConfig: config,
      actualProtocol: 'responses',
      traceLogs: [AiExecutionAttemptLog(
        level: config.level,
        model: config.model,
        endpoint: config.endpoint,
        durationMs: 15,
        isSuccess: true,
      )],
    ));
  }

  @override
  void close() {}
}

class _DelayedProfileKeyService extends SecureSettingsService {
  Completer<String?>? pendingRead;

  @override
  Future<String?> readAiApiKeyForProfile(String profileId) =>
      pendingRead?.future ?? super.readAiApiKeyForProfile(profileId);
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
