import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/nas/nas_api_error.dart';
import '../../data/repositories/nas_smart_home_repository.dart';
import '../../domain/models/nas_homeassistant_models.dart';
import '../../domain/models/smart_home_models.dart';
import '../controllers/providers.dart';

const _unset = Object();

/// The HA controller deliberately owns the remote-to-UI mapping.
///
/// No device is created until it has come from the NAS entity endpoint. The
/// previous mock repository is not used here, so an unavailable NAS/HA cannot
/// be rendered as an online or successfully controlled device.
class SmartHomeState {
  const SmartHomeState({
    required this.devices,
    required this.scenes,
    required this.logs,
    required this.haStatus,
    required this.haAddress,
    required this.nasAddress,
    required this.nasOnline,
    this.integrations = const <NasHaIntegration>[],
    this.entities = const <NasHaEntity>[],
    this.permissions = const <NasHaEntityPermission>[],
    this.consumableGroups = const <NasHaConsumableGroup>[],
    this.consumableRecipes = const <NasHaConsumableRecipe>[],
    this.linkageRules = const <NasHaLinkageRule>[],
    this.linkageActionId,
    this.linkageError,
    this.entityStates = const <String, NasHaEntityState>{},
    this.staleEntityIds = const <String>{},
    this.accessDeniedEntityIds = const <String>{},
    this.isLoading = false,
    this.isCommandLoading = false,
    this.commandDeviceId,
    this.message,
    this.commandError,
    this.lastRefreshedAt,
  });

  final List<SmartDevice> devices;
  // Scenes remain empty because no real NAS scene contract is defined yet.
  // Linkage logs are always projected from NAS suggestions; local inventory
  // matching and local deduction are intentionally not performed.
  final List<SmartScene> scenes;
  final List<ConsumableLinkageLog> logs;
  final HaConnectionStatus haStatus;
  final String haAddress;
  final String nasAddress;
  final bool nasOnline;
  final List<NasHaIntegration> integrations;
  final List<NasHaEntity> entities;
  final List<NasHaEntityPermission> permissions;
  final List<NasHaConsumableGroup> consumableGroups;
  final List<NasHaConsumableRecipe> consumableRecipes;
  final List<NasHaLinkageRule> linkageRules;
  final String? linkageActionId;
  final String? linkageError;
  final Map<String, NasHaEntityState> entityStates;
  final Set<String> staleEntityIds;
  final Set<String> accessDeniedEntityIds;
  final bool isLoading;
  final bool isCommandLoading;
  final String? commandDeviceId;
  final String? message;
  final String? commandError;
  final DateTime? lastRefreshedAt;

  bool get hasPermissionError => accessDeniedEntityIds.isNotEmpty;

  SmartHomeState copyWith({
    List<SmartDevice>? devices,
    List<SmartScene>? scenes,
    List<ConsumableLinkageLog>? logs,
    HaConnectionStatus? haStatus,
    String? haAddress,
    String? nasAddress,
    bool? nasOnline,
    List<NasHaIntegration>? integrations,
    List<NasHaEntity>? entities,
    List<NasHaEntityPermission>? permissions,
    List<NasHaConsumableGroup>? consumableGroups,
    List<NasHaConsumableRecipe>? consumableRecipes,
    List<NasHaLinkageRule>? linkageRules,
    Object? linkageActionId = _unset,
    Object? linkageError = _unset,
    Map<String, NasHaEntityState>? entityStates,
    Set<String>? staleEntityIds,
    Set<String>? accessDeniedEntityIds,
    bool? isLoading,
    bool? isCommandLoading,
    Object? commandDeviceId = _unset,
    Object? message = _unset,
    Object? commandError = _unset,
    Object? lastRefreshedAt = _unset,
  }) {
    return SmartHomeState(
      devices: devices ?? this.devices,
      scenes: scenes ?? this.scenes,
      logs: logs ?? this.logs,
      haStatus: haStatus ?? this.haStatus,
      haAddress: haAddress ?? this.haAddress,
      nasAddress: nasAddress ?? this.nasAddress,
      nasOnline: nasOnline ?? this.nasOnline,
      integrations: integrations ?? this.integrations,
      entities: entities ?? this.entities,
      permissions: permissions ?? this.permissions,
      consumableGroups: consumableGroups ?? this.consumableGroups,
      consumableRecipes: consumableRecipes ?? this.consumableRecipes,
      linkageRules: linkageRules ?? this.linkageRules,
      linkageActionId: identical(linkageActionId, _unset) ? this.linkageActionId : linkageActionId as String?,
      linkageError: identical(linkageError, _unset) ? this.linkageError : linkageError as String?,
      entityStates: entityStates ?? this.entityStates,
      staleEntityIds: staleEntityIds ?? this.staleEntityIds,
      accessDeniedEntityIds: accessDeniedEntityIds ?? this.accessDeniedEntityIds,
      isLoading: isLoading ?? this.isLoading,
      isCommandLoading: isCommandLoading ?? this.isCommandLoading,
      commandDeviceId: identical(commandDeviceId, _unset)
          ? this.commandDeviceId
          : commandDeviceId as String?,
      message: identical(message, _unset) ? this.message : message as String?,
      commandError: identical(commandError, _unset) ? this.commandError : commandError as String?,
      lastRefreshedAt: identical(lastRefreshedAt, _unset)
          ? this.lastRefreshedAt
          : lastRefreshedAt as DateTime?,
    );
  }
}

