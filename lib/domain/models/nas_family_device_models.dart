/// Type-safe DTOs for NAS family and sync-device endpoints.
///
/// These models intentionally stay independent from UI state and persistence.
/// They accept the snake_case API contract and a small set of camelCase aliases
/// so clients remain compatible with older NAS responses.
library;

Map<String, dynamic> _object(Object? value, String name) {
  if (value is! Map) throw FormatException('$name must be an object.');
  return Map<String, dynamic>.from(value);
}

Object? _first(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    if (json.containsKey(key)) return json[key];
  }
  return null;
}

String _requiredString(
  Map<String, dynamic> json,
  String field, {
  List<String> aliases = const <String>[],
}) {
  final value = _first(json, <String>[field, ...aliases]);
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field is required.');
  }
  return value;
}

String? _optionalString(
  Map<String, dynamic> json,
  String field, {
  List<String> aliases = const <String>[],
}) {
  final value = _first(json, <String>[field, ...aliases]);
  if (value == null) return null;
  if (value is! String) throw FormatException('$field must be a string or null.');
  return value;
}

int _requiredInt(
  Map<String, dynamic> json,
  String field, {
  List<String> aliases = const <String>[],
}) {
  final value = _first(json, <String>[field, ...aliases]);
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  throw FormatException('$field is required and must be an integer.');
}

DateTime _requiredDateTime(
  Map<String, dynamic> json,
  String field, {
  List<String> aliases = const <String>[],
}) {
  final value = _first(json, <String>[field, ...aliases]);
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field is required.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$field must be a date-time.');
  return parsed.toUtc();
}

DateTime? _optionalDateTime(
  Map<String, dynamic> json,
  String field, {
  List<String> aliases = const <String>[],
}) {
  final value = _first(json, <String>[field, ...aliases]);
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field must be a date-time or null.');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$field must be a date-time.');
  return parsed.toUtc();
}

class NasFamilyDto {
  const NasFamilyDto({
    required this.id,
    required this.name,
    required this.createdAt,
  });

  final String id;
  final String name;
  final DateTime createdAt;

  factory NasFamilyDto.fromJson(Object? value) {
    final json = _object(value, 'family');
    return NasFamilyDto(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      createdAt: _requiredDateTime(json, 'created_at', aliases: const ['createdAt']),
    );
  }
}

class NasFamilyMembershipDto {
  const NasFamilyMembershipDto({
    required this.familyId,
    required this.role,
    this.userId,
    this.joinedAt,
  });

  final String familyId;
  final String role;
  final String? userId;
  final DateTime? joinedAt;

  factory NasFamilyMembershipDto.fromJson(Object? value) {
    final json = _object(value, 'membership');
    return NasFamilyMembershipDto(
      familyId: _requiredString(json, 'family_id', aliases: const ['familyId']),
      role: _requiredString(json, 'role'),
      userId: _optionalString(json, 'user_id', aliases: const ['userId']),
      joinedAt: _optionalDateTime(json, 'joined_at', aliases: const ['joinedAt']),
    );
  }
}

class NasFamilyResponseDto {
  const NasFamilyResponseDto({
    required this.family,
    required this.membership,
  });

  final NasFamilyDto family;
  final NasFamilyMembershipDto membership;

  factory NasFamilyResponseDto.fromJson(Object? value) {
    final json = _object(value, 'family response');
    return NasFamilyResponseDto(
      family: NasFamilyDto.fromJson(json['family']),
      membership: NasFamilyMembershipDto.fromJson(json['membership']),
    );
  }
}

class NasFamilyMemberDto {
  const NasFamilyMemberDto({
    required this.id,
    required this.email,
    required this.nickname,
    required this.role,
    required this.joinedAt,
  });

  final String id;
  final String email;
  final String nickname;
  final String role;
  final DateTime joinedAt;

