/// AI 协议调用与自适应辅助工具
class AiClientHelper {
  const AiClientHelper._();

  /// 根据 endpoint 与配置的 endpointType 推断应使用的协议及 URI
  ///
  /// 如果 endpoint 显式以 `/responses` 结尾，则判定为 responses；
  /// 如果显式以 `/chat/completions` 结尾，则判定为 chat；
  /// 否则若配置为 'auto'，返回 auto 并提供优先尝试的协议。
  static String resolveProtocol(String endpoint, String configuredType) {
    final clean = (Uri.tryParse(endpoint.trim())?.path ?? '').replaceAll(RegExp(r'/+$'), '');
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
    final input = Uri.tryParse(endpoint.trim());
    final parsed = input?.replace(path: input.path.replaceAll(RegExp(r'/+$'), ''));
    if (parsed == null || !['http', 'https'].contains(parsed.scheme) || parsed.host.isEmpty || parsed.userInfo.isNotEmpty) {
      throw ArgumentError('AI 服务地址无效。');
    }
    if (parsed.path.endsWith('/chat/completions')) return parsed;
    return parsed.replace(pathSegments: [...parsed.pathSegments, 'chat', 'completions']);
  }

  static Uri responsesUri(String endpoint) {
    final input = Uri.tryParse(endpoint.trim());
    final parsed = input?.replace(path: input.path.replaceAll(RegExp(r'/+$'), ''));
    if (parsed == null || !['http', 'https'].contains(parsed.scheme) || parsed.host.isEmpty || parsed.userInfo.isNotEmpty) {
      throw ArgumentError('AI 服务地址无效。');
    }
    if (parsed.path.endsWith('/responses')) return parsed;
    return parsed.replace(pathSegments: [...parsed.pathSegments, 'responses']);
  }

  /// 只保留可用于诊断的地址部分，避免把 API key 等查询参数写入日志。
  static String sanitizeEndpoint(String endpoint) {
    final trimmed = endpoint.trim();
    final separator = trimmed.indexOf(RegExp(r'[?#]'));
    final withoutQuery = separator < 0 ? trimmed : trimmed.substring(0, separator);
    final parsed = Uri.tryParse(withoutQuery);
    return parsed?.hasAuthority == true
        ? parsed!.replace(userInfo: '').toString()
        : withoutQuery;
  }

  /// 统一从响应体（Chat 或 Responses 格式）解析文本内容
  static String? extractResponseText(Map<String, dynamic> decoded) {
    String? textParts(Object? content) {
      if (content is String) return content;
      if (content is! List) return null;
      final text = content.whereType<Map>()
          .where((part) => part['type'] == null ||
              part['type'] == 'text' || part['type'] == 'output_text')
          .map((part) => part['text'])
          .whereType<String>().where((text) => text.trim().isNotEmpty)
          .join('\n');
      return text.isEmpty ? null : text;
    }

    // Reasoning/tool items may precede assistant messages. Read every text
    // part, without exposing reasoning summaries or tool arguments as answers.
    final output = decoded['output'];
    if (output is List) {
      final text = output.whereType<Map>()
          .where((item) => item['type'] == null || item['type'] == 'message')
          .map((item) => textParts(item['content']))
          .whereType<String>().join('\n');
      if (text.isNotEmpty) return text;
    }
    final outputText = textParts(decoded['output_text']);
    if (outputText != null) return outputText;
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final message = (choices.first as Map)['message'];
      if (message is Map) return textParts(message['content']);
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
