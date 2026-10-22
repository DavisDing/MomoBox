import 'dart:convert';

import '../data/repositories/settings_repository.dart';
import '../domain/inventory/expiry_rules.dart';
import '../domain/inventory/reminder_rules.dart';
import '../domain/models/ai_action.dart';
import '../domain/models/chore_models.dart';
import '../domain/models/inventory_models.dart';
import 'chore_service.dart';
import 'inventory_service.dart';
import 'reminder_service.dart';
import 'shopping_service.dart';

export '../domain/models/ai_action.dart';

class AiInventoryActionService {
  AiInventoryActionService(this._settings, this._inventory, {
    ShoppingService? shopping, ChoreService? chores, ReminderService? reminders,
    Future<String> Function()? deviceContext,
    Future<String> Function(AiInventoryAction)? describeDevice,
    Future<void> Function(AiInventoryAction)? executeDevice,
  }) : _shopping = shopping, _chores = chores, _reminders = reminders,
       _deviceContext = deviceContext, _describeDevice = describeDevice,
       _executeDevice = executeDevice;
  static const permissionKey = 'ai_allow_inventory_writes';
  final SettingsRepository _settings;
  final InventoryService _inventory;
  final ShoppingService? _shopping;
  final ChoreService? _chores;
  final ReminderService? _reminders;
  final Future<String> Function()? _deviceContext;
  final Future<String> Function(AiInventoryAction)? _describeDevice;
  final Future<void> Function(AiInventoryAction)? _executeDevice;
  final Map<AiInventoryAction, String> _previews = {};

  // An existing explicit opt-out is preserved. New installations may propose
  // any supported action; every write still requires individual confirmation.
  Future<bool> get proposalsAllowed async =>
      await _settings.getValue(permissionKey) != 'false';

  Future<void> checkPermission() async {
    if (!await proposalsAllowed) throw StateError('AI 操作建议已关闭，请先在 AI 设置中开启。');
  }

  Future<String> contextSnapshot() async {
    final buffer = StringBuffer();
    if (_shopping != null) {
      final entries = await _shopping.readEntries();
      buffer.writeln('【采购清单】');
      for (final entry in entries) {
        buffer.writeln(jsonEncode({'id': entry.id, 'name': entry.itemName,
          'quantity': entry.targetQuantity, 'completed': entry.isCompleted,
          'productId': entry.productId}));
      }
    }
    if (_chores != null) {
      buffer.writeln('【家务】');
      for (final chore in await _chores.readSavedChores()) {
        buffer.writeln(jsonEncode(chore.toJson()));
      }
    }
    if (_reminders != null) {
      buffer.writeln('【待处理提醒】');
      for (final candidate in await _pendingReminders()) {
        buffer.writeln(jsonEncode({'id': candidate.key, 'name': candidate.item.name,
          'type': candidate.type.name}));
      }
    }
    if (_deviceContext != null) {
      try { buffer.writeln(await _deviceContext()); }
      catch (_) { buffer.writeln('设备上下文暂不可用，不能猜测设备 ID 或命令。'); }
    }
    return buffer.toString();
  }

  Future<List<ReminderCandidate>> _pendingReminders() async =>
      ReminderRules.visibleCandidates(await _inventory.watchInventory().first,
        await _reminders!.watchAcknowledgements().first);

