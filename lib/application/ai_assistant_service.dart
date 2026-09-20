import 'dart:async';

import 'package:http/http.dart' as http;

import '../data/repositories/inventory_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../domain/models/ai_usage_models.dart';
import '../services/secure_settings_service.dart';
import 'ai_client_helper.dart';
import 'ai_draft_service.dart';
import 'ai_fallback_executor.dart';
import 'ai_usage_service.dart';

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
  });

  final String id;
  final String role; // 'user', 'assistant', 'system'
  final String content;
  final DateTime timestamp;
}

class AiAssistantService {
  AiAssistantService(
    this._settings,
    this._secureSettings,
    this._inventoryRepository, {
    http.Client? client,
    AiUsageService? usageService,
    AiFallbackExecutor? fallbackExecutor,
  })  : _usageService = usageService ?? AiUsageService(_settings),
        _fallbackExecutor = fallbackExecutor ?? AiFallbackExecutor(client: client);

  final SettingsRepository _settings;
  final SecureSettingsService _secureSettings;
  final InventoryRepository _inventoryRepository;
  final AiUsageService _usageService;
  final AiFallbackExecutor _fallbackExecutor;
  int _requestSequence = 0;
  String? _latestRequestToken;

  /// Begins a new assistant request. A newer request invalidates an older
  /// response before it can be returned to the UI.
  String createRequestToken() {
    final token = '${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';
    _latestRequestToken = token;
    return token;
  }

  Future<String> ask(
    String question,
    List<ChatMessage> history, {
    String? requestToken,
  }) async {
    final token = requestToken ?? createRequestToken();
    _latestRequestToken = token;
    void ensureCurrent() {
      if (_latestRequestToken != token) {
        throw AiRequestSupersededException(token);
      }
    }
    ensureCurrent();
    final configs = await _resolveFallbackConfigs();
    ensureCurrent();
    if (configs.isEmpty) {
      throw StateError('请先在「设置 -> AI 解析配置」中填写兼容 OpenAI 的 AI 地址、模型和 API Key。');
    }

    // 获取当前完整库存和批次快照作为上下文
    final inventory = await _inventoryRepository
        .watchInventory()
        .first
        .timeout(const Duration(seconds: 3));
    ensureCurrent();

    final buffer = StringBuffer();
    buffer.writeln('【当前时间】：${DateTime.now().toIso8601String().substring(0, 10)}');
    buffer.writeln('【当前家庭库存物品清单】：');
    if (inventory.isEmpty) {
      buffer.writeln('（目前库存为空，暂无物品）');
    } else {
      for (final item in inventory) {
        buffer.writeln(
          '- 商品名: ${item.name}, 分类: ${item.category}, 品牌: ${item.brand ?? "无"}, 规格: ${item.specification ?? "无"}, 存放位置: ${item.location ?? "未指定"}, 总余量: ${item.totalStock} ${item.unit}',
        );
        for (final b in item.batches) {
          final exp = b.expiryDate != null ? b.expiryDate!.toIso8601String().substring(0, 10) : '未记录';
          final prod = b.productionDate != null ? b.productionDate!.toIso8601String().substring(0, 10) : '未记录';
          final days = b.daysUntilExpiry;
          final state = b.isDiscarded
              ? '已丢弃'
              : (days != null && days < 0 ? '已过期 ${-days} 天' : (days != null ? '剩余 $days 天到期' : '无明确到期日'));
          buffer.writeln(
            '  * 批次 ${b.batchNo ?? "默认"}: 余量 ${b.remainingQuantity}, 生产日期: $prod, 保质期/到期日: $exp ($state)',
          );
        }
      }
    }

    final systemPrompt = '''
你是「MomoBox 嬷嬷的小箱子」内置的智能管家吉祥物。
你的职责是帮助用户查询家庭物品库存、到期情况、质保期、存放位置、采买建议等。
你只有库存只读查询能力，无法修改库存、记录消耗、控制设备或执行混合计划。不得声称任何操作已执行、扣减或写入；如用户请求这些操作，请引导至库存页手动确认，设备控制尚未支持。
回答风格亲切、简洁、准确。严格依据提供的库存数据进行解答，如果库存中没有某件物品或数据未记录，请诚实说明。

${buffer.toString()}
''';

    final recentMessages = history.length <= 6 ? history : history.sublist(history.length - 6);
    final recentHistory = recentMessages.map((m) => {'role': m.role, 'content': m.content}).toList();

    try {
      final response = await _fallbackExecutor.execute(
        configs: configs,
        systemPrompt: systemPrompt,
        userPrompt: question,
        chatHistory: recentHistory,
        temperature: 0.3,
      );

      ensureCurrent();
      _recordUsage(
        response.rawDecoded,
        response.usedConfig.model,
        response.actualProtocol,
        providerLevel: response.usedLevel.name,
        elapsedMs: response.traceLogs.fold<int>(0, (sum, log) => sum + log.durationMs),
      );

      ensureCurrent();
      return response.content.trim();
    } on AiRequestSupersededException {
      rethrow;
    } on AiFallbackException catch (error) {
      if (_latestRequestToken == token) {
        _recordFailureAttempts(error.traceLogs, 'qa');
      }
      throw StateError('AI 服务异常：$error');
    }
  }

