import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import '../core/database/app_database.dart';
import '../data/nas/nas_sync_api.dart';
import '../data/nas/nas_api_error.dart';
import '../data/repositories/media_repository.dart';
import '../data/repositories/sync_workspace_repository.dart';
import '../domain/models/recognition_models.dart';
import '../services/media_storage_service.dart';

/// Null means explicitly configured single-device mode. A selected but
/// unavailable NAS must throw, so OCR/AI never silently run on the phone.
typedef BackendResolver = Future<NasSyncApi?> Function();

class BackendProcessingService {
  BackendProcessingService(this.database, this.repository, this.storage,
      {required this.resolveApi, required this.scopeId});
  final AppDatabase database;
  final MediaRepository repository;
  final MediaStorageService storage;
  final BackendResolver resolveApi;
  final String? Function() scopeId;

  Future<void> _state(String id, String scope, String state, {String? error}) async {
    await database.customStatement('''INSERT INTO backend_media_state
      (asset_id,scope_id,state,error,updated_at) VALUES (?,?,?,?,?)
      ON CONFLICT(asset_id) DO UPDATE SET state=excluded.state,
      error=excluded.error,updated_at=excluded.updated_at
      WHERE backend_media_state.scope_id=excluded.scope_id''',
      [id, scope, state, error, DateTime.now().toUtc().toIso8601String()]);
    // Notify existing media streams after raw side-table updates.
    await database.customUpdate('UPDATE media_assets SET mime_type=mime_type WHERE id=?',
      variables: [Variable.withString(id)], updates: {database.mediaAssets});
  }

  Future<String> _scope(NasSyncApi api) async {
    await api.assertProcessingSession();
    final scope = scopeId();
    if (scope == null) throw StateError('请先登录当前家庭。');
    return scope;
  }

  /// Persist local intent against the original binding without requiring login.
  Future<void> stage(MediaAsset asset, {bool deleting = false}) async {
    final owner = await SyncWorkspaceRepository(database).readOwner();
    final current = scopeId();
    if (current != null && owner != null && current != owner.familyId) throw StateError('当前家庭与本机图片绑定不匹配。');
    final scope = owner?.familyId ?? current;
    if (scope == null) throw StateError('缺少原家庭绑定，请保留图片并重新登录。');
    final old = await database.customSelect('SELECT scope_id FROM backend_media_state WHERE asset_id=?',
      variables: [Variable.withString(asset.id)]).getSingleOrNull();
    if (old != null && old.read<String>('scope_id') != scope) throw StateError('图片家庭不匹配。');
    await _state(asset.id, scope, deleting ? 'deleting' : 'failed', error: '等待 NAS 会话恢复后同步');
  }

  Future<void> flushDeletes(NasSyncApi api) async {
    final scope = await _scope(api);
    final rows = await database.customSelect("SELECT asset_id FROM backend_media_state WHERE scope_id=? AND state='deleting'",
      variables: [Variable.withString(scope)]).get();
    for (final row in rows) {
      final id = row.read<String>('asset_id');
      await api.processingRequest('/media/$id/delete');
      api.assertCurrentSession();
      await _state(id, scope, 'deleted');
    }
  }

  Future<void> upload(NasSyncApi api, MediaAsset asset) async {
    final scope = await _scope(api);
    final state = await database.customSelect(
      'SELECT scope_id,state FROM backend_media_state WHERE asset_id=?',
      variables: [Variable.withString(asset.id)]).getSingleOrNull();
    if (state != null && state.read<String>('scope_id') != scope) {
      throw StateError('图片属于其他家庭，当前不支持改绑迁移。');
    }
    if (state?.read<String>('state') == 'deleted') return;
    if (state?.read<String>('state') == 'deleting') {
      await delete(api, asset);
      await repository.markDeleted(asset.id);
      await storage.deleteIfExists(asset.localPath);
      return;
    }
    final reassignment = await database.customSelect(
      'SELECT * FROM backend_media_reassign WHERE asset_id=?',
      variables: [Variable.withString(asset.id)]).getSingleOrNull();
    if (reassignment != null && reassignment.read<String>('scope_id') != scope) {
      throw StateError('图片关联属于其他家庭。');
    }
    if (const {'synced', 'ocr_processing', 'ocr_failed', 'ocr_complete', 'download_failed'}.contains(state?.read<String>('state'))) {
      if (reassignment != null) await _finishReassign(api, asset.id, reassignment.read<String>('product_id'));
      return;
    }
    await _state(asset.id, scope, 'uploading');
    try {
      final file = File(asset.localPath);
      if (!await file.exists()) throw StateError('图片文件已丢失，请重新拍摄。');
      if (await file.length() > 8 * 1024 * 1024) {
        throw StateError('图片超过 8 MiB，请选择较小的 JPEG 或 PNG 图片。');
      }
      final response = await api.processingRequest('/media/upload', body: {
        'id': asset.id, 'entity_type': reassignment == null ? asset.entityType : 'intake_draft',
        'entity_id': reassignment?.read<String>('from_entity_id') ?? asset.entityId, 'media_type': asset.type.storageValue,
        'content': base64Encode(await file.readAsBytes()),
        if (asset.hasOcrText) 'ocr_text': asset.ocrText,
      });
      api.assertCurrentSession();
      if (response['id'] != asset.id || response['deleted_at'] != null) {
        throw const FormatException('后端图片回执不匹配。');
      }
      await _state(asset.id, scope, 'synced');
    } catch (_) {
      // A lost response keeps the same UUID and bytes for safe retry.
      api.assertCurrentSession();
      await _state(asset.id, scope, 'failed', error: '上传未完成，请重试');
      rethrow;
    }
    if (reassignment != null) await _finishReassign(api, asset.id, reassignment.read<String>('product_id'));
  }

