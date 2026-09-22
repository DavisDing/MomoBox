import 'dart:convert';

import '../data/repositories/settings_repository.dart';
import 'inventory_service.dart';

/// Model output is only an untrusted proposal. Never dispatch arbitrary tools,
/// SQL, entity names or methods supplied by the model.
class AiInventoryAction {
  const AiInventoryAction({
    required this.kind,
    required this.productId,
    this.batchId,
    this.quantity,
  });
  final String kind;
  final String productId;
  final String? batchId;
  final int? quantity;

  static AiInventoryAction? parse(String text) {
    try {
      final envelope = jsonDecode(text);
      if (envelope is! Map || envelope['action'] is! Map) return null;
      final data = envelope['action'] as Map;
      final kind = data['kind'];
      final productId = data['productId'];
      final batchId = data['batchId'];
      final quantity = data['quantity'];
      if (!['consume', 'replenish', 'discard'].contains(kind) ||
          productId is! String ||
          productId.isEmpty) {
        return null;
      }
      if (kind != 'consume' && (batchId is! String || batchId.isEmpty)) {
        return null;
      }
      if (kind != 'discard' &&
          (quantity is! int || quantity < 1 || quantity > 1000000)) {
        return null;
      }
      return AiInventoryAction(
        kind: kind as String,
        productId: productId,
        batchId: batchId is String ? batchId : null,
        quantity: quantity is int ? quantity : null,
      );
    } catch (_) {
      return null;
    }
  }

  static String displayText(String text) {
    if (parse(text) != null) return '库存操作建议已生成，尚未执行。请查看商品、批次和数量后确认。';
    try {
      final data = jsonDecode(text);
      if (data is Map && data['reply'] is String) {
        if (data['action'] != null) return '操作建议格式无效，未执行任何操作。请重新描述商品和数量。';
        return data['reply'] as String;
      }
    } catch (_) {
      /* ordinary natural-language reply */
    }
    return text;
  }
}

class AiInventoryActionService {
  AiInventoryActionService(this._settings, this._inventory);
  static const permissionKey = 'ai_allow_inventory_writes';
  final SettingsRepository _settings;
  final InventoryService _inventory;

  Future<String> describe(AiInventoryAction action) async =>
      (await _prepare(action)).description;

  Future<({String description, int? remaining})> _prepare(
    AiInventoryAction action,
  ) async {
    if (await _settings.getValue(permissionKey) != 'true') {
      throw StateError('AI 库存操作权限已关闭，请先在设置中授权。');
    }
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
      return (
        description: '消耗「${item.name}」${action.quantity} 件，按先到期先出扣减可用批次。',
        remaining: null,
      );
    }
    final batch = item.batches.where((b) => b.id == action.batchId).firstOrNull;
    if (batch == null || batch.isDiscarded) throw StateError('批次不存在或已报废。');
    final label = '${batch.batchNo ?? '未命名'}（${batch.id}）';
    if (action.kind == 'replenish') {
      return (
        description: '补充「${item.name}」批次 $label：${action.quantity} 件，沿用该批次日期。',
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
    String? confirmedDescription,
  }) async {
    // Revalidate permission and identity immediately before invoking existing
    // transactional rules. UI confirmation is mandatory at the caller.
    final prepared = await _prepare(action);
    if (confirmedDescription != null &&
        prepared.description != confirmedDescription) {
      throw StateError('库存已变化，请重新确认。');
    }
    switch (action.kind) {
      case 'consume':
        await _inventory.consume(action.productId, action.quantity!);
      case 'replenish':
        await _inventory.replenishBatch(action.batchId!, action.quantity!);
      case 'discard':
        await _inventory.discardBatch(
          action.batchId!,
          expectedRemainingQuantity: prepared.remaining,
        );
      default:
        throw StateError('不支持该操作。');
    }
  }
}
