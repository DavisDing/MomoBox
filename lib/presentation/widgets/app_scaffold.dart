import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';
import 'ai_assistant_dialog.dart';
import 'intake_sheet.dart';

class AppScaffold extends ConsumerWidget {
  const AppScaffold({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final location = GoRouterState.of(context).uri.path;
    final currentIndex = switch (location) {
      '/alerts' => 1,
      '/shopping' => 2,
      '/settings' => 3,
      _ => 0,
    };
    const locations = ['/', '/alerts', '/shopping', '/settings'];
    final useNavigationRail = MediaQuery.sizeOf(context).width >= 840;
    final destinations = [
      NavigationDestination(
        icon: Icon(palette.inventoryIcon),
        selectedIcon: Icon(palette.inventoryIcon),
        label: palette.inventoryLabel,
      ),
      NavigationDestination(
        icon: Icon(palette.alertIcon),
        selectedIcon: Icon(palette.alertIcon),
        label: palette.alertLabel,
      ),
      NavigationDestination(
        icon: Icon(palette.shoppingIcon),
        selectedIcon: Icon(palette.shoppingIcon),
        label: palette.shoppingLabel,
      ),
      const NavigationDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: '设置',
      ),
    ];

    return Scaffold(
      body: Stack(
        children: [
          useNavigationRail
              ? Row(
                  children: [
                    SafeArea(
                      child: NavigationRail(
                        selectedIndex: currentIndex,
                        labelType: NavigationRailLabelType.all,
                        onDestinationSelected: (index) => context.go(locations[index]),
                        destinations: destinations
                            .map(
                              (destination) => NavigationRailDestination(
                                icon: destination.icon,
                                selectedIcon: destination.selectedIcon,
                                label: Text(destination.label),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: child),
                  ],
                )
              : child,

          // 吉祥物 AI 智能问答小浮窗 (位于右下角上方，可点击呼起)
          Positioned(
            right: 16,
            bottom: currentIndex == 0 ? 80 : 16,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => AiAssistantDialog.show(context),
                borderRadius: BorderRadius.circular(30),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: palette.primary.withValues(alpha: 0.3), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: palette.primary.withValues(alpha: 0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(palette.mascot, style: const TextStyle(fontSize: 22)),
                      const SizedBox(width: 6),
                      Text(
                        '问${palette.mascotName}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: palette.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: currentIndex == 0
          ? FloatingActionButton.extended(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => const IntakeSheet(),
              ),
              icon: const Icon(Icons.add_box_outlined),
              label: const Text('手动入库'),
            )
          : null,
      bottomNavigationBar: useNavigationRail
          ? null
          : NavigationBar(
              height: 62,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              selectedIndex: currentIndex,
              onDestinationSelected: (index) => context.go(locations[index]),
              destinations: destinations,
            ),
    );
  }
}
