import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_assistant_service.dart';
import 'package:momo_box/application/ai_conversation_store.dart';
import '../support/memory_settings_repository.dart';

class ControlledAssistant implements AiAssistantService {
  final result = Completer<String>();
  @override
  String createRequestToken() => 'test';
  @override
  Future<String> ask(
    String question,
    List<ChatMessage> history, {
    String? requestToken,
  }) => result.future;
}

void main() {
  test('消息立即保存，关闭页面后回复仍持久化，重启恢复当前会话', () async {
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    final store = AiConversationStore(settings);
    addTearDown(store.dispose);
    await store.load();
    final service = ControlledAssistant();
    final request = store.send('库存查询', service);
    await store.save();
    final data = jsonDecode(settings.values[AiConversationStore.storageKey]!);
    expect(data['sessions'][0]['messages'].last['content'], '库存查询');
    final origin = store.current;
    store.create();
    service.result.complete('真实回复');
    await request;
    await store.save();
    expect(origin.messages.last.content, '真实回复');
    expect(store.current.messages.last.content, isNot('真实回复'));
    final restored = AiConversationStore(settings);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.currentId, store.currentId);
    expect(restored.sessions.last.messages.last.content, '真实回复');
  });

  for (final clearLast in [true, false]) {
    test('删除/清空会话阻止迟到回复并持久化：$clearLast', () async {
      final settings = MemorySettingsRepository();
      addTearDown(settings.close);
      final store = AiConversationStore(settings);
      addTearDown(store.dispose);
      await store.load();
      final service = ControlledAssistant();
      final origin = store.currentId;
      final request = store.send('待删除', service);
      await store.save();
      if (!clearLast) store.create();
      store.delete(origin);
      service.result.complete('迟到回复');
      await request;
      await store.save();
      expect(
        settings.values[AiConversationStore.storageKey],
        isNot(contains('迟到回复')),
      );
      expect(store.isLoading, isFalse);
    });
  }

  test('损坏存档不被空会话覆盖', () async {
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    settings.values[AiConversationStore.storageKey] = '{broken';
    final store = AiConversationStore(settings);
    addTearDown(store.dispose);
    await store.load();
    expect(store.ready, isFalse);
    expect(store.storageError, isNotNull);
    expect(settings.values[AiConversationStore.storageKey], '{broken');
    await expectLater(store.save(), throwsStateError);
    expect(settings.values[AiConversationStore.storageKey], '{broken');
  });

  test('显式重建先保留损坏原文，重启可读取新会话', () async {
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    settings.values[AiConversationStore.storageKey] = '{broken';
    final store = AiConversationStore(settings);
    addTearDown(store.dispose);
    await store.load();
    expect(store.canRecoverArchive, isTrue);
    await store.recoverCorruptArchive();
    expect(store.ready, isTrue);
    expect(store.canRecoverArchive, isFalse);
    expect(settings.values.entries.where((e) =>
        e.key.startsWith('ai_conversations_quarantine:')).single.value, '{broken');
    final restored = AiConversationStore(settings);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.ready, isTrue);
    expect(restored.sessions, hasLength(1));
  });

  test('原文保留失败或存档已被修改时禁止重建覆盖', () async {
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    settings.values[AiConversationStore.storageKey] = '{broken';
    final store = AiConversationStore(settings);
    addTearDown(store.dispose);
    await store.load();
    settings.failWrites = true;
    await expectLater(store.recoverCorruptArchive(), throwsStateError);
    expect(settings.values[AiConversationStore.storageKey], '{broken');
    expect(store.ready, isFalse);
    settings.failWrites = false;
    settings.values[AiConversationStore.storageKey] = '{changed';
    await expectLater(store.recoverCorruptArchive(), throwsStateError);
    expect(settings.values[AiConversationStore.storageKey], '{changed');
  });

  test('并发重建共用一次恢复，不覆盖恢复后新建的会话', () async {
    final settings = _DelayedQuarantineSettings();
    addTearDown(settings.close);
    settings.values[AiConversationStore.storageKey] = '{broken';
    final store = AiConversationStore(settings);
    addTearDown(store.dispose);
    await store.load();
    final first = store.recoverCorruptArchive();
    await settings.entered.future;
    final second = store.recoverCorruptArchive();
    expect(store.isRecoveringArchive, isTrue);
    settings.release.complete();
    await first;
    store.create();
    final newId = store.currentId;
    await second;
    await store.save();
    expect(store.currentId, newId);
    expect(store.sessions, hasLength(2));
    expect(settings.values.keys.where((k) =>
        k.startsWith('ai_conversations_quarantine:')), hasLength(1));
  });

  test('保存失败可重试，后续写队列仍可恢复', () async {
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    final store = AiConversationStore(settings);
    addTearDown(store.dispose);
    await store.load();
    settings.failWrites = true;
    await expectLater(store.save(), throwsStateError);
    expect(store.storageError, isNotNull);
    settings.failWrites = false;
    await store.save();
    expect(store.storageError, isNull);
  });
}

class _DelayedQuarantineSettings extends MemorySettingsRepository {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> setValue(String key, String value) async {
    if (key.startsWith('ai_conversations_quarantine:')) {
      entered.complete();
      await release.future;
    }
    await super.setValue(key, value);
  }
}
