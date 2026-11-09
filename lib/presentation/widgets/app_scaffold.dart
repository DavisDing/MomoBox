import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';
import 'momo_floating_dock.dart';

class AppScaffold extends ConsumerWidget {
  const AppScaffold({required this.child, super.key});
  final Widget child;

  static const paths = ['/assistant', '/inventory', '/', '/smart-home', '/settings'];
  static const labels = ['助手', '物品', '今日', '家居', '设置'];
  static const icons = [Icons.auto_awesome_outlined, Icons.grid_view_outlined,
    Icons.home_outlined, Icons.chair_outlined, Icons.tune_rounded];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final location = GoRouterState.of(context).uri.path;
    final selected = location == '/profile' ? 4 : paths.indexOf(location);
    final index = selected < 0 ? 2 : selected;
    final media = MediaQuery.of(context);
    final rail = media.size.width >= 840;
    final showDock = !rail && media.viewInsets.bottom == 0;
    void navigate(int value) => context.go(paths[value]);
    final destinations = List.generate(paths.length, (i) => NavigationDestination(
      icon: Icon(icons[i]), label: labels[i],
      selectedIcon: Icon(i == 2 ? Icons.home_rounded : icons[i],
        color: i == 2 ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.primary),
    ));
    final geometry = MomoDockLayout.resolve(context, destinations,
      availableWidth: media.size.width - media.padding.horizontal);
    return MomoDockInsets(
      bottom: showDock ? geometry.occupiedHeight : 0,
      child: Scaffold(
        extendBody: true,
        body: rail ? Row(children: [
          SafeArea(child: NavigationRail(
            scrollable: true, selectedIndex: index,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: navigate,
            destinations: List.generate(paths.length, (i) => NavigationRailDestination(
              icon: Icon(icons[i]), label: Text(labels[i]),
            )),
          )),
          const VerticalDivider(width: 1),
          Expanded(child: LayoutBuilder(builder: (context, constraints) => MediaQuery(
            data: media.copyWith(size: Size(constraints.maxWidth, constraints.maxHeight),
              padding: media.padding.copyWith(left: 0),
              viewPadding: media.viewPadding.copyWith(left: 0)),
            child: Semantics(container: true, explicitChildNodes: true, child: child),
          ))),
        ]) : child,
        bottomNavigationBar: showDock ? MomoFloatingCapsuleDock(
          selectedIndex: index, onDestinationSelected: navigate,
          destinations: destinations, palette: palette, layout: geometry,
        ) : null,
      ),
    );
  }
}
