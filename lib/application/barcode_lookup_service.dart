import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/repositories/barcode_cache_repository.dart';
import '../domain/models/recognition_models.dart';
import 'failover_executor.dart';
import 'settings_service.dart';

enum BarcodeApiLevel { primary, secondary, fallback }

extension on BarcodeApiLevel {
  ServiceFallbackLevel get serviceLevel => switch (this) {
        BarcodeApiLevel.primary => ServiceFallbackLevel.primary,
        BarcodeApiLevel.secondary => ServiceFallbackLevel.secondary,
        BarcodeApiLevel.fallback => ServiceFallbackLevel.fallback,
      };
}

class BarcodeEndpointConfig {
  const BarcodeEndpointConfig({
    required this.level,
    required this.name,
    required this.endpoint,
    this.timeout = const Duration(seconds: 8),
  });

  final BarcodeApiLevel level;
  final String name;
  final String endpoint;
  final Duration timeout;

  bool get isValid => endpoint.trim().isNotEmpty;
}

class BarcodeLookupService {
  BarcodeLookupService(
    this._cache,
    this._settings, {
    http.Client? client,
    DateTime Function()? clock,
  })  : _client = client ?? http.Client(),
        _clock = clock ?? DateTime.now;

  static const enabledKey = 'barcode_api_enabled';
  static const endpointKey = 'barcode_api_endpoint';
  static const secondaryEndpointKey = 'barcode_api_secondary_endpoint';
  static const fallbackEndpointKey = 'barcode_api_fallback_endpoint';
  static const profilesKey = 'barcode_api_profiles';
  static const profileRoleKey = 'fallbackRole';
  static const primaryRole = 'primary';
  static const secondaryRole = 'secondary';
  static const fallbackRole = 'fallback';
  static const standbyRole = 'standby';
  static const defaultFreeProfileId = 'free_open_food_facts';
  static const defaultFreeEndpoint =
      'https://world.openfoodfacts.org/api/v2/product/{barcode}.json';

  static const _executor = FailoverExecutor<BarcodeEndpointConfig, BarcodeLookupResult?>();

  static List<Map<String, dynamic>> normalizeProfilesForRoles(
    Iterable<Map<String, dynamic>> source, {
    String? legacyPrimaryEndpoint,
  }) {
    final profiles = source
        .map((profile) => Map<String, dynamic>.from(profile))
        .where((profile) => profile['endpoint']?.toString().trim().isNotEmpty == true)
        .toList();
    final legacyEndpoint = legacyPrimaryEndpoint?.trim() ?? '';

    if (profiles.isEmpty) {
      if (legacyEndpoint.isEmpty || legacyEndpoint == defaultFreeEndpoint) {
        return [defaultFreeProfile()];
      }
      return [
        <String, dynamic>{
          'id': 'legacy_primary',
          'name': '已有条码服务',
          'endpoint': legacyEndpoint,
          profileRoleKey: primaryRole,
        },
      ];
    }

    Map<String, dynamic>? selectedPrimary;
    for (final profile in profiles) {
      if (profile[profileRoleKey] == primaryRole) {
        selectedPrimary = profile;
        break;
      }
    }
    if (selectedPrimary == null && legacyEndpoint.isNotEmpty) {
      for (final profile in profiles) {
        if (profile['endpoint']?.toString().trim() == legacyEndpoint) {
          selectedPrimary = profile;
          break;
        }
      }
    }
    selectedPrimary ??= profiles.first;

    for (final profile in profiles) {
      if (identical(profile, selectedPrimary)) {
        profile[profileRoleKey] = primaryRole;
      } else if (profile[profileRoleKey] == null ||
          profile[profileRoleKey] == primaryRole) {
        profile[profileRoleKey] = standbyRole;
      }
    }
    return profiles;
  }

  final BarcodeCacheRepository _cache;
  final SettingsService _settings;
  final http.Client _client;
  final DateTime Function() _clock;

