import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/database/app_database.dart';
import '../data/nas/nas_api_error.dart';
import '../data/nas/nas_sync_api.dart';
import '../data/repositories/initial_import_repository.dart';
import '../data/repositories/calendar_date_repository.dart';
import '../data/repositories/sync_category_repository.dart';
import '../data/repositories/sync_outbox_repository.dart';
import '../data/repositories/sync_workspace_repository.dart';
import '../domain/inventory/calendar_date.dart';
import '../domain/models/initial_import_models.dart';
import '../domain/models/nas_import_models.dart';
import 'sync_engine.dart';
import 'sync_execution_coordinator.dart';

/// Explicit, bounded import of current stock and a separate history archive.
/// Construction, login and ordinary sync never call prepare or execute.
class InitialImportService {
  InitialImportService({required AppDatabase database, required NasSyncApi api,
    required SyncEngine engine, required SyncWorkspaceIdentity identity,
    required String deviceId, required String localWorkspaceId, Uuid? uuid})
      : _database = database, _api = api, _engine = engine, _identity = identity,
        _deviceId = deviceId, _workspaceId = localWorkspaceId,
        _repository = InitialImportRepository(database),
        _outbox = SyncOutboxRepository(database),
        _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final NasSyncApi _api;
  final SyncEngine _engine;
  final SyncWorkspaceIdentity _identity;
  final String _deviceId;
  final String _workspaceId;
  final InitialImportRepository _repository;
  final SyncOutboxRepository _outbox;
  final Uuid _uuid;
  bool _closed = false;
  int _revision = 0;

  bool get isCurrent {
    if (_closed) return false;
    try {
      _api.assertCurrentSession();
      return true;
    } on NasApiError {
      return false;
    }
  }

  void close() { _closed = true; _revision++; }

  Stream<InitialImportProgress?> watchProgress() =>
      _repository.watchProgress(_identity.familyId);

  Future<InitialImportPreview?> readPreparedPreview() async =>
      (await _repository.load(_identity.familyId))?.preview;

  Future<void> _assertCurrent([int? revision]) async {
    if (_closed || (revision != null && revision != _revision)) {
      throw StateError('导入已暂停或会话已改变；原计划和回执已保留。');
    }
    _api.assertCurrentSession();
    final owner = await SyncWorkspaceRepository(_database).readOwner();
    _api.assertCurrentSession();
    if (owner == null || !owner.matches(_identity)) {
      throw StateError('本机归属与当前 NAS、账号或家庭不一致，已保留导入计划。');
    }
    if (await _outbox.getConfirmedBootstrapMode(_identity.familyId) == 'keep_local_only') {
      throw StateError('当前选择仅保留本地，导入已暂停。');
    }
    if (_closed || (revision != null && revision != _revision)) {
      throw StateError('导入已暂停；原计划和回执已保留。');
    }
    _api.assertCurrentSession();
  }

  Future<T> _coordinated<T>(Future<T> Function() action) =>
      SyncExecutionCoordinator.run(_database, _identity.familyId, action);

