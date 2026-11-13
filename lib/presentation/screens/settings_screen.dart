import '../widgets/nas_ai_models.dart';
import '../widgets/momo_mobile_layout.dart';
import '../../app/momo_typography.dart';
import 'nas_settings_screen.dart';
import 'home_assistant_settings_screen.dart';
import 'sync_settings_screen.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../widgets/app_feedback.dart';
import '../widgets/momo_components.dart';
import '../widgets/momo_floating_dock.dart';

import '../../app/momo_theme.dart';
import '../../application/barcode_lookup_service.dart';
import '../../application/storage_management_service.dart';
import '../../application/update_service.dart';
import '../../data/repositories/backup_repository.dart';
import '../../domain/backup/backup_format.dart';
import '../../services/local_notification_service.dart';
import '../../services/diagnostic_log_service.dart';
import '../controllers/providers.dart';
import 'ai_usage_screen.dart';
import 'statistics_screen.dart';

/// Quiet, grouped entry points; editing stays in the dedicated screens.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      left: false, right: false, bottom: false,
      child: ListView(
        key: const PageStorageKey('settings-overview'),
        padding: MomoMobileLayout.pageInsets(context).add(
          EdgeInsets.only(bottom: 20 + MomoDockInsets.bottomOf(context))),
        children: [
          MomoHouseholdBar(onPressed: () => _openSettingsPage(context,
            (_) => const SettingsCategoryScreen(category: SettingsCategory.household))),
          const MomoPageHeader(
            eyebrow: 'MAKE IT YOURS',
            title: '一切，按你喜欢。',
            subtitle: Text('你的家，你的习惯。'),
          ),
          MomoCard(
            margin: const EdgeInsets.only(bottom: 24),
            color: Theme.of(context).colorScheme.primaryContainer,
            onTap: () => _openSettingsPage(context,
              (_) => const SettingsCategoryScreen(category: SettingsCategory.household)),
            child: Row(children: [
              CircleAvatar(backgroundColor: Theme.of(context).colorScheme.surface,
                foregroundColor: Theme.of(context).colorScheme.primary,
                child: const Icon(Icons.home_outlined)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('我的小家', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('物品与日常，都在自己手里。', style: Theme.of(context).textTheme.bodySmall),
              ])),
              const Icon(Icons.chevron_right_rounded, size: 18),
            ]),
          ),
          _SettingsGroup(title: '智能与连接', children: [
            _SettingsLink(icon: Icons.auto_awesome_outlined, title: 'AI 服务',
              subtitle: '查看 NAS 模型与应用操作权限', destination: (_) => const AiSettingsScreen()),
            _SettingsLink(icon: Icons.hub_outlined, title: '家居连接',
              subtitle: 'Home Assistant 与设备', destination: (_) => const HomeAssistantSettingsScreen()),
            _categoryLink(SettingsCategory.household),
          ]),
          _SettingsGroup(title: '日常偏好', children: [
            _categoryLink(SettingsCategory.appearance),
            _SettingsLink(
              icon: Icons.notifications_active_outlined,
              title: '提醒与通知',
              subtitle: '权限与测试提醒',
              destination: (_) => const NotificationSettingsScreen(),
            ),
            _categoryLink(SettingsCategory.data),
          ]),
        ],
      ),
    ),
  );

  Widget _categoryLink(SettingsCategory category) => _SettingsLink(
    icon: category.icon,
    title: category.title,
    subtitle: category.summary,
    destination: (_) => SettingsCategoryScreen(category: category),
  );
}

enum SettingsCategory {
  appearance('外观与显示', '主题与字体大小', Icons.palette_outlined),
  intelligence('识别与用量', 'AI 调用记录与条码查询', Icons.qr_code_scanner),
  household('家庭与同步', 'NAS、家居连接与同步', Icons.home_outlined),
  data('数据与隐私', '统计、备份与安全', Icons.shield_outlined);

  const SettingsCategory(this.title, this.summary, this.icon);

  final String title;
  final String summary;
  final IconData icon;
}

/// A focused second-level list, with an ordinary back stack and no tab dock.
class SettingsCategoryScreen extends ConsumerWidget {
  const SettingsCategoryScreen({required this.category, super.key});