  static Map<String, dynamic> defaultFreeProfile() => <String, dynamic>{
        'id': defaultFreeProfileId,
        'name': '免费公共条码库 (Open Food Facts)',
        'endpoint': defaultFreeEndpoint,
        profileRoleKey: primaryRole,
      };

  Future<BarcodeLookupResult?> lookup(String rawBarcode) async {
    final barcode = rawBarcode.trim();
    if (!_isValidBarcode(barcode)) throw ArgumentError('条码格式不正确。');
    final cached = await _cache.loadFresh(barcode, now: _clock());
    if (cached != null) return cached;

    final enabled = await _settings.getValue(enabledKey);
    if (enabled != 'true') return null;

    try {
      final response = await _executor.execute(
        configs: await _resolveFallbackConfigs(),
        isConfigured: (config) => config.isValid,
        levelOf: (config) => config.level.serviceLevel,
        endpointOf: (config) => config.endpoint,
        noConfigMessage: '没有可用的条码服务，请检查主/副/兜底服务配置。',
        allFailedMessage: '所有已配置的条码服务均不可用，请稍后重试或手动填写。',
        call: (config) => _lookupFromEndpoint(config, barcode),
        // A request completed successfully even when the product is not in the
        // selected public database. Do not try another source for a confirmed miss.
        isValidResult: (_) => true,
      );
      final result = response.value;
      if (result == null) return null;
      await _cache.save(
        result,
        expiresAt: _clock().add(const Duration(days: 30)),
      );
      return result;
    } on FailoverException<BarcodeEndpointConfig> catch (error) {
      throw StateError(error.message);
    }
  }

  Future<List<BarcodeEndpointConfig>> _resolveFallbackConfigs() async {
    final primaryEndpoint = (await _settings.getValue(endpointKey))?.trim();
    final profiles = await _readProfiles(primaryEndpoint);
    final secondaryEndpoint = (await _settings.getValue(secondaryEndpointKey))?.trim();
    final fallbackEndpoint = (await _settings.getValue(fallbackEndpointKey))?.trim();
    final configs = <BarcodeEndpointConfig>[];

    Map<String, dynamic>? profileFor(String role, String? legacyEndpoint) {
      for (final profile in profiles) {
        if (profile[profileRoleKey] == role) return profile;
      }
      if (legacyEndpoint == null || legacyEndpoint.isEmpty) return null;
      for (final profile in profiles) {
        if (profile['endpoint']?.toString().trim() == legacyEndpoint) return profile;
      }
      return null;
    }

    BarcodeEndpointConfig? forRole(BarcodeApiLevel level, String role, String? legacyEndpoint) {
      final profile = profileFor(role, legacyEndpoint);
      final endpoint = profile?['endpoint']?.toString().trim() ?? legacyEndpoint ?? '';
      if (endpoint.isEmpty) return null;
      final profileName = profile?['name']?.toString().trim();
      return BarcodeEndpointConfig(
        level: level,
        name: profileName == null || profileName.isEmpty ? role : profileName,
        endpoint: endpoint,
      );
    }

    final primary = forRole(BarcodeApiLevel.primary, primaryRole, primaryEndpoint);
    final secondary = forRole(BarcodeApiLevel.secondary, secondaryRole, secondaryEndpoint);
    final fallback = forRole(BarcodeApiLevel.fallback, fallbackRole, fallbackEndpoint);
    for (final config in [primary, secondary, fallback]) {
      if (config != null && !configs.any((item) => item.endpoint == config.endpoint)) {
        configs.add(config);
      }
    }
    return configs;
  }

