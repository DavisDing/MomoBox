DateTime? _optionalDateTime(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('Invalid $key');
  return DateTime.tryParse(value) ?? (throw FormatException('Invalid $key'));
}

enum NasHaIntegrationStatus {
  unknown,
  healthy,
  unavailable,
  invalidCredentials,
  disabled,
}

NasHaIntegrationStatus _parseIntegrationStatus(Object? value) {
  switch (value) {
    case 'healthy':
      return NasHaIntegrationStatus.healthy;
    case 'unavailable':
      return NasHaIntegrationStatus.unavailable;
    case 'invalid_credentials':
      return NasHaIntegrationStatus.invalidCredentials;
    case 'disabled':
      return NasHaIntegrationStatus.disabled;
    default:
      return NasHaIntegrationStatus.unknown;
  }
}

String _integrationStatusValue(NasHaIntegrationStatus value) {
  switch (value) {
    case NasHaIntegrationStatus.unknown:
      return 'unknown';
    case NasHaIntegrationStatus.healthy:
      return 'healthy';
    case NasHaIntegrationStatus.unavailable:
      return 'unavailable';
    case NasHaIntegrationStatus.invalidCredentials:
      return 'invalid_credentials';
    case NasHaIntegrationStatus.disabled:
      return 'disabled';
  }
}

