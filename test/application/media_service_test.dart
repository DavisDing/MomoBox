import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:momo_box/application/media_service.dart';
import 'package:momo_box/application/backend_processing_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/media_repository.dart';
import 'package:momo_box/domain/models/recognition_models.dart';
import 'package:momo_box/services/media_storage_service.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';

void main() {
 test('NAS attachment commits source before upload and retains source on unknown upload failure',() async {
  final h=await _Harness.create();
  h.backend.uploadFailure=StateError('NAS unavailable');
  await expectLater(h.attach(),throwsStateError);
  final asset=(await h.repository.loadAllActive()).single;
  expect(await File(asset.localPath).exists(),isTrue);
  expect(h.backend.uploads,1);
 });
 for(final boundary in ['file written','metadata pending']) {
  test('cleanup waits for attachment at $boundary across service instances',() async {
   final h=await _Harness.create(); final gate=h.gate();
   if(boundary=='file written') { h.storage.storeGate=gate; } else { h.repository.createGate=gate; }
   final save=h.track(h.attach()); await gate.entered.future;
   final cleanup=h.track(h.otherService.reconcile()); await _drainMicrotasks();
   expect(h.repository.activeLoads,0); gate.release();
   final asset=await save; final result=await cleanup;
   expect(result.deletedMetadata,0); expect(await File(asset.localPath).exists(),isTrue);
  });
 }
 test('cleanup preserves all referenced NAS cache metadata including old drafts and absent files',() async {
  final h=await _Harness.create(); final old=await h.seed('old',entityType:'intake_draft',old:true);
  await h.seed('missing',missing:true); final orphan=await File('${h.directory.path}/orphan').writeAsString('unused');
  final result=await h.service.reconcile();
  expect(result.deletedFiles,1);expect(result.deletedMetadata,0);
  expect(await h.repository.loadAllActive(),hasLength(2));expect(await File(old.localPath).exists(),isTrue);
  expect(await orphan.exists(),isFalse);
  expect((await h.otherService.reconcile()).deletedFiles,0);
 });
 test('metadata failure rolls source back and does not poison queued cleanup',() async {
  final h=await _Harness.create(); h.repository.createFailure=StateError('disk');
  await expectLater(h.attach(),throwsStateError);
  expect(await h.storage.existingPaths(),isEmpty);
  expect((await h.otherService.reconcile()).deletedMetadata,0);
 });
 test('OCR and cleanup share one media queue and NAS result updates local search cache',() async {
  final h=await _Harness.create();final asset=await h.seed('image');final gate=h.gate();h.backend.ocrGate=gate;
  final ocr=h.track(h.service.runOcr(asset));await gate.entered.future;
  final cleanup=h.track(h.otherService.reconcile());await _drainMicrotasks();expect(h.repository.activeLoads,0);
  gate.release();expect(await ocr,'NAS text');await cleanup;
  expect((await h.repository.loadAllActive()).single.ocrText,'NAS text');
 });
 test('offline user writes are rejected before creating source files',() async {
  final h=await _Harness.create();final readOnly=MediaService(h.repository,h.storage,backend:h.backend,
   assertWritable:()=>throw StateError('read only'));
  await expectLater(h.attach(service:readOnly),throwsStateError);
  expect(await h.storage.existingPaths(),isEmpty);expect(await h.repository.loadAllActive(),isEmpty);
 });
 test('NAS deletion intent precedes local cache removal',() async {
  final h=await _Harness.create();final asset=await h.seed('delete');await h.service.delete(asset);
  expect(h.backend.deleted,[asset.id]);expect(await h.repository.loadAllActive(),isEmpty);
  expect(await File(asset.localPath).exists(),isFalse);
 });
}

// Cross an event-loop boundary only to drain already-enqueued microtasks. All
// meaningful interleavings are pinned by explicit gates, not elapsed time.
Future<void> _drainMicrotasks() => Future<void>(() {});

class _Gate {
  final entered = Completer<void>();
  final _released = Completer<void>();

  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await _released.future;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

class _Harness {
  _Harness(this.database, this.directory) {
    repository = _ControlledMediaRepository(database);
    storage = _ControlledMediaStorage(directory, prefix: 'first');
    otherStorage = _ControlledMediaStorage(directory, prefix: 'second');
    backend = _Backend(database,repository,storage);
    service = MediaService(repository,storage,backend:backend);
    otherService = MediaService(repository,otherStorage,backend:backend);
  }

  final AppDatabase database;
  final Directory directory;
  late final _Backend backend;
  late final _ControlledMediaRepository repository;
  late final _ControlledMediaStorage storage;
  late final _ControlledMediaStorage otherStorage;
  late final MediaService service;
  late final MediaService otherService;
  final _gates = <_Gate>[];
  final _pending = <Future<void>>[];

  static Future<_Harness> create() async {
    final h = _Harness(
      AppDatabase.forTesting(NativeDatabase.memory()),
      await Directory.systemTemp.createTemp('momobox-media-test-'),
    );
    addTearDown(() async {
      for (final gate in h._gates) {
        gate.release();
      }
      await Future.wait(h._pending);
      await h.database.close();
      await h.directory.delete(recursive: true);
    });
    return h;
  }

  _Gate gate() {
    final gate = _Gate();
    _gates.add(gate);
    return gate;
  }

