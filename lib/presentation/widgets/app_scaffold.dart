import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';
import 'ai_assistant_dialog.dart';
import 'momo_floating_dock.dart';

class AppScaffold extends ConsumerWidget {
  const AppScaffold({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MomoPalette.fromStoredValue(
      ref.watch(themeNameProvider).valueOrNull,
    );
    final location = GoRouterState.of(context).uri.path;

    // 5个入口:
    // 0: 首页 (/)
    // 1: 库存 (/inventory)
    // 2: AI 助手（打开面板，不改变当前页面）
    // 3: 家居 (/smart-home)
    // 4: 我的 (/profile 或 /settings)
    final currentIndex = switch (location) {
      '/inventory' => 1,
      '/smart-home' => 3,
      '/settings' || '/profile' => 4,
      _ => 0, // 默认首页
    };

    final media = MediaQuery.of(context);
    final useNavigationRail = media.size.width >= 840;
    final showDock = !useNavigationRail && media.viewInsets.bottom == 0;

    const destinations = [
      NavigationDestination(
        icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: '首页',
      ),
      NavigationDestination(
        icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2_rounded), label: '库存',
      ),
      NavigationDestination(
        tooltip: 'AI 助手',
        icon: Icon(Icons.auto_awesome_outlined), label: 'AI 助手',
      ),
      NavigationDestination(
        icon: Icon(Icons.cottage_outlined), selectedIcon: Icon(Icons.cottage_rounded), label: '家居',
      ),
      NavigationDestination(
        icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: '我的',
      ),
    ];

    final dockLayout = MomoDockLayout.resolve(
      context,
      destinations,
      availableWidth: media.size.width - media.padding.horizontal,
    );
    final dockOccupiedHeight = showDock ? dockLayout.occupiedHeight : 0.0;
    return MomoDockInsets(
      bottom: dockOccupiedHeight,
      child: Scaffold(
        extendBody: true, // 允许底层内容穿透到底部悬浮胶囊底栏后方自然滚动
        // Scaffold publishes the measured bottom bar height to MediaQuery for
        // automatic padding consumers. Explicit page padding/slivers must use
        // MomoDockInsets instead; nested Scaffolds may remove MediaQuery.padding.
        body: Stack(
          children: [
            useNavigationRail
                ? Row(
                  children: [
                    SafeArea(
                      child: NavigationRail(
                        scrollable: true,
                        selectedIndex:
                            currentIndex > 2
                                ? currentIndex - 1
                                : (currentIndex == 2 ? 0 : currentIndex),
                        labelType: NavigationRailLabelType.all,
                        leading: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: IconButton(
                            tooltip: 'AI 助手',
                            padding: EdgeInsets.zero,
                            onPressed: () => AiAssistantDialog.show(context),
                            icon: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: palette.primary.withValues(alpha: 0.18),
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                palette.mascot,
                                style: const TextStyle(fontSize: 24, height: 1),
                              ),
                            ),
                          ),
                        ),
                        onDestinationSelected: (index) {
                          switch (index) {
                            case 0:
                              context.go('/');
                              break;
                            case 1:
                              context.go('/inventory');
                              break;
                            case 2:
                              context.go('/smart-home');
                              break;
                            case 3:
                              context.go('/settings');
                              break;
                          }
                        },
                        destinations: [
                          const NavigationRailDestination(
                            icon: Icon(Icons.home_outlined),
                            selectedIcon: Icon(Icons.home_rounded),
                            label: Text('首页'),
                          ),
                          NavigationRailDestination(
                            icon: Icon(palette.inventoryIcon),
                            selectedIcon: Icon(palette.inventoryIcon),
                            label: Text('库存'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.hub_outlined),
                            selectedIcon: Icon(Icons.hub_rounded),
                            label: Text('家居'),
                          ),
                          const NavigationRailDestination(
                            icon: Icon(Icons.person_outline_rounded),
                            selectedIcon: Icon(Icons.person_rounded),
                            label: Text('我的'),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      // Confine the nested Navigator's BlockSemantics to its
                      // own pane; otherwise it also hides the preceding rail.
                      child: LayoutBuilder(builder: (context, constraints) => MediaQuery(
                        data: media.copyWith(
                          size: Size(constraints.maxWidth, constraints.maxHeight),
                          padding: media.padding.copyWith(left: 0),
                          viewPadding: media.viewPadding.copyWith(left: 0),
                        ),
                        child: Semantics(
                          container: true,
                          explicitChildNodes: true,
                          child: child,
                        ),
                      )),
                    ),
                  ],
                )
                : child,

          ],
        ),
        // 底部悬浮毛玻璃胶囊 Dock：
        // 1. 悬浮浮空形态（左右留边，不贴底）
        // 2. 保留原生 NavigationBar 的点击、焦点及导航语义
        // 3. 动态字号自适应与调色板动态联动
        bottomNavigationBar:
            !showDock
                ? null
                : MomoFloatingCapsuleDock(
                  selectedIndex: currentIndex,
                  palette: palette,
                  destinations: destinations,
                  layout: dockLayout,
                  onDestinationSelected: (index) {
                    switch (index) {
                      case 0:
                        context.go('/');
                        break;
                      case 1:
                        context.go('/inventory');
                        break;
                      case 2:
                        AiAssistantDialog.show(context);
                        break;
                      case 3:
                        context.go('/smart-home');
                        break;
                      case 4:
                        context.go('/settings');
                        break;
                    }
                  },
                ),
      ),
    );
  }
}
