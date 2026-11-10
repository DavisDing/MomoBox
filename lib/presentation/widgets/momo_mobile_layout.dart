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
    this.eyebrow,
    this.subtitle,
    this.actions = const [],
    super.key,
  });

  final String title;
  final String? eyebrow;
  final Widget? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (eyebrow != null) ...[
          Text(eyebrow!, style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant, letterSpacing: 1.1)),
          const SizedBox(height: 6),
        ],
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.headlineLarge),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
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
      padding: const EdgeInsets.only(top: 4, bottom: 12),
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

/// The same quiet household entry anchors every collection page.
class MomoHouseholdBar extends StatelessWidget {
  const MomoHouseholdBar({required this.onPressed, this.actions = const [], super.key});

  final VoidCallback onPressed;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 4),
    child: Row(children: [
      Expanded(child: Align(alignment: Alignment.centerLeft, child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(44, 44),
        ),
        icon: Icon(Icons.home_outlined, size: 18, color: Theme.of(context).colorScheme.primary),
        label: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 5, children: [
          Text('我的小家', style: Theme.of(context).textTheme.labelLarge),
          const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
        ]),
      ))),
      ...actions,
    ]),
  );
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
