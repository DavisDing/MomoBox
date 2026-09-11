import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';
import '../controllers/smart_home_controller.dart';
import '../../application/ai_assistant_service.dart';

enum AiPlanStatus {
  idle,
  proposed,
  confirmed,
  cancelled,
}

class MixedPlanData {
  const MixedPlanData({
    required this.taskTitle,
    required this.deviceAction,
    required this.consumables,
    required this.selectedConsumable,
    this.status = AiPlanStatus.proposed,
  });

  final String taskTitle;
  final String deviceAction;
  final List<String> consumables;
  final String selectedConsumable;
  final AiPlanStatus status;

  MixedPlanData copyWith({
    String? selectedConsumable,
    AiPlanStatus? status,
  }) {
    return MixedPlanData(
      taskTitle: taskTitle,
      deviceAction: deviceAction,
      consumables: consumables,
      selectedConsumable: selectedConsumable ?? this.selectedConsumable,
      status: status ?? this.status,
    );
  }
}

class AiAssistantDialog extends ConsumerStatefulWidget {
  const AiAssistantDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AiAssistantDialog(),
    );
  }

  @override
  ConsumerState<AiAssistantDialog> createState() => _AiAssistantDialogState();
}

class _AiAssistantDialogState extends ConsumerState<AiAssistantDialog> {
  final _messages = <ChatMessage>[];
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isLoading = false;

  MixedPlanData? _currentPlan;

