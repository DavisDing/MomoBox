import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../domain/models/recognition_models.dart';

class MediaRepository {
  MediaRepository(this._database, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Stream<List<MediaAsset>> watchForEntity({
    required String entityType,
    required String entityId,
  }) =>
      (_database.select(_database.mediaAssets)
            ..where((asset) => asset.entityType.equals(entityType))
            ..where((asset) => asset.entityId.equals(entityId))
            ..where((asset) => asset.deletedAt.isNull())
            ..orderBy([(asset) => OrderingTerm.desc(asset.createdAt)]))
          .watch()
          .map(_toModels);

  Future<List<MediaAsset>> loadForEntity({
    required String entityType,
    required String entityId,
  }) =>
      (_database.select(_database.mediaAssets)
            ..where((asset) => asset.entityType.equals(entityType))
            ..where((asset) => asset.entityId.equals(entityId))
            ..where((asset) => asset.deletedAt.isNull())
            ..orderBy([(asset) => OrderingTerm.desc(asset.createdAt)]))
          .get()
          .then(_toModels);

  Future<List<MediaAsset>> loadAllActive() =>
      (_database.select(_database.mediaAssets)..where((asset) => asset.deletedAt.isNull()))
          .get()
          .then(_toModels);

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
    final now = DateTime.now();
    final id = _uuid.v4();
    await _database.into(_database.mediaAssets).insert(
          MediaAssetsCompanion.insert(
            id: id,
            entityType: entityType,
            entityId: entityId,
            mediaType: type.storageValue,
            localPath: localPath,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            width: Value(width),
            height: Value(height),
            sha256: sha256,
            createdAt: now,
          ),
        );
    return MediaAsset(
      id: id,
      entityType: entityType,
      entityId: entityId,
      type: type,
      localPath: localPath,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      sha256: sha256,
      width: width,
      height: height,
      createdAt: now,
    );
  }

  Future<void> updateOcr(String id, String text) =>
      (_database.update(_database.mediaAssets)..where((asset) => asset.id.equals(id))).write(
        MediaAssetsCompanion(
          ocrText: Value(text),
          ocrUpdatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> reassignEntity({
    required String fromEntityType,
    required String fromEntityId,
    required String toEntityType,
    required String toEntityId,
  }) =>
      (_database.update(_database.mediaAssets)
            ..where((asset) => asset.entityType.equals(fromEntityType))
            ..where((asset) => asset.entityId.equals(fromEntityId))
            ..where((asset) => asset.deletedAt.isNull()))
          .write(
        MediaAssetsCompanion(
          entityType: Value(toEntityType),
          entityId: Value(toEntityId),
        ),
      );

  Future<MediaAsset?> markDeleted(String id) async {
    final record = await (_database.select(_database.mediaAssets)
          ..where((asset) => asset.id.equals(id))
          ..where((asset) => asset.deletedAt.isNull()))
        .getSingleOrNull();
    if (record == null) return null;
    await (_database.update(_database.mediaAssets)..where((asset) => asset.id.equals(id))).write(
      MediaAssetsCompanion(deletedAt: Value(DateTime.now())),
    );
    return _toModel(record);
  }

  Future<int> removeMissingPaths(Set<String> existingPaths) async {
    final active = await loadAllActive();
    final missing = active.where((asset) => !existingPaths.contains(asset.localPath));
    var count = 0;
    for (final asset in missing) {
      await markDeleted(asset.id);
      count++;
    }
    return count;
  }

  List<MediaAsset> _toModels(List<MediaAssetRecord> records) =>
      records.map(_toModel).toList(growable: false);

  MediaAsset _toModel(MediaAssetRecord record) => MediaAsset(
        id: record.id,
        entityType: record.entityType,
        entityId: record.entityId,
        type: MediaAssetType.fromStorageValue(record.mediaType),
        localPath: record.localPath,
        mimeType: record.mimeType,
        sizeBytes: record.sizeBytes,
        width: record.width,
        height: record.height,
        sha256: record.sha256,
        ocrText: record.ocrText,
        ocrUpdatedAt: record.ocrUpdatedAt,
        createdAt: record.createdAt,
      );
}
