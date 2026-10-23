import 'dart:convert';

import '../../core/database/app_database.dart';
import '../../domain/models/initial_import_models.dart';

class SyncCategoryRepository {
  SyncCategoryRepository(this.database);
  final AppDatabase database;

  String _key(String scopeId, String name) =>
      'sync_category_identity:$scopeId:${Uri.encodeComponent(name)}';

  Future<String?> readId(String scopeId, String name) async {
    final id = (await (database.select(database.appSettings)
      ..where((row) => row.key.equals(_key(scopeId, name))))
      .getSingleOrNull())?.value;
    if (id == null) return null;
    final remote = await (database.select(database.appSettings)
      ..where((row) => row.key.equals('sync_aux:$scopeId:categories:$id')))
      .getSingleOrNull();
    if (remote == null) return id; // A new local category has no remote row yet.
    final envelope = Map<String, dynamic>.from(jsonDecode(remote.value) as Map);
    final payload = envelope['payload'];
    if (envelope['deleted_at'] != null ||
        (payload is Map && payload['deleted_at'] != null)) {
      return null; // Retain audit/binding; never reference its tombstoned UUID.
    }
    return id;
  }

  Future<List<Map<String, dynamic>>> remoteCategories(String scopeId) async {
    final prefix = 'sync_aux:$scopeId:categories:';
    final rows = await database.select(database.appSettings).get();
    final result = <Map<String, dynamic>>[];
    for (final row in rows.where((row) => row.key.startsWith(prefix))) {
      final envelope = Map<String, dynamic>.from(jsonDecode(row.value) as Map);
      if (envelope['deleted_at'] != null) continue;
      final rawPayload = envelope['payload'];
      final id = envelope['entity_id'];
      if (envelope['entity'] != 'categories' || id is! String || rawPayload is! Map) {
        throw const FormatException('分类同步记录损坏，请保留现场核对。');
      }
      final payload = Map<String, dynamic>.from(rawPayload);
      if (payload['deleted_at'] != null) continue;
      if (payload['name'] is! String || (payload['id'] != null && payload['id'] != id)) {
        throw const FormatException('分类身份或名称无效。');
      }
      result.add({...payload, 'id': id});
    }
    return result;
  }

  Future<void> save(String scopeId, InitialImportCategory category) async {
    await database.into(database.appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(key: _key(scopeId, category.sourceName),
        value: category.categoryId, updatedAt: DateTime.now().toUtc()));
  }

  Future<void> rename(String scopeId, String categoryId, String name) async {
    final prefix = 'sync_category_identity:$scopeId:';
    final rows = await (database.select(database.appSettings)
      ..where((row) => row.value.equals(categoryId))).get();
    for (final row in rows) {
      if (row.key.startsWith(prefix) && row.key != _key(scopeId, name)) {
        await (database.delete(database.appSettings)..where((setting) => setting.key.equals(row.key))).go();
      }
    }
    await save(scopeId, InitialImportCategory(sourceName: name, categoryId: categoryId,
      action: InitialImportCategoryAction.reuse));
  }
}
