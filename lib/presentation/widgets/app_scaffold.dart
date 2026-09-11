import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/momo_theme.dart';
import '../controllers/providers.dart';
import 'ai_assistant_dialog.dart';
import 'intake_sheet.dart';

class AppScaffold extends ConsumerStatefulWidget {
  const AppScaffold({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppScaffold> createState() => _AppScaffoldState();
}

class _AppScaffoldState extends ConsumerState<AppScaffold> {
  // 可拖拽悬浮按钮的偏量位置（相对右下角）
  Offset _fabOffset = const Offset(16, 80);

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
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

    final useNavigationRail = MediaQuery.sizeOf(context).width >= 840;
    final screenSize = MediaQuery.sizeOf(context);

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
        icon: Container(
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
          child: Text(palette.mascot, style: const TextStyle(fontSize: 22)),
        ),
        selectedIcon: Container(
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
          child: Text(palette.mascot, style: const TextStyle(fontSize: 22)),
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

    return Scaffold(
      body: Stack(
        children: [
          useNavigationRail
              ? Row(
                  children: [
                    SafeArea(
                      child: NavigationRail(
                        selectedIndex: currentIndex > 2 ? currentIndex - 1 : (currentIndex == 2 ? 0 : currentIndex),
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

          // 仅在库存页展示可拖拽悬浮入库按钮
          if (currentIndex == 1)
            Positioned(
              right: _fabOffset.dx,
              bottom: _fabOffset.dy,
              child: GestureDetector(
                onPanUpdate: (details) {
                  setState(() {
                    final newDx = _fabOffset.dx - details.delta.dx;
                    final newDy = _fabOffset.dy - details.delta.dy;
                    final clampedDx = newDx.clamp(12.0, (screenSize.width - 150).clamp(12.0, 500.0));
                    final clampedDy = newDy.clamp(70.0, (screenSize.height - 140).clamp(70.0, 900.0));
                    _fabOffset = Offset(clampedDx, clampedDy);
                  });
                },
                onPanEnd: (details) {
                  final isCloserToLeft = _fabOffset.dx > (screenSize.width / 2);
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
                        color: (isDark ? const Color(0xFF1E293B) : palette.surface).withValues(alpha: 0.82),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: (isDark ? Colors.white.withValues(alpha: 0.15) : palette.primary.withValues(alpha: 0.25)),
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
                      child: FloatingActionButton.extended(
                        tooltip: '入库',
                        elevation: 0,
                        focusElevation: 0,
                        hoverElevation: 0,
                        highlightElevation: 0,
                        backgroundColor: Colors.transparent,
                        foregroundColor: palette.primary,
                        splashColor: palette.primary.withValues(alpha: 0.12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          builder: (_) => const IntakeSheet(),
                        ),
                        icon: Icon(Icons.add_box_rounded, color: palette.primary, size: 22),
                        label: Text(
                          '入库',
                          style: TextStyle(
                            color: palette.primary,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: useNavigationRail
          ? null
          : ClipRRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  decoration: BoxDecoration(
                    color: (isDark ? const Color(0xFF0F172A) : palette.surface).withValues(alpha: 0.85),
                    border: Border(
                      top: BorderSide(
                        color: (isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06)),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: NavigationBar(
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    height: 64,
                    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                    selectedIndex: currentIndex,
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
                    destinations: destinations,
                  ),
                ),
              ),
            ),
    );
  }
}