  Future<List<Map<String, dynamic>>> _readProfiles(String? legacyPrimaryEndpoint) async {
    final raw = await _settings.getValue(profilesKey);
    if (raw == null || raw.trim().isEmpty) {
      return normalizeProfilesForRoles(
        const [],
        legacyPrimaryEndpoint: legacyPrimaryEndpoint,
      );
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return normalizeProfilesForRoles(
          const [],
          legacyPrimaryEndpoint: legacyPrimaryEndpoint,
        );
      }
      return normalizeProfilesForRoles(
        decoded.whereType<Map>().map((item) => Map<String, dynamic>.from(item)),
        legacyPrimaryEndpoint: legacyPrimaryEndpoint,
      );
    } on FormatException {
      return normalizeProfilesForRoles(
        const [],
        legacyPrimaryEndpoint: legacyPrimaryEndpoint,
      );
    }
  }

  Future<BarcodeLookupResult?> _lookupFromEndpoint(
    BarcodeEndpointConfig config,
    String barcode,
  ) async {
    final uri = _buildLookupUri(config.endpoint, barcode);
    try {
      final response = await _client
          .get(
            uri,
            headers: const {
              'Accept': 'application/json',
              'User-Agent': 'MomoBox/0.1 (local barcode lookup)',
            },
          )
          .timeout(config.timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('${config.name} 返回 ${response.statusCode}');
      }
      return _parseResponse(barcode, response.body);
    } on TimeoutException {
      throw StateError('${config.name} 请求超时');
    } on FormatException {
      throw StateError('${config.name} 返回的数据格式不正确');
    } on http.ClientException {
      throw StateError('无法连接 ${config.name}，请检查网络或服务地址');
    }
  }

  Uri _buildLookupUri(String configuredEndpoint, String barcode) {
    final raw = configuredEndpoint.trim();
    if (raw.contains('{barcode}')) {
      final encoded = Uri.encodeComponent(barcode);
      final uri = Uri.tryParse(raw.replaceAll('{barcode}', encoded));
      if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
        throw ArgumentError('条码 API 地址无效。');
      }
      return uri;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw ArgumentError('条码 API 地址无效。');
    }
    return uri.replace(pathSegments: [...uri.pathSegments, barcode]);
  }

  BarcodeLookupResult? _parseResponse(String barcode, String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    if (decoded['found'] == false || decoded['status'] == 0 || decoded['success'] == false) {
      return null;
    }
    final data = _firstMap(decoded, const ['data', 'product']) ?? decoded;
    if (data['found'] == false ||
        data['status'] == 0 ||
        data['success'] == false) {
      return null;
    }
    final name = _textOrNull(data['name']) ??
        _textOrNull(data['product_name']) ??
        _textOrNull(data['product_name_zh']);
    final category = _textOrNull(data['category']) ?? _lastCategory(data['categories']);
    final result = BarcodeLookupResult(
      barcode: barcode,
      source: 'external_api',
      name: name,
      brand: _textOrNull(data['brand']) ?? _textOrNull(data['brands']),
      specification: _textOrNull(data['specification']) ??
          _textOrNull(data['quantity']) ??
          _textOrNull(data['size']),
      category: category,
    );
    if (!result.hasProductData) {
      throw const FormatException('响应中缺少可识别的商品字段');
    }
    return result;
  }

  Map<String, dynamic>? _firstMap(Map<String, dynamic> source, List<String> keys) {
    for (final key in keys) {
      final value = source[key];
      if (value is Map<String, dynamic>) return value;
    }
    return null;
  }

  String? _textOrNull(Object? value) {
    if (value is List) {
      final values = value.whereType<String>().map((item) => item.trim()).where((item) => item.isNotEmpty);
      final joined = values.join(', ');
      return joined.isEmpty ? null : joined;
    }
    return stringOrNull(value);
  }

  String? _lastCategory(Object? source) {
    final category = _textOrNull(source);
    if (category == null) return null;
    final entries = category.split(RegExp(r'[>／/]'));
    return entries.last.trim().isEmpty ? null : entries.last.trim();
  }

  bool _isValidBarcode(String value) => RegExp(r'^\d{8,14}$').hasMatch(value);
}
