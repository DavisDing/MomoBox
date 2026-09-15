import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';

class HomeAssistantSettingsScreen extends ConsumerStatefulWidget {
  const HomeAssistantSettingsScreen({super.key});

  @override
  ConsumerState<HomeAssistantSettingsScreen> createState() => _HomeAssistantSettingsScreenState();
}

class _HomeAssistantSettingsScreenState extends ConsumerState<HomeAssistantSettingsScreen> {
  final _haUrlController = TextEditingController(text: 'http://homeassistant.local:8123');
  final _tokenController = TextEditingController();
  final bool _isTesting = false;

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

  void _testConnection() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('当前版本尚未支持 Home Assistant，未校验令牌、保存配置或连接设备。')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);

    return Scaffold(
      appBar: AppBar(title: const Text('Home Assistant 连接配置（规划中）')),
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
                          '当前版本尚未接入，配置仅供预览',
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
                    child: const Text('未支持', style: TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.bold)),
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
                    '以下为规划中的设备白名单示例，不代表真实设备或授权。勾选不会保存或启用控制。',
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
                    '• 当前版本未实现 NAS 与 HA 通信，请勿在预览页输入真实令牌。\n'
                    '• 不会向任何第三方云端上报家庭设备状态。\n'
                    '• 当前不会接收设备联动事件或自动扣减库存。',
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