  Future<InitialImportPreview> preview() => _coordinated(() async {
    await _assertCurrent();
    final active = await _repository.load(_identity.familyId);
    if (active?.progress.isActive == true) {
      throw StateError('已有冻结导入计划。请先审阅原计划并继续，不能用新计划替换未知回执。');
    }
    final capability = await _api.importCapabilities(deviceId: _deviceId);
    CalendarDate.validateTimeZone(capability.familyTimeZone);
    final source = await _readSource();
    final blockers = <String>[];
    final exclusions = <String>[
      '图片、说明书和 OCR 仅保留本机。',
      '提醒已处理记录、账号凭据、NAS/HA 绑定与运行现场不导入。',
    ];
    if (await _outbox.hasSnapshotBlockingChanges(scopeId: _identity.familyId)) {
      blockers.add('存在待发、在途、被拒绝、阻塞或未解决冲突，请先结算原操作。');
    }
    final mode = await _outbox.getConfirmedBootstrapMode(_identity.familyId);
    if (mode != 'join_and_merge' && mode != 'create_new_family') {
      blockers.add('请先明确确认首次连接的远端同步模式。');
    }
    final categoryRepository = SyncCategoryRepository(_database);
    final remoteCategories = await categoryRepository.remoteCategories(_identity.familyId);
    final names = source.products.where((row) => row.deletedAt == null && row.serverVersion == 0)
      .map((row) => row.category).toSet().toList()..sort();
    final categories = <InitialImportCategory>[];
    for (final name in names) {
      final related = names.where((other) => other.trim().toLowerCase() == name.trim().toLowerCase());
      final candidates = remoteCategories.where((row) =>
        (row['name'] as String?)?.trim().toLowerCase() == name.trim().toLowerCase()).toList();
      final bound = await categoryRepository.readId(_identity.familyId, name);
      final exact = candidates.where((row) => row['name'] == name).toList();
      final ambiguous = name.trim() != name || name.isEmpty || related.length > 1 ||
          candidates.length > 1 || (candidates.isNotEmpty && exact.length != 1) ||
          (bound != null && exact.isNotEmpty && exact.single['id'] != bound);
      final category = InitialImportCategory(sourceName: name,
        categoryId: bound ?? (exact.length == 1 ? exact.single['id'] as String : _uuid.v4()),
        action: ambiguous ? InitialImportCategoryAction.blocked :
          exact.length == 1 ? InitialImportCategoryAction.reuse : InitialImportCategoryAction.create,
        reason: ambiguous ? '分类名称空白、大小写或已有身份存在歧义，请先核对。' :
          exact.length == 1 ? '复用已读取的同名分类；服务端仍将复检。' :
            '新分类身份已固定；服务端预检会检查远端重叠。');
      categories.add(category);
      if (ambiguous) blockers.add('分类「$name」存在歧义。');
    }
    final categoryIds = {for (final category in categories) category.sourceName: category.categoryId};
    final products = <Map<String, dynamic>>[];
    final batches = <Map<String, dynamic>>[];
    final shopping = <Map<String, dynamic>>[];
    final history = <Map<String, dynamic>>[];
    var deleted = 0;
    var alreadyRemote = 0;
    for (final product in source.products) {
      if (product.deletedAt != null) { deleted++; continue; }
      if (product.serverVersion != 0) { alreadyRemote++; continue; }
      products.add({'id': product.id, 'name': product.name, 'category_id': categoryIds[product.category],
        'barcode': product.barcode, 'brand': product.brand, 'specification': product.specification,
        'location': product.location, 'unit': product.unit,
        'low_stock_threshold': product.lowStockThreshold,
        'created_at': product.createdAt.toUtc().toIso8601String(),
        'updated_at': product.updatedAt.toUtc().toIso8601String()});
    }
    final productIds = source.products.where((row) => row.deletedAt == null).map((row) => row.id).toSet();
    for (final batch in source.batches) {
      if (batch.deletedAt != null) { deleted++; continue; }
      if (!productIds.contains(batch.productId)) blockers.add('批次 ${batch.id} 缺少可导入商品。');
      if (batch.serverVersion != 0) { alreadyRemote++; continue; }
      if (batch.initialQuantity < 0 || batch.initialQuantity > 2147483647 ||
          batch.remainingQuantity < 0 || batch.remainingQuantity > batch.initialQuantity ||
          (batch.isDiscarded && batch.remainingQuantity != 0)) {
        blockers.add('批次 ${batch.id} 的累计数量、余量或报废状态不合法。');
      }
      final calendar = await CalendarDateRepository(_database).read(batch.id);
      final productionDate = calendar['produced_date'] == null ? batch.productionDate :
        CalendarDate.decode(calendar['produced_date']!);
      final expiryDate = calendar['expiry_date'] == null ? batch.expiryDate :
        CalendarDate.decode(calendar['expiry_date']!);
      for (final date in [productionDate, expiryDate].whereType<DateTime>()) {
        if (date.hour != 0 || date.minute != 0 || date.second != 0 ||
            date.millisecond != 0 || date.microsecond != 0) {
          blockers.add('批次 ${batch.id} 日期来源可能受旧时区转换影响，请先人工核对日期。');
        }
      }
      final dateSource = switch (batch.dateSource) { 'ai' => 'ai_draft',
        'calculated' => 'manual', _ => batch.dateSource };
      if (dateSource != batch.dateSource) exclusions.add('批次 ${batch.id} 日期来源 ${batch.dateSource} 按 $dateSource 传输；原说明留本机。');
      batches.add({'id': batch.id, 'product_id': batch.productId, 'batch_no': batch.batchNo,
        'produced_date': productionDate == null ? null : CalendarDate.encode(productionDate),
        'expiry_date': expiryDate == null ? null : CalendarDate.encode(expiryDate),
        'date_source': dateSource, 'date_precision': batch.datePrecision,
        'initial_quantity': batch.initialQuantity, 'quantity': batch.remainingQuantity,
        'is_opened': batch.isOpened,
        'status': batch.isDiscarded ? 'discarded' : batch.remainingQuantity == 0 ? 'used_up' : 'active',
        'created_at': batch.createdAt.toUtc().toIso8601String(),
        'updated_at': batch.updatedAt.toUtc().toIso8601String()});
    }
    for (final item in source.shopping) {
      if (item.deletedAt != null) { deleted++; continue; }
      if (item.serverVersion != 0) { alreadyRemote++; continue; }
      if (item.productId != null && !productIds.contains(item.productId)) {
        blockers.add('采购 ${item.itemName} 关联商品未包含在当前计划。');
      }
      shopping.add({'id': item.id, 'product_id': item.productId, 'name': item.itemName,
        'category': item.category, 'reason': item.reason, 'desired_quantity': item.targetQuantity,
        'checked': item.isCompleted, 'created_at': item.createdAt.toUtc().toIso8601String(),
        'updated_at': item.updatedAt.toUtc().toIso8601String()});
    }
    for (final movement in source.movements) {
      if (!const ['intake', 'restock', 'consume', 'discard', 'adjust'].contains(movement.type) ||
          movement.quantity == 0 ||
          (const ['intake', 'restock'].contains(movement.type) && movement.quantity < 0) ||
          (const ['consume', 'discard'].contains(movement.type) && movement.quantity > 0)) {
        blockers.add('历史 ${movement.id} 类型或数量符号不支持，请保留原记录核对。');
      }
      history.add({'id': movement.id, 'product_id': movement.productId,
        'batch_id': movement.batchId, 'type': movement.type, 'quantity': movement.quantity,
        'note': movement.note, 'occurred_at': movement.createdAt.toUtc().toIso8601String(),
        'source_time_zone': null});
    }
    if (deleted > 0) exclusions.add('$deleted 条软删除资料只保留本机，不复活或传播历史删除。');
    if (alreadyRemote > 0) exclusions.add('$alreadyRemote 条已有远端版本的商品、批次或采购不重新初始化；以当前 NAS 为准。');
    if (source.policies.isNotEmpty) {
      exclusions.add('${source.policies.length} 条已有远端提醒策略沿用服务端，不重新初始化。');
    }
    final manifest = <String, dynamic>{'format_version': 1, 'device_id': _deviceId,
      'import_id': _uuid.v4(), 'local_workspace_id': _workspaceId, 'unsettled_outbox_count': 0,
      'categories': categories.map((category) => {'id': category.categoryId,
        'name': category.sourceName, 'reuse_existing': category.action == InitialImportCategoryAction.reuse})
        .toList(growable: false),
      'products': products, 'product_batches': batches, 'shopping_items': shopping,
      'reminder_settings': <Map<String, dynamic>>[], 'history': history};
    final counts = {for (final entity in initialImportEntities) entity: (manifest[entity] as List).length};
    final total = counts.values.fold(0, (sum, value) => sum + value);
    if (total > capability.maxRecords || source.truncated) blockers.add('数据超过本次原子导入的 ${capability.maxRecords} 条限制；未上传业务数据。');
    if (utf8.encode(jsonEncode(manifest)).length > capability.maxRequestBytes) {
      blockers.add('导入请求超过 ${capability.maxRequestBytes} 字节限制；未上传业务数据。');
    }
    await _assertCurrent();
    return InitialImportPreview(importId: manifest['import_id'] as String, target: _identity,
      localWorkspaceId: _workspaceId, counts: Map.unmodifiable(counts),
      blockers: List.unmodifiable(blockers), exclusions: List.unmodifiable(exclusions),
      categories: List.unmodifiable(categories), fingerprint: source.digest,
      familyTimeZone: capability.familyTimeZone, manifest: manifest);
  });

