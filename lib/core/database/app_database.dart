import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

@DataClassName('ProductRecord')
class Products extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get category => text()();
  TextColumn get brand => text().nullable()();
  TextColumn get specification => text().nullable()();
  TextColumn get barcode => text().nullable()();
  TextColumn get location => text().nullable()();
  TextColumn get unit => text().withDefault(const Constant('件'))();
  IntColumn get lowStockThreshold => integer().withDefault(const Constant(1))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get serverVersion => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get updatedByDevice => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('BatchRecord')
class ProductBatches extends Table {
  TextColumn get id => text()();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get batchNo => text().nullable()();
  DateTimeColumn get productionDate => dateTime().nullable()();
  DateTimeColumn get expiryDate => dateTime().nullable()();
  TextColumn get dateSource => text().withDefault(const Constant('manual'))();
  TextColumn get datePrecision => text().withDefault(const Constant('day'))();
  IntColumn get initialQuantity => integer()();
  IntColumn get remainingQuantity => integer()();
  BoolColumn get isOpened => boolean().withDefault(const Constant(false))();
  BoolColumn get isDiscarded => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get serverVersion => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get updatedByDevice => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('StockMovementRecord')
class StockMovements extends Table {
  TextColumn get id => text()();
  TextColumn get productId => text().references(Products, #id)();
  TextColumn get batchId => text().nullable().references(ProductBatches, #id)();
  TextColumn get type => text()();
  IntColumn get quantity => integer()();
  TextColumn get note => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ShoppingEntryRecord')
class ShoppingEntries extends Table {
  TextColumn get id => text()();
  TextColumn get productId => text().nullable().references(Products, #id)();
  TextColumn get itemName => text()();
  TextColumn get category => text().nullable()();
  IntColumn get targetQuantity => integer().withDefault(const Constant(1))();
  TextColumn get reason => text().withDefault(const Constant('手动添加'))();
  BoolColumn get isCompleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  IntColumn get serverVersion => integer().withDefault(const Constant(0))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get updatedByDevice => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}


@DataClassName('ReminderAcknowledgmentRecord')
class ReminderAcknowledgments extends Table {
  TextColumn get reminderKey => text()();
  TextColumn get fingerprint => text()();
  DateTimeColumn get acknowledgedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {reminderKey};
}

@DataClassName('BarcodeCacheRecord')
class BarcodeLookupCache extends Table {
  TextColumn get barcode => text()();
  TextColumn get payloadJson => text().nullable()();
  TextColumn get source => text()();
  DateTimeColumn get fetchedAt => dateTime()();
  DateTimeColumn get expiresAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {barcode};
}

@DataClassName('MediaAssetRecord')
class MediaAssets extends Table {
  TextColumn get id => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get mediaType => text()();
  TextColumn get localPath => text()();
  TextColumn get mimeType => text()();
  IntColumn get sizeBytes => integer()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  TextColumn get sha256 => text()();
  TextColumn get ocrText => text().nullable()();
  DateTimeColumn get ocrUpdatedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('AppSettingRecord')
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}


@DataClassName('SyncStateRecord')
class SyncStates extends Table {
  TextColumn get scopeId => text()();
  TextColumn get familyId => text().nullable()();
  TextColumn get deviceId => text().nullable()();
  TextColumn get localWorkspaceId => text().nullable()();
  TextColumn get bootstrapStatus =>
      text().withDefault(const Constant('unconfigured'))();
  IntColumn get pullCursor => integer().withDefault(const Constant(0))();
  IntColumn get pushAckCursor => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastPushAt => dateTime().nullable()();
  DateTimeColumn get lastPullAt => dateTime().nullable()();
  DateTimeColumn get lastSuccessAt => dateTime().nullable()();
  TextColumn get lastErrorCode => text().nullable()();
  TextColumn get lastErrorMessage => text().nullable()();
  IntColumn get consecutiveFailures => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextRetryAt => dateTime().nullable()();
  IntColumn get serverSchemaVersion => integer().nullable()();
  IntColumn get syncProtocolVersion => integer().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {scopeId};
}

@DataClassName('SyncOutboxRecord')
class SyncOutbox extends Table {
  TextColumn get changeId => text()();
  TextColumn get scopeId => text()();
  TextColumn get operation => text()();
  TextColumn get entity => text().nullable()();
  TextColumn get entityId => text().nullable()();
  IntColumn get baseVersion => integer().withDefault(const Constant(0))();
  TextColumn get operationId => text().nullable()();
  TextColumn get integrationId => text().nullable()();
  TextColumn get command => text().nullable()();
  TextColumn get idempotencyKey => text()();
  TextColumn get requestJson => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();
  TextColumn get lastErrorCode => text().nullable()();
  TextColumn get lastErrorMessage => text().nullable()();
  IntColumn get serverCursor => integer().nullable()();
  IntColumn get serverVersion => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {changeId};
}

@DataClassName('SyncConflictRecord')
class SyncConflicts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get scopeId => text()();
  TextColumn get changeId => text()();
  TextColumn get outboxChangeId => text().nullable()();
  TextColumn get entity => text()();
  TextColumn get entityId => text().nullable()();
  TextColumn get reason => text()();
  IntColumn get serverVersion => integer().nullable()();
  TextColumn get serverPayloadJson => text().nullable()();
  TextColumn get clientPayloadJson => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('open'))();
  TextColumn get resolution => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get resolvedAt => dateTime().nullable()();
}

@DataClassName('SyncAppliedChangeRecord')
class SyncAppliedChanges extends Table {
  TextColumn get scopeId => text()();
  TextColumn get changeId => text()();
  IntColumn get cursor => integer()();
  DateTimeColumn get appliedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {scopeId, changeId};
}

@DriftDatabase(
  tables: [
    Products,
    ProductBatches,
    StockMovements,
    ShoppingEntries,
    AppSettings,
    ReminderAcknowledgments,
    BarcodeLookupCache,
    MediaAssets,
    SyncStates,
    SyncOutbox,
    SyncConflicts,
    SyncAppliedChanges,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) async => migrator.createAll(),
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            await migrator.createTable(reminderAcknowledgments);
          }
          if (from < 3) {
            await migrator.createTable(barcodeLookupCache);
            await migrator.createTable(mediaAssets);
          }
          if (from < 4) {
            await migrator.addColumn(products, products.serverVersion);
            await migrator.addColumn(products, products.deletedAt);
            await migrator.addColumn(products, products.updatedByDevice);
            await migrator.addColumn(productBatches, productBatches.serverVersion);
            await migrator.addColumn(productBatches, productBatches.deletedAt);
            await migrator.addColumn(productBatches, productBatches.updatedByDevice);
            await migrator.addColumn(shoppingEntries, shoppingEntries.serverVersion);
            await migrator.addColumn(shoppingEntries, shoppingEntries.deletedAt);
            await migrator.addColumn(shoppingEntries, shoppingEntries.updatedByDevice);
            await migrator.createTable(syncStates);
            await migrator.createTable(syncOutbox);
            await migrator.createTable(syncConflicts);
            await migrator.createTable(syncAppliedChanges);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File(p.join(directory.path, 'momobox.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
