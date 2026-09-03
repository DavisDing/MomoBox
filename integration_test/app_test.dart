import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:momo_box/app/momo_box_app.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/presentation/controllers/providers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首次启动可在库存、提醒和采买页面之间导航', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: const MomoBoxApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('嬷嬷的小箱子'), findsOneWidget);
    expect(find.text('手动入库'), findsOneWidget);

    await tester.tap(find.text('提醒'));
    await tester.pumpAndSettle();
    expect(find.text('效期与库存提醒'), findsOneWidget);
    expect(find.text('当前无待处理提醒。'), findsOneWidget);

    await tester.tap(find.text('采买'));
    await tester.pumpAndSettle();
    expect(find.text('待采买清单'), findsOneWidget);
    expect(find.text('暂无待采买物品。'), findsOneWidget);

    await tester.tap(find.text('库存'));
    await tester.pumpAndSettle();
    expect(find.text('嬷嬷的小箱子'), findsOneWidget);
  });
}
