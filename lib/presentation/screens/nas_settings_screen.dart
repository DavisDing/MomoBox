import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/momo_theme.dart';
import '../../application/nas_connection_service.dart';
import '../controllers/providers.dart';
import '../widgets/app_feedback.dart';

class NasSettingsScreen extends ConsumerStatefulWidget {
  const NasSettingsScreen({super.key});

  @override
  ConsumerState<NasSettingsScreen> createState() => _NasSettingsScreenState();
}

class _NasSettingsScreenState extends ConsumerState<NasSettingsScreen> {
  final _serverUrlController = TextEditingController();
  final _familyCodeController = TextEditingController();
  bool _autoSync = true;
  bool _syncImages = true;
  bool _controllersInitialized = false;

  @override
  void dispose() {
    _serverUrlController.dispose();
    _familyCodeController.dispose();
    super.dispose();
  }

  String _statusTitle(NasConnectionState state) {
    return switch (state.status) {
      NasConnectionStatus.unconfigured => '未配置',
      NasConnectionStatus.checking => '连接中',
      NasConnectionStatus.connected => '已连接',
      NasConnectionStatus.unavailable => '服务不可用',
      NasConnectionStatus.failed => '连接失败',
    };
  }

  Color _statusColor(BuildContext context, NasConnectionStatus status) {
    return switch (status) {
      NasConnectionStatus.connected => Colors.green,
      NasConnectionStatus.checking => Theme.of(context).colorScheme.primary,
      NasConnectionStatus.unconfigured => Colors.blueGrey,
      NasConnectionStatus.unavailable || NasConnectionStatus.failed => Colors.orange,
    };
  }

  Future<void> _testConnection() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await ref.read(nasConnectionProvider.notifier).refresh(
          serverUrl: _serverUrlController.text,
          familyCode: _familyCodeController.text,
        );
    if (!mounted) return;
    final state = ref.read(nasConnectionProvider);
    showAppSnackBar(
      context,
      SnackBar(content: Text(state.message ?? _statusTitle(state))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final state = ref.watch(nasConnectionProvider);
    final statusColor = _statusColor(context, state.status);

    if (!_controllersInitialized && state.serverUrl.isNotEmpty) {
      _serverUrlController.text = state.serverUrl;
      _familyCodeController.text = state.familyCode;
      _controllersInitialized = true;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('NAS 协同与家庭共享')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.dns_rounded, color: statusColor, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('NAS 协同服务', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        const SizedBox(height: 4),
                        Text(
                          state.serverUrl.isEmpty ? '配置服务地址后进行真实健康检查' : state.serverUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _statusTitle(state),
                      style: TextStyle(fontSize: 12, color: statusColor, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('NAS 服务端配置', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _serverUrlController,
                    decoration: const InputDecoration(
                      labelText: 'NAS 服务器地址',
                      hintText: 'http://192.168.x.x:8080',
                      prefixIcon: Icon(Icons.link_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _familyCodeController,
                    decoration: const InputDecoration(
                      labelText: '家庭组识别码 / 邀请码（可选）',
                      hintText: '如 MOMO-FAMILY-888',
                      prefixIcon: Icon(Icons.group_work_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('局域网自动双向同步', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('保存偏好；具体同步由 NAS 账户与同步协议状态决定', style: TextStyle(fontSize: 12)),
                    value: _autoSync,
                    activeTrackColor: palette.primary,
                    onChanged: (v) => setState(() => _autoSync = v),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('同步物资照片与包装原图', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('保存偏好；服务端未开放媒体同步时不会上传', style: TextStyle(fontSize: 12)),
                    value: _syncImages,
                    activeTrackColor: palette.primary,
                    onChanged: (v) => setState(() => _syncImages = v),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: palette.primary),
                      onPressed: state.status == NasConnectionStatus.checking ? null : _testConnection,
                      icon: state.status == NasConnectionStatus.checking
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.network_check_rounded),
                      label: Text(state.status == NasConnectionStatus.checking ? '检测中…' : '测试并保存 NAS 连接'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('当前接入范围', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 6),
                  Text(
                    '客户端现在会调用 NAS 的 /api/v1/health 进行真实可用性检测，并将检测结果用于首页状态展示。后端 Docker 服务已纳入部署链路；库存同步、家庭成员认证和设备控制仍以服务端 API 实际开放能力为准。',
                    style: TextStyle(fontSize: 12, height: 1.5, color: Theme.of(context).textTheme.bodySmall?.color),
                  ),
                  if (state.message != null) ...[
                    const SizedBox(height: 8),
                    Text(state.message!, style: TextStyle(fontSize: 12, color: statusColor)),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
