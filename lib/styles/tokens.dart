import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/theme_providers.dart';

/// PiggyCount Design Token 系统
///
/// 设计理念：类似 CSS Design Tokens，通过语义化命名统一管理颜色。
/// 所有 UI 组件都应该使用 Token 而非直接使用颜色值。
///
/// Token 分类：
/// 1. Surface（背景色）- 页面、卡片、弹窗等背景
/// 2. Text（文字颜色）- 标题、正文、提示、禁用等
/// 3. Icon（图标颜色）- 主要、次要、提示图标
/// 4. Border（边框/分割线）- 卡片边框、列表分割线
/// 5. Semantic（语义色）- 成功、警告、错误、信息
/// 6. Interactive（交互色）- 按钮、链接、选中状态
/// 7. Brand（品牌图标色）- 各服务品牌固定色
///
/// 使用示例：
/// ```dart
/// Container(
///   color: PiggyTokens.surface(context),
///   child: Text(
///     'Hello',
///     style: TextStyle(color: PiggyTokens.textPrimary(context)),
///   ),
/// )
/// ```
class PiggyTokens {
  // ========== 背景色 Token (Surface) ==========

  /// 页面背景色（Scaffold 背景）
  /// - 亮色模式：随主题色派生的同色系淡色（见 PiggyTheme.deriveLightScaffoldBackground）
  /// - 暗黑模式：#151A24 (深蓝灰)
  /// 直接读 Theme，保证与 Scaffold/AppBar 背景单一来源。
  static Color scaffoldBackground(BuildContext context) =>
      Theme.of(context).scaffoldBackgroundColor;

  /// 卡片背景色（贴在页面上的卡片）
  /// - 亮色模式：#F9F9F9 (卡片内部，与淡蓝页面形成对比)
  /// - 暗黑模式：#1C2330 (深蓝灰，与深蓝页面形成对比)
  static Color surface(BuildContext context) =>
      isDark(context) ? cardBackgroundDarkStatic : cardBackgroundLightStatic;

  /// 次级背景色（嵌套卡片、输入框背景）
  /// - 亮色模式：#F5F5F5 (灰100)
  /// - 暗黑模式：#232B3D (更深的蓝灰)
  static Color surfaceSecondary(BuildContext context) =>
      isDark(context) ? const Color(0xFF232B3D) : Colors.grey.shade100;

  /// 悬浮卡片背景色（Dialog、BottomSheet、Dropdown 等）
  /// - 亮色模式：#FFFFFF (白色)
  /// - 暗黑模式：#232B3D (略亮于普通卡片)
  static Color surfaceElevated(BuildContext context) =>
      isDark(context) ? const Color(0xFF232B3D) : Colors.white;

  /// PrimaryHeader 背景色
  /// - 亮色模式：用户选择的主题色
  /// - 暗黑模式：#151A24 (深蓝灰，与页面背景一致)
  static Color surfaceHeader(BuildContext context) => isDark(context)
      ? scaffoldBackgroundDarkStatic
      : Theme.of(context).colorScheme.primary;

  /// BottomSheet 背景色（金额输入等弹窗）
  /// - 亮色模式：#FFFFFF (白色)
  /// - 暗黑模式：#1C2330 (深蓝灰，同卡片)
  static Color surfaceSheet(BuildContext context) =>
      isDark(context) ? cardBackgroundDarkStatic : Colors.white;

  /// 键盘按钮背景色
  /// - 亮色模式：#FFFFFF (白色)
  /// - 暗黑模式：#1C2330 (深蓝灰，同卡片)
  static Color surfaceKey(BuildContext context) =>
      isDark(context) ? cardBackgroundDarkStatic : Colors.white;

  /// 键盘次级按钮背景色（日期、+/-等）
  /// - 亮色模式：#F5F5F5 (灰100)
  /// - 暗黑模式：#232B3D (深蓝灰)
  static Color surfaceKeySecondary(BuildContext context) =>
      isDark(context) ? const Color(0xFF232B3D) : Colors.grey.shade100;

  /// 禁用按钮背景色
  /// - 亮色模式：#E0E0E0 (灰300)
  /// - 暗黑模式：#232B3D (更深的蓝灰)
  static Color surfaceDisabled(BuildContext context) =>
      isDark(context) ? const Color(0xFF232B3D) : Colors.grey.shade300;

  /// 输入框背景色
  /// - 亮色模式：#F3F4F6 (浅灰)
  /// - 暗黑模式：#232B3D (深蓝灰)
  static Color surfaceInput(BuildContext context) =>
      isDark(context) ? const Color(0xFF232B3D) : const Color(0xFFF3F4F6);

  /// 标签/Chip 背景色（未选中状态）
  /// - 亮色模式：#EEEEEE (灰200)
  /// - 暗黑模式：#232B3D (深蓝灰)
  static Color surfaceChip(BuildContext context) =>
      isDark(context) ? const Color(0xFF232B3D) : Colors.grey.shade200;

