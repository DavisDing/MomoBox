import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/ai_fallback_executor.dart';
import 'package:momo_box/application/media_service.dart';
import 'package:momo_box/services/local_ocr_service.dart';
import 'package:momo_box/domain/models/recognition_models.dart';
import 'package:momo_box/application/backend_processing_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/media_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/services/media_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('zero discard is accepted, invalid zero consume preserves page and cursor', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final inventory = InventoryRepository(db);
    final product = await inventory.createProductWithBatch(const IntakeDraft(name: '米', category: '食品生鲜', quantity: 1, lowStockThreshold: 1));
    final batch = (await db.select(db.productBatches).get()).single.id;
    var type = 'discard';
    final api = NasSyncApi('https://nas.example', accessToken: 'test', client: MockClient((_) async => http.Response(jsonEncode({
      'records': [{'id':'zero', 'cursor':1, 'product_id':product, 'batch_id':batch, 'operation_id':null,
        'type':type,'quantity':0,'created_at':'2026-11-03T01:00:00Z'}],
      'next_cursor':1, 'until':1, 'has_more':false,
    }), 200)));
    addTearDown(api.close);
    final service = BackendProcessingService(db, MediaRepository(db), MediaStorageService(), resolveApi: () async => api, scopeId: () => 'family');
    await service.syncHistory(api);
    expect((await db.select(db.stockMovements).get()).where((m) => m.id == 'zero').single.quantity, 0);
    await db.customStatement("DELETE FROM app_settings WHERE key LIKE 'sync_backend_history_cursor:%'");
    type = 'consume';
    await expectLater(service.syncHistory(api), throwsFormatException);
    expect(await db.customSelect("SELECT * FROM app_settings WHERE key LIKE 'sync_backend_history_cursor:%'").get(), isEmpty);
    expect((await inventory.loadInventory()).single.totalStock, 1);
  });

  test('history replaces only its correlated local event and never changes stock', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final inventory = InventoryRepository(db);
    final productId = await inventory.createProductWithBatch(const IntakeDraft(
      name: '米', category: '食品生鲜', quantity: 7, lowStockThreshold: 1));
    final local = (await inventory.loadMovements(productId)).single;
    final source = await db.customSelect('SELECT operation_id FROM stock_movement_sources').getSingle();
    final batch = await db.customSelect('SELECT batch_id FROM stock_movements WHERE id = ?', variables: [Variable.withString(local.id)]).getSingle();
    var current = true;
    final api = NasSyncApi('https://nas.example', accessToken: 'test',
      isSessionCurrent: () => current,
      client: MockClient((request) async => http.Response(jsonEncode({
        'records': [{
          'cursor': 1, 'id': 'server-record', 'product_id': productId,
          'batch_id': batch.read<String>('batch_id'), 'operation_id': source.read<String>('operation_id'),
          'type': 'restock', 'quantity': 7, 'note': 'server restock',
          'created_at': DateTime.now().toUtc().toIso8601String(),
        }], 'next_cursor': 1, 'until': 1, 'has_more': false,
      }), 200)));
    addTearDown(api.close);
    final service = BackendProcessingService(db, MediaRepository(db), MediaStorageService(),
      resolveApi: () async => api, scopeId: () => 'family');
    await service.syncHistory(api);
    expect((await inventory.loadMovements(productId)).single.id, 'server-record');
    expect((await inventory.loadMovements(productId)).single.type, local.type);
    expect((await inventory.loadInventory()).single.totalStock, 7);
    // Replayed immutable rows are upserted once, even after cursor recovery.
    await db.customStatement("DELETE FROM app_settings WHERE key LIKE 'sync_backend_history_cursor:%'");
    await service.syncHistory(api);
    expect(await inventory.loadMovements(productId), hasLength(1));
    current = false;
    await expectLater(service.syncHistory(api), throwsA(isA<NasApiError>()));
    expect((await inventory.loadInventory()).single.totalStock, 7);
  });

  test('malformed history page rolls back records and cursor', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final api = NasSyncApi('https://nas.example', accessToken: 'test',
      client: MockClient((_) async => http.Response(jsonEncode({
        'records': [], 'next_cursor': 0, 'until': 1, 'has_more': true,
      }), 200)));
    addTearDown(api.close);
    final service = BackendProcessingService(db, MediaRepository(db), MediaStorageService(),
      resolveApi: () async => api, scopeId: () => 'family');
    await expectLater(service.syncHistory(api), throwsFormatException);
    expect(await db.select(db.stockMovements).get(), isEmpty);
    expect(await db.select(db.appSettings).get(), isEmpty);
  });

  test('one missing local image does not prevent the next image from uploading', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory()); addTearDown(db.close);
    final dir = await Directory.systemTemp.createTemp('audit-media-'); addTearDown(() => dir.delete(recursive:true));
    final repository = MediaRepository(db);
    final missing = await repository.create(entityType:'product', entityId:'product', type:MediaAssetType.productImage,
      localPath:'${dir.path}/missing',mimeType:'image/jpeg',sizeBytes:3,sha256:'a');
    final file = await File('${dir.path}/present').writeAsBytes([1,2,3]);
    final valid = await repository.create(entityType:'product',entityId:'product',type:MediaAssetType.productImage,
      localPath:file.path,mimeType:'image/jpeg',sizeBytes:3,sha256:'b');
    final uploaded = <String>[];
    final api = NasSyncApi('https://nas.example',accessToken:'test',client:MockClient((r) async {
      if (r.url.path.endsWith('/upload')) { final id=(jsonDecode(r.body) as Map)['id'] as String; uploaded.add(id); return http.Response(jsonEncode({'id':id,'deleted_at':null}),200); }
      return http.Response('{"assets":[]}',200);
    }));addTearDown(api.close);
    final backend=BackendProcessingService(db,repository,MediaStorageService(),resolveApi:() async=>api,scopeId:()=> 'family');
    final media=MediaService(repository,MediaStorageService(),_NeverLocalOcr(),backend:backend);
    await expectLater(media.syncBackend(api),throwsStateError);
    expect(uploaded,[valid.id]);
    expect((await repository.loadAllActive()).firstWhere((a)=>a.id==missing.id).backendState,'failed');
  });

  test('backend AI uses NAS without any phone provider configuration or key', () async {
    var directCalls = 0;
    final api = NasSyncApi('https://nas.example', accessToken: 'nas-token',
      client: MockClient((request) async {
        expect(request.url.host, 'nas.example');
        expect(request.headers['Authorization'], 'Bearer nas-token');
        if (request.url.path.endsWith('/capabilities')) {
          return http.Response('{"backend_ai":true}', 200);
        }
        final payload = jsonDecode(request.body) as Map;
        expect(payload['user_prompt'], 'OCR text');
        expect(payload.containsKey('api_key'), isFalse);
        expect(payload.containsKey('endpoint'), isFalse);
        return http.Response(jsonEncode({'content': 'draft', 'usage': {},
          'model': 'nas-model', 'protocol': 'chat', 'level': 'secondary', 'elapsed_ms': 5}), 200);
      }));
    addTearDown(api.close);
    final executor = AiFallbackExecutor(backendResolver: () async => api,
      client: MockClient((_) async { directCalls++; throw StateError('phone AI must not run'); }));
    addTearDown(executor.close);
    final result = await executor.execute(configs: [], systemPrompt: 'contract', userPrompt: 'OCR text');
    expect(result.content, 'draft');
    expect(result.usedLevel, AiApiLevel.secondary);
    expect(directCalls, 0);
  });

  test('lost upload receipt reuses original ID and OCR stays on backend', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final directory = await Directory.systemTemp.createTemp('momo-backend-media-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/source.jpg').writeAsBytes([1, 2, 3]);
    final repository = MediaRepository(db);
    final asset = await repository.create(entityType: 'product', entityId: 'product',
      type: MediaAssetType.instructionImage, localPath: file.path,
      mimeType: 'image/jpeg', sizeBytes: 3, sha256: 'source');
    final uploadBodies = <String>[];
    var ocrCalls = 0;
    final api = NasSyncApi('https://nas.example', accessToken: 'test', client: MockClient((request) async {
      if (request.url.path.endsWith('/upload')) {
        uploadBodies.add(request.body);
        if (uploadBodies.length == 1) throw http.ClientException('lost response');
        return http.Response(jsonEncode({'id': asset.id, 'deleted_at': null}), 200);
      }
      ocrCalls++;
      return http.Response(jsonEncode({'id': asset.id, 'ocr_status': 'complete', 'ocr_text': '后端文字'}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    addTearDown(api.close);
    final backend = BackendProcessingService(db, repository, MediaStorageService(),
      resolveApi: () async => api, scopeId: () => 'family');
    await expectLater(backend.upload(api, asset), throwsA(isA<NasApiError>()));
    expect(await file.exists(), isTrue);
    final state = await db.customSelect('SELECT state FROM backend_media_state').getSingle();
    expect(state.read<String>('state'), 'failed');
    final localOcr = _NeverLocalOcr();
    final service = MediaService(repository, MediaStorageService(), localOcr, backend: backend);
    expect(await service.runOcr(asset), '后端文字');
    expect(uploadBodies, hasLength(2));
    expect(uploadBodies[0], uploadBodies[1]);
    expect(ocrCalls, 1);
    expect(localOcr.calls, 0);
    expect((await repository.loadAllActive()).single.ocrText, '后端文字');
  });

  test('processing mode changed during response rejects late results', () async {
    var allowed = true;
    final api = NasSyncApi('https://nas.example', accessToken: 'test',
      client: MockClient((_) async { allowed = false; return http.Response('{"content":"late"}', 200); }));
    api.setProcessingGuard(() async { if (!allowed) throw StateError('mode changed'); });
    addTearDown(api.close);
    await expectLater(api.processingRequest('/ai/analyze', body: {}), throwsStateError);
  });

  test('processing mode changed during token refresh prevents upload retry', () async {
    var allowed = true;
    var requests = 0;
    final api = NasSyncApi('https://nas.example', accessToken: 'expired',
      refreshHandler: () async {
        allowed = false;
        return 'refreshed';
      },
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 401);
      }));
    api.setProcessingGuard(() async {
      if (!allowed) throw StateError('mode changed');
    });
    addTearDown(api.close);
    await expectLater(api.processingRequest('/media/upload', body: {}), throwsStateError);
    expect(requests, 1);
  });

  test('selected unavailable backend never falls back to phone AI', () async {
    var calls = 0;
    final executor = AiFallbackExecutor(backendResolver: () async => throw StateError('NAS offline'),
      client: MockClient((_) async { calls++; return http.Response('{}', 200); }));
    addTearDown(executor.close);
    await expectLater(executor.execute(configs: const [AiEndpointConfig(
      level: AiApiLevel.primary, endpoint: 'https://phone.example/v1',
      apiKey: 'phone-key', model: 'phone-model')], systemPrompt: 'contract', userPrompt: 'text'),
      throwsStateError);
    expect(calls, 0);
  });
}

class _NeverLocalOcr extends LocalOcrService {
  int calls = 0;
  @override
  Future<String> extractText(String path) async {
    calls++;
    throw StateError('backend mode must not invoke phone OCR');
  }
}
