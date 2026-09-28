import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/momo_theme.dart';
import '../../application/nas_connection_service.dart';
import '../../domain/models/nas_homeassistant_models.dart';
import '../../domain/models/smart_home_models.dart';
import '../controllers/providers.dart';
import '../controllers/smart_home_controller.dart';

class HomeAssistantSettingsScreen extends ConsumerStatefulWidget {
  const HomeAssistantSettingsScreen({super.key});

  @override
  ConsumerState<HomeAssistantSettingsScreen> createState() => _HomeAssistantSettingsScreenState();
}

class _HomeAssistantSettingsScreenState extends ConsumerState<HomeAssistantSettingsScreen> {
  final _nameController = TextEditingController(text: 'Home Assistant');
  final _haUrlController = TextEditingController();
  final _tokenController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _hydratedIntegrationId;
  bool _formDirty = false;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_markFormDirty);
    _haUrlController.addListener(_markFormDirty);
    _tokenController.addListener(_markFormDirty);
  }

  @override
  void dispose() {
    _nameController
      ..removeListener(_markFormDirty)
      ..dispose();
    _haUrlController
      ..removeListener(_markFormDirty)
      ..dispose();
    _tokenController
      ..removeListener(_markFormDirty)
      ..dispose();
    super.dispose();
  }

  void _markFormDirty() {
    if (!_formDirty) _formDirty = true;
  }

  void _hydrateFromState(SmartHomeState homeState) {
    final integration = homeState.integrations.firstOrNull;
    if (integration == null || _formDirty || _hydratedIntegrationId == integration.id) return;

    _nameController.text = integration.name;
    _haUrlController.text = integration.baseUrl.toString();
    // The NAS API never returns the stored token. It must be entered again
    // when saving an existing integration, so it is never exposed in the UI.
    _tokenController.clear();
    _formDirty = false;
    _hydratedIntegrationId = integration.id;
  }

  Uri? _parseHaUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.port != -1 && (uri.port < 1 || uri.port > 65535))) {
      return null;
    }
    return uri.replace(path: '', query: '', fragment: '');
  }

  Future<void> _saveIntegration() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final url = _parseHaUrl(_haUrlController.text);
    if (url == null) return;

    final controller = ref.read(smartHomeControllerProvider.notifier);
    await controller.configureIntegration(
      name: _nameController.text.trim(),
      baseUrl: url,
      accessToken: _tokenController.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _formDirty = false;
      _hydratedIntegrationId = ref.read(smartHomeControllerProvider).integrations.firstOrNull?.id;
    });
  }

  Future<void> _testIntegration() async {
    await ref.read(smartHomeControllerProvider.notifier).testIntegration();
  }

  Future<void> _refresh() async {
    await ref.read(smartHomeControllerProvider.notifier).refresh();
  }

  NasHaEntityPermission? _permissionFor(SmartHomeState state, NasHaEntity entity) {
    return state.permissions.where((permission) {
      return permission.integrationId == entity.integrationId && permission.entityId == entity.entityId;
    }).firstOrNull;
  }

  NasHaEntityState? _stateFor(SmartHomeState state, NasHaEntity entity) {
    return state.entityStates['${entity.integrationId}::${entity.entityId}'];
  }

  Future<void> _updatePermission(
    NasHaEntityPermission permission, {
    bool? canView,
    bool? canControl,
  }) async {
    final nextCanView = canView ?? permission.canView;
    final nextCanControl = nextCanView ? (canControl ?? permission.canControl) : false;
    await ref.read(smartHomeControllerProvider.notifier).updatePermission(
          NasHaEntityPermission(
            integrationId: permission.integrationId,
            entityId: permission.entityId,
            role: permission.role,
            canView: nextCanView,
            canControl: nextCanControl,
            allowedCommands: permission.allowedCommands,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final homeState = ref.watch(smartHomeControllerProvider);
    final nasState = ref.watch(nasConnectionProvider);
    _hydrateFromState(homeState);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Home Assistant 连接配置'),
        actions: [
          IconButton(
            tooltip: '刷新集成、实体和权限',
            onPressed: homeState.isLoading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildStatusCard(homeState, nasState),
          const SizedBox(height: 12),
          if (homeState.message != null || homeState.commandError != null)
            _buildFeedbackCard(homeState),
          if (homeState.message != null || homeState.commandError != null) const SizedBox(height: 12),
          _buildConnectionForm(homeState, palette),
          const SizedBox(height: 12),
          _buildEntitiesCard(homeState, palette),
          const SizedBox(height: 12),
          _buildSecurityCard(),
        ],
      ),
    );
  }

  Widget _buildStatusCard(SmartHomeState state, NasConnectionState nasState) {
    final status = _statusPresentation(state, nasState);
    final integration = state.integrations.firstOrNull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: status.color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.hub_rounded, color: status.color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Home Assistant 集成', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 4),
                  Text(status.description, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  if (integration != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '${integration.name} · ${integration.baseUrl}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: status.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                status.label,
                style: TextStyle(fontSize: 11, color: status.color, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  ({String label, String description, Color color}) _statusPresentation(
    SmartHomeState state,
    NasConnectionState nasState,
  ) {
    if (nasState.status != NasConnectionStatus.connected && !state.nasOnline) {
      return (
        label: '需先连接 NAS',
        description: '请先在 NAS 设置中登录并连接服务器。',
        color: Colors.orange,
      );
    }
    switch (state.haStatus) {
      case HaConnectionStatus.online:
        return (label: '在线', description: 'Home Assistant 连接正常，实体状态来自 NAS。', color: Colors.green);
      case HaConnectionStatus.stale:
        return (label: '状态过期', description: '已连接，但部分实体状态可能不是最新状态。', color: Colors.orange);
      case HaConnectionStatus.syncing:
        return (label: '连接中', description: '正在从 NAS 读取 Home Assistant 集成和实体。', color: Colors.blue);
      case HaConnectionStatus.offline:
        return (label: '离线', description: 'NAS 已连接，但 Home Assistant 当前不可用。', color: Colors.red);
      case HaConnectionStatus.unconfigured:
        return (label: '未配置', description: '尚未保存 Home Assistant 集成配置。', color: Colors.grey);
    }
  }

  Widget _buildFeedbackCard(SmartHomeState state) {
    final isError = state.commandError != null || state.haStatus == HaConnectionStatus.offline;
    final text = state.commandError ?? state.message!;
    return Card(
      color: (isError ? Colors.red : Colors.blue).withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
                size: 20, color: isError ? Colors.red : Colors.blue),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 12, height: 1.4))),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionForm(SmartHomeState state, MomoPalette palette) {
    final isLoading = state.isLoading;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('连接参数配置', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 6),
              const Text(
                '配置会保存到已连接的 NAS；令牌由 NAS 保管，页面不会回显已有令牌。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nameController,
                enabled: !isLoading,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '连接名称',
                  hintText: '例如：家里的 Home Assistant',
                  prefixIcon: Icon(Icons.label_outline_rounded),
                ),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return '请输入连接名称。';
                  if (text.length > 120) return '连接名称不能超过 120 个字符。';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _haUrlController,
                enabled: !isLoading,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Home Assistant 地址',
                  hintText: 'http://homeassistant.local:8123',
                  prefixIcon: Icon(Icons.link_rounded),
                ),
                validator: (value) => _parseHaUrl(value ?? '') == null
                    ? '请输入有效的 http(s) 地址，不要包含路径、查询参数或片段。'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tokenController,
                enabled: !isLoading,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: '长期访问令牌',
                  hintText: '新建或更新配置时重新输入令牌',
                  prefixIcon: Icon(Icons.key_rounded),
                ),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.length < 16) return '请输入有效的长期访问令牌。';
                  if (text.length > 4096) return '令牌长度超过限制。';
                  if (text.contains(RegExp(r'[\u0000-\u001F\u007F]'))) return '令牌不能包含控制字符。';
                  return null;
                },
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: palette.primary),
                      onPressed: isLoading ? null : _saveIntegration,
                      icon: isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.save_outlined),
                      label: const Text('保存配置'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isLoading || state.integrations.isEmpty ? null : _testIntegration,
                      icon: const Icon(Icons.network_check_rounded),
                      label: const Text('测试连接'),
                    ),
                  ),
                ],
              ),
              if (isLoading) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEntitiesCard(SmartHomeState state, MomoPalette palette) {
    final entities = state.entities;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.checklist_rounded, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('实体权限与状态', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                if (entities.isNotEmpty) Text('${entities.length} 个实体', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              '实体来自 NAS 的真实发现结果。权限开关只修改 NAS 侧白名单，不会直接向 Home Assistant 发送未授权服务调用。',
              style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.4),
            ),
            const Divider(height: 20),
            if (state.isLoading && entities.isEmpty)
              const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
            else if (state.integrations.isEmpty)
              const _EmptyHint(icon: Icons.settings_input_component_outlined, text: '保存 Home Assistant 配置后，这里会显示已发现的实体。')
            else if (state.haStatus == HaConnectionStatus.offline && entities.isEmpty)
              const _EmptyHint(icon: Icons.cloud_off_outlined, text: 'Home Assistant 当前离线，暂时无法读取实体。')
            else if (entities.isEmpty)
              const _EmptyHint(icon: Icons.devices_other_outlined, text: '当前没有可显示的实体，或账号没有查看权限。')
            else
              ...entities.map((entity) => _buildEntityTile(state, entity, palette)),
          ],
        ),
      ),
    );
  }

  Widget _buildEntityTile(SmartHomeState state, NasHaEntity entity, MomoPalette palette) {
    final permission = _permissionFor(state, entity);
    final remoteState = _stateFor(state, entity);
    final key = '${entity.integrationId}::${entity.entityId}';
    final stale = state.staleEntityIds.contains(key);
    final denied = state.accessDeniedEntityIds.contains(key);
    final currentState = remoteState?.state ?? entity.currentState ?? '暂无状态';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
        leading: Icon(_entityIcon(entity.domain), color: palette.primary),
        title: Text(entity.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        subtitle: Text(
          '${entity.entityId} · ${stale ? '状态可能过期' : _localizedEntityState(currentState)}',
          style: TextStyle(fontSize: 11, color: stale || denied ? Colors.orange : Colors.grey),
        ),
        trailing: _permissionBadge(permission, denied),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _statusChip('域：${entity.domain}'),
                if (entity.areaName?.trim().isNotEmpty == true) _statusChip('区域：${entity.areaName}'),
                if (remoteState != null) _statusChip('读取：${_formatTime(remoteState.fetchedAt)}'),
                if (entity.isControllable) _statusChip('支持控制') else _statusChip('只读'),
              ],
            ),
          ),
          if (permission == null)
            const ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.lock_outline, size: 18),
              title: Text('未返回此实体的权限记录', style: TextStyle(fontSize: 12)),
              subtitle: Text('当前不会在客户端推断或扩大权限。', style: TextStyle(fontSize: 11)),
            )
          else ...[
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('允许查看状态', style: TextStyle(fontSize: 12)),
              subtitle: Text('角色：${permission.role}', style: const TextStyle(fontSize: 11)),
              value: permission.canView,
              activeThumbColor: palette.primary,
              onChanged: state.isLoading ? null : (value) => _updatePermission(permission, canView: value),
            ),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('允许控制实体', style: TextStyle(fontSize: 12)),
              subtitle: Text(
                permission.allowedCommands.isEmpty
                    ? '服务端未开放具体 typed command'
                    : '允许命令：${permission.allowedCommands.join('、')}',
                style: const TextStyle(fontSize: 11),
              ),
              value: permission.canControl,
              activeThumbColor: palette.primary,
              onChanged: state.isLoading || !permission.canView
                  ? null
                  : (value) => _updatePermission(permission, canControl: value),
            ),
          ],
        ],
      ),
    );
  }

  Widget _permissionBadge(NasHaEntityPermission? permission, bool denied) {
    final label = denied
        ? '无权限'
        : permission == null
            ? '未返回'
            : permission.canControl
                ? '可控制'
                : permission.canView
                    ? '只读'
                    : '隐藏';
    final color = denied || permission == null
        ? Colors.orange
        : permission.canControl
            ? Colors.green
            : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold)),
    );
  }

  Widget _statusChip(String text) {
    return Chip(
      label: Text(text, style: const TextStyle(fontSize: 10)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
    );
  }

  IconData _entityIcon(String domain) {
    switch (domain) {
      case 'light':
        return Icons.lightbulb_outline_rounded;
      case 'media_player':
        return Icons.tv_rounded;
      case 'climate':
        return Icons.thermostat_rounded;
      case 'switch':
        return Icons.toggle_on_outlined;
      case 'washer':
        return Icons.local_laundry_service_outlined;
      case 'lock':
        return Icons.lock_outline_rounded;
      case 'camera':
        return Icons.videocam_outlined;
      default:
        return Icons.devices_other_outlined;
    }
  }

  String _localizedEntityState(String value) {
    const labels = <String, String>{
      'on': '已开启',
      'off': '已关闭',
      'playing': '播放中',
      'paused': '已暂停',
      'idle': '空闲',
      'heat': '制热',
      'cool': '制冷',
      'dry': '除湿',
      'fan_only': '送风',
      'auto': '自动',
      'unavailable': '设备离线',
      'unknown': '状态未知',
    };
    return labels[value.toLowerCase()] ?? value;
  }

  String _formatTime(DateTime value) {
    final local = value.toLocal();
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  Widget _buildSecurityCard() {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('安全与权限说明', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 6),
            Text(
              '• Home Assistant 长期访问令牌只提交给已登录的 NAS，并由 NAS 保存；本页面不会显示已保存的令牌。\n'
              '• 实体控制必须同时经过 NAS 权限和 typed command 白名单，客户端不会发送 raw service_data。\n'
              '• Home Assistant 离线、状态过期或权限不足时，页面会明确显示状态，不会伪造在线或执行成功。\n'
              '• 场景、脚本、洗衣机事件和库存自动扣减目前没有接入本页面。',
              style: TextStyle(fontSize: 12, height: 1.5, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.4))),
        ],
      ),
    );
  }
}
