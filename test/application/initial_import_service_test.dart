import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/initial_import_service.dart';
import 'package:momo_box/application/sync_engine.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';
import 'package:momo_box/data/repositories/calendar_date_repository.dart';
import 'package:momo_box/data/repositories/initial_import_repository.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/data/repositories/sync_workspace_repository.dart';
import 'package:momo_box/domain/models/initial_import_models.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/domain/models/nas_import_models.dart';
import 'package:momo_box/domain/models/nas_sync_models.dart';
import 'package:momo_box/domain/models/sync_models.dart';

const _identity = SyncWorkspaceIdentity(endpoint: 'https://nas.example/api/v1/',
  userId: 'user-a', familyId: 'family-a');

class _ImportApi extends NasSyncApi {
  _ImportApi() : super('https://nas.example', accessToken: 'test-token');
  final preflights = <Map<String, dynamic>>[];
  final confirms = <String>[];
  NasImportReceipt? receipt;
  bool loseConfirmResponse = false;
  bool badFingerprint = false;
  bool current = true;
  Completer<void>? confirmEntered;
  Completer<void>? confirmRelease;
  int historyReads = 0;
  NasImportHistoryPage? historyOverride;

  @override
  void assertCurrentSession() {
    if (!current) throw NasApiError(kind: NasApiErrorKind.unauthorized, message: 'changed');
    super.assertCurrentSession();
  }

  @override
  Future<NasImportCapabilities> importCapabilities({required String deviceId}) async =>
    const NasImportCapabilities(maxRecords: 1000, maxRequestBytes: 1048576,
      familyTimeZone: 'Asia/Shanghai');

  @override
  Future<NasImportReceipt> preflightImport(Map<String, dynamic> manifest) async {
    preflights.add(Map<String, dynamic>.from(jsonDecode(jsonEncode(manifest)) as Map));
    receipt = NasImportReceipt(importId: manifest['import_id'] as String,
      status: 'prepared', fingerprint: 'server-digest', checkpoint: 'import-cp',
      counts: {for (final entity in initialImportEntities) entity: (manifest[entity] as List).length},
      blockers: const [], familyTimeZone: 'Asia/Shanghai', serverCursor: 0, historyCursor: 0);
    return receipt!;
  }

  @override
  Future<NasImportReceipt> getImport({required String importId, required String deviceId}) async {
    if (receipt == null) throw NasApiError(kind: NasApiErrorKind.notFound, message: 'not found', statusCode: 404);
    if (badFingerprint) {
      return NasImportReceipt(importId: importId, status: receipt!.status,
        fingerprint: 'different-digest', checkpoint: receipt!.checkpoint,
        counts: receipt!.counts, blockers: const []);
    }
    return receipt!;
  }

  @override
  Future<NasImportReceipt> confirmImport({required String importId, required String deviceId,
    required String checkpoint, required String fingerprint}) async {
    expect(checkpoint, 'import-cp');
    expect(fingerprint, 'server-digest');
    confirms.add(importId);
    confirmEntered?.complete();
    if (confirmRelease != null) await confirmRelease!.future;
    receipt = NasImportReceipt(importId: importId, status: 'completed',
      fingerprint: fingerprint, checkpoint: checkpoint, counts: receipt!.counts,
      blockers: const [], familyTimeZone: 'Asia/Shanghai', serverCursor: 10,
      historyCursor: (preflights.last['history'] as List).length);
    if (loseConfirmResponse) {
      loseConfirmResponse = false;
      throw NasApiError(kind: NasApiErrorKind.network, message: 'response lost');
    }
    return receipt!;
  }

  @override
  Future<NasImportHistoryPage> importHistory({required String deviceId, int after = 0,
    int until = 0, int limit = 100}) async {
    historyReads++;
    if (historyOverride != null) return historyOverride!;
    final rows = preflights.last['history'] as List;
    final high = until == 0 ? rows.length : until;
    return NasImportHistoryPage(records: [
      for (var i = after; i < high; i++)
        {...Map<String, dynamic>.from(rows[i] as Map), 'cursor': i + 1,
          'import_id': receipt!.importId, 'local_workspace_id': 'workspace-a',
          'received_at': '2026-10-22T00:00:00Z'}
    ], nextCursor: high, until: high, hasMore: false);
  }

  @override
  Future<NasSyncVersions> capabilities() async =>
    const NasSyncVersions(schemaVersion: 1, syncProtocolVersion: 1);