class NasHaIntegration {
  const NasHaIntegration({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.status,
    required this.createdAt,
    this.lastCheckedAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final Uri baseUrl;
  final NasHaIntegrationStatus status;
  final DateTime? lastCheckedAt;
  final DateTime createdAt;
  final DateTime? updatedAt;

  factory NasHaIntegration.fromJson(Object? value) {
    final json = _asObject(value, 'integration');
    final baseUrl = _validatedBaseUrl(_requiredString(json, 'base_url'));
    return NasHaIntegration(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      baseUrl: baseUrl,
      status: _parseIntegrationStatus(json['status']),
      lastCheckedAt: _optionalDateTime(json, 'last_checked_at'),
      createdAt: _optionalDateTime(json, 'created_at') ??
          (throw const FormatException('Missing created_at')),
      updatedAt: _optionalDateTime(json, 'updated_at'),
    );
  }
}

class NasHaConnectionTestResult {
  const NasHaConnectionTestResult({
    required this.connected,
    required this.checkedAt,
    this.serverVersion,
    this.errorCode,
  });

  final bool connected;
  final DateTime checkedAt;
  final String? serverVersion;
  final String? errorCode;

  factory NasHaConnectionTestResult.fromJson(Object? value) {
    final json = _asObject(value, 'connection test');
    final connected = json['connected'];
    if (connected is! bool) throw const FormatException('Invalid connected');
    return NasHaConnectionTestResult(
      connected: connected,
      checkedAt: _optionalDateTime(json, 'checked_at') ??
          (throw const FormatException('Missing checked_at')),
      serverVersion: _nullableString(json['server_version']),
      errorCode: _nullableString(json['error_code']),
    );
  }
}

class NasHaDiscoverResult {
  const NasHaDiscoverResult({
    required this.integrationId,
    required this.devices,
    required this.entities,
  });

  final String integrationId;
  final int devices;
  final int entities;

  factory NasHaDiscoverResult.fromJson(Object? value) {
    final json = _asObject(value, 'discover');
    return NasHaDiscoverResult(
      integrationId: _requiredString(json, 'integration_id'),
      devices: _requiredInt(json, 'devices'),
      entities: _requiredInt(json, 'entities'),
    );
  }
}

class NasHaEntity {
  const NasHaEntity({
    required this.id,
    required this.integrationId,
    required this.entityId,
    required this.domain,
    required this.name,
    required this.isVisible,
    required this.isControllable,
    this.areaName,
    this.capabilities = const <String>[],
    this.currentState,
    this.lastStateAt,
  });

  final String id;
  final String integrationId;
  final String entityId;
  final String domain;
  final String name;
  final String? areaName;
  final List<String> capabilities;
  final String? currentState;
  final bool isVisible;
  final bool isControllable;
  final DateTime? lastStateAt;

  factory NasHaEntity.fromJson(Object? value) {
    final json = _asObject(value, 'entity');
    return NasHaEntity(
      id: _requiredString(json, 'id'),
      integrationId: _requiredString(json, 'integration_id'),
      entityId: _requiredString(json, 'entity_id'),
      domain: _requiredString(json, 'domain'),
      name: _requiredString(json, 'name'),
      areaName: _nullableString(json['area_name']),
      capabilities: _stringList(json['capabilities']),
      currentState: _nullableString(json['current_state']),
      isVisible: _requiredBool(json, 'is_visible'),
      isControllable: _requiredBool(json, 'is_controllable'),
      lastStateAt: _optionalDateTime(json, 'last_state_at'),
    );
  }
}

class NasHaEntityState {
  const NasHaEntityState({
    required this.entityId,
    required this.state,
    required this.attributes,
    required this.fetchedAt,
  });

  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;
  final DateTime fetchedAt;

  factory NasHaEntityState.fromJson(Object? value) {
    final json = _asObject(value, 'entity state');
    final attributes = json['attributes'];
    if (attributes != null && attributes is! Map) {
      throw const FormatException('Invalid attributes');
    }
    return NasHaEntityState(
      entityId: _requiredString(json, 'entity_id'),
      state: _requiredString(json, 'state'),
      attributes: attributes == null ? const <String, dynamic>{} : Map<String, dynamic>.from(attributes),
      fetchedAt: _optionalDateTime(json, 'fetched_at') ??
          (throw const FormatException('Missing fetched_at')),
    );
  }
}

enum NasHaCommand {
  turnOn,
  turnOff,
  toggle,
  setBrightness,
  setTemperature,
  setHvacMode,
  play,
  pause,
  activateScene,
  runScript,
}

abstract class NasHaCommandParameters {
  const NasHaCommandParameters();

  Map<String, dynamic> toJson();
}

class NasHaBrightnessParameters extends NasHaCommandParameters {
  NasHaBrightnessParameters(int brightness)
      : assert(brightness >= 0 && brightness <= 100),
        brightness = _checkedBrightness(brightness);

  final int brightness;

  @override
  Map<String, dynamic> toJson() => {'brightness': brightness};
}

class NasHaTemperatureParameters extends NasHaCommandParameters {
  NasHaTemperatureParameters(num temperature)
      : temperature = _checkedTemperature(temperature.toDouble());

  final double temperature;

  @override
  Map<String, dynamic> toJson() => {'temperature': temperature};
}

class NasHaHvacModeParameters extends NasHaCommandParameters {
  NasHaHvacModeParameters(String hvacMode)
      : hvacMode = _checkedHvacMode(hvacMode);

  final String hvacMode;

  @override
  Map<String, dynamic> toJson() => {'hvac_mode': hvacMode};
}

int _checkedBrightness(int value) {
  if (value < 0 || value > 100) {
    throw ArgumentError.value(value, 'brightness', 'must be between 0 and 100');
  }
  return value;
}

double _checkedTemperature(double value) {
  if (value < -100 || value > 200) {
    throw ArgumentError.value(value, 'temperature', 'must be between -100 and 200');
  }
  return value;
}

String _checkedHvacMode(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 64 || normalized.contains(RegExp(r'[\r\n]'))) {
    throw ArgumentError.value(value, 'hvacMode', 'must be 1-64 characters without line breaks');
  }
  return normalized;
}

String nasHaCommandValue(NasHaCommand command) {
  switch (command) {
    case NasHaCommand.turnOn:
      return 'turn_on';
    case NasHaCommand.turnOff:
      return 'turn_off';
    case NasHaCommand.toggle:
      return 'toggle';
    case NasHaCommand.setBrightness:
      return 'set_brightness';
    case NasHaCommand.setTemperature:
      return 'set_temperature';
    case NasHaCommand.setHvacMode:
      return 'set_hvac_mode';
    case NasHaCommand.play:
      return 'play';
    case NasHaCommand.pause:
      return 'pause';
    case NasHaCommand.activateScene:
      return 'activate_scene';
    case NasHaCommand.runScript:
      return 'run_script';
  }
}

class NasHaCommandResult {
  const NasHaCommandResult({
    required this.accepted,
    required this.entityId,
    required this.command,
    required this.executedAt,
    this.state,
  });

  final bool accepted;
  final String entityId;
  final String command;
  final DateTime executedAt;
  final NasHaEntityState? state;

