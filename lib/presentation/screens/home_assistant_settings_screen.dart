import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/momo_theme.dart';
import '../../domain/models/smart_home_models.dart';
import '../controllers/providers.dart';
import '../controllers/smart_home_controller.dart';

class HomeAssistantSettingsScreen extends ConsumerStatefulWidget {
  const HomeAssistantSettingsScreen({super.key});

  @override
  ConsumerState<HomeAssistantSettingsScreen> createState() => _HomeAssistantSettingsScreenState();
}

class _HomeAssistantSettingsScreenState extends ConsumerState<HomeAssistantSettingsScreen> {
  final _haUrlController = TextEditingController(text: 'http://homeassistant.local:8123');
  final _tokenController = TextEditingController(text: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.mock_token_secret');
  bool _isTesting = false;

  // 设备白名单勾选 Mock
  final Map<String, bool> _whitelist = {
    'media_player.living_room_tv (客厅电视)': true,
    'light.living_room_main (客厅主灯)': true,
    'climate.living_room_ac (客厅空调)': true,
    'switch.kitchen_ice_maker (厨房制冰机)': true,
    'washer.balcony_smart_washer (阳台洗衣机)': true,
    'lock.front_door (智能门锁 - 高风险)': false,
    'camera.living_room (客厅摄像头 - 隐私高风险)': false,
  };

  @override
  void dispose() {
    _haUrlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  void _testConnection() async {
    setState(() => _isTesting = true);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (mounted) {
      setState(() => _isTesting = false);
      ref.read(smartHomeControllerProvider.notifier).setHaConnectionStatus(HaConnectionStatus.online);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🎉 Home Assistant 授权与连接校验成功！已同步实体白名单。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final homeState = ref.watch(smartHomeControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Home Assistant 连接配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 状态卡片
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.hub_rounded, color: Colors.blue, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Home Assistant 集成', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                        Text(
                          homeState.haStatus == HaConnectionStatus.online ? '已授权连接 · 局域网 WebSocket 正常' : '未授权或离线',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('在线 (Mock)', style: TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 连接与 Token 配置
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('连接参数配置', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _haUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Home Assistant 地址',
                      hintText: 'http://homeassistant.local:8123',
                      prefixIcon: Icon(Icons.link_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _tokenController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '长期访问令牌 (Long-Lived Access Token)',
                      hintText: '输入在 HA 个人资料中创建的长期令牌',
                      prefixIcon: Icon(Icons.key_rounded),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: palette.primary),
                      onPressed: _isTesting ? null : _testConnection,
                      icon: _isTesting
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.verified_user_outlined),
                      label: const Text('校验 Token 并保存'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 实体白名单勾选卡片
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.checklist_rounded, size: 20),
                      const SizedBox(width: 8),
                      const Text('设备与实体安全白名单', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '只有勾选允许的设备才会展示在家居页并允许 AI 执行控制。高风险设备默认禁止 AI 触碰。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const Divider(height: 18),
                  ..._whitelist.entries.map((entry) {
                    final isHighRisk = entry.key.contains('高风险');
                    return CheckboxListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        entry.key,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isHighRisk ? FontWeight.normal : FontWeight.w600,
                          color: isHighRisk ? Colors.red.shade400 : null,
                        ),
                      ),
                      value: entry.value,
                      activeColor: palette.primary,
                      onChanged: (val) {
                        setState(() {
                          _whitelist[entry.key] = val ?? false;
                        });
                      },
                    );
                  }),
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
                  Text('安全与权限说明', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  SizedBox(height: 6),
                  Text(
                    '• MomoBox 仅在局域网内通过 NAS 后端与 HA 通信，令牌安全加密存储于 NAS。\n'
                    '• 不会向任何第三方云端上报家庭设备状态。\n'
                    '• 设备联动事件产生时，默认创建待确认扣减建议，避免误扣库存。',
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
