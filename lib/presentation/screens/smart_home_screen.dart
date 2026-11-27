import '../widgets/momo_mobile_layout.dart';
import '../widgets/momo_floating_dock.dart';
import '../widgets/momo_components.dart';
import '../../app/momo_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/app_feedback.dart';

import '../../domain/models/smart_home_models.dart';
import '../controllers/providers.dart';
import '../controllers/smart_home_controller.dart';
import '../widgets/home_environment_card.dart';
import 'home_assistant_settings_screen.dart';

class SmartHomeScreen extends ConsumerStatefulWidget {
  const SmartHomeScreen({super.key});

  @override
  ConsumerState<SmartHomeScreen> createState() => _SmartHomeScreenState();
}

class _SmartHomeScreenState extends ConsumerState<SmartHomeScreen> {
  String? _selectedRoom;

  @override
  Widget build(BuildContext context) {
    final homeState = ref.watch(smartHomeControllerProvider);
    final controller = ref.read(smartHomeControllerProvider.notifier);
    final routines = controller.homeRoutines;

    return Scaffold(
      body: SafeArea(
        left: false, right: false, bottom: false,
        child: RefreshIndicator(
          onRefresh: () async {
            await controller.refresh();
            ref.read(publicWeatherServiceProvider).expireCache();
            ref.invalidate(publicWeatherReadingProvider);
            ref.invalidate(homeEnvironmentProvider);
          },
          child: ListView(
            key: const PageStorageKey('smart-home-page'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: MomoMobileLayout.pageInsets(context).add(
              EdgeInsets.only(bottom: 20 + MomoDockInsets.bottomOf(context))),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(child: MomoPageHeader(title: '家居')),
                  const SizedBox(width: 12),
                  Flexible(child: _buildHaRefreshButton(context, homeState)),
                ],
              ),
              const HomeEnvironmentCard(),
              const SizedBox(height: 24),
              Column(
                key: const ValueKey('smart-home-device-heading'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text('家里的设备', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  if (homeState.haStatus != HaConnectionStatus.unconfigured &&
                      (homeState.message != null || homeState.commandError != null || homeState.linkageError != null))
                    _buildStateNotice(context, homeState),
                ],
              ),
              if (homeState.haStatus == HaConnectionStatus.unconfigured)
                _buildUnconfiguredState(context)
              else ...[
                  _buildRoomsAndDevices(context, ref, homeState.devices),
                  if (routines.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _buildSectionHeader(
                      context,
                      title: '场景与脚本',
                      icon: Icons.auto_awesome_outlined,
                    ),
                    const SizedBox(height: 10),
                    MomoCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (final routine in routines)
                            ListTile(
                              title: Text(routine.target),
                              subtitle: routine.unavailable == null
                                  ? null
                                  : Text(routine.unavailable!),
                              trailing: TextButton(
                                onPressed: routine.unavailable == null
                                    ? () => _confirmRoutine(
                                          routine.id, routine.target, routine.isScene,
                                        )
                                    : null,
                                child: Text(routine.isScene ? '激活场景' : '运行脚本'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height:16),
                  // 耗材联动建议与日志入口 (洗衣机耗材、制冰机等)
                  _buildSectionHeader(
                    context,
                    title: '设备耗材联动与建议',
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

  Future<void> _confirmRoutine(String id, String target, bool isScene) async {
    final label = isScene ? '激活场景' : '运行脚本';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('$label $target？'),
        content: const Text('Home Assistant 将执行其中配置的操作。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(label),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final receipt = await ref.read(smartHomeControllerProvider.notifier).invokeRoutine(id);
    if (!mounted) return;
    showAppSnackBar(context, SnackBar(content: Text(receipt)));
  }

  Widget _buildStateNotice(BuildContext context, SmartHomeState state) {
    final error = state.commandError ?? state.linkageError;
    final text = error ?? state.message!;
    final isError = error != null || state.haStatus == HaConnectionStatus.offline;
    final canDismiss = !isError && state.isPermissionNotice;
    final scheme = Theme.of(context).colorScheme;
    final color = isError ? scheme.onErrorContainer : scheme.onSurfaceVariant;
    return MomoCard(
      key: const ValueKey('smart-home-notice'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: EdgeInsets.zero,
      borderRadius: 14,
      color: isError ? scheme.errorContainer : scheme.surfaceContainerLow,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 14, top: 16),
            child: Icon(
              isError ? Icons.error_outline_rounded :
                  canDismiss ? Icons.lock_outline_rounded : Icons.info_outline_rounded,
              size: 18,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: color,
                height: 1.5,
              )),
            ),
          ),
          if (canDismiss)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 2),
              child: IconButton(
                tooltip: '关闭权限提示',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                icon: const Icon(Icons.close_rounded, size: 18),
                color: color,
                onPressed: () => ref
                    .read(smartHomeControllerProvider.notifier)
                    .dismissPermissionNotice(),
              ),
            )
          else
            const SizedBox(width: 14),
        ],
      ),
    );
  }

  Widget _buildHaRefreshButton(BuildContext context, SmartHomeState state) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (state.haStatus) {
      HaConnectionStatus.online => ('HA 已连接', scheme.primary),
      HaConnectionStatus.syncing => ('同步中', scheme.primary),
      HaConnectionStatus.offline => ('HA 离线', scheme.error),
      HaConnectionStatus.stale => ('HA 状态过期', scheme.tertiary),
      HaConnectionStatus.unconfigured => ('HA 未配置', scheme.onSurfaceVariant),
    };
    return Tooltip(
      message: state.isLoading ? '正在刷新设备状态' : '刷新设备状态',
      child: TextButton.icon(
        onPressed: state.isLoading ? null :
            () => ref.read(smartHomeControllerProvider.notifier).refresh(),
        style: TextButton.styleFrom(
          foregroundColor: color,
          disabledForegroundColor: color,
          backgroundColor: color.withValues(alpha: 0.06),
          minimumSize: const Size(44, 30),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          // Keep the compact capsule inside a full-size native tap target.
          tapTargetSize: MaterialTapTargetSize.padded,
          visualDensity: VisualDensity.standard,
          shape: const StadiumBorder(),
        ),
        icon: state.isLoading
            ? SizedBox.square(dimension: 14, child: CircularProgressIndicator(
                strokeWidth: 1.5, color: color, semanticsLabel: '正在刷新设备状态'))
            : const Icon(Icons.refresh_rounded, size: 14),
        label: Text(state.isLoading ? '刷新中…' : label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
          textAlign: TextAlign.center),
      ),
    );
  }

  Widget _buildUnconfiguredState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.home_outlined, size: 30, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            const Text('Home Assistant 尚未配置', style: TextStyle(fontSize: MomoTextSize.section, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(builder: (_) => const HomeAssistantSettingsScreen()),
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('连接 Home Assistant'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context, {
    required String title,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
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
    // Permission changes can remove a room while its tab was selected.
    final selected = rooms.contains(_selectedRoom) ? _selectedRoom : null;
    final visible = devices.where((device) => selected == null || device.room == selected);
    final theme = Theme.of(context);
    return Column(key: const ValueKey('smart-home-devices'),
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SingleChildScrollView(scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final room in <String?>[null, ...rooms]) Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Semantics(selected: selected == room, child: TextButton(
              key: ValueKey('smart-home-room-${room ?? 'all'}'),
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 44),
                foregroundColor: selected == room ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero,
                  side: BorderSide.none),
              ),
              onPressed: () => setState(() => _selectedRoom = room),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(
                  color: selected == room ? theme.colorScheme.primary : Colors.transparent,
                  width: 2))),
                child: Text(room ?? '全部', style: theme.textTheme.bodySmall),
              ),
            )),
          ),
        ])),
      const SizedBox(height: 12),
      if (devices.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text('暂无已授权设备', style: theme.textTheme.bodyMedium)),
      MomoAdaptiveTiles(minimumWidth: 148,
        children: visible.map((device) => _buildDeviceCard(context, ref, device)).toList()),
    ]);
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
      color:device.isOn ? theme.colorScheme.primaryContainer : null,
      onTap:() => _showDeviceControlSheet(context,device),
      padding:const EdgeInsets.all(14),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,children:[
          Flexible(child: Icon(icon,size:24,color:theme.colorScheme.primary)),
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

            return SingleChildScrollView(
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
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        const Text('设定温度', style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: latestDevice.isOn
                                  ? () => controller.updateClimateTemperature(latestDevice.id, -1.0)
                                  : null,
                            ),
                            Flexible(child: Text(
                              '${latestDevice.temperature.toStringAsFixed(0)}°C',
                              style: const TextStyle(fontSize: MomoTextSize.section, fontWeight: FontWeight.bold),
                              textAlign: TextAlign.center,
                            )),
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
                    Wrap(
                      alignment: WrapAlignment.spaceAround,
                      spacing: 8,
                      runSpacing: 8,
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