  Future<T> track<T>(Future<T> future) {
    // Observe failure immediately, while leaving the original future available
    // for throwsA assertions, and await settled operations before closing SQLite.
    _pending.add(future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    return future;
  }

  Future<MediaAsset> attach({
    MediaService? service,
    String entityType = 'product',
  }) =>
      track((service ?? this.service).attachImage(
        source: XFile('unused-by-test-storage'),
        entityType: entityType,
        entityId: entityType == 'intake_draft' ? 'draft' : 'product',
        type: MediaAssetType.productImage,
      ));

  // Fixture writes complete before starting concurrent service operations.
  Future<MediaAsset> seed(
    String name, {
    String entityType = 'product',
    bool old = false,
    bool missing = false,
  }) async {
    final file = File('${directory.path}/$name.jpg');
    if (!missing) await file.writeAsString(name);
    final asset = await repository.create(
      entityType: entityType,
      entityId: entityType == 'intake_draft' ? 'draft' : 'product',
      type: MediaAssetType.productImage,
      localPath: file.path,
      mimeType: 'image/jpeg',
      sizeBytes: name.length,
      sha256: name,
    );
    if (old) {
      await (database.update(database.mediaAssets)
            ..where((row) => row.id.equals(asset.id)))
          .write(MediaAssetsCompanion(
        createdAt: Value(DateTime.now().subtract(const Duration(days: 2))),
      ));
    }
    return asset;
  }
}

class _ControlledMediaRepository extends MediaRepository {
  _ControlledMediaRepository(super.database);

  _Gate? createGate;
  _Gate? snapshotGate;
  _Gate? reassignGate;
  _Gate? deleteGate;
  Object? createFailure;
  int activeLoads = 0;
  int reassignCalls = 0;
  int markDeletedCalls = 0;

  @override
  Future<MediaAsset> create({
    required String entityType,
    required String entityId,
    required MediaAssetType type,
    required String localPath,
    required String mimeType,
    required int sizeBytes,
    required String sha256,
    int? width,
    int? height,
  }) async {
    await createGate?.wait();
    final failure = createFailure;
    if (failure != null) throw failure;
    return super.create(
      entityType: entityType,
      entityId: entityId,
      type: type,
      localPath: localPath,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      sha256: sha256,
      width: width,
      height: height,
    );
  }

  @override
  Future<List<MediaAsset>> loadAllActive() async {
    activeLoads++;
    final snapshot = await super.loadAllActive();
    await snapshotGate?.wait();
    return snapshot;
  }

  @override
  Future<void> reassignEntity({
    required String fromEntityType,
    required String fromEntityId,
    required String toEntityType,
    required String toEntityId,
  }) async {
    reassignCalls++;
    await reassignGate?.wait();
    await super.reassignEntity(
      fromEntityType: fromEntityType,
      fromEntityId: fromEntityId,
      toEntityType: toEntityType,
      toEntityId: toEntityId,
    );
  }

  @override
  Future<MediaAsset?> markDeleted(String id) async {
    markDeletedCalls++;
    await deleteGate?.wait();
    return super.markDeleted(id);
  }
}

// Platform image/OCR work is substituted. Files, repository mutations,
// tombstones and OCR index operations use real temporary files and in-memory DB.
class _ControlledMediaStorage extends MediaStorageService {
  _ControlledMediaStorage(this.directory, {required this.prefix});

  final Directory directory;
  final String prefix;
  _Gate? storeGate;
  _Gate? pathsGate;
  _Gate? cleanupGate;
  Object? storeFailure;
  Object? deleteFailure;
  Object? cleanupFailure;
  int storeCalls = 0;

  @override
  Future<StoredImageFile> storeUploadSource(XFile source) async {
    storeCalls++;
    final failure = storeFailure;
    if (failure != null) throw failure;
    final file = File('${directory.path}/$prefix-$storeCalls.jpg');
    await file.writeAsBytes([1, 2, 3], flush: true);
    await storeGate?.wait();
    return StoredImageFile(
      path: file.path,
      mimeType: 'image/jpeg',
      sizeBytes: 3,
      sha256: 'test-only',
    );
  }

  @override
  Future<Set<String>> existingPaths() async {
    final snapshot = {
      await for (final entity in directory.list(followLinks: false))
        if (entity is File) entity.path,
    };
    await pathsGate?.wait();
    return snapshot;
  }

  @override
  Future<int> deleteUnreferenced(Set<String> referencedPaths) async {
    await cleanupGate?.wait();
    final failure = cleanupFailure;
    if (failure != null) throw failure;
    return super.deleteUnreferenced(referencedPaths);
  }

  @override
  Future<bool> deleteIfExists(String path) async {
    final failure = deleteFailure;
    if (failure != null) throw failure;
    return super.deleteIfExists(path);
  }
}

class _Backend extends BackendProcessingService {
 _Backend(super.db,super.repo,super.storage):super(resolveApi:()async=>NasSyncApi('https://fixture.invalid'),scopeId:()=> 'family');
 _Gate? ocrGate;
 Object? uploadFailure;
 int uploads=0;
 final deleted=<String>[];
 @override Future<void> upload(NasSyncApi api,MediaAsset asset) async { uploads++;if(uploadFailure!=null)throw uploadFailure!; }
 @override Future<String> ocr(NasSyncApi api,MediaAsset asset) async {
  await ocrGate?.wait();await repository.updateOcr(asset.id,'NAS text');return 'NAS text';
 }
 @override Future<void> stage(MediaAsset asset,{bool deleting=false}) async {}
 @override Future<void> delete(NasSyncApi api,MediaAsset asset) async {deleted.add(asset.id);}
}
