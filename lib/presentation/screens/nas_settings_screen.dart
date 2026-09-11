import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';
import '../controllers/smart_home_controller.dart';

class NasSettingsScreen extends ConsumerStatefulWidget {
  const NasSettingsScreen({super.key});

  @override
  ConsumerState<NasSettingsScreen> createState() => _NasSettingsScreenState();
}

class _NasSettingsScreenState extends ConsumerState<NasSettingsScreen> {
  final _serverUrlController = TextEditingController(text: 'http://192.168.31.200:8080');
  final _familyCodeController = TextEditingController(text: 'MOMO-FAMILY-888');
  bool _autoSync = true;
  bool _syncImages = true;
  bool _isConnecting = false;

  @override
  void dispose() {
    _serverUrlController.dispose();
    _familyCodeController.dispose();
    super.dispose();
  }

  void _testConnection() async {
    setState(() => _isConnecting = true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      setState(() => _isConnecting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🎉 NAS 协同服务连接测试成功！(Mock 在线)')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('NAS 协同与家庭共享')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.dns_rounded, color: Colors.green, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('局域网 NAS 协同状态', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            Text('绿联 DX4600 Docker · 在线', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text('已连接 (Mock)', style: TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.bold)),
                      ),
                    ],
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
                      labelText: '家庭组识别码 / 邀请码',
                      hintText: '如 MOMO-FAMILY-888',
                      prefixIcon: Icon(Icons.group_work_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('局域网自动双向同步', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('本地变动实时上传至 NAS，避免多设备冲突', style: TextStyle(fontSize: 12)),
                    value: _autoSync,
                    activeColor: palette.primary,
                    onChanged: (v) => setState(() => _autoSync = v),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('同步物资照片与包装原图', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('将说明书与入库图片同步存储到 NAS', style: TextStyle(fontSize: 12)),
                    value: _syncImages,
                    activeColor: palette.primary,
                    onChanged: (v) => setState(() => _syncImages = v),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: palette.primary),
                      onPressed: _isConnecting ? null : _testConnection,
                      icon: _isConnecting
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.network_check_rounded),
                      label: const Text('测试并保存 NAS 连接'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('家庭成员与协同说明', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  SizedBox(height: 6),
                  Text(
                    '• 当前账号：家政主管（管理员）\n'
                    '• 共享模式：单机本地优先，断网无缝离线读写；联网后由 NAS 后端自动处理协同与变更日志。\n'
                    '（当前为前端 Mock 交互，等待全栈 Agent 接入 Docker 后端服务）',
                    style: TextStyle(fontSize: 12, height: 1.5, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