  final SettingsCategory category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = switch (category) {
      SettingsCategory.appearance => [
        _SettingsGroup(children: [
          _SettingsLink(
            icon: Icons.palette_outlined,
            title: '主题中心与个性化',
            subtitle: MomoPalette.fromStoredValue(
              ref.watch(themeNameProvider).valueOrNull).label,
            destination: (_) => const ThemeSettingsScreen(),
          ),
          _SettingsLink(
            icon: Icons.format_size_rounded,
            title: '界面字体大小',
            subtitle: '选择适合自己的阅读大小',
            destination: (_) => const FontScaleSettingsScreen(),
          ),
        ]),
      ],
      SettingsCategory.intelligence => [
        _SettingsGroup(title: 'AI 助手', children: [
          _SettingsLink(
            icon: Icons.analytics_outlined,
            title: 'AI 用量与日志汇总',
            subtitle: '查看 Token 用量与调用明细',
            destination: (_) => const AiUsageScreen(),
          ),
        ]),
        _SettingsGroup(title: '识别服务', children: [
          _SettingsLink(
            icon: Icons.qr_code_scanner,
            title: '外部条码 API 接口',
            subtitle: '管理查询接口与调用顺序',
            destination: (_) => const BarcodeSettingsScreen(),
          ),
        ]),
      ],
      SettingsCategory.household => [
        _SettingsGroup(title: '连接', children: [
          _SettingsLink(
            icon: Icons.dns_outlined,
            title: 'NAS 协同管理',
            subtitle: '服务地址、账号与家庭成员',
            destination: (_) => const NasSettingsScreen(),
          ),
          _SettingsLink(
            icon: Icons.hub_outlined,
            title: 'Home Assistant 连接配置',
            subtitle: '连接授权与设备权限',
            destination: (_) => const HomeAssistantSettingsScreen(),
          ),
        ]),
        _SettingsGroup(title: '同步', children: [
          _SettingsLink(
            icon: Icons.sync_outlined,
            title: '同步状态与冲突处理',
            subtitle: '首次同步、手动同步与冲突记录',
            destination: (_) => const SyncSettingsScreen(),
          ),
        ]),
      ],
      SettingsCategory.data => [
        _SettingsGroup(title: '本地数据', children: [
          _SettingsLink(
            icon: Icons.insert_chart_outlined,
            title: '库存统计',
            subtitle: '消耗、入库与报废趋势',
            destination: (_) => const StatisticsScreen(),
          ),
          _SettingsLink(
            icon: Icons.backup_outlined,
            title: '数据备份与迁移',
            subtitle: '核心数据 JSON 导出与合并导入',
            destination: (_) => const BackupSettingsScreen(),
          ),
        ]),
        _SettingsGroup(title: '隐私与诊断', children: [
          _SettingsLink(
            icon: Icons.shield_outlined,
            title: '隐私与密钥安全',
            subtitle: '了解凭证存储与数据边界',
            destination: (_) => const PrivacySettingsScreen(),
          ),
          _SettingsLink(
            icon: Icons.bug_report_outlined,
            title: '本地诊断导出',
            subtitle: '查看记录范围并导出脱敏诊断',
            destination: (_) => const DiagnosticExportScreen(),
          ),
        ]),
        _SettingsGroup(title: '识别与应用', children: [
          _SettingsLink(icon: SettingsCategory.intelligence.icon,
            title: SettingsCategory.intelligence.title,
            subtitle: SettingsCategory.intelligence.summary,
            destination: (_) => const SettingsCategoryScreen(category: SettingsCategory.intelligence)),
          _SettingsLink(icon: Icons.info_outline, title: '关于与存储信息',
            subtitle: '版本、空间与许可', destination: (_) => const AboutSettingsScreen()),
        ]),
      ],
    };
    return Scaffold(
      appBar: MomoAppBar.adaptive(context, title: Text(category.title)),
      body: ListView(
        key: PageStorageKey('settings-${category.name}'),
        padding: MomoMobileLayout.pageInsets(context).add(
          const EdgeInsets.only(top: 16, bottom: 24)),
        children: groups,
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(MomoTextSize.body) >
        MomoTextSize.body * 1.5;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Semantics(
                header: true,
                child: Text(title!, style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                )),
              ),
            ),
          Column(children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Divider(height: 1, indent: largeText ? 0 : 34),
                children[i],
              ],
            ]),
        ],
      ),
    );
  }
}