  Future<String?> _describeAppAction(AiInventoryAction action) async {
    final a = action;
    switch (a.kind) {
      case 'intake':
        final draft = a.intakeDraft;
        return '打开可编辑入库草稿：「${draft.name}」${draft.quantity} 件。'
            '核对日期及相似商品后，点击“确认入库”才会写入。';
      case 'shopping_add':
        if (_shopping == null) throw StateError('采购服务不可用。');
        final items = await _inventory.watchInventory().first;
        final product = items.where((item) => item.id == a.productId).firstOrNull;
        if (a.productId.isNotEmpty && product == null) throw StateError('关联商品已不存在。');
        if (product != null && product.name != a.string('name')) throw StateError('商品名称与 ID 不匹配，请重新提问。');
        final entries = await _shopping.readEntries();
        final existing = entries.where((entry) => !entry.isCompleted &&
          (a.productId.isNotEmpty ? entry.productId == a.productId :
            entry.productId == null && entry.itemName.trim().toLowerCase() == a.string('name')!.trim().toLowerCase())).firstOrNull;
        return '采购「${a.string('name')}」增加 ${a.quantity} 件；'
            '${existing == null ? '新建采购项' : '合并到现有 ${existing.targetQuantity} 件，合计 ${existing.targetQuantity + a.quantity!} 件'}。'
            '\n分类：${existing?.category ?? (existing == null ? a.string('category') : null) ?? '未分类'}；'
            '原因：${existing == null ? a.string('reason') ?? 'AI 助手建议' : existing.reason}。';
      case 'shopping_complete':
      case 'shopping_delete':
        if (_shopping == null) throw StateError('采购服务不可用。');
        final entries = await _shopping.readEntries();
        final entry = entries.where((e) => e.id == a.id).firstOrNull;
        if (entry == null) throw StateError('采购项已不存在，请重新提问。');
        return '${a.kind == 'shopping_delete' ? '删除采购项' : a.arguments['completed'] == true ? '标记采购已完成' : '恢复为待采购'}'
            '：「${entry.itemName}」${entry.targetQuantity} 件（当前${entry.isCompleted ? '已完成' : '未完成'}）。'
            '${a.kind == 'shopping_complete' ? '仅修改采购状态，不会自动入库。' : ''}';
      case 'reminder_acknowledge':
        if (_reminders == null) throw StateError('提醒服务不可用。');
        final candidates = await _pendingReminders();
        final candidate = candidates.where((c) => c.key == a.id).firstOrNull;
        if (candidate == null) throw StateError('提醒已变化或已处理，请重新提问。');
        return '将「${candidate.item.name}」${const {ReminderType.expired: '过期', ReminderType.expiring: '临期', ReminderType.lowStock: '低库存'}[candidate.type]}提醒标记为已处理。'
            '\n当前库存 ${candidate.item.totalStock} 件；最近到期 ${_dateText(candidate.item.nearestDatedBatch?.expiryDate)}。';
      case 'chore_add':
      case 'chore_update':
      case 'chore_complete':
      case 'chore_delete':
      case 'chore_toggle':
        if (_chores == null) throw StateError('家务服务不可用。');
        ChoreItem? existing;
        if (a.kind != 'chore_add') {
          existing = (await _chores.readSavedChores()).where((c) => c.id == a.id).firstOrNull;
          if (existing == null) throw StateError('家务已不存在，请重新提问。');
        }
        final previous = existing == null ? '' :
            '\n原安排：${existing.repeatDescription}，下次 ${_dateText(existing.nextDueDate)}，'
            '${existing.isEnabled ? '已启用' : '已停用'}；备注：${existing.notes ?? '无'}。';
        if (a.kind == 'chore_delete') return '删除家务「${existing!.title}」。$previous';
        if (a.kind == 'chore_complete') return '完成「${existing!.title}」，按${existing.repeatDescription}推算下次日期。$previous';
        if (a.kind == 'chore_toggle') return '${a.arguments['enabled'] == true ? '启用' : '停用'}家务「${existing!.title}」。$previous';
        return '${a.kind == 'chore_add' ? '新增' : '修改'}家务「${a.string('title')}」：'
            '${_repeatLabels[a.string('repeatInterval')]}；分类：${a.string('category') ?? existing?.category ?? '家居清洁'}；'
            '下次日期：${a.string('nextDueDate') ?? (existing == null ? '按周期推算' : _dateText(existing.nextDueDate))}；'
            '备注：${a.string('notes') ?? existing?.notes ?? '无'}。$previous';
      case 'device_control':
        if (_describeDevice == null) throw StateError('设备控制不可用，请先连接 NAS 和 Home Assistant。');
        return _describeDevice(a);
      case 'set_theme':
        return '主题从 ${await _settings.getValue('theme') ?? 'default'} 改为 ${a.string('value')}。';
      case 'set_font_scale':
        return '应用字号比例从 ${await _settings.getValue('font_scale') ?? '1.0'} 改为 ${a.arguments['value']}。';
      case 'open_page':
        return '打开${AiInventoryAction.pages[a.string('page')]}页面。文件选择、恢复、清理、凭据和权限更改需在页面中另行确认。';
      default:
        return null;
    }
  }

  Future<String> describe(AiInventoryAction action) async {
    final before = await _fingerprint(action);
    final prepared = await _prepare(action);
    final after = await _fingerprint(action);
    if (before != after) throw StateError('数据正在变化，请重新查看操作。');
    if (_previews.length > 100) _previews.clear();
    _previews[action] = after;
    return prepared.description;
  }

