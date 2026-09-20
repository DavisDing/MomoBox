import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureSettingsService {
  static const aiApiKeyKey = 'ai_api_key';
  static const _aiProfileKeyPrefix = 'ai_api_key_profile_';

  SecureSettingsService({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<String?> readAiApiKey() => _readNormalized(aiApiKeyKey);

  Future<void> writeAiApiKey(String value) => _writeOrDelete(aiApiKeyKey, value);

  Future<void> deleteAiApiKey() => _storage.delete(key: aiApiKeyKey);

  Future<String?> readAiApiKeyForProfile(String profileId) {
    final normalizedId = _normalizeProfileId(profileId);
    if (normalizedId == null) return Future.value(null);
    return _readNormalized('$_aiProfileKeyPrefix$normalizedId');
  }

  Future<void> writeAiApiKeyForProfile(String profileId, String value) {
    final normalizedId = _normalizeProfileId(profileId);
    if (normalizedId == null) {
      throw ArgumentError.value(profileId, 'profileId', 'AI 配置 ID 不能为空。');
    }
    return _writeOrDelete('$_aiProfileKeyPrefix$normalizedId', value);
  }

  Future<void> deleteAiApiKeyForProfile(String profileId) {
    final normalizedId = _normalizeProfileId(profileId);
    if (normalizedId == null) return Future.value();
    return _storage.delete(key: '$_aiProfileKeyPrefix$normalizedId');
  }

  Future<String?> _readNormalized(String key) async {
    final value = await _storage.read(key: key);
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  Future<void> _writeOrDelete(String key, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      await _storage.delete(key: key);
      return;
    }
    // Never log or mirror this value to the regular settings database. The
    // only persistent copy is the platform secure-storage entry.
    await _storage.write(key: key, value: normalized);
  }

  String? _normalizeProfileId(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.contains(RegExp(r'[\r\n]'))) return null;
    return normalized;
  }
}