  /// Explicit permission to upload the reviewed manifest for server preflight.
  /// This still never initializes inventory; execute requires a second action.
  Future<InitialImportProgress> prepare(InitialImportPreview preview) => _coordinated(() async {
    await _assertCurrent();
    if (!preview.canPrepare || !preview.target.matches(_identity) ||
        preview.localWorkspaceId != _workspaceId || preview.fingerprint != (await _readSource()).digest) {
      throw StateError('预检已过期、存在阻塞或目标身份已改变，请重新审阅。');
    }
    if (await _outbox.hasSnapshotBlockingChanges(scopeId: _identity.familyId)) {
      throw StateError('本地出现未结算操作，未发送导入计划。');
    }
    await _database.transaction(() async {
      await _assertCurrent();
      if (preview.fingerprint != (await _readSource()).digest ||
          await _outbox.hasSnapshotBlockingChanges(scopeId: _identity.familyId)) {
        throw StateError('确认期间本机数据已改变，请重新预检。');
      }
      await _repository.savePrepared(preview);
      await _assertCurrent();
    });
    return _preflightStored();
  });

  Future<InitialImportProgress> _preflightStored() async {
    final stored = (await _repository.load(_identity.familyId))!;
    final revision = _revision;
    try {
      await _assertCurrent(revision);
      final manifest = {...stored.preview.manifest, 'device_id': _deviceId};
      final receipt = await _api.preflightImport(manifest);
      await _assertCurrent(revision);
      _validateReceipt(stored.preview, receipt, expected: stored.receipt);
      if (receipt.isCompleted) {
        await _persistCompletedReceipt(stored, receipt, revision);
      } else {
        await _database.transaction(() async {
          await _assertCurrent(revision);
          await _repository.update(_identity.familyId, stored.preview.importId,
            status: receipt.status == 'blocked' ? InitialImportStatus.blocked : InitialImportStatus.prepared,
            receipt: receipt, message: receipt.blockers.map((b) => '${b.code}: ${b.message}').join('\n'));
          await _assertCurrent(revision);
        });
      }
    } catch (error) {
      await _recordPaused(stored.preview.importId, error);
      rethrow;
    }
    return (await _repository.load(_identity.familyId))!.progress;
  }

