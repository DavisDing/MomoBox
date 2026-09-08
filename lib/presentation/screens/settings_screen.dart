import 'dart:convert';
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
          _SettingsGroupTitle('外观与显示'),
          Card(
            child: ListTile(
              leading: CircleAvatar(backgroundColor: active.primary, child: Text(active.mascot)),
              title: const Text('主题中心'),
              subtitle: Text('当前：${active.label}（${active.mascot}）'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ThemeSettingsScreen()),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _SettingsGroupTitle('识别与外部服务'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.qr_code_2_outlined),
              title: const Text('外部条码 API'),
              subtitle: const Text('支持多配置切换与设为默认；内置免费公共条码库。'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const BarcodeSettingsScreen()),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('AI 解析配置'),
              subtitle: const Text('支持多套兼容 OpenAI 服务配置，模型切换与设为默认。'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AiSettingsScreen()),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _SettingsGroupTitle('数据与存储'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text('备份与恢复'),
              subtitle: const Text('导出和导入 JSON 备份文件。'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const BackupSettingsScreen()),
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('清理媒体缓存'),
              subtitle: const Text('删除孤儿图片、丢失图片记录和过期的入库草稿图片。'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _cleanupMedia(context, ref),
            ),
          ),
          const SizedBox(height: 14),
          _SettingsGroupTitle('系统与状态'),
          const Card(
            child: ListTile(
              leading: Icon(Icons.phone_android_outlined),
              title: Text('单机模式运行中'),
              subtitle: Text('数据安全保存在本机 SQLite，无需网络也能完整使用。'),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.notifications_active_outlined),
              title: const Text('重新请求通知权限'),
              subtitle: const Text('用于到期提醒和低库存提醒。'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _requestNotificationPermission(context, ref),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '注：当前主题仅供本人本地使用和私有设备验证；若未来公开发布、上架或分发，需重新完成资源授权/合规审查。AI、OCR 和扫码均为可选增强能力；未配置时单机库存仍可完全离线使用。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
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
}

class _SettingsGroupTitle extends StatelessWidget {
  const _SettingsGroupTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

/// ---------------- 二级页面 1：主题中心 ----------------
class ThemeSettingsScreen extends ConsumerWidget {
  const ThemeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    return Scaffold(
      appBar: AppBar(title: const Text('主题中心')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          RadioGroup<MomoSkin>(
            groupValue: active.skin,
            onChanged: (skin) {
              if (skin == null) return;
              final palette = [
                MomoPalette.defaultPalette,
                MomoPalette.momoPalette,
                MomoPalette.doraemonPalette,
              ].firstWhere((palette) => palette.skin == skin);
              ref.read(settingsServiceProvider).setValue('theme', palette.storedValue);
            },
            child: Column(
              children: [
                ...[MomoPalette.defaultPalette, MomoPalette.momoPalette, MomoPalette.doraemonPalette].map(
                  (palette) => Card(
                    child: RadioListTile<MomoSkin>(
                      value: palette.skin,
                      title: Text(palette.label),
                      subtitle: Text('${palette.mascot} ${palette.inventoryLabel} / ${palette.alertLabel} / ${palette.shoppingLabel}'),
                      secondary: CircleAvatar(backgroundColor: palette.primary, child: Text(palette.mascot)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '切换主题将同时更新顶部与底部导航配色、专属吉祥物和导航文案。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// ---------------- 二级页面 2：外部条码 API ----------------
class BarcodeSettingsScreen extends ConsumerStatefulWidget {
  const BarcodeSettingsScreen({super.key});

  @override
  ConsumerState<BarcodeSettingsScreen> createState() => _BarcodeSettingsScreenState();
}

class _BarcodeSettingsScreenState extends ConsumerState<BarcodeSettingsScreen> {
  bool _enabled = false;
  String _currentEndpoint = '';
  List<Map<String, String>> _profiles = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final settings = ref.read(settingsServiceProvider);
    final enabledStr = await settings.getValue(BarcodeLookupService.enabledKey);
    final endpoint = await settings.getValue(BarcodeLookupService.endpointKey) ?? '';
    final profilesRaw = await settings.getValue(BarcodeLookupService.profilesKey);
    List<Map<String, String>> loadedProfiles = [];
    if (profilesRaw != null && profilesRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(profilesRaw) as List;
        loadedProfiles = decoded.map((e) => Map<String, String>.from(e as Map)).toList();
      } catch (_) {}
    }
    if (loadedProfiles.isEmpty) {
      loadedProfiles = [
        {
          'name': '官方免费公开库 (Open Food Facts)',
          'endpoint': BarcodeLookupService.defaultFreeEndpoint,
        },
      ];
    }
    setState(() {
      _enabled = enabledStr == 'true';
      _currentEndpoint = endpoint.isEmpty ? BarcodeLookupService.defaultFreeEndpoint : endpoint;
      _profiles = loadedProfiles;
      _loading = false;
    });
  }

  Future<void> _saveData() async {
    final settings = ref.read(settingsServiceProvider);
    await settings.setValue(BarcodeLookupService.enabledKey, '$_enabled');
    await settings.setValue(BarcodeLookupService.endpointKey, _currentEndpoint);
    await settings.setValue(BarcodeLookupService.profilesKey, jsonEncode(_profiles));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('条码 API 配置已保存')));
    }
  }

  void _addOrEditProfile([int? index]) {
    final isEdit = index != null;
    final item = isEdit ? _profiles[index] : null;
    final nameController = TextEditingController(text: item?['name'] ?? '');
    final endpointController = TextEditingController(text: item?['endpoint'] ?? '');

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isEdit ? '编辑条码服务' : '新增条码服务'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '服务名称', hintText: '如：我的自建条码库')),
            const SizedBox(height: 10),
            TextField(controller: endpointController, decoration: const InputDecoration(labelText: 'API 地址', hintText: 'https://example.com/api/{barcode}'), keyboardType: TextInputType.url),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              final url = endpointController.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              setState(() {
                if (isEdit) {
                  _profiles[index] = {'name': name, 'endpoint': url};
                  if (_currentEndpoint == item?['endpoint']) {
                    _currentEndpoint = url;
                  }
                } else {
                  _profiles.add({'name': name, 'endpoint': url});
                }
              });
              _saveData();
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('外部条码 API')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('外部条码 API'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加服务配置',
            onPressed: () => _addOrEditProfile(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: SwitchListTile(
              title: const Text('启用外部条码查询'),
              subtitle: const Text('扫码后自动查询商品名称、品牌与规格信息并缓存在本地 30 天。未填写时默认使用内置免费公共库。'),
              value: _enabled,
              onChanged: (value) {
                setState(() => _enabled = value);
                _saveData();
              },
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('配置列表（点击选择默认使用）', style: Theme.of(context).textTheme.titleSmall),
          ),
          ..._profiles.asMap().entries.map((entry) {
            final idx = entry.key;
            final profile = entry.value;
            final isDefault = _currentEndpoint == profile['endpoint'];
            return Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: isDefault
                    ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
                    : BorderSide.none,
              ),
              child: ListTile(
                title: Text(profile['name'] ?? ''),
                subtitle: Text(profile['endpoint'] ?? ''),
                leading: Icon(
                  isDefault ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: isDefault ? Theme.of(context).colorScheme.primary : null,
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (val) {
                    if (val == 'edit') {
                      _addOrEditProfile(idx);
                    } else if (val == 'delete') {
                      setState(() {
                        _profiles.removeAt(idx);
                        if (isDefault && _profiles.isNotEmpty) {
                          _currentEndpoint = _profiles.first['endpoint']!;
                        }
                      });
                      _saveData();
                    }
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(value: 'edit', child: Text('编辑')),
                    if (_profiles.length > 1) const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
                onTap: () {
                  setState(() => _currentEndpoint = profile['endpoint'] ?? '');
                  _saveData();
                },
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// ---------------- 二级页面 3：AI 解析配置 ----------------
class AiSettingsScreen extends ConsumerStatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  ConsumerState<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends ConsumerState<AiSettingsScreen> {
  String _currentEndpoint = '';
  String _currentModel = '';
  List<Map<String, String>> _profiles = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final settings = ref.read(settingsServiceProvider);
    final endpoint = await settings.getValue(AiDraftService.endpointKey) ?? '';
    final model = await settings.getValue(AiDraftService.modelKey) ?? '';
    final profilesRaw = await settings.getValue(AiDraftService.profilesKey);
    List<Map<String, String>> loadedProfiles = [];
    if (profilesRaw != null && profilesRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(profilesRaw) as List;
        loadedProfiles = decoded.map((e) => Map<String, String>.from(e as Map)).toList();
      } catch (_) {}
    }
    if (loadedProfiles.isEmpty && endpoint.isNotEmpty) {
      loadedProfiles = [
        {'name': '默认模型', 'endpoint': endpoint, 'model': model},
      ];
    }
    setState(() {
      _currentEndpoint = endpoint;
      _currentModel = model;
      _profiles = loadedProfiles;
      _loading = false;
    });
  }

  Future<void> _saveData() async {
    final settings = ref.read(settingsServiceProvider);
    await settings.setValue(AiDraftService.endpointKey, _currentEndpoint);
    await settings.setValue(AiDraftService.modelKey, _currentModel);
    await settings.setValue(AiDraftService.profilesKey, jsonEncode(_profiles));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('AI 配置已更新')));
    }
  }

  void _addOrEditProfile([int? index]) {
    final isEdit = index != null;
    final item = isEdit ? _profiles[index] : null;
    final nameController = TextEditingController(text: item?['name'] ?? '');
    final endpointController = TextEditingController(text: item?['endpoint'] ?? '');
    final modelController = TextEditingController(text: item?['model'] ?? '');
    final keyController = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isEdit ? '编辑 AI 配置' : '新增 AI 配置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameController, decoration: const InputDecoration(labelText: '配置名称', hintText: '如：OpenAI / 个人本地模型')),
              const SizedBox(height: 8),
              TextField(controller: endpointController, decoration: const InputDecoration(labelText: '服务地址', hintText: 'https://api.openai.com/v1'), keyboardType: TextInputType.url),
              const SizedBox(height: 8),
              TextField(controller: modelController, decoration: const InputDecoration(labelText: '模型名称', hintText: 'gpt-4o-mini 或 qwen')),
              const SizedBox(height: 8),
              TextField(controller: keyController, decoration: const InputDecoration(labelText: 'API Key (留空不修改)'), obscureText: true),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final name = nameController.text.trim();
              final url = endpointController.text.trim();
              final model = modelController.text.trim();
              final key = keyController.text.trim();
              if (name.isEmpty || url.isEmpty || model.isEmpty) return;
              if (key.isNotEmpty) {
                await ref.read(secureSettingsServiceProvider).writeAiApiKey(key);
              }
              setState(() {
                if (isEdit) {
                  _profiles[index] = {'name': name, 'endpoint': url, 'model': model};
                  if (_currentEndpoint == item?['endpoint']) {
                    _currentEndpoint = url;
                    _currentModel = model;
                  }
                } else {
                  _profiles.add({'name': name, 'endpoint': url, 'model': model});
                  if (_profiles.length == 1) {
                    _currentEndpoint = url;
                    _currentModel = model;
                  }
                }
              });
              _saveData();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('AI 解析配置')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 解析配置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加配置',
            onPressed: () => _addOrEditProfile(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'AI 仅用于根据说明书或包装的本地 OCR 文本智能提取草稿，提取后由您确认入库，绝不静默修改数据。支持配置多个服务并选择默认。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('配置列表（点击选择默认使用）', style: Theme.of(context).textTheme.titleSmall),
          ),
          if (_profiles.isEmpty)
            Card(
              child: ListTile(
                title: const Text('暂无 AI 配置'),
                subtitle: const Text('点击右上角 "+" 添加兼容 OpenAI 的服务地址与模型。'),
                trailing: TextButton(
                  onPressed: () => _addOrEditProfile(),
                  child: const Text('立即添加'),
                ),
              ),
            )
          else
            ..._profiles.asMap().entries.map((entry) {
              final idx = entry.key;
              final profile = entry.value;
              final isDefault = _currentEndpoint == profile['endpoint'] && _currentModel == profile['model'];
              return Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: isDefault
                      ? BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)
                      : BorderSide.none,
                ),
                child: ListTile(
                  title: Text(profile['name'] ?? ''),
                  subtitle: Text('${profile['model']} · ${profile['endpoint']}'),
                  leading: Icon(
                    isDefault ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: isDefault ? Theme.of(context).colorScheme.primary : null,
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (val) {
                      if (val == 'edit') {
                        _addOrEditProfile(idx);
                      } else if (val == 'delete') {
                        setState(() {
                          _profiles.removeAt(idx);
                          if (isDefault && _profiles.isNotEmpty) {
                            _currentEndpoint = _profiles.first['endpoint']!;
                            _currentModel = _profiles.first['model']!;
                          }
                        });
                        _saveData();
                      }
                    },
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(value: 'edit', child: Text('编辑')),
                      const PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                  onTap: () {
                    setState(() {
                      _currentEndpoint = profile['endpoint'] ?? '';
                      _currentModel = profile['model'] ?? '';
                    });
                    _saveData();
                  },
                ),
              );
            }),
        ],
      ),
    );
  }
}

/// ---------------- 二级页面 4：备份与恢复 ----------------
class BackupSettingsScreen extends ConsumerWidget {
  const BackupSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('导出 JSON 备份'),
              subtitle: const Text('将本机的全部商品、多批次、库存变动历史、采购清单和设置导出为单个 JSON 文件。'),
              onTap: () => _exportBackup(context, ref),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('导入 JSON 备份'),
              subtitle: const Text('从已有 JSON 备份文件恢复数据；系统默认跳过重复记录，保护已有数据完整性。'),
              onTap: () => _importBackup(context, ref),
            ),
          ),
        ],
      ),
    );
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
