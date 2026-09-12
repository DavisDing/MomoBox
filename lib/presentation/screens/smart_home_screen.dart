import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/momo_theme.dart';
import '../../domain/models/smart_home_models.dart';
import '../controllers/providers.dart';
import '../controllers/smart_home_controller.dart';

class SmartHomeScreen extends ConsumerWidget {
  const SmartHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final homeState = ref.watch(smartHomeControllerProvider);
    final controller = ref.read(smartHomeControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.home_outlined, size: 24),
            const SizedBox(width: 8),
            const Text('智能家居与联动'),
            const Spacer(),
            _buildHaBadge(context, homeState.haStatus),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '刷新设备状态',
            icon: homeState.isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: homeState.isLoading ? null : () => controller.refresh(),
          ),
          IconButton(
            tooltip: 'HA 连接配置',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: homeState.haStatus == HaConnectionStatus.unconfigured
          ? _buildUnconfiguredState(context, palette)
          : RefreshIndicator(
              onRefresh: () => controller.refresh(),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // 1. 场景快捷区
                  _buildSectionHeader(
                    context,
                    title: '常用全屋场景',
                    subtitle: '一键联动控制多设备状态',
                    icon: Icons.auto_awesome_mosaic_outlined,
                  ),
                  const SizedBox(height: 10),
                  _buildScenesRow(context, homeState.scenes, palette),

                  const SizedBox(height: 24),

                  // 2. 耗材联动建议与日志入口 (洗衣机耗材、制冰机等)
                  _buildSectionHeader(
                    context,
                    title: '设备耗材联动与建议',
                    subtitle: '设备事件触发的库存建议与自动扣减日志',
                    icon: Icons.recycling_rounded,
                  ),
                  const SizedBox(height: 10),
                  _buildConsumableLinkageCard(context, ref, homeState.logs, palette),

                  const SizedBox(height: 24),

                  // 3. 房间与设备卡片 (客厅 / 厨房 / 阳台)
                  _buildSectionHeader(
                    context,
                    title: '房间设备控制',
                    subtitle: '已授权白名单设备控制项',
                    icon: Icons.devices_other_rounded,
                  ),
                  const SizedBox(height: 10),
                  _buildRoomsAndDevices(context, ref, homeState.devices, palette),

                  const SizedBox(height: 48),
                ],
              ),
            ),
    );
  }

  Widget _buildHaBadge(BuildContext context, HaConnectionStatus status) {
    final (label, color) = switch (status) {
      HaConnectionStatus.online => ('HA 已连接', Colors.green),
      HaConnectionStatus.syncing => ('同步中', Colors.blue),
      HaConnectionStatus.offline => ('HA 离线', Colors.orange),
      HaConnectionStatus.unconfigured => ('未配置', Colors.grey),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildUnconfiguredState(BuildContext context, MomoPalette palette) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hub_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('尚未连接 Home Assistant', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              '在「我的」->「Home Assistant 连接配置」中填写 HA 地址与授权令牌，即可在 MomoBox 中掌控全屋智能与设备耗材联动。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => context.push('/settings'),
              icon: const Icon(Icons.settings),
              label: const Text('前往配置连接'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ],
    );
  }

  Widget _buildScenesRow(BuildContext context, List<SmartScene> scenes, MomoPalette palette) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: scenes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final scene = scenes[index];
          return InkWell(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('已触发场景：【${scene.name}】（Mock执行成功）'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            borderRadius: BorderRadius.circular(16),
            child: Container(
              width: 120,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.05) : palette.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: 0.08) : palette.primary.withValues(alpha: 0.15),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(scene.icon, style: const TextStyle(fontSize: 24)),
                  const SizedBox(height: 6),
                  Text(
                    scene.name,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    scene.description,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildConsumableLinkageCard(
    BuildContext context,
    WidgetRef ref,
    List<ConsumableLinkageLog> logs,
    MomoPalette palette,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (logs.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('暂无耗材联动事件', style: theme.textTheme.bodySmall),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: logs.map((log) {
            final isPending = log.status == ConsumableActionStatus.pending;
            final isDeducted = log.status == ConsumableActionStatus.deducted;

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isPending
                    ? (isDark ? Colors.amber.withValues(alpha: 0.1) : Colors.amber.withValues(alpha: 0.08))
                    : (isDark ? Colors.white.withValues(alpha: 0.02) : Colors.grey.withValues(alpha: 0.05)),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isPending ? Colors.amber.withValues(alpha: 0.3) : Colors.transparent,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isPending ? Icons.pending_actions_rounded : Icons.check_circle_outline,
                        color: isPending ? Colors.amber.shade800 : Colors.green,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          log.ruleDescription,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: (isPending ? Colors.amber : (isDeducted ? Colors.green : Colors.grey)).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isPending ? '待确认' : (isDeducted ? '已自动扣减' : '已忽略'),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isPending ? Colors.amber.shade900 : (isDeducted ? Colors.green : Colors.grey),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${log.deviceName} · ${log.eventSummary}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        '耗材建议：${log.consumableName} × ${log.quantity} ${log.unit}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: palette.primary,
                        ),
                      ),
                      const Spacer(),
                      if (isPending) ...[
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () {
                            ref.read(smartHomeControllerProvider.notifier).ignoreConsumableLog(log.id);
                          },
                          child: const Text('忽略', style: TextStyle(fontSize: 11)),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () {
                            ref.read(smartHomeControllerProvider.notifier).confirmConsumableLog(log.id);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('已确认扣减【${log.consumableName}】${log.quantity}${log.unit}，库存已更新！'),
                              ),
                            );
                          },
                          child: const Text('确认扣减', style: TextStyle(fontSize: 11)),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildRoomsAndDevices(
    BuildContext context,
    WidgetRef ref,
    List<SmartDevice> devices,
    MomoPalette palette,
  ) {
    final rooms = ['客厅', '厨房', '阳台'];

    return Column(
      children: rooms.map((room) {
        final roomDevices = devices.where((d) => d.room == room).toList();
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                child: Row(
                  children: [
                    Text(
                      room,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '(${roomDevices.length} 个设备)',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              ...roomDevices.map((dev) => _buildDeviceCard(context, ref, dev, palette)),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDeviceCard(
    BuildContext context,
    WidgetRef ref,
    SmartDevice device,
    MomoPalette palette,
  ) {
    final theme = Theme.of(context);
    final controller = ref.read(smartHomeControllerProvider.notifier);

    final icon = switch (device.type) {
      DeviceType.tv => Icons.tv_rounded,
      DeviceType.light => Icons.lightbulb_outline_rounded,
      DeviceType.climate => Icons.ac_unit_rounded,
      DeviceType.iceMaker => Icons.kitchen_rounded,
      DeviceType.washer => Icons.local_laundry_service_rounded,
      DeviceType.switchDevice => Icons.power_settings_new_rounded,
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (device.isOn ? palette.primary : Colors.grey).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    color: device.isOn ? palette.primary : Colors.grey,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        device.statusText,
                        style: TextStyle(
                          fontSize: 12,
                          color: device.isOn ? palette.primary : theme.textTheme.bodySmall?.color,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: device.isOn,
                  activeTrackColor: palette.primary,
                  onChanged: (val) {
                    controller.toggleDevice(device.id);
                  },
                ),
              ],
            ),

            // 空调专属温度调节
            if (device.type == DeviceType.climate && device.isOn) ...[
              const Divider(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('温度设置 (${device.mode})', style: const TextStyle(fontSize: 12)),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, size: 22),
                        onPressed: () => controller.updateClimateTemperature(device.id, -1.0),
                      ),
                      Text(
                        '${device.temperature.toStringAsFixed(0)}°C',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline, size: 22),
                        onPressed: () => controller.updateClimateTemperature(device.id, 1.0),
                      ),
                    ],
                  ),
                ],
              ),
            ],

            // 灯光专属亮度调节
            if (device.type == DeviceType.light && device.isOn) ...[
              const Divider(height: 16),
              Row(
                children: [
                  const Icon(Icons.brightness_low, size: 16, color: Colors.grey),
                  Expanded(
                    child: Slider(
                      value: device.brightness.toDouble(),
                      min: 1,
                      max: 100,
                      activeColor: palette.primary,
                      onChanged: (val) {
                        controller.updateLightBrightness(device.id, val.toInt());
                      },
                    ),
                  ),
                  Text('${device.brightness}%', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
