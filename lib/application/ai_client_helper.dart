/// AI 协议调用与自适应辅助工具
class AiClientHelper {
  const AiClientHelper._();

  /// 根据 endpoint 与配置的 endpointType 推断应使用的协议及 URI
  ///
  /// 如果 endpoint 显式以 `/responses` 结尾，则判定为 responses；
  /// 如果显式以 `/chat/completions` 结尾，则判定为 chat；
  /// 否则若配置为 'auto'，返回 auto 并提供优先尝试的协议。
  static String resolveProtocol(String endpoint, String configuredType) {
    final clean = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    if (clean.endsWith('/responses')) {
      return 'responses';
    }
    if (clean.endsWith('/chat/completions')) {
      return 'chat';
    }
    if (configuredType == 'responses' || configuredType == 'chat') {
      return configuredType;
    }
    return 'auto';
  }

  static Uri chatCompletionUri(String endpoint) {
    final clean = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    final parsed = Uri.tryParse(clean);
    if (parsed == null || !parsed.hasScheme || !parsed.hasAuthority) {
      throw ArgumentError('AI 服务地址无效。');
    }
    if (parsed.path.endsWith('/chat/completions')) return parsed;
    return parsed.replace(pathSegments: [...parsed.pathSegments, 'chat', 'completions']);
  }

  static Uri responsesUri(String endpoint) {
    final clean = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
    final parsed = Uri.tryParse(clean);
    if (parsed == null || !parsed.hasScheme || !parsed.hasAuthority) {
      throw ArgumentError('AI 服务地址无效。');
    }
    if (parsed.path.endsWith('/responses')) return parsed;
    return parsed.replace(pathSegments: [...parsed.pathSegments, 'responses']);
  }

  /// 只保留可用于诊断的地址部分，避免把 API key 等查询参数写入日志。
  static String sanitizeEndpoint(String endpoint) {
    final parsed = Uri.tryParse(endpoint.trim());
    if (parsed == null || !parsed.hasScheme || !parsed.hasAuthority) {
      return endpoint.split('?').first.split('#').first;
    }
    return parsed.replace(query: null, fragment: null).toString();
  }

  /// 统一从响应体（Chat 或 Responses 格式）解析文本内容
  static String? extractResponseText(Map<String, dynamic> decoded) {
    // 1. 尝试 Responses API 格式
    final output = decoded['output'];
    if (output is List && output.isNotEmpty) {
      final first = output.first;
      if (first is Map) {
        final contentList = first['content'];
        if (contentList is List && contentList.isNotEmpty) {
          final textItem = contentList.first;
          if (textItem is Map && textItem['text'] is String) {
            return textItem['text'] as String;
          }
        }
      }
    }
    final outputText = decoded['output_text'];
    if (outputText is String && outputText.isNotEmpty) {
      return outputText;
    }

    // 2. 尝试 Chat Completions 格式
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final message = (choices.first as Map)['message'];
      if (message is Map && message['content'] is String) {
        return message['content'] as String;
      }
    }

    return null;
  }
}

/// 仅表示当前服务调用已经被后续请求替代，不代表 AI 服务本身失败。
class AiRequestSupersededException implements Exception {
  const AiRequestSupersededException(this.requestToken);

  final String requestToken;

  @override
  String toString() => 'AI 请求已被更新的请求替代。';
}
