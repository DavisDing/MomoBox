import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';
import '../../domain/models/initial_import_models.dart';
import '../../domain/models/nas_import_models.dart';
import 'sync_workspace_repository.dart';

const initialImportEntities = ['categories', 'products', 'product_batches',
  'shopping_items', 'reminder_settings', 'history'];

class StoredInitialImport {
  const StoredInitialImport({required this.preview, required this.status,
    required this.historyCursor, required this.historyUntil, required this.snapshotApplied,
    required this.confirmStarted,
    this.receipt, this.message});
  final InitialImportPreview preview;
  final InitialImportStatus status;
  final NasImportReceipt? receipt;
  final String? message;
  final int historyCursor;
  final int historyUntil;
  final bool snapshotApplied;
  final bool confirmStarted;

  InitialImportProgress get progress => InitialImportProgress(
    importId: preview.importId, status: status, counts: preview.counts,
    acceptedCount: receipt?.isCompleted == true ? preview.totalCount : 0,
    totalCount: preview.totalCount, exclusions: preview.exclusions,
    familyTimeZone: preview.familyTimeZone, message: message,
    canAbandon: !confirmStarted && receipt?.isCompleted != true &&
      status != InitialImportStatus.abandoned && status != InitialImportStatus.completed);
}

class InitialImportRepository {
  InitialImportRepository(this.database);
  final AppDatabase database;

  String _marker(String scopeId) => 'sync_initial_import_active:$scopeId';
  String _revision(String scopeId) => 'sync_initial_import_revision:$scopeId';

  Stream<InitialImportProgress?> watchProgress(String scopeId) =>
      (database.select(database.appSettings)
        ..where((row) => row.key.equals(_revision(scopeId))))
      .watchSingleOrNull().asyncMap((_) async => (await load(scopeId))?.progress);

  Future<StoredInitialImport?> load(String scopeId) async {
    final rows = await database.customSelect('''
      SELECT * FROM sync_initial_import_plans WHERE scope_id = ?
      ORDER BY updated_at DESC, import_id DESC LIMIT 1
    ''', variables: [Variable<String>(scopeId)]).get();
    if (rows.isEmpty) return null;
    final row = rows.single;
    final id = row.read<String>('import_id');
    final metadata = Map<String, dynamic>.from(jsonDecode(row.read<String>('metadata_json')) as Map);
    final manifest = <String, dynamic>{'format_version': 1,
      'import_id': id, 'local_workspace_id': row.read<String>('workspace_id'),
      'device_id': metadata['device_id'], 'unsettled_outbox_count': 0,
      for (final entity in initialImportEntities) entity: <Map<String, dynamic>>[]};
    final items = await database.customSelect('''
      SELECT entity, payload_json FROM sync_initial_import_items
      WHERE import_id = ? ORDER BY ordinal
    ''', variables: [Variable<String>(id)]).get();
    for (final item in items) {
      (manifest[item.read<String>('entity')] as List).add(
        Map<String, dynamic>.from(jsonDecode(item.read<String>('payload_json')) as Map));
    }
    final preview = InitialImportPreview(importId: id,
      target: SyncWorkspaceIdentity.decode(row.read<String>('identity_json')),
      localWorkspaceId: row.read<String>('workspace_id'),
      counts: Map<String, int>.from(metadata['counts'] as Map),
      blockers: const [], exclusions: List<String>.from(metadata['exclusions'] as List),
      categories: (metadata['categories'] as List).map((raw) {
        final value = raw as Map;
        return InitialImportCategory(sourceName: value['name'] as String,
          categoryId: value['id'] as String,
          action: InitialImportCategoryAction.values.byName(value['action'] as String),
          reason: value['reason'] as String?);
      }).toList(growable: false),
      fingerprint: row.read<String>('local_digest'),
      familyTimeZone: metadata['family_time_zone'] as String, manifest: manifest);
    final receipt = row.readNullable<String>('receipt_json');
    return StoredInitialImport(preview: preview,
      status: InitialImportStatus.values.byName(row.read<String>('status')),
      receipt: receipt == null ? null : NasImportReceipt.fromJson(
        Map<String, dynamic>.from(jsonDecode(receipt) as Map)),
      message: row.readNullable<String>('message'),
      historyCursor: row.read<int>('history_cursor'),
      historyUntil: row.read<int>('history_until'),
      snapshotApplied: row.read<int>('snapshot_applied') != 0,
      confirmStarted: row.read<int>('confirm_started') != 0);
  }