  /// 胶囊切换器背景色
  /// - 亮色模式：rgba(0,0,0,0.06) (浅灰透明)
  /// - 暗黑模式：#232B3D (深蓝灰)
  static Color surfaceCapsule(BuildContext context) => isDark(context)
      ? const Color(0xFF232B3D)
      : Colors.black.withValues(alpha: 0.06);

  /// 弹出层/浮层内卡片背景色（如二级分类选择）
  /// - 亮色模式：#FFFFFF (白色)
  /// - 暗黑模式：#2A3244 (中深蓝灰)
  static Color surfacePopoverCard(BuildContext context) =>
      isDark(context) ? const Color(0xFF2A3244) : Colors.white;

  /// 分类图标背景色（未选中状态）
  /// - 亮色模式：#EEEEEE (灰200)
  /// - 暗黑模式：#333D50 (深蓝灰)
  static Color surfaceCategoryIcon(BuildContext context) =>
      isDark(context) ? const Color(0xFF333D50) : Colors.grey.shade200;

  /// 分类图标背景色 - 浅色版（二级分类用）
  /// - 亮色模式：#F5F5F5 (灰100)
  /// - 暗黑模式：#2A3244 (深蓝灰)
  static Color surfaceCategoryIconLight(BuildContext context) =>
      isDark(context) ? const Color(0xFF2A3244) : Colors.grey.shade100;

  /// 分类图标颜色（未选中状态）
  /// - 亮色模式：#616161 (灰700)
  /// - 暗黑模式：#AEAEB2 (浅灰)
  static Color iconCategory(BuildContext context) =>
      isDark(context) ? const Color(0xFFAEAEB2) : Colors.grey.shade700;

