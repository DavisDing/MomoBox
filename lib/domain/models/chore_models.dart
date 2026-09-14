import 'dart:convert';

/// 周期循环模式
enum ChoreRepeatInterval {
  daily,
  weekly,
  biweekly,
  monthly,
  quarterly,
}

/// 周期家务/维护提醒模型
class ChoreItem {
  const ChoreItem({
    required this.id,
    required this.title,
    required this.category,
    required this.repeatInterval,
    required this.nextDueDate,
    this.customDays,
    this.lastCompletedDate,
    this.isEnabled = true,
    this.notes,
  });

  final String id;
  final String title;
  final String category; // 家居清洁, 耗材更换, 个人卫生, 设备维护
  final ChoreRepeatInterval repeatInterval;
  final int? customDays;
  final DateTime nextDueDate;
  final DateTime? lastCompletedDate;
  final bool isEnabled;
  final String? notes;

  /// 计算周期天数
  int get intervalDays => switch (repeatInterval) {
        ChoreRepeatInterval.daily => 1,
        ChoreRepeatInterval.weekly => 7,
        ChoreRepeatInterval.biweekly => 14,
        ChoreRepeatInterval.monthly => 30,
        ChoreRepeatInterval.quarterly => 90,
      };

  /// 周期描述文字
  String get repeatDescription => switch (repeatInterval) {
        ChoreRepeatInterval.daily => '每天',
        ChoreRepeatInterval.weekly => '每周',
        ChoreRepeatInterval.biweekly => '每两周',
        ChoreRepeatInterval.monthly => '每月',
        ChoreRepeatInterval.quarterly => '每季度 (90天)',
      };

  /// 是否今天待办或已逾期
  bool isDue({DateTime? today}) {
    final now = today ?? DateTime.now();
    final todayDate = DateTime(now.year, now.month, now.day);
    final dueDate = DateTime(nextDueDate.year, nextDueDate.month, nextDueDate.day);
    return isEnabled && !dueDate.isAfter(todayDate);
  }

  /// 距到期天数（负数表示逾期）
  int daysUntil({DateTime? today}) {
    final now = today ?? DateTime.now();
    final todayDate = DateTime(now.year, now.month, now.day);
    final dueDate = DateTime(nextDueDate.year, nextDueDate.month, nextDueDate.day);
    return dueDate.difference(todayDate).inDays;
  }

  /// 完成本次家务并推算下一次到期时间
  ChoreItem complete({DateTime? completionDate}) {
    final doneDate = completionDate ?? DateTime.now();
    final base = DateTime(doneDate.year, doneDate.month, doneDate.day);
    final next = base.add(Duration(days: intervalDays));
    return copyWith(
      lastCompletedDate: doneDate,
      nextDueDate: next,
    );
  }

  ChoreItem copyWith({
    String? id,
    String? title,
    String? category,
    ChoreRepeatInterval? repeatInterval,
    int? customDays,
    DateTime? nextDueDate,
    DateTime? lastCompletedDate,
    bool? isEnabled,
    String? notes,
  }) {
    return ChoreItem(
      id: id ?? this.id,
      title: title ?? this.title,
      category: category ?? this.category,
      repeatInterval: repeatInterval ?? this.repeatInterval,
      customDays: customDays ?? this.customDays,
      nextDueDate: nextDueDate ?? this.nextDueDate,
      lastCompletedDate: lastCompletedDate ?? this.lastCompletedDate,
      isEnabled: isEnabled ?? this.isEnabled,
      notes: notes ?? this.notes,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'category': category,
        'repeatInterval': repeatInterval.name,
        'customDays': customDays,
        'nextDueDate': nextDueDate.toIso8601String(),
        'lastCompletedDate': lastCompletedDate?.toIso8601String(),
        'isEnabled': isEnabled,
        'notes': notes,
      };

  factory ChoreItem.fromJson(Map<String, dynamic> json) {
    return ChoreItem(
      id: json['id'] as String,
      title: json['title'] as String,
      category: (json['category'] as String?) ?? '家居清洁',
      repeatInterval: ChoreRepeatInterval.values.firstWhere(
        (e) => e.name == json['repeatInterval'],
        orElse: () => ChoreRepeatInterval.weekly,
      ),
      customDays: json['customDays'] as int?,
      nextDueDate: DateTime.parse(json['nextDueDate'] as String),
      lastCompletedDate: json['lastCompletedDate'] != null
          ? DateTime.parse(json['lastCompletedDate'] as String)
          : null,
      isEnabled: (json['isEnabled'] as bool?) ?? true,
      notes: json['notes'] as String?,
    );
  }

  static List<ChoreItem> decodeList(String rawJson) {
    try {
      final list = jsonDecode(rawJson) as List<dynamic>;
      return list.map((item) => ChoreItem.fromJson(item as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static String encodeList(List<ChoreItem> items) {
    return jsonEncode(items.map((i) => i.toJson()).toList());
  }

  /// 常见家庭周期任务预设
  static List<ChoreItem> defaultPresets(DateTime baseDate) {
    final base = DateTime(baseDate.year, baseDate.month, baseDate.day);
    return [
      ChoreItem(
        id: 'chore-sheets',
        title: '更换床单被罩',
        category: '家居清洁',
        repeatInterval: ChoreRepeatInterval.biweekly,
        nextDueDate: base.add(const Duration(days: 14)),
        notes: '高温清洗杀菌并暴晒晾干',
      ),
      ChoreItem(
        id: 'chore-towels',
        title: '洗涤/消毒浴巾毛巾',
        category: '个人卫生',
        repeatInterval: ChoreRepeatInterval.weekly,
        nextDueDate: base.add(const Duration(days: 7)),
        notes: '定期清洗防止滋生细菌',
      ),
      ChoreItem(
        id: 'chore-water-filter',
        title: '更换净水器/滤水壶滤芯',
        category: '耗材更换',
        repeatInterval: ChoreRepeatInterval.monthly,
        nextDueDate: base.add(const Duration(days: 30)),
        notes: '保障家庭饮用水质健康',
      ),
    ];
  }
}
