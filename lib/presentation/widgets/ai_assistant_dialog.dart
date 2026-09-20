import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';
import 'package:uuid/uuid.dart';
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


class AiSession {
  AiSession({
    required this.id,
    required this.title,
    required this.createdAt,
    List<ChatMessage>? messages,
  }) : messages = messages ?? [];

  final String id;
  String title;
  final DateTime createdAt;
  final List<ChatMessage> messages;

  AiSession copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    List<ChatMessage>? messages,
  }) {
    return AiSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      messages: messages != null ? List.from(messages) : List.from(this.messages),
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
  final _sessions = <AiSession>[];
  String _currentSessionId = '';
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isLoading = false;
  Object? _activeRequestToken;
  String? _activeRequestSessionId;

  MixedPlanData? _currentPlan;

  AiSession get _currentSession {
    return _sessions.firstWhere(
      (s) => s.id == _currentSessionId,
      orElse: () => _sessions.first,
    );
  }

  List<ChatMessage> get _messages => _currentSession.messages;

  ChatMessage _createDefaultWelcomeMessage() {
    return ChatMessage(
      id: '0',
      role: 'assistant',
      content: '你好呀！我是 MomoBox 的随身智能管家。\n'
          '我可以帮你：\n'
          '① 基于真实库存查询数量、效期和存放位置\n'
          '② 提供采买建议（需先配置 AI 服务）\n'
          '当前助手只读，不会扣减库存或控制设备。请在库存页确认消耗；NAS、家居控制与混合计划尚未支持。',
      timestamp: DateTime.now(),
    );
  }

  @override
  void initState() {
    super.initState();
    final initialSession = AiSession(
      id: const Uuid().v4(),
      title: '新对话',
      createdAt: DateTime.now(),
      messages: [_createDefaultWelcomeMessage()],
    );
    _sessions.add(initialSession);
    _currentSessionId = initialSession.id;
  }

  void _createNewSession() {
    setState(() {
      final newSession = AiSession(
        id: const Uuid().v4(),
        title: '新会话 ${_sessions.length + 1}',
        createdAt: DateTime.now(),
        messages: [_createDefaultWelcomeMessage()],
      );
      _sessions.insert(0, newSession);
      _currentSessionId = newSession.id;
      _currentPlan = null;
    });
    _scrollToBottom();
  }

  void _switchSession(String sessionId) {
    setState(() {
      _currentSessionId = sessionId;
      _currentPlan = null;
    });
    _scrollToBottom();
  }

  void _deleteSession(String sessionId) {
    if (_sessions.length <= 1) {
      // Keep the list item stable while clearing its contents. The request
      // token is invalidated so a reply that finishes later cannot be written
      // into the newly reset conversation.
      setState(() {
        final session = _sessions.single;
        _invalidateRequestForSession(session.id);
        session
          ..title = '新对话'
          ..messages.clear()
          ..messages.add(_createDefaultWelcomeMessage());
        _currentSessionId = session.id;
        _currentPlan = null;
      });
      return;
    }
    setState(() {
      _invalidateRequestForSession(sessionId);
      _sessions.removeWhere((s) => s.id == sessionId);
      if (_currentSessionId == sessionId) {
        _currentSessionId = _sessions.first.id;
      }
      _currentPlan = null;
    });
    _scrollToBottom();
  }

  void _invalidateRequestForSession(String sessionId) {
    if (_activeRequestSessionId != sessionId) return;
    _activeRequestToken = null;
    _activeRequestSessionId = null;
    _isLoading = false;
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

    final origin = _currentSession;
    final history = List<ChatMessage>.of(origin.messages);
    final requestToken = Object();
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: text,
      timestamp: DateTime.now(),
    );

    setState(() {
      if (origin.title == '新对话' || origin.title.startsWith('新会话')) {
        origin.title = text.length > 12 ? '${text.substring(0, 12)}...' : text;
      }
      origin.messages.add(userMsg);
      _isLoading = true;
      _activeRequestToken = requestToken;
      _activeRequestSessionId = origin.id;
    });
    _scrollToBottom();

    try {
      // Only capability limitations are handled locally; inventory answers must
      // go through the real service and its database snapshot.
      final reply = _unsupportedActionReply(text) ??
          await ref.read(aiAssistantServiceProvider).ask(text, history);
      if (mounted &&
          identical(_activeRequestToken, requestToken) &&
          _sessions.contains(origin)) {
        setState(() {
          origin.messages.add(ChatMessage(
            id: const Uuid().v4(),
            role: 'assistant',
            content: reply,
            timestamp: DateTime.now(),
          ));
        });
      }
    } catch (error) {
      if (mounted &&
          identical(_activeRequestToken, requestToken) &&
          _sessions.contains(origin)) {
        final message = error is TimeoutException
            ? '请求超时，请检查网络后重试。'
            : '请检查「我的」中的 AI 地址、模型、API Key 和网络后重试。';
        setState(() {
          origin.messages.add(ChatMessage(
            id: const Uuid().v4(),
            role: 'assistant',
            content: '本次请求失败，未执行任何库存或设备操作。$message',
            timestamp: DateTime.now(),
          ));
        });
      }
    } finally {
      if (mounted && identical(_activeRequestToken, requestToken)) {
        setState(() {
          _isLoading = false;
          _activeRequestToken = null;
          _activeRequestSessionId = null;
        });
        _scrollToBottom();
      }
    }
  }

  String? _unsupportedActionReply(String text) {
    if (text.contains('吃了') || text.contains('消耗') || text.contains('扣减')) {
      return '当前 AI 助手只支持查询，未扣减库存或写入记录。请在库存页选择商品并确认消耗数量。';
    }
    if (text.contains('洗衣服') || text.contains('洗涤') ||
        text.contains('开洗衣机') || text.contains('打开电视') ||
        text.contains('开电视') || text.contains('关闭电视') ||
        text.contains('关电视') || text.contains('观影模式') ||
        (text.contains('空调') && (text.contains('25') || text.contains('调到')))) {
      return '当前版本尚未接入 Home Assistant，无法执行设备控制或混合计划。未发送设备指令，也未扣减耗材。';
    }
    return null;
  }

  void _confirmPlan() {
    if (_currentPlan == null) return;
    setState(() {
      _currentPlan = _currentPlan!.copyWith(status: AiPlanStatus.cancelled);
      _messages.add(ChatMessage(
        id: const Uuid().v4(),
        role: 'assistant',
        content: '混合计划执行尚未支持。未发送设备指令，也未扣减耗材。',
        timestamp: DateTime.now(),
      ));
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
              color: Theme.of(context).colorScheme.surface,
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
                        '真实库存问答 · 只读，不执行库存或设备操作',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '新建会话',
                  icon: const Icon(Icons.add_comment_outlined, size: 20),
                  onPressed: _createNewSession,
                ),
                IconButton(
                  tooltip: '历史会话',
                  icon: const Icon(Icons.history_rounded, size: 20),
                  onPressed: () => _showHistorySessionsSheet(context, palette),
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
                        color: isUser ? palette.primary : theme.colorScheme.surface,
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
              color: Theme.of(context).colorScheme.surface,
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
                      hintText: '问问${palette.mascotName}，如：“还有多少洗衣液？”',
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
      backgroundColor: Theme.of(context).colorScheme.surface,
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

  void _showHistorySessionsSheet(BuildContext context, MomoPalette palette) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.65,
              ),
              padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(sheetCtx).padding.bottom + 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.history_rounded, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '对话历史与会话列表',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () {
                          Navigator.of(sheetCtx).pop();
                          _createNewSession();
                        },
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('新会话', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.separated(
                      itemCount: _sessions.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (ctx, index) {
                        final session = _sessions[index];
                        final isCurrent = session.id == _currentSessionId;
                        final userMessagesCount = session.messages.where((m) => m.role == 'user').length;
                        final timeStr = '${session.createdAt.month}月${session.createdAt.day}日 ${session.createdAt.hour.toString().padLeft(2, "0")}:${session.createdAt.minute.toString().padLeft(2, "0")}';

                        return Material(
                          color: isCurrent
                              ? palette.primary.withValues(alpha: 0.12)
                              : (isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.02)),
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () {
                              Navigator.of(sheetCtx).pop();
                              _switchSession(session.id);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: Row(
                                children: [
                                  Icon(
                                    isCurrent ? Icons.chat_bubble : Icons.chat_bubble_outline,
                                    size: 18,
                                    color: isCurrent ? palette.primary : Colors.grey,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          session.title,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                                            color: isCurrent ? palette.primary : null,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '$timeStr · $userMessagesCount 条对话',
                                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
                                    onPressed: () {
                                      _deleteSession(session.id);
                                      setSheetState(() {});
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

}