  /// 选中状态背景色（列表项选中、高亮）
  /// - 亮色模式：主题色 8% 透明度
  /// - 暗黑模式：主题色 15% 透明度
  static Color surfaceSelected(BuildContext context) => isDark(context)
      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.15)
      : Theme.of(context).colorScheme.primary.withValues(alpha: 0.08);

  /// 悬停/按压状态背景色
  /// - 亮色模式：rgba(0,0,0,0.04)
  /// - 暗黑模式：rgba(255,255,255,0.08)
  static Color surfaceHover(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.04);

  // ========== 文字颜色 Token (Text) ==========

  /// 亮色下主要文字的原值（单一来源，供 *_On 方法复用）。
  static const Color _textPrimaryLight = Color(0xFF111827);

  /// 亮色下次要文字的原值（= Colors.black54）。
  static const Color _textSecondaryLight = Color(0x8A000000);

  /// 主要文字颜色（标题、正文）
  /// - 亮色模式：#111827 (灰900)
  /// - 暗黑模式：#FFFFFF (白色)
  static Color textPrimary(BuildContext context) =>
      textPrimaryOn(isDark(context));

  /// 主要文字颜色（无 context 场景：CustomPainter、ThemeData 构建）。
  ///
  /// 为什么需要它：Painter 与主题构建拿不到 BuildContext，只有一个
  /// [isDark] 标记。原先 token 层只导出「亮色常量」（`primaryTextStatic`），
  /// 于是每个调用点自己补暗色分支（`isDark ? Colors.white : xxxStatic`）——
  /// 等于把 token 的暗色取值复制到各处，改 token 改不动，而且很容易漏：
  /// 实际就漏了一处，图表平均线在暗色模式下仍用亮色灰。
  /// 把「按模式取值」也放进 token 后，调用点不再复制。
  static Color textPrimaryOn(bool isDark) =>
      isDark ? Colors.white : _textPrimaryLight;

  /// 次要文字颜色（副标题、说明文字）
  /// - 亮色模式：rgba(0,0,0,0.54) 即 Colors.black54
  /// - 暗黑模式：rgba(255,255,255,0.7)
  static Color textSecondary(BuildContext context) =>
      textSecondaryOn(isDark(context));

  /// 次要文字颜色（无 context 场景），理由同 [textPrimaryOn]。
  static Color textSecondaryOn(bool isDark) =>
      isDark ? Colors.white.withValues(alpha: 0.7) : _textSecondaryLight;

  /// 提示文字颜色（placeholder、hint、辅助说明）
  /// - 亮色模式：#9CA3AF (灰400)
  /// - 暗黑模式：rgba(255,255,255,0.54)
  static Color textTertiary(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.54)
      : const Color(0xFF9CA3AF);

  /// 禁用文字颜色
  /// - 亮色模式：rgba(0,0,0,0.26)
  /// - 暗黑模式：rgba(255,255,255,0.38)
  static Color textDisabled(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.38)
      : Colors.black.withValues(alpha: 0.26);

  /// 反色文字（用于深色背景上的白色文字）
  /// - 亮色模式：#FFFFFF
  /// - 暗黑模式：#FFFFFF
  static Color textOnPrimary(BuildContext context) => Colors.white;

  /// 链接文字颜色
  /// - 亮色模式：#3B82F6 (蓝色)
  /// - 暗黑模式：#60A5FA (亮蓝色)
  static Color textLink(BuildContext context) =>
      isDark(context) ? const Color(0xFF60A5FA) : const Color(0xFF3B82F6);

  /// Header 内主要文字颜色（用于 PrimaryHeader 内的内容）
  /// - 亮色模式：#FFFFFF（在主题色背景上）
  /// - 暗黑模式：#FFFFFF（在黑色背景上）
  static Color textOnHeader(BuildContext context) => Colors.white;

  /// Header 内次要文字颜色（用于 PrimaryHeader 内的副标题）
  /// - 亮色模式：rgba(255,255,255,0.8)（在主题色背景上）
  /// - 暗黑模式：rgba(255,255,255,0.7)（在黑色背景上）
  static Color textOnHeaderSecondary(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.7)
      : Colors.white.withValues(alpha: 0.8);

  // ========== 图标颜色 Token (Icon) ==========

  /// 主要图标颜色
  /// - 亮色模式：#000000 (87% opacity)
  /// - 暗黑模式：#FFFFFF (白色)
  static Color iconPrimary(BuildContext context) =>
      isDark(context) ? Colors.white : Colors.black87;

  /// 次要图标颜色
  /// - 亮色模式：rgba(0,0,0,0.54)
  /// - 暗黑模式：rgba(255,255,255,0.7)
  static Color iconSecondary(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.7)
      : Colors.black.withValues(alpha: 0.54);

  /// 提示图标颜色
  /// - 亮色模式：rgba(0,0,0,0.38)
  /// - 暗黑模式：rgba(255,255,255,0.54)
  static Color iconTertiary(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.54)
      : Colors.black.withValues(alpha: 0.38);

  // ========== 边框/分割线 Token (Border) ==========

  /// 分割线颜色
  /// - 亮色模式：rgba(0,0,0,0.06)
  /// - 暗黑模式：主题色 30% 透明度
  static Color divider(BuildContext context) => isDark(context)
      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)
      : Colors.black.withValues(alpha: 0.06);

  /// 边框颜色（卡片边框）
  /// - 亮色模式：transparent（使用阴影）
  /// - 暗黑模式：主题色 30% 透明度
  static Color border(BuildContext context) => isDark(context)
      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)
      : Colors.transparent;

  /// 强调边框颜色
  /// - 亮色模式：rgba(0,0,0,0.12)
  /// - 暗黑模式：主题色 30% 透明度
  static Color borderStrong(BuildContext context) => isDark(context)
      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)
      : Colors.black.withValues(alpha: 0.12);

  // ========== 控件轨道 Token (Control Track) ==========

  /// 开关「关闭态」轨道色。
  ///
  /// WCAG 1.4.11（非文本对比度）要求可交互控件的可视边界与相邻颜色
  /// 至少 3:1。原先关闭态用 `textSecondary @ 10% alpha`（亮色下等效
  /// 黑色 @5.4%），与白底对比度仅约 1.13:1：轨道几乎看不见，连带
  /// 「中心透明 + 白色描边」的滑块也失去参照——用户看不出滑块停在哪侧，
  /// 关闭态与「控件被禁用」也难分辨。
  ///
  /// 取值按对比度反推（相对亮度 L，contrast = (L1+0.05)/(L2+0.05)）：
  /// - 亮色 `#8A8A8A`：L≈0.254 → 对白底 3.45:1，对卡片底(#F7F6F3) 3.12:1
  /// - 暗色 `white@42%`：叠在 #121212 上约 #6E6E6E，L≈0.155 → 对比 3.7:1
  ///
  /// 注意：这比原设计的淡轨道明显更深（也更接近系统原生开关）。
  /// 若要回到接近原设计的淡轨道，只改这里一处即可——但会低于 3:1。
  static Color switchTrackOff(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.42)
      : const Color(0xFF8A8A8A);

  /// 主题色边框（用于卡片等）
  /// - 亮色模式：transparent
  /// - 暗黑模式：主题色 30% 透明度
  static Color borderThemed(BuildContext context) => isDark(context)
      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)
      : Colors.transparent;

  // ========== 卡片边框 Token (Card Border) ==========

  /// 卡片外边框颜色
  /// - 亮色模式：transparent（使用阴影）
  /// - 暗黑模式：transparent（去掉边框）
  static Color cardOuterBorderColor(BuildContext context) => Colors.transparent;

  /// 卡片外边框宽度
  /// - 亮色模式：0
  /// - 暗黑模式：0
  static double cardOuterBorderWidth(BuildContext context) => 0;

  /// 卡片内部分割线颜色
  /// - 亮色模式：rgba(0,0,0,0.06)
  /// - 暗黑模式：transparent（去掉分割线）
  static Color cardInnerDividerColor(BuildContext context) => isDark(context)
      ? Colors.transparent
      : Colors.black.withValues(alpha: 0.06);

  /// 卡片内部分割线高度
  /// - 亮色模式：1
  /// - 暗黑模式：0（去掉分割线）
  static double cardInnerDividerHeight(BuildContext context) =>
      isDark(context) ? 0 : 1;

  /// 明细列表「天」之间的分隔线。区别于卡片内 item 分隔(cardInnerDivider
  /// 暗黑不显示):明细 day 分隔亮暗都显示细线(暗黑 white 8% / 亮 black 6%)。
  static double listDayDividerHeight(BuildContext context) => 1;
  static Color listDayDividerColor(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);

  /// 卡片内部分割线组件
  /// 封装了 height、thickness、color 三个属性
  /// 设置项分割线。默认左缩进 48(对齐 AppListTile 内容:icon 容器 36 + 间距 12),
  /// 让线避开左侧 icon。section 顶部 / 卡片外等需要全宽的场景传 indent: 0。
  static Widget cardDivider(BuildContext context, {double indent = 48}) =>
      Divider(
        height: cardInnerDividerHeight(context),
        thickness: cardInnerDividerHeight(context),
        color: cardInnerDividerColor(context),
        indent: indent,
      );

  // ========== 主题色 Token (Theme) ==========

  /// 主题色（自动适配用户选择的颜色）
  /// - 亮色模式：用户选择的主题色（如 #F8C91C）
  /// - 暗黑模式：深色版本（如 #C49A15）
  static Color primary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  /// 辅助色
  static Color secondary(BuildContext context) =>
      Theme.of(context).colorScheme.secondary;

  // ========== 语义色 Token (Semantic) ==========

  /// 成功状态颜色
  /// - 亮色模式：#22C55E
  /// - 暗黑模式：#34D399
  static Color success(BuildContext context) =>
      isDark(context) ? const Color(0xFF34D399) : const Color(0xFF22C55E);

  /// 警告状态颜色
  /// - 亮色模式：#F59E0B
  /// - 暗黑模式：#FBBF24
  static Color warning(BuildContext context) =>
      isDark(context) ? const Color(0xFFFBBF24) : const Color(0xFFF59E0B);

  /// 错误状态颜色
  /// - 亮色模式：#EF4444
  /// - 暗黑模式：#F87171
  static Color error(BuildContext context) =>
      isDark(context) ? const Color(0xFFF87171) : const Color(0xFFEF4444);

  /// 信息提示颜色
  /// - 亮色模式：#3B82F6
  /// - 暗黑模式：#60A5FA
  static Color info(BuildContext context) =>
      isDark(context) ? const Color(0xFF60A5FA) : const Color(0xFF3B82F6);

  // ========== 交互色 Token (Interactive) ==========

  /// 主按钮背景色
  /// - 亮色模式：主题色
  /// - 暗黑模式：主题色
  static Color buttonPrimary(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  /// 次要按钮背景色
  /// - 亮色模式：transparent
  /// - 暗黑模式：transparent
  static Color buttonSecondary(BuildContext context) => Colors.transparent;

  /// 主按钮文字颜色
  /// - 亮色模式：#FFFFFF
  /// - 暗黑模式：#FFFFFF
  static Color buttonPrimaryText(BuildContext context) => Colors.white;

  /// 次要按钮文字颜色
  /// - 亮色模式：主题色
  /// - 暗黑模式：主题色
  static Color buttonSecondaryText(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  /// 禁用按钮背景色
  /// - 亮色模式：#E5E7EB (灰200)
  /// - 暗黑模式：#2A3244 (深蓝灰)
  static Color buttonDisabled(BuildContext context) =>
      isDark(context) ? const Color(0xFF2A3244) : const Color(0xFFE5E7EB);

  /// Switch 开启状态轨道颜色
  /// - 亮色模式：主题色
  /// - 暗黑模式：主题色
  static Color switchActiveTrack(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  /// Switch 关闭状态轨道颜色
  /// - 亮色模式：#E5E7EB
  /// - 暗黑模式：#2A3244 (深蓝灰)
  static Color switchInactiveTrack(BuildContext context) =>
      isDark(context) ? const Color(0xFF2A3244) : const Color(0xFFE5E7EB);

  // ========== 品牌图标色 Token (Brand Icons) ==========
  // 这些颜色是各服务的品牌色，在亮暗模式下保持一致

  /// 本地存储图标色（灰色）
  static const Color brandLocal = Color(0xFF9E9E9E);

  /// Supabase 品牌色（绿色）
  static const Color brandSupabase = Color(0xFF3ECF8E);

  /// WebDAV 品牌色（橙色）
  static const Color brandWebdav = Color(0xFFFF9800);

  /// iCloud 品牌色（苹果蓝）
  static const Color brandIcloud = Color(0xFF007AFF);

  /// S3 存储品牌色（紫色）
  static const Color brandS3 = Color(0xFF8B5CF6);

  /// 云服务通用图标色（蓝色）
  static const Color brandCloud = Color(0xFF2196F3);

  // ========== 状态指示器 Token (Status Indicators) ==========

  /// 在线/连接成功指示色
  /// - 亮色模式：#22C55E
  /// - 暗黑模式：#34D399
  static Color statusOnline(BuildContext context) => success(context);

  /// 离线/断开连接指示色
  /// - 亮色模式：#9CA3AF
  /// - 暗黑模式：rgba(255,255,255,0.38)
  static Color statusOffline(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.38)
      : const Color(0xFF9CA3AF);

  /// 待处理/等待中指示色
  /// - 亮色模式：#F59E0B
  /// - 暗黑模式：#FBBF24
  static Color statusPending(BuildContext context) => warning(context);

  // ========== 图表/统计色 Token (Chart Colors) ==========

  /// 收入颜色
  /// - 亮色模式：#22C55E
  /// - 暗黑模式：#34D399
  static Color chartIncome(BuildContext context) => success(context);

  /// 支出颜色
  /// - 亮色模式：#EF4444
  /// - 暗黑模式：#F87171
  static Color chartExpense(BuildContext context) => error(context);

  /// 转账颜色
  /// - 亮色模式：#3B82F6
  /// - 暗黑模式：#60A5FA
  static Color chartTransfer(BuildContext context) => info(context);

  /// 收入颜色（动态方案，根据用户设置）
  /// - [IncomeExpenseColorScheme.redIncome]：error(红)
  /// - [IncomeExpenseColorScheme.greenIncome]：success(绿)
  /// - [IncomeExpenseColorScheme.blueIncome]：`#477AF8`(蓝)
  static Color incomeColor(BuildContext context, WidgetRef ref) {
    final scheme = ref.watch(incomeExpenseColorSchemeProvider);
    return _resolveSchemeColor(context, scheme.incomeColor);
  }

  /// 支出颜色（动态方案，根据用户设置）
  /// - [IncomeExpenseColorScheme.redIncome]：success(绿)
  /// - [IncomeExpenseColorScheme.greenIncome]：error(红)
  /// - [IncomeExpenseColorScheme.blueIncome]：`#EE6839`(橙)
  static Color expenseColor(BuildContext context, WidgetRef ref) {
    final scheme = ref.watch(incomeExpenseColorSchemeProvider);
    return _resolveSchemeColor(context, scheme.expenseColor);
  }

  /// 把收入/支出颜色 token 与 PiggyTokens 内的 error/success 对齐:
  /// 需要走主题色 token 的(如语义红/绿)用 [error]/[success](自动跟随暗黑模式),
  /// 自定义色(蓝/橙等明/暗一致的)直接返回原值。
  static Color _resolveSchemeColor(BuildContext context, SchemeColor c) {
    switch (c) {
      case SchemeColor.error:
        return error(context);
      case SchemeColor.success:
        return success(context);
      case SchemeColor.incomeBlue:
        return const Color(0xFF477AF8);
      case SchemeColor.expenseOrange:
        return const Color(0xFFEE6839);
    }
  }

  // ========== 遮罩层 Token (Overlay) ==========

  /// 模态遮罩层颜色
  /// - 亮色模式：rgba(0,0,0,0.5)
  /// - 暗黑模式：rgba(0,0,0,0.7)
  static Color overlay(BuildContext context) => isDark(context)
      ? Colors.black.withValues(alpha: 0.7)
      : Colors.black.withValues(alpha: 0.5);

  /// 轻量遮罩层颜色（用于下拉刷新等）
  /// - 亮色模式：rgba(0,0,0,0.05)
  /// - 暗黑模式：rgba(255,255,255,0.05)
  static Color overlayLight(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.05)
      : Colors.black.withValues(alpha: 0.05);

  // ========== 悬浮 Tab 栏 Token (Floating Tab Bar) ==========

  /// 悬浮 Tab 栏背景色（PiggyHeader/PiggyTitleBar 标题栏与底部导航栏共用）
  /// - 亮色模式：随主题色派生的页面背景 95% 不透明（与页面背景融为一体）
  /// - 暗黑模式：深蓝灰 95% 不透明
  static Color tabBarBackground(BuildContext context) => isDark(context)
      ? cardBackgroundDarkStatic.withValues(alpha: 0.95)
      : Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.95);

  /// 悬浮 Tab 栏阴影
  static List<BoxShadow> get tabBarShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 20,
          offset: const Offset(0, 4),
        ),
      ];

  // ========== 辅助方法 ==========

  /// 计算 AppBar 下方内容的顶部内边距（缺陷 G 修复）
  ///
  /// 替代手动 `MediaQuery.of(context).padding.top + 56 + extra`，
  /// 使用 [kToolbarHeight] 保持与 Material AppBar 标准高度一致，
  /// 避免 extendBodyBehindAppBar / 横屏 / 灵动岛等场景下内容被状态栏遮挡。
  ///
  /// [extra] 为 AppBar 底部到内容起始处的额外间距，默认 0。
  static double topScrollablePadding(BuildContext context,
          {double extra = 0}) =>
      MediaQuery.of(context).padding.top + kToolbarHeight + extra;

  /// 判断当前是否为暗黑模式
  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// 根据语义获取颜色（用于动态状态）
  static Color semantic(BuildContext context, String type) {
    switch (type) {
      case 'success':
        return success(context);
      case 'warning':
        return warning(context);
      case 'error':
        return error(context);
      case 'info':
        return info(context);
      default:
        return textPrimary(context);
    }
  }

  // ========== 静态常量（用于无 context 场景，如 CustomPainter、主题定义） ==========
  // 注意：这些是亮色或暗色模式下的具体值，需要「按模式取值」时请用
  // PiggyTokens.textPrimaryOn(bool isDark) / textSecondaryOn(bool isDark)。
  // 历史上这里曾导出「只有亮色」的 primaryTextStatic / secondaryTextStatic，
  // 导致调用点各自复制暗色分支（见 *_On 的注释），已下线。

  /// Scaffold 背景色（暗色模式）— #151A24 (深蓝灰)
  /// 单一来源：PiggyTokens.scaffoldBackground(context) 与 PiggyTheme.darkTheme 共享
  static const Color scaffoldBackgroundDarkStatic = Color(0xFF151A24);

  /// 卡片背景色（亮色模式）— #F9F9F9
  static const Color cardBackgroundLightStatic = Color(0xFFF9F9F9);

  /// 卡片背景色（暗色模式）— #1C2330 (深蓝灰，与页面背景形成层级对比)
  static const Color cardBackgroundDarkStatic = Color(0xFF1C2330);

  /// 分割线颜色（亮色模式）— black 6%
  static Color get dividerStatic => Colors.black.withValues(alpha: 0.06);

  /// 分割线颜色（暗色模式）— white 12%
  static Color get dividerDarkStatic => Colors.white.withValues(alpha: 0.12);
}

