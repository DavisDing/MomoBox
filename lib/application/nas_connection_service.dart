import 'dart:convert';

import 'package:http/http.dart' as http;

import '../application/settings_service.dart';

const nasServerUrlKey = 'nas_server_url';
const nasFamilyCodeKey = 'nas_family_code';
const nasLastCheckedAtKey = 'nas_last_checked_at';

/// The NAS status is based only on a real health request. A configured URL or
/// a locally built Docker image is never treated as an online connection.
enum NasConnectionStatus {
  unconfigured,
  checking,
  connected,
  unavailable,
  failed,
}

class NasConnectionState {
  const NasConnectionState({
    required this.status,
    this.serverUrl = '',
    this.familyCode = '',
    this.message,
    this.checkedAt,
  });

  final NasConnectionStatus status;
  final String serverUrl;
  final String familyCode;
  final String? message;
  final DateTime? checkedAt;

  bool get isConnected => status == NasConnectionStatus.connected;

  NasConnectionState copyWith({
    NasConnectionStatus? status,
    String? serverUrl,
    String? familyCode,
    String? message,
    bool clearMessage = false,
    DateTime? checkedAt,
  }) {
    return NasConnectionState(
      status: status ?? this.status,
      serverUrl: serverUrl ?? this.serverUrl,
      familyCode: familyCode ?? this.familyCode,
      message: clearMessage ? null : message ?? this.message,
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }
}

class NasHealthResult {
  const NasHealthResult({
    required this.status,
    this.message,
  });

  final NasConnectionStatus status;
  final String? message;
}

class NasConnectionService {
  NasConnectionService(this._settings, {http.Client? client}) : _client = client ?? http.Client();

  final SettingsService _settings;
  final http.Client _client;

  Future<NasConnectionState> loadState() async {
    final serverUrl = await _settings.getValue(nasServerUrlKey) ?? '';
    final familyCode = await _settings.getValue(nasFamilyCodeKey) ?? '';
    return NasConnectionState(
      status: serverUrl.trim().isEmpty ? NasConnectionStatus.unconfigured : NasConnectionStatus.unavailable,
      serverUrl: serverUrl,
      familyCode: familyCode,
    );
  }

  Future<NasConnectionState> saveAndCheck({
    required String serverUrl,
    required String familyCode,
  }) async {
    final normalized = normalizeServerUrl(serverUrl);
    if (normalized == null) {
      return NasConnectionState(
        status: NasConnectionStatus.failed,
        serverUrl: serverUrl.trim(),
        familyCode: familyCode.trim(),
        message: '请输入有效的 NAS 地址，例如 http://192.168.1.20:8080。',
      );
    }

    await _settings.setValue(nasServerUrlKey, normalized);
    await _settings.setValue(nasFamilyCodeKey, familyCode.trim());
    final checkedAt = DateTime.now();
    await _settings.setValue(nasLastCheckedAtKey, checkedAt.toIso8601String());

    final health = await checkHealth(normalized);
    return NasConnectionState(
      status: health.status,
      serverUrl: normalized,
      familyCode: familyCode.trim(),
      message: health.message,
      checkedAt: checkedAt,
    );
  }

  Future<NasHealthResult> checkHealth(String serverUrl) async {
    final normalized = normalizeServerUrl(serverUrl);
    if (normalized == null) {
      return const NasHealthResult(
        status: NasConnectionStatus.failed,
        message: 'NAS 地址无效。',
      );
    }

    try {
      final response = await _client
          .get(Uri.parse('$normalized/api/v1/health'))
          .timeout(const Duration(seconds: 6));
      Map<String, dynamic>? body;
      if (response.body.isNotEmpty) {
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) body = decoded;
        } catch (_) {
          // The HTTP status remains the source of truth for older servers.
        }
      }

      if (response.statusCode == 200) {
        final serviceStatus = body?['status']?.toString();
        if (serviceStatus == null || serviceStatus == 'ok') {
          return const NasHealthResult(status: NasConnectionStatus.connected, message: '健康检查通过。');
        }
        return NasHealthResult(
          status: NasConnectionStatus.unavailable,
          message: 'NAS 服务已响应，但当前状态为 $serviceStatus。',
        );
      }
      if (response.statusCode == 503) {
        return const NasHealthResult(
          status: NasConnectionStatus.unavailable,
          message: 'NAS 服务可访问，但数据库当前不可用。',
        );
      }
      return NasHealthResult(
        status: NasConnectionStatus.failed,
        message: 'NAS 返回 HTTP ${response.statusCode}。',
      );
    } catch (error) {
      return NasHealthResult(
        status: NasConnectionStatus.failed,
        message: _friendlyError(error),
      );
    }
  }

  static String? normalizeServerUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      return null;
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(path: path).toString().replaceFirst(RegExp(r'/+$'), '');
  }

  static String _friendlyError(Object error) {
    if (error is http.ClientException) return '无法连接 NAS，请检查地址和局域网网络。';
    return error.toString().contains('TimeoutException') ? '连接 NAS 超时。' : '无法连接 NAS，请检查地址和局域网网络。';
  }

  void close() => _client.close();
}
