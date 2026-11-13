import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/legacy_client_settings_cleanup.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'retired phone AI configuration is removed without deleting NAS credentials or business preferences',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'ai_api_key': 'old',
        'ai_api_key_profile_custom': 'old2',
        'nas_access_token': 'keep',
      });
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      await settings.setValue('ai_api_endpoint', 'old-endpoint');
      await settings.setValue('ai_api_profiles', 'invalid old profiles');
      await settings.setValue('theme', 'momo');
      await settings.setValue('ai_assistant_sessions', 'keep history');
      final cleanup = LegacyClientSettingsCleanup(db);
      await cleanup.run();
      await cleanup.run();
      expect(await settings.getValue('ai_api_endpoint'), isNull);
      expect(await settings.getValue('ai_api_profiles'), isNull);
      expect(await settings.getValue('theme'), 'momo');
      expect(await settings.getValue('ai_assistant_sessions'), 'keep history');
      expect(await const FlutterSecureStorage().readAll(), {
        'nas_access_token': 'keep',
      });
    },
  );
}
