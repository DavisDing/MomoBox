import 'dart:io';

import 'package:image_picker/image_picker.dart';

import '../data/repositories/media_repository.dart';
import '../domain/models/recognition_models.dart';
import '../services/local_ocr_service.dart';
import '../services/media_storage_service.dart';

class MediaService {
  MediaService(this._repository, this._storage, this._ocr);

  final MediaRepository _repository;
  final MediaStorageService _storage;
  final LocalOcrService _ocr;

  Stream<List<MediaAsset>> watchForEntity({
    required String entityType,
    required String entityId,
  }) =>
      _repository.watchForEntity(entityType: entityType, entityId: entityId);

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
  }) async {
    final stored = await _storage.storeImage(source);
    try {
      return await _repository.create(
        entityType: entityType,
        entityId: entityId,
        type: type,
        localPath: stored.path,
        mimeType: stored.mimeType,
        sizeBytes: stored.sizeBytes,
        sha256: stored.sha256,
      );
    } catch (_) {
      await _storage.deleteIfExists(stored.path);
      rethrow;
    }
  }

  Future<String> runOcr(MediaAsset asset) async {
    if (!await File(asset.localPath).exists()) {
      throw StateError('图片文件已丢失，无法识别。');
    }
    final text = await _ocr.extractText(asset.localPath);
    await _repository.updateOcr(asset.id, text);
    return text;
  }

  Future<void> reassignIntakeAssets({
    required String intakeDraftId,
    required String productId,
  }) =>
      _repository.reassignEntity(
        fromEntityType: 'intake_draft',
        fromEntityId: intakeDraftId,
        toEntityType: 'product',
        toEntityId: productId,
      );

  Future<void> delete(MediaAsset asset) async {
    final removed = await _repository.markDeleted(asset.id);
    if (removed != null) await _storage.deleteIfExists(removed.localPath);
  }

  Future<MediaCleanupReport> reconcile({
    Duration intakeDraftRetention = const Duration(days: 1),
  }) async {
    var deletedFiles = 0;
    var deletedMetadata = 0;
    final cutoff = DateTime.now().subtract(intakeDraftRetention);
    final active = await _repository.loadAllActive();

    // A dismissed intake sheet can leave a temporary draft behind. Keep it
    // long enough for an interrupted flow to be recovered, then clean it up.
    for (final asset in active.where(
      (asset) => asset.entityType == 'intake_draft' && asset.createdAt.isBefore(cutoff),
    )) {
      final removed = await _repository.markDeleted(asset.id);
      if (removed == null) continue;
      deletedMetadata++;
      if (await _storage.deleteIfExists(removed.localPath)) deletedFiles++;
    }

    final remaining = await _repository.loadAllActive();
    final existing = await _storage.existingPaths();
    for (final asset in remaining.where((asset) => !existing.contains(asset.localPath))) {
      final removed = await _repository.markDeleted(asset.id);
      if (removed != null) deletedMetadata++;
    }

    final referenced = (await _repository.loadAllActive())
        .map((asset) => asset.localPath)
        .toSet();
    deletedFiles += await _storage.deleteUnreferenced(referenced);
    return MediaCleanupReport(
      deletedFiles: deletedFiles,
      deletedMetadata: deletedMetadata,
    );
  }
}
