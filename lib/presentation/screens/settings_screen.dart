import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/momo_theme.dart';
import '../../application/ai_draft_service.dart';
import '../../application/barcode_lookup_service.dart';
import '../controllers/providers.dart';
import 'ai_usage_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);

    return Scaffold(
      appBar: AppBar(
        title: const Text('系统设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          _buildSettingsTile(
            context,
            icon: Icons.palette_outlined,
            title: '主题中心与个性化',
            subtitle: '当前：${palette.label}（吉祥物：${palette.mascot} ${palette.mascotName}）',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ThemeSettingsScreen()),
            ),
          ),
          _buildSettingsTile(
            context,
            icon: Icons.qr_code_scanner,
            title: '外部条码 API 接口',
            subtitle: '多接口配置、免费源切换、默认查询源',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BarcodeSettingsScreen()),
            ),
          ),
          _buildSettingsTile(
            context,
            icon: Icons.psychology_outlined,
            title: 'AI 解析与模型配置',
            subtitle: '支持 chat/responses 协议、多模型切换与默认模型',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
            ),
          ),
          _buildSettingsTile(
            context,
            icon: Icons.analytics_outlined,
            title: 'AI 用量与日志汇总',
            subtitle: '当日/7天/30天/全部 Token、缓存命中与明细统计',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AiUsageScreen()),
            ),
          ),
          _buildSettingsTile(
            context,
            icon: Icons.backup_outlined,
            title: '数据备份与迁移',
            subtitle: '全量 JSON 备份导出、数据导入与快照管理',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BackupSettingsScreen()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          child: Icon(icon, color: Theme.of(context).colorScheme.primary),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: onTap,
      ),
    );
  }
}

class ThemeSettingsScreen extends ConsumerWidget {
  const ThemeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTheme = ref.watch(themeNameProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('主题中心')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: MomoPalette.allPalettes.map((palette) {
          final isSelected = (currentTheme ?? 'default') == palette.storedValue;
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: isSelected ? palette.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () async {
                await ref.read(settingsServiceProvider).setValue('theme', palette.storedValue);
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: palette.primary.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(palette.mascot, style: const TextStyle(fontSize: 26)),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                palette.label,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: palette.primary,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  palette.mascotName,
                                  style: const TextStyle(color: Colors.white, fontSize: 10),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _buildPaletteTag('Logo', Icon(palette.appLogoIcon, size: 14, color: palette.primary)),
                              _buildPaletteTag(palette.inventoryLabel, Icon(palette.inventoryIcon, size: 14, color: palette.primary)),
                              _buildPaletteTag(palette.alertLabel, Icon(palette.alertIcon, size: 14, color: palette.primary)),
                              _buildPaletteTag(palette.shoppingLabel, Icon(palette.shoppingIcon, size: 14, color: palette.primary)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (isSelected)
                      Icon(Icons.check_circle, color: palette.primary, size: 26)
                    else
                      const Icon(Icons.radio_button_unchecked, color: Colors.grey),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPaletteTag(String text, Widget icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 2),
          Text(text, style: const TextStyle(fontSize: 10, color: Colors.black87)),
        ],
      ),
    );
  }
}

class BarcodeSettingsScreen extends ConsumerStatefulWidget {
  const BarcodeSettingsScreen({super.key});

  @override
  ConsumerState<BarcodeSettingsScreen> createState() => _BarcodeSettingsScreenState();
}

class _BarcodeSettingsScreenState extends ConsumerState<BarcodeSettingsScreen> {
  bool _useExternal = false;
  List<Map<String, dynamic>> _profiles = [];
  String _activeId = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsServiceProvider);
    final use = (await settings.getValue(BarcodeLookupService.enabledKey)) == 'true';
    final profilesRaw = await settings.getValue(BarcodeLookupService.profilesKey);
    final defaultEndpoint = await settings.getValue(BarcodeLookupService.endpointKey) ?? '';

    List<Map<String, dynamic>> parsedProfiles = [];
    if (profilesRaw != null && profilesRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(profilesRaw);
        if (decoded is List) {
          parsedProfiles = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {}
    }

    if (parsedProfiles.isEmpty) {
      parsedProfiles = [
        {
          'id': 'free_default',
          'name': '免费公共条码库 (Open Food Facts)',
          'endpoint': BarcodeLookupService.defaultFreeEndpoint,
        },
      ];
    }

    setState(() {
      _useExternal = use;
      _profiles = parsedProfiles;
      _activeId = parsedProfiles.firstWhere(
        (p) => p['endpoint'] == defaultEndpoint,
        orElse: () => parsedProfiles.first,
      )['id'] as String;
    });
  }

