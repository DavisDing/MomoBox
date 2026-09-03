import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/momo_theme.dart';
import '../../application/ai_draft_service.dart';
import '../../application/barcode_lookup_service.dart';
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
                onChanged: (_) => ref.read(settingsServiceProvider).setValue('theme', palette.storedValue),
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
          Text('识别与 AI（可选）', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.qr_code_2_outlined),
              title: const Text('外部条码 API'),
              subtitle: const Text('默认关闭；填写地址后，扫描结果会缓存 30 天。地址可使用 {barcode} 占位符。'),
              onTap: () => _configureBarcodeApi(context, ref),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('AI 解析配置'),
              subtitle: const Text('兼容 OpenAI Chat Completions 的自有服务；API Key 使用系统安全存储。'),
              onTap: () => _configureAi(context, ref),
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
          Card(
            child: ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('重新请求通知权限'),
              subtitle: const Text('用于临期、过期和低库存提醒。'),
              onTap: () => _requestNotificationPermission(context, ref),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('清理媒体缓存'),
              subtitle: const Text('删除孤儿图片、丢失图片记录和超过 1 天未确认的入库草稿图片。'),
              onTap: () => _cleanupMedia(context, ref),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '注：当前主题仅供本人本地使用和私有设备验证；若未来公开发布、上架或分发，需重新完成资源授权/合规审查。AI、OCR 和扫码均为可选增强能力；未配置时单机库存仍可离线使用，NAS 尚未接入。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _configureBarcodeApi(BuildContext context, WidgetRef ref) async {
    final endpoint = TextEditingController(text: await ref.read(settingsServiceProvider).getValue(BarcodeLookupService.endpointKey) ?? '');
    var enabled = (await ref.read(settingsServiceProvider).getValue(BarcodeLookupService.enabledKey)) == 'true';
    if (!context.mounted) { endpoint.dispose(); return; }
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('外部条码 API'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('启用外部查询'), value: enabled, onChanged: (value) => setState(() => enabled = value)),
              TextField(controller: endpoint, decoration: const InputDecoration(labelText: '请求地址', hintText: 'https://example.com/barcode/{barcode}'), keyboardType: TextInputType.url),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(onPressed: () async { await ref.read(settingsServiceProvider).setValue(BarcodeLookupService.enabledKey, '$enabled'); await ref.read(settingsServiceProvider).setValue(BarcodeLookupService.endpointKey, endpoint.text.trim()); if (context.mounted) Navigator.pop(context); }, child: const Text('保存')),
          ],
        ),
      ),
    );
    endpoint.dispose();
  }

  Future<void> _configureAi(BuildContext context, WidgetRef ref) async {
    final settings = ref.read(settingsServiceProvider);
    final endpoint = TextEditingController(text: await settings.getValue(AiDraftService.endpointKey) ?? '');
    final model = TextEditingController(text: await settings.getValue(AiDraftService.modelKey) ?? '');
    final key = TextEditingController();
    if (!context.mounted) { endpoint.dispose(); model.dispose(); key.dispose(); return; }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('AI 解析配置'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('AI 只生成可编辑草稿；你必须确认后才会应用到入库表单。默认不上传原图。'),
          const SizedBox(height: 10),
          TextField(controller: endpoint, decoration: const InputDecoration(labelText: '服务地址', hintText: 'https://example.com/v1'), keyboardType: TextInputType.url),
          const SizedBox(height: 8),
          TextField(controller: model, decoration: const InputDecoration(labelText: '模型名称')),
          const SizedBox(height: 8),
          TextField(controller: key, decoration: const InputDecoration(labelText: 'API Key（留空表示不修改）'), obscureText: true),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () async { await settings.setValue(AiDraftService.endpointKey, endpoint.text.trim()); await settings.setValue(AiDraftService.modelKey, model.text.trim()); if (key.text.trim().isNotEmpty) await ref.read(secureSettingsServiceProvider).writeAiApiKey(key.text); if (context.mounted) Navigator.pop(context); }, child: const Text('保存')),
        ],
      ),
    );
    endpoint.dispose(); model.dispose(); key.dispose();
  }

  Future<void> _cleanupMedia(BuildContext context, WidgetRef ref) async {
    try {
      final report = await ref.read(mediaServiceProvider).reconcile();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('媒体缓存清理完成：删除文件 ${report.deletedFiles} 个，清理记录 ${report.deletedMetadata} 条。'),
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('清理媒体缓存失败：$error')));
      }
    }
  }

  Future<void> _requestNotificationPermission(BuildContext context, WidgetRef ref) async {
    try {
      final granted = await ref.read(localNotificationServiceProvider).requestPermission();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            granted ? '通知权限请求已完成。' : '通知服务未初始化或权限未开启，请检查系统设置。',
          ),
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('请求通知权限失败：$error')));
      }
    }
  }

  Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    try {
      final contents = await ref.read(backupServiceProvider).exportJson();
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
      final report = await ref.read(backupServiceProvider).importJson(content);
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
