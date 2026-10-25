import 'momo_typography.dart';
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
  // Material colors live here so every skin and component shares dark mode.
  final background = isDark ? Colors.black : palette.background;
  final surface = isDark ? const Color(0xFF1C1C1E) : palette.surface;
  final text = isDark ? Colors.white : palette.text;
  final action = isDark ? Colors.white : Colors.black;
  final onAction = isDark ? Colors.black : Colors.white;
  final outline = text.withValues(alpha: isDark ? 0.14 : 0.08);
  final colorScheme = ColorScheme.fromSeed(
    seedColor: palette.primary,
    brightness: brightness,
    primary: palette.primary,
    secondary: palette.secondary,
    surface: surface,
    onSurface: text,
  );
  final systemUiOverlayStyle = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    statusBarBrightness: brightness,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness:
        isDark ? Brightness.light : Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );

  final textTheme = buildMomoTextTheme(
    ThemeData(brightness: brightness).textTheme,
  ).apply(bodyColor: text, displayColor: text);

  return ThemeData(
    useMaterial3: true,
    buttonTheme: const ButtonThemeData(alignedDropdown: true),
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: background,
    // Content cards stay solid; floating materials opt into backdrop blur.
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: outline, width: 0.5),
      ),
    ),
    // 全局胶囊按钮风格
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        backgroundColor: action,
        foregroundColor: onAction,
        disabledBackgroundColor: action.withValues(alpha: 0.3),
        disabledForegroundColor: onAction.withValues(alpha: 0.3),
        minimumSize: const Size(48, 48),
        shape: const StadiumBorder(),
        textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        backgroundColor: surface.withValues(alpha: isDark ? 0.8 : 0.82),
        disabledForegroundColor: text.withValues(alpha: 0.3),
        minimumSize: const Size(48, 48),
        shape: const StadiumBorder(),
        side: BorderSide(color: outline, width: 1),
        textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: action,
        foregroundColor: onAction,
        disabledBackgroundColor: action.withValues(alpha: 0.3),
        disabledForegroundColor: onAction.withValues(alpha: 0.3),
        elevation: 0,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: const StadiumBorder(),
        textStyle: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.primary,
        shape: const StadiumBorder(),
        minimumSize: const Size(44, 44),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: const CircleBorder(),
        highlightColor: text.withValues(alpha: 0.1),
      ),
    ),
    listTileTheme: ListTileThemeData(
      minTileHeight: 56,
      iconColor: text.withValues(alpha: 0.7),
      textColor: text,
      titleTextStyle: textTheme.titleMedium,
      subtitleTextStyle: textTheme.bodyMedium?.copyWith(
        color: colorScheme.onSurfaceVariant,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    dividerTheme: DividerThemeData(color: outline, thickness: 0.5),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled) ? null : Colors.white,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.disabled)
                ? null
                : states.contains(WidgetState.selected)
                ? palette.primary
                : colorScheme.surfaceContainerHighest,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surface,
      selectedColor: palette.primary.withValues(alpha: isDark ? 0.2 : 0.1),
      side: BorderSide(color: outline, width: 0.5),
      shape: const StadiumBorder(),
      labelStyle: textTheme.bodyMedium,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: text,
      unselectedLabelColor: colorScheme.onSurfaceVariant,
      labelStyle: textTheme.labelLarge,
      indicatorColor: palette.primary,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: outline,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color:
              isDark
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.black.withValues(alpha: 0.06),
          width: 0.8,
        ),
      ),
      textStyle: TextStyle(
        color: text,
        fontSize: MomoTextSize.body,
        fontWeight: FontWeight.w500,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    appBarTheme: AppBarTheme(
      // Navigation belongs to the page canvas, not the raised card surface.
      // Keep native/sliver bars consistent with the shared glass app bar.
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle: systemUiOverlayStyle,
      titleTextStyle: textTheme.titleLarge,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: palette.primary.withValues(alpha: isDark ? 0.32 : 0.18),
      elevation: 0,
      labelTextStyle: WidgetStatePropertyAll(textTheme.labelMedium),
    ),
    textTheme: textTheme,
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Colors.black.withValues(alpha: 0.8),
      contentTextStyle: TextStyle(
        color: Colors.white,
        fontSize: MomoTextSize.body,
        fontWeight: FontWeight.w500,
      ),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: const StadiumBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      labelStyle: textTheme.bodyMedium,
      hintStyle: textTheme.bodyMedium?.copyWith(
        color: colorScheme.onSurfaceVariant,
      ),
      helperStyle: textTheme.bodySmall,
      errorStyle: textTheme.bodySmall,
      errorMaxLines: 3,
      filled: true,
      fillColor: text.withValues(alpha: isDark ? 0.08 : 0.04),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: palette.primary, width: 2.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colorScheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colorScheme.error, width: 2.0),
      ),
    ),
  );
}

class MomoAppInfo {
  // Release builds inject the same values used by --build-name/--build-number.
  static const String appVersion = String.fromEnvironment(
    'MOMO_APP_VERSION',
    defaultValue: '0.1.0',
  );
  static const String buildNumber = String.fromEnvironment(
    'MOMO_BUILD_NUMBER',
    defaultValue: '1',
  );
  static const String versionDisplay = '$appVersion（构建 $buildNumber）';
}
