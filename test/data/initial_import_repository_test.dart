import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/backup_repository.dart';
import 'package:momo_box/data/repositories/calendar_date_repository.dart';
import 'package:momo_box/data/repositories/initial_import_repository.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/sync_category_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/domain/models/nas_import_models.dart';

void main() {
  test('v5 upgrade adds queryable import state and nullable calendar columns without guessing old dates', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory(setup: (sqlite) {
      sqlite.execute('CREATE TABLE product_batches(id TEXT PRIMARY KEY,expiry_date INTEGER,remaining_quantity INTEGER)');
      sqlite.execute("INSERT INTO product_batches VALUES('legacy',1792627200,5)");
      sqlite.execute('PRAGMA user_version=5');
    }));
    addTearDown(database.close);
    final legacy = await database.customSelect('SELECT * FROM product_batches').getSingle();
    expect(legacy.read<int>('remaining_quantity'), 5);
    expect(legacy.readNullable<String>('expiry_date_calendar'), isNull);
    final tables = await database.customSelect("SELECT name FROM sqlite_master WHERE name LIKE 'sync_initial_import_%'").get();
    expect(tables.map((row) => row.read<String>('name')).toSet(),
      containsAll(['sync_initial_import_plans', 'sync_initial_import_items', 'sync_initial_import_scope']));
    expect((await database.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 6);
  });

  test('real auxiliary category envelope preserves id and metadata; tombstones are excluded', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final outbox = SyncOutboxRepository(database);
    await outbox.applyRemoteAuxiliaryEntity(scopeId: 'family', entity: 'categories',
      entityId: 'stable-category', payload: {'name': '食品', 'color': '#aabbcc', 'sort_order': -4},
      version: 1, updatedAt: DateTime.utc(2026, 10, 22));
    final categories = await SyncCategoryRepository(database).remoteCategories('family');
    expect(categories.single, {'id': 'stable-category', 'name': '食品', 'color': '#aabbcc', 'sort_order': -4});
    await outbox.applyRemoteAuxiliaryEntity(scopeId: 'family', entity: 'categories',
      entityId: 'stable-category', payload: {}, version: 2,
      updatedAt: DateTime.utc(2026, 10, 23), deletedAt: DateTime.utc(2026, 10, 23));
    expect(await SyncCategoryRepository(database).remoteCategories('family'), isEmpty);
  });

  test('canonical dates survive core v3 backup while NAS archive is expressly excluded', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final target = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    addTearDown(target.close);
    await InventoryRepository(database).createProductWithBatch(IntakeDraft(name: '米', category: '食品',
      quantity: 5, productionDate: DateTime.utc(2026, 10, 22), expiryDate: DateTime.utc(2027, 10, 22)));
    final batch = await database.select(database.productBatches).getSingle();
    await InitialImportRepository(database).saveHistoryPage('family', const NasImportHistoryPage(
      records: [{'id': 'archive-only', 'cursor': 1, 'quantity': -2}],
      nextCursor: 1, until: 1, hasMore: false));
    final content = await BackupRepository(database).exportJson();
    final document = jsonDecode(content) as Map;
    expect(document['version'], 3);
    expect((document['batches'] as List).single['production_date'], '2026-10-22');
    expect((document['coverage'] as Map)['excludes'], contains('sync_imported_history'));
    expect(content, isNot(contains('archive-only')));
    await BackupRepository(target).importJson(content);
    expect(await CalendarDateRepository(target).read(batch.id),
      {'produced_date': '2026-10-22', 'expiry_date': '2027-10-22'});
    expect(await InitialImportRepository(target).history('family'), isEmpty);
  });
}
