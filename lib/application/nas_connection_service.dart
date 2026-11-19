import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/nas/nas_endpoint.dart';
import '../services/local_network_permission_service.dart';
import 'settings_service.dart';

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
  NasConnectionService(
    this._settings, {
    http.Client? client,
    LocalNetworkPermissionService? localNetworkPermission,
  }) : _client = client ?? http.Client(),
       _localNetworkPermission = localNetworkPermission ?? LocalNetworkPermissionService();

  final SettingsService _settings;
  final http.Client _client;
  final LocalNetworkPermissionService _localNetworkPermission;

  Future<LocalNetworkPermissionStatus> requestLocalNetworkAccess() =>
      _localNetworkPermission.request();

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
        message: '请输入有效的 NAS 地址，例如 http://192.168.1.20:18473。',
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
          .get(nasApiBaseUri(normalized).resolve('health'))
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        try {
          final body = jsonDecode(response.body);
          if (body is Map<String, dynamic> && body['status'] == 'ok') {
            return const NasHealthResult(
              status: NasConnectionStatus.connected,
              message: '健康检查通过。',
            );
          }
        } on FormatException {
          // An HTTP 200 from a proxy login or fallback page is not NAS health.
        }
        return const NasHealthResult(
          status: NasConnectionStatus.failed,
          message: '服务已响应，但不是有效的 MomoBox 健康检查响应。请核对 NAS 地址和反向代理。',
        );
      }
      if (response.statusCode == 503) {
        return const NasHealthResult(
          status: NasConnectionStatus.unavailable,
          message: 'NAS 服务可访问，但数据库当前不可用。',
        );
      }
      if (response.statusCode == 404) {
        return const NasHealthResult(
          status: NasConnectionStatus.failed,
          message: 'NAS 健康检查接口未找到（HTTP 404）。请核对 NAS 地址、端口和反向代理。',
        );
      }
      return NasHealthResult(
        status: NasConnectionStatus.failed,
        message: 'NAS 返回 HTTP ${response.statusCode}。',
      );
    } catch (error) {
      final permission = await _localNetworkPermission.status();
      return NasHealthResult(
        status: NasConnectionStatus.failed,
        message: permission == LocalNetworkPermissionStatus.denied
            ? 'NAS 未连通，局域网访问也未授权。请重新测试连接并允许“附近设备”权限；已拒绝时可到系统设置中开启。'
            : _friendlyError(error),
      );
    }
  }

  static String? normalizeServerUrl(String value) =>
      tryParseNasServerUri(value)?.toString();

  static String _friendlyError(Object error) {
    if (error is http.ClientException) return '无法连接 NAS，请检查地址和局域网网络。';
    return error.toString().contains('TimeoutException') ? '连接 NAS 超时。' : '无法连接 NAS，请检查地址和局域网网络。';
  }

  void close() => _client.close();
}
