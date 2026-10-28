/// Persisted category names are shared by intake, shopping and AI prompts.
/// Suggestions only prefill editable drafts; they never migrate saved products.
abstract final class ProductCategories {
  static const fallback = '其他物品';
  static const values = [
    '药品保健', '食品生鲜', '美妆个护', '母婴用品',
    '粮油调味', '零食饮料', '冷冻速食', '宠物用品',
    '家居清洁', '纸品湿巾', '厨房用品', '餐具水具',
    '衣物鞋帽', '家纺寝具', '数码电器', '电池灯具',
    '文具办公', '工具五金', '运动户外', '玩具图书',
    '园艺绿植', '汽车用品', fallback,
  ];

  static const _aliases = {
    '零食': '零食饮料', '休闲食品': '零食饮料', '饮料': '零食饮料',
    '食品': '食品生鲜', '生鲜': '食品生鲜', '药品': '药品保健',
    '保健品': '药品保健', '个护': '美妆个护', '清洁用品': '家居清洁',
    '纸巾': '纸品湿巾', '电子产品': '数码电器', '其他': fallback,
  };

  static const _hints = {
    '零食饮料': ['薯片', '饼干', '爆米花', '巧克力', '果冻', '汽水', '可乐'],
    '纸品湿巾': ['抽纸', '卷纸', '纸巾', '湿巾'],
    '家居清洁': ['洗衣液', '洗衣粉', '洗洁精', '洁厕液'],
    '电池灯具': ['电池', '灯泡'],
  };

  // Scope these qualifiers to relevant candidates, not the entire product name.
  // Single characters such as 药/猫/狗 also occur in ordinary food names.
  static final _petUse = RegExp(r'宠物|猫粮|狗粮|犬粮|猫用|狗用|犬用|猫零食|狗零食|犬零食');
  static final _supplement = RegExp(r'药品|药物|药用|胶囊|片剂|保健|营养补充|维生素');
  static final _nonFoodForm = RegExp(r'模型|玩具|模具|香薰|香氛|香水|蜡烛');

  static String? canonical(String? category) {
    final trimmed = category?.trim();
    if (values.contains(trimmed)) return trimmed;
    return _aliases[trimmed];
  }

  /// Validates model output without reclassifying it from the product name.
  /// Missing/uncertain categories remain unknown; unsupported values are errors.
  /// Prompts request canonical names; reception tolerates existing aliases.
  static String? validateAiCategory(Object? category) {
    if (category == null) return null;
    if (category is! String) {
      throw const FormatException('AI 返回的分类必须是文字或 null。');
    }
    if (category.trim().isEmpty) return null;
    final normalized = canonical(category);
    if (normalized == null) {
      throw const FormatException('AI 返回了不支持的分类，请重新解析或手动选择。');
    }
    return normalized;
  }

  /// Manual-entry hints only; never post-process AI output with these rules.
  /// Intentionally small, high-confidence hints, not a universal classifier.
  /// Explicit pet food/tissues become 宠物用品; supplements and food-shaped
  /// non-food objects do not produce snack hints. These rules do not veto
  /// other independent matches. Conflicting categories produce no local hint.
  static String? suggestForName(String name) {
    final matches = candidatesForManualEntry(name);
    return matches.length == 1 ? matches.single : null;
  }

  /// Exposes ambiguity for manual-entry feedback without choosing a winner.
  static Set<String> candidatesForManualEntry(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty) return const <String>{};
    final matches = <String>{};
    for (final entry in _hints.entries) {
      if (!entry.value.any(normalized.contains)) continue;
      var category = entry.key;
      if (category == '零食饮料') {
        if (_supplement.hasMatch(normalized) || _nonFoodForm.hasMatch(normalized)) {
          continue;
        }
      }
      if ((category == '零食饮料' || category == '纸品湿巾') &&
          _petUse.hasMatch(normalized)) {
        category = '宠物用品';
      }
      matches.add(category);
    }
    return Set.unmodifiable(matches);
  }

  /// Local suggestions for manual entry before AI has been applied.
  /// User selections and AI results bypass local name hints entirely.
  static String forManualEntry({required String name, String? category}) =>
      suggestForName(name) ?? canonical(category) ?? fallback;
}
