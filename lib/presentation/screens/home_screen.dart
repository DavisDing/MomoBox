import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/momo_theme.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/models/smart_home_models.dart';
import '../controllers/providers.dart';
import '../controllers/smart_home_controller.dart';
import '../widgets/intake_sheet.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

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
              OutlinedButton.icon(
                onPressed: () => ref.invalidate(inventoryProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (items) {
          return CustomScrollView(
            slivers: [
              // 顶部渐变与家庭状态栏
              SliverToBoxAdapter(
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    MediaQuery.of(context).padding.top + 16,
                    16,
                    16,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        palette.primary.withValues(alpha: isDark ? 0.25 : 0.15),
                        theme.scaffoldBackgroundColor,
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 顶部第一行：家庭名称与模式徽章
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: palette.primary.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(palette.appLogoIcon, color: palette.primary, size: 24),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      '嬷嬷的温馨小家',
                                      style: theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _buildModeBadge(context, isNas: homeState.nasOnline),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '美好生活 · 秩序井然',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // 连接状态横条（NAS 与 HA 状态）
                      _buildSyncStatusRow(context, homeState, palette),
                    ],
                  ),
                ),
              ),

              // 快捷入库动作栏 (拍照/扫码/手动)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildQuickIntakeBar(context, palette),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 16)),

              // 提醒摘要卡片 (四分类直达)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildAlertSummaryCard(context, summary, palette),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 16)),

              // 采买速览卡片 (跳转二级路由 /shopping)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildShoppingSummaryCard(context, shoppingAsync, summary, palette),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 16)),

              // 常用家电设备与场景快捷操作
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildSmartHomeQuickSection(context, ref, homeState, palette),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildModeBadge(BuildContext context, {required bool isNas}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isNas ? Colors.green.withValues(alpha: 0.15) : Colors.blueGrey.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isNas ? 'NAS 协同模式' : '单机模式',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isNas ? Colors.green.shade700 : Colors.blueGrey.shade700,
        ),
      ),
    );
  }

  Widget _buildSyncStatusRow(BuildContext context, SmartHomeState homeState, MomoPalette palette) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: (isDark ? Colors.white.withValues(alpha: 0.05) : Colors.white),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // NAS 状态
          _buildStatusDot(
            label: 'NAS 局域网',
            isOnline: homeState.nasOnline,
            detail: homeState.nasOnline ? '已同步' : '未连接',
          ),
          // HA 状态
          _buildStatusDot(
            label: 'Home Assistant',
            isOnline: homeState.haStatus == HaConnectionStatus.online,
            detail: switch (homeState.haStatus) {
              HaConnectionStatus.online => '在线就绪',
              HaConnectionStatus.syncing => '同步中',
              HaConnectionStatus.offline => '离线',
              HaConnectionStatus.unconfigured => '未配置',
            },
          ),
        ],
      ),
    );
  }

  Widget _buildStatusDot({
    required String label,
    required bool isOnline,
    required String detail,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isOnline ? Colors.green : Colors.orange,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$label: ',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        Text(
          detail,
          style: TextStyle(
            fontSize: 12,
            color: isOnline ? Colors.green.shade700 : Colors.orange.shade700,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickIntakeBar(BuildContext context, MomoPalette palette) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildQuickActionBtn(
              context,
              icon: Icons.qr_code_scanner,
              label: '扫码入库',
              color: palette.primary,
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => const IntakeSheet(),
              ),
            ),
            _buildQuickActionBtn(
              context,
              icon: Icons.camera_alt_outlined,
              label: '拍照识别',
              color: palette.secondary,
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => const IntakeSheet(),
              ),
            ),
            _buildQuickActionBtn(
              context,
              icon: Icons.edit_note_rounded,
              label: '手动录入',
              color: Colors.deepPurpleAccent,
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => const IntakeSheet(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionBtn(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertSummaryCard(BuildContext context, ReminderSummary summary, MomoPalette palette) {
    final theme = Theme.of(context);
    final expiredCount = summary.expired.length;
    final expiringSoon = summary.expiringWithinDays(3);
    final expiring30 = summary.expiring.length;
    final lowStockCount = summary.lowStock.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(palette.alertIcon, color: palette.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '效期与库存提醒摘要',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => context.push('/alerts'),
                  child: const Text('待处理详情 >', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildSummaryGridItem(
                    context,
                    label: '已过期',
                    count: expiredCount,
                    color: Colors.red,
                    onTap: () => context.push('/alerts?filter=expired'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildSummaryGridItem(
                    context,
                    label: '即将到期 (3天)',
                    count: expiringSoon,
                    color: Colors.orange,
                    onTap: () => context.push('/alerts?filter=expiring'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildSummaryGridItem(
                    context,
                    label: '30天内临期',
                    count: expiring30,
                    color: Colors.amber.shade800,
                    onTap: () => context.push('/alerts?filter=expiring'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildSummaryGridItem(
                    context,
                    label: '库存偏低',
                    count: lowStockCount,
                    color: Colors.blue,
                    onTap: () => context.push('/alerts?filter=low_stock'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryGridItem(
    BuildContext context, {
    required String label,
    required int count,
    required Color color,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.15 : 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Column(
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: theme.textTheme.bodySmall?.color,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(palette.shoppingIcon, color: palette.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  '采买速览清单',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => context.push('/shopping'),
                  child: const Text('查看完整清单 >', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            shoppingAsync.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('加载采购失败: $e', style: const TextStyle(fontSize: 12)),
              data: (entries) {
                final pending = entries.where((e) => !e.isCompleted).toList();
                if (pending.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
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
                          child: Row(
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: palette.secondary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  entry.itemName,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                ),
                              ),
                              Text(
                                '需采购 ${entry.targetQuantity} 件',
                                style: TextStyle(
                                  fontSize: 12,
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
                          style: TextStyle(fontSize: 11, color: palette.primary),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmartHomeQuickSection(
    BuildContext context,
    WidgetRef ref,
    SmartHomeState homeState,
    MomoPalette palette,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 取前两个常用场景 + 前两个常用设备
    final quickScenes = homeState.scenes.take(2).toList();
    final quickDevices = homeState.devices.take(2).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.home_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  '常用智能家居快捷操作',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => context.go('/smart-home'),
                  child: const Text('进入家居页 >', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // 常用场景胶囊
            Row(
              children: quickScenes.map((scene) {
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        side: BorderSide(color: palette.primary.withValues(alpha: 0.3)),
                      ),
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已向 Home Assistant 发送执行指令：【${scene.name}】（Mock）'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(scene.icon, style: const TextStyle(fontSize: 16)),
                          const SizedBox(width: 6),
                          Text(scene.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 12),

            // 常用设备小开关
            Row(
              children: quickDevices.map((device) {
                return Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                device.name,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                device.statusText,
                                style: TextStyle(fontSize: 10, color: theme.textTheme.bodySmall?.color),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        Switch.adaptive(
                          value: device.isOn,
                          activeTrackColor: palette.primary,
                          onChanged: (val) {
                            ref.read(smartHomeControllerProvider.notifier).toggleDevice(device.id);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('设备【${device.name}】已${val ? '开启' : '关闭'}（Mock）'),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}