// ============================================================================
// 设计基准令牌 (Design Tokens)
// ============================================================================

/// 间距、圆角等尺寸令牌
class PiggyDimens {
  // ========== 间距令牌 ==========
  static const double p4 = 4;
  static const double p8 = 8;
  static const double p12 = 12;
  static const double p16 = 16;
  static const double p20 = 20;
  static const double p24 = 24;

  // ========== 圆角令牌（语义化分档） ==========
  //
  // 项目统一圆角标准，按视觉层级分 7 档。
  // 所有 BorderRadius.circular 调用应使用这些令牌，禁止魔法数字。
  //
  // 使用示例：
  //   borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)

  /// 极小圆角 - 徽章、状态点、小指示器（原 4/6 合并）
  static const double radiusXs = 4;

  /// 小圆角 - 输入框、小卡片、列表项容器
  static const double radiusSm = 8;

  /// 中小圆角 - 图标盒（设置页风格）
  static const double radiusMd = 10;

  /// 中圆角 - 按钮、次级卡片、导航项涟漪、菜单项
  static const double radiusLg = 12;

  /// 大圆角 - 主卡片、Dialog、BottomSheet 顶部
  static const double radiusXl = 16;

  /// 超大圆角 - 海报、日历选中态、特殊突出元素
  static const double radius2xl = 20;

