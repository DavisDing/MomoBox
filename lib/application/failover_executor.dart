/// 依次尝试主服务、副服务和兜底服务的通用执行器。
///
/// 各具体服务只负责构建请求、解析响应和校验结果；这里统一处理
/// 可选配置过滤、尝试顺序、耗时记录和全链路失败。
enum ServiceFallbackLevel { primary, secondary, fallback }

class ServiceExecutionAttemptLog<C> {
  const ServiceExecutionAttemptLog({
    required this.config,
    required this.level,
    required this.endpoint,
    required this.durationMs,
    required this.isSuccess,
    this.failureReason,
  });

  final C config;
  final ServiceFallbackLevel level;
  final String endpoint;
  final int durationMs;
  final bool isSuccess;
  final String? failureReason;
}

class FailoverResponse<C, T> {
  const FailoverResponse({
    required this.value,
    required this.usedConfig,
    required this.traceLogs,
  });

  final T value;
  final C usedConfig;
  final List<ServiceExecutionAttemptLog<C>> traceLogs;
}

class FailoverException<C> implements Exception {
  const FailoverException(this.message, this.traceLogs);

  final String message;
  final List<ServiceExecutionAttemptLog<C>> traceLogs;

  @override
  String toString() => message;
}

class FailoverExecutor<C, T> {
  const FailoverExecutor();

  Future<FailoverResponse<C, T>> execute({
    required List<C> configs,
    required bool Function(C config) isConfigured,
    required ServiceFallbackLevel Function(C config) levelOf,
    required String Function(C config) endpointOf,
    required Future<T> Function(C config) call,
    required bool Function(T value) isValidResult,
    required String noConfigMessage,
    required String allFailedMessage,
  }) async {
    final activeConfigs = configs.where(isConfigured).toList(growable: false);
    if (activeConfigs.isEmpty) throw StateError(noConfigMessage);

    final traceLogs = <ServiceExecutionAttemptLog<C>>[];
    for (final config in activeConfigs) {
      final stopwatch = Stopwatch()..start();
      String? failureReason;
      T? value;
      var completed = false;
      try {
        value = await call(config);
        completed = true;
        if (!isValidResult(value as T)) {
          throw const FormatException('服务返回内容为空或不可用');
        }
      } catch (error) {
        failureReason = error.toString();
      } finally {
        stopwatch.stop();
      }

      final isSuccess = failureReason == null && completed;
      traceLogs.add(
        ServiceExecutionAttemptLog<C>(
          config: config,
          level: levelOf(config),
          endpoint: endpointOf(config),
          durationMs: stopwatch.elapsedMilliseconds,
          isSuccess: isSuccess,
          failureReason: failureReason,
        ),
      );
      if (isSuccess) {
        return FailoverResponse(value: value as T, usedConfig: config, traceLogs: traceLogs);
      }
    }

    throw FailoverException<C>(allFailedMessage, traceLogs);
  }
}
