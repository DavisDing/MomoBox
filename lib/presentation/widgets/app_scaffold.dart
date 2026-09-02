import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';
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
        icon: const Icon(Icons.inventory_2_outlined),
        selectedIcon: const Icon(Icons.inventory_2),
        label: palette.inventoryLabel,
      ),
      NavigationDestination(
        icon: const Icon(Icons.notifications_none),
        selectedIcon: const Icon(Icons.notifications),
        label: palette.alertLabel,
      ),
      NavigationDestination(
        icon: const Icon(Icons.shopping_bag_outlined),
        selectedIcon: const Icon(Icons.shopping_bag),
        label: palette.shoppingLabel,
      ),
      const NavigationDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: '设置',
      ),
    ];

    return Scaffold(
      body: useNavigationRail
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
              selectedIndex: currentIndex,
              onDestinationSelected: (index) => context.go(locations[index]),
              destinations: destinations,
            ),
    );
  }
}