  /// 最大圆角 - 启动页、AI 聊天气泡、大分类头像
  static const double radius3xl = 24;

  // 兼容别名（指向新令牌，保留以避免破坏旧引用）
  static const double radius12 = radiusLg;
  static const double radius16 = radiusXl;

  // 列表相关：分组头与行的统一垂直内边距
  static const double listHeaderVertical = 6;
  static const double listRowVertical = 8;

  // ========== 语义化 EdgeInsets 常量（消除重复字面量） ==========

  /// 首页提醒卡片统一外边距（home_page 三张卡片共用）
  static const EdgeInsets cardMargin = EdgeInsets.fromLTRB(12, 4, 12, 8);

  /// 首页提醒卡片统一内边距（home_page 三张卡片共用，含左侧装饰条避让）
  static const EdgeInsets reminderCardPadding =
      EdgeInsets.fromLTRB(p16, p12, p12, p12);

  /// 通用卡片内边距
  static const EdgeInsets cardPadding = EdgeInsets.all(16);

  /// 通用水平外边距（页面主体两侧）
  static const EdgeInsets pageHorizontalMargin =
      EdgeInsets.symmetric(horizontal: 12);

  /// 头部水平内边距（与 [pageHorizontalMargin] 同值，语义分离）
  ///
  /// 统一原 PrimaryHeader(8) / GlassHeader(16) / pageHorizontalMargin(12) 三值分裂。
  static const double headerHorizontalValue = 12;