  factory NasFamilyMemberDto.fromJson(Object? value) {
    final json = _object(value, 'family member');
    return NasFamilyMemberDto(
      id: _requiredString(json, 'id'),
      email: _requiredString(json, 'email'),
      nickname: _requiredString(json, 'nickname'),
      role: _requiredString(json, 'role'),
      joinedAt: _requiredDateTime(json, 'joined_at', aliases: const ['joinedAt']),
    );
  }
}

class NasFamilyInviteDto {
  const NasFamilyInviteDto({
    required this.inviteId,
    required this.code,
    required this.expiresAt,
    required this.remainingUses,
  });

  final String inviteId;
  final String code;
  final DateTime expiresAt;
  final int remainingUses;

  factory NasFamilyInviteDto.fromJson(Object? value) {
    final json = _object(value, 'invite response');
    return NasFamilyInviteDto(
      inviteId: _requiredString(json, 'invite_id', aliases: const ['inviteId']),
      code: _requiredString(json, 'code'),
      expiresAt: _requiredDateTime(json, 'expires_at', aliases: const ['expiresAt']),
      remainingUses: _requiredInt(
        json,
        'remaining_uses',
        aliases: const ['remainingUses'],
      ),
    );
  }
}

class NasDeviceDto {
  const NasDeviceDto({
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

  factory NasDeviceDto.fromJson(Object? value) {
    final json = _object(value, 'sync device');
    final cursor = _first(json, const ['last_sync_cursor', 'lastSyncCursor']);
    int? parsedCursor;
    if (cursor != null) {
      if (cursor is int) {
        parsedCursor = cursor;
      } else if (cursor is num && cursor == cursor.roundToDouble()) {
        parsedCursor = cursor.toInt();
      } else {
        throw const FormatException('last_sync_cursor must be an integer.');
      }
    }
    final current = _first(json, const ['is_current', 'isCurrent']);
    if (current != null && current is! bool) {
      throw const FormatException('is_current must be a boolean.');
    }
    return NasDeviceDto(
      id: _requiredString(json, 'id', aliases: const ['device_id', 'deviceId']),
      deviceName: _requiredString(json, 'device_name', aliases: const ['deviceName']),
      platform: _requiredString(json, 'platform'),
      createdAt: _requiredDateTime(json, 'created_at', aliases: const ['createdAt']),
      appVersion: _optionalString(json, 'app_version', aliases: const ['appVersion']),
      lastSeenAt: _optionalDateTime(json, 'last_seen_at', aliases: const ['lastSeenAt']),
      revokedAt: _optionalDateTime(json, 'revoked_at', aliases: const ['revokedAt']),
      status: _optionalString(json, 'status'),
      lastSyncCursor: parsedCursor,
      lastSyncAt: _optionalDateTime(json, 'last_sync_at', aliases: const ['lastSyncAt']),
      isCurrent: current as bool?,
    );
  }
}

class NasCreateFamilyRequest {
  const NasCreateFamilyRequest({required this.name});
  final String name;
  Map<String, dynamic> toJson() => <String, dynamic>{'name': name};
}

class NasCreateInviteRequest {
  const NasCreateInviteRequest({
    required this.expiresInHours,
    required this.maxUses,
  });

  final int expiresInHours;
  final int maxUses;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'expires_in_hours': expiresInHours,
        'max_uses': maxUses,
      };
}

class NasJoinFamilyRequest {
  const NasJoinFamilyRequest({required this.code});
  final String code;
  Map<String, dynamic> toJson() => <String, dynamic>{'code': code};
}

class NasRegisterFamilyDeviceRequest {
  const NasRegisterFamilyDeviceRequest({
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

List<NasFamilyMemberDto> parseNasFamilyMembers(Object? value) {
  final json = _object(value, 'members response');
  final raw = json['members'];
  if (raw is! List) throw const FormatException('members must be an array.');
  return raw.map(NasFamilyMemberDto.fromJson).toList(growable: false);
}

List<NasDeviceDto> parseNasDevices(Object? value) {
  final json = _object(value, 'devices response');
  final raw = json['devices'];
  if (raw is! List) throw const FormatException('devices must be an array.');
  return raw.map(NasDeviceDto.fromJson).toList(growable: false);
}