  Future<void> savePrepared(InitialImportPreview preview) => database.transaction(() async {
    final previous = await load(preview.target.familyId);
    if (previous != null && previous.progress.isActive) {
      throw StateError('已有冻结导入计划，请审阅并恢复原计划。');
    }
    final metadata = {'device_id': preview.manifest['device_id'], 'counts': preview.counts,
      'exclusions': preview.exclusions, 'family_time_zone': preview.familyTimeZone,
      'categories': preview.categories.map((category) => {'name': category.sourceName,
        'id': category.categoryId, 'action': category.action.name,
        'reason': category.reason}).toList(growable: false)};
    await database.customStatement('''
      INSERT INTO sync_initial_import_plans(import_id,scope_id,identity_json,workspace_id,
        local_digest,status,metadata_json,updated_at) VALUES(?,?,?,?,?,?,?,?)
    ''', [preview.importId, preview.target.familyId, preview.target.encode(),
      preview.localWorkspaceId, preview.fingerprint, InitialImportStatus.prepared.name,
      jsonEncode(metadata), DateTime.now().toUtc().toIso8601String()]);
    var ordinal = 0;
    for (final entity in initialImportEntities) {
      for (final raw in preview.manifest[entity] as List) {
        final payload = Map<String, dynamic>.from(raw as Map);
        await database.customStatement('''
          INSERT INTO sync_initial_import_items(import_id,entity,entity_id,ordinal,payload_json)
          VALUES(?,?,?,?,?)
        ''', [preview.importId, entity, payload['id'], ordinal++, jsonEncode(payload)]);
      }
    }
    await _setMarker(preview.target.familyId, preview.importId);
    await _notify(preview.target.familyId);
  });

  Future<void> update(String scopeId, String importId, {
    required InitialImportStatus status, NasImportReceipt? receipt, String? message,
    int? historyCursor, int? historyUntil, bool? snapshotApplied,
    bool? confirmStarted,
  }) => database.transaction(() async {
    await database.customStatement('''
      UPDATE sync_initial_import_plans SET status=?,
        receipt_json=COALESCE(?,receipt_json),message=?,
        history_cursor=COALESCE(?,history_cursor),history_until=COALESCE(?,history_until),
        snapshot_applied=COALESCE(?,snapshot_applied),
        confirm_started=COALESCE(?,confirm_started),updated_at=?
      WHERE scope_id=? AND import_id=?
    ''', [status.name, receipt == null ? null : jsonEncode(receipt.toJson()), message,
      historyCursor, historyUntil, snapshotApplied == null ? null : (snapshotApplied ? 1 : 0),
      confirmStarted == null ? null : (confirmStarted ? 1 : 0),
      DateTime.now().toUtc().toIso8601String(), scopeId, importId]);
    if (status == InitialImportStatus.completed || status == InitialImportStatus.abandoned) {
      await (database.delete(database.appSettings)
        ..where((row) => row.key.equals(_marker(scopeId)) & row.value.equals(importId))).go();
    }
    await _notify(scopeId);
  });

  Future<void> saveHistoryPage(String scopeId, NasImportHistoryPage page) async {
    for (final record in page.records) {
      final id = record['id'];
      final cursor = record['cursor'];
      if (id is! String || id.isEmpty || cursor is! int || cursor < 1) {
        throw const FormatException('历史来源或游标无效。');
      }
      final existing = await database.customSelect('''
        SELECT payload_json FROM sync_imported_history WHERE scope_id=? AND source_id=?
      ''', variables: [Variable<String>(scopeId), Variable<String>(id)]).getSingleOrNull();
      final payload = jsonEncode(record);
      if (existing != null && existing.read<String>('payload_json') != payload) {
        throw const FormatException('相同历史来源 ID 返回了不同内容，已暂停恢复。');
      }
      if (existing == null) {
        await database.customStatement('''
          INSERT INTO sync_imported_history(scope_id,source_id,cursor,payload_json) VALUES(?,?,?,?)
        ''', [scopeId, id, cursor, payload]);
      }
    }
  }

  Future<List<Map<String, dynamic>>> history(String scopeId, {int after = 0,
    int limit = 100}) async {
    if (after < 0 || limit < 1 || limit > 500) throw ArgumentError('invalid history bounds');
    final rows = await database.customSelect('''
      SELECT payload_json FROM sync_imported_history WHERE scope_id=? AND cursor>?
      ORDER BY cursor LIMIT ?
    ''', variables: [Variable<String>(scopeId), Variable<int>(after), Variable<int>(limit)]).get();
    return rows.map((row) => Map<String, dynamic>.from(
      jsonDecode(row.read<String>('payload_json')) as Map)).toList(growable: false);
  }

  Future<void> _setMarker(String scopeId, String importId) =>
      database.into(database.appSettings).insertOnConflictUpdate(AppSettingsCompanion.insert(
        key: _marker(scopeId), value: importId, updatedAt: DateTime.now().toUtc()));

  Future<void> _notify(String scopeId) =>
      database.into(database.appSettings).insertOnConflictUpdate(AppSettingsCompanion.insert(
        key: _revision(scopeId), value: DateTime.now().toUtc().toIso8601String(),
        updatedAt: DateTime.now().toUtc()));
}