final nasSmartHomeRepositoryProvider = Provider<NasSmartHomeRepository>((ref) {
  final connection = ref.watch(nasConnectionProvider);
  final repository = NasSmartHomeRepository.fromBaseUrl(connection.serverUrl);
  ref.onDispose(repository.close);
  return repository;
});

class SmartHomeController extends StateNotifier<SmartHomeState> {
  SmartHomeController(
    this._repository, {
    required String nasAddress,
  })  : _nasAddress = nasAddress,
        super(
          SmartHomeState(
            devices: const <SmartDevice>[],
            scenes: const <SmartScene>[],
            logs: const <ConsumableLinkageLog>[],
            haStatus: HaConnectionStatus.unconfigured,
            haAddress: '',
            nasAddress: nasAddress,
            nasOnline: false,
          ),
        ) {
    unawaited(refresh());
  }

  static const _staleAfter = Duration(minutes: 5);

  final NasSmartHomeRepository _repository;
  final String _nasAddress;
  Future<void>? _refreshInFlight;
  final Map<String, NasHaEntity> _entitiesByKey = <String, NasHaEntity>{};
  final Map<String, NasHaEntityState> _statesByKey = <String, NasHaEntityState>{};
  final Map<String, bool> _stateFetchDenied = <String, bool>{};
  List<NasHaLinkageSuggestion> _linkageSuggestions = const <NasHaLinkageSuggestion>[];
  final Uuid _uuid = const Uuid();

  String _key(String integrationId, String entityId) => '$integrationId::$entityId';

  @override
  void dispose() {
    _entitiesByKey.clear();
    _statesByKey.clear();
    _stateFetchDenied.clear();
    _linkageSuggestions = const <NasHaLinkageSuggestion>[];
    super.dispose();
  }

  Future<void> refresh() {
    final current = _refreshInFlight;
    if (current != null) return current;
    final next = _refreshInternal();
    _refreshInFlight = next;
    return next.whenComplete(() {
      if (identical(_refreshInFlight, next)) _refreshInFlight = null;
    });
  }

