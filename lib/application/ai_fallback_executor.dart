import 'dart:async';
import 'package:uuid/uuid.dart';
import '../data/nas/nas_api_error.dart';
import 'backend_processing_service.dart';
import 'backend_processing_error.dart';

enum AiApiLevel { primary, secondary, fallback }

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
    required this.model,
    required this.actualProtocol,
    required this.traceLogs,
  });

  final String content;
  final Map<String, dynamic> rawDecoded;
  final AiApiLevel usedLevel;
  final String model;
  final String actualProtocol;
  final List<AiExecutionAttemptLog> traceLogs;
}

/// Authenticated NAS-only AI boundary. No model URLs or credentials are
/// accepted by the mobile client. Provider failover is owned by the NAS.
class AiFallbackExecutor {
  AiFallbackExecutor({required this.backendResolver, this.modelReader,
    bool Function(String content)? contentFilter}) : _contentFilter = contentFilter;
  final BackendResolver backendResolver;
  final Future<String?> Function()? modelReader;
  final bool Function(String content)? _contentFilter;
  void close() {}

  Future<AiFallbackResponse> execute({required String systemPrompt,
    required String userPrompt, List<Map<String,String>> chatHistory = const [],
    double temperature = 0.2}) async {
    final api = await backendResolver();
    if (api == null) throw const BackendProcessingSetupException('请先连接 NAS 后端并登录家庭账号。');
    final model = await modelReader?.call();
    api.assertCurrentSession();
    final capabilities = await api.processingRequest('/capabilities',method:'GET');
    if (capabilities['backend_ai'] != true) {
      throw const BackendProcessingSetupException('NAS 尚未配置 AI 网关。请在 NAS Compose 设置 AI_ENDPOINT 和 AI_API_KEY 后重建后端容器（AI_MODEL 可留空自动获取）。');
    }
    final result = await api.processingRequest('/ai/analyze', body:{
      'request_id':const Uuid().v4(), 'system_prompt':systemPrompt,
      'user_prompt':userPrompt, 'history':chatHistory, 'temperature':temperature,
      if (model?.isNotEmpty == true) 'model':model,
    });
    api.assertCurrentSession();
    final content = result['content'];
    if (content is! String || content.trim().isEmpty ||
        (_contentFilter != null && !_contentFilter(content))) {
      throw const FormatException('NAS AI 返回内容无效。');
    }
    final modelName = result['model'], protocol = result['protocol'], elapsed = result['elapsed_ms'];
    if (modelName is! String || protocol is! String || elapsed is! int) {
      throw const FormatException('NAS AI 返回信息不完整。');
    }
    final level = switch(result['level']) {
      'secondary'=>AiApiLevel.secondary,'fallback'=>AiApiLevel.fallback,_=>AiApiLevel.primary,
    };
    return AiFallbackResponse(content:content, rawDecoded:{'usage':result['usage']},
      usedLevel:level, model:modelName, actualProtocol:protocol,
      traceLogs:[AiExecutionAttemptLog(level:level,model:modelName,endpoint:'NAS',
        durationMs:elapsed,isSuccess:true)]);
  }
}

/// Only display sanitized classifications, never upstream bodies or URLs.
String aiFailureMessage(Object error) {
  if (error is BackendProcessingSetupException) return error.message;
  if (error is NasApiError) {
    return switch (error.code) {
      'AI_RESULT_UNKNOWN' => 'NAS 上一次 AI 请求结果不明，请核实后再手动发起新请求。',
      'PROCESSING_BUSY' => 'NAS 正在处理其他请求，请稍后重试。',
      'PROCESSOR_UNAVAILABLE' => 'NAS AI 服务不可用，请检查 NAS 上的模型地址、模型、密钥及网络。',
      'PROCESSING_FAILED' => 'NAS AI 处理失败，请检查 NAS 后端日志。',
      _ => switch (error.kind) {
        NasApiErrorKind.unauthorized => 'NAS 登录已失效，请在家庭与同步中重新登录。',
        NasApiErrorKind.forbidden => 'NAS 家庭或设备身份不可用，请在 NAS 设置中重试连接；尚未加入家庭时需填写邀请码。',
        NasApiErrorKind.notFound => 'NAS 尚不支持此 AI 接口，请更新 NAS 后端。',
        NasApiErrorKind.network => '无法连接 NAS，请检查手机到 NAS 的网络和服务器地址。',
        NasApiErrorKind.timeout => 'NAS AI 请求超时，请核实处理结果后再手动重试。',
        NasApiErrorKind.rateLimited => 'NAS 请求过于频繁，请稍后重试。',
        NasApiErrorKind.server => 'NAS AI 服务暂时不可用，请检查 NAS 配置和后端日志。',
        _ => 'NAS AI 请求失败，请检查 NAS 配置、会话及接口版本。',
      },
    };
  }
  if (error is TimeoutException) return '请求超时，请检查网络后重试。';
  if (error is FormatException) return 'AI 返回的数据格式不兼容或缺少有效文本，请检查接口协议和后端版本。';
  return '请检查 NAS 连接及 NAS 部署中的 AI 配置后重试。';
}
