import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/models/recognition_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/widgets/intake_sheet.dart';

void main() {
  testWidgets('入库分类覆盖家庭常见物品，旧分类仍可编辑', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaAssetsProvider.overrideWith((ref, target) => Stream.value(<MediaAsset>[])),
      ],
      child: MaterialApp(home: Scaffold(body: const IntakeSheet(
        initialName: '旧商品', initialCategory: '原有自定义分类',
      ))),
    ));
    await tester.pumpAndSettle();
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>).first,
    );
    final categories = dropdown.items!.map((item) => item.value).toList();
    expect(categories, containsAll([
      '原有自定义分类', '药品保健', '其他物品', '粮油调味', '宠物用品',
      '家居清洁', '数码电器', '工具五金', '运动户外',
    ]));
    expect(categories.toSet().length, categories.length);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('OCR'), findsOneWidget);
    expect(find.text('AI解析'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final name in ['带图片的草稿', '']) {
    testWidgets('${name.isEmpty ? '纯图片' : '文字和图片'}草稿重开后沿用同一个媒体关联', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final observedIds = <String>[];
      final assetsByDraft = <String, List<MediaAsset>>{};

      Future<void> open(IntakeSheet sheet) async {
        await tester.pumpWidget(ProviderScope(
          key: UniqueKey(),
          overrides: [
            mediaAssetsProvider.overrideWith((ref, target) {
              observedIds.add(target.entityId);
              return Stream.value(assetsByDraft[target.entityId] ?? <MediaAsset>[]);
            }),
          ],
          child: MaterialApp(home: Scaffold(body: sheet)),
        ));
        await tester.pumpAndSettle();
      }

      // An explicit initial name isolates this test from earlier in-memory drafts.
      await open(IntakeSheet(initialName: name));
      final originalId = observedIds.single;
      // Represents already-saved media/OCR metadata; no camera or OCR engine is
      // faked as having run. Restoration must query this same entity identity.
      assetsByDraft[originalId] = [MediaAsset(
        id: 'photo', entityType: 'intake_draft', entityId: originalId,
        type: MediaAssetType.instructionImage, localPath: '/missing-test-image.png',
        mimeType: 'image/png', sizeBytes: 1, sha256: 'test-only',
        createdAt: DateTime(2026, 9, 15), ocrText: '已保存在草稿的 OCR 文本',
      )];
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await open(const IntakeSheet());
      expect(observedIds.last, originalId);
      final container = ProviderScope.containerOf(tester.element(find.byType(IntakeSheet)));
      final restored = container.read(mediaAssetsProvider((
        entityType: 'intake_draft', entityId: observedIds.last,
      ))).requireValue;
      expect(restored.single.id, 'photo');
      expect(restored.single.ocrText, '已保存在草稿的 OCR 文本');
      if (name.isNotEmpty) expect(find.text(name), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