  @override
  Future<NasSyncBootstrap> bootstrap({required String deviceId}) async => NasSyncBootstrap(
    schemaVersion: 1, syncProtocolVersion: 1, serverCursor: 10, mergeRequired: true,
    availableModes: const ['join_and_merge', 'create_new_family', 'keep_local_only'],
    checkpoint: 'snapshot-cp', snapshot: {
      for (final entity in initialImportEntities.where((entity) => entity != 'history'))
        entity: [for (final raw in preflights.last[entity] as List)
          {...Map<String, dynamic>.from(raw as Map), 'version': 1,
            'updated_at': '2026-10-22T00:00:00Z'}]
    });

  @override
  Future<NasSyncConfirmResult> confirmBootstrap({required String mode,
    required String deviceId, String? localWorkspaceId, int? snapshotCursor, String? checkpoint}) async =>
    NasSyncConfirmResult(accepted: true, serverCursor: 10, checkpoint: checkpoint,
      nextAction: mode == 'join_and_merge' ? 'pull_snapshot' : 'push_local_changes');

  @override
  Future<NasSyncPullResponse> pull({required String deviceId, required int cursor,
    int limit = 100}) async => NasSyncPullResponse(changes: const [], nextCursor: cursor, hasMore: false);

  @override
  Future<NasSyncPushResponse> push({required String deviceId, required int baseCursor,
    required List<NasSyncChange> changes}) async {
    final accepted = [
      for (final change in changes) NasSyncAcceptedChange(changeId: change.changeId,
        serverCursor: 10, serverVersion: 1)
    ];
    return NasSyncPushResponse(accepted: accepted,
      replayed: const [], conflicts: const [], rejected: const [], results: [
        for (final entry in accepted) NasSyncPushResult(changeId: entry.changeId,
          status: 'accepted', accepted: entry)
      ], cursor: 10);
  }
}

