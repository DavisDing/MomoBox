import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/application/chore_service.dart';
import 'package:momo_box/domain/models/chore_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/widgets/chores_sheet.dart';

void main() {
  const layouts = [
    (Size(390, 844), 1.0, Brightness.light, true),
    (Size(320, 640), 1.3, Brightness.dark, null),
    (Size(320, 640), 3.4, Brightness.light, false),
    (Size(844, 390), 3.4, Brightness.dark, null),
  ];

  for (final (size, scale, brightness, inlineFooter) in layouts) {
    testWidgets(
      'reminder card stays readable and actionable at $size / $scale',
      (tester) async {
        final now = DateTime.now();
        final chore = ChoreItem(
          id: 'filter',
          title: '清洁客厅靠近阳台的空气净化器滤网',
          category: '设备维护',
          repeatInterval: ChoreRepeatInterval.quarterly,
          nextDueDate: DateTime(now.year, now.month, now.day - 45),
          notes: '关闭电源后拆下滤网。清洁后等待完全干燥，再重新安装。',
        );
        final service = _RecordingChoreService(chore);
        addTearDown(service.close);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [choreServiceProvider.overrideWithValue(service)],
            child: MaterialApp(
              theme: buildMomoTheme(MomoPalette.defaultPalette, brightness),
              builder:
                  (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!,
                  ),
              home: Scaffold(
                body: Center(
                  child: Builder(
                    builder:
                        (context) => TextButton(
                          onPressed: () => ChoresSheet.show(context),
                          child: const Text('打开提醒'),
                        ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开提醒'));
        await tester.pumpAndSettle();

        final title = find.text(chore.title);
        final frequency = find.text('频率：每季度 (90天)');
        final notes = find.text(chore.notes!);
        final status = find.textContaining('已逾期');
        final complete = find.byWidgetPredicate(
          (widget) => widget is FilledButton,
        );
        final more = find.byTooltip('更多操作');
        expect(
          tester.getRect(title).bottom,
          lessThan(tester.getRect(frequency).top),
        );
        expect(
          tester.getRect(frequency).bottom,
          lessThan(tester.getRect(notes).top),
        );
        expect(
          tester.getRect(notes).bottom,
          lessThan(tester.getRect(status).top),
        );
        expect(
          tester.getRect(title).right,
          lessThan(tester.getRect(more).left),
        );
        expect(tester.getSize(more).shortestSide, greaterThanOrEqualTo(44));
        expect(tester.getSize(complete).height, greaterThanOrEqualTo(48));

        final stacked =
            tester.getRect(status).bottom < tester.getRect(complete).top;
        if (inlineFooter != null) {
          expect(stacked, !inlineFooter);
        }
        if (!stacked) {
          expect(
            tester.getCenter(status).dy,
            closeTo(tester.getCenter(complete).dy, 1),
          );
          expect(
            tester.getRect(status).right,
            lessThan(tester.getRect(complete).left),
          );
        }

        await Scrollable.ensureVisible(tester.element(more), alignment: 0.5);
        await tester.pumpAndSettle();
        if (scale == 1) {
          await tester.tap(title);
          await tester.pumpAndSettle();
          expect(find.text('编辑周期提醒'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
        }
        await tester.tap(more.hitTestable());
        await tester.pumpAndSettle();
        expect(find.text('编辑详情').hitTestable(), findsOneWidget);
        expect(find.text('删除提醒').hitTestable(), findsOneWidget);
        await tester.tap(find.text('暂停提醒'));
        await tester.pumpAndSettle();
        expect(service.item.isEnabled, isFalse);
        expect(find.text('已暂停'), findsOneWidget);

        await Scrollable.ensureVisible(
          tester.element(complete),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(complete.hitTestable());
        await tester.pumpAndSettle();
        expect(service.completedId, chore.id);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

class _RecordingChoreService extends Fake implements ChoreService {
  _RecordingChoreService(this.item);

  ChoreItem item;
  String? completedId;
  final _items = StreamController<List<ChoreItem>>.broadcast();

  @override
  Stream<List<ChoreItem>> watchChores() async* {
    yield [item];
    yield* _items.stream;
  }

  @override
  Future<void> toggleChore(String id, bool isEnabled) async {
    item = item.copyWith(isEnabled: isEnabled);
    _items.add([item]);
  }

  @override
  Future<ChoreItem?> completeChore(
    String id, {
    DateTime? completionDate,
  }) async {
    completedId = id;
    item = item.complete(completionDate: completionDate);
    _items.add([item]);
    return item;
  }

  Future<void> close() => _items.close();
}
