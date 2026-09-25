/// Type-safe transport models for the MomoBox NAS API.
///
/// These models intentionally contain no UI or persistence concerns. Secrets
/// are accepted only at the boundary where the API needs them and are never
/// included in diagnostic output.
library;

DateTime? _readNullableDateTime(Object? value, String field) {
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field must be an ISO-8601 string or null.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$field must be a valid ISO-8601 date-time.');
  }
  return parsed.toUtc();
}

String _readRequiredString(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field is required.');
  }
  return value;
}

int _readRequiredInt(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  throw FormatException('$field is required and must be an integer.');
}

List<T> _readList<T>(
  Map<String, dynamic> json,
  String field,
  T Function(Object? value) readItem,
) {
  final value = json[field];
  if (value is! List) throw FormatException('$field must be an array.');
  return value.map(readItem).toList(growable: false);
}

class NasRegisterRequest {
  const NasRegisterRequest({
    required this.email,
    required this.password,
    required this.nickname,
  });

  final String email;
  final String password;
  final String nickname;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'email': email,
        'password': password,
        'nickname': nickname,
      };
}

class NasRegisterDeviceRequest {
  const NasRegisterDeviceRequest({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    this.appVersion,
  });

  final String deviceId;
  final String deviceName;
  final String platform;
  final String? appVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'device_id': deviceId,
        'device_name': deviceName,
        'platform': platform,
        if (appVersion != null && appVersion!.trim().isNotEmpty)
          'app_version': appVersion,
      };
}

class NasLoginRequest {
  const NasLoginRequest({
    required this.email,
    required this.password,
    this.device,
  });

  final String email;
  final String password;
  final NasRegisterDeviceRequest? device;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'email': email,
        'password': password,
        if (device != null) 'device': device!.toJson(),
      };
}

class NasRefreshRequest {
  const NasRefreshRequest(this.refreshToken);

  final String refreshToken;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'refresh_token': refreshToken,
      };
}

class NasUser {
  const NasUser({
    required this.id,
    required this.email,
    required this.nickname,
  });

  final String id;
  final String email;
  final String nickname;

  factory NasUser.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('user must be an object.');
    final json = Map<String, dynamic>.from(value);
    return NasUser(
      id: _readRequiredString(json, 'id'),
      email: _readRequiredString(json, 'email'),
      nickname: _readRequiredString(json, 'nickname'),
    );
  }
}

class NasAuthResponse {
  const NasAuthResponse({
    required this.user,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });

  final NasUser user;
  final String accessToken;
  final String refreshToken;
  final int expiresIn;

  factory NasAuthResponse.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('auth response must be an object.');
    }
    final json = Map<String, dynamic>.from(value);
    final accessToken = _readRequiredString(json, 'access_token');
    final refreshToken = _readRequiredString(json, 'refresh_token');
    final expiresIn = _readRequiredInt(json, 'expires_in');
    if (expiresIn <= 0) {
      throw const FormatException('expires_in must be greater than zero.');
    }
    return NasAuthResponse(
      user: NasUser.fromJson(json['user']),
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresIn: expiresIn,
    );
  }
}

class NasFamilyMembership {
  const NasFamilyMembership({
    required this.familyId,
    required this.role,
  });

  final String familyId;
  final String role;

  factory NasFamilyMembership.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('family membership must be an object.');
    }
    final json = Map<String, dynamic>.from(value);
    return NasFamilyMembership(
      familyId: _readRequiredString(json, 'family_id'),
      role: _readRequiredString(json, 'role'),
    );
  }
}

class NasSyncDevice {
  const NasSyncDevice({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.createdAt,
    this.appVersion,
    this.lastSeenAt,
    this.revokedAt,
    this.status,
    this.lastSyncCursor,
    this.lastSyncAt,
    this.isCurrent,
  });

  final String id;
  final String deviceName;
  final String platform;
  final DateTime createdAt;
  final String? appVersion;
  final DateTime? lastSeenAt;
  final DateTime? revokedAt;
  final String? status;
  final int? lastSyncCursor;
  final DateTime? lastSyncAt;
  final bool? isCurrent;

  factory NasSyncDevice.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('sync device must be an object.');
    }
    final json = Map<String, dynamic>.from(value);
    final createdAt = _readNullableDateTime(json['created_at'], 'created_at');
    if (createdAt == null) {
      throw const FormatException('created_at is required.');
    }
    final cursorValue = json['last_sync_cursor'];
    final lastSyncCursor = cursorValue == null
        ? null
        : cursorValue is int
            ? cursorValue
            : cursorValue is num
                ? cursorValue.toInt()
                : (throw const FormatException(
                    'last_sync_cursor must be an integer.',
                  ));
    final isCurrent = json['is_current'];
    if (isCurrent != null && isCurrent is! bool) {
      throw const FormatException('is_current must be a boolean.');
    }
    return NasSyncDevice(
      id: _readRequiredString(json, 'id'),
      deviceName: _readRequiredString(json, 'device_name'),
      platform: _readRequiredString(json, 'platform'),
      createdAt: createdAt,
      appVersion: json['app_version'] as String?,
      lastSeenAt: _readNullableDateTime(json['last_seen_at'], 'last_seen_at'),
      revokedAt: _readNullableDateTime(json['revoked_at'], 'revoked_at'),
      status: json['status'] as String?,
      lastSyncCursor: lastSyncCursor,
      lastSyncAt: _readNullableDateTime(json['last_sync_at'], 'last_sync_at'),
      isCurrent: isCurrent as bool?,
    );
  }
}

class NasMeResponse {
  const NasMeResponse({
    required this.user,
    required this.families,
    required this.devices,
  });

  final NasUser user;
  final List<NasFamilyMembership> families;
  final List<NasSyncDevice> devices;

  factory NasMeResponse.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('me response must be an object.');
    final json = Map<String, dynamic>.from(value);
    return NasMeResponse(
      user: NasUser.fromJson(json['user']),
      families: _readList(
        json,
        'families',
        NasFamilyMembership.fromJson,
      ),
      devices: _readList(json, 'devices', NasSyncDevice.fromJson),
    );
  }
}