  factory NasHaCommandResult.fromJson(Object? value) {
    final json = _asObject(value, 'command response');
    final accepted = json['accepted'];
    if (accepted is! bool) throw const FormatException('Invalid accepted');
    return NasHaCommandResult(
      accepted: accepted,
      entityId: _requiredString(json, 'entity_id'),
      command: _requiredString(json, 'command'),
      executedAt: _optionalDateTime(json, 'executed_at') ??
          (throw const FormatException('Missing executed_at')),
      state: json['state'] == null ? null : NasHaEntityState.fromJson(json['state']),
    );
  }
}

class NasHaEntityPermission {
  const NasHaEntityPermission({
    required this.integrationId,
    required this.entityId,
    required this.role,
    required this.canView,
    required this.canControl,
    required this.allowedCommands,
  });

  final String integrationId;
  final String entityId;
  final String role;
  final bool canView;
  final bool canControl;
  final List<String> allowedCommands;

  factory NasHaEntityPermission.fromJson(Object? value) {
    final json = _asObject(value, 'permission');
    return NasHaEntityPermission(
      integrationId: _requiredString(json, 'integration_id'),
      entityId: _requiredString(json, 'entity_id'),
      role: _requiredString(json, 'role'),
      canView: _requiredBool(json, 'can_view'),
      canControl: _requiredBool(json, 'can_control'),
      allowedCommands: _stringList(json['allowed_commands']),
    );
  }

  Map<String, dynamic> toJson() => {
        'integration_id': integrationId,
        'entity_id': entityId,
        'role': role,
        'can_view': canView,
        'can_control': canControl,
        'allowed_commands': allowedCommands,
      };
}

class NasHaIntegrationInput {
  const NasHaIntegrationInput({
    required this.name,
    required this.baseUrl,
    required this.accessToken,
  });

  final String name;
  final Uri baseUrl;
  final String accessToken;

  Map<String, dynamic> toJson() => {
        'name': _validatedIntegrationName(name),
        'base_url': _validatedBaseUrl(baseUrl.toString()).toString(),
        'access_token': _validatedAccessToken(accessToken),
      };
}

class NasHaIntegrationUpdate {
  const NasHaIntegrationUpdate({
    this.name,
    this.baseUrl,
    this.accessToken,
    this.enabled,
  });

  final String? name;
  final Uri? baseUrl;
  final String? accessToken;
  final bool? enabled;

  Map<String, dynamic> toJson() => {
        if (name != null) 'name': _validatedIntegrationName(name!),
        if (baseUrl != null)
          'base_url': _validatedBaseUrl(baseUrl!.toString()).toString(),
        if (accessToken != null) 'access_token': _validatedAccessToken(accessToken!),
        if (enabled != null) 'enabled': enabled,
      };
}

Map<String, dynamic> _asObject(Object? value, String label) {
  if (value is! Map) throw FormatException('Invalid $label response');
  return Map<String, dynamic>.from(value);
}

Uri _validatedBaseUrl(String value) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null ||
      (parsed.scheme != 'http' && parsed.scheme != 'https') ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.query.isNotEmpty ||
      parsed.fragment.isNotEmpty ||
      (parsed.path.isNotEmpty && parsed.path != '/') ||
      (parsed.port != -1 && (parsed.port < 1 || parsed.port > 65535))) {
    throw const FormatException('Invalid base_url');
  }
  return parsed.replace(path: '', query: '', fragment: '');
}

String _validatedIntegrationName(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 120) {
    throw ArgumentError.value(value, 'name', 'must be 1-120 characters');
  }
  return normalized;
}

String _validatedAccessToken(String value) {
  final normalized = value.trim();
  if (normalized.length < 16 || normalized.length > 4096 ||
      normalized.contains(RegExp(r'[\u0000-\u001F\u007F]'))) {
    throw ArgumentError.value(value, 'accessToken', 'must be 16-4096 characters without control characters');
  }
  return normalized;
}

String _requiredStringFromValue(Object? value, String label) {
  if (value is! String || value.trim().isEmpty) throw FormatException('Invalid $label');
  return value;
}

String _requiredString(Map<String, dynamic> json, String key) =>
    _requiredStringFromValue(json[key], key);

String? _nullableString(Object? value) => value == null ? null : _requiredStringFromValue(value, 'string');

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key');
  return value;
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Invalid $key');
  return value;
}

List<String> _stringList(Object? value) {
  if (value == null) return const <String>[];
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('Invalid string list');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

