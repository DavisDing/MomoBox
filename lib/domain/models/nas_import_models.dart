class NasImportCapabilities {
  const NasImportCapabilities({required this.maxRecords, required this.maxRequestBytes,
    required this.familyTimeZone});
  final int maxRecords;
  final int maxRequestBytes;
  final String familyTimeZone;

  factory NasImportCapabilities.fromJson(Map<String, dynamic> json) {
    if (json['import_format_version'] != 1 || json['atomic_import'] != true ||
        json['history_archive'] != true || json['calendar_dates'] != true) {
      throw const FormatException('NAS 不支持当前库存与独立历史导入。');
    }
    return NasImportCapabilities(maxRecords: _int(json, 'max_records', minimum: 1),
      maxRequestBytes: _int(json, 'max_request_bytes', minimum: 1),
      familyTimeZone: _string(json, 'family_time_zone'));
  }
}

class NasImportBlocker {
  const NasImportBlocker({required this.code, required this.message,
    this.entity, this.entityId});
  final String code;
  final String message;
  final String? entity;
  final String? entityId;
  factory NasImportBlocker.fromJson(Map<String, dynamic> json) => NasImportBlocker(
    code: _string(json, 'code'), message: _string(json, 'message'),
    entity: json['entity'] as String?, entityId: json['entity_id'] as String?);
}

class NasImportReceipt {
  const NasImportReceipt({required this.importId, required this.status,
    required this.fingerprint, required this.counts, required this.blockers,
    this.checkpoint, this.familyTimeZone, this.serverCursor, this.historyCursor});
  final String importId;
  final String status;
  final String fingerprint;
  final String? checkpoint;
  final Map<String, int> counts;
  final List<NasImportBlocker> blockers;
  final String? familyTimeZone;
  final int? serverCursor;
  final int? historyCursor;
  bool get isCompleted => status == 'completed';

  factory NasImportReceipt.fromJson(Map<String, dynamic> json) {
    final status = _string(json, 'status');
    if (!const ['prepared', 'blocked', 'completed'].contains(status)) {
      throw const FormatException('无效导入状态。');
    }
    final rawCounts = json['counts'];
    if (rawCounts is! Map) throw const FormatException('导入回执缺少 counts。');
    final counts = <String, int>{};
    for (final entry in rawCounts.entries) {
      if (entry.key is! String || entry.value is! int || (entry.value as int) < 0) {
        throw const FormatException('导入 counts 无效。');
      }
      counts[entry.key as String] = entry.value as int;
    }
    final rawBlockers = json['blockers'] ?? const [];
    if (rawBlockers is! List) throw const FormatException('导入 blockers 无效。');
    final checkpoint = json['checkpoint'] as String?;
    if (status == 'prepared' && (checkpoint == null || checkpoint.isEmpty)) {
      throw const FormatException('导入回执缺少 checkpoint。');
    }
    return NasImportReceipt(importId: _string(json, 'import_id'), status: status,
      fingerprint: status == 'blocked' && json['fingerprint'] == null
          ? '' : _string(json, 'fingerprint'), checkpoint: checkpoint,
      counts: Map.unmodifiable(counts), blockers: rawBlockers.map((value) =>
        NasImportBlocker.fromJson(Map<String, dynamic>.from(value as Map))).toList(growable: false),
      familyTimeZone: json['family_time_zone'] as String?,
      serverCursor: json['server_cursor'] == null ? null : _int(json, 'server_cursor'),
      historyCursor: json['history_cursor'] == null ? null : _int(json, 'history_cursor'));
  }

  Map<String, dynamic> toJson() => {'import_id': importId, 'status': status,
    'fingerprint': fingerprint, 'checkpoint': checkpoint, 'counts': counts,
    'blockers': blockers.map((b) => {'code': b.code, 'message': b.message,
      if (b.entity != null) 'entity': b.entity,
      if (b.entityId != null) 'entity_id': b.entityId}).toList(growable: false),
    if (familyTimeZone != null) 'family_time_zone': familyTimeZone,
    if (serverCursor != null) 'server_cursor': serverCursor,
    if (historyCursor != null) 'history_cursor': historyCursor};
}

class NasImportHistoryPage {
  const NasImportHistoryPage({required this.records, required this.nextCursor,
    required this.until, required this.hasMore});
  final List<Map<String, dynamic>> records;
  final int nextCursor;
  final int until;
  final bool hasMore;

  factory NasImportHistoryPage.fromJson(Map<String, dynamic> json) {
    final raw = json['records'];
    if (raw is! List || json['has_more'] is! bool) {
      throw const FormatException('无效历史分页。');
    }
    final next = _int(json, 'next_cursor');
    final until = _int(json, 'until');
    if (next > until) throw const FormatException('历史游标越过高水位。');
    return NasImportHistoryPage(records: raw.map((value) =>
      Map<String, dynamic>.from(value as Map)).toList(growable: false),
      nextCursor: next, until: until, hasMore: json['has_more'] as bool);
  }
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) throw FormatException('$key 必须为非空字符串。');
  return value;
}

int _int(Map<String, dynamic> json, String key, {int minimum = 0}) {
  final value = json[key];
  if (value is! int || value < minimum) throw FormatException('$key 必须为合法整数。');
  return value;
}
