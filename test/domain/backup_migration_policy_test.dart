import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/backup/backup_format.dart';

void main() {
  test('设备/NAS/同步/提醒同步派生键及安全凭据不可迁移', () {
    for (final key in [
      'nas_user_id',
      'nas_device_id',
      'nas_family_id',
      'nas_server_url',
      'nas_family_code',
      'nas_last_checked_at',
      'sync_local_workspace_id',
      'sync_bootstrap:family:1',
      'sync_aux:family:1:category:1',
      'sync_conflict_cursor:family:1:change',
      'reminder_sync_policy:family:1:reminder-1',
      'SYNC_bootstrap:family:1',
      'nas:device',
      'sync:future',
      'user_id',
      'device_id',
      'family_id',
      'local_workspace_id',
      'ha_access_token',
      'home_assistant_integration',
      'ai_api_key',
      'ai_api_key_profile_1',
      'serviceApiKey',
      'service_access_token',
      'service_refresh_token',
      'password',
      'service_secret',
      'credentials',
      'http_authorization',
    ]) {
      expect(BackupFormat.isPortableSetting(key), isFalse, reason: key);
      expect(BackupFormat.portableSettingValue(key, 'sensitive-value'), isNull,
          reason: key);
    }
  });

  test('正常业务配置、家务及聊天保持原文，不按业务文本关键字删数据', () {
    for (final key in [
      'theme',
      'home_section_order',
      'recurring_chores_list',
      'ai_conversations_v1',
      'ai_usage_logs',
      'ai_model',
      'ai_allow_inventory_writes',
      'reminder_lead_days',
      'reminder_enabled',
      'barcode_api_enabled',
      'custom_business_setting',
    ]) {
      const content = '{"content":"NAS 状态与 token 用量讨论"}';
      expect(BackupFormat.isPortableSetting(key), isTrue, reason: key);
      expect(BackupFormat.portableSettingValue(key, content), content,
          reason: key);
    }
    expect(BackupFormat.portableSettingValue('ai_secondary_endpoint', ''), '');
    expect(BackupFormat.portableSettingValue('ai_api_profiles', ''), '');
  });

  for (final key in ['ai_api_profiles', 'barcode_api_profiles']) {
    test('$key 仅保留非敏感字段，包含未知嵌套凭据的历史配置不会泄露', () {
      final original = [
        {
          'id': 'profile-1',
          'name': '测试服务',
          'endpoint': 'https://service.invalid/v1',
          'model': 'model-1',
          'endpointType': 'responses',
          'fallbackRole': 'primary',
          'apiKey': 'inline-secret',
          '_apiKeyDraft': 'draft-secret',
          'hasApiKey': true,
          'token': 'token-secret',
          'headers': {'Authorization': 'Bearer nested-secret'},
          'futureCredentials': ['future-secret'],
        },
      ];
      final result = BackupFormat.portableSettingValue(key, jsonEncode(original))!;
      expect(jsonDecode(result), [
        {
          'id': 'profile-1',
          'name': '测试服务',
          'endpoint': 'https://service.invalid/v1',
          'model': 'model-1',
          'endpointType': 'responses',
          'fallbackRole': 'primary',
        },
      ]);
      expect(original.single['apiKey'], 'inline-secret');
      expect(BackupFormat.portableSettingValue(key, result), result);
    });

    for (final raw in [
      '{"apiKey":"secret"',
      '{"apiKey":"secret"}',
      '["secret"]',
      '[{"endpoint":{"apiKey":"secret"}}]',
    ]) {
      test('$key 损坏时失败关闭，不返回可能含密钥的原文：$raw', () {
        expect(() => BackupFormat.portableSettingValue(key, raw),
            throwsFormatException);
      });
    }
  }

  test('单独服务地址及配置列表中的地址去除 userinfo 和敏感 query', () {
    const endpoint =
        'https://user:password-secret@ai.invalid/v1?apiKey=key-secret&token=token-secret&region=local';
    for (final key in [
      'ai_api_endpoint', 'ai_secondary_endpoint', 'ai_fallback_endpoint',
    ]) {
      final result = BackupFormat.portableSettingValue(key, endpoint)!;
      final uri = Uri.parse(result);
      expect(uri.userInfo, isEmpty);
      expect(uri.queryParameters, {'region': 'local'});
      expect(result, isNot(contains('secret')));
    }
    final profiles = BackupFormat.portableSettingValue('barcode_api_profiles',
        jsonEncode([{'id': '1', 'endpoint': endpoint}]))!;
    final uri = Uri.parse((jsonDecode(profiles) as List).single['endpoint'] as String);
    expect(uri.userInfo, isEmpty);
    expect(uri.queryParameters, {'region': 'local'});
  });

  test('含凭据的条码地址脱敏后仍保留可替换的条码模板', () {
    final profiles = BackupFormat.portableSettingValue('barcode_api_profiles',
        jsonEncode([
          {'endpoint': 'https://user:secret@service.invalid/{barcode}.json?key=secret'},
        ]))!;
    final endpoint = (jsonDecode(profiles) as List).single['endpoint'] as String;
    expect(endpoint, 'https://service.invalid/{barcode}.json');
    expect(endpoint, contains('{barcode}'));
    expect(endpoint, isNot(contains('secret')));
  });

  test('认证和签名 query 去除而保留业务参数、重复值及条码模板', () {
    const endpoint = 'https://service.invalid/{barcode}.json?auth=auth-secret'
        '&sig=sig-secret&signature=signature-secret&X-Amz-Credential=aws-secret'
        '&X-Amz-Signature=aws-sig-secret&X-Goog-Signature=goog-secret'
        '&fields=name&fields=brand&region=local';
    final profiles = BackupFormat.portableSettingValue('barcode_api_profiles',
        jsonEncode([{'id': 'signed', 'endpoint': endpoint}]))!;
    final sanitized = (jsonDecode(profiles) as List).single['endpoint'] as String;
    expect(sanitized, contains('{barcode}'));
    expect(sanitized, isNot(contains('secret')));
    expect(Uri.parse(sanitized).queryParametersAll, {
      'fields': ['name', 'brand'],
      'region': ['local'],
    });
    expect(BackupFormat.portableSettingValue('ai_api_endpoint',
        'https://service.invalid/v1?auth=secret&signature=secret'),
        'https://service.invalid/v1');
  });

  test('设备身份前缀规范化涵盖历史 camelCase 与不同分隔符', () {
    for (final key in ['NasUserId', 'nas:user:id', 'SyncLocalWorkspaceId',
      'HomeAssistantConnection', 'ReminderSyncPolicy:family:policy']) {
      expect(BackupFormat.isPortableSetting(key), isFalse, reason: key);
    }
    expect(BackupFormat.isPortableSetting('customBusinessSetting'), isTrue);
  });

  test('正常服务地址原文保留，包括条码模板及非敏感 query', () {
    const endpoint =
        'https://service.invalid/{barcode}.json?fields=name&region=local';
    final profiles = BackupFormat.portableSettingValue('barcode_api_profiles',
        jsonEncode([{'id': '1', 'endpoint': endpoint}]))!;
    expect((jsonDecode(profiles) as List).single['endpoint'], endpoint);
    expect(BackupFormat.portableSettingValue('ai_api_endpoint',
        'https://ai.invalid/v1?region=local'), 'https://ai.invalid/v1?region=local');
  });

  test('覆盖元数据可选且不改变 v1-v3 所需段或原解析兼容性', () {
    for (final version in [1, 2, 3]) {
      final document = <String, Object>{
        'format': BackupFormat.formatName,
        'version': version,
        for (final section in BackupFormat.requiredSections) section: [],
      };
      final original = BackupFormat.parse(jsonEncode(document));
      final withCoverage = BackupFormat.parse(jsonEncode({
        ...document,
        'coverage': BackupFormat.coverage,
      }));
      for (final section in BackupFormat.requiredSections) {
        expect(BackupFormat.records(original, section),
            BackupFormat.records(withCoverage, section));
      }
      expect(withCoverage['coverage'], BackupFormat.coverage);
    }
    expect(BackupFormat.coverage['kind'], 'core_json');
    expect(BackupFormat.coverage['media_restore_supported'], isFalse);
    expect(BackupFormat.coverage['excludes'], contains('media_ocr_text'));
    expect(BackupFormat.coverage['excludes'], contains('sync_outbox'));
    final settings = BackupFormat.coverage['settings'] as Map;
    expect(settings['excluded_prefixes'], contains('reminder_sync_policy:'));
    final privacy = BackupFormat.coverage['privacy'] as Map;
    expect(privacy['may_contain_personal_information'], isTrue);
    expect(privacy['sensitive_content'], contains('ai_chat_history'));
    expect(privacy['upload_required'], isFalse);
    expect(BackupFormat.privacyDescription, contains('无需上传'));
    expect(BackupFormat.scopeDescription, contains('媒体 OCR'));
    expect(BackupFormat.restoreDescription, contains('当前设备身份'));
  });
}