  Future<String> ocr(NasSyncApi api, MediaAsset asset) async {
    await upload(api, asset);
    final scope = await _scope(api);
    await _state(asset.id, scope, 'ocr_processing');
    late Map<String, dynamic> result;
    try {
      result = await api.processingRequest('/media/${asset.id}/ocr');
    } catch (_) {
      api.assertCurrentSession();
      await _state(asset.id, scope, 'ocr_failed', error: '后端 OCR 未完成，可重试');
      rethrow;
    }
    api.assertCurrentSession();
    if (result['id'] != asset.id || result['ocr_status'] != 'complete') {
      await _state(asset.id, scope, 'ocr_failed', error: '后端 OCR 失败，可重试或手动输入');
      throw StateError(result['ocr_status'] == 'processing'
          ? '后端正在识别，请稍后重试。' : '后端 OCR 失败，可重试或手动输入。');
    }
    await _state(asset.id, scope, 'ocr_complete');
    final text = result['ocr_text'] as String;
    await repository.updateOcr(asset.id, text);
    return text;
  }

  Future<void> delete(NasSyncApi api, MediaAsset asset) async {
    final scope = await _scope(api);
    await _state(asset.id, scope, 'deleting');
    // Always send the tombstone even after an unknown upload outcome.
    await api.processingRequest('/media/${asset.id}/delete');
    api.assertCurrentSession();
    await _state(asset.id, scope, 'deleted');
  }

  Future<void> _finishReassign(NasSyncApi api, String id, String productId) async {
    await api.processingRequest('/media/$id/reassign', body: {'product_id': productId});
    api.assertCurrentSession();
    await database.customStatement('DELETE FROM backend_media_reassign WHERE asset_id=?', [id]);
  }

  Future<void> reassignIntake(List<MediaAsset> assets, String productId) async {
    if (assets.isEmpty) return;
    NasSyncApi? selectedApi;
    Object? sessionError;
    try { selectedApi = await resolveApi(); } catch (error) { sessionError = error; }
    if (selectedApi == null && sessionError == null) {
      await repository.reassignEntity(fromEntityType: 'intake_draft', fromEntityId: assets.first.entityId,
        toEntityType: 'product', toEntityId: productId);
      return;
    }
    final api = selectedApi;
    final owner = await SyncWorkspaceRepository(database).readOwner();
    final scope = api == null ? owner?.familyId : await _scope(api);
    if (scope == null) throw StateError('缺少原家庭绑定，无法迁移图片关联。');
    await database.transaction(() async {
      api?.assertCurrentSession();
      for (final asset in assets) {
        await database.customStatement('''INSERT OR IGNORE INTO backend_media_reassign
          (asset_id,scope_id,from_entity_id,product_id) VALUES (?,?,?,?)''',
          [asset.id, scope, asset.entityId, productId]);
      }
      await repository.reassignEntity(fromEntityType: 'intake_draft', fromEntityId: assets.first.entityId,
        toEntityType: 'product', toEntityId: productId);
    });
    if (sessionError != null) throw StateError('图片已关联当前商品，后端待恢复登录后同步。');
    for (final asset in await repository.loadForEntity(entityType: 'product', entityId: productId)) {
      await upload(api!, asset);
    }
  }

