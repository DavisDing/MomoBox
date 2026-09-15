import 'package:uuid/uuid.dart';

import '../data/repositories/settings_repository.dart';
import '../domain/models/chore_models.dart';

class ChoreService {
  ChoreService(this._settingsRepository, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  Future<List<ChoreItem>>? _loading;

  final SettingsRepository _settingsRepository;
  static const _storageKey = 'recurring_chores_list';

  /// 获取所有周期家务
  Future<List<ChoreItem>> getChores() {
    return _loading ??= _loadChores().whenComplete(() {
      _loading = null;
    });
  }

  Future<List<ChoreItem>> _loadChores() async {
    final raw = await _settingsRepository.getValue(_storageKey);
    if (raw == null || raw.trim().isEmpty) {
      // 首次初始化默认预设
      final defaults = ChoreItem.defaultPresets(_clock());
      await _saveChores(defaults);
      return defaults;
    }
    return ChoreItem.decodeList(raw);
  }

  /// 监听周期家务列表
  Stream<List<ChoreItem>> watchChores() {
    return _settingsRepository.watchValue(_storageKey).asyncMap((raw) {
      if (raw == null || raw.trim().isEmpty) {
        return getChores();
      }
      return ChoreItem.decodeList(raw);
    });
  }

  /// 保存列表
  Future<void> _saveChores(List<ChoreItem> chores) async {
    await _settingsRepository.setValue(_storageKey, ChoreItem.encodeList(chores));
  }

  /// 添加周期家务
  Future<ChoreItem> addChore({
    required String title,
    required String category,
    required ChoreRepeatInterval repeatInterval,
    DateTime? nextDueDate,
    String? notes,
  }) async {
    final chores = await getChores();
    final now = DateTime.now();
    final due = nextDueDate ?? DateTime(now.year, now.month, now.day).add(
      Duration(
        days: switch (repeatInterval) {
          ChoreRepeatInterval.daily => 1,
          ChoreRepeatInterval.weekly => 7,
          ChoreRepeatInterval.biweekly => 14,
          ChoreRepeatInterval.monthly => 30,
          ChoreRepeatInterval.quarterly => 90,
        },
      ),
    );

    final item = ChoreItem(
      id: const Uuid().v4(),
      title: title.trim(),
      category: category.trim(),
      repeatInterval: repeatInterval,
      nextDueDate: due,
      notes: notes?.trim(),
    );

    final updated = [...chores, item];
    await _saveChores(updated);
    return item;
  }

  /// 标记完成某项家务
  Future<ChoreItem?> completeChore(String id, {DateTime? completionDate}) async {
    final chores = await getChores();
    final index = chores.indexWhere((c) => c.id == id);
    if (index == -1) return null;

    final updatedItem = chores[index].complete(completionDate: completionDate);
    final updatedList = List<ChoreItem>.from(chores);
    updatedList[index] = updatedItem;
    await _saveChores(updatedList);
    return updatedItem;
  }


  /// 编辑更新周期家务
  Future<void> updateChore({
    required String id,
    required String title,
    required String category,
    required ChoreRepeatInterval repeatInterval,
    DateTime? nextDueDate,
    String? notes,
    bool? isEnabled,
  }) async {
    final chores = await getChores();
    final index = chores.indexWhere((c) => c.id == id);
    if (index == -1) return;

    final existing = chores[index];
    final updatedItem = existing.copyWith(
      title: title.trim(),
      category: category.trim(),
      repeatInterval: repeatInterval,
      nextDueDate: nextDueDate ?? existing.nextDueDate,
      notes: notes?.trim(),
      isEnabled: isEnabled ?? existing.isEnabled,
    );

    final updatedList = List<ChoreItem>.from(chores);
    updatedList[index] = updatedItem;
    await _saveChores(updatedList);
  }

  /// 删除家务
  Future<void> deleteChore(String id) async {
    final chores = await getChores();
    final updated = chores.where((c) => c.id != id).toList();
    await _saveChores(updated);
  }

  /// 开关启用状态
  Future<void> toggleChore(String id, bool isEnabled) async {
    final chores = await getChores();
    final index = chores.indexWhere((c) => c.id == id);
    if (index == -1) return;

    final updatedList = List<ChoreItem>.from(chores);
    updatedList[index] = updatedList[index].copyWith(isEnabled: isEnabled);
    await _saveChores(updatedList);
  }
}
