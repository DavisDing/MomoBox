import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models/nas_sync_models.dart';
import 'nas_api_error.dart';

typedef NasSyncAccessTokenProvider = String? Function();
typedef NasSyncTokenRefresh = Future<String?> Function();

/// HTTP boundary for the NAS sync contract.
///
/// This class deliberately does not depend on [NasApiClient]'s private
/// transport state. Callers may provide a token provider (the normal seam),
/// or set a token directly for tests/temporary wiring. No scheduling or
/// persistence is performed here.
class NasSyncApi {
  NasSyncApi(
    String baseUrl, {
    String? accessToken,
    NasSyncAccessTokenProvider? accessTokenProvider,
    NasSyncTokenRefresh? refreshHandler,
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _requestTimeout = requestTimeout,
        _baseUri = _parseBaseUri(baseUrl),
        _accessToken = accessToken,
        _accessTokenProvider = accessTokenProvider,
        _refreshHandler = refreshHandler;

  final http.Client _client;
  final Duration _requestTimeout;
  final Uri _baseUri;
  final NasSyncAccessTokenProvider? _accessTokenProvider;
  String? _accessToken;
  NasSyncTokenRefresh? _refreshHandler;
  Future<String?>? _refreshInFlight;

  void setAccessToken(String? token) {
    final normalized = token?.trim();
    _accessToken = normalized == null || normalized.isEmpty ? null : normalized;
  }

  void setRefreshHandler(NasSyncTokenRefresh? handler) {
    _refreshHandler = handler;
  }

  void close() => _client.close();

  Future<NasSyncBootstrap> bootstrap({required String deviceId}) async {
    final json = await _sendJson(
      method: 'GET',
      path: '/sync/bootstrap',
      queryParameters: {'device_id': deviceId},
    );
    return _parse(json, NasSyncBootstrap.fromJson);
  }

  Future<NasSyncConfirmResult> confirmBootstrap({
    required String mode,
    required String deviceId,
    String? localWorkspaceId,
  }) async {
    final body = <String, dynamic>{'mode': mode, 'device_id': deviceId};
    if (localWorkspaceId != null && localWorkspaceId.trim().isNotEmpty) {
      body['local_workspace_id'] = localWorkspaceId;
    }
    final json = await _sendJson(
      method: 'POST',
      path: '/sync/bootstrap/confirm',
      body: body,
    );
    return _parse(json, NasSyncConfirmResult.fromJson);
  }

  Future<NasSyncPushResponse> push({
    required String deviceId,
    required int baseCursor,
    required List<NasSyncChange> changes,
  }) async {
    if (baseCursor < 0) {
      throw NasApiError.invalidResponse(const FormatException('base_cursor must be non-negative'));
    }
    if (changes.isEmpty || changes.length > 100) {
      throw NasApiError.invalidResponse(
        const FormatException('push changes must contain between 1 and 100 items'),
      );
    }
    for (final change in changes) {
      try {
        change.validateForPush();
      } on FormatException catch (error) {
        throw NasApiError.invalidResponse(error);
      }
    }
    final json = await _sendJson(
      method: 'POST',
      path: '/sync/push',
      body: {
        'device_id': deviceId,
        'base_cursor': baseCursor,
        'changes': changes.map((change) => change.toJson()).toList(growable: false),
      },
    );
    return _parse(json, NasSyncPushResponse.fromJson);
  }

  Future<NasSyncPullResponse> pull({
    required String deviceId,
    required int cursor,
    int limit = 100,
  }) async {
    if (cursor < 0 || limit < 1 || limit > 500) {
      throw NasApiError.invalidResponse(
        const FormatException('cursor must be non-negative and limit must be between 1 and 500'),
      );
    }
    final json = await _sendJson(
      method: 'GET',
      path: '/sync/pull',
      queryParameters: {
        'device_id': deviceId,
        'cursor': '$cursor',
        'limit': '$limit',
      },
    );
    return _parse(json, NasSyncPullResponse.fromJson);
  }

  Future<Map<String, dynamic>> _sendJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
    bool retryOnUnauthorized = true,
    String? tokenOverride,
  }) async {
    final token = tokenOverride ?? _accessTokenProvider?.call() ?? _accessToken;
    if (token == null || token.trim().isEmpty) {
      throw NasApiError(
        kind: NasApiErrorKind.unauthorized,
        message: '当前没有有效的 NAS 登录凭证。',
        statusCode: 401,
      );
    }

    final uri = _baseUri.resolve(path.startsWith('/') ? path.substring(1) : path).replace(
          queryParameters: queryParameters,
        );
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json; charset=utf-8',
      'Authorization': 'Bearer ${token.trim()}',
    };

    late http.Response response;
    try {
      final encodedBody = body == null ? null : jsonEncode(body);
      switch (method) {
        case 'GET':
          response = await _client.get(uri, headers: headers).timeout(_requestTimeout);
          break;
        case 'POST':
          response = await _client
              .post(uri, headers: headers, body: encodedBody)
              .timeout(_requestTimeout);
          break;
        default:
          throw ArgumentError('Unsupported NAS sync HTTP method: $method');
      }
    } on TimeoutException catch (error) {
      throw NasApiError.timeout(error);
    } on http.ClientException catch (error) {
      throw NasApiError.network(error);
    } on NasApiError {
      rethrow;
    } catch (error) {
      throw NasApiError.network(error);
    }

    if (response.statusCode == 401 && retryOnUnauthorized && _refreshHandler != null) {
      final refreshedToken = await _refreshOnce();
      if (refreshedToken != null && refreshedToken.trim().isNotEmpty) {
        setAccessToken(refreshedToken);
        return _sendJson(
          method: method,
          path: path,
          body: body,
          queryParameters: queryParameters,
          retryOnUnauthorized: false,
          tokenOverride: refreshedToken,
        );
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiError.fromResponse(response);
    }
    if (response.body.trim().isEmpty) {
      throw NasApiError.invalidResponse(const FormatException('empty response body'));
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw const FormatException('response is not an object');
      return Map<String, dynamic>.from(decoded);
    } catch (error) {
      throw NasApiError.invalidResponse(error);
    }
  }

  Future<String?> _refreshOnce() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final handler = _refreshHandler;
    if (handler == null) return Future<String?>.value(null);
    final future = handler();
    _refreshInFlight = future;
    return future.whenComplete(() => _refreshInFlight = null);
  }

  T _parse<T>(Map<String, dynamic> json, T Function(Map<String, dynamic>) parser) {
    try {
      return parser(json);
    } on NasApiError {
      rethrow;
    } on FormatException catch (error) {
      throw NasApiError.invalidResponse(error);
    } on TypeError catch (error) {
      throw NasApiError.invalidResponse(error);
    }
  }
}

Uri _parseBaseUri(String baseUrl) {
  final normalized = baseUrl.trim();
  if (normalized.isEmpty) throw NasApiError.invalidBaseUrl('NAS 地址不能为空。');
  final parsed = Uri.tryParse(normalized);
  if (parsed == null ||
      (parsed.scheme != 'http' && parsed.scheme != 'https') ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.query.isNotEmpty ||
      parsed.fragment.isNotEmpty) {
    throw NasApiError.invalidBaseUrl('NAS 地址必须是有效的 http 或 https 地址。');
  }
  var path = parsed.path.replaceFirst(RegExp(r'/+$'), '');
  if (path.endsWith('/api/v1')) path = path.substring(0, path.length - '/api/v1'.length);
  if (path == '/') path = '';
  return parsed.replace(path: '$path/api/v1/');
}