  /// Pull all media for one entity, then download into the local display cache.
  /// Tombstones remove cached bytes; absence from a page never implies deletion.
  Future<void> refreshEntity(NasSyncApi api, String kind, String id) async {
    final scope = await _scope(api);
    var after = '';
    var hadFailures = false;
    for (var page = 0; page < 100; page++) {
      final response = await api.processingRequest('/media', method: 'GET',
        queryParameters: {'entity_type': kind, 'entity_id': id, 'after': after});
      final rows = (response['assets'] as List).cast<Map<String, dynamic>>();
      final locals = {for (final asset in (id.isEmpty ? await repository.loadAllActive() : await repository.loadForEntity(entityType: kind, entityId: id))) asset.id: asset};
      for (final row in rows) {
        api.assertCurrentSession();
        final assetId = row['id'] as String;
        if (assetId.compareTo(after) <= 0 || row['entity_type'] != kind || (id.isNotEmpty && row['entity_id'] != id)) {
          throw const FormatException('后端媒体分页无效。');
        }
        after = assetId;
        final local = locals[assetId];
        try {
        if (row['deleted_at'] != null) {
          if (local != null) {
            await repository.markDeleted(assetId);
            await storage.deleteIfExists(local.localPath);
          }
          await _state(assetId, scope, 'deleted');
          continue;
        }
        if (local == null || !await File(local.localPath).exists()) {
          final full = await api.processingRequest('/media/$assetId', method: 'GET');
          api.assertCurrentSession();
          if (full['deleted_at'] != null) continue;
          if (full['id'] != assetId || full['entity_type'] != kind || full['entity_id'] != row['entity_id']) {
            throw const FormatException('后端图片关联不匹配。');
          }
          final content = base64Decode(full['content'] as String);
          final stored = await storage.storeBackendImage(assetId, content);
          api.assertCurrentSession();
          if (local == null) {
            await repository.cacheRemote(id: assetId, entityType: kind, entityId: row['entity_id'] as String,
              type: MediaAssetType.fromStorageValue(full['media_type'] as String),
              localPath: stored.path, mimeType: stored.mimeType, sizeBytes: stored.sizeBytes,
              sha256: stored.sha256, createdAt: DateTime.parse(full['created_at'] as String));
          } else {
            await (database.update(database.mediaAssets)..where((m) => m.id.equals(assetId)))
              .write(MediaAssetsCompanion(localPath: Value(stored.path)));
          }
        }
        if (row['ocr_status'] == 'complete') {
          await repository.updateOcr(assetId, row['ocr_text'] as String);
        }
        await _state(assetId, scope, row['ocr_status'] == 'complete' ? 'ocr_complete' :
          row['ocr_status'] == 'processing' ? 'ocr_processing' :
          row['ocr_status'] == 'failed' ? 'ocr_failed' : 'synced');
        } catch (_) {
          api.assertCurrentSession();
          hadFailures = true;
          await _state(assetId, scope, 'download_failed', error: '图片尚未恢复，其余图片继续同步');
        }
      }
      if (rows.length < 50) {
        if (hadFailures) throw StateError('部分图片尚未恢复，请稍后重试。');
        return;
      }
    }
    throw StateError('图片较多，请再次刷新以继续。');
  }

  Future<void> refreshProducts(NasSyncApi api) async {
    try {
      await refreshEntity(api, 'product', '');
    } on NasApiError catch (error) {
      // Older NAS versions require an entity ID. Preserve their compatibility
      // while current servers use one family-wide metadata pagination stream.
      if (error.statusCode != 400 && error.statusCode != 404) rethrow;
      final products = await (database.select(database.products)..where((p) => p.deletedAt.isNull())).get();
      for (final product in products) { await refreshEntity(api, 'product', product.id); }
    }
  }

