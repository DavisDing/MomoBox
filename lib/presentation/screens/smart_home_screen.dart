import '../widgets/momo_mobile_layout.dart';
import '../widgets/momo_floating_dock.dart';
import '../widgets/momo_components.dart';
import '../../app/momo_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../widgets/app_feedback.dart';

import '../../domain/models/smart_home_models.dart';
import '../controllers/providers.dart';
import '../controllers/smart_home_controller.dart';
import '../widgets/home_environment_card.dart';
import 'home_assistant_settings_screen.dart';

class SmartHomeScreen extends ConsumerWidget {
  const SmartHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final homeState = ref.watch(smartHomeControllerProvider);
    final controller = ref.read(smartHomeControllerProvider.notifier);

    return Scaffold(
      body: SafeArea(
        left: false, right: false, bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            await controller.refresh();
            ref.read(publicWeatherServiceProvider).expireCache();
            ref.invalidate(homeEnvironmentProvider);
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: MomoMobileLayout.pageInsets(context).add(
              EdgeInsets.only(bottom: 20 + MomoDockInsets.bottomOf(context))),
            children: [
              MomoPageHeader(
                title: '让家，懂你。',
                subtitle: Align(alignment: Alignment.centerLeft,
                  child: _buildHaBadge(context, homeState.haStatus)),
                actions: [
                  IconButton(
                    tooltip: '刷新设备状态',
                    icon: homeState.isLoading
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh_rounded),
                    onPressed: homeState.isLoading ? null : () => controller.refresh(),
                  ),
                  IconButton(tooltip: 'HA 连接配置', icon: const Icon(Icons.tune_rounded),
                    onPressed: () => Navigator.of(context,rootNavigator:true).push(MaterialPageRoute<void>(
                      builder:(_) => const HomeAssistantSettingsScreen()))),
                ],
              ),
              const HomeEnvironmentCard(),
              const SizedBox(height: 18),
              if (homeState.haStatus == HaConnectionStatus.unconfigured)
                _buildUnconfiguredState(context)
              else ...[
                  if (homeState.message != null || homeState.commandError != null || homeState.linkageError != null)
                    _buildStateNotice(context, homeState),
                  _buildSectionHeader(context, title:'家里的设备',
                    subtitle:'已授权设备 · 点击卡片查看详细控制',icon:Icons.devices_other_rounded),
                  const SizedBox(height:10),
                  _buildRoomsAndDevices(context, ref, homeState.devices),
                  const SizedBox(height:16),
                  // 耗材联动建议与日志入口 (洗衣机耗材、制冰机等)
                  _buildSectionHeader(
                    context,
                    title: '设备耗材联动与建议',
                    subtitle: '设备事件触发的库存建议与自动扣减日志',
                    icon: Icons.recycling_rounded,
                  ),
                  const SizedBox(height: 10),
                  _buildConsumableLinkageCard(context, ref, homeState.logs),

                  const SizedBox(height: 24),

              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStateNotice(BuildContext context, SmartHomeState state) {
    final error = state.commandError ?? state.linkageError;
    final text = error ?? state.message!;
    final isError = error != null || state.haStatus == HaConnectionStatus.offline;
    final color = isError ? Colors.red : Colors.amber.shade800;
    return MomoCard(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(isError ? Icons.error_outline : Icons.info_outline, size: 20, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(fontSize: MomoTextSize.caption, color: color))),
          ],
      ),
    );
  }

