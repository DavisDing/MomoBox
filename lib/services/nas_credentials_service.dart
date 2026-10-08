import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/models/nas_models.dart';

class NasStoredCredentials {
  const NasStoredCredentials({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    this.serverIdentity,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;
  final String? serverIdentity;
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
  static const _serverIdentityKey = 'nas_server_identity';

  final FlutterSecureStorage _storage;
  Future<void> _tail = Future<void>.value();

  // A shared credential service serializes reads/writes/deletes across old and
  // new auth clients. A logout cannot race a partially persisted refresh.
  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<NasStoredCredentials?> readForServer(String serverIdentity) =>
      _serialized(() => _read(serverIdentity: serverIdentity));

  Future<NasStoredCredentials?> read() => _serialized(() => _read());

  Future<NasStoredCredentials?> _read({String? serverIdentity}) async {
    try {
      if (serverIdentity != null) {
        // Check the commit marker before touching possibly corrupt residual
        // values. Unbound/other-server credentials are retained, not recovered.
        final binding = _normalize(await _storage.read(key: _serverIdentityKey));
        if (binding != serverIdentity) return null;
      }
      final values = await Future.wait<String?>(<Future<String?>>[
        _storage.read(key: _accessTokenKey),
        _storage.read(key: _refreshTokenKey),
        _storage.read(key: _expiresAtKey),
        _storage.read(key: _serverIdentityKey),
      ]);
      if (serverIdentity != null && _normalize(values[3]) != serverIdentity) {
        return null;
      }
      final accessToken = _normalize(values[0]);
      final refreshToken = _normalize(values[1]);
      final expiresAtMillis = int.tryParse(values[2] ?? '');
      if (accessToken == null || refreshToken == null || expiresAtMillis == null) {
        return null;
      }
      return NasStoredCredentials(
        accessToken: accessToken,
        refreshToken: refreshToken,
        serverIdentity: _normalize(values[3]),
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

  Future<void> save(
    NasAuthResponse response, {
    DateTime? now,
    String? serverIdentity,
  }) async {
    await saveIfCurrent(response, now: now, serverIdentity: serverIdentity);
  }

  Future<bool> saveIfCurrent(
    NasAuthResponse response, {
    DateTime? now,
    String? serverIdentity,
    bool Function()? isCurrent,
  }) => _serialized(() async {
    if (isCurrent != null && !isCurrent()) return false;
    final accessToken = _normalize(response.accessToken);
    final refreshToken = _normalize(response.refreshToken);
    if (accessToken == null || refreshToken == null || response.expiresIn <= 0) {
      throw const NasCredentialsException('NAS 返回了无效的登录凭证。');
    }
    final issuedAt = now?.toUtc() ?? DateTime.now().toUtc();
    final expiresAt = issuedAt.add(Duration(seconds: response.expiresIn));
    try {
      // Write the binding last as a commit marker. A failed/partial save must
      // never make a mixed token pair eligible for automatic restore.
      await _storage.delete(key: _serverIdentityKey);
      await _storage.write(key: _accessTokenKey, value: accessToken);
      await _storage.write(key: _refreshTokenKey, value: refreshToken);
      await _storage.write(
        key: _expiresAtKey,
        value: expiresAt.millisecondsSinceEpoch.toString(),
      );
      if (isCurrent != null && !isCurrent()) return false;
      if (serverIdentity != null) {
        await _storage.write(key: _serverIdentityKey, value: serverIdentity);
      }
      if (isCurrent != null && !isCurrent()) {
        await _storage.delete(key: _serverIdentityKey);
        return false;
      }
      return true;
    } catch (error) {
      throw const NasCredentialsException('无法保存 NAS 安全凭证。');
    }
  });

  Future<void> clear() => clearIfCurrent();

  Future<void> clearIfCurrent({bool Function()? isCurrent}) => _serialized(() async {
    if (isCurrent != null && !isCurrent()) return;
    try {
      await Future.wait<void>(<Future<void>>[
        _storage.delete(key: _accessTokenKey),
        _storage.delete(key: _refreshTokenKey),
        _storage.delete(key: _expiresAtKey),
        _storage.delete(key: _serverIdentityKey),
      ]);
    } catch (error) {
      throw const NasCredentialsException('无法清除 NAS 安全凭证。');
    }
  });

  String? _normalize(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
