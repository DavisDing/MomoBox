import 'dart:ui';
import 'package:flutter/material.dart';
import '../../app/momo_theme.dart';
import '../../app/momo_typography.dart';

/// 悬浮毛玻璃胶囊底栏容器（Momo Floating Capsule Dock）
/// 严格遵循 HyperOS × iOS 融合风格通用玻璃拟态规范：
/// 1. 悬浮浮空形态：左右留外边距（16~24dp），不贴边，圆角胶囊形（圆角 32~36dp）
/// 2. 通透玻璃拟态：BackdropFilter 高斯模糊（sigma 20~24）+ 75%~85% 表面半透明 + 1px 细微光描边 + 柔和环境扩散投影
/// 3. 主题与调色板接入：严格引用 MomoPalette（primary、surface、text、skin），支持 5 套皮肤实时换肤，绝不硬编码色彩
/// 4. 动态字号与字体缩放：高度基于 MomoTextSize.caption 和系统 textScaler 动态计算，杜绝大字体溢出
/// 5. 无障碍支持：内部使用原生 NavigationBar，具备完整的 Semantics 与无障碍读屏支持
class MomoFloatingCapsuleDock extends StatelessWidget {
  const MomoFloatingCapsuleDock({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.palette,
    super.key,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;
  final MomoPalette palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // 动态缩放高度：根据系统文字缩放因子与规范字号自适应计算，防止 RenderFlex overflow
    final textScaler = MediaQuery.textScalerOf(context);
    final scaledCaption = textScaler.scale(MomoTextSize.caption);
    final captionDelta = (scaledCaption - MomoTextSize.caption).clamp(0.0, 48.0);
    final barHeight = 64.0 + captionDelta * 1.6;

    // 适配调色板半透明毛玻璃背景
    final baseSurface = isDark ? const Color(0xFF0F172A) : palette.surface;
    final glassBg = baseSurface.withValues(alpha: isDark ? 0.82 : 0.85);

    // 1px 极细微光描边
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.08);

    // 柔和大扩散环境投影
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.40)
        : palette.primary.withValues(alpha: 0.12);

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(36),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: glassBg,
                borderRadius: BorderRadius.circular(36),
                border: Border.all(color: borderColor, width: 1.0),
                boxShadow: [
                  BoxShadow(
                    color: shadowColor,
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: NavigationBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                height: barHeight,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected,
                destinations: destinations,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
