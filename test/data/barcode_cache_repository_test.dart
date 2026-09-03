import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/barcode_cache_repository.dart';
import 'package:momo_box/domain/models/recognition_models.dart';

void main() {
  test('barcode cache expires and persists product candidates', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = BarcodeCacheRepository(database);
    final result = const BarcodeLookupResult(
      barcode: '6901234567890',
      source: 'external_api',
      name: '缓存商品',
      category: '食品生鲜',
    );
    await repository.save(result, expiresAt: DateTime(2026, 9, 10));

    expect((await repository.loadFresh(result.barcode, now: DateTime(2026, 9, 3)))?.name, '缓存商品');
    expect(await repository.loadFresh(result.barcode, now: DateTime(2026, 9, 11)), isNull);
    expect(jsonDecode((await database.select(database.barcodeLookupCache).get()).single.payloadJson!)['name'], '缓存商品');
  });
}
