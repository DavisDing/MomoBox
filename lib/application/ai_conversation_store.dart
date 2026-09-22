import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/repositories/settings_repository.dart';
import 'ai_assistant_service.dart';
import 'ai_fallback_executor.dart';

class AiSession {
  AiSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.messages,
  });
  final String id;
  String title;
  final DateTime createdAt;
  final List<ChatMessage> messages;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'messages':
        messages
            .map(
              (m) => {
                'id': m.id,
                'role': m.role,
                'content': m.content,
                'timestamp': m.timestamp.toIso8601String(),
              },
            )
            .toList(),
  };

  factory AiSession.fromJson(Map<String, dynamic> value) => AiSession(
    id: value['id'] as String,
    title: value['title'] as String,
    createdAt: DateTime.parse(value['createdAt'] as String),
    messages:
        (value['messages'] as List)
            .map(
              (m) => ChatMessage(
                id: m['id'] as String,
                role: m['role'] as String,
                content: m['content'] as String,
                timestamp: DateTime.parse(m['timestamp'] as String),
              ),
            )
            .toList(),
  );
}

/// App-scoped, not sheet-scoped: closing a route cannot lose an in-flight reply.
/// Every mutation is saved through one ordered queue; deletion invalidates replies.
class AiConversationStore extends ChangeNotifier {
  AiConversationStore(this._settings) {
    sessions.add(_newSession('新对话'));
    currentId = sessions.first.id;
  }
  static const storageKey = 'ai_conversations_v1';
  final SettingsRepository _settings;
  final List<AiSession> sessions = [];
  late String currentId;
  bool ready = false;
  String? storageError;
  Future<void> _writes = Future.value();
  Object? _request;
  String? _requestSession;
  bool _disposed = false;
  // Execution receipts are persisted with conversations so a proposal cannot
  // be clicked twice, including after reopening/restarting the app.
  final Map<String, String> actionReceipts = {};
  bool get isLoading => _request != null;
  AiSession get current => sessions.firstWhere(
    (s) => s.id == currentId,
    orElse: () => sessions.first,
  );

  static AiSession _newSession(String title) => AiSession(
    id: const Uuid().v4(),
    title: title,
    createdAt: DateTime.now(),
    messages: [
      ChatMessage(
        id: const Uuid().v4(),
        role: 'assistant',
        content:
            '你好呀！我是 MomoBox 的随身智能管家。\n'
            '我可以查询真实库存、效期和存放位置，提供采买建议。\n'
            '库存操作需在设置中授权，并逐次确认；设备控制尚未接入。',
        timestamp: DateTime.now(),
      ),
    ],
  );

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    try {
      final raw = await _settings.getValue(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        final saved =
            (data['sessions'] as List)
                .map(
                  (s) =>
                      AiSession.fromJson(Map<String, dynamic>.from(s as Map)),
                )
                .toList();
        if (saved.isNotEmpty) {
          sessions
            ..clear()
            ..addAll(saved);
          currentId = data['currentId'] as String;
        }
        actionReceipts.addAll(
          Map<String, String>.from(data['receipts'] as Map? ?? {}),
        );
        actionReceipts.removeWhere((_, value) => value == '等待确认');
        final pendingId = data['pendingSession'] as String?;
        final interrupted =
            sessions.where((s) => s.id == pendingId).firstOrNull;
        if (interrupted != null) {
          interrupted.messages.add(_reply('上次请求因应用退出而中断，未执行任何操作，请重新发送。'));
        }
      }
      ready = true;
      storageError = null;
      await save();
    } catch (_) {
      ready = false;
      storageError = '会话读取失败，原记录未覆盖。请重试。';
    }
    _changed();
  }

  Future<void> save() {
    final snapshot = jsonEncode({
      'sessions': sessions.map((s) => s.toJson()).toList(),
      'currentId': currentId,
      'pendingSession': _requestSession,
      'receipts': actionReceipts,
    });
    final operation = _writes.then(
      (_) => _settings.setValue(storageKey, snapshot),
    );
    _writes = operation.then<void>(
      (_) {
        storageError = null;
        _changed();
      },
      onError: (Object error, StackTrace stack) {
        storageError = '会话保存失败，请重试；退出应用可能丢失未保存内容。';
        _changed();
      },
    );
    return operation;
  }

  void _saveAndNotify() {
    // Error remains visible, and a later write can recover the queue.
    save().catchError((Object _) {});
    _changed();
  }

  void create() {
    if (!ready) return;
    final session = _newSession('新会话 ${sessions.length + 1}');
    sessions.insert(0, session);
    currentId = session.id;
    _saveAndNotify();
  }

  void select(String id) {
    if (!ready || !sessions.any((session) => session.id == id)) return;
    currentId = id;
    _saveAndNotify();
  }

  void delete(String id) {
    if (!ready || !sessions.any((session) => session.id == id)) return;
    if (_requestSession == id) {
      _request = null;
      _requestSession = null;
    }
    if (sessions.length == 1) {
      sessions[0] = _newSession('新对话');
    } else {
      sessions.removeWhere((s) => s.id == id);
    }
    if (!sessions.any((s) => s.id == currentId)) currentId = sessions.first.id;
    _saveAndNotify();
  }

  static ChatMessage _reply(String content) => ChatMessage(
    id: const Uuid().v4(),
    role: 'assistant',
    content: content,
    timestamp: DateTime.now(),
  );

  Future<void> send(
    String text,
    AiAssistantService service, {
    String? localReply,
  }) async {
    if (!ready || isLoading || text.trim().isEmpty) return;
    final origin = current;
    final history = List<ChatMessage>.of(origin.messages);
    final token = Object();
    _request = token;
    _requestSession = origin.id;
    if (origin.title == '新对话' || origin.title.startsWith('新会话')) {
      origin.title = text.length > 12 ? '${text.substring(0, 12)}...' : text;
    }
    origin.messages.add(
      ChatMessage(
        id: const Uuid().v4(),
        role: 'user',
        content: text,
        timestamp: DateTime.now(),
      ),
    );
    _changed();
    bool isCurrent() => identical(_request, token) && sessions.contains(origin);
    try {
      await save();
      if (!isCurrent()) return;
      final answer =
          localReply ??
          await service.ask(text, history, requestToken: const Uuid().v4());
      if (isCurrent()) origin.messages.add(_reply(answer));
    } catch (error) {
      if (isCurrent()) {
        origin.messages.add(
          _reply('本次请求失败，未执行任何库存或设备操作。${aiFailureMessage(error)}'),
        );
      }
    } finally {
      if (isCurrent()) {
        _request = null;
        _requestSession = null;
        _saveAndNotify();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
