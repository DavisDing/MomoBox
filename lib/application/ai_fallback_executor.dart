import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import 'ai_client_helper.dart';

enum AiApiLevel { primary, secondary, fallback }

/// 各级 API 的独立配置
class AiEndpointConfig {
  const AiEndpointConfig({
    required this.level,
    required this.endpoint,
    required this.apiKey,
    required this.model,
    this.endpointType = 'auto',
    this.timeout = const Duration(seconds: 5),
    this.maxRetries = 0,
  });

  final AiApiLevel level;
  final String endpoint;
  final String apiKey;
  final String model;
  final String endpointType; // 'auto', 'chat', 'responses'
  final Duration timeout;
  final int maxRetries;

  bool get isValid =>
      endpoint.trim().isNotEmpty && apiKey.trim().isNotEmpty && model.trim().isNotEmpty;
}

/// 单次调用的耗时与状态审计日志
class AiExecutionAttemptLog {
  const AiExecutionAttemptLog({
    required this.level,
    required this.model,
    required this.endpoint,
    required this.durationMs,
    required this.isSuccess,
    this.failureReason,
  });

  final AiApiLevel level;
  final String model;
  final String endpoint;
  final int durationMs;
  final bool isSuccess;
  final String? failureReason;

  @override
  String toString() =>
      '[$level][$model] 耗时:${durationMs}ms 状态:${isSuccess ? "成功" : "失败"}${failureReason != null ? " 原因:$failureReason" : ""}';
}

/// 降级执行统一返回结构（对调用方透明）
class AiFallbackResponse {
  const AiFallbackResponse({
    required this.content,
    required this.rawDecoded,
    required this.usedLevel,
    required this.usedConfig,
    required this.actualProtocol,
    required this.traceLogs,
  });

  final String content;
  final Map<String, dynamic> rawDecoded;
  final AiApiLevel usedLevel;
  final AiEndpointConfig usedConfig;
  final String actualProtocol;
  final List<AiExecutionAttemptLog> traceLogs;
}

/// 全链路失败的标准错误结构
class AiFallbackException implements Exception {
  const AiFallbackException(this.message, this.traceLogs);

  final String message;
  final List<AiExecutionAttemptLog> traceLogs;

  @override
  String toString() {
    final buffer = StringBuffer('AI调用全链路降级失败: $message\n【调用链追踪】:\n');
    for (final log in traceLogs) {
      buffer.writeln(' - $log');
    }
    return buffer.toString();
  }
}

/// 核心调度引擎：实现「主 API → 副 API → 兜底模型」透明降级
class AiFallbackExecutor {
  AiFallbackExecutor({
    http.Client? client,
    bool Function(String content)? contentFilter,
  })  : _client = client ?? http.Client(),
        _contentFilter = contentFilter;

  final http.Client _client;
  final bool Function(String content)? _contentFilter;

