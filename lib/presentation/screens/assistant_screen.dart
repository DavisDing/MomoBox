import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/momo_theme.dart';
import '../../app/momo_typography.dart';
import '../../application/ai_assistant_service.dart';
import '../../application/ai_conversation_store.dart';
import '../../application/ai_inventory_action_service.dart';
import '../controllers/providers.dart';
import '../widgets/intake_sheet.dart';
import '../widgets/momo_floating_dock.dart';
import '../widgets/momo_mobile_layout.dart';
import 'alerts_screen.dart';
import 'home_assistant_settings_screen.dart';
import 'inventory_screen.dart';
import 'nas_settings_screen.dart';
import 'settings_screen.dart';
import 'shopping_screen.dart';
import 'statistics_screen.dart';
import 'sync_settings_screen.dart';

class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  AiConversationStore get _store => ref.read(aiConversationStoreProvider);
  List<AiSession> get _sessions => _store.sessions;
  String get _currentSessionId => _store.currentId;
  bool get _isLoading => !_store.ready || _store.isLoading;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  bool _checkingConsent = false;

  AiSession get _currentSession {
    return _sessions.firstWhere(
      (s) => s.id == _currentSessionId,
      orElse: () => _sessions.first,
    );
  }

  List<ChatMessage> get _messages => _currentSession.messages;

  void _createNewSession() {
    _store.create();
    _scrollToBottom();
  }

  Future<void> _recoverConversationArchive() async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('保留原存档并重建会话？'),
      content: const Text('损坏的原始存档会先另存到本机，再创建空白会话；不会删除库存或执行任何 AI 操作。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保留并重建')),
      ],
    ));
    if (confirmed != true || !mounted) return;
    try {
      await _store.recoverCorruptArchive();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('重建失败，原存档已保留，请重试。')),
        );
      }
    }
  }

  void _switchSession(String sessionId) {
    _store.select(sessionId);
    _scrollToBottom();
  }

  void _deleteSession(String sessionId) {
    _store.delete(sessionId);
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        if (MediaQuery.disableAnimationsOf(context) || MediaQuery.accessibleNavigationOf(context)) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          return;
        }
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
    if (text.isEmpty || _isLoading || _checkingConsent) return;
    _checkingConsent = true;
    try {
      final settings = ref.read(settingsRepositoryProvider);
      final backendMode = (await settings.getValue('nas_server_url'))?.trim().isNotEmpty == true;
      final consentKey = backendMode ? 'ai_assistant_context_consent_backend_v1' : 'ai_assistant_context_consent_v2';
      if (await settings.getValue(consentKey) != 'true') {
        if (!mounted) return;
        final consent = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
          title: const Text('发送给你配置的 AI 服务？'), scrollable: true,
          content: const Text('提问会携带近期对话，以及当前库存/批次、采购、待处理提醒、已保存家务和已授权设备状态。'
            '连接后端时先发送到 NAS，由 NAS 使用其配置的主服务和失败回退服务；单机时使用手机配置的 AI 服务。不向模型发送图片、密钥或账号凭据。'
            '\n同意发送不代表同意操作，任何变更仍须逐次确认。此选择会保存在本机。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('同意并发送')),
          ],
        ));
        if (consent != true || !mounted) return;
        await settings.setValue(consentKey, 'true');
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('发送授权保存失败，请重试。')));
      return;
    } finally {
      _checkingConsent = false;
    }
    if (!mounted || _isLoading) return;
    _textController.clear();
    final store = _store;
    final service = ref.read(aiAssistantServiceProvider);
    final operation = store.send(text, service, localReply: null);
    _scrollToBottom();
    await operation;
    if (mounted) _scrollToBottom();
  }

  Future<void> _confirmInventoryAction(ChatMessage message) async {
    final action = AiInventoryAction.parse(message.content);
    if (action == null) return;
    final store = _store;
    final origin = _currentSession;
    final service = ref.read(aiInventoryActionServiceProvider);
    // Lock before opening the confirmation route to prevent duplicate dialogs.
    if (store.actionReceipts.containsKey(message.id)) return;
    setState(() => store.actionReceipts[message.id] = '等待确认');
    bool executing = false;
    try {
      final description = await service.describe(action);
      if (!mounted) return;
      if (action.kind == 'intake') {
        await showModalBottomSheet<void>(
          context: context, isScrollControlled: true, useSafeArea: true,
          builder: (_) => IntakeSheet(
            initialDraft: action.intakeDraft,
            initialCategoryFromAi: true,
            beforeIntake: () async {
              if (!store.sessions.contains(origin)) throw StateError('原会话已删除，请重新提问。');
              if (executing) throw StateError('本次入库已提交，请先核实库存。');
              // This guard must precede any await: closing the sheet while a
              // permission/save future is pending must not unlock the proposal.
              executing = true;
              try {
                await service.checkPermission();
                store.actionReceipts[message.id] = '执行中／中断后请核实结果，勿重复提交';
                await store.save();
                await service.checkPermission();
                if (!store.sessions.contains(origin)) {
                  throw StateError('原会话已删除，请重新提问。');
                }
              } catch (_) {
                // Intake has not reached the inventory service yet. A failed
                // preflight must remain retryable, including after dismissal.
                executing = false;
                store.actionReceipts.remove(message.id);
                try { await store.save(); } catch (_) { /* storage warning */ }
                rethrow;
              }
            },
            onIntakeSuccess: (productId) async {
              store.actionReceipts[message.id] = '已执行';
              if (store.sessions.contains(origin)) {
                origin.messages.add(ChatMessage(id: const Uuid().v4(), role: 'assistant',
                  content: '已按你确认的草稿完成入库。', timestamp: DateTime.now()));
              }
              await store.save();
            },
          ),
        );
        if (executing && store.actionReceipts[message.id] != '已执行') {
          store.actionReceipts[message.id] = '提交结果待核实，请先检查库存';
        }
        return;
      }
      final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('确认操作'),
        scrollable: true,
        content: Text(description),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认执行')),
        ],
      ));
      if (confirmed != true || !store.sessions.contains(origin)) return;
      store.actionReceipts[message.id] = '执行中／中断后请核实结果，勿重复提交';
      await store.save();
      executing = true;
      if (action.kind == 'open_page') {
        await service.checkPermission();
        if (!mounted) return;
        await Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => _actionPage(action.string('page')!),
        ));
      } else {
        await service.execute(action, confirmedDescription: description);
      }
      store.actionReceipts[message.id] = action.kind == 'open_page' ? '已打开页面' : '已执行';
      if (store.sessions.contains(origin)) {
        origin.messages.add(ChatMessage(id: const Uuid().v4(), role: 'assistant',
          content: action.kind == 'open_page' ? '已打开${AiInventoryAction.pages[action.string('page')]}页面；具体操作以页面结果为准。' : '已完成：$description', timestamp: DateTime.now()));
      }
      await store.save();
    } catch (error) {
      if (executing && !{'已执行', '已打开页面'}.contains(store.actionReceipts[message.id])) {
        store.actionReceipts[message.id] = '执行结果未确认，请核实后重新提问';
      }
      if (mounted) {
        final detail = error is StateError ? error.message : '操作或记录保存失败，请先核实实际结果。';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(detail)));
      }
    } finally {
      if (!executing) store.actionReceipts.remove(message.id);
      try { await store.save(); } catch (_) { /* visible storage warning */ }
      if (mounted) setState(() {});
    }
  }

  Widget _actionPage(String page) => switch (page) {
    'backup' => const BackupSettingsScreen(),
    'storage' => const StorageManagementScreen(),
    'ai_settings' => const AiSettingsScreen(),
    'nas_settings' => const NasSettingsScreen(),
    'ha_settings' => const HomeAssistantSettingsScreen(),
    'sync_settings' => const SyncSettingsScreen(),
    'notifications' => const NotificationSettingsScreen(),
    'privacy' => const PrivacySettingsScreen(),
    'statistics' => const StatisticsScreen(),
    'inventory' => const InventoryScreen(),
    'shopping' => const ShoppingScreen(),
    'alerts' => const AlertsScreen(),
    _ => const SettingsScreen(),
  };

  @override
  Widget build(BuildContext context) {
    ref.watch(aiConversationStoreProvider);
    ref.watch(aiInventoryPermissionProvider);
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final theme = Theme.of(context);

    final welcome = _messages.length == 1 && _messages.first.content.startsWith('你好呀！');
    final content = SafeArea(
          bottom: false,
          child: Column(
            children: [
              // Session tools share one menu when text or screen size needs space.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: LayoutBuilder(builder: (context, constraints) {
                  final compact = MomoMobileLayout.stack(context, constraints.maxWidth, minimum: 390);
                  return Row(children: [
                    Expanded(child: Text(compact ? '助手' : 'AI 助手', style: theme.textTheme.titleMedium)),
                    if (compact)
                      PopupMenuButton<String>(
                        tooltip: '会话选项',
                        icon: const Icon(Icons.more_horiz_rounded),
                        onSelected: (value) {
                          if (value == 'new') _createNewSession();
                          if (value == 'history') _showHistorySessionsSheet(context);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'new', child: Text('新建会话')),
                          PopupMenuItem(value: 'history', child: Text('历史会话')),
                        ],
                      )
                    else ...[
                      IconButton(tooltip: '新建会话', icon: const Icon(Icons.add_comment_outlined), onPressed: _createNewSession),
                      IconButton(tooltip: '历史会话', icon: const Icon(Icons.history_rounded),
                        onPressed: () => _showHistorySessionsSheet(context)),
                    ],
                    if (compact)
                      IconButton(tooltip:'AI 服务',icon:const Icon(Icons.tune_rounded),
                        onPressed:()=>Navigator.of(context,rootNavigator:true).push(
                          MaterialPageRoute<void>(builder:(_)=>const AiSettingsScreen())))
                    else TextButton.icon(
                      icon:const Icon(Icons.tune_rounded,size:16),label:const Text('AI 服务'),
                      onPressed:()=>Navigator.of(context,rootNavigator:true).push(
                        MaterialPageRoute<void>(builder:(_)=>const AiSettingsScreen())),
                    ),
                  ]);
                }),
              ),

              if (_store.storageError != null)
                ListTile(
                  title: Text(_store.storageError!, style: const TextStyle(color: Colors.red)),
                  trailing: Wrap(children: [TextButton(onPressed: () async {
                    if (_store.ready) {
                      try { await _store.save(); } catch (_) { /* visible in store */ }
                    } else {
                      await _store.load();
                    }
                  }, child: const Text('重试')),
                    if (_store.canRecoverArchive)
                      TextButton(onPressed: _recoverConversationArchive,
                        child: const Text('重建会话')),
                  ]),
                ),
              if (_store.isRecoveringArchive) const LinearProgressIndicator(),
              // Keep the composer and conversation usable above a phone keyboard.
              if (!welcome && MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom > 480 &&
                  MediaQuery.textScalerOf(context).scale(MomoTextSize.body) <= MomoTextSize.body * 1.5)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    _buildQuickChip('📦 入库两盒牛奶'),
                    const SizedBox(width: 8),
                    _buildQuickChip('📺 打开电视'),
                    const SizedBox(width: 8),
                    _buildQuickChip('❄️ 空调调到 25 度'),
                    const SizedBox(width: 8),
                    _buildQuickChip('🧴 还有多少洗衣液？'),
                    const SizedBox(width: 8),
                    _buildQuickChip('🛒 采购三包纸巾'),
                  ],
                ),
              ),

              // 对话列表
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    if (welcome && index == 0) return _buildWelcome(theme);
                    final msg = _messages[index];
                    final isUser = msg.role == 'user';
                    return Align(
                      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isUser ? theme.colorScheme.surfaceContainerHighest : theme.colorScheme.surface,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: Radius.circular(isUser ? 16 : 4),
                            bottomRight: Radius.circular(isUser ? 4 : 16),
                          ),
                          border: isUser
                              ? null
                              : Border.all(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                                ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [SelectableText(
                          isUser ? msg.content : AiInventoryAction.displayText(msg.content),
                          style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontSize: MomoTextSize.title,
                            height: 1.5,
                          ),
                        ),
                        if (!isUser && AiInventoryAction.parse(msg.content) != null)
                          TextButton(
                            onPressed: _store.actionReceipts.containsKey(msg.id) ||
                                !(ref.watch(aiInventoryPermissionProvider).valueOrNull ?? false)
                                ? null : () => _confirmInventoryAction(msg),
                            child: Text(_store.actionReceipts[msg.id] ?? '查看并确认操作'),
                          ),
                        ],),
                      ),
                    );
                  },
                ),
              ),

              if (_isLoading && _store.storageError == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
                      ),
                      const SizedBox(width: 8),
                      Flexible(child: Text('${palette.mascotName} 正在思考…', style: theme.textTheme.bodySmall)),
                    ],
                  ),
                ),

              // 底部输入栏
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        decoration: InputDecoration(
                          hintText: '问问家里的事…',
                          hintStyle: const TextStyle(fontSize: MomoTextSize.body),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          isDense: true,
                        ),
                        minLines: 1,
                        maxLines: MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom > 480 ? 3 : 1,
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: '发送消息',
                      icon: const Icon(Icons.send_rounded, size: 20),
                      onPressed: _isLoading ? null : () => _sendMessage(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
    return Scaffold(body: Padding(
      padding: EdgeInsets.only(bottom: MomoDockInsets.bottomOf(context)),
      child: content,
    ));
  }

  Widget _buildWelcome(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 20),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(24)),
        child: Icon(Icons.auto_awesome_outlined, size: 32, color: theme.colorScheme.primary)),
      const SizedBox(height: 28),
      Text('生活的小事，\n一起理清楚。', style: theme.textTheme.headlineLarge),
      const SizedBox(height: 12),
      Text('找物品、记采买、照顾你的家。\n想起什么，就问一句。',
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 24),
      for (final entry in [
        (Icons.schedule_outlined, '哪些物品需要先用？'),
        (Icons.shopping_bag_outlined, '帮我整理下次采买清单'),
        (Icons.chair_outlined, '家里有哪些已授权设备？'),
      ]) ListTile(contentPadding: EdgeInsets.zero,
        leading: Icon(entry.$1, color: theme.colorScheme.primary),
        title: Text(entry.$2, style: theme.textTheme.bodyMedium),
        trailing: const Icon(Icons.north_east_rounded, size: 16),
        onTap: _isLoading ? null : () => _sendMessage(entry.$2)),
    ]),
  );

  Widget _buildQuickChip(String label) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: MomoTextSize.caption)),
      onPressed: _isLoading ? null : () => _sendMessage(label.replaceAll(RegExp(r'^[^\s]+\s+'), '')),
    );
  }

  void _showHistorySessionsSheet(BuildContext context) {
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
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
                      Expanded(
                        child: Text(
                          '对话历史与会话列表',
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          Navigator.of(sheetCtx).pop();
                          _createNewSession();
                        },
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('新会话', style: TextStyle(fontSize: MomoTextSize.caption)),
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
                              ? theme.colorScheme.primary.withValues(alpha: 0.12)
                              : theme.colorScheme.surface,
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
                                    color: isCurrent ? theme.colorScheme.primary : Colors.grey,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          session.title,
                                          style: TextStyle(
                                            fontSize: MomoTextSize.body,
                                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                                            color: isCurrent ? theme.colorScheme.primary : null,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '$timeStr · $userMessagesCount 条对话',
                                          style: const TextStyle(fontSize: MomoTextSize.caption, color: Colors.grey),
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
