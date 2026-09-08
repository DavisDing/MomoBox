import 'dart:convert';
import '../data/repositories/settings_repository.dart';
import '../domain/models/ai_usage_models.dart';

class AiUsageService {
  AiUsageService(this._settings);

  final SettingsRepository _settings;
  static const storageKey = 'ai_usage_logs';

  Future<List<AiUsageRecord>> getLogs() async {
    final raw = await _settings.getValue(storageKey);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => AiUsageRecord.fromJson(Map<String, dynamic>.from(m)))
          .toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } catch (_) {
      return const [];
    }
  }

  Stream<List<AiUsageRecord>> watchLogs() {
    return _settings.watchValue(storageKey).map((raw) {
      if (raw == null || raw.trim().isEmpty) return const <AiUsageRecord>[];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! List) return const <AiUsageRecord>[];
        final list = decoded
            .whereType<Map>()
            .map((m) => AiUsageRecord.fromJson(Map<String, dynamic>.from(m)))
            .toList();
        list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        return list;
      } catch (_) {
        return const <AiUsageRecord>[];
      }
    });
  }

  Future<void> recordUsage(AiUsageRecord record) async {
    final current = await getLogs();
    final updated = [record, ...current];
    // 最多保留最近 500 条用量日志
    final trimmed = updated.take(500).map((r) => r.toJson()).toList();
    await _settings.setValue(storageKey, jsonEncode(trimmed));
  }

  Future<void> clearLogs() async {
    await _settings.setValue(storageKey, '[]');
  }
}