  /// 执行三级降级请求
  Future<AiFallbackResponse> execute({
    required List<AiEndpointConfig> configs,
    required String systemPrompt,
    required String userPrompt,
    List<Map<String, String>> chatHistory = const [],
    double temperature = 0.2,
  }) async {
    final activeConfigs = configs.where((c) => c.isValid).toList();
    if (activeConfigs.isEmpty) {
      throw StateError('没有可用的 AI 配置，请检查主/副/兜底 API 配置。');
    }

    final traceLogs = <AiExecutionAttemptLog>[];

    for (final config in activeConfigs) {
      final stopwatch = Stopwatch()..start();
      String? failureReason;
      Map<String, dynamic>? validDecoded;
      String? validContent;
      String actualUsedType = 'chat';

      try {
        final result = await _callSingleApi(
          config: config,
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          chatHistory: chatHistory,
          temperature: temperature,
        );
        validDecoded = result['decoded'] as Map<String, dynamic>;
        validContent = result['content'] as String;
        actualUsedType = result['protocol'] as String;

        // 判定 3: 提取内容为空
        if (validContent.trim().isEmpty) {
          throw const FormatException('模型返回文本内容为空');
        }
        // 判定 4: 命中敏感/异常关键词
        if (_contentFilter != null && !_contentFilter(validContent)) {
          throw const FormatException('返回内容命中敏感或异常关键词校验');
        }
      } catch (e) {
        failureReason = e.toString();
      } finally {
        stopwatch.stop();
      }

      final isSuccess = failureReason == null && validContent != null;
      traceLogs.add(
        AiExecutionAttemptLog(
          level: config.level,
          model: config.model,
          endpoint: config.endpoint,
          durationMs: stopwatch.elapsedMilliseconds,
          isSuccess: isSuccess,
          failureReason: failureReason,
        ),
      );

      // 只要有一级成功，直接返回对上层透明的结果
      if (isSuccess && validDecoded != null) {
        developer.log(
          'AI 在 [${config.level}] 调用成功，耗时 ${stopwatch.elapsedMilliseconds}ms',
          name: 'AiFallbackExecutor',
        );
        return AiFallbackResponse(
          content: validContent,
          rawDecoded: validDecoded,
          usedLevel: config.level,
          usedConfig: config,
          actualProtocol: actualUsedType,
          traceLogs: traceLogs,
        );
      }

      developer.log(
        'AI [${config.level}] 失败，耗时 ${stopwatch.elapsedMilliseconds}ms, 触发降级. 原因: $failureReason',
        name: 'AiFallbackExecutor',
        error: failureReason,
      );
    }

    developer.log(
      'AI 三级调用链均告失败！',
      name: 'AiFallbackExecutor',
      error: traceLogs.map((e) => e.toString()).join('\n'),
    );
    throw AiFallbackException('三级 API 均不可用，已尝试所有降级模型', traceLogs);
  }

  Future<Map<String, dynamic>> _callSingleApi({
    required AiEndpointConfig config,
    required String systemPrompt,
    required String userPrompt,
    required List<Map<String, String>> chatHistory,
    required double temperature,
  }) async {
    final protocol = AiClientHelper.resolveProtocol(config.endpoint, config.endpointType);
    final attempts = (protocol == 'responses')
        ? ['responses']
        : (protocol == 'chat')
            ? ['chat']
            : ['chat', 'responses'];

    http.Response? response;
    String actualUsedType = attempts.first;

    for (var i = 0; i < attempts.length; i++) {
      final currentType = attempts[i];
      final isResponses = currentType == 'responses';
      final uri = isResponses
          ? AiClientHelper.responsesUri(config.endpoint)
          : AiClientHelper.chatCompletionUri(config.endpoint);

      final Map<String, dynamic> body = isResponses
          ? {
              'model': config.model.trim(),
              'instructions': systemPrompt,
              'input': userPrompt,
            }
          : {
              'model': config.model.trim(),
              'temperature': temperature,
              'messages': [
                {'role': 'system', 'content': systemPrompt},
                ...chatHistory,
                {'role': 'user', 'content': userPrompt},
              ],
            };

      try {
        final res = await _client
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${config.apiKey.trim()}',
              },
              body: jsonEncode(body),
            )
            .timeout(config.timeout); // 判定 1: 超时

        if ((res.statusCode == 404 || res.statusCode == 405) && i < attempts.length - 1) {
          continue;
        }
        response = res;
        actualUsedType = currentType;
        break;
      } on TimeoutException {
        throw TimeoutException('接口请求超时 (超时阈值: ${config.timeout.inSeconds}s)');
      }
    }

    // 判定 2: HTTP 状态码非 2xx
    if (response == null || response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException(
        'HTTP ${response?.statusCode ?? "无响应"}: ${response?.body ?? ""}',
      );
    }

    // 判定 3: 格式解析失败或缺少必需字段
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('响应 Body 不是标准 JSON Map 结构');
    }

    final content = AiClientHelper.extractResponseText(decoded);
    if (content == null || content.trim().isEmpty) {
      throw const FormatException('未从响应中解析到有效文本字段');
    }

    return {
      'content': content.trim(),
      'decoded': decoded,
      'protocol': actualUsedType,
    };
  }
}