  Future<InitialImportProgress> execute() => resume();

  /// Continue the same durable import ID. A missing receipt triggers only the
  /// same preflight, never a replacement plan or ordinary stock command.
  Future<InitialImportProgress> resume() async {
    await _coordinated(() async {
      final stored = await _repository.load(_identity.familyId);
      if (stored == null) throw StateError('没有可恢复的导入计划。');
      if (!stored.progress.isActive) return;
      final revision = _revision;
      try {
        await _assertCurrent(revision);
        NasImportReceipt receipt;
        try {
          receipt = await _api.getImport(importId: stored.preview.importId, deviceId: _deviceId);
        } on NasApiError catch (error) {
          if (error.statusCode != 404) rethrow;
          if (stored.preview.fingerprint != (await _readSource()).digest) {
            throw StateError('原计划未找到且本机资料已改变，请保留现场核对，不能换 ID 重传。');
          }
          receipt = await _api.preflightImport({...stored.preview.manifest, 'device_id': _deviceId});
        }
        await _assertCurrent(revision);
        _validateReceipt(stored.preview, receipt, expected: stored.receipt);
        if (!receipt.isCompleted) {
          if (stored.preview.fingerprint != (await _readSource()).digest ||
              await _outbox.hasSnapshotBlockingChanges(scopeId: _identity.familyId)) {
            throw StateError('冻结计划后本机资料或队列发生变化，未发送初始化请求；请保留现场核对。');
          }
          if (receipt.status == 'blocked') {
            receipt = await _api.preflightImport({...stored.preview.manifest, 'device_id': _deviceId});
            _validateReceipt(stored.preview, receipt, expected: stored.receipt);
          }
          if (receipt.status != 'prepared' || receipt.checkpoint == null) {
            await _repository.update(_identity.familyId, stored.preview.importId,
              status: InitialImportStatus.blocked, receipt: receipt,
              message: receipt.blockers.map((b) => b.message).join('\n'));
            return;
          }
          await _repository.update(_identity.familyId, stored.preview.importId,
            status: InitialImportStatus.sending, receipt: receipt, confirmStarted: true);
          await _assertCurrent(revision);
          final preparedReceipt = receipt;
          receipt = await _api.confirmImport(importId: stored.preview.importId,
            deviceId: _deviceId, checkpoint: receipt.checkpoint!, fingerprint: receipt.fingerprint);
          await _assertCurrent(revision);
          _validateReceipt(stored.preview, receipt, expected: preparedReceipt);
          if (!receipt.isCompleted) throw const FormatException('NAS 未返回完整导入回执。');
        }
        await _persistCompletedReceipt(stored, receipt, revision);
      } catch (error) {
        await _recordPaused(stored.preview.importId, error);
        rethrow;
      }
    });
    final stored = (await _repository.load(_identity.familyId))!;
    if (stored.status == InitialImportStatus.awaitingSnapshot) await _recover(stored);
    return (await _repository.load(_identity.familyId))!.progress;
  }