  Future<List<AiEndpointConfig>> _resolveFallbackConfigs() =>
      AiDraftService.resolveFallbackConfigs(_settings, _secureSettings);

  void _recordUsage(
    Map<String, dynamic> decoded,
    String model,
    String endpointType, {
    String? providerLevel,
    int elapsedMs = 0,
  }) {
    try {
      final usage = decoded['usage'] is Map
          ? decoded['usage'] as Map
          : const <String, dynamic>{};

      final prompt = _asNum(usage['prompt_tokens'] ?? usage['input_tokens']);
      final completion = _asNum(usage['completion_tokens'] ?? usage['output_tokens']);
      final total = _asNum(usage['total_tokens'], fallback: prompt + completion);

      int cachedRead = 0;
      int cachedWrite = 0;
      final promptDetails = usage['prompt_tokens_details'] ?? usage['input_token_details'];
      if (promptDetails is Map) {
        cachedRead = _asNum(promptDetails['cached_tokens']).toInt();
      }
      final cacheCreation = usage['cache_creation_input_tokens'];
      if (cacheCreation is num) {
        cachedWrite = cacheCreation.toInt();
      }

      _usageService.recordUsage(
        AiUsageRecord(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          timestamp: DateTime.now(),
          model: model,
          endpointType: endpointType,
          promptTokens: prompt.toInt(),
          completionTokens: completion.toInt(),
          totalTokens: total.toInt(),
          cachedWriteTokens: cachedWrite,
          cachedReadTokens: cachedRead,
          purpose: 'qa',
          providerLevel: providerLevel,
          elapsedMs: elapsedMs,
        ),
      );
    } catch (_) {}
  }

  void _recordFailureAttempts(
    List<AiExecutionAttemptLog> attempts,
    String purpose,
  ) {
    for (final attempt in attempts) {
      _usageService.recordUsage(
        AiUsageRecord(
          id: '${DateTime.now().microsecondsSinceEpoch}-${attempt.level.name}',
          timestamp: DateTime.now(),
          model: attempt.model,
          endpointType: 'unknown',
          promptTokens: 0,
          completionTokens: 0,
          totalTokens: 0,
          purpose: purpose,
          status: 'failure',
          providerLevel: attempt.level.name,
          failureReason: attempt.failureReason,
          elapsedMs: attempt.durationMs,
        ),
      );
    }
  }
}

num _asNum(Object? value, {num fallback = 0}) => value is num && value.isFinite ? value : fallback;