  /// 头部水平内边距 EdgeInsets（基于 [headerHorizontalValue]）。
  static const EdgeInsets headerHorizontal =
      EdgeInsets.symmetric(horizontal: headerHorizontalValue);

  /// iOS 风格警示框宽度（危险确认框对齐左图窄卡片观感）。
  static const double alertWidth = 270;
}

/// 阴影令牌
class PiggyShadows {
  static List<BoxShadow> card = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.04),
      blurRadius: 8,
      offset: const Offset(0, 2),
    )
  ];
}

/// 分割线组件令牌
class PiggyDivider {
  static Divider thin({EdgeInsetsGeometry? padding}) => Divider(
        height: 1,
        thickness: 1,
        color: PiggyTokens.dividerStatic,
      );

  static Divider short({double indent = 0, double endIndent = 0}) => Divider(
        height: 1,
        thickness: 1,
        indent: indent,
        endIndent: endIndent,
        color: PiggyTokens.dividerStatic,
      );
}

/// 图表令牌：统一图表组件的视觉参数
class PiggyChartTokens {
  static const double lineWidth = 2.0;
  static const double dotRadius = 2.5;
  static const double cornerRadius = 12.0;
  static const double xLabelFontSize = 10.0;
  static const double yLabelFontSize = 10.0;

