import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';

class SettingsRepository {
  SettingsRepository(this._database);

  final AppDatabase _database;

  Stream<String?> watchValue(String key) {
    return (_database.select(_database.appSettings)
          ..where((setting) => setting.key.equals(key)))
        .watchSingleOrNull()
        .map((entry) => entry?.value);
  }

  Future<void> setValue(String key, String value) async {
    await _database.into(_database.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: key,
            value: value,
            updatedAt: DateTime.now(),
          ),
        );
  }
}
