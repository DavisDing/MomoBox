import 'dart:ui';
import 'package:flutter/material.dart';
import '../../app/momo_typography.dart';

/// 通用悬浮操作项数据模型
class MomoFloatingActionItem {
  const MomoFloatingActionItem({
    required this.id,
    required this.label,
    required this.icon,
    this.isDestructive = false,
    this.badge,
  });

  final String id;
  final String label;
  final IconData icon;
  final bool isDestructive;
  final String? badge;
}

/// 批量操作悬浮栏（Floating Action Bar）
/// 严格遵循通用玻璃拟态规范：
/// - 胶囊形大圆角（圆角 28dp+），白色半透明（75%~85%）+ backdrop-blur (sigma 24)
/// - 1px 细微光描边 + 柔和大扩散投影
/// - 横向等宽排列 4~6 项，垂直居中布局（线性图标 22dp + 12px 标签）
/// - 删除/危险操作仅图标与文字着红色，风格克制绝不刺眼
class MomoFloatingActionBar extends StatelessWidget {
  const MomoFloatingActionBar({
    required this.items,
    required this.onActionSelected,
    this.onClose,
    this.title,
    super.key,
  });

  final List<MomoFloatingActionItem> items;
  final ValueChanged<String> onActionSelected;
  final VoidCallback? onClose;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bgColor = isDark
        ? const Color(0xFF1E293B).withValues(alpha: 0.85)
        : Colors.white.withValues(alpha: 0.82);

    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.70);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null && title!.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? Colors.black.withValues(alpha: 0.6) : Colors.black.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (onClose != null) ...[
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: onClose,
                    child: const Icon(Icons.close_rounded, size: 14, color: Colors.white70),
                  ),
                ],
              ],
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              height: 68,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(32),
                border: Border.all(color: borderColor, width: 1.0),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                    blurRadius: 28,
                    offset: const Offset(0, 10),
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: items.map((item) {
                  return Expanded(
                    child: _buildItem(context, item, isDark),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildItem(BuildContext context, MomoFloatingActionItem item, bool isDark) {
    final color = item.isDestructive
        ? const Color(0xFFFF453A)
        : (isDark ? Colors.white.withValues(alpha: 0.9) : const Color(0xFF1F2937));

    return InkWell(
      onTap: () => onActionSelected(item.id),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(item.icon, size: 22, color: color),
            const SizedBox(height: 3),
            Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: color.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部常态悬浮胶囊导航栏（Momo Floating Capsule Dock）
/// 融合 HyperOS × iOS 玻璃拟态体系：
/// - 浮空于内容之上，左右边距 24dp，底边距 24~34dp（适配 iPhone Home Bar）
/// - 容器高 66dp，半透明毛玻璃背景 + 1px 极细微光描边 + 柔和环境扩散投影
/// - 4 个导航 Entry + 1 个居中主操作胶囊（快捷入库）
class MomoFloatingCapsuleDock extends StatelessWidget {
  const MomoFloatingCapsuleDock({
    required this.currentIndex,
    required this.onTapIndex,
    required this.onCenterAction,
    this.centerLabel = '入库',
    this.centerMascot,
    super.key,
  });

  final int currentIndex;
  final ValueChanged<int> onTapIndex;
  final VoidCallback onCenterAction;
  final String centerLabel;
  final String? centerMascot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bgColor = isDark
        ? const Color(0xFF1E293B).withValues(alpha: 0.85)
        : Colors.white.withValues(alpha: 0.82);

    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.white.withValues(alpha: 0.75);

    return ClipRRect(
      borderRadius: BorderRadius.circular(36),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          height: 66,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(36),
            border: Border.all(color: borderColor, width: 1.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                blurRadius: 30,
                offset: const Offset(0, 10),
                spreadRadius: -4,
              ),
            ],
          ),
          child: Row(
            children: [
              // 0: 首页
              Expanded(
                child: _buildNavTab(
                  index: 0,
                  label: '首页',
                  iconOutline: Icons.home_outlined,
                  iconFilled: Icons.home_rounded,
                  isDark: isDark,
                ),
              ),
              // 1: 库存
              Expanded(
                child: _buildNavTab(
                  index: 1,
                  label: '库存',
                  iconOutline: Icons.inventory_2_outlined,
                  iconFilled: Icons.inventory_2_rounded,
                  isDark: isDark,
                ),
              ),
              // 居中快捷操作：胶囊形主按钮 (Primary Action Capsule)
              // 浅色模式：纯黑背景 + 白字；深色模式反色，遵循设计规范
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _buildCenterCapsuleButton(context, isDark),
              ),
              // 3: 家居
              Expanded(
                child: _buildNavTab(
                  index: 3,
                  label: '家居',
                  iconOutline: Icons.hub_outlined,
                  iconFilled: Icons.hub_rounded,
                  isDark: isDark,
                ),
              ),
              // 4: 我的
              Expanded(
                child: _buildNavTab(
                  index: 4,
                  label: '我的',
                  iconOutline: Icons.person_outline_rounded,
                  iconFilled: Icons.person_rounded,
                  isDark: isDark,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavTab({
    required int index,
    required String label,
    required IconData iconOutline,
    required IconData iconFilled,
    required bool isDark,
  }) {
    final isSelected = currentIndex == index;
    final activeColor = isDark ? Colors.white : const Color(0xFF111827);
    final inactiveColor = isDark
        ? Colors.white.withValues(alpha: 0.45)
        : const Color(0xFF6B7280);

    return InkWell(
      onTap: () => onTapIndex(index),
      borderRadius: BorderRadius.circular(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedScale(
            scale: isSelected ? 1.08 : 1.0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutBack,
            child: Icon(
              isSelected ? iconFilled : iconOutline,
              size: 22,
              color: isSelected ? activeColor : inactiveColor,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              color: isSelected ? activeColor : inactiveColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterCapsuleButton(BuildContext context, bool isDark) {
    final capsuleBg = isDark ? Colors.white : const Color(0xFF111827);
    final capsuleFg = isDark ? const Color(0xFF111827) : Colors.white;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onCenterAction,
        borderRadius: BorderRadius.circular(24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: capsuleBg,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.18),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (centerMascot != null && centerMascot!.isNotEmpty) ...[
                Text(centerMascot!, style: const TextStyle(fontSize: 15)),
                const SizedBox(width: 4),
              ] else ...[
                Icon(Icons.add_rounded, size: 18, color: capsuleFg),
                const SizedBox(width: 2),
              ],
              Text(
                centerLabel,
                style: TextStyle(
                  color: capsuleFg,
                  fontSize: MomoTextSize.caption,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
