import 'nas_settings_screen.dart';
import 'home_assistant_settings_screen.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../widgets/app_feedback.dart';

import '../../app/momo_theme.dart';
import '../../application/ai_draft_service.dart';
import '../../application/barcode_lookup_service.dart';
import '../../application/storage_management_service.dart';
import '../../data/repositories/backup_repository.dart';
import '../../services/local_notification_service.dart';
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
          _buildSectionHeader(context, '外观与个性化'),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _buildSettingsListTile(
                  context,
                  icon: Icons.palette_outlined,
                  title: '主题中心与个性化',
                  subtitle: '当前：${palette.label}（吉祥物：${palette.mascot} ${palette.mascotName}）',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ThemeSettingsScreen()),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _buildSettingsListTile(
                  context,
                  icon: Icons.format_size_rounded,
                  title: '界面字体大小',
                  subtitle: '支持紧凑、标准、大号及关怀超大号字号',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FontScaleSettingsScreen()),
                  ),
                ),
              ],
            ),
          ),

          _buildSectionHeader(context, '隐私、密钥与外部服务'),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _buildSettingsListTile(
                  context,
                  icon: Icons.shield_outlined,
                  title: '隐私与密钥安全',
                  subtitle: 'AI 密钥与敏感凭证仅保存在设备安全存储中',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PrivacySettingsScreen()),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _buildSettingsListTile(
                  context,
                  icon: Icons.psychology_outlined,
                  title: 'AI 解析与模型配置',
                  subtitle: '自动识别协议、chat/responses 双协议与多模型切换',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _buildSettingsListTile(
                  context,
                  icon: Icons.analytics_outlined,
                  title: 'AI 用量与日志汇总',
                  subtitle: '当日/7天/30天/全部 Token 与明细统计',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AiUsageScreen()),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _buildSettingsListTile(
                  context,
                  icon: Icons.qr_code_scanner,
                  title: '外部条码 API 接口',
                  subtitle: '多接口配置、免费源切换与调用角色',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BarcodeSettingsScreen()),
                  ),
                ),
              ],
            ),
          ),

          _buildSectionHeader(context, '网络服务与家庭协同'),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _buildSettingsListTile(
                  context,
                  icon: Icons.dns_outlined,
                  title: 'NAS 协同管理',
                  subtitle: '局域网双向同步、家庭组识别码与多端协同',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const NasSettingsScreen()),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _buildSettingsListTile(
                  context,
                  icon: Icons.hub_outlined,
                  title: 'Home Assistant 连接配置',
                  subtitle: 'HA 地址、Token 授权状态与设备白名单',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HomeAssistantSettingsScreen()),
                  ),
                ),
              ],
            ),
          ),

          _buildSectionHeader(context, '数据与系统'),
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _buildSettingsListTile(
                  context,
                  icon: Icons.notifications_active_outlined,
                  title: '提醒与通知',
                  subtitle: '查看通知权限、重新授权并发送测试提醒',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const NotificationSettingsScreen()),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _buildSettingsListTile(
                  context,
                  icon: Icons.backup_outlined,
                  title: '数据备份与迁移',
                  subtitle: '全量 JSON 备份导出、数据导入与快照管理',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BackupSettingsScreen()),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                _buildSettingsListTile(
                  context,
                  icon: Icons.info_outline,
                  title: '关于与存储信息',
                  subtitle: '版本号、本地数据说明、存储空间管理与许可',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AboutSettingsScreen()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildSettingsListTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
        child: Icon(icon, color: Theme.of(context).colorScheme.primary),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.arrow_forward_ios, size: 14),
      onTap: onTap,
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = ref.read(settingsServiceProvider);
    final use = (await settings.getValue(BarcodeLookupService.enabledKey)) == 'true';
    final profilesRaw = await settings.getValue(BarcodeLookupService.profilesKey);

    var profiles = <Map<String, dynamic>>[];
    String? configurationError;
    try {
      profiles = BarcodeLookupService.parseProfiles(profilesRaw);
    } on FormatException {
      configurationError = '条码接口配置格式无效，请重新配置。';
    }

    if (!mounted) return;
    setState(() {
      _useExternal = use;
      _profiles = profiles;
    });
    if (configurationError != null) {
      showAppSnackBar(context,
        SnackBar(content: Text(configurationError)),
      );
    }
  }

  Future<void> _save() async {
    final settings = ref.read(settingsServiceProvider);
    await settings.setValue(BarcodeLookupService.enabledKey, _useExternal ? 'true' : 'false');
    await settings.setValue(BarcodeLookupService.profilesKey, jsonEncode(_profiles));

    if (mounted) {
      showAppSnackBar(context, const SnackBar(content: Text('条码配置已保存')));
    }
  }

  String _roleLabel(Map<String, dynamic> profile) {
    switch (profile[BarcodeLookupService.profileRoleKey]) {
      case BarcodeLookupService.primaryRole:
        return '主服务';
      case BarcodeLookupService.secondaryRole:
        return '副服务';
      case BarcodeLookupService.fallbackRole:
        return '兜底服务';
      default:
        return '仅保存';
    }
  }

  void _assignProfileRole(Map<String, dynamic> profile, String role) {
    if (role != BarcodeLookupService.standbyRole) {
      for (final existing in _profiles) {
        if (existing != profile && existing[BarcodeLookupService.profileRoleKey] == role) {
          existing[BarcodeLookupService.profileRoleKey] = BarcodeLookupService.standbyRole;
        }
      }
    }
    profile[BarcodeLookupService.profileRoleKey] = role;
  }

  void _addOrEditProfile([Map<String, dynamic>? item]) {
    final nameCtrl = TextEditingController(text: item?['name'] as String? ?? '');
    final urlCtrl = TextEditingController(text: item?['endpoint'] as String? ?? '');
    var role = item?[BarcodeLookupService.profileRoleKey] as String? ?? BarcodeLookupService.standbyRole;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(item == null ? '添加条码接口' : '编辑条码接口'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '接口名称')),
                const SizedBox(height: 12),
                TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: 'API 地址模板（含 {barcode}）')),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: role,
                  decoration: const InputDecoration(labelText: '调用角色'),
                  items: const [
                    DropdownMenuItem(value: BarcodeLookupService.primaryRole, child: Text('主服务', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: BarcodeLookupService.secondaryRole, child: Text('副服务（主服务失败时调用）', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: BarcodeLookupService.fallbackRole, child: Text('兜底服务（前两者失败时调用）', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: BarcodeLookupService.standbyRole, child: Text('仅保存，不参与调用', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => role = value);
                  },
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
                if (name.isEmpty || url.isEmpty) return;
                setState(() {
                  final profile = item ?? <String, dynamic>{'id': DateTime.now().millisecondsSinceEpoch.toString()};
                  profile['name'] = name;
                  profile['endpoint'] = url;
                  if (item == null) _profiles.add(profile);
                  _assignProfileRole(profile, role);
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
      appBar: AppBar(title: const Text('外部条码 API')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('启用外部条码查询'),
            subtitle: const Text('已预配免费的 Open Food Facts；开启后，条码会发送给主服务，失败时依次尝试副服务和兜底服务。'),
            value: _useExternal,
            onChanged: (value) {
              setState(() => _useExternal = value);
              _save();
            },
          ),
          const Divider(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(child: Text('接口配置列表（点击设为主服务；副服务和兜底服务均可留空）', style: TextStyle(fontWeight: FontWeight.bold))),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加配置'),
                onPressed: () => _addOrEditProfile(),
              ),
            ],
          ),
          ..._profiles.map((profile) {
            final isPrimary = profile[BarcodeLookupService.profileRoleKey] == BarcodeLookupService.primaryRole;
            return Card(
              child: ListTile(
                leading: Icon(
                  isPrimary ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: isPrimary ? Theme.of(context).primaryColor : Colors.grey,
                ),
                title: Row(
                  children: [
                    Expanded(child: Text(profile['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.bold))),
                    Text(_roleLabel(profile), style: const TextStyle(fontSize: 11)),
                  ],
                ),
                subtitle: Text(profile['endpoint'] as String? ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                onTap: () {
                  setState(() => _assignProfileRole(profile, BarcodeLookupService.primaryRole));
                  _save();
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () => _addOrEditProfile(profile),
                    ),
                    if (_profiles.length > 1)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () {
                          setState(() {
                            final wasPrimary = profile[BarcodeLookupService.profileRoleKey] == BarcodeLookupService.primaryRole;
                            _profiles.remove(profile);
                            if (wasPrimary) _assignProfileRole(_profiles.first, BarcodeLookupService.primaryRole);
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
    final defaultType = await settings.getValue(AiDraftService.endpointTypeKey) ?? 'auto';
    final storedActiveId = await settings.getValue(AiDraftService.activeProfileKey);
    final storedSecondaryId = await settings.getValue(AiDraftService.secondaryProfileIdKey);
    final storedFallbackId = await settings.getValue(AiDraftService.fallbackProfileIdKey);
    final secondaryEndpoint = await settings.getValue(AiDraftService.secondaryEndpointKey);
    final secondaryModel = await settings.getValue(AiDraftService.secondaryModelKey);
    final secondaryType = await settings.getValue(AiDraftService.secondaryTypeKey) ?? 'auto';
    final fallbackEndpoint = await settings.getValue(AiDraftService.fallbackEndpointKey);
    final fallbackModel = await settings.getValue(AiDraftService.fallbackModelKey);
    final fallbackType = await settings.getValue(AiDraftService.fallbackTypeKey) ?? 'auto';

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
          'endpointType': 'chat',
        },
        {
          'id': 'openai_responses',
          'name': 'OpenAI Responses API',
          'endpoint': 'https://api.openai.com/v1',
          'model': 'gpt-4o-mini',
          'endpointType': 'responses',
        },
      ];
    }

    var shouldSanitizeProfiles = false;

    void restoreLegacyFallbackProfile({
      required String role,
      required String legacyId,
      required String? endpoint,
      required String? model,
      required String endpointType,
    }) {
      if (endpoint == null || endpoint.trim().isEmpty || model == null || model.trim().isEmpty) return;
      final profileId = role == AiDraftService.secondaryRole
          ? (storedSecondaryId?.trim().isNotEmpty == true ? storedSecondaryId!.trim() : legacyId)
          : (storedFallbackId?.trim().isNotEmpty == true ? storedFallbackId!.trim() : legacyId);
      if (parsedProfiles.any((profile) => profile['id'] == profileId)) return;
      parsedProfiles.add({
        'id': profileId,
        'name': role == AiDraftService.secondaryRole ? '副服务（已迁移）' : '兜底服务（已迁移）',
        'endpoint': endpoint.trim(),
        'model': model.trim(),
        'endpointType': endpointType,
        AiDraftService.profileRoleKey: role,
      });
      shouldSanitizeProfiles = true;
    }

    restoreLegacyFallbackProfile(
      role: AiDraftService.secondaryRole,
      legacyId: 'secondary_profile',
      endpoint: secondaryEndpoint,
      model: secondaryModel,
      endpointType: secondaryType,
    );
    restoreLegacyFallbackProfile(
      role: AiDraftService.fallbackRole,
      legacyId: 'fallback_profile',
      endpoint: fallbackEndpoint,
      model: fallbackModel,
      endpointType: fallbackType,
    );

    for (final profile in parsedProfiles) {
      final id = profile['id'] as String;
      // Migrate a legacy plaintext profile key into platform secure storage,
      // then ensure it will not be written back to SQLite.
      final legacyKey = profile.remove('apiKey') as String?;
      if (legacyKey != null && legacyKey.trim().isNotEmpty) {
        shouldSanitizeProfiles = true;
        await secureSettings.writeAiApiKeyForProfile(id, legacyKey);
      }
      profile.remove('_apiKeyDraft');
      profile['hasApiKey'] = (await secureSettings.readAiApiKeyForProfile(id))?.trim().isNotEmpty == true;
    }

    final selected = parsedProfiles.firstWhere(
      (profile) => profile['id'] == storedActiveId,
      orElse: () => parsedProfiles.firstWhere(
        (profile) => profile['endpoint'] == defaultEndpoint && profile['model'] == defaultModel,
        orElse: () => parsedProfiles.first,
      ),
    );
    if (defaultApiKey.trim().isNotEmpty && !(selected['hasApiKey'] as bool)) {
      await secureSettings.writeAiApiKeyForProfile(selected['id'] as String, defaultApiKey);
      selected['hasApiKey'] = true;
      shouldSanitizeProfiles = true;
    }

    // Existing installations only had a selected/default service. Make it
    // the primary service and retain any persisted fallback assignments.
    final selectedId = selected['id'] as String;
    for (final profile in parsedProfiles) {
      if (profile[AiDraftService.profileRoleKey] == AiDraftService.primaryRole && profile['id'] != selectedId) {
        profile.remove(AiDraftService.profileRoleKey);
        shouldSanitizeProfiles = true;
      }
    }
    if (selected[AiDraftService.profileRoleKey] != AiDraftService.primaryRole) {
      selected[AiDraftService.profileRoleKey] = AiDraftService.primaryRole;
      shouldSanitizeProfiles = true;
    }
    void restoreFallbackRole(String? profileId, String role) {
      if (profileId == null || profileId.isEmpty || profileId == selectedId) return;
      final profile = parsedProfiles.where((item) => item['id'] == profileId).firstOrNull;
      if (profile == null) return;
      for (final item in parsedProfiles) {
        if (item != profile && item[AiDraftService.profileRoleKey] == role) {
          item.remove(AiDraftService.profileRoleKey);
          shouldSanitizeProfiles = true;
        }
      }
      if (profile[AiDraftService.profileRoleKey] != role) {
        profile[AiDraftService.profileRoleKey] = role;
        shouldSanitizeProfiles = true;
      }
    }
    restoreFallbackRole(
      storedSecondaryId?.trim().isNotEmpty == true ? storedSecondaryId : 'secondary_profile',
      AiDraftService.secondaryRole,
    );
    restoreFallbackRole(
      storedFallbackId?.trim().isNotEmpty == true ? storedFallbackId : 'fallback_profile',
      AiDraftService.fallbackRole,
    );

    if (shouldSanitizeProfiles) {
      final sanitized = parsedProfiles.map((profile) {
        final value = Map<String, dynamic>.from(profile)..remove('hasApiKey');
        return value;
      }).toList();
      await settings.setValue(AiDraftService.profilesKey, jsonEncode(sanitized));
      await secureSettings.deleteAiApiKey();
    }
    // Older installs had no active profile identifier. Persist the selected
    // profile before deleting the old shared key so AI services resolve the
    // migrated profile-scoped secret on their next request.
    if (storedActiveId != selected['id']) {
      await settings.setValue(AiDraftService.activeProfileKey, selected['id'] as String);
    }

    if (mounted) {
      setState(() {
        _profiles = parsedProfiles;
        _activeId = selected['id'] as String;
      });
    }
  }

  Future<void> _save() async {
    final settings = ref.read(settingsServiceProvider);
    final secureSettings = ref.read(secureSettingsServiceProvider);

    final current = _profiles.firstWhere(
      (profile) => profile['id'] == _activeId,
      orElse: () => _profiles.first,
    );
    _assignProfileRole(current, AiDraftService.primaryRole);

    final persisted = <Map<String, dynamic>>[];
    for (final profile in _profiles) {
      final id = profile['id'] as String;
      final draftKey = profile.remove('_apiKeyDraft') as String?;
      if (draftKey != null) {
        await secureSettings.writeAiApiKeyForProfile(id, draftKey);
        profile['hasApiKey'] = draftKey.trim().isNotEmpty;
      }
      final serializable = Map<String, dynamic>.from(profile)
        ..remove('apiKey')
        ..remove('hasApiKey');
      persisted.add(serializable);
    }
    await settings.setValue(AiDraftService.profilesKey, jsonEncode(persisted));

    await settings.setValue(AiDraftService.endpointKey, current['endpoint'] as String? ?? '');
    await settings.setValue(AiDraftService.modelKey, current['model'] as String? ?? '');
    await settings.setValue(AiDraftService.endpointTypeKey, current['endpointType'] as String? ?? 'chat');
    await settings.setValue(AiDraftService.activeProfileKey, current['id'] as String);

    final secondary = _profileWithRole(AiDraftService.secondaryRole);
    await settings.setValue(AiDraftService.secondaryEndpointKey, secondary?['endpoint'] as String? ?? '');
    await settings.setValue(AiDraftService.secondaryModelKey, secondary?['model'] as String? ?? '');
    await settings.setValue(AiDraftService.secondaryTypeKey, secondary?['endpointType'] as String? ?? 'auto');
    await settings.setValue(AiDraftService.secondaryProfileIdKey, secondary?['id'] as String? ?? '');

    final fallback = _profileWithRole(AiDraftService.fallbackRole);
    await settings.setValue(AiDraftService.fallbackEndpointKey, fallback?['endpoint'] as String? ?? '');
    await settings.setValue(AiDraftService.fallbackModelKey, fallback?['model'] as String? ?? '');
    await settings.setValue(AiDraftService.fallbackTypeKey, fallback?['endpointType'] as String? ?? 'auto');
    await settings.setValue(AiDraftService.fallbackProfileIdKey, fallback?['id'] as String? ?? '');

    // All current keys are profile-scoped. Remove the old shared key after
    // a successful save so there is only one protected copy per profile.
    await secureSettings.deleteAiApiKey();

    if (mounted) {
      showAppSnackBar(context, const SnackBar(content: Text('AI 配置已保存；密钥仅保存在设备安全存储中。')));
    }
  }

  Map<String, dynamic>? _profileWithRole(String role) {
    for (final profile in _profiles) {
      if (profile[AiDraftService.profileRoleKey] == role) return profile;
    }
    return null;
  }

  void _assignProfileRole(Map<String, dynamic> profile, String requestedRole) {
    final id = profile['id'] as String;
    var role = requestedRole;

    if (role != AiDraftService.primaryRole && _activeId == id) {
      final replacement = _profiles.where((item) => item['id'] != id).firstOrNull;
      if (replacement == null) {
        role = AiDraftService.primaryRole;
      } else {
        replacement[AiDraftService.profileRoleKey] = AiDraftService.primaryRole;
        _activeId = replacement['id'] as String;
      }
    }

    if (role != AiDraftService.standbyRole) {
      for (final item in _profiles) {
        if (item['id'] != id && item[AiDraftService.profileRoleKey] == role) {
          item.remove(AiDraftService.profileRoleKey);
        }
      }
    }
    if (role == AiDraftService.standbyRole) {
      profile.remove(AiDraftService.profileRoleKey);
    } else {
      profile[AiDraftService.profileRoleKey] = role;
    }
    if (role == AiDraftService.primaryRole) {
      _activeId = id;
    }
  }

  String _roleLabel(Map<String, dynamic> profile) {
    switch (profile[AiDraftService.profileRoleKey]) {
      case AiDraftService.primaryRole:
        return '主服务';
      case AiDraftService.secondaryRole:
        return '副服务';
      case AiDraftService.fallbackRole:
        return '兜底服务';
      default:
        return '未加入容灾';
    }
  }

  void _addOrEditProfile([Map<String, dynamic>? item]) {
    final nameCtrl = TextEditingController(text: item?['name'] as String? ?? '');
    final urlCtrl = TextEditingController(text: item?['endpoint'] as String? ?? 'https://api.openai.com/v1');
    final modelCtrl = TextEditingController(text: item?['model'] as String? ?? 'gpt-4o-mini');
    final keyCtrl = TextEditingController();
    String endpointType = item?['endpointType'] as String? ?? 'auto';
    String fallbackRole = item?[AiDraftService.profileRoleKey] as String? ??
        (item?['id'] == _activeId ? AiDraftService.primaryRole : AiDraftService.standbyRole);

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
                  isExpanded: true,
                  initialValue: fallbackRole,
                  isDense: true,
                  decoration: const InputDecoration(labelText: '容灾角色'),
                  items: const [
                    DropdownMenuItem(value: AiDraftService.primaryRole, child: Text('主服务（优先调用）', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: AiDraftService.secondaryRole, child: Text('副服务（主服务失败时调用）', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: AiDraftService.fallbackRole, child: Text('兜底服务（前两者失败时调用）', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: AiDraftService.standbyRole, child: Text('仅保存，不参与调用', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => fallbackRole = value);
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: endpointType,
                  isDense: true,
                  isExpanded: true,
                  menuMaxHeight: 280,
                  borderRadius: BorderRadius.circular(16),
                  decoration: const InputDecoration(labelText: '接口协议类型'),
                  items: const [
                    DropdownMenuItem(
                      value: 'auto',
                      child: Text('自动判断 (Auto 推荐)', overflow: TextOverflow.ellipsis),
                    ),
                    DropdownMenuItem(
                      value: 'chat',
                      child: Text('Chat Completions (/v1/chat/completions)', overflow: TextOverflow.ellipsis),
                    ),
                    DropdownMenuItem(
                      value: 'responses',
                      child: Text('Responses API (/v1/responses)', overflow: TextOverflow.ellipsis),
                    ),
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
                  decoration: const InputDecoration(labelText: 'API Key', hintText: '留空则保留已保存的密钥'),
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
                    final profile = <String, dynamic>{
                      'id': newId,
                      'name': name,
                      'endpoint': url,
                      'model': model,
                      '_apiKeyDraft': key,
                      'hasApiKey': key.isNotEmpty,
                      'endpointType': endpointType,
                    };
                    _profiles.add(profile);
                    _assignProfileRole(profile, fallbackRole);
                  } else {
                    item['name'] = name;
                    item['endpoint'] = url;
                    item['model'] = model;
                    if (key.isNotEmpty) {
                      item['_apiKeyDraft'] = key;
                      item['hasApiKey'] = true;
                    }
                    item['endpointType'] = endpointType;
                    _assignProfileRole(item, fallbackRole);
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
            children: [
              const Expanded(
                child: Text(
                  '模型服务列表（点按设为主服务；编辑可设置副服务或兜底服务）',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
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
            final type = p['endpointType'] as String? ?? 'auto';
            final Color badgeColor = type == 'responses'
                ? Colors.purple
                : (type == 'chat' ? Colors.blue : Colors.teal);
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(
                  isDefault ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: isDefault ? Theme.of(context).primaryColor : Colors.grey,
                ),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p['name'] as String? ?? '',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: badgeColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            type == 'auto' ? '自动 (auto)' : type,
                            style: TextStyle(fontSize: 10, color: badgeColor),
                          ),
                        ),
                        Text(_roleLabel(p), style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                  ],
                ),
                subtitle: Text(
                  '模型: ${p['model']} | ${p['endpoint']}\n密钥：${p['hasApiKey'] == true ? '已安全保存' : '未配置'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  setState(() => _assignProfileRole(p, AiDraftService.primaryRole));
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
                        onPressed: () async {
                          await ref.read(secureSettingsServiceProvider).deleteAiApiKeyForProfile(p['id'] as String);
                          if (!mounted) return;
                          setState(() {
                            _profiles.removeWhere((el) => el['id'] == p['id']);
                            if (_activeId == p['id']) {
                              final nextPrimary = _profiles.first;
                              _activeId = nextPrimary['id'] as String;
                              _assignProfileRole(nextPrimary, AiDraftService.primaryRole);
                            }
                          });
                          await _save();
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

class BackupSettingsScreen extends ConsumerStatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  ConsumerState<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends ConsumerState<BackupSettingsScreen> {
  bool _busy = false;

  Future<void> _exportBackup() async {
    setState(() => _busy = true);
    try {
      final json = await ref.read(backupServiceProvider).exportJson();
      final directory = await getTemporaryDirectory();
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      final file = File(p.join(directory.path, 'momobox-backup-$stamp.json'));
      await file.writeAsString(json, flush: true);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/json', name: p.basename(file.path))],
        subject: '嬷嬷的小箱子数据备份',
        text: 'MomoBox 全量 JSON 数据备份',
      );
    } catch (error) {
      if (mounted) {
        showAppSnackBar(context, SnackBar(content: Text('导出失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importBackup() async {
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (selection == null) return;
      final selected = selection.files.single;
      final content = selected.bytes != null
          ? utf8.decode(selected.bytes!)
          : await File(selected.path!).readAsString();
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认导入备份？'),
          content: const Text('导入会合并到当前数据；相同 ID 的记录将跳过，当前数据不会被覆盖。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('开始导入')),
          ],
        ),
      );
      if (approved != true || !mounted) return;

      setState(() => _busy = true);
      final report = await ref.read(backupServiceProvider).importJson(content);
      if (!mounted) return;
      await _showImportReport(report);
    } on BackupImportException catch (error) {
      if (mounted) await _showImportFailures(error.failures);
    } on FormatException {
      if (mounted) {
        showAppSnackBar(context, const SnackBar(content: Text('文件不是有效的 UTF-8 JSON 备份。')));
      }
    } catch (error) {
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('导入失败：$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showImportReport(ImportReport report) => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('数据导入完成'),
          content: Text('成功导入 ${report.imported} 条记录；跳过 ${report.skipped} 条重复记录。'),
          actions: [FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('确定'))],
        ),
      );

  Future<void> _showImportFailures(List<ImportFailure> failures) => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('备份文件未导入'),
          content: SingleChildScrollView(
            child: Text(failures.isEmpty ? '备份文件格式不正确。' : failures.map((failure) => '• $failure').join('\n')),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('确定'))],
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('数据备份与迁移')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('导出全量数据备份 (JSON)'),
                subtitle: const Text('生成备份文件后，可保存或发送到其他设备。API 密钥不会包含在备份中。'),
                trailing: _busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
                onTap: _busy ? null : _exportBackup,
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: const Text('导入数据备份'),
                subtitle: const Text('默认合并导入；重复 ID 自动跳过，不覆盖当前数据。'),
                onTap: _busy ? null : _importBackup,
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('恢复到空白设备时，先安装 MomoBox，再选择此前导出的 JSON 文件即可。导入会先完整校验文件，校验失败不会写入部分数据。'),
            ),
          ],
        ),
      );
}

class FontScaleSettingsScreen extends ConsumerWidget {
  const FontScaleSettingsScreen({super.key});

  static const _options = [
    (scale: 0.9, label: '紧凑 (0.9x)', desc: '适合喜欢一屏查看更多物品清单的用户'),
    (scale: 1.0, label: '标准 (1.0x - 默认)', desc: '系统标准字体排版比例'),
    (scale: 1.15, label: '大号 (1.15x)', desc: '字迹更加清晰醒目'),
    (scale: 1.3, label: '关怀超大号 (1.3x)', desc: '专为长辈设计，大字易读不易看错'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentScale = ref.watch(fontScaleProvider).valueOrNull ?? 1.0;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('字体大小设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            margin: const EdgeInsets.only(bottom: 20),
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '设置字体大小后将即时应用于全应用界面，方便不同视力习惯与家庭长辈轻松查看效期与库存。',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ..._options.map((opt) {
            final isSelected = (currentScale - opt.scale).abs() < 0.01;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: isSelected ? theme.colorScheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                leading: CircleAvatar(
                  backgroundColor: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  foregroundColor: isSelected ? Colors.white : theme.colorScheme.onSurface,
                  child: Text(
                    '${(opt.scale * 10).round() / 10}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                title: Text(
                  opt.label,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                subtitle: Text(opt.desc, style: const TextStyle(fontSize: 12)),
                trailing: isSelected
                    ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
                    : null,
                onTap: () async {
                  await ref
                      .read(settingsServiceProvider)
                      .setValue('font_scale', opt.scale.toString());
                },
              ),
            );
          }),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('实时字号效果预览：', style: TextStyle(fontWeight: FontWeight.bold)),
                  const Divider(height: 20),
                  Text('布洛芬缓释胶囊 · 剩余 2 盒', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text('到期日期：2027-06-30（效期充足）', style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text('存放位置：客厅电视柜医药箱', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends ConsumerState<NotificationSettingsScreen> {
  NotificationPermissionStatus _status = NotificationPermissionStatus.unavailable;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final status = await ref.read(localNotificationServiceProvider).permissionStatus();
    if (mounted) {
      setState(() {
        _status = status;
        _busy = false;
      });
    }
  }

  Future<void> _requestPermission() async {
    setState(() => _busy = true);
    try {
      final granted = await ref.read(localNotificationServiceProvider).requestPermission();
      if (mounted) {
        showAppSnackBar(context,
          SnackBar(content: Text(granted ? '通知权限已开启。' : '通知权限未开启，请在系统设置中允许通知。')),
        );
      }
    } catch (error) {
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('无法请求通知权限：$error')));
    } finally {
      await _refreshStatus();
    }
  }

  Future<void> _sendTest() async {
    setState(() => _busy = true);
    try {
      await ref.read(localNotificationServiceProvider).showTestNotification();
      if (mounted) showAppSnackBar(context, const SnackBar(content: Text('测试通知已发送。')));
    } catch (error) {
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('$error')));
    } finally {
      await _refreshStatus();
    }
  }

  String get _statusLabel => switch (_status) {
        NotificationPermissionStatus.allowed => '已允许',
        NotificationPermissionStatus.denied => '未允许',
        NotificationPermissionStatus.unavailable => '暂时无法确认',
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('提醒与通知')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: Icon(
                  _status == NotificationPermissionStatus.allowed
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                ),
                title: const Text('通知权限'),
                subtitle: Text(_busy ? '正在检查…' : _statusLabel),
                trailing: TextButton(
                  onPressed: _busy ? null : _requestPermission,
                  child: Text(_status == NotificationPermissionStatus.allowed ? '重新检查' : '请求授权'),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.notification_important_outlined),
                title: const Text('发送测试提醒'),
                subtitle: const Text('确认系统通知是否能正常显示。'),
                onTap: _busy ? null : _sendTest,
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'MomoBox 会根据临期、过期和低库存状态在本地安排提醒。通知未开启时，库存和提醒页面仍可正常使用；打开 App 后可继续查看所有待处理项目。',
              ),
            ),
          ],
        ),
      );
}

class StorageManagementScreen extends ConsumerStatefulWidget {
  const StorageManagementScreen({super.key});

  @override
  ConsumerState<StorageManagementScreen> createState() => _StorageManagementScreenState();
}

class _StorageManagementScreenState extends ConsumerState<StorageManagementScreen> {
  StorageUsage? _usage;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _busy = true);
    try {
      final usage = await ref.read(storageManagementServiceProvider).loadUsage();
      if (mounted) setState(() => _usage = usage);
    } catch (error) {
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('无法读取存储空间：$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String content, String action) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(content),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: Text(action)),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _cleanAll() async {
    final confirmed = await _confirm(
      '一键清理？',
      '将清空全部条码缓存、AI 用量日志，并清理无用图片（临时入库图片保留 1 天）。'
      '不会删除库存、采购清单、历史记录、备份、服务配置和正在使用的商品图片。'
      'AI 用量日志清空后无法恢复，下次条码查询可能需要联网。',
      '确认清理',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final report = await ref.read(storageManagementServiceProvider).cleanAll();
      if (!mounted) return;
      showAppSnackBar(context, SnackBar(
        content: Text('清理完成：${report.barcodeEntries} 条条码缓存、'
            '${report.media.deletedFiles} 个无用文件、'
            '${report.media.deletedMetadata} 条无效图片记录；AI 用量日志已清空。'),
      ));
    } catch (error) {
      if (mounted) {
        showAppSnackBar(context, SnackBar(
          content: Text('清理未全部完成，已完成的清理不会回退，可重试：$error'),
        ));
      }
    } finally {
      if (mounted) await _reload();
    }
  }

  Future<void> _clearExpiredBarcodeCache() async {
    if (!await _confirm('清理过期条码缓存？', '只会删除已经失效的条码查询结果，不影响库存与商品数据。', '清理') || !mounted) return;
    setState(() => _busy = true);
    try {
      final count = await ref.read(storageManagementServiceProvider).clearExpiredBarcodeCache();
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('已清理 $count 条过期缓存。')));
    } catch (error) {
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('清理失败，可重试：$error')));
    } finally {
      if (mounted) await _reload();
    }
  }

  Future<void> _clearAllBarcodeCache() async {
    if (!await _confirm('清空所有条码缓存？', '下次扫码查询时可能需要重新联网获取商品信息；不会删除库存记录。', '清空') || !mounted) return;
    setState(() => _busy = true);
    try {
      final count = await ref.read(storageManagementServiceProvider).clearAllBarcodeCache();
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('已清空 $count 条条码缓存。')));
    } catch (error) {
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('清理失败，可重试：$error')));
    } finally {
      if (mounted) await _reload();
    }
  }

  Future<void> _cleanUnusedMedia() async {
    if (!await _confirm('清理无用图片？', '只会删除未被商品引用的临时或遗失图片，不会删除正在使用的商品图片。', '清理') || !mounted) return;
    setState(() => _busy = true);
    try {
      final report = await ref.read(storageManagementServiceProvider).cleanUnusedMedia();
      if (mounted) {
        showAppSnackBar(context,
          SnackBar(content: Text('已清理 ${report.deletedFiles} 个文件、${report.deletedMetadata} 条无效记录。')),
        );
      }
    } catch (error) {
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('清理失败，可重试：$error')));
    } finally {
      if (mounted) await _reload();
    }
  }

  String _bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final usage = _usage;
    return Scaffold(
      appBar: AppBar(
        title: const Text('数据与存储空间'),
        actions: [IconButton(onPressed: _busy ? null : _reload, icon: const Icon(Icons.refresh), tooltip: '刷新')],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _busy && usage == null
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('本机数据占用', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 12),
                        Text('合计：${_bytes(usage?.deviceTotalBytes ?? 0)}'),
                        Text('数据库：${_bytes(usage?.databaseBytes ?? 0)}'),
                        Text('商品图片：${_bytes(usage?.mediaBytes ?? 0)}'),
                        const SizedBox(height: 8),
                        Text('条码缓存：${usage?.barcodeCacheEntries ?? 0} 条（${_bytes(usage?.barcodeCacheBytes ?? 0)}，已包含在数据库中）'),
                        Text('AI 用量日志：${_bytes(usage?.aiUsageLogBytes ?? 0)}（已包含在数据库中）'),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _cleanAll,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cleaning_services_outlined),
            label: Text(_busy ? '正在处理…' : '一键清理'),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_delete_outlined),
              title: const Text('清理过期条码缓存'),
              subtitle: const Text('删除已过期的条码查询结果。'),
              onTap: _busy ? null : _clearExpiredBarcodeCache,
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('清空全部条码缓存'),
              subtitle: const Text('仅删除扫码查询结果，不会删除商品或库存。'),
              onTap: _busy ? null : _clearAllBarcodeCache,
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.photo_size_select_actual_outlined),
              title: const Text('清理无用图片'),
              subtitle: const Text('删除未被商品引用的临时图片和无效记录。'),
              onTap: _busy ? null : _cleanUnusedMedia,
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('“清理缓存”不会删除库存、采购清单、历史记录或备份。若要迁移数据，请使用“数据备份与迁移”。'),
          ),
        ],
      ),
    );
  }
}

