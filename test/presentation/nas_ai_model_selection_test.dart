import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/models/nas_ai_model.dart';
import 'package:momo_box/application/backend_processing_error.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/repositories/sync_workspace_repository.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/widgets/nas_ai_models.dart';
import '../support/memory_settings_repository.dart';

void main() {
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
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: NasAiModels())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('family-fast'), findsOneWidget);
      expect(find.text('family-smart'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('添加配置'), findsNothing);
      await tester.tap(find.text('family-smart'));
      await tester.pumpAndSettle();
      expect(settings.values[nasAiSelectionKey(identity)], 'family-smart');
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
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: NasAiModels())),
          ),
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
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: NasAiModels())),
          ),
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
