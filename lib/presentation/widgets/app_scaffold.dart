import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/momo_theme.dart';
import '../../app/momo_typography.dart';
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
  // 可拖拽悬浮按钮的偏量位置（相对右下角，专用于库存页）
  Offset _fabOffset = const Offset(16, 12);

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(
      ref.watch(themeNameProvider).valueOrNull,
    );
    final location = GoRouterState.of(context).uri.path;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 5个入口:
    // 0: 首页 (/)
    // 1: 库存 (/inventory)
    // 2: AI 助手 (居中呼吸按钮，呼出面板)
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
    final screenSize = media.size;
    final showDock = !useNavigationRail && media.viewInsets.bottom == 0;
    final showInventoryFab = currentIndex == 1 && media.viewInsets.bottom == 0;

    final destinations = [
      const NavigationDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home_rounded),
        label: '首页',
      ),
      NavigationDestination(
        icon: Icon(palette.inventoryIcon),
        selectedIcon: Icon(palette.inventoryIcon),
        label: palette.inventoryLabel,
      ),
      NavigationDestination(
        tooltip: 'AI 助手',
        icon: Semantics(
          label: 'AI 助手',
          excludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: palette.primary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: palette.primary.withValues(alpha: 0.25),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Text(
              palette.mascot,
              style: const TextStyle(fontSize: 22, height: 1),
            ),
          ),
        ),
        selectedIcon: Semantics(
          label: 'AI 助手',
          excludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: palette.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: palette.primary.withValues(alpha: 0.4),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Text(
              palette.mascot,
              style: const TextStyle(fontSize: 22, height: 1),
            ),
          ),
        ),
        label: palette.mascotName,
      ),
      const NavigationDestination(
        icon: Icon(Icons.hub_outlined),
        selectedIcon: Icon(Icons.hub_rounded),
        label: '家居',
      ),
      const NavigationDestination(
        icon: Icon(Icons.person_outline_rounded),
        selectedIcon: Icon(Icons.person_rounded),
        label: '我的',
      ),
    ];

    final dockLayout = MomoDockLayout.resolve(
      context,
      destinations,
      availableWidth: media.size.width - media.padding.horizontal,
    );
    final dockOccupiedHeight = showDock ? dockLayout.occupiedHeight : 0.0;
    final fabLabelStyle = theme.textTheme.labelLarge!.copyWith(
      fontSize: MomoTextSize.body,
      height: 1.3,
      fontWeight: FontWeight.bold,
      color: palette.primary,
    );
    final fabLabel = TextPainter(
      text: TextSpan(text: '入库', style: fabLabelStyle),
      textScaler: media.textScaler,
      textDirection: Directionality.of(context),
    )..layout();
    final fabHeight = math.max(56.0, fabLabel.height + 24);
    fabLabel.dispose();

    return MomoDockInsets(
      bottom: dockOccupiedHeight + (showInventoryFab ? fabHeight + 12 : 0),
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
                    Expanded(
                      // Confine the nested Navigator's BlockSemantics to its
                      // own pane; otherwise it also hides the preceding rail.
                      child: Semantics(
                        container: true,
                        explicitChildNodes: true,
                        child: widget.child,
                      ),
                    ),
                  ],
                )
                : widget.child,

            // 仅在库存页展示可拖拽悬浮入库按钮（避免首页出现多个入库入口）
            if (showInventoryFab)
              Positioned(
                right: _fabOffset.dx,
                bottom: dockOccupiedHeight + _fabOffset.dy,
                child: GestureDetector(
                  onPanUpdate: (details) {
                    setState(() {
                      final newDx = _fabOffset.dx - details.delta.dx;
                      final newDy = _fabOffset.dy - details.delta.dy;
                      final clampedDx = newDx.clamp(
                        12.0,
                        (screenSize.width - 150).clamp(12.0, 500.0),
                      );
                      final clampedDy = newDy.clamp(
                        12.0,
                        math.max(
                          12.0,
                          screenSize.height -
                              dockOccupiedHeight -
                              fabHeight -
                              media.padding.top -
                              12,
                        ),
                      );
                      _fabOffset = Offset(
                        clampedDx.toDouble(),
                        clampedDy.toDouble(),
                      );
                    });
                  },
                  onPanEnd: (details) {
                    final isCloserToLeft =
                        _fabOffset.dx > (screenSize.width / 2);
                    setState(() {
                      _fabOffset = Offset(
                        isCloserToLeft ? screenSize.width - 156 : 16,
                        _fabOffset.dy,
                      );
                    });
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface.withValues(
                            alpha: 0.82,
                          ),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color:
                                (isDark
                                    ? Colors.white.withValues(alpha: 0.15)
                                    : palette.primary.withValues(alpha: 0.25)),
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: palette.primary.withValues(alpha: 0.22),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Theme(
                          data: theme.copyWith(
                            floatingActionButtonTheme: theme
                                .floatingActionButtonTheme
                                .copyWith(
                                  extendedSizeConstraints:
                                      BoxConstraints.tightFor(
                                        height: fabHeight,
                                      ),
                                ),
                          ),
                          child: FloatingActionButton.extended(
                            tooltip: '入库',
                            elevation: 0,
                            focusElevation: 0,
                            hoverElevation: 0,
                            highlightElevation: 0,
                            backgroundColor: Colors.transparent,
                            foregroundColor: palette.primary,
                            splashColor: palette.primary.withValues(
                              alpha: 0.12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                            onPressed:
                                () => showModalBottomSheet<void>(
                                  context: context,
                                  isScrollControlled: true,
                                  useSafeArea: true,
                                  builder: (_) => const IntakeSheet(),
                                ),
                            icon: Icon(
                              Icons.add_box_rounded,
                              color: palette.primary,
                              size: 22,
                            ),
                            label: Text('入库', style: fabLabelStyle),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
