import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('主题中心', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...[MomoPalette.defaultPalette, MomoPalette.momoPalette, MomoPalette.doraemonPalette].map(
            (palette) => Card(
              child: RadioListTile<MomoSkin>(
                value: palette.skin,
                groupValue: active.skin,
                onChanged: (_) => ref.read(settingsRepositoryProvider).setValue('theme', palette.storedValue),
                title: Text(palette.label),
                subtitle: Text('${palette.mascot} ${palette.inventoryLabel} / ${palette.alertLabel} / ${palette.shoppingLabel}'),
                secondary: CircleAvatar(backgroundColor: palette.primary, child: Text(palette.mascot)),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text('数据与隐私', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('导出 JSON 备份'),
              subtitle: const Text('导出本机商品、批次、历史记录和采购清单。'),
              onTap: () => _exportBackup(context, ref),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('导入 JSON 备份'),
              subtitle: const Text('默认不覆盖已有记录，并显示导入结果。'),
              onTap: () => _importBackup(context, ref),
            ),
          ),
          const SizedBox(height: 14),
          Text('连接状态', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Card(
            child: ListTile(
              leading: Icon(Icons.phone_android_outlined),
              title: Text('当前为单机模式'),
              subtitle: Text('数据保存在本机 SQLite；NAS 同步将在后续阶段接入。'),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '注：主题名称和资源的正式发布授权仍需产品确认；当前未接入 AI、OCR、扫码或 NAS，不会伪装成已连接状态。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    try {
      final contents = await ref.read(backupRepositoryProvider).exportJson();
      final directory = await getTemporaryDirectory();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${directory.path}/momobox-backup-$timestamp.json');
      await file.writeAsString(contents);
      await Share.shareXFiles([XFile(file.path)], text: 'MomoBox 本地数据备份');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('备份文件已生成。')));
      }
    } catch (error) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败：$error')));
    }
  }

  Future<void> _importBackup(BuildContext context, WidgetRef ref) async {
    try {
      final selected = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      final file = selected?.files.singleOrNull;
      if (file == null) return;
      final content = file.bytes != null
          ? String.fromCharCodes(file.bytes!)
          : await File(file.path!).readAsString();
      final report = await ref.read(backupRepositoryProvider).importJson(content);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入完成：新增 ${report.imported} 条，跳过 ${report.skipped} 条。')),
        );
      }
    } catch (error) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入失败：$error')));
    }
  }
}