class _SettingsLink extends StatelessWidget {
  const _SettingsLink({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.destination,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder destination;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final largeText = MediaQuery.textScalerOf(context).scale(MomoTextSize.body) >
        MomoTextSize.body * 1.5;
    return ListTile(
      minTileHeight: 68,
      contentPadding: EdgeInsets.zero,
      horizontalTitleGap: 12,
      leading: largeText ? null : Icon(icon, size: 22, color: theme.colorScheme.primary),
      title: Text(title, style: theme.textTheme.titleMedium),
      subtitle: Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      )),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: () => _openSettingsPage(context, destination),
    );
  }
}

void _openSettingsPage(BuildContext context, WidgetBuilder destination) {
  final reduceMotion = MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context);
  Widget page(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    // Detail pages live above the shell. Reserve the system gesture area even
    // for existing screens with explicit ListView padding; no phantom dock gap.
    child: SafeArea(top: false, left: false, right: false, child: destination(context)),
  );
  final Route<void> route = reduceMotion
      ? PageRouteBuilder<void>(
          pageBuilder: (context, animation, secondaryAnimation) => page(context),
          transitionDuration: const Duration(milliseconds: 120),
          reverseTransitionDuration: const Duration(milliseconds: 120),
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              FadeTransition(opacity: animation, child: child),
        )
      : MaterialPageRoute<void>(builder: page);
  Navigator.of(context, rootNavigator: true).push(route);
}

class DiagnosticExportScreen extends StatefulWidget {
  const DiagnosticExportScreen({super.key});

  @override
  State<DiagnosticExportScreen> createState() => _DiagnosticExportScreenState();
}

class _DiagnosticExportScreenState extends State<DiagnosticExportScreen> {
  bool _busy = false;

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    final diagnostics = DiagnosticLogService.shared;
    try {
      final content = await diagnostics.exportJson();
      final temporary = await getTemporaryDirectory();
      final directory = Directory(p.join(temporary.path, 'diagnostic-export'));
      await directory.create(recursive: true);
      final file = File(p.join(directory.path, 'momobox-diagnostics.json'));
      await file.writeAsString(content, flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'MomoBox 脱敏诊断',
        text: 'MomoBox 本地 Dart/Flutter 错误诊断',
        sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (error, stack) {
      unawaited(diagnostics.record(DiagnosticEvent.diagnosticsExportFailed, error, stackTrace: stack));
      if (mounted) showAppSnackBar(context, const SnackBar(content: Text('诊断导出失败，请稍后重试。')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: MomoAppBar.adaptive(context, title: const Text('本地诊断导出')),
    body: ListView(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MomoDockInsets.bottomOf(context)),
      children: [
        const Card(child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('诊断只记录预定义错误事件、异常类型、项目模块及行列号和时间。'
              '不包含错误原文、库存或采购信息、AI 内容、URL、密钥或文件路径。'
              '\n\n最多保留 3 份、每份 64 KiB 的本地记录；导出后由你选择保存或分享位置。'
              '\n\n记录范围为 App 运行期间捕获到的 Dart/Flutter 错误，'
              '不涵盖原生崩溃、系统终止，也不保证故障发生前的异步记录已写入。'),
        )),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _export,
          icon: const Icon(Icons.ios_share),
          label: Text(_busy ? '正在导出…' : '导出脱敏诊断'),
        ),
      ],
    ),
  );
}

class ThemeSettingsScreen extends ConsumerWidget {
  const ThemeSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTheme = ref.watch(themeNameProvider).valueOrNull;

