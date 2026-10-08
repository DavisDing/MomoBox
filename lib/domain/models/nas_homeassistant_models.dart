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
    this.hvacModes = const <String>[],
    this.temperatureMin,
    this.temperatureMax,
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
  final List<String> hvacModes;
  final double? temperatureMin;
  final double? temperatureMax;
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
      hvacModes: _stringList(json['hvac_modes']),
      temperatureMin: _nullableNum(json['temperature_min']),
      temperatureMax: _nullableNum(json['temperature_max']),
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

double? _nullableNum(Object? value) {
  if (value == null) return null;
  if (value is num && value.isFinite) return value.toDouble();
  throw const FormatException('Invalid number');
}

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


/// Integer-count units supported by the first Home Assistant consumable
/// linkage release. Volume and weight conversion is intentionally not done on
/// the client; the NAS service remains authoritative for the inventory result.
enum NasHaConsumableUnit {
  piece,
  capsule,
  tablet,
  load,
  cycle,
}

NasHaConsumableUnit _parseConsumableUnit(Object? value) {
  switch (value) {
    case 'piece':
      return NasHaConsumableUnit.piece;
    case 'capsule':
      return NasHaConsumableUnit.capsule;
    case 'tablet':
      return NasHaConsumableUnit.tablet;
    case 'load':
      return NasHaConsumableUnit.load;
    case 'cycle':
      return NasHaConsumableUnit.cycle;
    default:
      throw FormatException('Invalid consumable unit: $value');
  }
}

String nasHaConsumableUnitValue(NasHaConsumableUnit value) {
  switch (value) {
    case NasHaConsumableUnit.piece:
      return 'piece';
    case NasHaConsumableUnit.capsule:
      return 'capsule';
    case NasHaConsumableUnit.tablet:
      return 'tablet';
    case NasHaConsumableUnit.load:
      return 'load';
    case NasHaConsumableUnit.cycle:
      return 'cycle';
  }
}

class NasHaConsumableGroupItem {
  const NasHaConsumableGroupItem({
    required this.id,
    required this.groupId,
    required this.productId,
    required this.quantity,
    required this.unit,
  });

  final String id;
  final String groupId;
  final String productId;
  final int quantity;
  final NasHaConsumableUnit unit;

  factory NasHaConsumableGroupItem.fromJson(Object? value) {
    final json = _asObject(value, 'consumable group item');
    return NasHaConsumableGroupItem(
      id: _nullableString(json['id']) ?? '',
      groupId: _nullableString(json['group_id']) ?? '',
      productId: _requiredString(json, 'product_id'),
      quantity: _positiveInt(json['quantity'], 'quantity'),
      unit: _parseConsumableUnit(json['unit']),
    );
  }

  Map<String, dynamic> toJson() => {
        if (id.isNotEmpty) 'id': id,
        if (groupId.isNotEmpty) 'group_id': groupId,
        'product_id': productId,
        'quantity': quantity,
        'unit': nasHaConsumableUnitValue(unit),
      };
}

