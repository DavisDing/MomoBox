import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';
import '../../domain/models/recognition_models.dart';

class BarcodeCacheUsage {
  const BarcodeCacheUsage({required this.entries, required this.bytes});

  final int entries;
  final int bytes;
}

class BarcodeCacheRepository {
  BarcodeCacheRepository(this._database);

  final AppDatabase _database;

  Future<BarcodeLookupResult?> loadFresh(String barcode, {DateTime? now}) async {
    final record = await (_database.select(_database.barcodeLookupCache)
          ..where((row) => row.barcode.equals(barcode)))
        .getSingleOrNull();
    if (record == null || !record.expiresAt.isAfter(now ?? DateTime.now())) return null;
    return _fromRecord(record);
  }

  Future<void> save(
    BarcodeLookupResult result, {
    required DateTime expiresAt,
  }) async {
    await _database.into(_database.barcodeLookupCache).insertOnConflictUpdate(
          BarcodeLookupCacheCompanion.insert(
            barcode: result.barcode,
            payloadJson: Value(jsonEncode(result.toJson())),
            source: result.source,
            fetchedAt: DateTime.now(),
            expiresAt: expiresAt,
          ),
        );
  }

  Future<int> purgeExpired({DateTime? now}) =>
      (_database.delete(_database.barcodeLookupCache)
            ..where((row) => row.expiresAt.isSmallerOrEqualValue(now ?? DateTime.now())))
          .go();

  Future<int> clearAll() => _database.delete(_database.barcodeLookupCache).go();

  Future<BarcodeCacheUsage> usage() async {
    final rows = await _database.select(_database.barcodeLookupCache).get();
    return BarcodeCacheUsage(
      entries: rows.length,
      bytes: rows.fold<int>(0, (sum, row) => sum + utf8.encode(row.payloadJson ?? '').length),
    );
  }

  BarcodeLookupResult? _fromRecord(BarcodeCacheRecord record) {
    final payload = record.payloadJson;
    if (payload == null) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic>) return null;
      return BarcodeLookupResult.fromJson(
        barcode: record.barcode,
        source: record.source,
        json: decoded,
      );
    } on FormatException {
      return null;
    }
  }
}
