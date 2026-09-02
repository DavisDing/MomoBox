import 'dart:async';
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

@DataClassName('AppSettingRecord')
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

@DriftDatabase(
  tables: [Products, ProductBatches, StockMovements, ShoppingEntries, AppSettings, ReminderAcknowledgments],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(QueryExecutor executor) : super(executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) async => migrator.createAll(),
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            await migrator.createTable(reminderAcknowledgments);
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