  Future<void> _persistCompletedReceipt(StoredInitialImport stored,
    NasImportReceipt receipt, int revision) => _database.transaction(() async {
    await _assertCurrent(revision);
    final categories = SyncCategoryRepository(_database);
    for (final category in stored.preview.categories) {
      await categories.save(_identity.familyId, category);
    }
    await _database.into(_database.appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(key: 'sync_family_time_zone:${_identity.familyId}',
        value: stored.preview.familyTimeZone, updatedAt: DateTime.now().toUtc()));
    await _database.into(_database.appSettings).insertOnConflictUpdate(
      AppSettingsCompanion.insert(key: 'sync_import_format:${_identity.familyId}',
        value: '1', updatedAt: DateTime.now().toUtc()));
    final pending = await _outbox.getPendingBootstrap(_identity.familyId);
    if (pending != null) {
      // Release the ordinary queue only together with invalidating any snapshot
      // fetched before the import changed the server's stock baseline.
      await _outbox.savePendingBootstrap(scopeId: _identity.familyId,
        snapshot: Map<String, dynamic>.from(pending['snapshot'] as Map),
        serverCursor: pending['server_cursor'] as int,
        checkpoint: pending['checkpoint'] as String?,
        bootstrapState: pending['bootstrap_state'] as String?,
        mode: pending['mode'] as String?, refreshRequired: true);
    }
    await _repository.update(_identity.familyId, stored.preview.importId,
      status: InitialImportStatus.awaitingSnapshot, receipt: receipt,
      message: 'NAS 已接受库存基线；等待权威快照和独立历史归档恢复。');
    await _assertCurrent(revision);
  });

  Future<void> _recover(StoredInitialImport stored) async {
    final revision = _revision;
    try {
      // History is independent: no history row is ever an inventory command.
      await _coordinated(() async {
        var after = stored.historyCursor;
        var until = stored.historyUntil;
        for (var pages = 0; pages < 20; pages++) {
          await _assertCurrent(revision);
          final page = await _api.importHistory(deviceId: _deviceId, after: after, until: until);
          await _assertCurrent(revision);
          if ((until != 0 && page.until != until) || page.nextCursor < after ||
              (page.hasMore && page.nextCursor <= after) ||
              page.until < (stored.receipt?.historyCursor ?? 0)) {
            throw const FormatException('历史分页未保持固定高水位或未推进。');
          }
          var previous = after;
          for (final record in page.records) {
            final cursor = record['cursor'];
            if (cursor is! int || cursor <= previous || cursor > page.until) {
              throw const FormatException('历史页重复、乱序或越过高水位。');
            }
            previous = cursor;
          }
          if ((page.hasMore && (page.records.isEmpty || previous != page.nextCursor)) ||
              (!page.hasMore && page.nextCursor != page.until)) {
            throw const FormatException('历史页回执与条目游标不一致。');
          }
          await _database.transaction(() async {
            await _assertCurrent(revision);
            await _repository.saveHistoryPage(_identity.familyId, page);
            await _repository.update(_identity.familyId, stored.preview.importId,
              status: InitialImportStatus.awaitingSnapshot,
              historyCursor: page.nextCursor, historyUntil: page.until);
            await _assertCurrent(revision);
          });
          after = page.nextCursor;
          until = page.until;
          if (!page.hasMore) return;
        }
        throw StateError('本次历史分页预算已用完，原游标已保存，请继续恢复。');
      });
      await _assertCurrent(revision);
      await _engine.completeInitialImport(onApplied: () async {
        await _assertCurrent(revision);
        final latest = (await _repository.load(_identity.familyId))!;
        if (latest.historyCursor < latest.historyUntil || latest.receipt?.isCompleted != true) {
          throw StateError('历史尚未恢复完整，不能显示导入完成。');
        }
        await _repository.update(_identity.familyId, stored.preview.importId,
          status: InitialImportStatus.completed, snapshotApplied: true,
          message: '当前库存与独立历史归档已恢复；明确排除的本机资料未迁移。');
        await _assertCurrent(revision);
      });
    } catch (error) {
      await _recordPaused(stored.preview.importId, error);
      rethrow;
    }
  }

