import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/models/nas_import_models.dart';
import 'package:momo_box/presentation/widgets/initial_import_history_dialog.dart';

Map<String, dynamic> _record(int cursor) => {'cursor': cursor, 'id': 'history-$cursor',
  'type': 'consume', 'quantity': -1, 'product_id': 'product',
  'occurred_at': '2026-10-22T00:00:00Z', 'source_time_zone': null};

void main() {
  Future<void> mount(WidgetTester tester, {
    required Future<NasImportHistoryPage> Function(int, int) load,
    bool Function()? current,
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: InitialImportHistoryDialog(
      familyId: 'family-a', loadPage: load, isSessionCurrent: current ?? () => true,
    ))));
    await tester.pump();
  }

  testWidgets('archive pages retain the first high-watermark', (tester) async {
    final reads = <(int, int)>[];
    await mount(tester, load: (after, until) async {
      reads.add((after, until));
      return NasImportHistoryPage(records: [_record(after == 0 ? 1 : 2)],
        nextCursor: after == 0 ? 1 : 2, until: 2, hasMore: after == 0);
    });
    expect(reads, [(0, 0)]);
    expect(find.textContaining('查看不会再次扣减库存'), findsOneWidget);
    expect(find.text('来源时区：未记录'), findsOneWidget);
    await tester.tap(find.text('下一页'));
    await tester.pump();
    expect(reads, [(0, 0), (1, 2)]);
    expect(find.text('第 2 页 · 截止游标 2'), findsOneWidget);
    expect(find.text('下一页'), findsNothing);
  });

  testWidgets('failed page retries the same cursor without skipping history', (tester) async {
    final reads = <(int, int)>[];
    await mount(tester, load: (after, until) async {
      reads.add((after, until));
      if (reads.length == 2) throw StateError('offline');
      return NasImportHistoryPage(records: [_record(after + 1)],
        nextCursor: after + 1, until: 2, hasMore: after == 0);
    });
    await tester.tap(find.text('下一页'));
    await tester.pump();
    expect(find.textContaining('offline'), findsOneWidget);
    await tester.tap(find.text('重试原页'));
    await tester.pump();
    expect(reads, [(0, 0), (1, 2), (1, 2)]);
    expect(find.text('第 2 页 · 截止游标 2'), findsOneWidget);
  });

  testWidgets('late archive response cannot display data after session change', (tester) async {
    var current = true;
    final response = Completer<NasImportHistoryPage>();
    await mount(tester, load: (_, _) => response.future, current: () => current);
    current = false;
    response.complete(NasImportHistoryPage(records: [_record(1)],
      nextCursor: 1, until: 1, hasMore: false));
    await tester.pump();
    expect(find.textContaining('会话已改变'), findsOneWidget);
    expect(find.textContaining('商品来源 ID'), findsNothing);
    expect(find.text('重试原页'), findsNothing);
  });

  testWidgets('a changed high-watermark is rejected instead of mixing pages', (tester) async {
    await mount(tester, load: (after, _) async => NasImportHistoryPage(
      records: [_record(after + 1)], nextCursor: after + 1,
      until: after == 0 ? 2 : 3, hasMore: true));
    await tester.tap(find.text('下一页'));
    await tester.pump();
    expect(find.textContaining('高水位改变'), findsOneWidget);
    expect(find.text('第 1 页 · 截止游标 2'), findsOneWidget);
  });
}