  /// Version information stays separate from the readable confirmation text.
  /// Equal names/quantities must not hide replacement of a batch or reminder.
  Future<String> _fingerprint(AiInventoryAction action) async {
    switch (action.kind) {
      case 'consume':
      case 'replenish':
      case 'discard':
        final items = await _inventory.watchInventory().first;
        final item = items.where((item) => item.id == action.productId).firstOrNull;
        return jsonEncode(item == null ? null : {
          'id': item.id, 'name': item.name,
          'batches': [for (final b in item.batches) {
            'id': b.id, 'remaining': b.remainingQuantity, 'discarded': b.isDiscarded,
            'production': b.productionDate?.toIso8601String(), 'expiry': b.expiryDate?.toIso8601String(),
          }],
        });
      case 'reminder_acknowledge':
        if (_reminders == null) return '';
        final candidate = (await _pendingReminders()).where((c) => c.key == action.id).firstOrNull;
        return candidate?.fingerprint ?? '';
      case 'shopping_add':
        if (_shopping == null) return '';
        final candidates = (await _shopping.readEntries()).where((entry) =>
          !entry.isCompleted && (action.productId.isNotEmpty
            ? entry.productId == action.productId
            : entry.productId == null && entry.itemName.trim().toLowerCase() ==
                action.string('name')!.trim().toLowerCase())).toList()
          ..sort((left, right) => left.id.compareTo(right.id));
        return jsonEncode(candidates.map(_shoppingEntrySnapshot).toList());
      case 'shopping_complete':
      case 'shopping_delete':
        if (_shopping == null) return '';
        final entry = (await _shopping.readEntries())
            .where((entry) => entry.id == action.id).firstOrNull;
        return jsonEncode(entry == null ? null : _shoppingEntrySnapshot(entry));
      case 'chore_update':
      case 'chore_complete':
      case 'chore_delete':
      case 'chore_toggle':
        return jsonEncode((await _chores?.readSavedChores() ?? <ChoreItem>[])
          .where((c) => c.id == action.id).firstOrNull?.toJson());
      default:
        return jsonEncode(action.toJson());
    }
  }

  static const _repeatLabels = {'daily': '每天', 'weekly': '每周', 'biweekly': '每两周',
    'monthly': '每月', 'quarterly': '每季度'};
  static String _dateText(DateTime? date) => date?.toIso8601String().substring(0, 10) ?? '未记录';

  static Map<String, Object?> _shoppingEntrySnapshot(ShoppingEntry entry) => {
    'id': entry.id, 'productId': entry.productId, 'itemName': entry.itemName,
    'category': entry.category, 'targetQuantity': entry.targetQuantity,
    'reason': entry.reason, 'isCompleted': entry.isCompleted,
  };

  Future<({String description, int? remaining})> _prepare(
    AiInventoryAction action,
  ) async {
    await checkPermission();
    if (AiInventoryAction.fromJson(action.toJson()) == null) throw StateError('操作参数无效或不支持。');
    final appDescription = await _describeAppAction(action);
    if (appDescription != null) return (description: appDescription, remaining: null);
    final items = await _inventory.watchInventory().first;
    final item = items.where((item) => item.id == action.productId).firstOrNull;
    if (item == null) throw StateError('商品不存在或已删除，请重新提问。');
    if (!['consume', 'replenish', 'discard'].contains(action.kind)) {
      throw StateError('不支持该操作。');
    }
    if (action.kind != 'discard' &&
        (action.quantity == null ||
            action.quantity! < 1 ||
            action.quantity! > 1000000)) {
      throw StateError('数量必须为有效的正整数。');
    }
    if (action.kind == 'consume') {
      if (action.batchId != null) {
        final batch = item.batches.where((b) => b.id == action.batchId && !b.isDiscarded).firstOrNull;
        if (batch == null || batch.expiryStatus == ExpiryStatus.expired || batch.remainingQuantity < action.quantity!) throw StateError('指定批次不可用或数量不足。');
      } else if (item.availableQuantity < action.quantity!) {
        throw StateError('可用库存不足。');
      }
      return (
        description: '消耗「${item.name}」${action.quantity} 件，'
            '${action.batchId == null ? '按先到期先出扣减可用批次' : '使用指定批次'}。'
            '\n当前批次：${[for (final b in item.batches) if (!b.isDiscarded && (action.batchId == null || b.id == action.batchId)) '${b.batchNo ?? '未命名'} / 到期 ${_dateText(b.expiryDate)} / 剩余 ${b.remainingQuantity} 件'].join('；')}。',
        remaining: null,
      );
    }
    final batch = item.batches.where((b) => b.id == action.batchId).firstOrNull;
    if (batch == null || batch.isDiscarded) throw StateError('批次不存在或已报废。');
    final label = '${batch.batchNo ?? '未命名'}（到期 ${_dateText(batch.expiryDate)}）';
    if (action.kind == 'replenish') {
      return (
        description: '补充「${item.name}」批次 $label：${action.quantity} 件，'
            '当前 ${batch.remainingQuantity} 件，沿用生产日期 ${_dateText(batch.productionDate)}。',
        remaining: null,
      );
    }
    return (
      description:
          '报废「${item.name}」批次 $label 的全部剩余 ${batch.remainingQuantity} 件。此操作不可撤销。',
      remaining: batch.remainingQuantity,
    );
  }

