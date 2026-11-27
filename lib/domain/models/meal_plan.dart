import 'dart:convert';
import 'dart:math' as math;

import 'inventory_models.dart';

class MealPlan {
  const MealPlan._(this.dish, this.ingredients);

  final String dish;
  final List<MealIngredient> ingredients;
  static const maxIngredients = 24;
  static const maxQuantity = 9999;

  static MealPlan parse(Object? raw) {
    final values = raw is Map ? raw['ingredients'] : null;
    if (raw is! Map ||
        raw.keys.any((key) => key != 'dish' && key != 'ingredients') ||
        values is! List ||
        values.isEmpty ||
        values.length > maxIngredients) {
      throw const FormatException('食材清单格式无效，请重试。');
    }
    final ingredients = values.map(MealIngredient.parse).toList();
    final unmatchedNames =
        ingredients
            .where((item) => item.productId == null)
            .map((item) => _key(item.name))
            .toList();
    final productIds = ingredients.map((item) => item.productId).nonNulls;
    if (unmatchedNames.toSet().length != unmatchedNames.length ||
        productIds.toSet().length != productIds.length) {
      throw const FormatException('食材清单包含重复项目，请重试。');
    }
    return MealPlan._(_text(raw['dish'], 100), List.unmodifiable(ingredients));
  }

  static MealPlan restock(
    Iterable<({String id, String name, int quantity, int consumed})> items,
  ) => MealPlan._('未来 7 天补货', [
    for (final item in items)
      MealIngredient._(
        item.name,
        '近 30 天消耗 ${item.consumed} 件',
        item.quantity,
        item.id,
      ),
  ]);

  Map<String, Object?> toJson() => {
    'dish': dish,
    'ingredients': [for (final ingredient in ingredients) ingredient.toJson()],
  };

