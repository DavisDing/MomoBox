import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/models/nas_ai_model.dart';
import 'package:momo_box/application/backend_processing_error.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/repositories/sync_workspace_repository.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';
import 'package:momo_box/presentation/widgets/nas_ai_models.dart';
import '../support/memory_settings_repository.dart';

void main() {
  testWidgets('设置展示当前模型，大目录按需展开且搜索覆盖全部模型', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(340, 760);
    addTearDown(tester.view.reset);
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    const identity = SyncWorkspaceIdentity(
      endpoint: 'https://nas.example/api/v1/',
      userId: 'member',
      familyId: 'family',
    );
    final selectionKey = nasAiSelectionKey(identity);
    await settings.setValue(selectionKey, 'selected-model');
    var loads = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          syncWorkspaceIdentityProvider.overrideWithValue(identity),
          nasAiModelsProvider.overrideWith((ref) async {
            loads++;
            return [
              const NasAiModel('selected-model'),
              for (var i = 1; i < 80; i++) NasAiModel('catalog-model-$i'),
            ];
          }),
        ],
        child: const MaterialApp(home: AiSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final permission = find.text('允许 AI 提议应用操作');
    final chooser = find.text('AI 模型');
    expect(find.text('selected-model'), findsOneWidget);
    expect(
      tester.getTopLeft(permission).dy,
      lessThan(tester.getTopLeft(chooser).dy),
    );
    expect(find.byType(RadioListTile<String>), findsNothing);
    expect(loads, 0);

    await tester.tap(chooser);
    await tester.pumpAndSettle();
    final allModels = find.text('全部模型（80）');
    expect(find.text('当前模型 · selected-model'), findsOneWidget);
    expect(allModels, findsOneWidget);
    expect(find.byType(RadioListTile<String>), findsOneWidget);
    final collapsedHeight = tester.getSize(find.byType(NasAiModels)).height;
    await tester.tap(allModels);
    await tester.pumpAndSettle();
    expect(find.text('catalog-model-1'), findsOneWidget);
    expect(
      tester.getSize(find.byType(NasAiModels)).height,
      greaterThan(collapsedHeight),
    );
    expect(find.byType(RadioListTile<String>).evaluate().length, lessThan(81));
    await tester.tap(allModels);
    await tester.pumpAndSettle();
    expect(find.text('catalog-model-1'), findsNothing);

    await tester.enterText(find.byType(TextField), '  MODEL-79  ');
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pumpAndSettle();
    final match = find.text('catalog-model-79');
    final scrollable =
        find
            .descendant(
              of: find.byType(NasAiModels),
              matching: find.byType(Scrollable),
            )
            .first;
    await tester.scrollUntilVisible(match, 60, scrollable: scrollable);
    expect(settings.values[selectionKey], 'selected-model');
    await tester.tap(match);
    await tester.pumpAndSettle();
    expect(settings.values[selectionKey], 'catalog-model-79');
    expect(loads, 1);
    expect(tester.takeException(), isNull);

    tester.view.resetViewInsets();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('catalog-model-79'), findsOneWidget);
    expect(find.byType(NasAiModels), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'App offers NAS model IDs without endpoint or API key inputs and saves selection for current household',
    (tester) async {
      final settings = MemorySettingsRepository();
      addTearDown(settings.close);
      const identity = SyncWorkspaceIdentity(
        endpoint: 'https://nas.example/api/v1/',
        userId: 'member',
        familyId: 'family',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(settings),
            syncWorkspaceIdentityProvider.overrideWithValue(identity),
            selectedAiModelProvider.overrideWith((ref) => Stream.value(null)),
            nasAiModelsProvider.overrideWith(
              (ref) async => const [
                NasAiModel('family-fast', isDefault: true),
                NasAiModel('family-smart'),
              ],
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: NasAiModels())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('family-fast'), findsOneWidget);
      expect(find.text('family-smart'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      final search = find.byType(TextField);
      await tester.enterText(search, '  SMART  ');
      await tester.pumpAndSettle();
      expect(find.text('family-smart'), findsOneWidget);
      expect(find.text('family-fast'), findsNothing);
      expect(find.text('NAS 默认模型'), findsOneWidget);
      expect(settings.values, isEmpty);
      await tester.enterText(search, 'missing-model');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的模型'), findsOneWidget);
      expect(find.text('原选模型已不可用，请重新选择。'), findsNothing);
      expect(settings.values, isEmpty);
      await tester.tap(find.byTooltip('清除模型搜索'));
      await tester.pumpAndSettle();
      expect(find.text('family-fast'), findsOneWidget);
      expect(find.text('family-smart'), findsOneWidget);
      expect(find.text('添加配置'), findsNothing);
      settings.failWrites = true;
      await tester.tap(find.text('family-smart'));
      await tester.pumpAndSettle();
      expect(find.text('模型选择未保存，请重试。'), findsOneWidget);
      expect(settings.values, isEmpty);
      settings.failWrites = false;
      await tester.tap(find.text('family-smart'));
      await tester.pumpAndSettle();
      expect(settings.values[nasAiSelectionKey(identity)], 'family-smart');
      expect(find.text('模型选择未保存，请重试。'), findsNothing);
      expect(settings.values.keys, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'model catalog failure exposes a retry without offering phone credentials',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedAiModelProvider.overrideWith((ref) => Stream.value(null)),
            nasAiModelsProvider.overrideWith(
              (ref) async => throw StateError('offline'),
            ),
          ],
          child: const MaterialApp(home: Scaffold(body: NasAiModels())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('模型列表暂不可用'), findsOneWidget);
      expect(find.byTooltip('刷新模型列表'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'stopped gateway shows a safe network reason; refresh recovers catalog',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedAiModelProvider.overrideWith((ref) => Stream.value(null)),
            nasAiModelsProvider.overrideWith((ref) async {
              attempts++;
              if (attempts == 1) {
                throw NasApiError(
                  kind: NasApiErrorKind.server,
                  statusCode: 502,
                  code: 'AI_MODELS_UNREACHABLE',
                  message: 'secret-key https://private-gateway',
                  requestId: '3df7425c-b97f-4b54-88ff-4c48c0f4ec5c',
                );
              }
              return const [NasAiModel('recovered-model', isDefault: true)];
            }),
          ],
          child: const MaterialApp(home: Scaffold(body: NasAiModels())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('NAS 无法连接 AI 网关'), findsOneWidget);
      expect(
        find.textContaining('3df7425c-b97f-4b54-88ff-4c48c0f4ec5c'),
        findsOneWidget,
      );
      expect(find.textContaining('secret-key'), findsNothing);
      expect(find.textContaining('private-gateway'), findsNothing);
      await tester.tap(find.byTooltip('刷新模型列表'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('recovered-model'), findsOneWidget);
      expect(find.textContaining('NAS 无法连接 AI 网关'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scenario in <(Object, String)>[
    (
      const BackendProcessingSetupException('NAS 正在自动初始化，请稍候；若持续失败请重试连接。'),
      'NAS 正在自动初始化',
    ),
    (
      NasApiError(
        kind: NasApiErrorKind.notFound,
        statusCode: 404,
        message: 'raw',
      ),
      'NAS 后端缺少模型目录接口',
    ),
    (
      NasApiError(
        kind: NasApiErrorKind.server,
        statusCode: 502,
        code: 'AI_MODELS_AUTH_FAILED',
        message: 'raw',
      ),
      'AI 网关拒绝了模型目录请求',
    ),
    (
      NasApiError(
        kind: NasApiErrorKind.server,
        statusCode: 502,
        code: 'AI_MODELS_EMPTY',
        message: 'raw',
      ),
      'AI 网关返回的可用模型为空',
    ),
    (
      NasApiError(
        kind: NasApiErrorKind.server,
        statusCode: 502,
        code: 'AI_MODELS_INVALID_RESPONSE',
        message: 'raw',
      ),
      'AI 网关未返回兼容的模型目录',
    ),
  ]) {
    testWidgets('model setup explains ${scenario.$2}', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedAiModelProvider.overrideWith((ref) => Stream.value(null)),
            nasAiModelsProvider.overrideWith((ref) async => throw scenario.$1),
          ],
          child: const MaterialApp(home: Scaffold(body: NasAiModels())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining(scenario.$2), findsOneWidget);
      expect(find.text('raw'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