  Future<void> _refreshInternal() async {
    if (!_repository.isConfigured) {
      _setUnconfigured('尚未配置 NAS 地址，无法读取 Home Assistant。');
      return;
    }

    if (mounted) {
      state = state.copyWith(
        isLoading: true,
        haStatus: HaConnectionStatus.syncing,
        nasAddress: _nasAddress,
        message: null,
        commandError: null,
      );
    }

    try {
      final hasCredentials = await _repository.restoreCredentials();
      if (!hasCredentials) {
        _setUnconfigured('尚未登录 NAS，无法读取 Home Assistant 集成。');
        return;
      }

      final integrations = await _repository.listIntegrations();
      if (!mounted) return;
      if (integrations.isEmpty) {
        state = state.copyWith(
          isLoading: false,
          haStatus: HaConnectionStatus.unconfigured,
          haAddress: '',
          nasOnline: true,
          integrations: const <NasHaIntegration>[],
          entities: const <NasHaEntity>[],
          permissions: const <NasHaEntityPermission>[],
          entityStates: const <String, NasHaEntityState>{},
          staleEntityIds: const <String>{},
          accessDeniedEntityIds: const <String>{},
          devices: const <SmartDevice>[],
          message: 'NAS 已连接，但尚未配置 Home Assistant 集成。',
          lastRefreshedAt: DateTime.now().toUtc(),
        );
        return;
      }

      final integration = _selectIntegration(integrations);
      final connection = await _repository.testIntegration(integration.id);
      if (!mounted) return;
      if (!connection.connected) {
        _setOffline(
          'Home Assistant 当前不可用${connection.errorCode == null ? '' : '（${connection.errorCode}）'}。',
          integrations: integrations,
          integration: integration,
        );
        return;
      }

      final results = await Future.wait<Object>(<Future<Object>>[
        _repository.listEntities(integrationId: integration.id),
        _repository.listPermissions(),
      ]);
      final entities = (results[0] as List<NasHaEntity>)
          .where((entity) => entity.isVisible)
          .toList(growable: false);
      final permissions = results[1] as List<NasHaEntityPermission>;

      _entitiesByKey
        ..clear()
        ..addEntries(entities.map((entity) => MapEntry(
              _key(entity.integrationId, entity.entityId),
              entity,
            )));
      _statesByKey.clear();
      _stateFetchDenied.clear();

      await Future.wait<void>(entities.map(_fetchState));
      if (!mounted) return;

      final staleEntityIds = <String>{};
      for (final entity in entities) {
        final key = _key(entity.integrationId, entity.entityId);
        final fetched = _statesByKey[key];
        if (fetched == null || _isStale(fetched.fetchedAt)) {
          staleEntityIds.add(key);
        }
      }

      final accessDenied = <String>{
        ..._stateFetchDenied.keys,
        ...entities
            .where((entity) => !entity.isControllable)
            .map((entity) => _key(entity.integrationId, entity.entityId)),
      };
      final nextStates = Map<String, NasHaEntityState>.unmodifiable(_statesByKey);
      await _refreshLinkageData(entities: entities);
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        haStatus: staleEntityIds.isEmpty
            ? HaConnectionStatus.online
            : HaConnectionStatus.stale,
        haAddress: integration.baseUrl.toString(),
        nasOnline: true,
        integrations: List<NasHaIntegration>.unmodifiable(integrations),
        entities: List<NasHaEntity>.unmodifiable(entities),
        permissions: List<NasHaEntityPermission>.unmodifiable(permissions),
        entityStates: nextStates,
        staleEntityIds: Set<String>.unmodifiable(staleEntityIds),
        accessDeniedEntityIds: Set<String>.unmodifiable(accessDenied),
        devices: _mapDevices(entities, staleEntityIds),
        message: accessDenied.isEmpty
            ? (staleEntityIds.isEmpty ? null : '部分设备状态已过期，当前仅展示最近已知状态。')
            : '部分设备当前没有控制权限，控制请求仍以 NAS 服务端授权为准。',
        lastRefreshedAt: DateTime.now().toUtc(),
      );
    } catch (error) {
      if (!mounted) return;
      _setFailure(error);
    } finally {
      if (mounted && state.isLoading) {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  Future<void> _refreshLinkageData({List<NasHaEntity>? entities}) async {
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _repository.listConsumableGroups(),
        _repository.listConsumableRecipes(),
        _repository.listLinkageRules(),
        _repository.listLinkageSuggestions(),
      ]);
      _linkageSuggestions = (results[3] as List<NasHaLinkageSuggestion>);
      final groups = results[0] as List<NasHaConsumableGroup>;
      final recipes = results[1] as List<NasHaConsumableRecipe>;
      final rules = results[2] as List<NasHaLinkageRule>;
      if (!mounted) return;
      state = state.copyWith(
        consumableGroups: List<NasHaConsumableGroup>.unmodifiable(groups),
        consumableRecipes: List<NasHaConsumableRecipe>.unmodifiable(recipes),
        linkageRules: List<NasHaLinkageRule>.unmodifiable(rules),
        logs: _mapLinkageLogs(
          _linkageSuggestions,
          rules: rules,
          entities: entities ?? state.entities,
        ),
        linkageError: null,
      );
    } catch (error) {
      // Device state remains useful if the optional linkage routes have not
      // been deployed yet. Never create local suggestions or local deductions.
      if (!mounted) return;
      state = state.copyWith(
        logs: const <ConsumableLinkageLog>[],
        linkageError: error is NasApiError ? error.message : '读取耗材联动数据失败。',
      );
    }
  }

  List<ConsumableLinkageLog> _mapLinkageLogs(
    List<NasHaLinkageSuggestion> suggestions, {
    List<NasHaLinkageRule>? rules,
    List<NasHaEntity>? entities,
  }) {
    final resolvedRules = rules ?? state.linkageRules;
    final resolvedEntities = entities ?? state.entities;
    return List<ConsumableLinkageLog>.unmodifiable(suggestions.map((suggestion) {
      final rule = resolvedRules.where((item) => item.id == suggestion.ruleId).firstOrNull;
      final entity = resolvedEntities.where((item) =>
          item.integrationId == (rule?.integrationId ?? '') &&
          item.entityId == (rule?.entityId ?? '')).firstOrNull;
      final firstPurchase = suggestion.purchaseSuggestions.firstOrNull;
      final name = suggestion.consumableName ??
          (suggestion.purchaseSuggestions.isEmpty
              ? (suggestion.recipeId.isEmpty ? '未命名耗材' : suggestion.recipeId)
              : suggestion.purchaseSuggestions.map((item) => item.productName).join('、'));
      final quantity = suggestion.quantity ?? firstPurchase?.quantity ?? 1;
      final unit = suggestion.unit == null
          ? (firstPurchase?.unit.name ?? '件')
          : suggestion.unit!.name;
      return ConsumableLinkageLog(
        id: suggestion.id,
        deviceName: suggestion.deviceName ?? entity?.name ?? 'Home Assistant 设备',
        eventSummary: suggestion.eventSummary ?? '运行 ${suggestion.applianceRunId} 已完成',
        consumableName: name,
        quantity: quantity,
        unit: _unitLabel(unit),
        status: _mapSuggestionStatus(suggestion.status),
        timestamp: suggestion.createdAt,
        purchaseSuggestions: suggestion.purchaseSuggestions
            .map((item) => ConsumablePurchaseSuggestion(
                  productId: item.productId,
                  productName: item.productName,
                  quantity: item.quantity,
                  unit: _unitLabel(item.unit.name),
                ))
            .toList(growable: false),
        ruleDescription: suggestion.ruleName ?? rule?.name ?? '设备事件触发耗材建议',
      );
    }));
  }

  ConsumableActionStatus _mapSuggestionStatus(NasHaLinkageSuggestionStatus status) {
    switch (status) {
      case NasHaLinkageSuggestionStatus.pending:
        return ConsumableActionStatus.pending;
      case NasHaLinkageSuggestionStatus.deducted:
        return ConsumableActionStatus.deducted;
      case NasHaLinkageSuggestionStatus.ignored:
        return ConsumableActionStatus.ignored;
      case NasHaLinkageSuggestionStatus.insufficientStock:
        return ConsumableActionStatus.insufficientStock;
      case NasHaLinkageSuggestionStatus.unknown:
        return ConsumableActionStatus.pending;
    }
  }

  String _unitLabel(String value) {
    const labels = <String, String>{
      'piece': '件',
      'capsule': '颗',
      'tablet': '片',
      'load': '次',
      'cycle': '次',
    };
    return labels[value] ?? value;
  }

  Future<void> _fetchState(NasHaEntity entity) async {
    final key = _key(entity.integrationId, entity.entityId);
    try {
      final remoteState = await _repository.fetchEntityState(
        integrationId: entity.integrationId,
        entityId: entity.entityId,
      );
      _statesByKey[key] = remoteState;
    } on NasApiError catch (error) {
      if (error.kind == NasApiErrorKind.forbidden ||
          error.kind == NasApiErrorKind.unauthorized) {
        _stateFetchDenied[key] = true;
      }
      // Keep no fabricated state. _mapDevices may use the server's cached
      // current_state and will mark it stale because no fresh fetch exists.
    } catch (_) {
      // A single broken entity must not hide all other real entities.
    }
  }

  NasHaIntegration _selectIntegration(List<NasHaIntegration> integrations) {
    for (final integration in integrations) {
      if (integration.status == NasHaIntegrationStatus.healthy) return integration;
    }
    return integrations.first;
  }

  bool _isStale(DateTime fetchedAt) =>
      DateTime.now().toUtc().difference(fetchedAt.toUtc()) > _staleAfter;

  List<SmartDevice> _mapDevices(
    List<NasHaEntity> entities,
    Set<String> staleEntityIds,
  ) {
    return List<SmartDevice>.unmodifiable(
      entities.map((entity) {
        final key = _key(entity.integrationId, entity.entityId);
        final remoteState = _statesByKey[key];
        final rawState = remoteState?.state ?? entity.currentState;
        final attributes = remoteState?.attributes ?? const <String, dynamic>{};
        final isUnavailable = rawState == null ||
            rawState == 'unknown' ||
            rawState == 'unavailable';
        final stale = staleEntityIds.contains(key) || remoteState == null;
        final type = _deviceType(entity.domain);
        final isOn = _isOn(entity.domain, rawState);
        final status = _statusText(
          entity,
          rawState,
          stale: stale,
          denied: _stateFetchDenied[key] == true,
        );
        return SmartDevice(
          id: key,
          name: entity.name,
          room: entity.areaName?.trim().isNotEmpty == true ? entity.areaName! : '未分区',
          type: type,
          isOn: isOn,
          brightness: _brightness(attributes),
          temperature: _temperature(attributes),
          mode: _displayHvacMode(rawState, attributes),
          windSpeed: _stringAttribute(attributes, 'fan_mode') ?? '未知',
          statusText: status,
          washerState: _washerState(rawState),
          isReachable: !isUnavailable && !stale && _stateFetchDenied[key] != true,
        );
      }),
    );
  }

  DeviceType _deviceType(String domain) {
    switch (domain.toLowerCase()) {
      case 'light':
        return DeviceType.light;
      case 'media_player':
        return DeviceType.tv;
      case 'climate':
        return DeviceType.climate;
      case 'washer':
        return DeviceType.washer;
      case 'switch':
        return DeviceType.switchDevice;
      default:
        return DeviceType.switchDevice;
    }
  }

  bool _isOn(String domain, String? value) {
    if (value == null) return false;
    final normalized = value.toLowerCase();
    if (domain == 'climate') return normalized != 'off' && normalized != 'unknown' && normalized != 'unavailable';
    return normalized == 'on' || normalized == 'playing' || normalized == 'active' || normalized == 'running';
  }

  String _statusText(
    NasHaEntity entity,
    String? rawState, {
    required bool stale,
    required bool denied,
  }) {
    if (denied) return '无权限查看实时状态';
    if (rawState == null) return '暂无状态';
    if (rawState == 'unavailable') return '设备离线';
    if (rawState == 'unknown') return '状态未知';
    if (stale) return '最近状态：${_localizedState(rawState)}（可能已过期）';
    return _localizedState(rawState);
  }

  String _localizedState(String value) {
    const values = <String, String>{
      'on': '已开启',
      'off': '已关闭',
      'playing': '播放中',
      'paused': '已暂停',
      'idle': '空闲',
      'heat': '制热',
      'cool': '制冷',
      'dry': '除湿',
      'fan_only': '送风',
      'auto': '自动',
      'running': '运行中',
      'completed': '已完成',
    };
    return values[value.toLowerCase()] ?? value;
  }

  int _brightness(Map<String, dynamic> attributes) {
    final percentage = _numberAttribute(attributes, 'brightness_pct');
    if (percentage != null) return percentage.round().clamp(0, 100);
    final raw = _numberAttribute(attributes, 'brightness');
    if (raw == null) return 80;
    return raw <= 100 ? raw.round().clamp(0, 100) : (raw / 255 * 100).round().clamp(0, 100);
  }

  double _temperature(Map<String, dynamic> attributes) {
    final value = _numberAttribute(attributes, 'temperature') ??
        _numberAttribute(attributes, 'current_temperature');
    return (value ?? 25).clamp(-100, 200).toDouble();
  }

  String _displayHvacMode(String? state, Map<String, dynamic> attributes) {
    final raw = _stringAttribute(attributes, 'hvac_mode') ?? state;
    switch (raw) {
      case 'cool':
        return '制冷';
      case 'heat':
        return '制热';
      case 'fan_only':
        return '送风';
      case 'dry':
        return '除湿';
      default:
        return raw ?? '未知';
    }
  }

  WasherState _washerState(String? value) {
    switch (value?.toLowerCase()) {
      case 'running':
        return WasherState.running;
      case 'completed':
        return WasherState.completed;
      default:
        return WasherState.idle;
    }
  }

  String? _stringAttribute(Map<String, dynamic> attributes, String key) {
    final value = attributes[key];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  num? _numberAttribute(Map<String, dynamic> attributes, String key) {
    final value = attributes[key];
    if (value is num && value.isFinite) return value;
    return value is String ? num.tryParse(value) : null;
  }

  NasHaEntity? _entityFor(String id) => _entitiesByKey[id];

  Future<void> toggleDevice(String id) => _sendCommandForDevice(
        id,
        NasHaCommand.toggle,
      );

  Future<void> setClimateMode(String id, String mode) async {
    final entity = _entityFor(id);
    if (entity == null) {
      _commandFailure('未找到对应的远程实体。');
      return;
    }
    final remoteMode = _remoteHvacMode(entity, mode);
    if (entity.hvacModes.isNotEmpty && !entity.hvacModes.contains(remoteMode)) {
      _commandFailure('该空调不支持“$mode”模式，未发送控制请求。');
      return;
    }
    await _sendCommandForDevice(
      id,
      NasHaCommand.setHvacMode,
      parameters: NasHaHvacModeParameters(remoteMode),
    );
  }

  Future<void> setClimateWindSpeed(String id, String speed) async {
    // The NAS typed-command contract intentionally has no fan-speed command.
    // Do not mutate the UI optimistically or send raw service_data.
    _commandFailure('当前 NAS 安全命令协议未开放风速控制，未发送请求。');
  }

  Future<void> updateClimateTemperature(String id, double delta) async {
    final entity = _entityFor(id);
    if (entity == null) {
      _commandFailure('未找到对应的远程实体。');
      return;
    }
    final device = state.devices.where((item) => item.id == id).firstOrNull;
    if (device == null) {
      _commandFailure('未找到对应的设备状态。');
      return;
    }
    final min = entity.temperatureMin ?? 16;
    final max = entity.temperatureMax ?? 30;
    final temperature = (device.temperature + delta).clamp(min, max).toDouble();
    await _sendCommandForDevice(
      id,
      NasHaCommand.setTemperature,
      parameters: NasHaTemperatureParameters(temperature),
    );
  }

  Future<void> updateLightBrightness(String id, int brightness) =>
      _sendCommandForDevice(
        id,
        NasHaCommand.setBrightness,
        parameters: NasHaBrightnessParameters(brightness.clamp(0, 100)),
      );

  Future<void> _sendCommandForDevice(
    String id,
    NasHaCommand command, {
    NasHaCommandParameters? parameters,
  }) async {
    final entity = _entityFor(id);
    if (entity == null) {
      _commandFailure('未找到对应的远程实体。');
      return;
    }
    if (state.isLoading || state.isCommandLoading) return;

    final permission = _permissionFor(entity);
    if (permission != null &&
        (!permission.canControl ||
            !permission.allowedCommands.contains(nasHaCommandValue(command)))) {
      _commandFailure('当前账号没有执行“${nasHaCommandValue(command)}”的权限。');
      return;
    }

    state = state.copyWith(
      isCommandLoading: true,
      commandDeviceId: id,
      commandError: null,
    );
    try {
      final result = await _repository.sendCommand(
        integrationId: entity.integrationId,
        entityId: entity.entityId,
        command: command,
        requestId: _uuid.v4(),
        parameters: parameters,
      );
      if (!result.accepted) {
        _commandFailure('NAS 未接受该控制请求。');
        return;
      }

      final remoteState = result.state ??
          await _repository.fetchEntityState(
            integrationId: entity.integrationId,
            entityId: entity.entityId,
          );
      _statesByKey[id] = remoteState;
      _stateFetchDenied.remove(id);
      final stale = _isStale(remoteState.fetchedAt);
      final staleIds = {...state.staleEntityIds}
        ..remove(id);
      if (stale) staleIds.add(id);
      if (!mounted) return;
      state = state.copyWith(
        isCommandLoading: false,
        commandDeviceId: null,
        entityStates: Map<String, NasHaEntityState>.unmodifiable(_statesByKey),
        staleEntityIds: Set<String>.unmodifiable(staleIds),
        devices: _mapDevices(state.entities, staleIds),
        haStatus: staleIds.isEmpty ? HaConnectionStatus.online : HaConnectionStatus.stale,
        message: stale ? '命令已接受，但返回的设备状态仍可能已过期。' : null,
        commandError: null,
      );
    } on NasApiError catch (error) {
      if (!mounted) return;
      if (error.kind == NasApiErrorKind.forbidden || error.kind == NasApiErrorKind.unauthorized) {
        final denied = {...state.accessDeniedEntityIds, id};
        state = state.copyWith(accessDeniedEntityIds: Set<String>.unmodifiable(denied));
      }
      _commandFailure(_friendlyCommandError(error));
    } catch (error) {
      if (mounted) _commandFailure('控制请求失败，设备状态未修改。');
    } finally {
      if (mounted && state.isCommandLoading) {
        state = state.copyWith(
          isCommandLoading: false,
          commandDeviceId: null,
        );
      }
    }
  }

  NasHaEntityPermission? _permissionFor(NasHaEntity entity) {
    final matches = state.permissions.where((permission) =>
        permission.integrationId == entity.integrationId &&
        permission.entityId == entity.entityId);
    if (matches.isEmpty) return null;
    // The API already authorizes the current actor. For client-side preflight,
    // accept an explicit permission that grants the command; a server 403 is
    // still authoritative and is retained in accessDeniedEntityIds.
    return matches.firstWhere(
      (permission) => permission.canControl,
      orElse: () => matches.first,
    );
  }

  String _remoteHvacMode(NasHaEntity entity, String displayMode) {
    const aliases = <String, String>{
      '制冷': 'cool',
      '制热': 'heat',
      '送风': 'fan_only',
      '除湿': 'dry',
      '自动': 'auto',
    };
    final candidate = aliases[displayMode] ?? displayMode;
    if (entity.hvacModes.contains(displayMode)) return displayMode;
    return candidate;
  }

  String _friendlyCommandError(NasApiError error) {
    switch (error.kind) {
      case NasApiErrorKind.forbidden:
        return 'NAS 拒绝了控制请求：当前账号没有权限。';
      case NasApiErrorKind.unauthorized:
        return 'NAS 登录状态已失效，未执行控制请求。';
      case NasApiErrorKind.network:
      case NasApiErrorKind.timeout:
      case NasApiErrorKind.server:
        return 'Home Assistant 当前不可用，控制请求未确认成功。';
      case NasApiErrorKind.conflict:
        return '设备状态发生冲突，控制请求未确认成功。';
      default:
        return '控制请求失败，设备状态未修改。';
    }
  }

  void _commandFailure(String message) {
    if (!mounted) return;
    state = state.copyWith(commandError: message);
  }

  void _setUnconfigured(String message) {
    if (!mounted) return;
    state = state.copyWith(
      isLoading: false,
      isCommandLoading: false,
      commandDeviceId: null,
      haStatus: HaConnectionStatus.unconfigured,
      haAddress: '',
      nasAddress: _nasAddress,
      nasOnline: false,
      integrations: const <NasHaIntegration>[],
      entities: const <NasHaEntity>[],
      permissions: const <NasHaEntityPermission>[],
      entityStates: const <String, NasHaEntityState>{},
      staleEntityIds: const <String>{},
      accessDeniedEntityIds: const <String>{},
      devices: const <SmartDevice>[],
      message: message,
      commandError: null,
    );
    _entitiesByKey.clear();
    _statesByKey.clear();
    _stateFetchDenied.clear();
  }

  void _setOffline(
    String message, {
    required List<NasHaIntegration> integrations,
    required NasHaIntegration integration,
  }) {
    if (!mounted) return;
    state = state.copyWith(
      isLoading: false,
      haStatus: HaConnectionStatus.offline,
      haAddress: integration.baseUrl.toString(),
      nasOnline: true,
      integrations: List<NasHaIntegration>.unmodifiable(integrations),
      entities: const <NasHaEntity>[],
      permissions: const <NasHaEntityPermission>[],
      entityStates: const <String, NasHaEntityState>{},
      staleEntityIds: const <String>{},
      accessDeniedEntityIds: const <String>{},
      devices: const <SmartDevice>[],
      message: message,
    );
  }

  void _setFailure(Object error) {
    if (!mounted) return;
    if (error is NasApiError && error.kind == NasApiErrorKind.forbidden) {
      state = state.copyWith(
        isLoading: false,
        haStatus: HaConnectionStatus.offline,
        nasOnline: true,
        message: 'NAS 拒绝读取 Home Assistant 数据：当前账号没有权限。',
      );
      return;
    }
    state = state.copyWith(
      isLoading: false,
      haStatus: HaConnectionStatus.offline,
      nasOnline: false,
      message: error is NasApiError ? error.message : '读取 Home Assistant 状态失败。',
    );
  }

  Future<void> configureIntegration({
    required String name,
    required Uri baseUrl,
    required String accessToken,
  }) async {
    if (!_repository.isConfigured) {
      _commandFailure('请先配置并连接 NAS，再保存 Home Assistant 集成。');
      return;
    }
    state = state.copyWith(isLoading: true, message: null, commandError: null);
    try {
      final hasCredentials = await _repository.restoreCredentials();
      if (!hasCredentials) {
        _setUnconfigured('尚未登录 NAS，无法保存 Home Assistant 集成。');
        return;
      }
      final current = state.integrations.firstOrNull;
      if (current == null) {
        await _repository.addIntegration(
          NasHaIntegrationInput(name: name, baseUrl: baseUrl, accessToken: accessToken),
        );
      } else {
        await _repository.updateIntegration(
          current.id,
          NasHaIntegrationUpdate(
            name: name,
            baseUrl: baseUrl,
            accessToken: accessToken,
            enabled: true,
          ),
        );
      }
      await refresh();
    } catch (error) {
      _setFailure(error);
    } finally {
      if (mounted && state.isLoading) state = state.copyWith(isLoading: false);
    }
  }

  Future<void> testIntegration() async {
    final integration = state.integrations.firstOrNull;
    if (integration == null) {
      _commandFailure('尚未保存 Home Assistant 集成。');
      return;
    }
    state = state.copyWith(isLoading: true, message: null, commandError: null);
    try {
      final result = await _repository.testIntegration(integration.id);
      if (!mounted) return;
      state = state.copyWith(
        isLoading: false,
        haStatus: result.connected ? HaConnectionStatus.online : HaConnectionStatus.offline,
        nasOnline: true,
        message: result.connected ? 'Home Assistant 连接校验通过。' : 'Home Assistant 连接失败。',
      );
      if (result.connected) await refresh();
    } catch (error) {
      _setFailure(error);
    } finally {
      if (mounted && state.isLoading) state = state.copyWith(isLoading: false);
    }
  }

  Future<void> updatePermission(NasHaEntityPermission permission) async {
    state = state.copyWith(isLoading: true, message: null, commandError: null);
    try {
      await _repository.updatePermission(permission);
      await refresh();
    } catch (error) {
      _setFailure(error);
    } finally {
      if (mounted && state.isLoading) state = state.copyWith(isLoading: false);
    }
  }

  Future<void> confirmConsumableLog(String id) => _resolveConsumableLog(
        id,
        NasHaSuggestionDecision.confirm,
      );

  Future<void> ignoreConsumableLog(String id) => _resolveConsumableLog(
        id,
        NasHaSuggestionDecision.ignore,
      );

  Future<void> _resolveConsumableLog(
    String id,
    NasHaSuggestionDecision decision,
  ) async {
    if (state.linkageActionId != null || id.trim().isEmpty) return;
    state = state.copyWith(
      linkageActionId: id,
      message: null,
      commandError: null,
      linkageError: null,
    );
    try {
      final resolved = await _repository.resolveLinkageSuggestion(
        suggestionId: id,
        decision: decision,
      );
      _linkageSuggestions = _linkageSuggestions
          .map((item) => item.id == resolved.id ? resolved : item)
          .toList(growable: false);
      if (!mounted) return;
      state = state.copyWith(
        logs: _mapLinkageLogs(_linkageSuggestions),
        linkageActionId: null,
        message: decision == NasHaSuggestionDecision.confirm
            ? '已由 NAS 服务端完成耗材确认与库存处理。'
            : '已由 NAS 服务端忽略该耗材建议。',
        commandError: null,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        linkageActionId: null,
        commandError: error is NasApiError ? error.message : '耗材联动操作失败，库存未在本地修改。',
      );
    }
  }

  void setHaConnectionStatus(HaConnectionStatus status) {
    if (status == HaConnectionStatus.online) return;
    state = state.copyWith(haStatus: status);
  }
}

final smartHomeControllerProvider =
    StateNotifierProvider<SmartHomeController, SmartHomeState>((ref) {
  final connection = ref.watch(nasConnectionProvider);
  return SmartHomeController(
    ref.watch(nasSmartHomeRepositoryProvider),
    nasAddress: connection.serverUrl,
  );
});