  /// 分类系列调色板（12 色，覆盖常见分类数量）。
  /// 饼图扇区与排行榜按分类排序下标取同一色板，保证扇区色与排行行色一一对应。
  static const List<Color> seriesColors = [
    Color(0xFF5B8FF9), // 蓝
    Color(0xFF5AD8A6), // 绿
    Color(0xFFF6BD16), // 黄
    Color(0xFFE86452), // 红
    Color(0xFF6DC8EC), // 浅蓝
    Color(0xFF945FB9), // 紫
    Color(0xFFFF9845), // 橙
    Color(0xFF1E9493), // 青
    Color(0xFFFF99C3), // 粉
    Color(0xFF269A99), // 深青
    Color(0xFFBDD2FD), // 淡蓝
    Color(0xFFA0DC2C), // 黄绿
  ];

  // ---- 语义字号槽位（P1-D：charts 内 fontSize 字面量的唯一来源）----
  /// 气泡提示文字
  static const double tooltipFontSize = 11.0;

  /// 图例行 / 环形中心标签
  static const double legendFontSize = 11.0;

  /// 区块标题（「资产构成 / 余额趋势 / 分类占比」等）
  static const double sectionTitleFontSize = 14.0;

  /// 图表标题（analytics_bar_chart 顶部标题）
  static const double titleFontSize = 15.0;

  /// 环形图中心金额
  static const double centerValueFontSize = 16.0;
}

/// 海报令牌：分享海报（RepaintBoundary.toImage 导出 PNG）专用语义色。
///
/// 全静态、无 BuildContext——海报是导出图片，必须与 App 明暗模式无关
/// （主题色由调用方通过 primaryColor 参数传入）；与 PiggyDimens 的静态
/// 设计哲学一致。收入/支出取「海报家族多数值」，annual_report 已对齐。
class PiggyPosterTokens {
  /// 收入 / 正向增长（month / year / ledger 海报多数值）
  static const Color income = Color(0xFF51CF66);

  /// 支出 / 负向下降
  static const Color expense = Color(0xFFFF6B6B);

  /// 收入徽章底色（浅绿）
  static const Color incomeBadgeBg = Color(0xFFE8F5E9);

  /// 支出徽章底色（浅红）
  static const Color expenseBadgeBg = Color(0xFFFFEBEE);

  /// 海报文字主色（浅底深字）
  static const Color textPrimary = Color(0xFF333333);

  /// 海报文字次色
  static const Color textSecondary = Color(0xFF666666);

  /// 海报文字弱色
  static const Color textTertiary = Color(0xFF999999);

  /// 奖牌金（年度成就 / 用户资料页勋章）
  static const Color medalGold = Color(0xFFFFD700);

  /// 奖牌银
  static const Color medalSilver = Color(0xFFC0C0C0);

  /// 奖牌铜
  static const Color medalBronze = Color(0xFFCD7F32);

  /// 年度海报深墨标题（primaryColor 顶栏上的标题文字）
  static const Color darkInk = Color(0xFF1A1A2E);
}

