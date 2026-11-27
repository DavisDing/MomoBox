import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:momo_box/application/ai_conversation_store.dart';
import 'package:momo_box/application/ai_draft_service.dart';
import 'package:momo_box/application/ai_inventory_action_service.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/application/media_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/domain/models/recognition_models.dart';
import 'package:momo_box/domain/recognition/ai_draft_parser.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/assistant_screen.dart';

import '../support/memory_settings_repository.dart';

void main() {
  testWidgets('发送相册小票，确认授权后解析并核对，最终确认才入库', (tester) async {
    final fixture = await _Fixture.pump(tester);
    await fixture.sendPicture(tester);
    expect(find.text('确认发送 OCR 文本？'), findsOneWidget);
    expect(fixture.media.uploads, 1);
    expect(fixture.ai.texts, isEmpty);
    expect(fixture.store.current.messages.last.content, '购物小票图片');

    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(fixture.ai.texts, ['商品包装文字']);
    expect(fixture.media.deletions, 1);
    expect(find.text('核对小票商品'), findsOneWidget);
    expect(find.text('鸡蛋'), findsWidgets);
    await fixture.expectStock(tester, isEmpty);
    await tester.tap(find.text('下一步'));
    await _flush(tester);
    expect(find.text('确认批量入库'), findsOneWidget);
    await fixture.expectStock(tester, isEmpty);
    await tester.tap(find.text('确认入库'));
    await _flush(tester);
    await fixture.expectStock(tester, equals([('鸡蛋', 2)]));
    expect(fixture.store.current.messages.last.content, '已批量入库 1 项。');

    final saved = AiConversationStore(fixture.settings);
    addTearDown(saved.dispose);
    await saved.load();
    expect(saved.current.messages.last.isReceipt, isTrue);
    expect(saved.current.messages.last.content, '已批量入库 1 项。');
    expect(
      fixture.settings.values[AiConversationStore.storageKey],
      isNot(contains('商品包装文字')),
    );
  });

  testWidgets('拍照后取消发送，不上传图片也不写聊天记录', (tester) async {
    final fixture = await _Fixture.pump(tester);
    await fixture.choosePicture(tester, camera: true);
    expect(fixture.sourceIndex, ImageSource.camera.index);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fixture.media.uploads, 0);
    expect(fixture.store.current.messages.where((m) => m.isReceipt), isEmpty);
  });

  testWidgets('拒绝发送 OCR 文字时清理临时小票且不调用模型', (tester) async {
    final fixture = await _Fixture.pump(tester);
    await fixture.sendPicture(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(fixture.ai.texts, isEmpty);
    expect(fixture.media.deletions, 1);
    expect(fixture.store.current.messages.last.content, '小票识别已取消。');
    await fixture.expectStock(tester, isEmpty);
  });

  testWidgets('小票无文字时在当前会话显示错误，可重新发送', (tester) async {
    final fixture = await _Fixture.pump(tester);
    fixture.media.ocrText = Future.value('  ');
    await fixture.sendPicture(tester);
    expect(fixture.store.current.messages.last.content, contains('未识别到文字'));
    expect(fixture.ai.texts, isEmpty);
    expect(fixture.media.deletions, 1);
    await tester.tap(find.byTooltip('发送小票图片'));
    await tester.pumpAndSettle();
    expect(find.text('从相册选择小票'), findsOneWidget);
  });

  testWidgets('切换会话后，延迟返回的小票 OCR 不弹窗也不进入新会话', (tester) async {
    final fixture = await _Fixture.pump(tester);
    final origin = fixture.store.current;
    final ocr = Completer<String>();
    fixture.media.ocrText = ocr.future;
    await fixture.choosePicture(tester);
    await tester.tap(find.text('发送图片'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在识别小票文字…'), findsOneWidget);
    fixture.store.create();
    await tester.pump();
    ocr.complete('商品包装文字');
    await tester.pumpAndSettle();
    expect(find.text('确认发送 OCR 文本？'), findsNothing);
    expect(fixture.ai.texts, isEmpty);
    expect(fixture.media.deletions, 1);
    expect(origin.messages.last.content, '小票识别已取消。');
    expect(fixture.store.current.messages.where((m) => m.isReceipt), isEmpty);
  });

  testWidgets('关闭 AI 操作建议时，仍可识别小票且不提议入库', (tester) async {
    final fixture = await _Fixture.pump(tester);
    await fixture.settings.setValue('ai_allow_inventory_writes', 'false');
    await fixture.sendPicture(tester);
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(find.text('核对小票商品'), findsNothing);
    expect(fixture.store.current.messages.last.content, contains('已关闭'));
    expect(fixture.ai.texts, hasLength(1));
    await fixture.expectStock(tester, isEmpty);
  });
}

Future<void> _flush(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
}

class _Fixture {
  _Fixture(this.settings, this.store, this.inventory);
  final MemorySettingsRepository settings;
  final AiConversationStore store;
  final InventoryService inventory;
  final media = _ReceiptMedia();
  final ai = _ReceiptAi();
  int? sourceIndex;

  static Future<_Fixture> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final settings = MemorySettingsRepository();
    final store = AiConversationStore(settings);
    await store.load();
    final fixture = _Fixture(
      settings,
      store,
      InventoryService(InventoryRepository(db)),
    );

    const channel = MethodChannel('plugins.flutter.io/image_picker');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickImage');
      fixture.sourceIndex = call.arguments['source'] as int;
      return '/fake/receipt.jpg';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    addTearDown(() => tester.runAsync(db.close));
    addTearDown(settings.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nasAppAccessProvider.overrideWithValue(NasAppAccess.connected),
          syncWorkspaceIdentityProvider.overrideWithValue(null),
          databaseProvider.overrideWithValue(db),
          settingsRepositoryProvider.overrideWithValue(settings),
          aiConversationStoreProvider.overrideWith((ref) => store),
          inventoryServiceProvider.overrideWithValue(fixture.inventory),
          aiInventoryActionServiceProvider.overrideWithValue(
            AiInventoryActionService(settings, fixture.inventory),
          ),
          mediaServiceProvider.overrideWithValue(fixture.media),
          aiDraftServiceProvider.overrideWithValue(fixture.ai),
        ],
        child: const MaterialApp(home: AssistantScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return fixture;
  }

  Future<void> choosePicture(WidgetTester tester, {bool camera = false}) async {
    await tester.tap(find.byTooltip('发送小票图片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(camera ? '拍摄购物小票' : '从相册选择小票'));
    await tester.pumpAndSettle();
    expect(find.text('发送图片'), findsOneWidget);
    expect(media.uploads, 0);
  }

  Future<void> sendPicture(WidgetTester tester) async {
    await choosePicture(tester);
    expect(sourceIndex, ImageSource.gallery.index);
    await tester.tap(find.text('发送图片'));
    // The progress indicator stays active behind the authorization dialog.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> expectStock(WidgetTester tester, Matcher matcher) async {
    await tester.runAsync(() async {
      final products = await inventory.loadInventory();
      expect(
        products.map((item) => (item.name, item.totalStock)).toList(),
        matcher,
      );
    });
  }
}

class _ReceiptMedia implements MediaService {
  Future<String>? ocrText;
  var uploads = 0;
  var deletions = 0;

  @override
  Future<MediaAsset> attachImage({
    required XFile source,
    required String entityType,
    required String entityId,
    required MediaAssetType type,
  }) async {
    ++uploads;
    return MediaAsset(
      id: 'test-receipt',
      entityType: entityType,
      entityId: entityId,
      type: type,
      localPath: source.path,
      mimeType: 'image/jpeg',
      sizeBytes: 12,
      sha256: 'test',
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<String> runOcr(MediaAsset asset) async => (await ocrText) ?? '商品包装文字';

  @override
  Future<void> delete(MediaAsset asset) async {
    ++deletions;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReceiptAi implements AiDraftService {
  final texts = <String>[];

  @override
  Future<List<ReceiptLine>> parseReceiptText(String text) async {
    texts.add(text);
    return [(name: '鸡蛋', quantity: 2, category: '食品生鲜')];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
