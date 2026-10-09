import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/domain/models/sync_models.dart';

void main() {
  late AppDatabase database;
  late InventoryRepository inventory;
  late String productId;
  late String batchId;
  final now = DateTime.utc(2026, 10, 6);

  Future<SyncRemoteApplyStatus> snapshot(
    Map<String, dynamic> payload, {
    int version = 2,
    String? id,
  }) =>
      inventory.applyRemoteProductBatch(
        batchId: id ?? batchId,
        payload: payload,
        version: version,
        updatedAt: now,
        applyQuantity: true,
        authoritativeSnapshot: true,
      );

  Future<BatchRecord> batch() async => (await inventory.getBatchRecord(batchId))!;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    inventory = InventoryRepository(database);
    productId = await inventory.createProductWithBatch(const IntakeDraft(
      name: '快照物品',
      category: '其他',
      quantity: 3,
    ));
    batchId = (await database.select(database.productBatches).get()).single.id;
    await (database.update(database.productBatches)
          ..where((row) => row.id.equals(batchId)))
        .write(const ProductBatchesCompanion(serverVersion: Value(2)));
  });

  tearDown(() => database.close());

  test('权威快照同版本修复数量元数据与initial且重放不生成流水', () async {
    final beforeMovements = await database.select(database.stockMovements).get();
    final payload = <String, dynamic>{
      'quantity': 8,
      'initial_quantity': 10,
      'batch_no': 'remote',
    };
    expect(await snapshot(payload), SyncRemoteApplyStatus.applied);
    var row = await batch();
    expect(row.remainingQuantity, 8);
    expect(row.initialQuantity, 10);
    expect(row.serverVersion, 2);
    expect(row.batchNo, 'remote');
    expect(await snapshot(payload), SyncRemoteApplyStatus.applied);
    row = await batch();
    expect(row.remainingQuantity, 8);
    expect(row.initialQuantity, 10);
    final afterMovements = await database.select(database.stockMovements).get();
    expect(afterMovements.map((entry) => entry.id), beforeMovements.map((entry) => entry.id));
  });

  test('快照缺失initial时提高到remaining所需下限并非累加', () async {
    await snapshot({'quantity': 8});
    expect((await batch()).initialQuantity, 8);
    expect((await batch()).remainingQuantity, 8);
    await snapshot({'quantity': 8});
    expect((await batch()).initialQuantity, 8);
    await snapshot({'quantity': 2}, version: 3);
    final row = await batch();
    expect(row.initialQuantity, 8);
    expect(row.remainingQuantity, 2);
    expect(row.serverVersion, 3);
  });

  test('快照真实initial存在时采用真实值且数量版本共同更新', () async {
    await snapshot({'quantity': 1, 'initial_quantity': 2}, version: 3);
    final row = await batch();
    expect(row.remainingQuantity, 1);
    expect(row.initialQuantity, 2);
    expect(row.serverVersion, 3);
  });

  test('NAS 0006修复后完整批次行通过严格initial校验并收敛版本', () async {
    await snapshot({
      'id': batchId, 'product_id': productId, 'quantity': 3,
      'initial_quantity': 5, 'status': 'active', 'version': 3,
      'created_at': now.toIso8601String(), 'updated_at': now.toIso8601String(),
      'deleted_at': null,
    }, version: 3);
    final row = await batch();
    expect(row.remainingQuantity, 3);
    expect(row.initialQuantity, 5);
    expect(row.serverVersion, 3);
    // The old, broken NAS row must still fail closed, not relax validation.
    await expectLater(snapshot({'quantity': 3, 'initial_quantity': 0}, version: 4),
      throwsFormatException);
    expect((await batch()).serverVersion, 3);
  });

  test('新批次initial缺省为quantity且支持零数量', () async {
    await snapshot({'product_id': productId, 'quantity': 0}, id: 'new-batch');
    final row = (await inventory.getBatchRecord('new-batch'))!;
    expect(row.remainingQuantity, 0);
    expect(row.initialQuantity, 0);
    expect(row.serverVersion, 2);
  });

  test('超出真实initial或非法数量整体拒绝且不推进版本', () async {
    for (final payload in <Map<String, dynamic>>[
      {'quantity': 8, 'initial_quantity': 7},
      {'quantity': 0, 'initial_quantity': -1},
      {'quantity': -1},
      {'initial_quantity': 8},
      {'quantity': 3.5},
      {'quantity': 3, 'initial_quantity': null},
    ]) {
      await expectLater(snapshot(payload, version: 3), throwsFormatException);
      final row = await batch();
      expect(row.remainingQuantity, 3);
      expect(row.initialQuantity, 3);
      expect(row.serverVersion, 2);
    }
    await expectLater(
      snapshot({'product_id': productId, 'quantity': 8, 'initial_quantity': 7}, id: 'invalid'),
      throwsFormatException,
    );
    expect(await inventory.getBatchRecord('invalid'), isNull);
  });

  test('NAS status 报废与恢复参与同版本权威修复', () async {
    await snapshot({'quantity': 0, 'status': 'discarded'});
    expect((await batch()).isDiscarded, isTrue);
    await snapshot({'quantity': 3, 'status': 'active'});
    expect((await batch()).isDiscarded, isFalse);
    expect((await batch()).remainingQuantity, 3);
    await snapshot({'quantity': 0, 'status': 'used_up'});
    expect((await batch()).isDiscarded, isFalse);
    expect((await batch()).remainingQuantity, 0);
  });

  test('未知状态、终态非零数量和冲突报废标记拒绝且不推进版本', () async {
    for (final payload in <Map<String, dynamic>>[
      {'quantity': 3, 'status': 'unknown'},
      {'quantity': 3, 'status': 'discarded'},
      {'quantity': 3, 'status': 'used_up'},
      {'quantity': 0, 'status': 'discarded', 'is_discarded': false},
    ]) {
      await expectLater(snapshot(payload, version: 3), throwsFormatException);
      final row = await batch();
      expect(row.remainingQuantity, 3);
      expect(row.serverVersion, 2);
      expect(row.isDiscarded, isFalse);
    }
  });

  test('权威快照不绕过旧版本保护', () async {
    expect(
      await snapshot({'quantity': 8, 'initial_quantity': 10}, version: 1),
      SyncRemoteApplyStatus.ignoredStale,
    );
    final row = await batch();
    expect(row.remainingQuantity, 3);
    expect(row.initialQuantity, 3);
    expect(row.serverVersion, 2);
  });

  test('普通entity upsert仍忽略同版本且默认不改旧批次数量', () async {
    expect(
      await inventory.applyRemoteProductBatch(
        batchId: batchId,
        payload: {'quantity': 8, 'batch_no': 'same-version'},
        version: 2,
        updatedAt: now,
        applyQuantity: true,
      ),
      SyncRemoteApplyStatus.alreadyApplied,
    );
    expect((await batch()).remainingQuantity, 3);
    expect((await batch()).batchNo, isNull);
    expect(
      await inventory.applyRemoteProductBatch(
        batchId: batchId,
        payload: {'quantity': 8, 'batch_no': 'next-version'},
        version: 3,
        updatedAt: now,
      ),
      SyncRemoteApplyStatus.applied,
    );
    final row = await batch();
    expect(row.remainingQuantity, 3);
    expect(row.serverVersion, 3);
    expect(row.batchNo, 'next-version');
  });

  test('快照即使包含restock字样也不按分配数量累加initial', () async {
    await snapshot({
      'quantity': 8,
      'command': 'restock',
      'allocations': [{'batch_id': batchId, 'quantity': 50}],
    });
    expect((await batch()).initialQuantity, 8);
    await snapshot({
      'quantity': 8,
      'initial_quantity': 10,
      'command': 'restock',
      'allocations': [{'batch_id': batchId, 'quantity': 50}],
    });
    expect((await batch()).initialQuantity, 10);
  });

  test('快照不能只推进版本而忘记应用权威数量', () async {
    await expectLater(
      inventory.applyRemoteProductBatch(
        batchId: batchId,
        payload: {'quantity': 8},
        version: 3,
        updatedAt: now,
        authoritativeSnapshot: true,
      ),
      throwsArgumentError,
    );
    final row = await batch();
    expect(row.serverVersion, 2);
    expect(row.remainingQuantity, 3);
  });
}
