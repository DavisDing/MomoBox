import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';

void main() {
  testWidgets('诊断导出先说明脱敏范围和原生崩溃边界', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: DiagnosticExportScreen()));
    expect(find.text('本地诊断导出'), findsOneWidget);
    expect(find.textContaining('不包含错误原文'), findsOneWidget);
    expect(find.textContaining('不涵盖原生崩溃、系统终止'), findsOneWidget);
    expect(find.text('导出脱敏诊断'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) => widget is FilledButton),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
