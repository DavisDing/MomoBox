import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/reminder_repository.dart';
import 'package:momo_box/domain/inventory/expiry_rules.dart';
import 'package:momo_box/domain/inventory/reminder_rules.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

void main() {
  late AppDatabase database;
  late InventoryRepository inventory;
  late ReminderRepository reminders;
  late String productId;
  late DateTime today;

  Future<void> apply(
    String id,
    Map<String, dynamic> payload, {
    String scope = 'family',
    bool deleted = false,
  }) =>
      reminders.applyRemoteSettings(
        scopeId: scope,
        entityId: id,
        payload: payload,
        updatedAt: today.toUtc(),
        deleted: deleted,
      );

  Future<InventoryItem> load() async => (await inventory.loadInventory()).single;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    reminders = ReminderRepository(database);
    inventory = InventoryRepository(database, syncScopeId: 'family');
    today = ExpiryRules.dateOnly(DateTime.now());
    productId = await inventory.createProductWithBatch(IntakeDraft(
      name: '牛奶',
      category: '食品',
      quantity: 3,
      lowStockThreshold: 1,
      expiryDate: today.add(const Duration(days: 10)),
    ));
  });

  tearDown(() => database.close());

  test('没有覆盖层时商品批次与提醒仍使用默认三十天', () async {
    final item = await load();
    expect(item.reminderPolicy.enabled, isTrue);
    expect(item.reminderPolicy.expiryWarningDays, 30);
    expect(item.lowStockThreshold, 1);
    expect(item.batches.single.expiryStatus, ExpiryStatus.expiring);
    expect(item.overallExpiryStatus, ExpiryStatus.expiring);
    expect(
      ReminderRules.visibleCandidates([item], const [], today: today)
          .single.type,
      ReminderType.expiring,
    );
  });

  test('缺省远端字段存完整三十天策略', () async {
    await apply('default', const {});
    final row = (await database.select(database.appSettings).get()).single;
    expect(jsonDecode(row.value), {
      'product_id': null,
      'enabled': true,
      'expiry_warning_days': 30,
      'low_stock_threshold': null,
      'opened_warning_days': null,
    });
    final item = await load();
    expect(item.reminderPolicy.expiryWarningDays, 30);
    expect(item.lowStockThreshold, 1);
  });

  test('已有七天家庭配置保留并贯通批次状态整体状态及通知', () async {
    await apply('default', const {
      'enabled': true,
      'expiry_warning_days': 7,
      'low_stock_threshold': 2,
    });
    final item = await load();
    expect(item.reminderPolicy.expiryWarningDays, 7);
    expect(item.lowStockThreshold, 2);
    expect(item.batches.single.expiryStatus, ExpiryStatus.safe);
    expect(item.overallExpiryStatus, ExpiryStatus.safe);
    expect(ReminderRules.visibleCandidates([item], const [], today: today), isEmpty);
    final scheduled = ReminderRules.unacknowledgedCandidates(
      [item], const [], today: today,
    );
    expect(scheduled.first.date, today.add(const Duration(days: 3)));
    expect(scheduled.last.date, today.add(const Duration(days: 11)));
    final stored = (await database.select(database.appSettings).get()).single;
    expect((jsonDecode(stored.value) as Map)['expiry_warning_days'], 7);
  });

  test('商品策略优先于家庭策略包括禁用及临期窗口', () async {
    await apply('default', const {
      'enabled': false,
      'expiry_warning_days': 7,
      'low_stock_threshold': 2,
    });
    await apply('product-policy', {
      'product_id': productId,
      'enabled': true,
      'expiry_warning_days': 15,
      'low_stock_threshold': 4,
    });
    final item = await load();
    expect(item.reminderPolicy.enabled, isTrue);
    expect(item.reminderPolicy.expiryWarningDays, 15);
    expect(item.lowStockThreshold, 4);
    expect(item.batches.single.expiryStatus, ExpiryStatus.expiring);
    expect(item.overallExpiryStatus, ExpiryStatus.expiring);
    expect(
      ReminderRules.visibleCandidates([item], const [], today: today)
          .map((entry) => entry.type),
      containsAll([ReminderType.expiring, ReminderType.lowStock]),
    );
  });

  test('商品空阈值继承家庭阈值并保留本地原阈值', () async {
    await apply('default', const {'low_stock_threshold': 5});
    await apply('product-policy', {
      'product_id': productId,
      'expiry_warning_days': 7,
      'low_stock_threshold': null,
    });
    final item = await load();
    expect(item.lowStockThreshold, 5);
    expect(item.reminderPolicy.expiryWarningDays, 7);
    expect((await inventory.getProductRecord(productId))!.lowStockThreshold, 1);
  });

  test('删除商品覆盖恢复家庭设置再删除家庭恢复三十天与商品阈值', () async {
    await apply('default', const {
      'enabled': false,
      'expiry_warning_days': 7,
      'low_stock_threshold': 2,
    });
    await apply('product-policy', {
      'product_id': productId,
      'expiry_warning_days': 20,
      'low_stock_threshold': 4,
    });
    expect((await load()).lowStockThreshold, 4);
    await apply('product-policy', const {}, deleted: true);
    final family = await load();
    expect(family.lowStockThreshold, 2);
    expect(family.reminderPolicy.enabled, isFalse);
    expect(family.reminderPolicy.expiryWarningDays, 7);
    await apply('default', const {}, deleted: true);
    final fallback = await load();
    expect(fallback.lowStockThreshold, 1);
    expect(fallback.reminderPolicy.enabled, isTrue);
    expect(fallback.reminderPolicy.expiryWarningDays, 30);
    expect(await database.select(database.appSettings).get(), isEmpty);
  });

  test('家庭禁用不隐藏现存库存或过期事实但通知候选全部停止', () async {
    final batch = (await database.select(database.productBatches).get()).single;
    await (database.update(database.productBatches)
          ..where((row) => row.id.equals(batch.id)))
        .write(ProductBatchesCompanion(
      expiryDate: Value(today.subtract(const Duration(days: 1))),
    ));
    await apply('default', const {
      'enabled': false,
      'expiry_warning_days': 7,
      'low_stock_threshold': 4,
    });
    final item = await load();
    expect(item.totalStock, 3);
    expect(item.isLowStock, isTrue);
    expect(item.activeBatches, hasLength(1));
    expect(item.batches.single.expiryStatus, ExpiryStatus.expired);
    expect(item.overallExpiryStatus, ExpiryStatus.expired);
    expect(item.availableQuantity, 0);
    expect(ReminderRules.candidates([item], today: today), isEmpty);
    expect(ReminderRules.visibleCandidates([item], const [], today: today), isEmpty);
    expect(
      ReminderRules.unacknowledgedCandidates([item], const [], today: today),
      isEmpty,
    );
  });

  test('商品禁用只影响目标商品而不是全家庭', () async {
    final otherId = await inventory.createProductWithBatch(IntakeDraft(
      name: '鸡蛋',
      category: '食品',
      quantity: 1,
      expiryDate: today.add(const Duration(days: 5)),
    ));
    await apply('product-policy', {
      'product_id': productId,
      'enabled': false,
      'expiry_warning_days': 7,
    });
    final items = await inventory.loadInventory();
    expect(items, hasLength(2));
    expect(items.firstWhere((item) => item.id == productId).totalStock, 3);
    final candidates = ReminderRules.unacknowledgedCandidates(
      items, const [], today: today,
    );
    expect(candidates, isNotEmpty);
    expect(candidates.map((entry) => entry.item.id).toSet(), {otherId});
  });

  test('重新启用恢复候选且低库存确认不会被禁用本身清除', () async {
    await reminders.acknowledge(
      reminderKey: '$productId:low-stock',
      fingerprint: 'threshold:4',
    );
    await apply('default', const {'enabled': false, 'low_stock_threshold': 4});
    final disabled = await load();
    await reminders.clearRecoveredLowStockAcknowledgements([disabled]);
    expect(await database.select(database.reminderAcknowledgments).get(), hasLength(1));
    expect(ReminderRules.candidates([disabled], today: today), isEmpty);
    await apply('default', const {'enabled': true, 'low_stock_threshold': 4});
    final enabled = await load();
    expect(ReminderRules.candidates([enabled], today: today), hasLength(3));
  });

  test('库存监听在仅设置改变后发布新有效策略', () async {
    final stream = StreamIterator(inventory.watchInventory());
    addTearDown(stream.cancel);
    expect(await stream.moveNext(), isTrue);
    expect(stream.current.single.reminderPolicy.expiryWarningDays, 30);
    await apply('default', const {'enabled': false, 'expiry_warning_days': 7});
    expect(await stream.moveNext(), isTrue);
    expect(stream.current.single.reminderPolicy.expiryWarningDays, 7);
    expect(stream.current.single.reminderPolicy.enabled, isFalse);
    expect(
      ReminderRules.unacknowledgedCandidates(stream.current, const [], today: today),
      isEmpty,
    );
  });

  test('窗口和阈值更新会改变通知指纹而不沿用旧确认', () async {
    await apply('default', const {'low_stock_threshold': 4});
    final original = await load();
    final oldCandidates = ReminderRules.candidates([original], today: today);
    final oldExpiry = oldCandidates.firstWhere((entry) => entry.type == ReminderType.expiring);
    final oldLow = oldCandidates.firstWhere((entry) => entry.type == ReminderType.lowStock);
    await reminders.acknowledgeAll([
      (reminderKey: oldExpiry.key, fingerprint: oldExpiry.fingerprint),
      (reminderKey: oldLow.key, fingerprint: oldLow.fingerprint),
    ]);
    final acknowledgements = await reminders.watchAcknowledgements().first;
    expect(
      ReminderRules.visibleCandidates([original], acknowledgements, today: today),
      isEmpty,
    );
    await apply('default', const {
      'expiry_warning_days': 15,
      'low_stock_threshold': 5,
    });
    final updated = await load();
    final newCandidates = ReminderRules.visibleCandidates(
      [updated], acknowledgements, today: today,
    );
    expect(newCandidates, hasLength(2));
    expect(
      newCandidates.firstWhere((entry) => entry.type == ReminderType.expiring).fingerprint,
      isNot(oldExpiry.fingerprint),
    );
    expect(
      newCandidates.firstWhere((entry) => entry.type == ReminderType.lowStock).fingerprint,
      'threshold:5',
    );
  });

  test('其他家庭和无同步作用域的库存不消费该覆盖层', () async {
    await apply('default', const {'enabled': false, 'expiry_warning_days': 7});
    await apply('default', const {'expiry_warning_days': 2}, scope: 'other');
    final other = InventoryRepository(database, syncScopeId: 'other');
    final local = InventoryRepository(database);
    expect((await other.loadInventory()).single.reminderPolicy.expiryWarningDays, 2);
    expect((await local.loadInventory()).single.reminderPolicy.expiryWarningDays, 30);
    expect((await local.loadInventory()).single.reminderPolicy.enabled, isTrue);
  });

  test('旧版仅阈值覆盖层按原三十天行为读取', () async {
    await database.into(database.appSettings).insert(AppSettingsCompanion.insert(
      key: 'reminder_sync_policy:family:legacy',
      value: jsonEncode({'product_id': null, 'low_stock_threshold': 4}),
      updatedAt: today,
    ));
    final item = await load();
    expect(item.lowStockThreshold, 4);
    expect(item.reminderPolicy.enabled, isTrue);
    expect(item.reminderPolicy.expiryWarningDays, 30);
    expect(ReminderRules.candidates([item], today: today), hasLength(3));
  });

  test('非空开封策略即使 disabled 仍显式失败且保留原策略', () async {
    await apply('default', const {'expiry_warning_days': 7});
    await expectLater(
      apply('default', const {
        'enabled': false,
        'opened_warning_days': 0,
        'expiry_warning_days': 15,
      }),
      throwsA(isA<FormatException>().having(
        (error) => error.message, 'message', contains('opened_warning_days'),
      )),
    );
    final item = await load();
    expect(item.reminderPolicy.expiryWarningDays, 7);
    expect(item.reminderPolicy.enabled, isTrue);
  });

  test('重复有效商品策略拒绝且删除旧策略后允许替换', () async {
    await apply('first', {'product_id': productId, 'expiry_warning_days': 7});
    await expectLater(
      apply('second', {'product_id': productId, 'expiry_warning_days': 15}),
      throwsFormatException,
    );
    expect((await load()).reminderPolicy.expiryWarningDays, 7);
    await apply('first', const {}, deleted: true);
    await apply('second', {'product_id': productId, 'expiry_warning_days': 15});
    expect((await load()).reminderPolicy.expiryWarningDays, 15);
  });

  test('无效类型或负数窗口与无效阈值不产生覆盖层', () async {
    for (final payload in <Map<String, dynamic>>[
      {'expiry_warning_days': -1},
      {'expiry_warning_days': 7.0},
      {'expiry_warning_days': null},
      {'enabled': 'false'},
      {'enabled': null},
      {'low_stock_threshold': 0},
      {'low_stock_threshold': 1.5},
      {'product_id': ' '},
    ]) {
      await expectLater(apply('default', payload), throwsFormatException);
      expect(await database.select(database.appSettings).get(), isEmpty);
    }
  });
}
