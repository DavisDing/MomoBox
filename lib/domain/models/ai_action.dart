import 'dart:convert';

import '../inventory/expiry_rules.dart';
import 'chore_models.dart';
import 'inventory_models.dart';

/// A proposal only. The legacy name also covers the assistant's other app actions.
/// Neither arbitrary tools nor SQL/settings keys are accepted from a model.
class AiInventoryAction {
  const AiInventoryAction({
    required this.kind,
    this.productId = '',
    this.batchId,
    this.quantity,
    this.arguments = const {},
  });

  final String kind;
  final String productId;
  final String? batchId;
  final int? quantity;
  final Map<String, Object?> arguments;

  static const schemas = <String, Set<String>>{
    'consume': {'productId', 'quantity', 'batchId'},
    'replenish': {'productId', 'batchId', 'quantity'},
    'discard': {'productId', 'batchId'},
    'intake': {'name', 'category', 'quantity', 'brand', 'specification', 'barcode',
      'location', 'batchNo', 'productionDate', 'expiryDate', 'shelfLifeAmount',
      'shelfLifeUnit', 'lowStockThreshold'},
    'shopping_add': {'name', 'quantity', 'productId', 'category', 'reason'},
    'shopping_complete': {'id', 'completed'},
    'shopping_delete': {'id'},
    'reminder_acknowledge': {'id'},
    'chore_add': {'title', 'category', 'repeatInterval', 'nextDueDate', 'notes'},
    'chore_update': {'id', 'title', 'category', 'repeatInterval', 'nextDueDate', 'notes'},
    'chore_complete': {'id'},
    'chore_delete': {'id'},
    'chore_toggle': {'id', 'enabled'},
    'device_control': {'id', 'command', 'value'},
    'set_theme': {'value'},
    'set_font_scale': {'value'},
    'open_page': {'page'},
  };

  static const pages = <String, String>{
    'backup': '备份与恢复', 'storage': '存储管理', 'ai_settings': 'AI 服务配置',
    'nas_settings': 'NAS 设置', 'ha_settings': 'Home Assistant 设置',
    'sync_settings': '同步与冲突处理', 'notifications': '通知设置',
    'privacy': '隐私设置', 'statistics': '统计', 'inventory': '库存',
    'shopping': '采购清单', 'alerts': '待处理提醒', 'settings': '设置',
  };

  static const deviceCommands = {
    'turn_on', 'turn_off', 'set_brightness', 'set_temperature', 'set_hvac_mode',
    'play', 'pause',
  };

  String? string(String key) => arguments[key] as String?;
  String get id => string('id')!;

  Map<String, Object?> toJson() => {
    ...arguments,
    'kind': kind,
    if (productId.isNotEmpty) 'productId': productId,
    if (batchId != null) 'batchId': batchId,
    if (quantity != null) 'quantity': quantity,
  };

  static AiInventoryAction? parse(String text) {
    try {
      final envelope = jsonDecode(text);
      if (envelope is! Map || envelope['action'] is! Map) return null;
      return fromJson(Map<String, Object?>.from(envelope['action'] as Map));
    } catch (_) {
      return null;
    }
  }

