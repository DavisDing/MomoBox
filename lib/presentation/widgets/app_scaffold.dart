import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';
import 'ai_assistant_dialog.dart';
import 'intake_sheet.dart';
import 'momo_floating_dock.dart';

class AppScaffold extends ConsumerStatefulWidget {
  const AppScaffold({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppScaffold> createState() => _AppScaffoldState();
}

class _AppScaffoldState extends ConsumerState<AppScaffold> {
  void _openQuickIntake(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const IntakeSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final location = GoRouterState.of(context).uri.path;

    // 5个入口:
    // 0: 首页 (/)
    // 1: 库存 (/inventory)
    // 2: 快捷入库 (居中主按钮)
    // 3: 家居 (/smart-home)
    // 4: 我的 (/profile 或 /settings)
    final currentIndex = switch (location) {
      '/inventory' => 1,
      '/smart-home' => 3,
      '/settings' || '/profile' => 4,
      _ => 0, // 默认首页
    };

    final useNavigationRail = MediaQuery.sizeOf(context).width >= 840;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      extendBody: true, // 允许底层内容穿透到底部悬浮胶囊后方自然滚动
      body: Stack(
        children: [
          // 底层主视图
          useNavigationRail
              ? Row(
                  children: [
                    SafeArea(
                      child: NavigationRail(
                        selectedIndex: currentIndex > 2
                            ? currentIndex - 1
                            : (currentIndex == 2 ? 0 : currentIndex),
                        labelType: NavigationRailLabelType.all,
                        leading: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: InkWell(
                            onTap: () => AiAssistantDialog.show(context),
                            borderRadius: BorderRadius.circular(24),
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: palette.primary.withValues(alpha: 0.18),
                                shape: BoxShape.circle,
                              ),
                              child: Text(palette.mascot, style: const TextStyle(fontSize: 24)),
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
                            label: Text(palette.inventoryLabel),
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
                    Expanded(child: widget.child),
                  ],
                )
              : widget.child,

          // 移动端：通用玻璃拟态悬浮胶囊底栏 (HyperOS × iOS 融合风格)
          // 悬浮在屏幕底部上方，左右留边距 24dp，不贴边，内容自底栏后方穿透滚动
          if (!useNavigationRail)
            Positioned(
              left: 24,
              right: 24,
              bottom: bottomInset > 0 ? bottomInset + 8 : 20,
              child: MomoFloatingCapsuleDock(
                currentIndex: currentIndex,
                onTapIndex: (index) {
                  switch (index) {
                    case 0:
                      context.go('/');
                      break;
                    case 1:
                      context.go('/inventory');
                      break;
                    case 3:
                      context.go('/smart-home');
                      break;
                    case 4:
                      context.go('/settings');
                      break;
                  }
                },
                onCenterAction: () => _openQuickIntake(context),
                centerLabel: '入库',
                centerMascot: palette.mascot,
              ),
            ),
        ],
      ),
    );
  }
}
