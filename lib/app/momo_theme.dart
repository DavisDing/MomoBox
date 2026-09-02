import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum MomoSkin { defaultSkin, momo, doraemon }

class MomoPalette {
  const MomoPalette({
    required this.skin,
    required this.label,
    required this.primary,
    required this.secondary,
    required this.background,
    required this.surface,
    required this.text,
    required this.mascot,
    required this.inventoryLabel,
    required this.alertLabel,
    required this.shoppingLabel,
  });

  final MomoSkin skin;
  final String label;
  final Color primary;
  final Color secondary;
  final Color background;
  final Color surface;
  final Color text;
  final String mascot;
  final String inventoryLabel;
  final String alertLabel;
  final String shoppingLabel;

  static const defaultPalette = MomoPalette(
    skin: MomoSkin.defaultSkin,
    label: '默认主题',
    primary: Color(0xFF4A90D9),
    secondary: Color(0xFF36CFC9),
    background: Color(0xFFF7F8FA),
    surface: Colors.white,
    text: Color(0xFF2C3E50),
    mascot: '📦',
    inventoryLabel: '库存',
    alertLabel: '提醒',
    shoppingLabel: '采买',
  );

  static const momoPalette = MomoPalette(
    skin: MomoSkin.momo,
    label: '嬷嬷主题',
    primary: Color(0xFFA63A3A),
    secondary: Color(0xFFD9A13B),
    background: Color(0xFFF5EBDD),
    surface: Color(0xFFFFFBF2),
    text: Color(0xFF3C3C3C),
    mascot: '👵',
    inventoryLabel: '百宝箱',
    alertLabel: '时效警',
    shoppingLabel: '采买折',
  );

  static const doraemonPalette = MomoPalette(
    skin: MomoSkin.doraemon,
    label: '哆啦A梦主题',
    primary: Color(0xFF1E90D2),
    secondary: Color(0xFFFF4D4F),
    background: Color(0xFFF0F7FC),
    surface: Colors.white,
    text: Color(0xFF2A3B4C),
    mascot: '🔔',
    inventoryLabel: '四次元袋',
    alertLabel: '时光警报',
    shoppingLabel: '补给单',
  );

  static MomoPalette fromStoredValue(String? value) {
    return switch (value) {
      'momo' => momoPalette,
      'doraemon' => doraemonPalette,
      _ => defaultPalette,
    };
  }

  String get storedValue => switch (skin) {
        MomoSkin.defaultSkin => 'default',
        MomoSkin.momo => 'momo',
        MomoSkin.doraemon => 'doraemon',
      };
}

ThemeData buildMomoTheme(MomoPalette palette, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final background = isDark ? const Color(0xFF101827) : palette.background;
  final surface = isDark ? const Color(0xFF1F2937) : palette.surface;
  final text = isDark ? const Color(0xFFF8FAFC) : palette.text;
  final colorScheme = ColorScheme.fromSeed(
    seedColor: palette.primary,
    brightness: brightness,
    primary: palette.primary,
    secondary: palette.secondary,
    surface: surface,
  );
  final systemUiOverlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    statusBarBrightness: brightness,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: background,
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: text,
      elevation: 0,
      centerTitle: false,
      systemOverlayStyle: systemUiOverlayStyle,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surface,
      indicatorColor: palette.primary.withOpacity(isDark ? 0.28 : 0.16),
    ),
    textTheme: ThemeData(brightness: brightness).textTheme.apply(
          bodyColor: text,
          displayColor: text,
        ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.primary.withOpacity(0.14)),
      ),
    ),
  );
}
