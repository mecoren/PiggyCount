import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'styles/tokens.dart';

class PiggyTheme {
  /// 文字主色（亮色模式）
  static const Color textDark = Color(0xFF333333);

  /// 从主题色派生亮色页面背景：取主题色色相，压到高明度，
  /// 让背景随用户换色保持同色系淡色（替代历史写死的淡蓝 #E5EEFE）。
  static Color deriveLightScaffoldBackground(Color primary) {
    final hsl = HSLColor.fromColor(primary);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.35, 0.85))
        .withLightness(0.95)
        .toColor();
  }

  static ThemeData lightTheme({required Color primary, TargetPlatform? platform}) {
    final base = ThemeData.light();
    final pf = platform ?? defaultTargetPlatform;
    final isIOS = pf == TargetPlatform.iOS || pf == TargetPlatform.macOS;
    final adjustedTextTheme =
        PiggyTypography.buildBase(base.textTheme, isIOS: isIOS)
            .apply(bodyColor: textDark, displayColor: textDark);
    final scaffoldBackground = deriveLightScaffoldBackground(primary);

    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: primary,
        secondary: primary,
        surface: PiggyTokens.cardBackgroundLightStatic,
      ),
      primaryColor: primary,
      scaffoldBackgroundColor: scaffoldBackground,
      dividerTheme: DividerThemeData(
        color: PiggyTokens.dividerStatic,
        thickness: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBackground, // 与页面背景融为一体
        foregroundColor: textDark,
        elevation: 0.0,
        centerTitle: true,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        // 圆角走 token（radiusXl = 16，恰与 M3 默认值相同，显式钉住防漂移）：
        // 全项目 FAB 只在这里声明一次，页面不要再逐处写 `shape:`。
        // 注意主题级 shape 会一并覆盖 FloatingActionButton.small(12) / .large(28)
        // 的 M3 默认形状，要用这两个变体必须自行传 `shape`。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        selectedItemColor: primary,
        unselectedItemColor: Colors.grey,
        showUnselectedLabels: true,
        backgroundColor: Colors.transparent, // 悬浮胶囊样式，外层透明
        elevation: 0,
      ),
      textTheme: adjustedTextTheme,
    );
  }

  static ThemeData darkTheme({required Color primary, TargetPlatform? platform}) {
    final base = ThemeData.dark();
    final pf = platform ?? defaultTargetPlatform;
    final isIOS = pf == TargetPlatform.iOS || pf == TargetPlatform.macOS;
    final adjusted = PiggyTypography.buildBase(base.textTheme, isIOS: isIOS)
        .apply(bodyColor: Colors.white, displayColor: Colors.white);

    return base.copyWith(
      brightness: Brightness.dark,
      colorScheme: base.colorScheme.copyWith(
        brightness: Brightness.dark,
        primary: primary,                    // ⭐ 主色
        onPrimary: Colors.black,             // ⭐ 主色上的前景色
        primaryContainer: primary,           // ⭐ Switch thumb 等组件使用
        onPrimaryContainer: Colors.black,    // ⭐ primaryContainer 上的前景色
        secondary: primary,                  // ⭐ 辅助色
        surface: PiggyTokens.cardBackgroundDarkStatic, // ⭐ 深蓝灰卡片
        onSurface: Colors.white,
      ),
      primaryColor: primary,     // ⭐ 主题色
      scaffoldBackgroundColor: PiggyTokens.scaffoldBackgroundDarkStatic, // ⭐ 深蓝灰页面背景
      appBarTheme: const AppBarTheme(
        backgroundColor: PiggyTokens.scaffoldBackgroundDarkStatic, // ⭐ 深蓝灰，与页面背景融为一体
        foregroundColor: Colors.white,
        elevation: 0.0,
        centerTitle: true,
        iconTheme: IconThemeData(color: Colors.white),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.black,   // 黑色文字（对比度更好）
        // 同亮色主题：FAB 圆角统一走 PiggyDimens.radiusXl（亮/暗不得分叉）
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        selectedItemColor: primary,
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