/// 个性化默认值令牌：跨文件共享的缺省常量（P1-D 单源化）
class PiggyPersonalizeDefaults {
  /// 默认主题色（天空蓝）。personalize_page 色板首选项与
  /// primaryColorProvider 默认值共用此常量，避免双处定义漂移。
  static const Color defaultPrimaryColor = Color(0xFF497FF8);
}

/// 文本样式令牌：全局统一字号与字重
class PiggyTextTokens {
  // 标题：用于列表主标题、条目标题
  static TextStyle title(BuildContext ctx) =>
      Theme.of(ctx).textTheme.bodyLarge?.copyWith(
            color: PiggyTokens.textPrimary(ctx),
          ) ??
      TextStyle(
          fontSize: 15,
          color: PiggyTokens.textPrimary(ctx),
          fontWeight: FontWeight.w400);

  // 强调标题：用于统计数字等需要比普通列表标题更醒目的场景
  static TextStyle strongTitle(BuildContext ctx) =>
      Theme.of(ctx).textTheme.bodyLarge?.copyWith(
            fontSize: 15,
            color: PiggyTokens.textPrimary(ctx),
            fontWeight: FontWeight.w600,
          ) ??
      TextStyle(
          fontSize: 15,
          color: PiggyTokens.textPrimary(ctx),
          fontWeight: FontWeight.w600);

  // 加粗标题：用于极强强调（如大额数字/主标题）
  static TextStyle boldTitle(BuildContext ctx) =>
      Theme.of(ctx).textTheme.bodyLarge?.copyWith(
            fontSize: 18,
            color: PiggyTokens.textPrimary(ctx),
            fontWeight: FontWeight.w700,
          ) ??
      TextStyle(
          fontSize: 18,
          color: PiggyTokens.textPrimary(ctx),
          fontWeight: FontWeight.w700);

  // 正文：用于一般性文字
  static TextStyle body(BuildContext ctx) =>
      Theme.of(ctx).textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            color: PiggyTokens.textPrimary(ctx),
          ) ??
      TextStyle(fontSize: 14, color: PiggyTokens.textPrimary(ctx));

  // 标签/说明：用于次要说明、辅助信息
  static TextStyle label(BuildContext ctx) =>
      Theme.of(ctx).textTheme.labelMedium?.copyWith(
            fontSize: 12,
            color: PiggyTokens.textSecondary(ctx),
          ) ??
      TextStyle(fontSize: 12, color: PiggyTokens.textSecondary(ctx));

  // 说明文字：用于列表项次要信息（时间/账户/附件计数等）
  // 消除 transaction_list_item 等多处散落的 fontSize: 11 字面量
  static TextStyle caption(BuildContext ctx) =>
      Theme.of(ctx).textTheme.bodySmall?.copyWith(
            fontSize: 11,
            color: PiggyTokens.textTertiary(ctx),
          ) ??
      TextStyle(fontSize: 11, color: PiggyTokens.textTertiary(ctx));
}

// ============================================================================
// 字体令牌 (Typography Tokens)
// ============================================================================

/// 字体配置令牌
class PiggyTypography {
  static bool useBundledFonts = false; // 已禁用打包字体，使用系统字体

  // Primary Latin family when bundled
  static const String bundledLatin = 'Inter';
  // Primary Chinese family when bundled
  static const String bundledCJK = 'NotoSansSC';
  // iOS system Chinese font
  static const String systemCJKiOS = 'PingFang SC';

  /// 构建基础文本主题
  static TextTheme buildBase(TextTheme base, {required bool isIOS}) {
    final bodyW = FontWeight.w400;
    final titleW = FontWeight.w600;
    final useBundledHere = useBundledFonts && !isIOS;
    final latin =
        useBundledHere ? bundledLatin : (isIOS ? 'Helvetica Neue' : 'Roboto');
    final cjk =
        useBundledHere ? bundledCJK : (isIOS ? systemCJKiOS : 'NotoSans');
    final familyFallback = <String>{
      latin,
      cjk,
      'PingFang SC',
      'Helvetica Neue',
      'Roboto',
      'Arial'
    };

    TextStyle merge(TextStyle? src, double size, FontWeight w,
        {double? height}) {
      return (src ?? const TextStyle()).copyWith(
        fontSize: size,
        fontWeight: w,
        height: height ?? 1.25,
        fontFamily: latin,
        fontFamilyFallback: familyFallback.toList(),
      );
    }

    return base.copyWith(
      bodySmall: merge(base.bodySmall, 12, bodyW),
      bodyMedium: merge(base.bodyMedium, 14, bodyW),
      bodyLarge: merge(base.bodyLarge, 15, bodyW, height: 1.28),
      labelLarge: merge(base.labelLarge, 13, FontWeight.w600),
      titleMedium: merge(base.titleMedium, 15, FontWeight.w500),
      titleLarge: merge(base.titleLarge, 18, titleW, height: 1.3),
      headlineSmall: merge(base.headlineSmall, 20, titleW, height: 1.3),
    );
  }
}
