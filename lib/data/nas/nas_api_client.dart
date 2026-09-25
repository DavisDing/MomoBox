import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models/nas_models.dart';
import 'nas_api_error.dart';

typedef NasAccessTokenRefresh = Future<String?> Function();

/// Small HTTP boundary for the versioned NAS API.
///
/// It owns no UI state and does not persist credentials. A caller supplies a
/// secure session service and can install a refresh callback through
/// [setRefreshHandler].
class NasApiClient {
  NasApiClient(
    String baseUrl, {
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _requestTimeout = requestTimeout,
        _baseUri = _parseBaseUri(baseUrl);

  final http.Client _client;
  final Duration _requestTimeout;
  final Uri _baseUri;
  String? _accessToken;
  NasAccessTokenRefresh? _refreshHandler;
  Future<String?>? _refreshInFlight;

  bool get hasAccessToken => _accessToken != null;

  void setAccessToken(String? accessToken) {
    final normalized = accessToken?.trim();
    _accessToken = normalized == null || normalized.isEmpty ? null : normalized;
  }

  void setRefreshHandler(NasAccessTokenRefresh? handler) {
    _refreshHandler = handler;
  }

  Future<NasAuthResponse> register(NasRegisterRequest request) async {
    final json = await _postJson('/auth/register', request.toJson());
    return _parseResponse(json, NasAuthResponse.fromJson);
  }

  Future<NasAuthResponse> login(NasLoginRequest request) async {
    final json = await _postJson('/auth/login', request.toJson());
    return _parseResponse(json, NasAuthResponse.fromJson);
  }

  Future<NasAuthResponse> refresh(NasRefreshRequest request) async {
    final json = await _postJson(
      '/auth/refresh',
      request.toJson(),
      authenticated: false,
      retryOnUnauthorized: false,
    );
    return _parseResponse(json, NasAuthResponse.fromJson);
  }

  Future<void> logout(NasRefreshRequest request) async {
    await _sendJson(
      method: 'POST',
      path: '/auth/logout',
      body: request.toJson(),
      authenticated: true,
      retryOnUnauthorized: false,
      expectBody: false,
    );
  }

  Future<NasMeResponse> me() async {
    final json = await _sendJson(method: 'GET', path: '/me');
    return _parseResponse(json, NasMeResponse.fromJson);
  }

  /// Sends an authenticated request to a JSON NAS endpoint.
  ///
  /// Feature-specific clients use this boundary instead of duplicating
  /// bearer-token, timeout, refresh, and error handling. The response remains
  /// an untyped JSON object so each feature can validate its own contract.
  Future<Map<String, dynamic>> requestJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
    bool authenticated = true,
    bool retryOnUnauthorized = true,
    bool expectBody = true,
  }) {
    return _sendJson(
      method: method,
      path: path,
      body: body,
      queryParameters: queryParameters,
      authenticated: authenticated,
      retryOnUnauthorized: retryOnUnauthorized,
      expectBody: expectBody,
    );
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = false,
    bool retryOnUnauthorized = true,
  }) async {
    final json = await _sendJson(
      method: 'POST',
      path: path,
      body: body,
      authenticated: authenticated,
      retryOnUnauthorized: retryOnUnauthorized,
    );
    return json;
  }

  Future<Map<String, dynamic>> _sendJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
    bool authenticated = true,
    bool retryOnUnauthorized = true,
    bool expectBody = true,
  }) async {
    final relativePath = path.startsWith('/') ? path.substring(1) : path;
    final resolvedUri = _baseUri.resolve(relativePath);
    final uri = queryParameters == null || queryParameters.isEmpty
        ? resolvedUri
        : resolvedUri.replace(queryParameters: {
            ...resolvedUri.queryParameters,
            ...queryParameters,
          });
    final headers = <String, String>{
      'Accept': 'application/json',
    };
    if (body != null) {
      headers['Content-Type'] = 'application/json; charset=utf-8';
    }
    if (authenticated) {
      final accessToken = _accessToken;
      if (accessToken == null) {
        throw NasApiError(
          kind: NasApiErrorKind.unauthorized,
          message: '当前没有有效的 NAS 登录凭证。',
          statusCode: 401,
        );
      }
      headers['Authorization'] = 'Bearer $accessToken';
    }

    http.Response response;
    try {
      response = await _sendRequest(
        method: method,
        uri: uri,
        headers: headers,
        body: body,
      );
    } on TimeoutException catch (error) {
      throw NasApiError.timeout(error);
    } on http.ClientException catch (error) {
      throw NasApiError.network(error);
    } catch (error) {
      throw NasApiError.network(error);
    }

    if (response.statusCode == 401 &&
        authenticated &&
        retryOnUnauthorized &&
        _refreshHandler != null) {
      final refreshedToken = await _refreshOnce();
      if (refreshedToken != null) {
        // The refresh callback may be supplied by a caller other than
        // NasAuthService. Do not rely on that callback to update this client;
        // the token returned here is the contract that makes the retry safe.
        setAccessToken(refreshedToken);
        return _sendJson(
          method: method,
          path: path,
          body: body,
          queryParameters: queryParameters,
          authenticated: authenticated,
          retryOnUnauthorized: false,
          expectBody: expectBody,
        );
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NasApiError.fromResponse(response);
    }
    if (!expectBody || response.statusCode == 204 || response.body.trim().isEmpty) {
      return <String, dynamic>{};
    }

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw const FormatException('response is not an object');
      return Map<String, dynamic>.from(decoded);
    } catch (error) {
      throw NasApiError.invalidResponse(error);
    }
  }

  Future<http.Response> _sendRequest({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, dynamic>? body,
  }) {
    final encodedBody = body == null ? null : jsonEncode(body);
    switch (method) {
      case 'GET':
        return _client.get(uri, headers: headers).timeout(_requestTimeout);
      case 'POST':
        return _client
            .post(uri, headers: headers, body: encodedBody)
            .timeout(_requestTimeout);
      case 'PATCH':
        return _client
            .patch(uri, headers: headers, body: encodedBody)
            .timeout(_requestTimeout);
      case 'PUT':
        return _client
            .put(uri, headers: headers, body: encodedBody)
            .timeout(_requestTimeout);
      case 'DELETE':
        return _client
            .delete(uri, headers: headers, body: encodedBody)
            .timeout(_requestTimeout);
      default:
        throw ArgumentError('Unsupported NAS HTTP method: $method');
    }
  }

  Future<String?> _refreshOnce() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final handler = _refreshHandler;
    if (handler == null) return Future<String?>.value(null);
    final future = handler();
    _refreshInFlight = future;
    return future.whenComplete(() {
      _refreshInFlight = null;
    });
  }

  T _parseResponse<T>(
    Map<String, dynamic> json,
    T Function(Object? value) parser,
  ) {
    try {
      return parser(json);
    } on FormatException catch (error) {
      throw NasApiError.invalidResponse(error);
    } on TypeError catch (error) {
      throw NasApiError.invalidResponse(error);
    }
  }
}

Uri _parseBaseUri(String baseUrl) {
  final normalized = baseUrl.trim();
  if (normalized.isEmpty) {
    throw NasApiError.invalidBaseUrl('NAS 地址不能为空。');
  }
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
  if (path.endsWith('/api/v1')) {
    path = path.substring(0, path.length - '/api/v1'.length);
  }
  if (path == '/') path = '';
  return parsed.replace(path: '$path/api/v1/');
}
