import 'dart:convert';

class BackupFormat {
  static const formatName = 'momobox-backup';
  static const supportedVersion = 3;
  static const legacyVersions = {1, 2, 3};
  static const requiredSections = [
    'products',
    'batches',
    'stock_movements',
    'shopping_entries',
    'settings',
    'reminder_acknowledgements',
    'barcode_lookup_cache',
  ];

  /// UI wording and optional export metadata describe a core-data backup,
  /// not a portable file archive. Old parsers ignore this extra header field.
  static const scopeDescription =
      '核心 JSON 备份包含商品、批次、库存变动、采购清单、提醒记录、条码缓存及用户业务配置'
      '（含家务和 AI 聊天）；不包含图片、说明书文件、媒体 OCR 文本、凭据、NAS 绑定或同步状态。';
  static const privacyDescription =
      '备份 JSON 和 AI 聊天历史可能包含个人信息；请保存在可信位置。'
      '备份与恢复均在本地进行，无需上传文件。';
  static const restoreDescription =
      '导入只补充缺失的核心记录，不覆盖已有数据，也不删除或替换当前设备身份与同步状态。'
      '新设备需重新配置 NAS 和服务密钥；媒体文件需另行迁移。';

  static const excludedSettingPrefixes = [
    'nas_',
    'nas:',
    'sync_',
    'sync:',
    'reminder_sync_policy:',
    'ha_',
    'ha:',
    'home_assistant_',
    'home_assistant:',
  ];

  static const coverage = <String, Object>{
    'metadata_version': 1,
    'kind': 'core_json',
    'includes': requiredSections,
    'settings': {
      'content_privacy': 'user_authored_business_text_preserved_not_redacted',
      'includes': 'user_business_configuration',
      'examples': ['recurring_chores_list', 'ai_conversations_v1'],
      'excluded_prefixes': excludedSettingPrefixes,
      'credentials': 'excluded_and_profile_fields_sanitized',
    },
    'excludes': [
      'media_assets',
      'media_files',
      'manual_files',
      'media_ocr_text',
      'media_ocr_search_index',
      'secure_storage_credentials',
      'device_account_family_bindings',
      'sync_states',
      'sync_outbox',
      'sync_conflicts',
      'sync_applied_changes',
    ],
    'restore_policy': 'insert_missing_preserve_existing_and_device_identity',
    'media_restore_supported': false,
    'privacy': {
      'may_contain_personal_information': true,
      'sensitive_content': ['business_data', 'user_settings', 'ai_chat_history'],
      'processing': 'local_only',
      'upload_required': false,
      'storage_advice': 'keep_in_a_trusted_location',
    },
  };

  static const _deviceSettingKeys = {
    'device_id',
    'user_id',
    'family_id',
    'family_code',
    'local_workspace_id',
  };
  static const _profileFields = {
    'id',
    'name',
    'endpoint',
    'model',
    'endpointType',
    'fallbackRole',
  };
  static final _credentialField = RegExp(
    r'(^|_)(api_?key|access_?token|refresh_?token|id_?token|auth_?token|token|password|secret|credential[s]?|authorization|cookie|bearer|signature|sig|hmac)(_|$)',
  );
  static const _sensitiveQueryParameters = <String>{
    // Generic API/auth query parameters.
    'key',
    'api_key',
    'apikey',
    'api_token',
    'auth',
    'auth_token',
    'access_token',
    'refresh_token',
    'id_token',
    'token',
    'password',
    'secret',
    'credential',
    'credentials',
    'authorization',
    'bearer',
    'cookie',
    'sig',
    'signature',
    'hmac',
    // Common signed URL parameters. Removing the complete signing tuple is
    // safer than leaving a replayable URL with only part of its credentials.
    'x_amz_algorithm',
    'x_amz_credential',
    'x_amz_date',
    'x_amz_expires',
    'x_amz_security_token',
    'x_amz_signedheaders',
    'x_amz_signature',
    'x_goog_algorithm',
    'x_goog_credential',
    'x_goog_date',
    'x_goog_expires',
    'x_goog_signedheaders',
    'x_goog_signature',
    // Azure SAS parameters.
    'sv',
    'st',
    'se',
    'sp',
    'sr',
    'skoid',
    'sktid',
    'skt',
    'ske',
    'sks',
    'skv',
  };
  static final _normalizedExcludedSettingPrefixes =
      excludedSettingPrefixes.map(_normalizedKey).toSet();