  MealAssessment assess(
    List<InventoryItem> inventory,
    List<ShoppingEntry> shopping,
  ) {
    final matches = [
      for (final ingredient in ingredients)
        inventory
            .where(
              (item) =>
                  ingredient.productId != null
                      ? item.id == ingredient.productId
                      : _key(item.name) == _key(ingredient.name),
            )
            .toList(),
    ];
    final productUseCount = <String, int>{};
    final pendingNameUses = <String, int>{};
    for (var index = 0; index < matches.length; index++) {
      final candidates = matches[index];
      final names = {_key(ingredients[index].name)};
      if (candidates.length == 1) {
        productUseCount.update(
          candidates.single.id,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        names.add(_key(candidates.single.name));
      }
      for (final name in names) {
        pendingNameUses.update(name, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final lines = <MealStockLine>[];
    for (var i = 0; i < ingredients.length; i++) {
      final ingredient = ingredients[i];
      final candidates = matches[i];
      final product = candidates.length == 1 ? candidates.single : null;
      final ambiguous =
          candidates.length > 1 ||
          (ingredient.productId != null && product == null) ||
          (product != null && productUseCount[product.id] != 1);
      final pending =
          shopping
              .where(
                (entry) =>
                    !entry.isCompleted &&
                    (entry.productId != null &&
                            entry.productId == product?.id ||
                        entry.productId == null &&
                            (_key(entry.itemName) == _key(ingredient.name) ||
                                product != null &&
                                    _key(entry.itemName) ==
                                        _key(product.name))),
              )
              .toList()
            ..sort((left, right) => left.id.compareTo(right.id));
      final ambiguousPending = pending.any(
        (entry) =>
            entry.productId == null &&
            (pendingNameUses[_key(entry.itemName)] ?? 0) > 1,
      );
      lines.add(
        MealStockLine(
          ingredient: ingredient,
          product: product,
          available: ambiguous ? null : product?.availableQuantity ?? 0,
          pending: pending.fold(0, (sum, entry) => sum + entry.targetQuantity),
          needsReview:
              ambiguous ||
              ambiguousPending ||
              ingredient.quantity == null ||
              (product != null && product.unit != '件'),
          pendingEntries: pending,
        ),
      );
    }
    return MealAssessment(dish, lines);
  }

  static String _key(String name) => name.trim().toLowerCase();
  static String _text(Object? value, int maxLength) {
    if (value is! String ||
        value.trim().isEmpty ||
        value.runes.length > maxLength ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const FormatException('食材名称或用量格式无效，请重试。');
    }
    return value.trim();
  }
}

class MealIngredient {
  const MealIngredient._(this.name, this.amount, this.quantity, this.productId);

  final String name;
  final String amount;
  final int? quantity;
  final String? productId;

  static MealIngredient parse(Object? raw) {
    if (raw is! Map ||
        raw.keys.any(
          (key) =>
              !const {'name', 'amount', 'quantity', 'productId'}.contains(key),
        )) {
      throw const FormatException('食材格式无效，请重试。');
    }
    final quantity = raw['quantity'];
    if (quantity != null &&
        (quantity is! int || quantity < 1 || quantity > MealPlan.maxQuantity)) {
      throw const FormatException('可采购数量必须为正整数件数。');
    }
    return MealIngredient._(
      MealPlan._text(raw['name'], 255),
      MealPlan._text(raw['amount'], 100),
      quantity as int?,
      raw['productId'] == null ? null : MealPlan._text(raw['productId'], 100),
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'amount': amount,
    if (quantity != null) 'quantity': quantity,
    if (productId != null) 'productId': productId,
  };
}

class MealStockLine {
  const MealStockLine({
    required this.ingredient,
    required this.product,
    required this.available,
    required this.pending,
    required this.needsReview,
    required this.pendingEntries,
  });

  final MealIngredient ingredient;
  final InventoryItem? product;
  final int? available;
  final int pending;
  final bool needsReview;
  final List<ShoppingEntry> pendingEntries;

  int get shortage =>
      needsReview ? 0 : math.max(0, ingredient.quantity! - available!);
  int get toBuy => math.max(0, shortage - pending);
  String get name => product?.name ?? ingredient.name;
  String get label =>
      name == ingredient.name ? name : '${ingredient.name}（库存：$name）';
}

class MealAssessment {
  const MealAssessment(this.dish, this.lines);

  final String dish;
  final List<MealStockLine> lines;
  Iterable<MealStockLine> get purchases =>
      lines.where((line) => line.toBuy > 0);

  String get fingerprint => jsonEncode([
    for (final line in lines)
      [
        line.product?.id,
        line.name,
        line.available,
        line.needsReview,
        line.toBuy,
        for (final entry in line.pendingEntries)
          [entry.id, entry.productId, entry.targetQuantity],
      ],
  ]);

  String get purchaseReview => [
    '为「$dish」加入采购清单',
    for (final line in purchases) '${line.name} × ${line.toBuy} 件',
  ].join('\n');

  String get restockMarkdown => [
    '### ${_escape(dish)}',
    '用过去 30 天的消耗推算 7 天用量，并参考低库存阈值。已扣除可用库存和待购数量。',
    for (final line in purchases)
      '- ${_escape(line.name)}：建议买 ${line.toBuy} 件，可用 ${line.available} 件，'
          '待购 ${line.pending} 件，${_escape(line.ingredient.amount)}',
    if (purchases.isEmpty) '现有采购清单已覆盖这些补货需求。',
  ].join('\n\n');

  String get markdown {
    final shortages = lines.where((line) => line.shortage > 0);
    final review = lines.where((line) => line.needsReview);
    final covered = lines.where(
      (line) => !line.needsReview && line.shortage == 0,
    );
    return [
      '### ${_escape(dish)}',
      if (shortages.isNotEmpty) ...[
        '**缺料清单**',
        for (final line in shortages)
          '- ${_escape(line.label)}：需 ${line.ingredient.quantity} 件，'
              '${line.product == null ? '库存未记录' : '可用 ${line.available} 件'}，缺 ${line.shortage} 件'
              '${line.pending > 0 ? '，已在采购清单 ${line.pending} 件' : ''}'
              '${line.toBuy > 0 ? '，还需买 ${line.toBuy} 件' : ''}',
      ],
      if (review.isNotEmpty) ...[
        '**需要核对**',
        for (final line in review)
          '- ${_escape(line.label)}：菜谱需 ${_escape(line.ingredient.amount)}，'
              '${line.available == null
                  ? '库存匹配不明确'
                  : line.product == null
                  ? '暂无同名库存记录'
                  : '库存有 ${line.available} ${_escape(line.product!.unit)}，请核对实际用量'}',
      ],
      if (covered.isNotEmpty)
        '**库存足够**\n${covered.map((line) => _escape(line.label)).join('、')}',
    ].join('\n\n');
  }

  static String _escape(String text) => text.replaceAllMapped(
    RegExp(r'[\\`*_{}\[\]<>#|]'),
    (match) => '\\${match[0]}',
  );
}
