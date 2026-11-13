import 'dart:async';

import 'package:image_picker/image_picker.dart';

import '../data/repositories/media_repository.dart';
import '../data/nas/nas_sync_api.dart';
import 'backend_processing_service.dart';
import '../domain/models/recognition_models.dart';
import '../services/media_storage_service.dart';

class MediaService {
  MediaService(this._repository, this._storage, {required this.backend,this.assertWritable});

  final BackendProcessingService backend;
  final void Function()? assertWritable;

  final MediaRepository _repository;
  final MediaStorageService _storage;

  // Media files and their metadata are a single logical resource. Keep every
  // mutating/cleanup path in one isolate-wide queue so reconcile cannot observe
  // the gap between a file write and its metadata commit, or delete a file
  // created after it took its reference snapshot. This also covers separate
  // MediaService/storage instances pointing at the same app media directory.
  static Future<void>? _lastMediaOperation;

  Future<T> _runSerialized<T>(Future<T> Function() operation) {
    final previous = _lastMediaOperation;
    final release = Completer<void>();
    final tail = release.future;
    // Only the release signal enters the queue, never the operation's result,
    // so a failed save/OCR/delete cannot poison later cleanup or writes.
    _lastMediaOperation = tail;
    Future<T> run() async {
      try {
        return await operation();
      } finally {
        // Release an idle tail rather than retaining a completed Future and
        // its scheduling zone across independent callers/test environments.
        // A queued successor owns the tail and must never be cleared here.
        if (identical(_lastMediaOperation, tail)) {
          _lastMediaOperation = null;
        }
        release.complete();
      }
    }
    return previous == null ? run() : previous.then<T>((_) => run());
  }

  Stream<List<MediaAsset>> watchForEntity({
    required String entityType,
    required String entityId,
  }) => _repository.watchForEntity(entityType: entityType, entityId: entityId);

  Future<List<MediaAsset>> loadForEntity({
    required String entityType,
    required String entityId,
  }) =>
      _repository.loadForEntity(entityType: entityType, entityId: entityId);

  Future<MediaAsset> attachImage({
    required XFile source,
    required String entityType,
    required String entityId,
    required MediaAssetType type,
  }) =>
      _runSerialized(() async {
        assertWritable?.call();
        NasSyncApi? api;
        try { api = await backend.resolveApi(); } catch (_) { /* stage against the durable household below */ }
        final stored = await _storage.storeUploadSource(source);
        var committed = false;
        try {
          final asset = await _repository.create(
            entityType: entityType,
            entityId: entityId,
            type: type,
            localPath: stored.path,
            mimeType: stored.mimeType,
            sizeBytes: stored.sizeBytes,
            sha256: stored.sha256,
          );
          committed = true;
          if (api == null) await backend.stage(asset);
          // Metadata is committed first so an interrupted upload can recover.
          if (api != null) {
            try { await backend.upload(api, asset); } catch (_) {
              throw StateError('图片已暂存，后端上传未完成；请联网后重试 OCR 或同步。');
            }
          }
          return asset;
        } catch (_) {
          // Keep a committed asset's source bytes for retry.
          if (!committed) {
            await _storage.deleteIfExists(stored.path);
          }
          rethrow;
        }
      });

  Future<String> runOcr(MediaAsset asset) =>
      _runSerialized(() async {
        final api = await backend.resolveApi();
        if (api != null) return backend.ocr(api, asset);
        throw StateError('NAS 暂不可用，请恢复连接后识别。');
      });

  Future<void> reassignIntakeAssets({
    required String intakeDraftId,
    required String productId,
  }) =>
      _runSerialized(
        () async {
          final service = backend;
          final assets = await _repository.loadForEntity(entityType: 'intake_draft', entityId: intakeDraftId);
          await service.reassignIntake(assets, productId);
        },
      );

  Future<void> delete(MediaAsset asset) =>
      _runSerialized(() async {
        assertWritable?.call();
        NasSyncApi? api;
        try { api = await backend.resolveApi(); } catch (_) { /* tombstone retains original household */ }
        await backend.stage(asset, deleting: true);
        if (api != null) {
          try { await backend.delete(api, asset); } catch (_) { /* durable tombstone remains queued */ }
        }
        final removed = await _repository.markDeleted(asset.id);
        if (removed != null) await _storage.deleteIfExists(removed.localPath);
      });

  Future<void> syncBackend(NasSyncApi api) => _runSerialized(() async {
    final service = backend;
    var failed = false;
    try { await service.flushDeletes(api); } catch (_) { api.assertCurrentSession(); failed = true; }
    for (final asset in await _repository.loadAllActive()) {
      try { await service.upload(api, asset); } catch (_) { api.assertCurrentSession(); failed = true; }
    }
    await service.refreshProducts(api);
    if (failed) throw StateError('部分图片未完成同步，请查看图片状态后重试。');
  });

  Future<MediaCleanupReport> reconcile({
    Duration intakeDraftRetention = const Duration(days: 1),
  }) =>
      _runSerialized(() async {
        // Missing phone cache files never mean the NAS original was deleted.
        final references = (await _repository.loadAllActive()).map((a)=>a.localPath).toSet();
        return MediaCleanupReport(deletedFiles:await _storage.deleteUnreferenced(references),deletedMetadata:0);
      });
}
