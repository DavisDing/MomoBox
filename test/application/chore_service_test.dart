import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/chore_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/domain/models/chore_models.dart';

void main() {
  late AppDatabase database;
  late SettingsRepository settings;
  final day = DateTime(2026, 9, 15);

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsRepository(database);
  });
  tearDown(() => database.close());

  test('只订阅家务也会保存预设，重启后到期日不后移', () async {
    final service = ChoreService(settings, clock: () => day);
    final first = await service.watchChores().first;
    final raw = await settings.getValue('recurring_chores_list');
    expect(raw, isNotNull);
    expect(ChoreItem.encodeList(first), raw);

    final restarted = ChoreService(settings, clock: () => day.add(const Duration(days: 10)));
    final restored = await restarted.watchChores().first;
    expect(ChoreItem.encodeList(restored), raw);
    expect(restored.map((item) => item.nextDueDate), first.map((item) => item.nextDueDate));
  });

  test('同时订阅和读取只初始化一次，不覆盖已保存的空列表', () async {
    var clockCalls = 0;
    final service = ChoreService(settings, clock: () {
      clockCalls++;
      return day;
    });
    final results = await Future.wait([
      service.watchChores().first,
      service.watchChores().first,
      service.getChores(),
    ]);
    expect(clockCalls, 1);
    expect(results.map(ChoreItem.encodeList).toSet(), hasLength(1));
    await settings.setValue('recurring_chores_list', '[]');
    expect(await service.watchChores().first, isEmpty);
    expect(clockCalls, 1);
  });

  test('默认家务写入失败必须报错，下次读取可重试', () async {
    final failing = _FailOnceSettings(database);
    final service = ChoreService(failing, clock: () => day);
    await expectLater(service.watchChores().first, throwsStateError);
    expect(await settings.getValue('recurring_chores_list'), isNull);
    expect(await service.watchChores().first, isNotEmpty);
  });

  test('新增家务使用注入时钟计算默认到期日', () async {
    final service = ChoreService(
      settings,
      clock: () => DateTime(2030, 1, 1, 23, 30),
    );

    final item = await service.addChore(
      title: '测试家务',
      category: '设备维护',
      repeatInterval: ChoreRepeatInterval.weekly,
    );

    expect(item.nextDueDate, DateTime(2030, 1, 8));
  });
}

class _FailOnceSettings extends SettingsRepository {
  _FailOnceSettings(super.database);
  bool failed = false;

  @override
  Future<void> setValue(String key, String value) async {
    if (!failed) {
      failed = true;
      throw StateError('test write failure');
    }
    await super.setValue(key, value);
  }
}
