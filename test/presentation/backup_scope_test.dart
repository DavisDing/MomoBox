import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/backup/backup_format.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';

void main() {
  testWidgets('备份页面明确核心范围、身份隔离与个人数据提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: BackupSettingsScreen()),
    ));
    await tester.pump();
    expect(find.text('导出核心数据备份 (JSON)'), findsOneWidget);
    expect(find.text('导出全量数据备份 (JSON)'), findsNothing);
    expect(find.text(BackupFormat.scopeDescription), findsOneWidget);
    final instructions = find.textContaining(BackupFormat.restoreDescription);
    await tester.ensureVisible(instructions);
    await tester.pump();
    expect(instructions, findsOneWidget);
    expect(find.textContaining(BackupFormat.privacyDescription), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
