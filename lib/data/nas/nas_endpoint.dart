import 'nas_api_error.dart';

Uri? tryParseNasServerUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
}

/// Keep the reverse-proxy prefix and append the API version exactly once.
/// The returned path also defines the existing credential binding boundary.
Uri nasApiBaseUri(String value) {
  final uri = tryParseNasServerUri(value);
  if (uri == null) {
    throw NasApiError.invalidBaseUrl('NAS 地址必须是有效的 http 或 https 地址。');
  }
  const apiPath = '/api/v1';
  var prefix = uri.path;
  if (prefix.endsWith(apiPath)) {
    prefix = prefix.substring(0, prefix.length - apiPath.length);
  }
  if (prefix == '/') prefix = '';
  return uri.replace(path: '$prefix$apiPath/');
}
