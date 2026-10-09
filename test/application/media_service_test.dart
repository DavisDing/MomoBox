import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:momo_box/application/media_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/media_repository.dart';
import 'package:momo_box/domain/models/recognition_models.dart';
import 'package:momo_box/services/local_ocr_service.dart';
import 'package:momo_box/services/media_storage_service.dart';

void main() {
  for (final boundary in ['file written', 'metadata pending']) {
    test('cleanup waits for attachment at $boundary across service instances', () async {
      final h = await _Harness.create();
      final gate = h.gate();
      if (boundary == 'file written') {
        h.storage.storeGate = gate;
      } else {
        h.repository.createGate = gate;
      }
      final save = h.track(h.attach());
      await gate.entered.future;
      expect(await h.storage.existingPaths(), hasLength(1));
      // Separate service and storage instances still use the same media folder.
      final cleanup = h.track(h.otherService.reconcile());
      await _drainMicrotasks();
      expect(h.repository.activeLoads, 0);
      gate.release();

      final asset = await save;
      final report = await cleanup;
      expect(report.deletedFiles, 0);
      expect(report.deletedMetadata, 0);
      expect(await File(asset.localPath).exists(), isTrue);
      expect((await h.repository.loadAllActive()).single.id, asset.id);
    });
  }

  test('attachment waits for deletion after the reference snapshot', () async {
    final h = await _Harness.create();
    final orphan = await File('${h.directory.path}/orphan.jpg').writeAsString('orphan');
    final gate = h.gate();
    h.storage.cleanupGate = gate;
    final cleanup = h.track(h.service.reconcile());
    await gate.entered.future;
    final save = h.track(h.attach(service: h.otherService));
    await _drainMicrotasks();
    expect(h.otherStorage.storeCalls, 0);
    gate.release();

    final report = await cleanup;
    final asset = await save;
    expect(report.deletedFiles, 1);
    expect(report.deletedMetadata, 0);
    expect(await orphan.exists(), isFalse);
    expect(await File(asset.localPath).exists(), isTrue);
    expect((await h.repository.loadAllActive()).single.id, asset.id);
  });

  test('missing-file snapshot cannot tombstone a concurrent attachment', () async {
    final h = await _Harness.create();
    final gate = h.gate();
    h.storage.pathsGate = gate;
    final cleanup = h.track(h.service.reconcile());
    await gate.entered.future;
    final save = h.track(h.attach(service: h.otherService));
    await _drainMicrotasks();
    expect(h.otherStorage.storeCalls, 0);
    gate.release();

    final report = await cleanup;
    final asset = await save;
    expect(report.deletedFiles, 0);
    expect(report.deletedMetadata, 0);
    expect((await h.repository.loadAllActive()).single.id, asset.id);
    expect(await File(asset.localPath).exists(), isTrue);
  });

  test('draft reassignment completes before cleanup takes an expiry snapshot', () async {
    final h = await _Harness.create();
    final draft = await h.seed('old', entityType: 'intake_draft', old: true);
    await h.repository.updateOcr(draft.id, 'saved instruction');
    final gate = h.gate();
    h.repository.reassignGate = gate;
    final reassign = h.track(h.otherService.reassignIntakeAssets(
      intakeDraftId: 'draft',
      productId: 'product',
    ));
    await gate.entered.future;
    final cleanup = h.track(h.service.reconcile());
    await _drainMicrotasks();
    expect(h.repository.activeLoads, 0);
    gate.release();

    await reassign;
    final report = await cleanup;
    expect(report.deletedFiles, 0);
    expect(report.deletedMetadata, 0);
    expect((await h.repository.loadAllActive()).single.entityType, 'product');
    expect(await File(draft.localPath).exists(), isTrue);
    final ocr = await h.repository.searchOcr(
      entityType: 'product',
      entityId: 'product',
      query: 'instruction',
    );
    expect(ocr.single.asset.id, draft.id);
  });

  test('queued draft reassignment includes an attachment still awaiting metadata', () async {
    final h = await _Harness.create();
    final gate = h.gate();
    h.repository.createGate = gate;
    final save = h.attach(entityType: 'intake_draft');
    await gate.entered.future;
    final reassign = h.track(h.otherService.reassignIntakeAssets(
      intakeDraftId: 'draft',
      productId: 'product',
    ));
    await _drainMicrotasks();
    expect(h.repository.reassignCalls, 0);
    gate.release();

    final asset = await save;
    await reassign;
    final stored = (await h.repository.loadAllActive()).single;
    expect(stored.id, asset.id);
    expect(stored.entityType, 'product');
    expect(stored.entityId, 'product');
    expect(await File(asset.localPath).exists(), isTrue);
  });

  test('cleanup expiry snapshot and later reassignment serialize without resurrection', () async {
    final h = await _Harness.create();
    final draft = await h.seed('old', entityType: 'intake_draft', old: true);
    final gate = h.gate();
    h.repository.snapshotGate = gate;
    final cleanup = h.track(h.service.reconcile());
    await gate.entered.future;
    final reassign = h.track(h.otherService.reassignIntakeAssets(
      intakeDraftId: 'draft',
      productId: 'product',
    ));
    await _drainMicrotasks();
    expect(h.repository.reassignCalls, 0);
    gate.release();

    final report = await cleanup;
    await reassign;
    expect(report.deletedFiles, 1);
    expect(report.deletedMetadata, 1);
    expect(await h.repository.loadAllActive(), isEmpty);
    expect(await File(draft.localPath).exists(), isFalse);
  });

  test('two cleanup requests do not duplicate deletion or reports', () async {
    final h = await _Harness.create();
    await h.seed('old', entityType: 'intake_draft', old: true);
    final gate = h.gate();
    h.repository.snapshotGate = gate;
    final first = h.track(h.service.reconcile());
    await gate.entered.future;
    final second = h.track(h.otherService.reconcile());
    await _drainMicrotasks();
    expect(h.repository.activeLoads, 1);
    gate.release();

    final firstReport = await first;
    final secondReport = await second;
    expect(firstReport.deletedFiles, 1);
    expect(firstReport.deletedMetadata, 1);
    expect(secondReport.deletedFiles, 0);
    expect(secondReport.deletedMetadata, 0);
    expect(h.repository.markDeletedCalls, 1);
  });

  test('manual deletion and cleanup do not delete the same asset concurrently', () async {
    final h = await _Harness.create();
    final asset = await h.seed('product');
    final gate = h.gate();
    h.repository.deleteGate = gate;
    final deletion = h.track(h.otherService.delete(asset));
    await gate.entered.future;
    final cleanup = h.track(h.service.reconcile());
    await _drainMicrotasks();
    expect(h.repository.activeLoads, 0);
    gate.release();

    await deletion;
    final report = await cleanup;
    expect(report.deletedFiles, 0);
    expect(report.deletedMetadata, 0);
    expect(h.repository.markDeletedCalls, 1);
    expect(await File(asset.localPath).exists(), isFalse);
  });

  test('OCR holds the boundary until text and its search index are saved', () async {
    final h = await _Harness.create();
    final asset = await h.seed('old', entityType: 'intake_draft', old: true);
    final gate = h.gate();
    h.ocr.gate = gate;
    final recognition = h.track(h.service.runOcr(asset));
    await gate.entered.future;
    final cleanup = h.track(h.otherService.reconcile());
    await _drainMicrotasks();
    expect(h.repository.activeLoads, 0);
    expect(await File(asset.localPath).exists(), isTrue);
    gate.release();

    expect(await recognition, 'recognized text');
    final report = await cleanup;
    expect(report.deletedFiles, 1);
    expect(report.deletedMetadata, 1);
    expect(await h.repository.loadAllActive(), isEmpty);
    final indexed = await h.database.customSelect(
      'SELECT asset_id FROM media_ocr_fts',
    ).get();
    expect(indexed, isEmpty);
  });

  test('metadata failure rolls back the file and does not poison queued cleanup', () async {
    final h = await _Harness.create();
    final gate = h.gate();
    final failure = StateError('metadata write failed');
    h.repository.createGate = gate;
    h.repository.createFailure = failure;
    final save = h.track(h.attach());
    final failed = expectLater(save, throwsA(same(failure)));
    await gate.entered.future;
    final cleanup = h.track(h.otherService.reconcile());
    gate.release();

    await failed;
    final report = await cleanup;
    expect(report.deletedFiles, 0);
    expect(report.deletedMetadata, 0);
    expect(await h.storage.existingPaths(), isEmpty);
    expect(await h.repository.loadAllActive(), isEmpty);
    h.repository.createFailure = null;
    expect(await File((await h.attach()).localPath).exists(), isTrue);
  });

  test('rollback deletion failure is reported and later cleanup retries the orphan', () async {
    final h = await _Harness.create();
    final failure = FileSystemException('rollback delete failed');
    h.repository.createFailure = StateError('metadata write failed');
    h.storage.deleteFailure = failure;
    await expectLater(h.attach(), throwsA(same(failure)));
    expect(await h.storage.existingPaths(), hasLength(1));
    expect(await h.repository.loadAllActive(), isEmpty);

    h.storage.deleteFailure = null;
    final report = await h.otherService.reconcile();
    expect(report.deletedFiles, 1);
    expect(report.deletedMetadata, 0);
  });

  test('cleanup failure reaches the caller and releases queued attachment', () async {
    final h = await _Harness.create();
    final gate = h.gate();
    final failure = FileSystemException('cleanup failed');
    h.storage.cleanupGate = gate;
    h.storage.cleanupFailure = failure;
    final cleanup = h.track(h.service.reconcile());
    final failed = expectLater(cleanup, throwsA(same(failure)));
    await gate.entered.future;
    final save = h.track(h.attach(service: h.otherService));
    gate.release();

    await failed;
    final asset = await save;
    expect(await File(asset.localPath).exists(), isTrue);
    expect((await h.repository.loadAllActive()).single.id, asset.id);
  });

  test('failed manual deletion preserves failure and leaves an orphan for cleanup', () async {
    final h = await _Harness.create();
    final asset = await h.seed('product');
    final failure = FileSystemException('delete failed');
    h.storage.deleteFailure = failure;
    await expectLater(h.service.delete(asset), throwsA(same(failure)));
    expect(await h.repository.loadAllActive(), isEmpty);
    expect(await File(asset.localPath).exists(), isTrue);

    h.storage.deleteFailure = null;
    final report = await h.otherService.reconcile();
    expect(report.deletedFiles, 1);
    expect(report.deletedMetadata, 0);
  });

  test('store and OCR failures release the queue without reporting success', () async {
    final h = await _Harness.create();
    final storeFailure = StateError('invalid image');
    h.storage.storeFailure = storeFailure;
    await expectLater(h.attach(), throwsA(same(storeFailure)));
    h.storage.storeFailure = null;
    final asset = await h.attach();
    final ocrFailure = StateError('OCR failed');
    h.ocr.failure = ocrFailure;
    await expectLater(h.service.runOcr(asset), throwsA(same(ocrFailure)));
    expect((await h.repository.loadAllActive()).single.ocrText, isNull);
    final report = await h.otherService.reconcile();
    expect(report.deletedFiles, 0);
    expect(report.deletedMetadata, 0);
    expect(await File(asset.localPath).exists(), isTrue);
  });

  test('cleanup preserves product/recent draft, removes old/missing/orphan and is idempotent', () async {
    final h = await _Harness.create();
    final product = await h.seed('product');
    final recent = await h.seed('recent', entityType: 'intake_draft');
    final old = await h.seed('old', entityType: 'intake_draft', old: true);
    await h.seed('missing', missing: true);
    final orphan = await File('${h.directory.path}/orphan.jpg').writeAsString('orphan');

    final report = await h.service.reconcile();
    expect(report.deletedFiles, 2);
    expect(report.deletedMetadata, 2);
    expect(await File(product.localPath).exists(), isTrue);
    expect(await File(recent.localPath).exists(), isTrue);
    expect(await File(old.localPath).exists(), isFalse);
    expect(await orphan.exists(), isFalse);
    expect((await h.repository.loadAllActive()).map((asset) => asset.id),
        unorderedEquals([product.id, recent.id]));
    final second = await h.otherService.reconcile();
    expect(second.deletedFiles, 0);
    expect(second.deletedMetadata, 0);
  });

  test('OCR of a missing file still fails and releases subsequent cleanup', () async {
    final h = await _Harness.create();
    final asset = await h.seed('missing', missing: true);
    await expectLater(
      h.service.runOcr(asset),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        '图片文件已丢失，无法识别。',
      )),
    );
    final report = await h.otherService.reconcile();
    expect(report.deletedFiles, 0);
    expect(report.deletedMetadata, 1);
  });

  test('custom intake retention is still honored', () async {
    final h = await _Harness.create();
    final draft = await h.seed('old', entityType: 'intake_draft', old: true);
    final kept = await h.service.reconcile(
      intakeDraftRetention: const Duration(days: 3),
    );
    expect(kept.deletedFiles, 0);
    expect(kept.deletedMetadata, 0);
    expect(await File(draft.localPath).exists(), isTrue);
    final removed = await h.otherService.reconcile();
    expect(removed.deletedFiles, 1);
    expect(removed.deletedMetadata, 1);
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
    service = MediaService(repository, storage, ocr);
    otherService = MediaService(repository, otherStorage, ocr);
  }

  final AppDatabase database;
  final Directory directory;
  final ocr = _ControlledOcr();
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
  Future<StoredImageFile> storeImage(XFile source) async {
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

class _ControlledOcr extends LocalOcrService {
  _Gate? gate;
  Object? failure;

  @override
  Future<String> extractText(String path) async {
    await gate?.wait();
    final error = failure;
    if (error != null) throw error;
    if (!await File(path).exists()) throw StateError('OCR source disappeared');
    return 'recognized text';
  }
}
