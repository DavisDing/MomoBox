import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/momo_typography.dart';

/// Size content for the available pane, including landscape cutouts. Text
/// remains at the user's chosen scale; layout changes instead of shrinking it.
abstract final class MomoMobileLayout {
  static EdgeInsets pageInsets(BuildContext context) {
    final media = MediaQuery.of(context);
    final gutter = media.size.width < 360 ? 16.0 : 20.0;
    final extra = math.max(0.0, (media.size.width - 720) / 2);
    return EdgeInsets.only(
      left: math.max(media.padding.left, gutter + extra),
      right: math.max(media.padding.right, gutter + extra),
    );
  }

  static bool stack(BuildContext context, double width, {double minimum = 360}) {
    final scale = MediaQuery.textScalerOf(context).scale(MomoTextSize.body) /
        MomoTextSize.body;
    return width < minimum * math.max(1.0, scale);
  }
}

class MomoPageHeader extends StatelessWidget {
  const MomoPageHeader({
    required this.title,
    this.subtitle,
    this.actions = const [],
    super.key,
  });

  final String title;
  final Widget? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.headlineLarge),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          DefaultTextStyle(
            style: theme.textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            child: subtitle!,
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 20),
      child: LayoutBuilder(builder: (context, constraints) {
        if (actions.isEmpty) return heading;
        final controls = Wrap(spacing: 4, runSpacing: 4, children: actions);
        if (MomoMobileLayout.stack(context, constraints.maxWidth, minimum: 300)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [heading, const SizedBox(height: 12), controls],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: heading),
            const SizedBox(width: 12),
            controls,
          ],
        );
      }),
    );
  }
}

/// Intrinsic-height tiles: a phone gets two columns only when both text and
/// touch targets fit. Large text and narrow panes naturally become a list.
class MomoAdaptiveTiles extends StatelessWidget {
  const MomoAdaptiveTiles({required this.children, this.minimumWidth = 148, super.key});

  final List<Widget> children;
  final double minimumWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(MomoTextSize.body) /
          MomoTextSize.body;
      final columns = ((constraints.maxWidth + 12) / (minimumWidth * math.max(1.0, scale) + 12))
          .floor().clamp(1, 2);
      final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [for (final child in children) SizedBox(width: width, child: child)],
      );
    },
  );
}