  Future<void> syncHistory(NasSyncApi api) async {
    final scope = await _scope(api);
    final key = 'sync_backend_history_cursor:$scope';
    final setting = await (database.select(database.appSettings)..where((v) => v.key.equals(key)))
        .getSingleOrNull();
    var after = int.tryParse(setting?.value ?? '') ?? 0;
    var until = 0;
    for (var page = 0; page < 100; page++) {
      final response = await api.processingRequest('/inventory/history', method: 'GET',
          queryParameters: {'after': '$after', 'until': '$until', 'limit': '100'});
      final records = (response['records'] as List).cast<Map<String, dynamic>>();
      final next = response['next_cursor'] as int;
      final high = response['until'] as int;
      final more = response['has_more'] as bool;
      if (high < after || (until != 0 && until != high) || next < after || next > high ||
          (more && (next == after || records.isEmpty))) {
        throw const FormatException('操作历史分页无效。');
      }
      until = high;
      var previous = after;
      final ids = <String>{};
      final operations = <String>{};
      for (final row in records) {
        final cursor = row['cursor'] as int;
        final id = row['id'];
        final quantity = row['quantity'] as int;
        if (id is! String || id.isEmpty || !ids.add(id) ||
            cursor <= previous || cursor > next || (quantity == 0 && row['type'] != 'discard') ||
            (const {'consume', 'discard'}.contains(row['type']) && quantity > 0) ||
            (row['type'] == 'restock' && quantity < 0) ||
            !const {'consume', 'restock', 'discard', 'adjust'}.contains(row['type'])) {
          throw const FormatException('操作历史记录无效。');
        }
        final operation = row['operation_id'];
        if (operation is String && operation.isNotEmpty && !operations.add('$operation:${row['batch_id']}')) {
          throw const FormatException('操作历史包含重复操作/批次。');
        }
        previous = cursor;
      }
      api.assertCurrentSession();
      await database.transaction(() async {
        await api.assertProcessingSession();
        for (final row in records) {
          final product = await (database.select(database.products)..where((p) =>
              p.id.equals(row['product_id'] as String))).getSingleOrNull();
          final batch = await (database.select(database.productBatches)..where((b) =>
              b.id.equals(row['batch_id'] as String))).getSingleOrNull();
          // Inventory sync must land first; retain the page cursor on failure.
          if (product == null || batch == null || batch.productId != product.id) {
            throw StateError('请先完成库存同步，再恢复操作历史。');
          }
          final operationId = row['operation_id'] as String?;
          var source = operationId == null || operationId.isEmpty ? null : await database.customSelect(
            'SELECT local_id FROM stock_movement_sources WHERE operation_id=? AND batch_id=?',
            variables: [Variable.withString(row['operation_id'] as String? ?? ''),
              Variable.withString(batch.id)]).getSingleOrNull();
          if (source == null && row['operation_id'] is String) {
            final oldOutbox = await (database.select(database.syncOutbox)..where((o) =>
                o.scopeId.equals(scope) & o.operationId.equals(row['operation_id'] as String))).get();
            if (oldOutbox.length == 1) {
              final request = jsonDecode(oldOutbox.single.requestJson) as Map;
              final instant = DateTime.tryParse(request['client_updated_at'] as String? ?? '');
              if (instant != null) {
                final matches = await (database.select(database.stockMovements)..where((m) =>
                  m.batchId.equals(batch.id) & m.quantity.equals(row['quantity'] as int) &
                  m.createdAt.equals(instant))).get();
                if (matches.length == 1) {
                  await database.customStatement(
                    'INSERT OR IGNORE INTO stock_movement_sources(operation_id,batch_id,local_id) VALUES (?,?,?)',
                    [row['operation_id'], batch.id, matches.single.id]);
                  source = await database.customSelect(
                    'SELECT local_id FROM stock_movement_sources WHERE operation_id=? AND batch_id=?',
                    variables: [Variable.withString(row['operation_id'] as String), Variable.withString(batch.id)]).getSingleOrNull();
                }
              }
            }
          }
          StockMovementRecord? original = await (database.select(database.stockMovements)..where((m) =>
            m.id.equals(row['id'] as String))).getSingleOrNull();
          if (source != null) {
            final sourceId = source.read<String>('local_id');
            original ??= await (database.select(database.stockMovements)..where((m) =>
              m.id.equals(sourceId))).getSingleOrNull();
            await (database.delete(database.stockMovements)..where((m) => m.id.equals(sourceId))).go();
          }
          await database.into(database.stockMovements).insertOnConflictUpdate(
            StockMovementsCompanion.insert(id: row['id'] as String,
              productId: product.id, batchId: Value(batch.id),
              type: original?.type ?? (row['type'] == 'restock' || row['type'] == 'adjust' ? 'adjustment' : row['type'] as String),
              quantity: row['quantity'] as int, note: Value(original?.note ?? switch (row['type']) {
                'consume' => '消耗', 'restock' => '补充库存', 'discard' => '批次报废', _ => '库存调整',
              }),
              createdAt: DateTime.parse(row['created_at'] as String)));
          if (operationId != null && operationId.isNotEmpty) {
            await database.customStatement('''INSERT INTO stock_movement_sources(operation_id,batch_id,local_id) VALUES (?,?,?)
              ON CONFLICT(operation_id,batch_id) DO UPDATE SET local_id=excluded.local_id''',
              [operationId, batch.id, row['id']]);
          }
        }
        await api.assertProcessingSession();
        await database.into(database.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: key, value: '$next', updatedAt: DateTime.now()));
      });
      after = next;
      if (!more) return;
    }
    throw StateError('历史较多，稍后同步将继续恢复。');
  }
}
