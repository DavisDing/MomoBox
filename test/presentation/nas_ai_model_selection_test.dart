import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/models/nas_ai_model.dart';
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
}