  @override
  void initState() {
    super.initState();
    _messages.add(
      ChatMessage(
        id: '0',
        role: 'assistant',
        content: '你好呀！我是 MomoBox 的随身智能管家。\n'
            '我可以帮你：\n'
            '① 智能家居控制（如“打开电视”、“客厅空调调到25度”）\n'
            '② 物资查询与记录（如“还有多少洗衣液”、“吃了两片感冒药”）\n'
            '③ 复杂混合计划（如“我要洗衣服” -> 自动规划洗衣机启动与耗材配方确认）\n'
            '请随时吩咐我吧！',
        timestamp: DateTime.now(),
      ),
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage([String? presetText]) async {
    final text = (presetText ?? _textController.text).trim();
    if (text.isEmpty || _isLoading) return;

    if (presetText == null) {
      _textController.clear();
    }

    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: text,
      timestamp: DateTime.now(),
    );

    setState(() {
      _messages.add(userMsg);
      _isLoading = true;
    });
    _scrollToBottom();

    // 优先匹配 3 种 Mock 意图交互与真实问答回退
    final handledLocally = await _tryHandleMockIntents(text);
    if (handledLocally) {
      if (mounted) {
        setState(() => _isLoading = false);
        _scrollToBottom();
      }
      return;
    }

    // 回退调用底层已有的 AI 助手服务 (兼容用户自配 API Key)
    try {
      final assistantService = ref.read(aiAssistantServiceProvider);
      final history = _messages.where((m) => m.role == 'user' || m.role == 'assistant').toList();
      final reply = await assistantService.ask(text, history);

      if (mounted) {
        setState(() {
          _messages.add(
            ChatMessage(
              id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
              role: 'assistant',
              content: reply,
              timestamp: DateTime.now(),
            ),
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add(
            ChatMessage(
              id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
              role: 'assistant',
              content: '小管家收到：“$text”。\n'
                  '（若要查询真实库存或调用远端大模型，请在「我的」中配置 AI 密钥；当前已作为本地智能指令处理。）',
              timestamp: DateTime.now(),
            ),
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _scrollToBottom();
      }
    }
  }

  /// 匹配 3 类智能意图并给出高可用 UI 反馈
  Future<bool> _tryHandleMockIntents(String text) async {
    final lower = text.toLowerCase();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // 意图 3: 混合计划（洗衣服 / 启动洗烘并扣耗材）
    if (lower.contains('洗衣服') || lower.contains('洗涤') || lower.contains('开洗衣机')) {
      setState(() {
        _currentPlan = const MixedPlanData(
          taskTitle: '洗衣家庭自动化计划',
          deviceAction: '启动阳台洗烘一体机（标准洗涤程序）',
          consumables: ['蓝月亮机洗专用洗衣液（1份）', '碧浪倍净洗衣凝珠（1颗）', '威露士衣物除菌液（1盖）'],
          selectedConsumable: '蓝月亮机洗专用洗衣液（1份）',
        );
        _messages.add(
          ChatMessage(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            role: 'assistant',
            content: '检测到混合计划意图：【洗衣服】。\n'
                '我已为你规划了设备控制与耗材方案，请在下方确认执行：',
            timestamp: DateTime.now(),
          ),
        );
      });
      return true;
    }

    // 意图 1: 设备控制 (打开电视 / 调空调 / 开关灯)
    if (lower.contains('打开电视') || lower.contains('开电视')) {
      ref.read(smartHomeControllerProvider.notifier).toggleDevice('media_player.living_room_tv');
      _addAssistantReply('✅ 已通过 Home Assistant 为你打开【客厅电视】（Mock 成功，设备状态已同步）');
      return true;
    }
    if (lower.contains('关闭电视') || lower.contains('关电视')) {
      ref.read(smartHomeControllerProvider.notifier).toggleDevice('media_player.living_room_tv');
      _addAssistantReply('✅ 已为你关闭【客厅电视】。');
      return true;
    }
    if (lower.contains('空调') && (lower.contains('25') || lower.contains('调到'))) {
      _addAssistantReply('❄️ 已将【客厅空调】调至制冷模式 25°C，舒适微风已开启。');
      return true;
    }
    if (lower.contains('观影模式') || lower.contains('电影')) {
      _addAssistantReply('🎬 已触发【观影模式】场景：客厅主灯已调暗至 20%，客厅电视已开启！');
      return true;
    }

    // 意图 2: 物资查询与记录 (还有多少洗衣液 / 吃了感冒药)
    if (lower.contains('洗衣液') && (lower.contains('多少') || lower.contains('还有') || lower.contains('库存'))) {
      _addAssistantReply('📦 查询到当前库存：\n'
          '• 【蓝月亮浓缩洗衣液】剩余 2 瓶（批次 20260810，到期日 2027-08）\n'
          '• 库存状态：充足（阈值为 1 瓶）。');
      return true;
    }
    if (lower.contains('感冒药') && (lower.contains('吃了') || lower.contains('消耗') || lower.contains('记录'))) {
      _addAssistantReply('💊 已为你记录消耗：\n'
          '• 商品：999感冒灵颗粒\n'
          '• 操作：按照 FEFO 规则优先消耗最早批次 2 袋\n'
          '• 剩余库存：6 袋。变动记录已写入本地日志。');
      return true;
    }

    return false;
  }

  void _addAssistantReply(String content) {
    setState(() {
      _messages.add(
        ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          role: 'assistant',
          content: content,
          timestamp: DateTime.now(),
        ),
      );
    });
  }

  void _confirmPlan() {
    if (_currentPlan == null) return;
    final plan = _currentPlan!;
    setState(() {
      _currentPlan = plan.copyWith(status: AiPlanStatus.confirmed);
      _messages.add(
        ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          role: 'assistant',
          content: '🎉 计划执行完成！\n'
              '1. ${plan.deviceAction} -> 已向 HA 下发指令；\n'
              '2. 耗材预分配：已扣减 ${plan.selectedConsumable}；\n'
              '3. 变动日志与待确认建议已同步至家居联动列表。',
          timestamp: DateTime.now(),
        ),
      );
    });
    _scrollToBottom();
  }

  void _cancelPlan() {
    setState(() {
      _currentPlan = _currentPlan?.copyWith(status: AiPlanStatus.cancelled);
      _messages.add(
        ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          role: 'assistant',
          content: '已取消本次洗衣服混合计划。',
          timestamp: DateTime.now(),
        ),
      );
    });
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      height: MediaQuery.sizeOf(context).height * 0.88,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 20,
            offset: Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        children: [
          // 顶部标题栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(
                bottom: BorderSide(
                  color: (isDark ? Colors.white.withValues(alpha: 0.08) : palette.primary.withValues(alpha: 0.1)),
                ),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: palette.primary.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Text(palette.mascot, style: const TextStyle(fontSize: 22)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            palette.mascotName,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: palette.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'AI 家庭随身管家',
                              style: TextStyle(fontSize: 10, color: palette.primary, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        '支持设备控制 / 耗材记录 / 混合执行计划',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          // 快捷提问意图胶囊
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _buildQuickChip('🧺 我要洗衣服', palette),
                const SizedBox(width: 8),
                _buildQuickChip('📺 打开电视', palette),
                const SizedBox(width: 8),
                _buildQuickChip('❄️ 空调调到 25 度', palette),
                const SizedBox(width: 8),
                _buildQuickChip('🧴 还有多少洗衣液？', palette),
                const SizedBox(width: 8),
                _buildQuickChip('💊 吃了两片感冒药', palette),
              ],
            ),
          ),

          // 对话列表
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length + (_currentPlan != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index < _messages.length) {
                  final msg = _messages[index];
                  final isUser = msg.role == 'user';
                  return Align(
                    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isUser ? palette.primary : palette.surface,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: Radius.circular(isUser ? 16 : 4),
                          bottomRight: Radius.circular(isUser ? 4 : 16),
                        ),
                        border: isUser
                            ? null
                            : Border.all(
                                color: (isDark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : palette.primary.withValues(alpha: 0.12)),
                              ),
                      ),
                      child: SelectableText(
                        msg.content,
                        style: TextStyle(
                          color: isUser ? Colors.white : theme.textTheme.bodyMedium?.color,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                    ),
                  );
                } else {
                  // 渲染混合任务确认卡片
                  return _buildPlanConfirmCard(palette);
                }
              },
            ),
          ),

          if (_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: palette.primary),
                  ),
                  const SizedBox(width: 8),
                  Text('${palette.mascotName} 正在规划执行方案...', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),

          // 底部输入栏
          Container(
            padding: EdgeInsets.fromLTRB(16, 8, 16, MediaQuery.of(context).viewInsets.bottom + 12),
            decoration: BoxDecoration(
              color: palette.surface,
              border: Border(
                top: BorderSide(
                  color: (isDark ? Colors.white.withValues(alpha: 0.08) : palette.primary.withValues(alpha: 0.1)),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: InputDecoration(
                      hintText: '吩咐${palette.mascotName}，如：“我要洗衣服”、“打开电视”',
                      hintStyle: const TextStyle(fontSize: 13),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.send_rounded, size: 20),
                  style: IconButton.styleFrom(backgroundColor: palette.primary),
                  onPressed: _isLoading ? null : () => _sendMessage(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickChip(String label, MomoPalette palette) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: palette.surface,
      side: BorderSide(color: palette.primary.withValues(alpha: 0.2)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      onPressed: _isLoading ? null : () => _sendMessage(label.replaceAll(RegExp(r'^[^\s]+\s+'), '')),
    );
  }

  Widget _buildPlanConfirmCard(MomoPalette palette) {
    final plan = _currentPlan;
    if (plan == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isProposed = plan.status == AiPlanStatus.proposed;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: (isDark ? const Color(0xFF1E293B) : palette.surface),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isProposed ? palette.primary : Colors.grey.withValues(alpha: 0.3),
          width: isProposed ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.assignment_turned_in_outlined, color: palette.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  plan.taskTitle,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isProposed ? Colors.orange.withValues(alpha: 0.15) : Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isProposed ? '待确认计划' : (plan.status == AiPlanStatus.confirmed ? '已执行' : '已取消'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isProposed ? Colors.orange.shade800 : Colors.green,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('1. 设备联动：${plan.deviceAction}', style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
          const Text('2. 耗材扣减配方（请确认使用耗材）：', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...plan.consumables.map((c) {
            final isSelected = c == plan.selectedConsumable;
            return InkWell(
              onTap: isProposed
                  ? () {
                      setState(() {
                        _currentPlan = plan.copyWith(selectedConsumable: c);
                      });
                    }
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 18,
                      color: isSelected ? palette.primary : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        c,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          if (isProposed) ...[
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: _cancelPlan,
                  child: const Text('取消'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: palette.primary),
                  onPressed: _confirmPlan,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('确认执行计划'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
