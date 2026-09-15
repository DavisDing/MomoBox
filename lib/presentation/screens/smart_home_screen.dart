import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/momo_theme.dart';
import '../../domain/models/inventory_models.dart';
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
            const Text('智能家居'),
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
                    subtitle: '已授权白名单设备控制项（点击卡片查看高级控制）',
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

    // 展示常用4个场景为两行各两个网格
    final displayScenes = scenes.take(4).toList();

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: 80,
      ),
      itemCount: displayScenes.length,
      itemBuilder: (context, index) {
        final scene = displayScenes[index];
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('已触发场景：【${scene.name}】执行指令已下发'),
                ),
              );
            },
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withValues(alpha: 0.05) : palette.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark ? Colors.white.withValues(alpha: 0.08) : palette.primary.withValues(alpha: 0.15),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: palette.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(scene.icon, style: const TextStyle(fontSize: 22)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          scene.name,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          scene.description,
                          style: TextStyle(
                            fontSize: 10,
                            color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
                          onPressed: () async {
                            await _handleConfirmConsumableWithValidation(context, ref, log);
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

  /// 严格校验真实库存扣减
  Future<void> _handleConfirmConsumableWithValidation(
    BuildContext context,
    WidgetRef ref,
    ConsumableLinkageLog log,
  ) async {
    final inventoryRepo = ref.read(inventoryRepositoryProvider);
    final shoppingService = ref.read(shoppingServiceProvider);

    // 查询所有库存物品
    final allItems = await inventoryRepo.loadInventory();

    // 匹配名称包含消耗品关键词的有效物品（如 浓缩洗衣液 -> 洗衣液）
    final cleanTarget = log.consumableName.replaceAll(RegExp(r'^(浓缩|特级|强效|天然|家用)'), '').trim();

    InventoryItem? matchedItem;
    for (final item in allItems) {
      if (item.name == log.consumableName ||
          item.name.contains(cleanTarget) ||
          cleanTarget.contains(item.name)) {
        matchedItem = item;
        break;
      }
    }

    final availableQty = matchedItem?.availableQuantity ?? 0;

    if (matchedItem == null || availableQty < log.quantity) {
      // 库存中不存在或可用数量不足，拒绝假扣减，弹出提示并可直接加入采买清单
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange),
              SizedBox(width: 8),
              Text('库存不足或物资未建档', style: TextStyle(fontSize: 16)),
            ],
          ),
          content: Text(
            matchedItem == null
                ? '在当前库存中未找到【${log.consumableName}】。

是否需要将其一键添加到待采买清单？'
                : '【${matchedItem.name}】当前可用库存为 $availableQty ${matchedItem.unit}，不足以扣减 ${log.quantity} ${log.unit}。

是否添加到待采买清单？',
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(dialogCtx).pop();
                await shoppingService.addOrMerge(
                  itemName: log.consumableName,
                  targetQuantity: log.quantity > 1 ? log.quantity : 2,
                  reason: '智能家居设备耗材联动补货提醒',
                  productId: matchedItem?.id,
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('已将【${log.consumableName}】加入采买清单'),
                    ),
                  );
                }
              },
              child: const Text('加入采买清单'),
            ),
          ],
        ),
      );
      return;
    }

    // 库存真实充足，执行 FEFO 扣减
    try {
      await inventoryRepo.consumeByFefo(matchedItem.id, log.quantity);
      ref.read(smartHomeControllerProvider.notifier).confirmConsumableLog(log.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功核销【${matchedItem.name}】× ${log.quantity} ${matchedItem.unit}，剩余可用：${availableQty - log.quantity}'),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('库存扣减失败: $e')),
        );
      }
    }
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
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showDeviceControlSheet(context, ref, device, palette),
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
                        Row(
                          children: [
                            Text(
                              device.name,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.tune_rounded, size: 14, color: Colors.grey),
                          ],
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

              // 空调专属模式与快捷温度调节
              if (device.type == DeviceType.climate && device.isOn) ...[
                const Divider(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: palette.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            device.mode,
                            style: TextStyle(fontSize: 11, color: palette.primary, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text('风速: ${device.windSpeed}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                    Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.remove_circle_outline, size: 20),
                          onPressed: () => controller.updateClimateTemperature(device.id, -1.0),
                        ),
                        Text(
                          '${device.temperature.toStringAsFixed(0)}°C',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.add_circle_outline, size: 20),
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
      ),
    );
  }

  /// 弹出设备精细化操作弹窗 (BottomSheet)
  void _showDeviceControlSheet(
    BuildContext context,
    WidgetRef ref,
    SmartDevice device,
    MomoPalette palette,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (modalCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setState) {
            final latestDevice = ref.watch(smartHomeControllerProvider).devices.firstWhere(
                  (d) => d.id == device.id,
                  orElse: () => device,
                );
            final controller = ref.read(smartHomeControllerProvider.notifier);

            return Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(sheetCtx).padding.bottom + 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部拖拽手柄与标题
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              latestDevice.name,
                              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            Text(
                              '${latestDevice.room} · ${latestDevice.statusText}',
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(modalCtx).pop(),
                      ),
                    ],
                  ),
                  const Divider(height: 24),

                  // 电源开关
                  SwitchListTile(
                    title: const Text('设备电源', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    subtitle: Text(latestDevice.isOn ? '已开启' : '已关闭', style: const TextStyle(fontSize: 12)),
                    value: latestDevice.isOn,
                    activeTrackColor: palette.primary,
                    onChanged: (val) {
                      controller.toggleDevice(latestDevice.id);
                    },
                  ),

                  // 空调高级操作面板
                  if (latestDevice.type == DeviceType.climate) ...[
                    const SizedBox(height: 12),
                    const Text('运行模式', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: ['制冷', '制热', '送风', '除湿'].map((m) {
                        final isSelected = latestDevice.mode == m;
                        return ChoiceChip(
                          label: Text(m),
                          selected: isSelected,
                          selectedColor: palette.primary.withValues(alpha: 0.18),
                          onSelected: latestDevice.isOn
                              ? (sel) {
                                  if (sel) controller.setClimateMode(latestDevice.id, m);
                                }
                              : null,
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    const Text('风速档位', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: ['自动', '低速', '中速', '高速'].map((s) {
                        final isSelected = latestDevice.windSpeed == s;
                        return ChoiceChip(
                          label: Text(s),
                          selected: isSelected,
                          selectedColor: palette.primary.withValues(alpha: 0.18),
                          onSelected: latestDevice.isOn
                              ? (sel) {
                                  if (sel) controller.setClimateWindSpeed(latestDevice.id, s);
                                }
                              : null,
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('设定温度', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: latestDevice.isOn
                                  ? () => controller.updateClimateTemperature(latestDevice.id, -1.0)
                                  : null,
                            ),
                            Text(
                              '${latestDevice.temperature.toStringAsFixed(0)}°C',
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            IconButton(
                              icon: const Icon(Icons.add_circle_outline),
                              onPressed: latestDevice.isOn
                                  ? () => controller.updateClimateTemperature(latestDevice.id, 1.0)
                                  : null,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],

                  // 灯光高级操作面板
                  if (latestDevice.type == DeviceType.light) ...[
                    const SizedBox(height: 12),
                    const Text('亮度调节', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    Slider(
                      value: latestDevice.brightness.toDouble(),
                      min: 1,
                      max: 100,
                      activeColor: palette.primary,
                      onChanged: latestDevice.isOn
                          ? (val) => controller.updateLightBrightness(latestDevice.id, val.toInt())
                          : null,
                    ),
                    Center(
                      child: Text(
                        '当前亮度: ${latestDevice.brightness}%',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  ],

                  // 电视高级操作面板
                  if (latestDevice.type == DeviceType.tv) ...[
                    const SizedBox(height: 12),
                    const Text('常用多媒体快捷指令', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        OutlinedButton.icon(
                          onPressed: latestDevice.isOn
                              ? () => ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('已发送音量 -5% 指令')),
                                  )
                              : null,
                          icon: const Icon(Icons.volume_down),
                          label: const Text('音量 -'),
                        ),
                        OutlinedButton.icon(
                          onPressed: latestDevice.isOn
                              ? () => ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('已发送音量 +5% 指令')),
                                  )
                              : null,
                          icon: const Icon(Icons.volume_up),
                          label: const Text('音量 +'),
                        ),
                        OutlinedButton.icon(
                          onPressed: latestDevice.isOn
                              ? () => ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('已发送静音指令')),
                                  )
                              : null,
                          icon: const Icon(Icons.volume_mute),
                          label: const Text('静音'),
                        ),
                      ],
                    ),
                  ],

                  // 洗衣机高级操作面板
                  if (latestDevice.type == DeviceType.washer) ...[
                    const SizedBox(height: 12),
                    const Text('洗护状态', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: palette.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              latestDevice.statusText,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}
