import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../application/settings_service.dart';
import '../data/repositories/barcode_cache_repository.dart';
import '../domain/models/recognition_models.dart';

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

  final BarcodeCacheRepository _cache;
  final SettingsService _settings;
  final http.Client _client;
  final DateTime Function() _clock;

  Future<BarcodeLookupResult?> lookup(String rawBarcode) async {
    final barcode = rawBarcode.trim();
    if (!_isValidBarcode(barcode)) throw ArgumentError('条码格式不正确。');
    final cached = await _cache.loadFresh(barcode, now: _clock());
    if (cached != null) return cached;

    final enabled = await _settings.getValue(enabledKey);
    final endpoint = await _settings.getValue(endpointKey);
    if (enabled != 'true' || endpoint == null || endpoint.trim().isEmpty) return null;

    final uri = _buildLookupUri(endpoint, barcode);
    try {
      final response = await _client
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('条码服务返回 ${response.statusCode}，请稍后重试或手动填写。');
      }
      final result = _parseResponse(barcode, response.body);
      if (result == null) return null;
      await _cache.save(
        result,
        expiresAt: _clock().add(const Duration(days: 30)),
      );
      return result;
    } on TimeoutException {
      throw StateError('条码服务请求超时，请稍后重试或手动填写。');
    } on FormatException {
      throw StateError('条码服务返回的数据格式不正确。');
    } on http.ClientException {
      throw StateError('无法连接条码服务，请检查网络或服务地址。');
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
    if (data['found'] == false || data['status'] == 0) return null;
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
    return result.hasProductData ? result : null;
  }

  Map<String, dynamic>? _firstMap(
    Map<String, dynamic> source,
    List<String> keys,
  ) {
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