  static String _normalizedKey(String key) => key
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match[1]}_${match[2]}',
      )
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  static bool isPortableSetting(String key) {
    final normalized = _normalizedKey(key.trim());
    return !_normalizedExcludedSettingPrefixes.any(normalized.startsWith) &&
        !_deviceSettingKeys.contains(normalized) &&
        !_credentialField.hasMatch(normalized);
  }

  /// Returns null for non-portable settings. Invalid profile JSON fails closed:
  /// never return its raw value, which might contain a legacy inline API key.
  /// The same policy must be applied on export AND historical backup import.
  static String? portableSettingValue(String key, String value) {
    if (!isPortableSetting(key)) return null;
    final normalizedKey = _normalizedKey(key.trim());
    if (normalizedKey == 'ai_api_profiles' ||
        normalizedKey == 'barcode_api_profiles') {
      // Existing installs use empty text for an unconfigured profile list.
      if (value.trim().isEmpty) return value;
      Object? decoded;
      try {
        decoded = jsonDecode(value);
      } on FormatException {
        throw const FormatException('服务配置 JSON 损坏，无法安全移除凭据。');
      }
      if (decoded is! List) {
        throw const FormatException('服务配置必须是对象列表，无法安全移除凭据。');
      }
      final profiles = <Map<String, String>>[];
      for (final entry in decoded) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('服务配置列表包含非对象记录。');
        }
        // Persist only the current non-secret configuration contract, rather
        // than guessing which unknown/header/nested fields contain secrets.
        final profile = <String, String>{};
        for (final field in _profileFields) {
          final fieldValue = entry[field];
          if (fieldValue == null) continue;
          if (fieldValue is! String) {
            throw const FormatException('服务配置字段必须是文本。');
          }
          profile[field] = field == 'endpoint'
              ? _sanitizeEndpoint(fieldValue)
              : fieldValue;
        }
        profiles.add(profile);
      }
      return jsonEncode(profiles);
    }
    if (normalizedKey == 'ai_api_endpoint' ||
        normalizedKey == 'ai_secondary_endpoint' ||
        normalizedKey == 'ai_fallback_endpoint') {
      return _sanitizeEndpoint(value);
    }
    // Preserve user-authored business data (including chores and chat) verbatim.
    return value;
  }

  static String _sanitizeEndpoint(String endpoint) {
    if (endpoint.isEmpty) return endpoint;
    final uri = Uri.tryParse(endpoint);
    if (uri == null) {
      throw const FormatException('服务地址损坏，无法安全移除凭据。');
    }
    final query = Map<String, List<String>>.from(uri.queryParametersAll);
    query.removeWhere((key, _) {
      final normalized = _normalizedKey(key);
      return _sensitiveQueryParameters.contains(normalized) ||
          _credentialField.hasMatch(normalized);
    });
    if (uri.userInfo.isEmpty && query.length == uri.queryParametersAll.length) {
      return endpoint;
    }
    final sanitized = uri
        .replace(userInfo: '', queryParameters: query)
        .toString()
        // Barcode profiles substitute this literal template before requesting.
        .replaceAll(RegExp(r'%7Bbarcode%7D', caseSensitive: false), '{barcode}');
    // Removing every credential parameter must not leave an empty query marker.
    return query.isEmpty
        ? sanitized.replaceFirst(RegExp(r'\?(?=#|$)'), '')
        : sanitized;
  }

  static const _requiredStringFields = <String, List<String>>{
    'products': ['id', 'name', 'category', 'unit', 'created_at', 'updated_at'],
    'batches': [
      'id',
      'product_id',
      'date_source',
      'date_precision',
      'created_at',
      'updated_at',
    ],
    'stock_movements': ['id', 'product_id', 'type', 'created_at'],
    'shopping_entries': [
      'id',
      'item_name',
      'reason',
      'created_at',
      'updated_at',
    ],
    'settings': ['key', 'value', 'updated_at'],
    'reminder_acknowledgements': ['reminder_key', 'fingerprint', 'acknowledged_at'],
    'barcode_lookup_cache': ['barcode', 'source', 'fetched_at', 'expires_at'],
  };

  static const _nullableStringFields = <String, List<String>>{
    'products': ['brand', 'specification', 'barcode', 'location'],
    'batches': ['batch_no', 'production_date', 'expiry_date'],
    'stock_movements': ['batch_id', 'note'],
    'shopping_entries': ['product_id', 'category'],
    'settings': [],
    'reminder_acknowledgements': [],
    'barcode_lookup_cache': ['payload_json'],
  };

  static const _requiredIntFields = <String, List<String>>{
    'products': ['low_stock_threshold'],
    'batches': ['initial_quantity', 'remaining_quantity'],
    'stock_movements': ['quantity'],
    'shopping_entries': ['target_quantity'],
    'settings': [],
    'reminder_acknowledgements': [],
    'barcode_lookup_cache': [],
  };

  static const _requiredBoolFields = <String, List<String>>{
    'products': [],
    'batches': ['is_opened', 'is_discarded'],
    'stock_movements': [],
    'shopping_entries': ['is_completed'],
    'settings': [],
    'reminder_acknowledgements': [],
    'barcode_lookup_cache': [],
  };

  static const _dateFields = <String, List<String>>{
    'products': ['created_at', 'updated_at', 'deleted_at'],
    'batches': ['production_date', 'expiry_date', 'created_at', 'updated_at', 'deleted_at'],
    'stock_movements': ['created_at'],
    'shopping_entries': ['created_at', 'updated_at', 'deleted_at'],
    'settings': ['updated_at'],
    'reminder_acknowledgements': ['acknowledged_at'],
    'barcode_lookup_cache': ['fetched_at', 'expires_at'],
  };

  static Map<String, dynamic> parse(String content) {
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw const FormatException('备份 JSON 格式错误。');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('不是有效的 MomoBox JSON 备份文件。');
    }
    if (decoded['format'] != formatName) {
      throw const FormatException('不是有效的 MomoBox JSON 备份文件。');
    }
    final version = decoded['version'];
    if (version is! int || !legacyVersions.contains(version)) {
      throw const FormatException('当前版本不支持该备份格式。');
    }
    final exportedAt = decoded['exported_at'];
    if (exportedAt != null &&
        (exportedAt is! String || DateTime.tryParse(exportedAt) == null)) {
      throw const FormatException('备份头中的 "exported_at" 必须是 ISO 8601 日期时间。');
    }
    final document = Map<String, dynamic>.from(decoded);
    for (final section in requiredSections) {
      final isLegacyOptional = version < 3 && (section == 'reminder_acknowledgements' || section == 'barcode_lookup_cache');
      if (isLegacyOptional && document[section] == null) {
        document[section] = <dynamic>[];
        continue;
      }
      if (document[section] is! List<dynamic>) {
        throw FormatException('备份文件缺少或损坏 "$section" 数据段。');
      }
    }
    return document;
  }

  static List<Map<String, dynamic>> records(
    Map<String, dynamic> document,
    String section,
  ) {
    if (!requiredSections.contains(section)) {
      throw ArgumentError.value(section, 'section', '不是受支持的备份数据段。');
    }
    final source = document[section];
    if (source is! List<dynamic>) {
      throw FormatException('备份文件缺少或损坏 "$section" 数据段。');
    }

    final records = <Map<String, dynamic>>[];
    for (var index = 0; index < source.length; index++) {
      final raw = source[index];
      if (raw is! Map<String, dynamic>) {
        throw FormatException('备份文件的 "$section" 第 ${index + 1} 条记录格式错误。');
      }
      final record = Map<String, dynamic>.from(raw);
      _validateRecord(section, record, index + 1);
      records.add(record);
    }
    return List.unmodifiable(records);
  }

  static void _validateRecord(
    String section,
    Map<String, dynamic> record,
    int index,
  ) {
    for (final field in _requiredStringFields[section]!) {
      final value = record[field];
      // Optional AI endpoints/settings legitimately use an empty string. The
      // value must still be present and typed; IDs and other fields stay nonempty.
      final allowsEmpty = section == 'settings' && field == 'value';
      if (value is! String) {
        _recordError(section, index, '“$field”必须是文本。');
      } else if (!allowsEmpty && value.trim().isEmpty) {
        _recordError(section, index, '“$field”必须是非空文本。');
      }
    }
    for (final field in _nullableStringFields[section]!) {
      final value = record[field];
      if (value != null && value is! String) {
        _recordError(section, index, '“$field”必须是文本或 null。');
      }
    }
    for (final field in _requiredIntFields[section]!) {
      if (record[field] is! int) {
        _recordError(section, index, '“$field”必须是整数。');
      }
    }
    for (final field in _requiredBoolFields[section]!) {
      if (record[field] is! bool) {
        _recordError(section, index, '“$field”必须是布尔值。');
      }
    }
    for (final field in _dateFields[section]!) {
      final value = record[field];
      if (value != null && (value is! String || DateTime.tryParse(value) == null)) {
        _recordError(section, index, '“$field”必须是 ISO 8601 日期时间或 null。');
      }
    }
    _validateInventoryValues(section, record, index);
  }

  static void _validateInventoryValues(
    String section,
    Map<String, dynamic> record,
    int index,
  ) {
    switch (section) {
      case 'products':
        if ((record['low_stock_threshold'] as int) < 1) {
          _recordError(section, index, '“low_stock_threshold”必须大于 0。');
        }
      case 'batches':
        final initial = record['initial_quantity'] as int;
        final remaining = record['remaining_quantity'] as int;
        if (initial < 1 || remaining < 0 || remaining > initial) {
          _recordError(
            section,
            index,
            '批次数量必须满足 initial_quantity > 0 且 0 ≤ remaining_quantity ≤ initial_quantity。',
          );
        }
        if (record['is_discarded'] as bool && remaining != 0) {
          _recordError(section, index, '已报废批次的 remaining_quantity 必须为 0。');
        }
      case 'stock_movements':
        if ((record['quantity'] as int) == 0) {
          _recordError(section, index, '“quantity”不能为 0。');
        }
      case 'shopping_entries':
        if ((record['target_quantity'] as int) < 1) {
          _recordError(section, index, '“target_quantity”必须大于 0。');
        }
      case 'settings':
      case 'reminder_acknowledgements':
      case 'barcode_lookup_cache':
        return;
    }
  }

  static Never _recordError(String section, int index, String reason) =>
      throw FormatException('备份文件的 "$section" 第 $index 条记录格式错误：$reason');
}