class PrivacySettingsScreen extends ConsumerStatefulWidget {
  const PrivacySettingsScreen({super.key});

  @override
  ConsumerState<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends ConsumerState<PrivacySettingsScreen> {
  int _configuredKeys = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Set<String>> _profileKeyIds() async {
    final settings = ref.read(settingsServiceProvider);
    final raw = await settings.getValue(AiDraftService.profilesKey);
    final ids = <String>{
      // These IDs were used by the initial fallback implementation. Keep
      // them in privacy controls until every old installation has migrated.
      'secondary_profile',
      'fallback_profile',
    };
    try {
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is List) {
        ids.addAll(
          decoded
              .whereType<Map>()
              .map((item) => item['id']?.toString() ?? '')
              .where((id) => id.isNotEmpty),
        );
      }
    } on FormatException {
      // Bad old profile data is handled by the AI settings page; the legacy
      // IDs above still let privacy controls clear any usable secret.
    }
    for (final settingKey in [
      AiDraftService.secondaryProfileIdKey,
      AiDraftService.fallbackProfileIdKey,
    ]) {
      final id = (await settings.getValue(settingKey))?.trim();
      if (id != null && id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  Future<void> _load() async {
    final secure = ref.read(secureSettingsServiceProvider);
    final profileIds = await _profileKeyIds();
    var count = (await secure.readAiApiKey())?.trim().isNotEmpty == true ? 1 : 0;
    for (final id in profileIds) {
      if ((await secure.readAiApiKeyForProfile(id))?.trim().isNotEmpty == true) count++;
    }
    if (mounted) {
      setState(() {
        _configuredKeys = count;
        _loading = false;
      });
    }
  }

  Future<void> _clearKeys() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除所有 AI 密钥？'),
        content: const Text('这会使 AI 解析和问答停止联网，直到你重新填写 API Key。服务地址和模型配置会保留。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('移除')),
        ],
      ),
    );
    if (approved != true) return;
    final secure = ref.read(secureSettingsServiceProvider);
    final profileIds = await _profileKeyIds();
    for (final id in profileIds) {
      await secure.deleteAiApiKeyForProfile(id);
    }
    await secure.deleteAiApiKey();
    await _load();
    if (mounted) showAppSnackBar(context, const SnackBar(content: Text('所有 AI 密钥已从设备安全存储中移除。')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('隐私与密钥')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('AI 服务密钥'),
                subtitle: Text(_loading ? '正在检查…' : '本设备已保存 $_configuredKeys 个密钥。密钥不会导出到 JSON 备份。'),
                trailing: TextButton(onPressed: _loading || _configuredKeys == 0 ? null : _clearKeys, child: const Text('全部移除')),
              ),
            ),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('本地数据与联网说明', style: TextStyle(fontWeight: FontWeight.bold)),
                    SizedBox(height: 8),
                    Text('库存、批次、采购清单、提醒状态和图片默认保存在本机。启用外部条码查询或 AI 服务后，条码、OCR 文本或提问内容会发送给你配置的主服务；主服务失败时，也可能发送给副服务或兜底服务。'),
                    SizedBox(height: 8),
                    Text('请只配置你信任的服务，并避免向外部 AI 服务发送不必要的个人或敏感信息。'),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

class AboutSettingsScreen extends ConsumerWidget {
  const AboutSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    return Scaffold(
        appBar: AppBar(title: const Text('关于嬷嬷的小箱子')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: palette.primary.withValues(alpha: 0.15),
                  child: Icon(palette.appLogoIcon, color: palette.primary),
                ),
                title: const Text('嬷嬷的小箱子'),
                subtitle: const Text('本地优先的家庭物品效期与库存管理工具'),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('版本号'),
                subtitle: const Text(MomoAppInfo.versionDisplay),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: const Text('数据存储与空间管理'),
                subtitle: const Text('核心数据仅保存于本机；可查看本地占用并清理条码与图片缓存。'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 14),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const StorageManagementScreen()),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('第三方许可'),
                subtitle: const Text('本应用使用 Flutter 及其开源依赖构建；完整许可信息随应用和依赖包提供。'),
              ),
            ),
          ],
        ),
      );
}
}
