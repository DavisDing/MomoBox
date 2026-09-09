import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum MomoSkin { defaultSkin, momo, doraemon, forest, sakura }

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
    required this.mascotName,
    required this.appLogoIcon,
    required this.inventoryIcon,
    required this.alertIcon,
    required this.shoppingIcon,
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
  final String mascotName;
  final IconData appLogoIcon;
  final IconData inventoryIcon;
  final IconData alertIcon;
  final IconData shoppingIcon;
  final String inventoryLabel;
  final String alertLabel;
  final String shoppingLabel;

  static const defaultPalette = MomoPalette(
    skin: MomoSkin.defaultSkin,
    label: '默认主题（极简蓝）',
    primary: Color(0xFF4A90D9),
    secondary: Color(0xFF36CFC9),
    background: Color(0xFFF7F8FA),
    surface: Colors.white,
    text: Color(0xFF2C3E50),
    mascot: '📦',
    mascotName: '箱宝',
    appLogoIcon: Icons.all_inbox_rounded,
    inventoryIcon: Icons.inventory_2_outlined,
    alertIcon: Icons.notifications_none,
    shoppingIcon: Icons.shopping_bag_outlined,
    inventoryLabel: '库存',
    alertLabel: '提醒',
    shoppingLabel: '采买',
  );

  static const momoPalette = MomoPalette(
    skin: MomoSkin.momo,
    label: '嬷嬷典雅（复古红）',
    primary: Color(0xFFA63A3A),
    secondary: Color(0xFFD9A13B),
    background: Color(0xFFF5EBDD),
    surface: Color(0xFFFFFBF2),
    text: Color(0xFF3C3C3C),
    mascot: '👵',
    mascotName: '嬷嬷',
    appLogoIcon: Icons.inventory_rounded,
    inventoryIcon: Icons.archive_outlined,
    alertIcon: Icons.access_alarms_outlined,
    shoppingIcon: Icons.assignment_outlined,
    inventoryLabel: '百宝箱',
    alertLabel: '时效警',
    shoppingLabel: '采买折',
  );

  static const doraemonPalette = MomoPalette(
    skin: MomoSkin.doraemon,
    label: '哆啦A梦（活力蓝）',
    primary: Color(0xFF1E90D2),
    secondary: Color(0xFFFF4D4F),
    background: Color(0xFFF0F7FC),
    surface: Colors.white,
    text: Color(0xFF2A3B4C),
    mascot: '🔔',
    mascotName: '哆啦叮当',
    appLogoIcon: Icons.card_giftcard_rounded,
    inventoryIcon: Icons.widgets_outlined,
    alertIcon: Icons.hourglass_top_outlined,
    shoppingIcon: Icons.receipt_long_outlined,
    inventoryLabel: '四次元袋',
    alertLabel: '时光警报',
    shoppingLabel: '补给单',
  );

  static const forestPalette = MomoPalette(
    skin: MomoSkin.forest,
    label: '森林物语（自然绿）',
    primary: Color(0xFF2E7D32),
    secondary: Color(0xFF81C784),
    background: Color(0xFFF1F8E9),
    surface: Colors.white,
    text: Color(0xFF1B5E20),
    mascot: '🌲',
    mascotName: '森灵',
    appLogoIcon: Icons.eco_rounded,
    inventoryIcon: Icons.park_outlined,
    alertIcon: Icons.wb_twilight_outlined,
    shoppingIcon: Icons.shopping_basket_outlined,
    inventoryLabel: '林间储仓',
    alertLabel: '萌芽警报',
    shoppingLabel: '补种清单',
  );

  static const sakuraPalette = MomoPalette(
    skin: MomoSkin.sakura,
    label: '樱花漫舞（柔和粉）',
    primary: Color(0xFFD81B60),
    secondary: Color(0xFFFF80AB),
    background: Color(0xFFFDF2F4),
    surface: Colors.white,
    text: Color(0xFF4A1525),
    mascot: '🌸',
    mascotName: '小樱',
    appLogoIcon: Icons.local_florist_rounded,
    inventoryIcon: Icons.favorite_border_rounded,
    alertIcon: Icons.schedule_outlined,
    shoppingIcon: Icons.card_giftcard_outlined,
    inventoryLabel: '樱之锦囊',
    alertLabel: '花期提醒',
    shoppingLabel: '赏味心愿',
  );

  static List<MomoPalette> get allPalettes => [
        defaultPalette,
        momoPalette,
        doraemonPalette,
        forestPalette,
        sakuraPalette,
      ];

  static MomoPalette fromStoredValue(String? value) {
    return switch (value) {
      'momo' => momoPalette,
      'doraemon' => doraemonPalette,
      'forest' => forestPalette,
      'sakura' => sakuraPalette,
      _ => defaultPalette,
    };
  }

  String get storedValue => switch (skin) {
        MomoSkin.defaultSkin => 'default',
        MomoSkin.momo => 'momo',
        MomoSkin.doraemon => 'doraemon',
        MomoSkin.forest => 'forest',
        MomoSkin.sakura => 'sakura',
      };
}

ThemeData buildMomoTheme(MomoPalette palette, Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  // 对标 Xiaomi HyperOS 4 与 iOS 27 柔光半透底色
  final background = isDark ? const Color(0xFF0F172A) : palette.background;
  final surface = isDark ? const Color(0xFF1E293B) : palette.surface;
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
    // HyperOS 4 / iOS 27 超椭圆与柔光微边框卡片
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: (isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.04)),
          width: 0.8,
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: systemUiOverlayStyle,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: palette.primary.withValues(alpha: isDark ? 0.32 : 0.18),
      elevation: 0,
    ),
    textTheme: ThemeData(brightness: brightness).textTheme.apply(
          bodyColor: text,
          displayColor: text,
        ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF1E293B) : surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: palette.primary.withValues(alpha: 0.2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: (isDark ? Colors.white.withValues(alpha: 0.1) : palette.primary.withValues(alpha: 0.18)),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: palette.primary, width: 2.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colorScheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colorScheme.error, width: 2.0),
      ),
    ),
  );
}
