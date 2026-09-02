import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/reminder_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

InventoryItem inventoryItem(String id, {required int stock, int threshold = 1}) => InventoryItem(
      id: id,
      name: id,
      category: '其他物品',
      brand: null,
      specification: null,
      barcode: null,
      location: null,
      unit: '件',
      lowStockThreshold: threshold,
      batches: [
        InventoryBatch(
          id: '$id-batch',
          productId: id,
          batchNo: null,
          initialQuantity: stock,
          remainingQuantity: stock,
          isDiscarded: false,
          expiryDate: null,
          productionDate: null,
        ),
      ],
    );

void main() {
  late AppDatabase database;
  late ReminderRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = ReminderRepository(database);
  });

  tearDown(() => database.close());

  test('单条标记已处理会写入提醒记录', () async {
    await repository.acknowledge(
      reminderKey: 'product-1:low-stock',
      fingerprint: 'threshold:1',
    );

    final records = await database.select(database.reminderAcknowledgments).get();
    expect(records, hasLength(1));
    expect(records.single.reminderKey, 'product-1:low-stock');
    expect(records.single.fingerprint, 'threshold:1');
  });

  test('同一提醒再次标记会更新 fingerprint 而不是新增记录', () async {
    await repository.acknowledge(
      reminderKey: 'product-1:low-stock',
      fingerprint: 'threshold:1',
    );
    await repository.acknowledge(
      reminderKey: 'product-1:low-stock',
      fingerprint: 'threshold:2',
    );

    final records = await database.select(database.reminderAcknowledgments).get();
    expect(records, hasLength(1));
    expect(records.single.fingerprint, 'threshold:2');
  });

  test('批量标记已处理会一次写入多条记录', () async {
    await repository.acknowledgeAll([
      (reminderKey: 'product-1:low-stock', fingerprint: 'threshold:1'),
      (reminderKey: 'product-2:expired', fingerprint: 'batch-2:2026-08-01'),
    ]);

    final records = await database.select(database.reminderAcknowledgments).get();
    expect(records, hasLength(2));
  });

  test('拒绝空提醒 key 或空 fingerprint', () async {
    expect(
      () => repository.acknowledge(reminderKey: ' ', fingerprint: 'threshold:1'),
      throwsArgumentError,
    );
    expect(
      () => repository.acknowledge(reminderKey: 'product-1:low-stock', fingerprint: ' '),
      throwsArgumentError,
    );
  });

  test('库存恢复到阈值以上时清除低库存确认，重新跌破后可再次提醒', () async {
    await repository.acknowledge(
      reminderKey: 'product-1:low-stock',
      fingerprint: 'threshold:1',
    );

    await repository.clearRecoveredLowStockAcknowledgements([
      inventoryItem('product-1', stock: 2),
    ]);
    expect(await database.select(database.reminderAcknowledgments).get(), isEmpty);

    await repository.acknowledge(
      reminderKey: 'product-1:low-stock',
      fingerprint: 'threshold:1',
    );
    await repository.clearRecoveredLowStockAcknowledgements([
      inventoryItem('product-1', stock: 1),
    ]);
    expect(
      await database.select(database.reminderAcknowledgments).get(),
      hasLength(1),
    );
  });
}
