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

  static String? canonical(String? category) {
    final trimmed = category?.trim();
    if (values.contains(trimmed)) return trimmed;
    return _aliases[trimmed];
  }

  /// Intentionally small, high-confidence hints, not a universal classifier.
  /// Ambiguous names and specialty products are left for the user/model.
  static String? suggestForName(String name) {
    final normalized = name.trim();
    if (normalized.isEmpty || RegExp(
      r'药|胶囊|保健|营养补充|维生素|宠物|猫|狗|模型|玩具|模具|味香|香薰',
    ).hasMatch(normalized)) {
      return null;
    }
    const hints = {
      '零食饮料': ['薯片', '饼干', '爆米花', '巧克力', '果冻', '汽水', '可乐'],
      '纸品湿巾': ['抽纸', '卷纸', '纸巾', '湿巾'],
      '家居清洁': ['洗衣液', '洗衣粉', '洗洁精', '洁厕液'],
      '电池灯具': ['电池', '灯泡'],
    };
    for (final entry in hints.entries) {
      if (entry.value.any(normalized.contains)) return entry.key;
    }
    return null;
  }

  /// AI/barcode suggestions may contain aliases or clearly mismatched classes.
  /// Manual selections (including legacy custom classes) bypass this method.
  static String forSuggestion({required String name, String? category}) =>
      suggestForName(name) ?? canonical(category) ?? fallback;
}