    return Scaffold(
      appBar: MomoAppBar.adaptive(context, title: const Text('主题中心')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MomoDockInsets.bottomOf(context)),
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
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: MomoTextSize.title),
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
                                  style: const TextStyle(color: Colors.white, fontSize: MomoTextSize.caption),
                                ),
                              ),
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
    final barcodeCtrl = TextEditingController(text: '3017620422003');
    bool testing = false;
    String? testResult;
    var role = item?[BarcodeLookupService.profileRoleKey] as String? ?? BarcodeLookupService.standbyRole;

    showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => _SwipeDismissProfileDialog(
        onDismiss: () => Navigator.pop(ctx),
        child: StatefulBuilder(
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
                TextField(controller: barcodeCtrl, keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '测试条码（仅点击测试时发送）')),
                if (testResult != null) Text(testResult!),
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
            TextButton(onPressed: testing ? null : () async {
              final endpoint = urlCtrl.text.trim();
              final barcode = barcodeCtrl.text.trim();
              final service = ref.read(barcodeLookupServiceProvider);
              setDialogState(() { testing = true; testResult = null; });
              String result;
              try {
                final product = await service.testEndpoint(endpoint, barcode);
                result = product == null ? '接口可用，但公共库未收录该条码；可继续手动录入。'
                    : '接口可用：${product.name ?? '已返回商品信息'}';
              } catch (_) {
                result = '测试失败，请检查条码格式、接口地址和网络。';
              }
              if (!context.mounted) return;
              setDialogState(() {
                testing = false;
                testResult = endpoint == urlCtrl.text.trim() && barcode == barcodeCtrl.text.trim()
                    ? result : '配置或条码已变化，请重新测试。';
              });
            }, child: Text(testing ? '测试中…' : '测试')),
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: MomoAppBar.adaptive(context, title: const Text('外部条码 API')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MomoDockInsets.bottomOf(context)),
        children: [
          SwitchListTile(
            title: const Text('启用外部条码查询'),
            subtitle: const Text('已预配 Open Food Facts 食品公共库，无需 Key；默认关闭，需主动启用。并非所有国内商品或非食品条码都有记录。开启后条码将发送给所选外部服务。'),
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
                    Text(_roleLabel(profile), style: const TextStyle(fontSize: MomoTextSize.caption)),
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

class AiSettingsScreen extends ConsumerWidget {
  const AiSettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar:MomoAppBar.adaptive(context,title:const Text('AI 模型与权限')),
    body:ListView(padding:const EdgeInsets.all(16),children:[
      const NasAiModels(),
      SwitchListTile.adaptive(title:const Text('允许 AI 提议应用操作'),
        subtitle:const Text('所有写操作仍须逐次确认。关闭后只读。'),
        value:ref.watch(aiInventoryPermissionProvider).valueOrNull ?? false,
        onChanged:(value)=>ref.read(settingsServiceProvider).setValue('ai_allow_inventory_writes',value.toString())),
    ]));
}

class BackupSettingsScreen extends ConsumerStatefulWidget {
  const BackupSettingsScreen({super.key});

  @override
  ConsumerState<BackupSettingsScreen> createState() => _BackupSettingsScreenState();
}

class _BackupSettingsScreenState extends ConsumerState<BackupSettingsScreen> {
  Object? _operationOwner;

  bool get _busy => _operationOwner != null;

  Object? _beginOperation() {
    // Guard before the first await, including callbacks from a stale build.
    if (!mounted || _busy) return null;
    final owner = Object();
    setState(() => _operationOwner = owner);
    return owner;
  }

  void _finishOperation(Object owner) {
    // A rejected/reentrant invocation must never unlock another operation.
    if (mounted && identical(_operationOwner, owner)) {
      setState(() => _operationOwner = null);
    }
  }

  Future<void> _exportBackup() async {
    final owner = _beginOperation();
    if (owner == null) return;
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
        text: 'MomoBox 核心数据 JSON 备份',
      );
    } catch (error) {
      if (mounted) {
        showAppSnackBar(context, SnackBar(content: Text('导出失败：$error')));
      }
    } finally {
      _finishOperation(owner);
    }
  }

  Future<void> _importBackup() async {
    if (ref.read(nasAppAccessProvider) != NasAppAccess.connected) {
      showAppSnackBar(context,const SnackBar(content:Text('恢复 NAS 连接后才能导入数据。')));
      return;
    }
    final owner = _beginOperation();
    if (owner == null) return;
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
          content: const Text('导入会补充缺失记录，并自动接入当前 NAS 家庭；相同 ID 的记录将跳过。图片/OCR 不会恢复，当前设备的登录和同步身份保持不变。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('开始导入')),
          ],
        ),
      );
      if (approved != true || !mounted) return;

      final service = ref.read(backupServiceProvider);
      final report = await service.importJson(content);
      try {
        if (mounted) await _showImportReport(report);
      } finally {
        await service.synchronizeRestoredData();
      }
    } on BackupImportException catch (error) {
      if (mounted) await _showImportFailures(error.failures);
    } on FormatException {
      if (mounted) {
        showAppSnackBar(context, const SnackBar(content: Text('文件不是有效的 UTF-8 JSON 备份。')));
      }
    } catch (error) {
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('导入失败：$error')));
    } finally {
      _finishOperation(owner);
    }
  }

  Future<void> _showImportReport(ImportReport report) => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('数据导入完成'),
          content: Text('成功导入 ${report.imported} 条记录；跳过 ${report.skipped - report.excludedSettings} 条重复记录、${report.excludedSettings} 条设备身份或不可迁移设置。'),
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
        appBar: MomoAppBar.adaptive(context, title: const Text('数据备份与迁移')),
        body: ListView(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MomoDockInsets.bottomOf(context)),
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('导出核心数据备份 (JSON)'),
                subtitle: const Text(BackupFormat.scopeDescription),
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
              child: Text('${BackupFormat.restoreDescription} 导入会先完整校验，失败不会写入部分数据。${BackupFormat.privacyDescription}'),
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
      appBar: MomoAppBar.adaptive(context, title: const Text('字体大小设置')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MomoDockInsets.bottomOf(context)),
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
                      style: TextStyle(fontSize: MomoTextSize.body),
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
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: MomoTextSize.body),
                  ),
                ),
                title: Text(
                  opt.label,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                subtitle: Text(opt.desc, style: const TextStyle(fontSize: MomoTextSize.caption)),
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

class _NotificationSettingsScreenState extends ConsumerState<NotificationSettingsScreen>
    with WidgetsBindingObserver {
  NotificationPermissionStatus _status = NotificationPermissionStatus.unavailable;
  bool _busy = true;
  bool _refreshAfterResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    if (_busy) {
      // Permission dialogs can resume the app before their Future completes.
      _refreshAfterResume = true;
      return;
    }
    setState(() => _busy = true);
    unawaited(_refreshStatus());
  }

  Future<void> _syncLatestNotifications() async {
    // Do not turn a loading acknowledgement stream into an empty list: that
    // would resurrect already handled reminders after granting permission.
    await Future.wait([
      ref.read(inventoryProvider.future),
      ref.read(reminderAcknowledgementsProvider.future),
    ], eagerError: true);
    if (!mounted) return;
    // Inventory may have changed while acknowledgements were loading.
    final items = ref.read(inventoryProvider).asData?.value;
    final acknowledgements = ref.read(reminderAcknowledgementsProvider).asData?.value;
    if (items == null || acknowledgements == null) {
      throw StateError('库存或提醒确认状态尚未就绪，请重试。');
    }
    await ref.read(localNotificationServiceProvider).sync(
      items,
      acknowledgements: acknowledgements,
    );
  }

  Future<void> _refreshStatus({
    bool permissionGranted = false,
    bool reschedule = true,
  }) async {
    if (!mounted) return;
    try {
      final status = await ref.read(localNotificationServiceProvider).permissionStatus();
      if (!mounted) return;
      setState(() => _status = status);
      if (reschedule && (permissionGranted || status == NotificationPermissionStatus.allowed)) {
        await _syncLatestNotifications();
      }
    } catch (error) {
      if (mounted) {
        showAppSnackBar(context, SnackBar(content: Text('无法刷新通知状态或重排提醒：$error')));
      }
    } finally {
      if (mounted) {
        final refreshAgain = _refreshAfterResume;
        _refreshAfterResume = false;
        setState(() => _busy = refreshAgain);
        if (refreshAgain) unawaited(_refreshStatus(reschedule: reschedule));
      }
    }
  }

  Future<void> _requestPermission() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    var granted = false;
    try {
      granted = await ref.read(localNotificationServiceProvider).requestPermission();
      if (mounted) {
        showAppSnackBar(context,
          SnackBar(content: Text(granted ? '通知权限已开启。' : '通知权限未开启，请在系统设置中允许通知。')),
        );
      }
    } catch (error) {
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('无法请求通知权限：$error')));
    } finally {
      if (mounted) await _refreshStatus(permissionGranted: granted);
    }
  }

  Future<void> _sendTest() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(localNotificationServiceProvider).showTestNotification();
      if (mounted) showAppSnackBar(context, const SnackBar(content: Text('测试通知已发送。')));
    } catch (error) {
      if (mounted) showAppSnackBar(context, SnackBar(content: Text('$error')));
    } finally {
      // Business sync cancels old schedules; do not cancel the test just sent.
      if (mounted) await _refreshStatus(reschedule: false);
    }
  }

  String get _statusLabel => switch (_status) {
        NotificationPermissionStatus.allowed => '已允许',
        NotificationPermissionStatus.denied => '未允许',
        NotificationPermissionStatus.unavailable => '暂时无法确认',
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: MomoAppBar.adaptive(context, title: const Text('提醒与通知')),
        body: ListView(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MomoDockInsets.bottomOf(context)),
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
      appBar: MomoAppBar.adaptive(
        context,
        title: const Text('数据与存储空间'),
        actions: [IconButton(onPressed: _busy ? null : _reload, icon: const Icon(Icons.refresh), tooltip: '刷新')],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MomoDockInsets.bottomOf(context)),
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

class PrivacySettingsScreen extends StatelessWidget {
  const PrivacySettingsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar:MomoAppBar.adaptive(context,title:const Text('隐私与服务')),
    body:const Padding(padding:EdgeInsets.all(16),child:Text(
      'App 必须连接 NAS 后端。库存与图片由家庭后端保存，手机保留缓存以便断网查看。'
      'AI 服务地址、模型网关与密钥只在 NAS Compose 配置；手机不保存 AI 密钥。'
      '发送前会说明获授权的文字上下文，模型建议不自动执行。HA 令牌由 NAS 加密保存。')));
}