void main() {
  late AppDatabase database;
  late InventoryRepository inventory;
  late SyncOutboxRepository outbox;
  late _ImportApi api;
  late SyncEngine engine;
  late InitialImportService service;

  InitialImportService createService() => InitialImportService(database: database, api: api,
    engine: engine, identity: _identity, deviceId: 'device-a', localWorkspaceId: 'workspace-a');

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    inventory = InventoryRepository(database);
    final id = await inventory.createProductWithBatch(const IntakeDraft(name: '米', category: '食品',
      quantity: 12, expiryDate: null));
    await inventory.consumeByFefo(id, 7);
    await SyncWorkspaceRepository(database).bind(_identity, isCurrent: () => true);
    outbox = SyncOutboxRepository(database);
    await outbox.ensureState(scopeId: 'family-a');
    await outbox.savePendingBootstrap(scopeId: 'family-a', snapshot: {}, serverCursor: 0,
      checkpoint: 'old-cp', mode: 'join_and_merge');
    final state = (await outbox.getState('family-a'))!;
    await outbox.saveState(state.copyWith(bootstrapStatus: SyncBootstrapStatus.ready));
    api = _ImportApi();
    engine = SyncEngine.withBusinessAdapter(api: api, repository: outbox,
      inventoryRepository: inventory, shoppingRepository: ShoppingRepository(database),
      scopeId: 'family-a', deviceId: 'device-a', localWorkspaceId: 'workspace-a');
    service = createService();
  });

  tearDown(() async { service.close(); api.close(); await database.close(); });

  test('preview is read-only; explicit import preserves 12/5 and archives without replay', () async {
    final preview = await service.preview();
    expect(preview.blockers, isEmpty);
    expect(api.preflights, isEmpty);
    expect(api.confirms, isEmpty);
    expect((preview.manifest['product_batches'] as List).single['initial_quantity'], 12);
    expect((preview.manifest['product_batches'] as List).single['quantity'], 5);
    final prepared = await service.prepare(preview);
    expect(prepared.status, InitialImportStatus.prepared);
    expect(api.confirms, isEmpty);
    expect((await service.readPreparedPreview())!.importId, preview.importId);
    final result = await service.execute();
    expect(result.status, InitialImportStatus.completed);
    final batch = await database.select(database.productBatches).getSingle();
    expect(batch.initialQuantity, 12);
    expect(batch.remainingQuantity, 5);
    expect(await database.select(database.stockMovements).get(), hasLength(2));
    final archives = await InitialImportRepository(database).history('family-a');
    expect(archives.map((row) => row['quantity']).toSet(), {12, -7});
    expect(api.confirms, [preview.importId]);
  });

  test('local replenish history exports adjustment as the import adjust enum', () async {
    final batch = await database.select(database.productBatches).getSingle();
    await inventory.replenishBatch(batch.id, 2);
    final preview = await service.preview();
    expect(preview.blockers, isEmpty);
    final history = preview.manifest['history'] as List;
    expect(history.where((raw) => (raw as Map)['type'] == 'adjust').single['quantity'], 2);
    expect((await database.select(database.stockMovements).get()).where((row) => row.type == 'adjustment'), hasLength(1));
  });

  test('accepted response lost then restart uses original receipt and never initializes twice', () async {
    final preview = await service.preview();
    await service.prepare(preview);
    api.loseConfirmResponse = true;
    await expectLater(service.execute(), throwsA(isA<NasApiError>()));
    final paused = (await InitialImportRepository(database).load('family-a'))!;
    expect(paused.confirmStarted, isTrue);
    expect(paused.progress.canAbandon, isFalse);
    service.close();
    service = createService();
    expect((await service.readPreparedPreview())!.importId, preview.importId);
    expect((await service.resume()).status, InitialImportStatus.completed);
    expect(api.confirms, [preview.importId]);
    expect(api.preflights, hasLength(1));
  });

  test('source mutation after review expires plan; unsubmitted plan can be ended safely', () async {
    final preview = await service.preview();
    await service.prepare(preview);
    await inventory.createProductWithBatch(const IntakeDraft(name: '盐', category: '食品', quantity: 1));
    await expectLater(service.execute(), throwsA(isA<StateError>()));
    expect(api.confirms, isEmpty);
    await service.abandonPrepared();
    final ended = (await InitialImportRepository(database).load('family-a'))!;
    expect(ended.status, InitialImportStatus.abandoned);
    expect(ended.progress.isActive, isFalse);
    expect((await service.preview()).totalCount, greaterThan(preview.totalCount));
  });

  test('pause during confirm retains unknown outcome, cannot abandon, resumes same import', () async {
    final preview = await service.preview();
    await service.prepare(preview);
    api.confirmEntered = Completer<void>();
    api.confirmRelease = Completer<void>();
    final failed = expectLater(service.execute(), throwsA(isA<StateError>()));
    await api.confirmEntered!.future;
    await service.pause();
    api.confirmRelease!.complete();
    await failed;
    await expectLater(service.abandonPrepared(), throwsA(isA<StateError>()));
    expect((await service.resume()).status, InitialImportStatus.completed);
    expect(api.confirms, [preview.importId]);
  });

  test('a changed remote fingerprint never reaches confirm or local snapshot', () async {
    await service.prepare(await service.preview());
    api.badFingerprint = true;
    await expectLater(service.execute(), throwsA(isA<FormatException>()));
    expect(api.confirms, isEmpty);
    expect((await database.select(database.productBatches).getSingle()).remainingQuantity, 5);
  });

  test('canonical date edits expire the reviewed plan even without a timestamp change', () async {
    final preview = await service.preview();
    await service.prepare(preview);
    final batch = await database.select(database.productBatches).getSingle();
    await CalendarDateRepository(database).applyPayload(batch.id, {'expiry_date': '2027-10-22'});
    await expectLater(service.execute(), throwsA(isA<StateError>()));
    expect(api.confirms, isEmpty);
  });

  for (final invalidPage in const [
    NasImportHistoryPage(records: [], nextCursor: 1, until: 2, hasMore: true),
    NasImportHistoryPage(records: [], nextCursor: 1, until: 2, hasMore: false),
  ]) {
    test('malformed history pagination preserves cursor and invalidates pre-import snapshot ${invalidPage.hasMore}', () async {
      final preview = await service.preview();
      await service.prepare(preview);
      api.historyOverride = invalidPage;
      await expectLater(service.execute(), throwsA(isA<FormatException>()));
      final stored = (await InitialImportRepository(database).load('family-a'))!;
      expect(stored.receipt!.isCompleted, isTrue);
      expect(stored.historyCursor, 0);
      expect(await InitialImportRepository(database).history('family-a'), isEmpty);
      expect((await outbox.getPendingBootstrap('family-a'))!['refresh_required'], isTrue);
      api.historyOverride = null;
      expect((await service.resume()).status, InitialImportStatus.completed);
      expect(api.confirms, [preview.importId]);
    });
  }

  test('a late accepted confirm after session change cannot save receipt or apply local stock', () async {
    await service.prepare(await service.preview());
    api.confirmEntered = Completer<void>();
    api.confirmRelease = Completer<void>();
    final failed = expectLater(service.execute(), throwsA(isA<NasApiError>()));
    await api.confirmEntered!.future;
    api.current = false;
    api.confirmRelease!.complete();
    await failed;
    final stored = (await InitialImportRepository(database).load('family-a'))!;
    expect(stored.receipt!.isCompleted, isFalse);
    expect(stored.confirmStarted, isTrue);
    expect(stored.progress.canAbandon, isFalse);
    expect(api.historyReads, 0);
    expect((await database.select(database.productBatches).getSingle()).remainingQuantity, 5);
    api.current = true;
    expect((await service.resume()).status, InitialImportStatus.completed);
    expect(api.confirms, hasLength(1));
  });

  test('completed receipt permits a later operation to settle with its original key before recovery', () async {
    final preview = await service.preview();
    await service.prepare(preview);
    api.historyOverride = const NasImportHistoryPage(records: [], nextCursor: 1, until: 2, hasMore: true);
    await expectLater(service.execute(), throwsA(isA<FormatException>()));
    final product = await database.select(database.products).getSingle();
    await outbox.enqueue(SyncOutboxDraft(changeId: 'later-operation', scopeId: 'family-a',
      operation: SyncOperation.entityUpsert, entity: 'products', entityId: product.id,
      idempotencyKey: 'original-later-key', requestJson: jsonEncode({
        'operation': 'entity_upsert', 'entity': 'products', 'entity_id': product.id,
        'payload': {'name': product.name},
      })));
    expect((await engine.runOnce()).pushed, 1);
    final operation = (await outbox.getByChangeId('later-operation'))!;
    expect(operation.status, SyncOutboxStatus.accepted);
    expect(operation.idempotencyKey, 'original-later-key');
    expect((await database.select(database.productBatches).getSingle()).remainingQuantity, 5);
    api.historyOverride = null;
    expect((await service.resume()).status, InitialImportStatus.completed);
    expect(api.confirms, [preview.importId]);
  });

  test('unaccepted plan blocks ordinary sync and accepted receipt permits original outbox settlement', () async {
    final preview = await service.preview();
    await service.prepare(preview);
    expect((await engine.runOnce()).skipped, isTrue);
    api.loseConfirmResponse = true;
    await expectLater(service.execute(), throwsA(isA<NasApiError>()));
    // An unknown outcome still blocks until a durable completed receipt is read.
    expect((await engine.runOnce()).skipped, isTrue);
    await InitialImportRepository(database).update('family-a', preview.importId,
      status: InitialImportStatus.awaitingSnapshot, receipt: api.receipt);
    final result = await engine.runOnce();
    expect(result.skipped, isFalse);
  });

  test('pending old operation is reported; preview never uploads around its gate', () async {
    await outbox.enqueue(SyncOutboxDraft(changeId: 'pending', scopeId: 'family-a',
      operation: SyncOperation.entityUpsert, entity: 'products', entityId: 'new-id',
      idempotencyKey: 'stable-pending-operation-key', requestJson: '{}'));
    final preview = await service.preview();
    expect(preview.canPrepare, isFalse);
    await expectLater(service.prepare(preview), throwsA(isA<StateError>()));
    expect(api.preflights, isEmpty);
  });

  test('normal new products after import reuse stable category and create dependency before new category product', () async {
    final preview = await service.preview();
    await service.prepare(preview);
    await service.execute();
    final scoped = InventoryRepository(database, outbox: outbox,
      syncScopeResolver: SyncWorkspaceRepository(database).localMutationScope);
    await scoped.createProductWithBatch(const IntakeDraft(name: '面', category: '食品', quantity: 1));
    final rows = await database.select(database.syncOutbox).get();
    final products = rows.where((row) => row.entity == 'products').toList();
    expect((jsonDecode(products.single.requestJson) as Map)['payload']['category_id'],
      preview.categories.single.categoryId);
    expect(rows.where((row) => row.entity == 'categories'), isEmpty);
    await scoped.createProductWithBatch(const IntakeDraft(name: '纸', category: '清洁', quantity: 1));
    final categories = await (database.select(database.syncOutbox)
      ..where((row) => row.entity.equals('categories'))).get();
    expect(categories, hasLength(1));
  });
}
