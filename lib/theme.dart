import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'styles/tokens.dart';

class PiggyTheme {
  // Brand colors - Light Mode
  static const Color honeyGold = Color(0xFFF8C91C); // 主色（亮色模式）
  static const Color hiveBrown = Color(0xFF8D6E63); // 辅助色
  static const Color energyOrange = Color(0xFFEF6C00); // 点缀色
  static const Color paperIvory = Color(0xFFFFF8E1); // 背景
  static const Color textDark = Color(0xFF333333); // 文字

  // Brand colors - Dark Mode ⭐ 改为与亮色模式相同（不减弱）
  static const Color honeyGoldDark = honeyGold; // 主色（暗黑模式 - 使用亮色）
  static const Color hiveBrownDark = hiveBrown; // 辅助色（暗黑模式 - 使用亮色）
  static const Color energyOrangeDark = energyOrange; // 点缀色（暗黑模式 - 使用亮色）

  static ThemeData lightTheme({TargetPlatform? platform}) {
    final base = ThemeData.light();
    final pf = platform ?? defaultTargetPlatform;
    final isIOS = pf == TargetPlatform.iOS || pf == TargetPlatform.macOS;
    final adjustedTextTheme =
        PiggyTypography.buildBase(base.textTheme, isIOS: isIOS)
            .apply(bodyColor: textDark, displayColor: textDark);

    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: honeyGold,
        secondary: energyOrange,
        surface: PiggyTokens.cardBackgroundLightStatic,
      ),
      primaryColor: honeyGold,
      scaffoldBackgroundColor: PiggyTokens.scaffoldBackgroundLightStatic,
      dividerTheme: DividerThemeData(
        color: PiggyTokens.dividerStatic,
        thickness: 1,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: PiggyTokens.scaffoldBackgroundLightStatic, // ⭐ 淡蓝，与页面背景融为一体
        foregroundColor: textDark,
        elevation: 0.0,
        centerTitle: true,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: honeyGold,
        foregroundColor: Colors.white,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        selectedItemColor: energyOrange,
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        backgroundColor: Colors.transparent, // 悬浮胶囊样式，外层透明
        elevation: 0,
      ),
      textTheme: adjustedTextTheme,
    );
  }

  static ThemeData darkTheme({TargetPlatform? platform}) {
    final base = ThemeData.dark();
    final pf = platform ?? defaultTargetPlatform;
    final isIOS = pf == TargetPlatform.iOS || pf == TargetPlatform.macOS;
    final adjusted = PiggyTypography.buildBase(base.textTheme, isIOS: isIOS)
        .apply(bodyColor: Colors.white, displayColor: Colors.white);

    return base.copyWith(
      brightness: Brightness.dark,
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        primary: honeyGoldDark,              // ⭐ 主色
        onPrimary: Colors.black,             // ⭐ 主色上的前景色
        primaryContainer: honeyGoldDark,     // ⭐ Switch thumb 等组件使用
        onPrimaryContainer: Colors.black,    // ⭐ primaryContainer 上的前景色
        secondary: energyOrangeDark,         // ⭐ 辅助色
        surface: PiggyTokens.cardBackgroundDarkStatic, // ⭐ 深蓝灰卡片
        onSurface: Colors.white,
      ),
      primaryColor: honeyGoldDark,     // ⭐ 主题色
      scaffoldBackgroundColor: PiggyTokens.scaffoldBackgroundDarkStatic, // ⭐ 深蓝灰页面背景
      appBarTheme: const AppBarTheme(
        backgroundColor: PiggyTokens.scaffoldBackgroundDarkStatic, // ⭐ 深蓝灰，与页面背景融为一体
        foregroundColor: Colors.white,
        elevation: 0.0,
        centerTitle: true,
        iconTheme: IconThemeData(color: Colors.white),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: honeyGoldDark,  // ⭐ 深金色
        foregroundColor: Colors.black,   // 黑色文字（对比度更好）
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        selectedItemColor: honeyGoldDark, // ⭐ 深金色
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        backgroundColor: Colors.transparent, // 悬浮胶囊样式，外层透明
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: PiggyTokens.cardBackgroundDarkStatic, // ⭐ 深蓝灰卡片
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXl), // ⭐ 与亮色统一为 radiusXl
          side: BorderSide(
            color: Colors.white.withValues(alpha: 0.1), // ⭐ 白色边框
            width: 1,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: PiggyTokens.dividerDarkStatic, // ⭐ 白色分割线（与 Token 单一来源）
        thickness: 1,
      ),
      iconTheme: const IconThemeData(
        color: Colors.white,
      ),
      textTheme: adjusted,
    );
  }

  /// 统一开关主题（亮/暗共用），参照 wait-home switchTheme：
  /// 无描边、选中纯色轨道、白色 thumb。
  /// 使用 [shrinkWrap] 缩小触控尺寸，让开关更紧凑（用户要求「不要现在这么大」）。
  /// [primary] 由 main.dart 动态主题色注入，保证开关跟随用户选色。
  static SwitchThemeData switchThemeData(Color primary, {required bool isDark}) {
    final trackBase = isDark
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.3);
    return SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return primary;
        }
        return trackBase;
      }),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      trackOutlineWidth: WidgetStateProperty.all(0),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
