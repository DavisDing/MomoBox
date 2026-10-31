import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../app/momo_theme.dart';
import '../../app/momo_typography.dart';

/// Space a page must include at the end of its scrollable content.
///
/// Unlike MediaQuery.padding, this survives nested Scaffolds and SafeAreas.
/// Explicit ListView padding and CustomScrollView slivers must consume it;
/// publishing the inset alone does not add any scroll extent.
class MomoDockInsets extends InheritedWidget {
  const MomoDockInsets({required this.bottom, required super.child, super.key});

  final double bottom;

  static double bottomOf(BuildContext context) {
    // Shell sheets use its Navigator but occupy their own surface above the
    // dock. Regular pages pushed into that Navigator still need the inset.
    if (ModalRoute.of(context) is PopupRoute) {
      return 0;
    }
    return context
            .dependOnInheritedWidgetOfExactType<MomoDockInsets>()
            ?.bottom ??
        0;
  }

  @override
  bool updateShouldNotify(MomoDockInsets oldWidget) =>
      bottom != oldWidget.bottom;
}

/// Shared by the shell's content inset and the dock's actual layout.
@immutable
class MomoDockLayout {
  const MomoDockLayout._({
    required this.barHeight,
    required this.bottomSpacing,
    required this.horizontalMargin,
    required this.innerPadding,
    required this.destinationWidth,
    required this.labelFontSize,
  });

  static const topSpacing = 8.0;
  static const labelGap = 4.0;
  static const labelHorizontalPadding = 2.0;

  final double barHeight;
  final double bottomSpacing;
  final double horizontalMargin;
  final double innerPadding;
  final double destinationWidth;
  final double labelFontSize;

  double get occupiedHeight => topSpacing + barHeight + bottomSpacing;

  factory MomoDockLayout.resolve(
    BuildContext context,
    List<NavigationDestination> destinations, {
    required double availableWidth,
  }) {
    // Keep 48dp targets before spending width on the floating margins.
    final spareWidth = math.max(
      0.0,
      availableWidth - destinations.length * kMinInteractiveDimension,
    );
    final innerPadding = math.min(4.0, spareWidth / 2);
    final horizontalMargin = math.min(
      12.0,
      math.max(0.0, (spareWidth - innerPadding * 2) / 2),
    );
    final destinationWidth =
        (availableWidth - (horizontalMargin + innerPadding) * 2) /
        destinations.length;
    final labelFontSize = MediaQuery.textScalerOf(
      context,
    ).scale(MomoTextSize.caption);
    var labelHeight = 0.0;
    for (final destination in destinations) {
      final painter = TextPainter(
        text: TextSpan(
          text: destination.label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            fontSize: labelFontSize,
            height: 1.3,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: Directionality.of(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout(
        maxWidth: math.max(1.0, destinationWidth - labelHorizontalPadding * 2),
      );
      labelHeight = math.max(labelHeight, painter.height);
      painter.dispose();
    }
    return MomoDockLayout._(
      // Native indicators are 32dp high; leave 7dp above and below the group.
      barHeight: math.max(
        64.0,
        (32 + labelGap + labelHeight + 14).ceilToDouble(),
      ),
      bottomSpacing: math.max(8.0, MediaQuery.viewPaddingOf(context).bottom),
      horizontalMargin: horizontalMargin,
      innerPadding: innerPadding,
      destinationWidth: destinationWidth,
      labelFontSize: labelFontSize,
    );
  }
}

/// Floating glass chrome with native NavigationBar destinations and semantics.
class MomoFloatingCapsuleDock extends StatelessWidget {
  const MomoFloatingCapsuleDock({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.palette,
    this.layout,
    super.key,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;
  final MomoPalette palette;
  final MomoDockLayout? layout;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context) || MediaQuery.accessibleNavigationOf(context);
    final baseSurface = isDark ? theme.colorScheme.surface : palette.surface;
    final borderColor =
        isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.08);

    return SafeArea(
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final geometry =
              layout ??
              MomoDockLayout.resolve(
                context,
                destinations,
                availableWidth: constraints.maxWidth,
              );
          final radius = BorderRadius.circular(
            math.min(24, geometry.barHeight / 2),
          );
          final indicatorShape = _DockIndicatorBorder(
            maxWidth: math.max(0, geometry.destinationWidth - 8),
          );
          final labelStyle = WidgetStateProperty.resolveWith<TextStyle>((
            states,
          ) {
            final selected = states.contains(WidgetState.selected);
            return (theme.textTheme.labelMedium ?? const TextStyle()).copyWith(
              fontSize: geometry.labelFontSize,
              height: 1.3,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color:
                  states.contains(WidgetState.disabled)
                      ? theme.colorScheme.onSurface.withValues(alpha: 0.38)
                      : selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
            );
          });

          return Padding(
            padding: EdgeInsets.fromLTRB(
              geometry.horizontalMargin,
              MomoDockLayout.topSpacing,
              geometry.horizontalMargin,
              geometry.bottomSpacing,
            ),
            // Paint the shadow outside the clipping used by the blur/content.
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color:
                        isDark
                            ? Colors.black.withValues(alpha: 0.40)
                            : Colors.black.withValues(alpha: 0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: BackdropFilter(
                  enabled: !highContrast,
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: baseSurface.withValues(
                        alpha:
                            highContrast
                                ? 1
                                : isDark
                                ? 0.82
                                : 0.85,
                      ),
                      borderRadius: radius,
                      border: Border.all(
                        color:
                            highContrast
                                ? theme.colorScheme.onSurface
                                : borderColor,
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: geometry.innerPadding,
                      ),
                      // Safe insets are owned by the outer dock, once. Labels
                      // are scaled above so NavigationDestination's native 1.3x
                      // cap cannot discard the app/system accessibility scale.
                      child: MediaQuery.removePadding(
                        context: context,
                        removeTop: true,
                        removeBottom: true,
                        removeLeft: true,
                        removeRight: true,
                        child: MediaQuery.withNoTextScaling(
                          child: NavigationBar(
                            backgroundColor: Colors.transparent,
                            surfaceTintColor: Colors.transparent,
                            elevation: 0,
                            height: geometry.barHeight,
                            animationDuration:
                                MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 250),
                            indicatorColor: palette.primary.withValues(
                              alpha: isDark ? 0.32 : 0.18,
                            ),
                            indicatorShape: indicatorShape,
                            labelTextStyle: labelStyle,
                            labelPadding: const EdgeInsets.only(
                              top: MomoDockLayout.labelGap,
                              left: MomoDockLayout.labelHorizontalPadding,
                              right: MomoDockLayout.labelHorizontalPadding,
                            ),
                            labelBehavior:
                                NavigationDestinationLabelBehavior.alwaysShow,
                            selectedIndex: selectedIndex,
                            onDestinationSelected: onDestinationSelected,
                            destinations: destinations,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// NavigationBar fixes its indicator at 64dp. Bound the painted shape and ink
/// to the destination's actual width without replacing its native semantics.
class _DockIndicatorBorder extends ShapeBorder {
  const _DockIndicatorBorder({required this.maxWidth});

  final double maxWidth;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  ShapeBorder scale(double t) => _DockIndicatorBorder(maxWidth: maxWidth * t);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: rect.center,
            width: math.min(rect.width, maxWidth),
            height: rect.height,
          ),
          const Radius.circular(16),
        ),
      );

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  bool operator ==(Object other) =>
      other is _DockIndicatorBorder && maxWidth == other.maxWidth;

  @override
  int get hashCode => maxWidth.hashCode;
}