  Future<void> pause() async {
    _revision++;
    final stored = await _repository.load(_identity.familyId);
    if (stored == null || !stored.progress.isActive) return;
    await _repository.update(_identity.familyId, stored.preview.importId,
      status: InitialImportStatus.paused,
      message: '已暂停后续处理。在途请求可能已被原 NAS 接受；继续时核对同一导入回执。');
  }

  /// Only plans that have never started a confirm request can be ended.
  /// A delayed or unknown confirm is never inferred safe from a GET response.
  Future<void> abandonPrepared() => _coordinated(() => _database.transaction(() async {
    await _assertCurrent();
    final stored = await _repository.load(_identity.familyId);
    if (stored == null || !stored.progress.canAbandon) {
      throw StateError('此计划曾发送确认或已完成，不能结束。请用原 ID 核对回执并恢复。');
    }
    await _repository.update(_identity.familyId, stored.preview.importId,
      status: InitialImportStatus.abandoned,
      message: '未发送库存确认的计划已结束。原冻结资料保留供核对，未删除本机业务数据。');
    await _assertCurrent();
  }));

  Future<NasImportHistoryPage> history({int after = 0, int until = 0, int limit = 100}) async {
    await _assertCurrent();
    return _api.importHistory(deviceId: _deviceId, after: after, until: until, limit: limit);
  }

  Future<void> _recordPaused(String importId, Object error) async {
    // Metadata belongs to the original immutable scope even after logout.
    final stored = await _repository.load(_identity.familyId);
    if (stored?.preview.importId != importId || stored?.status == InitialImportStatus.completed) return;
    await _repository.update(_identity.familyId, importId, status: InitialImportStatus.paused,
      message: '$error');
  }

  void _validateReceipt(InitialImportPreview preview, NasImportReceipt receipt,
    {NasImportReceipt? expected}) {
    if (receipt.importId != preview.importId ||
        (receipt.familyTimeZone != null && receipt.familyTimeZone != preview.familyTimeZone) ||
        receipt.counts.length != preview.counts.length ||
        preview.counts.entries.any((entry) => receipt.counts[entry.key] != entry.value) ||
        (expected != null && expected.fingerprint.isNotEmpty &&
          receipt.fingerprint != expected.fingerprint)) {
      throw const FormatException('导入回执与冻结计划不一致，已保留现场。');
    }
  }

  Future<_ImportSource> _readSource() => _database.transaction(() async {
    final products = await (_database.select(_database.products)
      ..orderBy([(row) => OrderingTerm.asc(row.id)])..limit(1001)).get();
    final batches = await (_database.select(_database.productBatches)
      ..orderBy([(row) => OrderingTerm.asc(row.id)])..limit(1001)).get();
    final shopping = await (_database.select(_database.shoppingEntries)
      ..orderBy([(row) => OrderingTerm.asc(row.id)])..limit(1001)).get();
    final movements = await (_database.select(_database.stockMovements)
      ..orderBy([(row) => OrderingTerm.asc(row.id)])..limit(1001)).get();
    final policies = await (_database.select(_database.appSettings)
      ..where((row) => row.key.like('reminder_sync_policy:${_identity.familyId}:%'))
      ..orderBy([(row) => OrderingTerm.asc(row.key)])..limit(1001)).get();
    final calendars = await _database.customSelect('''
      SELECT id,production_date_calendar,expiry_date_calendar FROM product_batches ORDER BY id LIMIT 1001
    ''').get();
    return _ImportSource(products, batches, shopping, movements, policies,
      calendars.map((row) => row.data).toList(growable: false));
  });
}

class _ImportSource {
  _ImportSource(this.products, this.batches, this.shopping, this.movements, this.policies, this.calendars);
  final List<ProductRecord> products;
  final List<BatchRecord> batches;
  final List<ShoppingEntryRecord> shopping;
  final List<StockMovementRecord> movements;
  final List<AppSettingRecord> policies;
  final List<Map<String, dynamic>> calendars;
  bool get truncated => [products.length, batches.length, shopping.length,
    movements.length, policies.length].any((count) => count > 1000);
  String get digest => sha256.convert(utf8.encode(jsonEncode({
    'products': products.map((row) => row.toJson()).toList(growable: false),
    'batches': batches.map((row) => row.toJson()).toList(growable: false),
    'shopping': shopping.map((row) => row.toJson()).toList(growable: false),
    'movements': movements.map((row) => row.toJson()).toList(growable: false),
    'policies': policies.map((row) => row.toJson()).toList(growable: false),
    'calendars': calendars,
  }))).toString();
}