  static AiInventoryAction? fromJson(Map<String, Object?> data) {
    try {
      final kind = data['kind'];
      final allowed = schemas[kind];
      if (kind is! String || allowed == null ||
          data.keys.any((key) => key != 'kind' && !allowed.contains(key))) {
        return null;
      }
      bool text(String key) => data[key] is String &&
          (data[key] as String).trim().isNotEmpty && (data[key] as String).length <= 1000;
      bool integer(String key) => data[key] is int &&
          (data[key] as int) > 0 && (data[key] as int) <= 1000000;
      for (final key in ['name', 'title', 'category', 'brand', 'specification',
        'barcode', 'location', 'batchNo', 'reason', 'notes', 'productId', 'batchId', 'id']) {
        if (data[key] != null && !text(key)) return null;
      }
      for (final key in ['quantity', 'lowStockThreshold', 'shelfLifeAmount']) {
        if (data.containsKey(key) && !integer(key)) return null;
      }
      for (final key in ['productionDate', 'expiryDate', 'nextDueDate']) {
        if (data[key] != null) date(data[key]);
      }
      if (['consume', 'replenish', 'discard'].contains(kind) && !text('productId')) return null;
      if (['replenish', 'discard'].contains(kind) && !text('batchId')) return null;
      if (['consume', 'replenish', 'intake', 'shopping_add'].contains(kind) && !integer('quantity')) return null;
      if (['intake', 'shopping_add'].contains(kind) && !text('name')) return null;
      if (kind == 'intake') {
        if (data['shelfLifeUnit'] != null &&
            !ShelfLifeUnit.values.any((unit) => unit.name == data['shelfLifeUnit'])) {
          return null;
        }
        if (data['productionDate'] != null && data['expiryDate'] != null &&
            date(data['expiryDate'])!.isBefore(date(data['productionDate'])!)) {
          return null;
        }
        if (data['shelfLifeAmount'] != null && data['productionDate'] == null) return null;
      }
      if (['shopping_complete', 'shopping_delete', 'reminder_acknowledge',
        'chore_update', 'chore_complete', 'chore_delete', 'chore_toggle', 'device_control']
          .contains(kind) && !text('id')) {
        return null;
      }
      if (kind == 'shopping_complete' && data['completed'] is! bool) return null;
      if (kind == 'chore_toggle' && data['enabled'] is! bool) return null;
      if (['chore_add', 'chore_update'].contains(kind) &&
          (!text('title') || !ChoreRepeatInterval.values.any((v) => v.name == data['repeatInterval']))) {
        return null;
      }
      if (kind == 'set_theme' && !['default', 'momo', 'doraemon', 'forest', 'sakura'].contains(data['value'])) return null;
      if (kind == 'set_font_scale' && ![0.9, 1.0, 1.15, 1.3].contains(data['value'])) return null;
      if (kind == 'open_page' && !pages.containsKey(data['page'])) return null;
      if (kind == 'device_control') {
        final command = data['command'];
        final value = data['value'];
        if (!deviceCommands.contains(command)) return null;
        if (command == 'set_brightness' && (value is! int || value < 0 || value > 100)) return null;
        if (command == 'set_temperature' && (value is! num || !value.isFinite || value < -100 || value > 200)) return null;
        if (command == 'set_hvac_mode' && !text('value')) return null;
        if (['turn_on', 'turn_off', 'play', 'pause'].contains(command) && value != null) return null;
      }
      return AiInventoryAction(
        kind: kind, productId: (data['productId'] as String?) ?? '',
        batchId: data['batchId'] as String?, quantity: data['quantity'] as int?,
        arguments: Map.unmodifiable({...data}..removeWhere((key, _) =>
          ['kind', 'productId', 'batchId', 'quantity'].contains(key))),
      );
    } catch (_) {
      return null;
    }
  }

  /// Reject normalized invalid dates such as February 31, not just invalid syntax.
  static DateTime? date(Object? raw) {
    if (raw == null) return null;
    if (raw is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
      throw const FormatException('日期应为 YYYY-MM-DD');
    }
    final result = DateTime.parse(raw);
    if (result.year < 2000 || result.year > 2100 ||
        result.toIso8601String().substring(0, 10) != raw) {
      throw const FormatException('日期无效');
    }
    return result;
  }

  IntakeDraft get intakeDraft => IntakeDraft(
    name: string('name')!, category: string('category') ?? '其他物品', quantity: quantity!,
    brand: string('brand'), specification: string('specification'),
    barcode: string('barcode'), location: string('location'), batchNo: string('batchNo'),
    lowStockThreshold: (arguments['lowStockThreshold'] as int?) ?? 1,
    productionDate: date(arguments['productionDate']), expiryDate: date(arguments['expiryDate']),
    shelfLifeAmount: arguments['shelfLifeAmount'] as int?,
    shelfLifeUnit: ShelfLifeUnit.values.firstWhere((v) => v.name == string('shelfLifeUnit'),
      orElse: () => ShelfLifeUnit.days), dateSource: 'ai',
  );

  static String displayText(String text) {
    if (parse(text) != null) return '操作建议已生成，尚未执行。请查看具体内容后确认。';
    try {
      final data = jsonDecode(text);
      if (data is Map && data['action'] != null) return '操作建议格式无效或暂不支持，未执行任何操作。请补充信息后重试。';
      if (data is Map && data['reply'] is String) return data['reply'] as String;
    } catch (_) { /* ordinary natural-language reply */ }
    return text;
  }
}
