import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_draft_service.dart';
import 'package:momo_box/services/secure_settings_service.dart';

import '../support/memory_settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final entry
      in <String?, String>{
        null: 'auto',
        '': 'auto',
        ' \t\n ': 'auto',
        'unexpected': 'auto',
        'chat': 'chat',
        'responses': 'responses',
        ' responses ': 'responses',
      }.entries) {
    test(
      'runtime primary/secondary/fallback normalize protocol ${entry.key} to ${entry.value}',
      () async {
        FlutterSecureStorage.setMockInitialValues({
          'ai_api_key_profile_primary': 'offline-primary',
          'ai_api_key_profile_secondary': 'offline-secondary',
          'ai_api_key_profile_fallback': 'offline-fallback',
        });
        final settings =
            MemorySettingsRepository()
              ..values.addAll({
                AiDraftService.endpointKey: 'https://primary.example/v1',
                AiDraftService.modelKey: 'primary-model',
                AiDraftService.activeProfileKey: 'primary',
                AiDraftService.secondaryEndpointKey:
                    'https://secondary.example/v1',
                AiDraftService.secondaryModelKey: 'secondary-model',
                AiDraftService.secondaryProfileIdKey: 'secondary',
                AiDraftService.fallbackEndpointKey:
                    'https://fallback.example/v1',
                AiDraftService.fallbackModelKey: 'fallback-model',
                AiDraftService.fallbackProfileIdKey: 'fallback',
                if (entry.key != null) ...{
                  AiDraftService.endpointTypeKey: entry.key!,
                  AiDraftService.secondaryTypeKey: entry.key!,
                  AiDraftService.fallbackTypeKey: entry.key!,
                },
              });
        addTearDown(settings.close);
        final configs = await AiDraftService.resolveFallbackConfigs(
          settings,
          SecureSettingsService(),
        );
        expect(configs, hasLength(3));
        expect(
          configs.map((config) => config.endpointType),
          everyElement(entry.value),
        );
      },
    );
  }
}