class NasHaConsumableGroup {
  const NasHaConsumableGroup({
    required this.id,
    required this.familyId,
    required this.name,
    required this.description,
    required this.items,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String familyId;
  final String name;
  final String description;
  final List<NasHaConsumableGroupItem> items;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory NasHaConsumableGroup.fromJson(Object? value) {
    final json = _asObject(value, 'consumable group');
    return NasHaConsumableGroup(
      id: _requiredString(json, 'id'),
      familyId: _nullableString(json['family_id']) ?? '',
      name: _requiredString(json, 'name'),
      description: _nullableString(json['description']) ?? '',
      items: _objectList(json['items'], NasHaConsumableGroupItem.fromJson),
      createdAt: _optionalDateTime(json, 'created_at'),
      updatedAt: _optionalDateTime(json, 'updated_at'),
    );
  }

  Map<String, dynamic> toJson() => {
        if (id.isNotEmpty) 'id': id,
        'name': name,
        'description': description,
        'items': items.map((item) => item.toJson()).toList(growable: false),
      };
}

class NasHaConsumableRecipeGroup {
  const NasHaConsumableRecipeGroup({
    required this.id,
    required this.recipeId,
    required this.groupId,
    required this.quantity,
    required this.unit,
  });

  final String id;
  final String recipeId;
  final String groupId;
  final int quantity;
  final NasHaConsumableUnit unit;

  factory NasHaConsumableRecipeGroup.fromJson(Object? value) {
    final json = _asObject(value, 'consumable recipe group');
    return NasHaConsumableRecipeGroup(
      id: _nullableString(json['id']) ?? '',
      recipeId: _nullableString(json['recipe_id']) ?? '',
      groupId: _requiredString(json, 'group_id'),
      quantity: _positiveInt(json['quantity'], 'quantity'),
      unit: _parseConsumableUnit(json['unit']),
    );
  }

  Map<String, dynamic> toJson() => {
        if (id.isNotEmpty) 'id': id,
        if (recipeId.isNotEmpty) 'recipe_id': recipeId,
        'group_id': groupId,
        'quantity': quantity,
        'unit': nasHaConsumableUnitValue(unit),
      };
}

class NasHaConsumableRecipe {
  const NasHaConsumableRecipe({
    required this.id,
    required this.familyId,
    required this.name,
    required this.description,
    required this.groups,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String familyId;
  final String name;
  final String description;
  final List<NasHaConsumableRecipeGroup> groups;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory NasHaConsumableRecipe.fromJson(Object? value) {
    final json = _asObject(value, 'consumable recipe');
    return NasHaConsumableRecipe(
      id: _requiredString(json, 'id'),
      familyId: _nullableString(json['family_id']) ?? '',
      name: _requiredString(json, 'name'),
      description: _nullableString(json['description']) ?? '',
      groups: _objectList(json['groups'], NasHaConsumableRecipeGroup.fromJson),
      createdAt: _optionalDateTime(json, 'created_at'),
      updatedAt: _optionalDateTime(json, 'updated_at'),
    );
  }

  Map<String, dynamic> toJson() => {
        if (id.isNotEmpty) 'id': id,
        'name': name,
        'description': description,
        'groups': groups.map((group) => group.toJson()).toList(growable: false),
      };
}

class NasHaLinkageRule {
  const NasHaLinkageRule({
    required this.id,
    required this.familyId,
    required this.name,
    required this.integrationId,
    required this.entityId,
    required this.applianceDomain,
    required this.startState,
    required this.completeState,
    required this.recipeId,
    required this.enabled,
    required this.requiresConfirmation,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String familyId;
  final String name;
  final String integrationId;
  final String entityId;
  final String applianceDomain;
  final String startState;
  final String completeState;
  final String recipeId;
  final bool enabled;
  final bool requiresConfirmation;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory NasHaLinkageRule.fromJson(Object? value) {
    final json = _asObject(value, 'linkage rule');
    return NasHaLinkageRule(
      id: _requiredString(json, 'id'),
      familyId: _nullableString(json['family_id']) ?? '',
      name: _requiredString(json, 'name'),
      integrationId: _requiredString(json, 'integration_id'),
      entityId: _requiredString(json, 'entity_id'),
      applianceDomain: _requiredString(json, 'appliance_domain'),
      startState: _requiredString(json, 'start_state'),
      completeState: _requiredString(json, 'complete_state'),
      recipeId: _requiredString(json, 'recipe_id'),
      enabled: _requiredBool(json, 'enabled'),
      requiresConfirmation: _requiredBool(json, 'requires_confirmation'),
      createdAt: _optionalDateTime(json, 'created_at'),
      updatedAt: _optionalDateTime(json, 'updated_at'),
    );
  }

  Map<String, dynamic> toJson() => {
        if (id.isNotEmpty) 'id': id,
        'name': name,
        'integration_id': integrationId,
        'entity_id': entityId,
        'appliance_domain': applianceDomain,
        'start_state': startState,
        'complete_state': completeState,
        'recipe_id': recipeId,
        'enabled': enabled,
        // The first release deliberately never permits automatic deduction.
        'requires_confirmation': true,
      };
}

class NasHaPurchaseSuggestion {
  const NasHaPurchaseSuggestion({
    required this.productId,
    required this.productName,
    required this.quantity,
    required this.unit,
  });

  final String productId;
  final String productName;
  final int quantity;
  final NasHaConsumableUnit unit;

  factory NasHaPurchaseSuggestion.fromJson(Object? value) {
    final json = _asObject(value, 'purchase suggestion');
    return NasHaPurchaseSuggestion(
      productId: _requiredString(json, 'product_id'),
      productName: _nullableString(json['product_name']) ?? _requiredString(json, 'product_id'),
      quantity: _positiveInt(json['quantity'], 'quantity'),
      unit: _parseConsumableUnit(json['unit']),
    );
  }
}

enum NasHaLinkageSuggestionStatus {
  pending,
  deducted,
  ignored,
  insufficientStock,
  unknown,
}

NasHaLinkageSuggestionStatus _parseLinkageSuggestionStatus(Object? value) {
  switch (value) {
    case 'pending':
      return NasHaLinkageSuggestionStatus.pending;
    case 'deducted':
      return NasHaLinkageSuggestionStatus.deducted;
    case 'ignored':
      return NasHaLinkageSuggestionStatus.ignored;
    case 'insufficient_stock':
      return NasHaLinkageSuggestionStatus.insufficientStock;
    default:
      return NasHaLinkageSuggestionStatus.unknown;
  }
}

class NasHaLinkageSuggestion {
  const NasHaLinkageSuggestion({
    required this.id,
    required this.familyId,
    required this.ruleId,
    required this.recipeId,
    required this.applianceRunId,
    required this.status,
    required this.requiresConfirmation,
    required this.purchaseSuggestions,
    required this.createdAt,
    this.resolvedAt,
    this.resolvedBy,
    this.ruleName,
    this.deviceName,
    this.eventSummary,
    this.consumableName,
    this.quantity,
    this.unit,
  });

  final String id;
  final String familyId;
  final String ruleId;
  final String recipeId;
  final String applianceRunId;
  final NasHaLinkageSuggestionStatus status;
  final bool requiresConfirmation;
  final List<NasHaPurchaseSuggestion> purchaseSuggestions;
  final DateTime createdAt;
  final DateTime? resolvedAt;
  final String? resolvedBy;
  final String? ruleName;
  final String? deviceName;
  final String? eventSummary;
  final String? consumableName;
  final int? quantity;
  final NasHaConsumableUnit? unit;

  factory NasHaLinkageSuggestion.fromJson(Object? value) {
    final json = _asObject(value, 'linkage suggestion');
    final createdAt = _optionalDateTime(json, 'created_at');
    if (createdAt == null) throw const FormatException('Missing created_at');
    final quantity = _nullablePositiveInt(json['quantity'], 'quantity');
    final rawUnit = json['unit'];
    return NasHaLinkageSuggestion(
      id: _requiredString(json, 'id'),
      familyId: _nullableString(json['family_id']) ?? '',
      ruleId: _requiredString(json, 'rule_id'),
      recipeId: _requiredString(json, 'recipe_id'),
      applianceRunId: _requiredString(json, 'appliance_run_id'),
      status: _parseLinkageSuggestionStatus(json['status']),
      requiresConfirmation: json['requires_confirmation'] is bool
          ? json['requires_confirmation'] as bool
          : true,
      purchaseSuggestions: _objectList(
        json['purchase_suggestions'],
        NasHaPurchaseSuggestion.fromJson,
      ),
      createdAt: createdAt,
      resolvedAt: _optionalDateTime(json, 'resolved_at'),
      resolvedBy: _nullableString(json['resolved_by']),
      ruleName: _nullableString(json['rule_name']),
      deviceName: _nullableString(json['device_name']),
      eventSummary: _nullableString(json['event_summary']),
      consumableName: _nullableString(json['consumable_name']),
      quantity: quantity,
      unit: rawUnit == null ? null : _parseConsumableUnit(rawUnit),
    );
  }
}

int _positiveInt(Object? value, String label) {
  final parsed = value is num ? value.toInt() : int.tryParse('$value');
  if (parsed == null || parsed < 1 || (value is num && value != parsed)) {
    throw FormatException('Invalid $label');
  }
  return parsed;
}

int? _nullablePositiveInt(Object? value, String label) =>
    value == null ? null : _positiveInt(value, label);

List<T> _objectList<T>(Object? value, T Function(Object?) parser) {
  if (value == null) return <T>[];
  if (value is! List) throw const FormatException('Invalid object list');
  return List<T>.unmodifiable(value.map(parser));
}

enum NasHaSuggestionDecision {
  confirm,
  ignore,
}

String nasHaSuggestionDecisionValue(NasHaSuggestionDecision value) {
  switch (value) {
    case NasHaSuggestionDecision.confirm:
      return 'confirm';
    case NasHaSuggestionDecision.ignore:
      return 'ignore';
  }
}
