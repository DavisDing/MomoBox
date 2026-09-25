import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/models/nas_models.dart';

class NasStoredCredentials {
  const NasStoredCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
}

class NasCredentialsException implements Exception {
  const NasCredentialsException(this.message);

  final String message;

  @override
  String toString() => 'NasCredentialsException';
}

/// Secure storage boundary for NAS tokens.
///
/// This service uses a NAS-specific key namespace and never shares keys with
/// the AI credential storage. Token values are never copied to regular app
/// settings or written to logs.
class NasCredentialsService {
  NasCredentialsService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _accessTokenKey = 'nas_access_token';
  static const _refreshTokenKey = 'nas_refresh_token';
  static const _expiresAtKey = 'nas_access_token_expires_at_ms';

  final FlutterSecureStorage _storage;

  Future<NasStoredCredentials?> read() async {
    try {
      final values = await Future.wait<String?>(<Future<String?>>[
        _storage.read(key: _accessTokenKey),
        _storage.read(key: _refreshTokenKey),
        _storage.read(key: _expiresAtKey),
      ]);
      final accessToken = _normalize(values[0]);
      final refreshToken = _normalize(values[1]);
      final expiresAtMillis = int.tryParse(values[2] ?? '');
      if (accessToken == null || refreshToken == null || expiresAtMillis == null) {
        return null;
      }
      return NasStoredCredentials(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          expiresAtMillis,
          isUtc: true,
        ),
      );
    } on NasCredentialsException {
      rethrow;
    } catch (error) {
      throw const NasCredentialsException('无法读取 NAS 安全凭证。');
    }
  }

  Future<void> save(NasAuthResponse response, {DateTime? now}) async {
    final accessToken = _normalize(response.accessToken);
    final refreshToken = _normalize(response.refreshToken);
    if (accessToken == null || refreshToken == null || response.expiresIn <= 0) {
      throw const NasCredentialsException('NAS 返回了无效的登录凭证。');
    }
    final issuedAt = now?.toUtc() ?? DateTime.now().toUtc();
    final expiresAt = issuedAt.add(Duration(seconds: response.expiresIn));
    try {
      await _storage.write(key: _accessTokenKey, value: accessToken);
      await _storage.write(key: _refreshTokenKey, value: refreshToken);
      await _storage.write(
        key: _expiresAtKey,
        value: expiresAt.millisecondsSinceEpoch.toString(),
      );
    } catch (error) {
      throw const NasCredentialsException('无法保存 NAS 安全凭证。');
    }
  }

  Future<void> clear() async {
    try {
      await Future.wait<void>(<Future<void>>[
        _storage.delete(key: _accessTokenKey),
        _storage.delete(key: _refreshTokenKey),
        _storage.delete(key: _expiresAtKey),
      ]);
    } catch (error) {
      throw const NasCredentialsException('无法清除 NAS 安全凭证。');
    }
  }

  String? _normalize(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