  Widget _buildHaBadge(BuildContext context, HaConnectionStatus status) {
    final (label, color) = switch (status) {
      HaConnectionStatus.online => ('HA 已连接', Colors.green),
      HaConnectionStatus.syncing => ('同步中', Colors.blue),
      HaConnectionStatus.offline => ('HA 离线', Colors.orange),
      HaConnectionStatus.stale => ('HA 状态过期', Colors.amber.shade800),
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
          Text(label, style: TextStyle(fontSize: MomoTextSize.caption, color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildUnconfiguredState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.hub_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('Home Assistant 尚未配置', style: TextStyle(fontSize: MomoTextSize.section, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              '当前没有可用的 NAS/ Home Assistant 集成。请先完成真实连接配置；未连接时不会展示虚假设备或执行控制。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: MomoTextSize.body, color: Colors.grey),
            ),
            const SizedBox(height: 20),
            MomoCapsuleButton(
              onPressed: () => context.push('/settings'),
              label: '打开连接配置',
              icon: const Icon(Icons.settings),
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
        Expanded(
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleLarge),
            Text(subtitle, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        ),
      ],
    );
  }

  Widget _buildConsumableLinkageCard(
    BuildContext context,
    WidgetRef ref,
    List<ConsumableLinkageLog> logs,
  ) {
    final theme = Theme.of(context);
    final controller = ref.read(smartHomeControllerProvider.notifier);
    if (logs.isEmpty) {
      return MomoCard(
          padding: const EdgeInsets.all(16),
        margin: EdgeInsets.zero,
          child: Text(
            '暂无耗材联动建议。建议、库存扣减和采购提示均由 NAS 服务端返回。',
            style: theme.textTheme.bodySmall,
          ),
        );
    }

    return MomoCard(
        padding: const EdgeInsets.all(16),
      margin: EdgeInsets.zero,
        child: Column(
          children: logs.map((log) {
            final isPending = log.status == ConsumableActionStatus.pending;
            final isDeducted = log.status == ConsumableActionStatus.deducted;
            final isInsufficient = log.status == ConsumableActionStatus.insufficientStock;
            final isActing = ref.read(smartHomeControllerProvider).linkageActionId == log.id;
            final statusColor = isPending
                ? Colors.amber.shade800
                : (isDeducted ? Colors.green : (isInsufficient ? Colors.orange : Colors.grey));
            final statusLabel = isPending
                ? '待确认'
                : (isDeducted
                    ? '已扣减'
                    : (isInsufficient ? '库存不足' : '已忽略'));

            return MomoCard(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
                borderRadius: 16,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isInsufficient
                            ? Icons.inventory_2_outlined
                            : (isPending ? Icons.pending_actions_rounded : Icons.check_circle_outline),
                        color: statusColor,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          log.ruleDescription,
                          style: const TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          statusLabel,
                          style: TextStyle(fontSize: MomoTextSize.caption, fontWeight: FontWeight.bold, color: statusColor),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${log.deviceName} · ${log.eventSummary}',
                    style: const TextStyle(fontSize: MomoTextSize.caption, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '耗材建议：${log.consumableName} × ${log.quantity} ${log.unit}',
                    style: TextStyle(fontSize: MomoTextSize.caption, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.primary),
                  ),
                  if (isInsufficient && log.purchaseSuggestions.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('库存不足，NAS 已生成采购建议：', style: TextStyle(fontSize: MomoTextSize.caption, color: statusColor)),
                    const SizedBox(height: 4),
                    ...log.purchaseSuggestions.map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          '• ${item.productName} × ${item.quantity} ${item.unit}',
                          style: const TextStyle(fontSize: MomoTextSize.caption),
                        ),
                      ),
                    ),
                  ],
                  if (isPending) ...[
                    const SizedBox(height: 10),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 8,
                        runSpacing: 8,
                      children: [
                          MomoCapsuleButton(
                            onPressed: isActing
                              ? null
                              : () async {
                                  await controller.ignoreConsumableLog(log.id);
                                  if (context.mounted) {
                                    final current = ref.read(smartHomeControllerProvider);
                                    showAppSnackBar(
                                      context,
                                      SnackBar(content: Text(current.commandError ?? '已忽略该耗材建议。')),
                                    );
                                  }
                                },
                            label: '忽略',
                            isPrimary: false,
                        ),

                          MomoCapsuleButton(
                            onPressed: isActing
                              ? null
                              : () async {
                                  await controller.confirmConsumableLog(log.id);
                                  if (context.mounted) {
                                    final current = ref.read(smartHomeControllerProvider);
                                    showAppSnackBar(
                                      context,
                                      SnackBar(content: Text(current.commandError ?? '已提交 NAS 服务端处理。')),
                                    );
                                  }
                                },
                            label: '确认扣减',
                            isLoading: isActing,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          }).toList(),
      ),
    );
  }

  Widget _buildRoomsAndDevices(
    BuildContext context,
    WidgetRef ref,
    List<SmartDevice> devices,
  ) {
    final rooms = devices.map((device) => device.room).toSet().toList()..sort();

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
                child: Wrap(
                  spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      room,
                      style: const TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '(${roomDevices.length} 个设备)',
                      style: const TextStyle(fontSize: MomoTextSize.caption, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              MomoAdaptiveTiles(minimumWidth:148,
                children:roomDevices.map((dev) => _buildDeviceCard(context,ref,dev)).toList()),
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

    return MomoCard(
      margin:EdgeInsets.zero,
      color:device.isOn ? theme.colorScheme.primaryContainer.withValues(alpha:.45) : null,
      onTap:() => _showDeviceControlSheet(context,device),
      padding:const EdgeInsets.all(14),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Wrap(spacing:8,runSpacing:4,crossAxisAlignment:WrapCrossAlignment.center,children:[
          Icon(icon,size:24,color:theme.colorScheme.primary),
          Switch.adaptive(value:device.isOn,
            key:ValueKey('smart-home-power-${device.id}'),
            onChanged:controller.powerUnavailableReason(device.id,turnOn:!device.isOn)!=null ? null :
              (value)=>controller.setDevicePower(device.id,value)),
        ]),
        const SizedBox(height:8),
        Text(device.name,style:theme.textTheme.titleSmall),
        const SizedBox(height:4),
        Text(device.statusText,style:theme.textTheme.bodySmall?.copyWith(color:theme.colorScheme.onSurfaceVariant)),
        if(device.type==DeviceType.climate && device.isOn)
          Text('设定 ${device.temperature.toStringAsFixed(0)}° · ${device.mode}',style:theme.textTheme.bodySmall),
        if(device.type==DeviceType.light && device.isOn)
          Text('亮度 ${device.brightness}%',style:theme.textTheme.bodySmall),
      ]),
    );
  }

  /// 弹出设备精细化操作弹窗 (BottomSheet)
  void _showDeviceControlSheet(
    BuildContext context,
    SmartDevice device,
  ) {
    final theme = Theme.of(context);

    var closeScheduled = false;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (modalCtx) {
        return Consumer(
          builder: (sheetCtx, modalRef, _) {
            final homeState = modalRef.watch(smartHomeControllerProvider);
            final matchingDevices = homeState.devices.where((d) => d.id == device.id);
            if (matchingDevices.isEmpty) {
              // Do not keep presenting the snapshot captured when the sheet
              // opened after a refresh, logout, or permission change removed
              // this device. Pop only after the current build completes.
              if (!closeScheduled) {
                closeScheduled = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (sheetCtx.mounted && ModalRoute.of(sheetCtx)?.isCurrent == true) {
                    Navigator.of(sheetCtx).pop();
                  }
                });
              }
              return const SizedBox.shrink();
            }
            final latestDevice = matchingDevices.first;
            final controller = modalRef.read(smartHomeControllerProvider.notifier);

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
                              style: const TextStyle(fontSize: MomoTextSize.caption, color: Colors.grey),
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
                    title: const Text('设备电源', style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold)),
                    // A scaffold SnackBar can sit behind this modal. Keep the
                    // actual failure visible in the existing power subtitle.
                    subtitle: Text(
                      '${latestDevice.isOn ? '已开启' : '已关闭'}'
                      '${homeState.commandError == null ? '' : '\n${homeState.commandError}'}',
                      style: const TextStyle(fontSize: MomoTextSize.caption),
                    ),
                    isThreeLine: homeState.commandError != null,
                    value: latestDevice.isOn,
                    activeTrackColor: Theme.of(context).colorScheme.primary,
                    key: ValueKey('smart-home-sheet-power-${latestDevice.id}'),
                    onChanged: controller.powerUnavailableReason(latestDevice.id, turnOn: !latestDevice.isOn) != null
                        ? null
                        : (val) async {
                            await controller.setDevicePower(latestDevice.id, val);
                            if (!sheetCtx.mounted || !controller.mounted) {
                                return;
                              }
                              if (!identical(
                              modalRef.read(smartHomeControllerProvider.notifier),
                              controller,
                            )) {
                              return;
                            }
                            final error = modalRef.read(smartHomeControllerProvider).commandError;
                            if (error != null) {
                              showAppSnackBar(sheetCtx, SnackBar(content: Text(error)));
                            }
                          },
                  ),

                  // 空调高级操作面板
                  if (latestDevice.type == DeviceType.climate) ...[
                    const SizedBox(height: 12),
                    const Text('运行模式', style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: ['制冷', '制热', '送风', '除湿'].map((m) {
                        final isSelected = latestDevice.mode == m;
                        return ChoiceChip(
                          label: Text(m),
                          selected: isSelected,
                          selectedColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
                          onSelected: latestDevice.isOn
                              ? (sel) {
                                  if (sel) {
                                          controller.setClimateMode(latestDevice.id, m);
                                        }
                                      }
                              : null,
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    const Text('风速档位', style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: ['自动', '低速', '中速', '高速'].map((s) {
                        final isSelected = latestDevice.windSpeed == s;
                        return ChoiceChip(
                          label: Text(s),
                          selected: isSelected,
                          selectedColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
                          onSelected: latestDevice.isOn
                              ? (sel) {
                                  if (sel) {
                                          controller.setClimateWindSpeed(latestDevice.id, s);
                                        }
                                      }
                              : null,
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('设定温度', style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold)),
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
                              style: const TextStyle(fontSize: MomoTextSize.section, fontWeight: FontWeight.bold),
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
                    const Text('亮度调节', style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold)),
                    Slider(
                      // HA can legitimately report zero brightness while the
                      // light is off; keep the real display value but satisfy
                      // this existing 1..100 slider contract.
                      value: latestDevice.brightness.clamp(1, 100).toDouble(),
                      min: 1,
                      max: 100,
                      activeColor: Theme.of(context).colorScheme.primary,
                      onChanged: latestDevice.isOn
                          ? (val) => controller.updateLightBrightness(latestDevice.id, val.toInt())
                          : null,
                    ),
                    Center(
                      child: Text(
                        '当前亮度: ${latestDevice.brightness}%',
                        style: const TextStyle(fontSize: MomoTextSize.caption, color: Colors.grey),
                      ),
                    ),
                  ],

                  // 电视高级操作面板
                  if (latestDevice.type == DeviceType.tv) ...[
                    const SizedBox(height: 12),
                    const Text('常用多媒体快捷指令', style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        MomoCapsuleButton(
                          onPressed: latestDevice.isOn
                              ? () => showAppSnackBar(context,
                                    const SnackBar(content: Text('当前 NAS 安全命令协议未开放音量控制，未发送请求。')),
                                  )
                              : null,
                          label: '音量 -',
                          isPrimary: false,
                          icon: const Icon(Icons.volume_down),
                        ),
                        MomoCapsuleButton(
                          onPressed: latestDevice.isOn
                              ? () => showAppSnackBar(context,
                                    const SnackBar(content: Text('当前 NAS 安全命令协议未开放音量控制，未发送请求。')),
                                  )
                              : null,
                          label: '音量 +',
                          isPrimary: false,
                          icon: const Icon(Icons.volume_up),
                        ),
                        MomoCapsuleButton(
                          onPressed: latestDevice.isOn
                              ? () => showAppSnackBar(context,
                                    const SnackBar(content: Text('当前 NAS 安全命令协议未开放静音控制，未发送请求。')),
                                  )
                              : null,
                          label: '静音',
                          isPrimary: false,
                          icon: const Icon(Icons.volume_mute),
                        ),
                      ],
                    ),
                  ],

                  // 洗衣机高级操作面板
                  if (latestDevice.type == DeviceType.washer) ...[
                    const SizedBox(height: 12),
                    const Text('洗护状态', style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              latestDevice.statusText,
                              style: const TextStyle(fontSize: MomoTextSize.caption),
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
