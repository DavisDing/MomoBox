import '../widgets/momo_mobile_layout.dart';
import '../widgets/momo_floating_dock.dart';
import '../widgets/momo_components.dart';
import '../../app/momo_typography.dart';
import '../widgets/calendar_sync_dialog.dart';
import '../widgets/chores_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../widgets/app_feedback.dart';

import '../../app/momo_theme.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/models/smart_home_models.dart';
import '../../domain/inventory/expiry_rules.dart';
import '../../application/nas_connection_service.dart';
import '../controllers/providers.dart';
import '../controllers/smart_home_controller.dart';
import '../widgets/intake_sheet.dart';
import '../widgets/momo_product_image.dart';
import '../widgets/momo_still_life.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final inventoryAsync = ref.watch(inventoryProvider);
    final summary = ref.watch(reminderSummaryProvider);
    final shoppingAsync = ref.watch(shoppingProvider);
    final homeState = ref.watch(smartHomeControllerProvider);
    return Scaffold(
      body: inventoryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('加载首页数据失败：$error'),
              const SizedBox(height: 12),
                  MomoCapsuleButton(
                onPressed: () => ref.invalidate(inventoryProvider),
                    isPrimary: false,
                    icon: const Icon(Icons.refresh),
                label: '重试',
                  ),
            ],
          ),
        ),
        data: (items) {
          final sectionOrder = ref.watch(homeSectionOrderProvider).valueOrNull ?? defaultHomeSectionOrder;

          Widget buildSectionByKey(String key) {
            switch (key) {
              case 'quick_intake':
                return _buildQuickIntakeBar(context);
              case 'alert_summary':
                return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
                  _buildAttentionList(context,summary),
                ]);
              case 'shopping_summary':
                return _buildShoppingSummaryCard(context, shoppingAsync, summary, palette);
              case 'chores_card':
                return _buildChoresCard(context, ref);
              case 'smart_home_quick':
                return _buildSmartHomeQuickSection(context, ref, homeState);
              case 'service_status':
                return _buildServiceStatus(context, ref);
              case 'reminder_details':
                return ExpansionTile(tilePadding:EdgeInsets.zero,title:const Text('提醒汇总'),
                  children:[_buildAlertSummaryCard(context,summary)]);
              default:
                return const SizedBox.shrink();
            }
          }

          final insets = MomoMobileLayout.pageInsets(context);
          final ordered = [...sectionOrder, 'reminder_details', 'service_status'];
          final today = items.isEmpty ? DateTime.now() : items.first.calendarToday;
          const weekdays = ['一', '二', '三', '四', '五', '六', '日'];

          return SafeArea(
            left: false, right: false, bottom: false,
            child: CustomScrollView(
              key: const PageStorageKey('today-page'),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverPadding(padding: insets,
                  sliver: SliverToBoxAdapter(child: MomoHouseholdBar(
                    onPressed: () => context.go('/settings'),
                    actions: [IconButton(tooltip: '自定义首页模块排序',
                      icon: const Icon(Icons.tune_rounded, size: 20),
                      onPressed: () => _showHomeOrderDialog(context, ref, sectionOrder))],
                  ))),
                SliverPadding(
                  padding: insets,
                  sliver: SliverToBoxAdapter(
                    child: MomoPageHeader(
                      title: '日常，有序。',
                      eyebrow: '${today.month} 月 ${today.day} 日，星期${weekdays[today.weekday - 1]}',
                      subtitle: const Text('家里的小事，都在这里。'),
                    ),
                  ),
                ),
                SliverPadding(padding: insets.add(const EdgeInsets.only(bottom: 12)),
                  sliver: SliverToBoxAdapter(child: _buildTodayHero(context, summary))),
                ...ordered.map((key) => SliverPadding(
                  padding: insets.add(const EdgeInsets.only(bottom: 16)),
                  sliver: SliverToBoxAdapter(child: buildSectionByKey(key)),
                )),
                SliverToBoxAdapter(
                  child: SizedBox(height: 16 + MomoDockInsets.bottomOf(context)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildAttentionList(BuildContext context,ReminderSummary summary) {
    final unique = <String,InventoryItem>{};
    for (final item in [...summary.expired,...summary.expiring,...summary.lowStock]) {
      unique[item.id] = item;
    }
    final attention = unique.values.take(2).toList();
    final theme = Theme.of(context);
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      _HomeFlowRow(children:[Expanded(child:Text('最近需要关注',style:theme.textTheme.titleLarge)),
        TextButton(onPressed:()=>context.push('/alerts'),child:const Text('查看全部'))]),
      if(attention.isEmpty) Padding(padding:const EdgeInsets.symmetric(vertical:12),
        child:Text('目前没有需要关注的物品。',style:theme.textTheme.bodyMedium)),
      for(final item in attention) _AttentionItem(item: item),
      TextButton.icon(onPressed:()=>context.go('/assistant'),
        icon:const Icon(Icons.auto_awesome_outlined,size:18),label:const Text('家里有什么，可以问问我')),
    ]);
  }

  Widget _buildTodayHero(BuildContext context, ReminderSummary summary) {
    final theme = Theme.of(context);
    final count = {...summary.expiring.map((item) => item.id), ...summary.expired.map((item) => item.id)}.length;
    return MomoCard(color: theme.colorScheme.primaryContainer,
      borderRadius: 24, margin: EdgeInsets.zero, padding: EdgeInsets.zero,
      child: LayoutBuilder(builder: (context, constraints) {
        final showArt = constraints.maxWidth >= 280 && MediaQuery.textScalerOf(context).scale(14) <= 18.2;
        return Stack(children: [
          if (showArt) const Positioned(right: 4, bottom: 8, width: 112, height: 150, child: MomoStillLife()),
          Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(Icons.eco_outlined, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6), Expanded(child:Text('今天，先照顾这些', style: theme.textTheme.bodySmall))]),
        const SizedBox(height: 8),
        Padding(padding: EdgeInsets.only(right: showArt ? 85 : 0),
          child: Text(count > 0 ? '别让好东西，\n被时间忘记。' : '物品有归处，\n日子有秩序。',
          style: theme.textTheme.headlineMedium)),
        const SizedBox(height: 6),
        Padding(padding: EdgeInsets.only(right: showArt ? 92 : 0),
          child: Text(count > 0 ? '$count 件物品需要留意效期。' : '暂时没有效期提醒。',
          style: theme.textTheme.bodySmall)),
        TextButton.icon(onPressed: () => context.push('/alerts'),
          style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
          label: const Text('看看是哪几件'), icon: const Icon(Icons.north_east_rounded, size: 16)),
      ])),
    ]);
  }));
  }

  Widget _buildStatusDot(
    BuildContext context, {
    required String label,
    required String detail,
    required bool isConnected,
  }) {
    final statusColor = isConnected ? Colors.green : Colors.blueGrey.shade400;
    final scheme = Theme.of(context).colorScheme;
    final detailColor = isConnected
            ? (Theme.of(context).brightness == Brightness.dark
                ? Colors.green.shade300
                : Colors.green.shade800)
            : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(width: 8, height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: statusColor)),
          const SizedBox(width: 8),
          Expanded(child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 8, runSpacing: 2,
            children: [
              Text(label, style: const TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.w600)),
              Text(detail, style: TextStyle(fontSize: MomoTextSize.caption, color: detailColor)),
            ],
          )),
        ],
      ),
    );
  }

  String _nasStatusLabel(NasConnectionStatus status) {
    return switch (status) {
      NasConnectionStatus.unconfigured => '未接入',
      NasConnectionStatus.checking => '连接中',
      NasConnectionStatus.connected => '已连接',
      NasConnectionStatus.unavailable => '服务不可用',
      NasConnectionStatus.failed => '连接失败',
    };
  }

  String _haStatusLabel(SmartHomeState state) {
    if (state.isLoading) return '连接中';
    return switch (state.haStatus) {
      HaConnectionStatus.online => state.nasOnline ? '已连接' : '服务不可用',
      HaConnectionStatus.offline => '服务不可用',
      HaConnectionStatus.stale => '状态过期',
      HaConnectionStatus.syncing => '连接中',
      HaConnectionStatus.unconfigured => '未接入',
    };
  }

  Widget _buildQuickIntakeBar(BuildContext context) {
    return MomoAdaptiveTiles(minimumWidth: 128, children: [
      _HomeShortcut(label: '记录新物品', icon: Icons.qr_code_scanner,
        onPressed: () => showModalBottomSheet<void>(context: context, isScrollControlled: true,
          useSafeArea: true, builder: (_) => const IntakeSheet())),
      _HomeShortcut(label: '采买清单', icon: Icons.checklist_rounded,
        onPressed: () => context.push('/shopping')),
    ]);
  }

  Widget _buildServiceStatus(BuildContext context, WidgetRef ref) {
    final aiConfigured = ref.watch(aiConfigurationStatusProvider).valueOrNull == true;
    final nasState = ref.watch(nasConnectionProvider);
    final homeState = ref.watch(smartHomeControllerProvider);
    return ExpansionTile(tilePadding:EdgeInsets.zero,childrenPadding:const EdgeInsets.only(bottom:4),
        shape:const Border(),collapsedShape:const Border(),title:const Text('服务状态'),
        subtitle:Text(nasState.isConnected?'NAS 协同模式':'单机模式 · 本地可用'),
        children:[
          _buildStatusDot(context,label:'NAS服务',isConnected:nasState.isConnected,detail:_nasStatusLabel(nasState.status)),
          _buildStatusDot(context,label:'HA服务',isConnected:homeState.nasOnline && homeState.haStatus==HaConnectionStatus.online && !homeState.isLoading,detail:_haStatusLabel(homeState)),
          _buildStatusDot(context,label:'AI服务',isConnected:false,detail:aiConfigured?'待验证':'未配置'),
        ]);
  }

  Widget _buildAlertSummaryCard(BuildContext context, ReminderSummary summary) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HomeFlowRow(children: [
          Expanded(child: Semantics(
            header: true,
            child: Text('需要留意', style: Theme.of(context).textTheme.titleLarge),
          )),
          IconButton(
            tooltip: '同步到日历',
            icon: const Icon(Icons.calendar_month_outlined, size: 22),
            onPressed: () => CalendarSyncDialog.show(context),
          ),
          TextButton(onPressed: () => context.push('/alerts'), child: const Text('提醒明细')),
        ]),
        const SizedBox(height: 8),
        MomoAdaptiveTiles(
          minimumWidth: 128,
          children: [
            _buildSummaryGridItem(context, icon: Icons.error_outline_rounded,
              label: '已过期批次', count: summary.expired.length,
              color: Theme.of(context).colorScheme.error,
              onTap: () => context.push('/alerts?filter=expired')),
            _buildSummaryGridItem(context, icon: Icons.timelapse_rounded,
              label: '3 天内到期', count: summary.expiringWithinDays(3),
              color: Colors.orange.shade800,
              onTap: () => context.push('/alerts?filter=expiring')),
            _buildSummaryGridItem(context, icon: Icons.schedule_rounded,
              label: '临期提醒', count: summary.expiring.length,
              color: Colors.orange.shade800,
              onTap: () => context.push('/alerts?filter=expiring')),
            _buildSummaryGridItem(context, icon: Icons.inventory_2_outlined,
              label: '库存偏低', count: summary.lowStock.length,
              color: Theme.of(context).colorScheme.primary,
              onTap: () => context.push('/alerts?filter=low_stock')),
          ],
        ),
      ],
    );
  }

  Widget _buildSummaryGridItem(BuildContext context, {
    required IconData icon, required String label, required int count,
    required Color color, required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return MomoCard(
      onTap: onTap,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 24, color: color),
          const SizedBox(height: 12),
          Text('$count', style: theme.textTheme.headlineLarge),
          const SizedBox(height: 4),
          Text(label, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _buildShoppingSummaryCard(
    BuildContext context,
    AsyncValue<List<ShoppingEntry>> shoppingAsync,
    ReminderSummary summary,
    MomoPalette palette,
  ) {
    final theme = Theme.of(context);

    return MomoCard(
        padding: const EdgeInsets.all(16),
      margin: EdgeInsets.zero,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          _HomeFlowRow(
              children: [
                Icon(palette.shoppingIcon, color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '采买速览清单',
                  style: theme.textTheme.titleLarge,
                ),
              ),
                TextButton(
                  onPressed: () => context.push('/shopping'),
                  child: const Text('查看完整清单 >', style: TextStyle(fontSize: MomoTextSize.caption)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            shoppingAsync.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('加载采购失败: $e', style: const TextStyle(fontSize: MomoTextSize.caption)),
              data: (entries) {
                final pending = entries.where((e) => !e.isCompleted).toList();
                if (pending.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: _HomeFlowRow(
                      children: [
                        const Text('🛒 ', style: TextStyle(fontSize: 18)),
                        Expanded(
                          child: Text(
                            summary.lowStock.isNotEmpty
                                ? '待采购清单已清空，但有 ${summary.lowStock.length} 件低库存物品建议补货。'
                                : '待采购清单已清空，所有常备物资充足。',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return Column(
                  children: [
                    ...pending.take(3).map((entry) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: _HomeFlowRow(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Theme.of(context).colorScheme.secondary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  entry.itemName,
                                  style: const TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.w500),
                                ),
                              ),
                              Text(
                                '需采购 ${entry.targetQuantity} 件',
                                style: TextStyle(
                                  fontSize: MomoTextSize.caption,
                                  color: theme.textTheme.bodySmall?.color,
                                ),
                              ),
                            ],
                          ),
                        )),
                    if (pending.length > 3)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '等共计 ${pending.length} 项待采购...',
                          style: TextStyle(fontSize: MomoTextSize.caption, color: Theme.of(context).colorScheme.primary),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      );
  }

  Widget _buildSmartHomeQuickSection(
    BuildContext context,
    WidgetRef ref,
    SmartHomeState homeState,
  ) {
    final theme = Theme.of(context);

    // Scenes/scripts have no confirmed execution flow on the smart-home page;
    // do not accidentally expose them as toggleable device switches here.
    final sceneEntityIds = homeState.entities
        .where((entity) => entity.domain == 'scene' || entity.domain == 'script')
        .map((entity) => '${entity.integrationId}::${entity.entityId}')
        .toSet();
    final quickDevices = homeState.devices
        .where((device) => !sceneEntityIds.contains(device.id))
        .take(2)
        .toList();
    final controller = ref.read(smartHomeControllerProvider.notifier);

    return MomoCard(
        padding: const EdgeInsets.all(16),
      margin: EdgeInsets.zero,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          _HomeFlowRow(
              children: [
                const Icon(Icons.home_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '智能家居预览（${_haStatusLabel(homeState)}）',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: () => context.go('/smart-home'),
                  child: const Text('进入家居页 >', style: TextStyle(fontSize: MomoTextSize.caption)),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // 常用设备小开关
          LayoutBuilder(
            builder: (context, constraints) {
              final scale =
                  MediaQuery.textScalerOf(context).scale(MomoTextSize.body) /
                  MomoTextSize.body;
              final columns =
                  constraints.maxWidth >= 480 && scale <= 1.3 ? 2 : 1;
              final itemWidth =
                  (constraints.maxWidth - (columns - 1) * 8) / columns;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: quickDevices.map((device) {
                final unavailable = controller.powerUnavailableReason(
                  device.id, turnOn: !device.isOn,
                );
                final isExecuting = homeState.isCommandLoading &&
                    homeState.commandDeviceId == device.id;
                return SizedBox(
                        width: itemWidth,
                        child: MomoCard(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          child: _HomeFlowRow(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                device.name,
                                style: const TextStyle(fontSize: MomoTextSize.caption, fontWeight: FontWeight.bold),
                              ),
                              Text(
                                isExecuting ? '控制请求进行中' :
                                    (unavailable ?? device.statusText),
                                style: TextStyle(fontSize: MomoTextSize.caption, color: theme.textTheme.bodySmall?.color),
                              ),
                            ],
                          ),
                        ),
                        Tooltip(
                          message: unavailable ?? device.statusText,
                          child: Switch.adaptive(
                            key: ValueKey('home-ha-toggle-${device.id}'),
                            value: device.isOn,
                            activeTrackColor: Theme.of(context).colorScheme.primary,
                            onChanged: unavailable != null ? null : (turnOn) async {
                              // The controller rechecks at submission time and
                              // changes state only from a matching NAS response.
                              await controller.setDevicePower(device.id, turnOn);
                              if (!context.mounted || !controller.mounted) {
                                              return;
                                            }
                                            if (!identical(
                                ref.read(smartHomeControllerProvider.notifier), controller,
                              )) {
                                return;
                              }
                              final error = ref.read(smartHomeControllerProvider).commandError;
                              if (error != null) {
                                showAppSnackBar(context, SnackBar(content: Text(error)));
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
              );
            },
          ),
            if (homeState.isLoading) const LinearProgressIndicator(),
            if (homeState.message != null || homeState.commandError != null ||
                quickDevices.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  homeState.commandError ?? homeState.message ?? '暂无可用的家居快捷项。',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      );
  }

  Widget _buildChoresCard(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final choresAsync = ref.watch(choresProvider);

    return MomoCard(
        padding: const EdgeInsets.all(16),
      margin: EdgeInsets.zero,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          _HomeFlowRow(
              children: [
                Icon(Icons.repeat_rounded, color: Theme.of(context).colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '周期循环提醒',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: () => ChoresSheet.show(context),
                  child: const Text('管理/新增 >', style: TextStyle(fontSize: MomoTextSize.caption)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            choresAsync.when(
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ),
              error: (err, _) => Text('周期数据加载异常：', style: const TextStyle(fontSize: MomoTextSize.caption)),
              data: (chores) {
                if (chores.isEmpty) {
                  return InkWell(
                    onTap: () => ChoresSheet.show(context),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: _HomeFlowRow(
                        children: [
                          Icon(Icons.add_circle_outline_rounded, size: 16, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '设置常规定期家务（如换床单、洗浴巾、换滤芯）',
                              style: TextStyle(fontSize: MomoTextSize.body, color: Theme.of(context).colorScheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return Column(
                  children: [
                    ...chores.take(3).map((chore) {
                      final isDue = chore.isDue();
                      final days = chore.daysUntil();
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: _HomeFlowRow(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isDue ? Colors.redAccent : Colors.green,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                chore.title,
                                style: TextStyle(
                                  fontSize: MomoTextSize.body,
                                  fontWeight: isDue ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ),
                            Text(
                              isDue
                                  ? (days < 0 ? '逾期 ${-days} 天' : '今日待办')
                                  : '还有 $days 天',
                              style: TextStyle(
                                fontSize: MomoTextSize.caption,
                                color: isDue ? Colors.redAccent : theme.hintColor,
                                fontWeight: isDue ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: '完成「${chore.title}」',
                              onPressed: () async {
                                await ref.read(choreServiceProvider).completeChore(chore.id);
                                if (context.mounted) {
                                  showAppSnackBar(context,
                                    SnackBar(content: Text('已打卡「${chore.title}」'), duration: const Duration(seconds: 1)),
                                  );
                                }
                              },
                              icon: Icon(Icons.check_circle_outline, size: 24, color: Theme.of(context).colorScheme.primary),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                );
              },
            ),
          ],
        ),
      );
  }

  void _showHomeOrderDialog(BuildContext context, WidgetRef ref, List<String> currentOrder) {
    final moduleLabels = <String, (String, IconData)>{
      'quick_intake': ('快捷录入动作栏', Icons.add_circle_outline),
      'alert_summary': ('效期与库存提醒摘要', Icons.notifications_active_outlined),
      'shopping_summary': ('采买清单速览', Icons.shopping_bag_outlined),
      'chores_card': ('家务周期打卡', Icons.event_repeat_rounded),
      'smart_home_quick': ('智能家居常用快捷', Icons.home_outlined),
    };

    final order = List<String>.from(currentOrder);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: SingleChildScrollView(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(child: Text('调整首页模块显示顺序', style: TextStyle(fontWeight: FontWeight.bold, fontSize: MomoTextSize.title))),
                    TextButton(
                      onPressed: () async {
                        await ref.read(settingsServiceProvider).setValue(homeSectionOrderKey, order.join(','));
                        if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                              },
                      child: const Text('保存'),
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('长按并拖拽右侧手柄调整顺序，保存后首页将实时更新。', style: TextStyle(fontSize: MomoTextSize.caption, color: Colors.grey)),
                ),
                const SizedBox(height: 8),
                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  onReorderItem: (oldIndex, newIndex) {
                    setModalState(() {
                      final item = order.removeAt(oldIndex);
                      order.insert(newIndex, item);
                    });
                  },
                  children: [
                    for (final key in order)
                      ListTile(
                        key: ValueKey(key),
                        leading: Icon(moduleLabels[key]?.$2 ?? Icons.widgets_outlined),
                        title: Text(moduleLabels[key]?.$1 ?? key, style: const TextStyle(fontSize: MomoTextSize.body)),
                        trailing: const Icon(Icons.drag_handle_rounded),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          )),
        ),
      ),
    );
  }
}

/// Preserve the compact layout while allowing accessibility text to flow.
class _HomeFlowRow extends StatelessWidget {
  const _HomeFlowRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.textScalerOf(context).scale(MomoTextSize.body) <=
        MomoTextSize.body * 1.3) {
      return Row(children: children);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children:
          children.map((child) {
            if (child is Flexible) return child.child;
            if (child is Spacer) return const SizedBox(height: 8);
            if (child is SizedBox &&
                child.width != null &&
                child.child == null) {
              return SizedBox(height: child.width);
            }
            return child;
          }).toList(),
    );
  }
}

class _HomeShortcut extends StatelessWidget {
  const _HomeShortcut({required this.label, required this.icon, required this.onPressed});
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MomoCard(
      onTap: onPressed,
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      borderRadius: 16,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Flexible(child: Text(label, style: theme.textTheme.labelLarge, textAlign: TextAlign.center)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttentionItem extends StatelessWidget {
  const _AttentionItem({required this.item});
  final InventoryItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = item.nearestDatedBatch?.daysUntilExpiry;
    final (detail, note) = switch (item.overallExpiryStatus) {
      ExpiryStatus.expired => ('已过期', '查看处理方式'),
      ExpiryStatus.expiring when days != null => (days == 0 ? '今日到期' : '$days 天后到期', '优先安排使用'),
      _ => ('库存偏低', '建议安排采买'),
    };
    final detailColor = item.overallExpiryStatus == ExpiryStatus.expired
        ? theme.colorScheme.error
        : item.overallExpiryStatus == ExpiryStatus.expiring
            ? theme.colorScheme.secondary
            : theme.colorScheme.onSurfaceVariant;

    return Semantics(
      button: true,
      label: '${item.name}，$detail，${item.totalStock} ${item.unit}',
      child: InkWell(
        onTap: () => context.push('/inventory/${item.id}'),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            SizedBox(width: 52, height: 52, child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: MomoProductImage(productId: item.id),
            )),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.name, style: theme.textTheme.titleSmall),
              const SizedBox(height: 3),
              Text('${item.location ?? '未设置位置'} · ${item.totalStock} ${item.unit}',
                style: theme.textTheme.bodySmall),
            ])),
            const SizedBox(width: 8),
            Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(detail, textAlign: TextAlign.end,
                style: theme.textTheme.bodySmall?.copyWith(color: detailColor)),
              const SizedBox(height: 3),
              Text(note, textAlign: TextAlign.end, style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant)),
            ])),
          ]),
        ),
      ),
    );
  }
}
