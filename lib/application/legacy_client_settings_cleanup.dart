import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/database/app_database.dart';
import '../domain/backup/backup_format.dart';

/// One-way removal of retired phone AI configuration. Business data, NAS
/// credentials and conversation history are deliberately outside this cleanup.
class LegacyClientSettingsCleanup {
  LegacyClientSettingsCleanup(this.database, {FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage();
  final AppDatabase database;
  final FlutterSecureStorage storage;
  Future<void> run() async {
    final marker =
        await (database.select(database.appSettings)..where(
          (row) => row.key.equals('nas_client_cleanup_v1'),
        )).getSingleOrNull();
    if (marker != null) return;
    final secrets = await storage.readAll();
    for (final key
        in secrets.keys
            .where(
              (key) =>
                  key == 'ai_api_key' || key.startsWith('ai_api_key_profile_'),
            )
            .toList()) {
      await storage.delete(key: key);
    }
    await database.transaction(() async {
      await (database.delete(database.appSettings)
        ..where((row) => row.key.isIn(BackupFormat.retiredAiSettingKeys))).go();
      await database
          .into(database.appSettings)
          .insertOnConflictUpdate(
            AppSettingsCompanion.insert(
              key: 'nas_client_cleanup_v1',
              value: 'done',
              updatedAt: DateTime.now(),
            ),
          );
    });
  }
}
