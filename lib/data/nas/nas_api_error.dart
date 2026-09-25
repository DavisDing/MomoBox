import 'dart:convert';

import 'package:http/http.dart' as http;

enum NasApiErrorKind {
  invalidBaseUrl,
  network,
  timeout,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  validation,
  rateLimited,
  server,
  invalidResponse,
  unknown,
}

/// A normalized, safe-to-display API error.
///
/// Response bodies, request headers and request payloads are deliberately not
/// retained. This prevents access/refresh tokens from accidentally reaching
/// logs or crash reports through an exception object.
class NasApiError implements Exception {
  NasApiError({
    required this.kind,
    required this.message,
    this.statusCode,
    this.code,
    this.requestId,
    Map<String, dynamic>? details,
    this.cause,
  }) : details = details == null ? null : _sanitizeMap(details);

  final NasApiErrorKind kind;
  final String message;
  final int? statusCode;
  final String? code;
  final String? requestId;
  final Map<String, dynamic>? details;
  final Object? cause;

  bool get isUnauthorized => kind == NasApiErrorKind.unauthorized;
  bool get isRetryable => kind == NasApiErrorKind.network ||
      kind == NasApiErrorKind.timeout ||
      kind == NasApiErrorKind.rateLimited ||
      kind == NasApiErrorKind.server;

  factory NasApiError.fromResponse(http.Response response) {
    String? code;
    String? message;
    String? requestId;
    Map<String, dynamic>? details;

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        final root = Map<String, dynamic>.from(decoded);
        final error = root['error'];
        final errorMap = error is Map ? Map<String, dynamic>.from(error) : root;
        code = errorMap['code'] as String?;
        message = errorMap['message'] as String?;
        requestId = errorMap['request_id'] as String?;
        final rawDetails = errorMap['details'];
        if (rawDetails is Map) {
          details = Map<String, dynamic>.from(rawDetails);
        }
      }
    } catch (_) {
      // The status code remains enough to classify the failure.
    }

    return NasApiError(
      kind: _kindForStatus(response.statusCode),
      statusCode: response.statusCode,
      code: _redact(code),
      message: _redact(message) ?? _defaultMessage(response.statusCode),
      requestId: _redact(requestId),
      details: details,
    );
  }

  factory NasApiError.invalidBaseUrl(String message) => NasApiError(
        kind: NasApiErrorKind.invalidBaseUrl,
        message: message,
      );

  factory NasApiError.network(Object cause) => NasApiError(
        kind: NasApiErrorKind.network,
        message: '无法连接 NAS。请检查网络和服务器地址。',
        cause: cause,
      );

  factory NasApiError.timeout(Object cause) => NasApiError(
        kind: NasApiErrorKind.timeout,
        message: 'NAS 请求超时，请稍后重试。',
        cause: cause,
      );

  factory NasApiError.invalidResponse([Object? cause]) => NasApiError(
        kind: NasApiErrorKind.invalidResponse,
        message: 'NAS 返回了无法识别的数据。',
        cause: cause,
      );

  @override
  String toString() {
    final status = statusCode == null ? '' : ' status=$statusCode';
    final apiCode = code == null ? '' : ' code=$code';
    // Do not include server message, details, cause, request body or headers.
    return 'NasApiError(${kind.name}$status$apiCode)';
  }
}

NasApiErrorKind _kindForStatus(int statusCode) {
  switch (statusCode) {
    case 401:
      return NasApiErrorKind.unauthorized;
    case 403:
      return NasApiErrorKind.forbidden;
    case 404:
      return NasApiErrorKind.notFound;
    case 409:
      return NasApiErrorKind.conflict;
    case 400:
    case 422:
      return NasApiErrorKind.validation;
    case 429:
      return NasApiErrorKind.rateLimited;
    default:
      return statusCode >= 500
          ? NasApiErrorKind.server
          : NasApiErrorKind.unknown;
  }
}

String _defaultMessage(int statusCode) {
  switch (_kindForStatus(statusCode)) {
    case NasApiErrorKind.unauthorized:
      return '登录状态已失效，请重新登录。';
    case NasApiErrorKind.forbidden:
      return '没有执行此操作的权限。';
    case NasApiErrorKind.notFound:
      return 'NAS 未找到请求的资源。';
    case NasApiErrorKind.conflict:
      return '请求与 NAS 当前状态冲突。';
    case NasApiErrorKind.validation:
      return '请求参数无效。';
    case NasApiErrorKind.rateLimited:
      return '请求过于频繁，请稍后重试。';
    case NasApiErrorKind.server:
      return 'NAS 服务暂时不可用，请稍后重试。';
    default:
      return 'NAS 请求失败。';
  }
}

String? _redact(String? value) {
  if (value == null) return null;
  var result = value;
  result = result.replaceAll(
    RegExp(r'bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    'Bearer [REDACTED]',
  );
  result = result.replaceAll(
    RegExp(
      r'(access[_ -]?token|refresh[_ -]?token|password|secret)\s*[:=]\s*[^,;\s]+',
      caseSensitive: false,
    ),
    r'\1=[REDACTED]',
  );
  return result;
}

Map<String, dynamic> _sanitizeMap(Map<String, dynamic> input) {
  final output = <String, dynamic>{};
  for (final entry in input.entries) {
    final key = entry.key;
    final lowerKey = key.toLowerCase();
    if (lowerKey.contains('token') ||
        lowerKey.contains('password') ||
        lowerKey.contains('secret') ||
        lowerKey == 'authorization') {
      output[key] = '[REDACTED]';
    } else {
      output[key] = _sanitizeValue(entry.value);
    }
  }
  return output;
}

Object? _sanitizeValue(Object? value) {
  if (value is Map) {
    return _sanitizeMap(Map<String, dynamic>.from(value));
  }
  if (value is List) return value.map(_sanitizeValue).toList(growable: false);
  if (value is String) return _redact(value);
  return value;
}
