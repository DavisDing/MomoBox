import 'dart:async';

import 'package:http/http.dart' as http;

import '../data/repositories/inventory_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../domain/models/ai_usage_models.dart';
import '../domain/models/inventory_models.dart';
import '../services/secure_settings_service.dart';
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

  Future<String> ask(String question, List<ChatMessage> history) async {
    final configs = await _resolveFallbackConfigs();
    if (configs.isEmpty) {
      throw StateError('请先在「设置 -> AI 解析配置」中填写兼容 OpenAI 的 AI 地址、模型和 API Key。');
    }

    // 获取当前完整库存和批次快照作为上下文
    final inventory = await _inventoryRepository
        .watchInventory()
        .first
        .timeout(const Duration(seconds: 3), onTimeout: () => const <InventoryItem>[]);

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
回答风格亲切、简洁、准确。严格依据提供的库存数据进行解答，如果库存中没有某件物品或数据未记录，请诚实说明。

${buffer.toString()}
''';

    final recentHistory = history.take(6).map((m) => {'role': m.role, 'content': m.content}).toList();

    try {
      final response = await _fallbackExecutor.execute(
        configs: configs,
        systemPrompt: systemPrompt,
        userPrompt: question,
        chatHistory: recentHistory,
        temperature: 0.3,
      );

      _recordUsage(response.rawDecoded, response.usedConfig.model, response.actualProtocol);

      return response.content.trim();
    } on AiFallbackException catch (error) {
      throw StateError('AI 服务异常：$error');
    }
  }

  Future<List<AiEndpointConfig>> _resolveFallbackConfigs() async {
    final configs = <AiEndpointConfig>[];

    // 主 API
    final primaryEndpoint = await _settings.getValue(AiDraftService.endpointKey);
    final primaryModel = await _settings.getValue(AiDraftService.modelKey);
    final activeProfileId = await _settings.getValue(AiDraftService.activeProfileKey);
    final profileKey = activeProfileId == null || activeProfileId.isEmpty
        ? null
        : await _secureSettings.readAiApiKeyForProfile(activeProfileId);
    final primaryApiKey = profileKey ?? await _secureSettings.readAiApiKey();
    final primaryType = (await _settings.getValue(AiDraftService.endpointTypeKey)) ?? 'auto';

    if (primaryEndpoint != null && primaryModel != null && primaryApiKey != null) {
      configs.add(
        AiEndpointConfig(
          level: AiApiLevel.primary,
          endpoint: primaryEndpoint,
          apiKey: primaryApiKey,
          model: primaryModel,
          endpointType: primaryType,
          timeout: const Duration(seconds: 5),
        ),
      );
    }

    // 副 API
    final secEndpoint = await _settings.getValue(AiDraftService.secondaryEndpointKey);
    final secModel = await _settings.getValue(AiDraftService.secondaryModelKey);
    final secApiKey = await _secureSettings.readAiApiKeyForProfile('secondary_profile');
    final secType = (await _settings.getValue(AiDraftService.secondaryTypeKey)) ?? 'auto';
    if (secEndpoint != null && secModel != null && secApiKey != null) {
      configs.add(
        AiEndpointConfig(
          level: AiApiLevel.secondary,
          endpoint: secEndpoint,
          apiKey: secApiKey,
          model: secModel,
          endpointType: secType,
          timeout: const Duration(seconds: 5),
        ),
      );
    }

    // 兜底模型
    final fallbackEndpoint = await _settings.getValue(AiDraftService.fallbackEndpointKey);
    final fallbackModel = await _settings.getValue(AiDraftService.fallbackModelKey);
    final fallbackApiKey = await _secureSettings.readAiApiKeyForProfile('fallback_profile');
    final fallbackType = (await _settings.getValue(AiDraftService.fallbackTypeKey)) ?? 'auto';
    if (fallbackEndpoint != null && fallbackModel != null && fallbackApiKey != null) {
      configs.add(
        AiEndpointConfig(
          level: AiApiLevel.fallback,
          endpoint: fallbackEndpoint,
          apiKey: fallbackApiKey,
          model: fallbackModel,
          endpointType: fallbackType,
          timeout: const Duration(seconds: 8),
        ),
      );
    }

    return configs;
  }

  void _recordUsage(Map<String, dynamic> decoded, String model, String endpointType) {
    try {
      final usage = decoded['usage'];
      if (usage is! Map) return;

      final prompt = (usage['prompt_tokens'] ?? usage['input_tokens'] ?? 0) as num;
      final completion = (usage['completion_tokens'] ?? usage['output_tokens'] ?? 0) as num;
      final total = (usage['total_tokens'] ?? (prompt + completion)) as num;

      int cachedRead = 0;
      int cachedWrite = 0;
      final promptDetails = usage['prompt_tokens_details'] ?? usage['input_token_details'];
      if (promptDetails is Map) {
        cachedRead = ((promptDetails['cached_tokens'] ?? 0) as num).toInt();
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
        ),
      );
    } catch (_) {}
  }
}
