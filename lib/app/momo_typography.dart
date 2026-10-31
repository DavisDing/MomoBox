import 'package:flutter/material.dart';

/// Shared roles for all screens. Glyphs/mascot artwork may use their own size.
abstract final class MomoTextSize {
  static const double caption = 12;
  static const double body = 14;
  static const double title = 16;
  static const double section = 18;
  static const double page = 22;
  static const double metric = 28;
  static const double display = 36;
}

TextTheme buildMomoTextTheme(TextTheme base) => base.copyWith(
  displayLarge: base.displayLarge?.copyWith(fontSize: MomoTextSize.display, height: 1.15, letterSpacing: -0.5, fontWeight: FontWeight.w600),
  displayMedium: base.displayMedium?.copyWith(fontSize: MomoTextSize.display, height: 1.15, letterSpacing: -0.5, fontWeight: FontWeight.w600),
  displaySmall: base.displaySmall?.copyWith(fontSize: MomoTextSize.metric, height: 1.15, letterSpacing: -0.5, fontWeight: FontWeight.w600),
  headlineLarge: base.headlineLarge?.copyWith(fontSize: MomoTextSize.metric, height: 1.15, letterSpacing: -0.5, fontWeight: FontWeight.w600),
  headlineMedium: base.headlineMedium?.copyWith(fontSize: MomoTextSize.page, height: 1.25, letterSpacing: -0.3, fontWeight: FontWeight.w600),
  headlineSmall: base.headlineSmall?.copyWith(fontSize: MomoTextSize.page, height: 1.3, fontWeight: FontWeight.w600),
  titleLarge: base.titleLarge?.copyWith(fontSize: MomoTextSize.section, height: 1.3, fontWeight: FontWeight.w600),
  titleMedium: base.titleMedium?.copyWith(fontSize: MomoTextSize.title, height: 1.4, fontWeight: FontWeight.w600),
  titleSmall: base.titleSmall?.copyWith(fontSize: MomoTextSize.body, height: 1.4, fontWeight: FontWeight.w600),
  bodyLarge: base.bodyLarge?.copyWith(fontSize: MomoTextSize.title, height: 1.5),
  bodyMedium: base.bodyMedium?.copyWith(fontSize: MomoTextSize.body, height: 1.5),
  bodySmall: base.bodySmall?.copyWith(fontSize: MomoTextSize.caption, height: 1.4),
  labelLarge: base.labelLarge?.copyWith(fontSize: MomoTextSize.body, height: 1.3, fontWeight: FontWeight.w600),
  labelMedium: base.labelMedium?.copyWith(fontSize: MomoTextSize.caption, height: 1.3, fontWeight: FontWeight.w500),
  labelSmall: base.labelSmall?.copyWith(fontSize: MomoTextSize.caption, height: 1.3, fontWeight: FontWeight.w500),
);

/// Keep the OS accessibility curve and apply the app preference on top.
class MomoTextScaler extends TextScaler {
  const MomoTextScaler(this.system, this.preference);
  final TextScaler system;
  final double preference;

  @override
  double scale(double fontSize) => system.scale(fontSize) * preference;

  @override
  double get textScaleFactor => scale(MomoTextSize.body) / MomoTextSize.body;
}