  Future<void> execute(
    AiInventoryAction action, {
    required String confirmedDescription,
  }) async {
    // Revalidate permission and identity immediately before invoking existing
    // transactional rules. UI confirmation is mandatory at the caller.
    final prepared = await _prepare(action);
    if (prepared.description != confirmedDescription ||
        _previews[action] != await _fingerprint(action)) {
      throw StateError('操作对象或数据已变化，请重新确认。');
    }
    await checkPermission();
    _previews.remove(action);
    switch (action.kind) {
      case 'consume':
        if (action.batchId == null) {
          await _inventory.consume(action.productId, action.quantity!);
        } else {
          await _inventory.consumeBatch(action.productId, action.batchId!, action.quantity!);
        }
      case 'replenish':
        await _inventory.replenishBatch(action.batchId!, action.quantity!);
      case 'discard':
        await _inventory.discardBatch(
          action.batchId!,
          expectedRemainingQuantity: prepared.remaining,
        );
      case 'shopping_add':
        await _shopping!.addOrMerge(itemName: action.string('name')!,
          targetQuantity: action.quantity!, reason: action.string('reason') ?? 'AI 助手建议',
          productId: action.productId.isEmpty ? null : action.productId,
          category: action.string('category'));
      case 'shopping_complete':
        await _shopping!.setCompleted(action.id, action.arguments['completed'] as bool);
      case 'shopping_delete':
        await _shopping!.delete(action.id);
      case 'reminder_acknowledge':
        final candidate = (await _pendingReminders()).where((c) => c.key == action.id).firstOrNull;
        if (candidate == null) throw StateError('提醒已变化，请重新确认。');
        await _reminders!.acknowledge(reminderKey: candidate.key, fingerprint: candidate.fingerprint);
      case 'chore_add':
        await _chores!.addChore(title: action.string('title')!,
          category: action.string('category') ?? '家居清洁',
          repeatInterval: ChoreRepeatInterval.values.byName(action.string('repeatInterval')!),
          nextDueDate: AiInventoryAction.date(action.arguments['nextDueDate']), notes: action.string('notes'));
      case 'chore_update':
        final choreService = _chores!;
        final existing = (await choreService.readSavedChores()).firstWhere((c) => c.id == action.id);
        await choreService.updateChore(id: action.id, title: action.string('title')!,
          category: action.string('category') ?? existing.category,
          repeatInterval: ChoreRepeatInterval.values.byName(action.string('repeatInterval')!),
          nextDueDate: AiInventoryAction.date(action.arguments['nextDueDate']), notes: action.string('notes'));
      case 'chore_complete':
        if (await _chores!.completeChore(action.id) == null) throw StateError('家务已不存在。');
      case 'chore_delete':
        await _chores!.deleteChore(action.id);
      case 'chore_toggle':
        await _chores!.toggleChore(action.id, action.arguments['enabled'] as bool);
      case 'device_control':
        if (_executeDevice == null) throw StateError('设备控制不可用。');
        await _executeDevice(action);
      case 'set_theme':
        await _settings.setValue('theme', action.string('value')!);
      case 'set_font_scale':
        await _settings.setValue('font_scale', action.arguments['value'].toString());
      default:
        throw StateError('此操作需要在对应页面中由用户完成确认。');
    }
  }
}
