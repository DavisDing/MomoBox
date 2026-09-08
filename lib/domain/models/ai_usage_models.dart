class AiUsageRecord {
  const AiUsageRecord({
    required this.id,
    required this.timestamp,
    required this.model,
    required this.endpointType,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    this.cachedWriteTokens = 0,
    this.cachedReadTokens = 0,
    this.purpose = 'draft',
  });

  final String id;
  final DateTime timestamp;
  final String model;
  final String endpointType; // 'chat' or 'responses'
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int cachedWriteTokens;
  final int cachedReadTokens;
  final String purpose; // 'draft' or 'qa'

  int get effectiveTotal => totalTokens > 0 ? totalTokens : (promptTokens + completionTokens);

  double get cacheRatio {
    final totalInput = promptTokens + cachedReadTokens;
    if (totalInput <= 0) return 0.0;
    return (cachedReadTokens / totalInput).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'model': model,
        'endpointType': endpointType,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'totalTokens': effectiveTotal,
        'cachedWriteTokens': cachedWriteTokens,
        'cachedReadTokens': cachedReadTokens,
        'purpose': purpose,
      };

  factory AiUsageRecord.fromJson(Map<String, dynamic> json) {
    return AiUsageRecord(
      id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
      model: json['model'] as String? ?? 'unknown',
      endpointType: json['endpointType'] as String? ?? 'chat',
      promptTokens: (json['promptTokens'] as num?)?.toInt() ?? 0,
      completionTokens: (json['completionTokens'] as num?)?.toInt() ?? 0,
      totalTokens: (json['totalTokens'] as num?)?.toInt() ?? 0,
      cachedWriteTokens: (json['cachedWriteTokens'] as num?)?.toInt() ?? 0,
      cachedReadTokens: (json['cachedReadTokens'] as num?)?.toInt() ?? 0,
      purpose: json['purpose'] as String? ?? 'draft',
    );
  }
}

class AiUsageSummary {
  const AiUsageSummary({
    required this.totalTokens,
    required this.promptTokens,
    required this.completionTokens,
    required this.cachedWriteTokens,
    required this.cachedReadTokens,
    required this.requestCount,
  });

  final int totalTokens;
  final int promptTokens;
  final int completionTokens;
  final int cachedWriteTokens;
  final int cachedReadTokens;
  final int requestCount;

  double get cacheRatio {
    final totalInput = promptTokens + cachedReadTokens;
    if (totalInput <= 0) return 0.0;
    return (cachedReadTokens / totalInput).clamp(0.0, 1.0);
  }

  factory AiUsageSummary.aggregate(List<AiUsageRecord> records) {
    var total = 0;
    var prompt = 0;
    var completion = 0;
    var cWrite = 0;
    var cRead = 0;
    for (final r in records) {
      total += r.effectiveTotal;
      prompt += r.promptTokens;
      completion += r.completionTokens;
      cWrite += r.cachedWriteTokens;
      cRead += r.cachedReadTokens;
    }
    return AiUsageSummary(
      totalTokens: total,
      promptTokens: prompt,
      completionTokens: completion,
      cachedWriteTokens: cWrite,
      cachedReadTokens: cRead,
      requestCount: records.length,
    );
  }
}