  Future<void> _save() async {
    final settings = ref.read(settingsServiceProvider);
    await settings.setValue(BarcodeLookupService.enabledKey, _useExternal ? 'true' : 'false');
    await settings.setValue(BarcodeLookupService.profilesKey, jsonEncode(_profiles));

    final current = _profiles.firstWhere(
      (p) => p['id'] == _activeId,
      orElse: () => _profiles.first,
    );
    await settings.setValue(BarcodeLookupService.endpointKey, current['endpoint'] as String? ?? '');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('条码配置已保存')));
    }
  }

  void _addOrEditProfile([Map<String, dynamic>? item]) {
    final nameCtrl = TextEditingController(text: item?['name'] as String? ?? '');
    final urlCtrl = TextEditingController(text: item?['endpoint'] as String? ?? '');

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item == null ? '添加条码接口' : '编辑条码接口'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '接口名称')),
            const SizedBox(height: 12),
            TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: 'API 地址模板（含 {barcode}）')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              setState(() {
                if (item == null) {
                  final newId = DateTime.now().millisecondsSinceEpoch.toString();
                  _profiles.add({'id': newId, 'name': name, 'endpoint': url});
                  _activeId = newId;
                } else {
                  item['name'] = name;
                  item['endpoint'] = url;
                }
              });
              Navigator.pop(ctx);
              _save();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('外部条码 API')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('启用外部条码查询'),
            subtitle: const Text('扫码若本地库无记录，尝试调用配置的云端或免费 API 查询商品名'),
            value: _useExternal,
            onChanged: (val) {
              setState(() => _useExternal = val);
              _save();
            },
          ),
          const Divider(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('接口配置列表（点击单选设为默认）', style: TextStyle(fontWeight: FontWeight.bold)),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加配置'),
                onPressed: () => _addOrEditProfile(),
              ),
            ],
          ),
          ..._profiles.map((p) {
            final isDefault = p['id'] == _activeId;
            return Card(
              child: ListTile(
                leading: Icon(
                  isDefault ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: isDefault ? Theme.of(context).primaryColor : Colors.grey,
                ),
                title: Text(p['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(p['endpoint'] as String? ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () {
                  setState(() => _activeId = p['id'] as String);
                  _save();
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () => _addOrEditProfile(p),
                    ),
                    if (_profiles.length > 1)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () {
                          setState(() {
                            _profiles.removeWhere((el) => el['id'] == p['id']);
                            if (_activeId == p['id']) {
                              _activeId = _profiles.first['id'] as String;
                            }
                          });
                          _save();
                        },
                      ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class AiSettingsScreen extends ConsumerStatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  ConsumerState<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends ConsumerState<AiSettingsScreen> {
  List<Map<String, dynamic>> _profiles = [];
  String _activeId = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsServiceProvider);
    final secureSettings = ref.read(secureSettingsServiceProvider);

    final profilesRaw = await settings.getValue(AiDraftService.profilesKey);
    final defaultEndpoint = await settings.getValue(AiDraftService.endpointKey) ?? '';
    final defaultModel = await settings.getValue(AiDraftService.modelKey) ?? '';
    final defaultApiKey = await secureSettings.readAiApiKey() ?? '';
    final defaultType = await settings.getValue(AiDraftService.endpointTypeKey) ?? 'chat';

    List<Map<String, dynamic>> parsedProfiles = [];
    if (profilesRaw != null && profilesRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(profilesRaw);
        if (decoded is List) {
          parsedProfiles = decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {}
    }

    if (parsedProfiles.isEmpty && defaultEndpoint.isNotEmpty) {
      parsedProfiles = [
        {
          'id': 'default_profile',
          'name': '默认模型配置',
          'endpoint': defaultEndpoint,
          'model': defaultModel,
          'apiKey': defaultApiKey,
          'endpointType': defaultType,
        }
      ];
    } else if (parsedProfiles.isEmpty) {
      parsedProfiles = [
        {
          'id': 'openai_chat',
          'name': 'OpenAI Chat Completions',
          'endpoint': 'https://api.openai.com/v1',
          'model': 'gpt-4o-mini',
          'apiKey': '',
          'endpointType': 'chat',
        },
        {
          'id': 'openai_responses',
          'name': 'OpenAI Responses API',
          'endpoint': 'https://api.openai.com/v1',
          'model': 'gpt-4o-mini',
          'apiKey': '',
          'endpointType': 'responses',
        },
      ];
    }

    setState(() {
      _profiles = parsedProfiles;
      _activeId = parsedProfiles.firstWhere(
        (p) => p['endpoint'] == defaultEndpoint && p['model'] == defaultModel,
        orElse: () => parsedProfiles.first,
      )['id'] as String;
    });
  }

  Future<void> _save() async {
    final settings = ref.read(settingsServiceProvider);
    final secureSettings = ref.read(secureSettingsServiceProvider);

    await settings.setValue(AiDraftService.profilesKey, jsonEncode(_profiles));

    final current = _profiles.firstWhere(
      (p) => p['id'] == _activeId,
      orElse: () => _profiles.first,
    );
    await settings.setValue(AiDraftService.endpointKey, current['endpoint'] as String? ?? '');
    await settings.setValue(AiDraftService.modelKey, current['model'] as String? ?? '');
    await settings.setValue(AiDraftService.endpointTypeKey, current['endpointType'] as String? ?? 'chat');
    await secureSettings.writeAiApiKey(current['apiKey'] as String? ?? '');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('AI 配置已同步并设为默认')));
    }
  }

  void _addOrEditProfile([Map<String, dynamic>? item]) {
    final nameCtrl = TextEditingController(text: item?['name'] as String? ?? '');
    final urlCtrl = TextEditingController(text: item?['endpoint'] as String? ?? 'https://api.openai.com/v1');
    final modelCtrl = TextEditingController(text: item?['model'] as String? ?? 'gpt-4o-mini');
    final keyCtrl = TextEditingController(text: item?['apiKey'] as String? ?? '');
    String endpointType = item?['endpointType'] as String? ?? 'chat';

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(item == null ? '添加 AI 模型服务' : '编辑 AI 模型服务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '配置名称（如：主力模型）')),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: endpointType,
                  decoration: const InputDecoration(labelText: '接口协议类型'),
                  items: const [
                    DropdownMenuItem(value: 'chat', child: Text('Chat Completions (/v1/chat/completions)')),
                    DropdownMenuItem(value: 'responses', child: Text('Responses API (/v1/responses)')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => endpointType = val);
                    }
                  },
                ),
                const SizedBox(height: 8),
                TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: 'API 地址 (Base URL)')),
                const SizedBox(height: 8),
                TextField(controller: modelCtrl, decoration: const InputDecoration(labelText: '模型名称 (Model)')),
                const SizedBox(height: 8),
                TextField(
                  controller: keyCtrl,
                  decoration: const InputDecoration(labelText: 'API Key'),
                  obscureText: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final url = urlCtrl.text.trim();
                final model = modelCtrl.text.trim();
                final key = keyCtrl.text.trim();
                if (name.isEmpty || url.isEmpty || model.isEmpty) return;

                setState(() {
                  if (item == null) {
                    final newId = DateTime.now().millisecondsSinceEpoch.toString();
                    _profiles.add({
                      'id': newId,
                      'name': name,
                      'endpoint': url,
                      'model': model,
                      'apiKey': key,
                      'endpointType': endpointType,
                    });
                    _activeId = newId;
                  } else {
                    item['name'] = name;
                    item['endpoint'] = url;
                    item['model'] = model;
                    item['apiKey'] = key;
                    item['endpointType'] = endpointType;
                  }
                });
                Navigator.pop(ctx);
                _save();
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 解析与模型配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('模型服务列表（点击勾选设为默认）', style: TextStyle(fontWeight: FontWeight.bold)),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加配置'),
                onPressed: () => _addOrEditProfile(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._profiles.map((p) {
            final isDefault = p['id'] == _activeId;
            final isResponses = p['endpointType'] == 'responses';
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  isDefault ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: isDefault ? Theme.of(context).primaryColor : Colors.grey,
                ),
                title: Row(
                  children: [
                    Expanded(child: Text(p['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.bold))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: (isResponses ? Colors.purple : Colors.blue).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isResponses ? 'responses' : 'chat',
                        style: TextStyle(fontSize: 10, color: isResponses ? Colors.purple : Colors.blue),
                      ),
                    ),
                  ],
                ),
                subtitle: Text('模型: ${p['model']} | ${p['endpoint']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () {
                  setState(() => _activeId = p['id'] as String);
                  _save();
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () => _addOrEditProfile(p),
                    ),
                    if (_profiles.length > 1)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () {
                          setState(() {
                            _profiles.removeWhere((el) => el['id'] == p['id']);
                            if (_activeId == p['id']) {
                              _activeId = _profiles.first['id'] as String;
                            }
                          });
                          _save();
                        },
                      ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class BackupSettingsScreen extends ConsumerWidget {
  const BackupSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backupService = ref.watch(backupServiceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('数据备份与迁移')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('导出全量数据备份 (JSON)'),
              subtitle: const Text('包含所有商品、批次、出入库变动与采买清单'),
              onTap: () async {
                try {
                  final json = await backupService.exportJson();
                  if (context.mounted) {
                    showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('数据导出成功'),
                        content: Text('已成功打包生成 JSON 数据快照（字符数：${json.length}）。'),
                        actions: [
                          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('确定')),
                        ],
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败：$e')));
                  }
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.file_upload_outlined),
              title: const Text('导入数据快照'),
              subtitle: const Text('支持合并或覆盖现有本地库存'),
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请选择标准 MomoBox JSON 备份文件')));
              },
            ),
          ),
        ],
      ),
    );
  }
}
