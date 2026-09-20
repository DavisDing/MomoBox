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
    this.status = 'success',
    this.providerLevel,
    this.failureReason,
    this.elapsedMs = 0,
  });

  final String id;
  final DateTime timestamp;
  final String model;
  final String endpointType; // 'chat', 'responses' or 'unknown'
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final int cachedWriteTokens;
  final int cachedReadTokens;
  final String purpose; // 'draft' or 'qa'
  final String status; // 'success' or 'failure'
  final String? providerLevel; // 'primary', 'secondary' or 'fallback'
  final String? failureReason;
  final int elapsedMs;

  bool get isSuccess => status == 'success';

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
        'status': status,
        if (providerLevel != null) 'providerLevel': providerLevel,
        if (failureReason != null) 'failureReason': failureReason,
        'elapsedMs': elapsedMs,
      };

  factory AiUsageRecord.fromJson(Map<String, dynamic> json) {
    return AiUsageRecord(
      id: _stringOr(json['id'], DateTime.now().millisecondsSinceEpoch.toString()),
      timestamp: DateTime.tryParse(_stringOr(json['timestamp'], '')) ?? DateTime.now(),
      model: _stringOr(json['model'], 'unknown'),
      endpointType: _stringOr(json['endpointType'], 'chat'),
      promptTokens: _intOr(json['promptTokens']),
      completionTokens: _intOr(json['completionTokens']),
      totalTokens: _intOr(json['totalTokens']),
      cachedWriteTokens: _intOr(json['cachedWriteTokens']),
      cachedReadTokens: _intOr(json['cachedReadTokens']),
      purpose: _stringOr(json['purpose'], 'draft'),
      status: _stringOr(json['status'], 'success'),
      providerLevel: _nullableString(json['providerLevel']),
      failureReason: _nullableString(json['failureReason']),
      elapsedMs: _intOr(json['elapsedMs']),
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

String _stringOr(Object? value, String fallback) => value is String && value.trim().isNotEmpty ? value : fallback;

String? _nullableString(Object? value) => value is String && value.trim().isNotEmpty ? value : null;

int _intOr(Object? value) => value is num && value.isFinite ? value.toInt() : 0;
