import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../domain/models/recognition_models.dart';


class MediaOcrSearchResult {
  const MediaOcrSearchResult({required this.asset, required this.snippet});

  final MediaAsset asset;
  final String snippet;
}

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

  Future<void> updateOcr(String id, String text) async {
    final normalized = text.trim();
    await _database.transaction(() async {
      await (_database.update(_database.mediaAssets)..where((asset) => asset.id.equals(id))).write(
        MediaAssetsCompanion(
          ocrText: Value(normalized.isEmpty ? null : normalized),
          ocrUpdatedAt: Value(DateTime.now()),
        ),
      );
      await _deleteOcrIndexRow(id);
      if (normalized.isNotEmpty) {
        final asset = await (_database.select(_database.mediaAssets)
              ..where((entry) => entry.id.equals(id)))
            .getSingleOrNull();
        if (asset != null && asset.deletedAt == null) {
          await _database.customStatement(
            'INSERT INTO media_ocr_fts(asset_id, entity_type, entity_id, ocr_text) VALUES (?, ?, ?, ?)',
            [asset.id, asset.entityType, asset.entityId, normalized],
          );
        }
      }
    });
  }

  /// Searches only local OCR text. FTS5 is attempted first; the LIKE fallback
  /// keeps short Chinese queries useful on SQLite builds whose unicode61
  /// tokenizer does not split CJK text into individual terms.
  Future<List<MediaOcrSearchResult>> searchOcr({
    required String entityType,
    required String entityId,
    required String query,
    int limit = 5,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const [];
    final safeLimit = limit.clamp(1, 20);
    final rows = <QueryRow>[];
    final ftsQuery = _ftsQuery(normalizedQuery);
    if (ftsQuery.isNotEmpty) {
      try {
        rows.addAll(
          await _database.customSelect(
            '''
            SELECT m.id, m.entity_type, m.entity_id, m.media_type, m.local_path,
                   m.mime_type, m.size_bytes, m.width, m.height, m.sha256,
                   m.ocr_text, m.ocr_updated_at, m.created_at,
                   snippet(media_ocr_fts, 3, '[', ']', '…', 18) AS snippet_text
            FROM media_ocr_fts
            INNER JOIN media_assets m ON m.id = media_ocr_fts.asset_id
            WHERE media_ocr_fts.entity_type = ?
              AND media_ocr_fts.entity_id = ?
              AND m.deleted_at IS NULL
              AND media_ocr_fts MATCH ?
            ORDER BY m.created_at DESC
            LIMIT ?
            ''',
            variables: [
              Variable.withString(entityType),
              Variable.withString(entityId),
              Variable.withString(ftsQuery),
              Variable.withInt(safeLimit),
            ],
          ).get(),
        );
      } catch (_) {
        // Some older SQLite builds expose FTS5 but reject a malformed token;
        // the local LIKE fallback below remains deterministic and offline.
      }
    }
    if (rows.isEmpty) {
      rows.addAll(
        await _database.customSelect(
          '''
          SELECT m.id, m.entity_type, m.entity_id, m.media_type, m.local_path,
                 m.mime_type, m.size_bytes, m.width, m.height, m.sha256,
                 m.ocr_text, m.ocr_updated_at, m.created_at,
                 substr(m.ocr_text, max(1, instr(lower(m.ocr_text), lower(?)) - 120), 280) AS snippet_text
          FROM media_assets m
          WHERE m.entity_type = ? AND m.entity_id = ?
            AND m.deleted_at IS NULL AND m.ocr_text IS NOT NULL
            AND lower(m.ocr_text) LIKE '%' || lower(?) || '%'
          ORDER BY m.created_at DESC
          LIMIT ?
          ''',
          variables: [
            Variable.withString(normalizedQuery),
            Variable.withString(entityType),
            Variable.withString(entityId),
            Variable.withString(normalizedQuery),
            Variable.withInt(safeLimit),
          ],
        ).get(),
      );
    }

    return rows.map(_toSearchResult).toList(growable: false);
  }

  Future<void> reassignEntity({
    required String fromEntityType,
    required String fromEntityId,
    required String toEntityType,
    required String toEntityId,
  }) async {
    await _database.transaction(() async {
      await (_database.update(_database.mediaAssets)
            ..where((asset) => asset.entityType.equals(fromEntityType))
            ..where((asset) => asset.entityId.equals(fromEntityId))
            ..where((asset) => asset.deletedAt.isNull()))
          .write(
        MediaAssetsCompanion(
          entityType: Value(toEntityType),
          entityId: Value(toEntityId),
        ),
      );
      await _database.customStatement(
        'UPDATE media_ocr_fts SET entity_type = ?, entity_id = ? WHERE entity_type = ? AND entity_id = ?',
        [toEntityType, toEntityId, fromEntityType, fromEntityId],
      );
    });
  }

  Future<MediaAsset?> markDeleted(String id) async {
    final record = await (_database.select(_database.mediaAssets)
          ..where((asset) => asset.id.equals(id))
          ..where((asset) => asset.deletedAt.isNull()))
        .getSingleOrNull();
    if (record == null) return null;
    await _database.transaction(() async {
      await (_database.update(_database.mediaAssets)..where((asset) => asset.id.equals(id))).write(
        MediaAssetsCompanion(deletedAt: Value(DateTime.now())),
      );
      await _deleteOcrIndexRow(id);
    });
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

  Future<void> _deleteOcrIndexRow(String id) =>
      _database.customStatement('DELETE FROM media_ocr_fts WHERE asset_id = ?', [id]);

  String _ftsQuery(String value) {
    final tokens = value
        .split(RegExp(r'[\s,，。！？!?；;、:：()（）\[\]{}<>]+'))
        .map((token) => token.replaceAll('"', '').trim())
        .where((token) => token.isNotEmpty)
        .take(8)
        .map((token) => '"$token"')
        .join(' OR ');
    return tokens;
  }

  MediaOcrSearchResult _toSearchResult(QueryRow row) {
    final asset = MediaAsset(
      id: row.read<String>('id'),
      entityType: row.read<String>('entity_type'),
      entityId: row.read<String>('entity_id'),
      type: MediaAssetType.fromStorageValue(row.read<String>('media_type')),
      localPath: row.read<String>('local_path'),
      mimeType: row.read<String>('mime_type'),
      sizeBytes: row.read<int>('size_bytes'),
      width: row.readNullable<int>('width'),
      height: row.readNullable<int>('height'),
      sha256: row.read<String>('sha256'),
      ocrText: row.readNullable<String>('ocr_text'),
      ocrUpdatedAt: row.readNullable<DateTime>('ocr_updated_at'),
      createdAt: row.read<DateTime>('created_at'),
    );
    final snippet = row.readNullable<String>('snippet_text')?.trim();
    return MediaOcrSearchResult(
      asset: asset,
      snippet: snippet == null || snippet.isEmpty ? (asset.ocrText ?? '') : snippet,
    );
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