class AboutSettingsScreen extends ConsumerStatefulWidget {
  const AboutSettingsScreen({super.key});

  @override
  ConsumerState<AboutSettingsScreen> createState() => _AboutSettingsScreenState();
}

class _AboutSettingsScreenState extends ConsumerState<AboutSettingsScreen> {
  late final UpdateService _updateService;
  bool _checking = false;
  bool _downloading = false;
  UpdateCheckResult? _checkResult;
  String? _updateMessage;
  double? _downloadProgress;
  File? _downloadedApk;

  @override
  void initState() {
    super.initState();
    _updateService = UpdateService();
  }

  @override
  void dispose() {
    _updateService.close();
    super.dispose();
  }

  Future<void> _checkForUpdates() async {
    if (_checking || _downloading) return;
    setState(() {
      _checking = true;
      _updateMessage = null;
    });
    try {
      final result = await _updateService.checkForUpdates();
      if (!mounted) return;
      setState(() {
        _checkResult = result;
        _downloadedApk = null;
        _checking = false;
        _updateMessage = result.hasUpdate
            ? '发现新版本 ${result.release!.version}'
            : '当前已是最新版本';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _updateMessage = '检测更新失败：$error';
      });
    }
  }

  Future<void> _downloadAndInstall() async {
    if (_checking || _downloading) return;
    final release = _checkResult?.release;
    if (release == null) return;
    if (!Platform.isAndroid) {
      try {
        await _updateService.openReleasePage(release.htmlUrl);
      } catch (error) {
        if (mounted) showAppSnackBar(context, SnackBar(content: Text('无法打开 Release 页面：$error')));
      }
      return;
    }

    setState(() {
      _downloading = true;
      _downloadProgress = null;
      _updateMessage = _downloadedApk == null ? '正在下载 APK…' : '正在准备安装…';
    });
    final File file;
    try {
      final downloaded = _downloadedApk;
      if (downloaded != null && await downloaded.exists()) {
        file = downloaded;
      } else {
        file = await _updateService.downloadApk(
          release,
          onProgress: (received, total) {
            if (!mounted || total <= 0) return;
            setState(() {
              _downloadProgress = (received / total).clamp(0.0, 1.0);
              if (received >= total) _updateMessage = '正在校验 APK…';
            });
          },
        );
      }
      if (!mounted) return;
      _downloadedApk = file;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _updateMessage = '安装包下载或校验失败：$error';
      });
      return;
    }

    setState(() {
      _downloadProgress = null;
      _updateMessage = 'APK 已下载，正在打开系统安装器…';
    });
    try {
      final result = await _updateService.installApk(file);
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _updateMessage = result == ApkInstallResult.permissionRequired
            ? 'APK 已下载。请在系统设置中允许安装此来源的应用，返回后点击“继续安装”，无需重新下载。'
            : '已打开系统安装器，请按系统提示完成安装。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _updateMessage = 'APK 已下载，但未能确认安装器已打开：$error。请先检查系统提示；若未打开，可点击“继续安装”重试，或打开发布页手动下载。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final release = _checkResult?.release;
    return Scaffold(
      appBar: MomoAppBar.adaptive(context, title: const Text('关于嬷嬷的小箱子')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MomoDockInsets.bottomOf(context)),
        children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                child: Icon(palette.appLogoIcon, color: Theme.of(context).colorScheme.primary),
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
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.system_update_outlined),
                          title: Text('检测更新'),
                          subtitle: Text('从 GitHub Releases 检查最新版本'),
                        ),
                      ),
                      TextButton(
                        onPressed: _checking || _downloading ? null : _checkForUpdates,
                        child: Text(_checking ? '检测中…' : '检查'),
                      ),
                    ],
                  ),
                  if (_updateMessage != null) ...[
                    const SizedBox(height: 4),
                    Text(_updateMessage!, style: TextStyle(fontSize: MomoTextSize.caption, color: Theme.of(context).colorScheme.primary)),
                  ],
                  if (release != null && _checkResult!.hasUpdate) ...[
                    const SizedBox(height: 10),
                    Text(
                      '${release.name} · ${release.publishedAt == null ? '' : _formatReleaseDate(release.publishedAt!)}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (release.body.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(release.body.trim(), maxLines: 5, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: MomoTextSize.caption)),
                    ],
                    const SizedBox(height: 10),
                    if (_downloading && _downloadProgress != null) LinearProgressIndicator(value: _downloadProgress),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: _checking || _downloading ? null : _downloadAndInstall,
                        icon: _downloading
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : Icon(Platform.isAndroid ? Icons.download : Icons.open_in_new),
                        label: Text(Platform.isAndroid
                            ? (_downloadedApk == null ? '下载并安装' : '继续安装')
                            : '打开 Release 页面'),
                      ),
                    ),
                    if (Platform.isAndroid)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _checking || _downloading ? null : () async {
                            try {
                              await _updateService.openReleasePage(release.htmlUrl);
                            } catch (error) {
                              if (context.mounted) showAppSnackBar(context, SnackBar(content: Text('无法打开发布页：$error')));
                            }
                          },
                          child: const Text('打开发布页手动下载'),
                        ),
                      ),
                  ],
                ],
              ),
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

  String _formatReleaseDate(DateTime date) {
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}

/// Capture an iOS-style right swipe across the modal (including its outer
/// margin), so the configuration page cannot be dismissed behind it.
class _SwipeDismissProfileDialog extends StatefulWidget {
  const _SwipeDismissProfileDialog({required this.onDismiss, required this.child});

  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<_SwipeDismissProfileDialog> createState() => _SwipeDismissProfileDialogState();
}

class _SwipeDismissProfileDialogState extends State<_SwipeDismissProfileDialog> {
  double _dragDistance = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragStart: (_) => _dragDistance = 0,
    onHorizontalDragUpdate: (details) => _dragDistance += details.delta.dx,
    onHorizontalDragEnd: (_) {
      if (_dragDistance > 80) widget.onDismiss();
      _dragDistance = 0;
    },
    child: SizedBox.expand(child: Center(child: widget.child)),
  );
}
