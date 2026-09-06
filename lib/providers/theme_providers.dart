import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/note_history.dart';
import '../widget/widget_manager.dart';
import '../providers.dart';

// 主题模式Provider（默认跟随系统）
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

// 主题模式持久化初始化
final themeModeInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('themeMode');
  if (saved != null) {
    switch (saved) {
      case 'light':
        ref.read(themeModeProvider.notifier).state = ThemeMode.light;
        break;
      case 'dark':
        ref.read(themeModeProvider.notifier).state = ThemeMode.dark;
        break;
      default:
        ref.read(themeModeProvider.notifier).state = ThemeMode.system;
    }
  }
  ref.listen<ThemeMode>(themeModeProvider, (prev, next) async {
    String value;
    switch (next) {
      case ThemeMode.light:
        value = 'light';
        break;
      case ThemeMode.dark:
        value = 'dark';
        break;
      default:
        value = 'system';
    }
    await prefs.setString('themeMode', value);
  });
});

// 可变主色（个性化换装使用）
// 默认值：天空蓝（与 personalize_page.dart 中 personalizeThemeSkyBlue 选项一致，
// 列表第一位）。老用户已在 prefs 存过 primaryColor 的，由 primaryColorInitProvider
// 覆盖为本机选择；未存过的新用户走此默认。
final primaryColorProvider = StateProvider<Color>((ref) => const Color(0xFF497FF8));

// 是否隐藏金额显示
final hideAmountsProvider = StateProvider<bool>((ref) => false);

// 字体选择Provider - 已移除，仅使用系统默认字体

// 主题色持久化初始化：
// - 启动时加载保存的主色
// - 监听主色变化并写入本地
final primaryColorInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getInt('primaryColor');
  if (saved != null) {
    ref.read(primaryColorProvider.notifier).state = Color(saved);
  }
  ref.listen<Color>(primaryColorProvider, (prev, next) async {
    final colorValue = (next.a * 255).toInt() << 24 | (next.r * 255).toInt() << 16 | (next.g * 255).toInt() << 8 | (next.b * 255).toInt();
    await prefs.setInt('primaryColor', colorValue);
    // Update widget with new theme color
    try {
      final repository = ref.read(repositoryProvider);
      final currentLedgerId = ref.read(currentLedgerIdProvider);
      final colorScheme = ref.read(incomeExpenseColorSchemeProvider);
      final baseCurrency = ref.read(baseCurrencyProvider);
      // 没有 BuildContext,靠 languageProvider 还原当前 App 语言(见
      // widget_manager.dart resolveWidgetLocalizations 文档)。
      final locale = ref.read(languageProvider);
      final widgetManager = WidgetManager();
      await widgetManager.updateAllWidgetsLocalized(
        repository,
        currentLedgerId,
        next,
        explicitLocale: locale,
        colorScheme: colorScheme,
        baseCurrency: baseCurrency,
      );
    } catch (e) {
      // Silently fail
    }

  });
});

/// Flutter [Color] → `#RRGGBB`。忽略 alpha，server 只存 6 位 hex。
String _colorToHex(Color color) {
  final r = (color.r * 255).toInt() & 0xff;
  final g = (color.g * 255).toInt() & 0xff;
  final b = (color.b * 255).toInt() & 0xff;
  return '#${r.toRadixString(16).padLeft(2, '0')}'
          '${g.toRadixString(16).padLeft(2, '0')}'
          '${b.toRadixString(16).padLeft(2, '0')}'
      .toUpperCase();
}

// 隐私模式持久化初始化：
// - 启动时加载保存的隐私模式状态
// - 监听隐私模式变化并写入本地
final hideAmountsInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool('hideAmounts');
  if (saved != null) {
    ref.read(hideAmountsProvider.notifier).state = saved;
  }
  ref.listen<bool>(hideAmountsProvider, (prev, next) async {
    await prefs.setBool('hideAmounts', next);
  });
});

/// 资产页「净值走势 / 资产构成」视图选择，持久化记住用户偏好（跨会话）。
enum AssetTrendView { trend, composition }

final assetTrendViewProvider =
    StateNotifierProvider<AssetTrendViewNotifier, AssetTrendView>(
        (ref) => AssetTrendViewNotifier());

class AssetTrendViewNotifier extends StateNotifier<AssetTrendView> {
  static const _key = 'assetTrendView';
  AssetTrendViewNotifier() : super(AssetTrendView.trend) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_key) == 'composition') {
      state = AssetTrendView.composition;
    }
  }

  Future<void> select(AssetTrendView v) async {
    if (state == v) return;
    state = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, v == AssetTrendView.composition ? 'composition' : 'trend');
  }
}

// 字体持久化初始化 - 已移除，仅使用系统默认字体

// Header装饰样式Provider
// 可选值：'icons'（图标平铺）、'particles'（粒子星星）、'honeycomb'（蜂巢六边形）
final headerDecorationStyleProvider = StateProvider<String>((ref) => 'icons');

// 金额显示格式Provider（默认显示完整金额）
// false = 完整金额（如 123,456.78）
// true = 简洁显示（如 12.3万）
final compactAmountProvider = StateProvider<bool>((ref) => false);

// 金额显示格式持久化初始化
final compactAmountInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool('compactAmount');
  if (saved != null) {
    ref.read(compactAmountProvider.notifier).state = saved;
  }
  ref.listen<bool>(compactAmountProvider, (prev, next) async {
    await prefs.setBool('compactAmount', next);
  });
});

// 显示交易时间Provider（默认显示）
// false = 只显示日期
// true = 显示日期和时间（时:分）
final showTransactionTimeProvider = StateProvider<bool>((ref) => true);

// 显示交易时间持久化初始化
final showTransactionTimeInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool('showTransactionTime');
  if (saved != null) {
    ref.read(showTransactionTimeProvider.notifier).state = saved;
  }
  ref.listen<bool>(showTransactionTimeProvider, (prev, next) async {
    await prefs.setBool('showTransactionTime', next);
  });
});

// 备注显示方式 Provider(默认分类优先)
// 'category' = 分类名为主,备注挂括号小灰字(当前样式)
// 'note'     = 备注优先,有备注显示备注、无备注显示分类名
final noteDisplayModeProvider = StateProvider<String>((ref) => 'category');

// 备注显示方式持久化初始化
final noteDisplayModeInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('noteDisplayMode');
  if (saved != null) {
    ref.read(noteDisplayModeProvider.notifier).state = saved;
  }
  ref.listen<String>(noteDisplayModeProvider, (prev, next) async {
    await prefs.setString('noteDisplayMode', next);
  });
});

/// 历史备注的默认查询范围，保持原有全账本行为。
final noteHistoryScopeProvider =
    StateProvider<NoteHistoryScope>((ref) => NoteHistoryScope.allCategories);

/// 历史备注的默认排序规则，保持原有按使用次数排序行为。
final noteHistorySortProvider =
    StateProvider<NoteHistorySort>((ref) => NoteHistorySort.frequency);

/// 历史备注展示数量的默认值，保持原有最多展示 20 条的行为。
const noteHistoryDefaultLimit = 20;

/// 历史备注展示数量允许的最小值，避免空列表配置。
const noteHistoryMinLimit = 1;

/// 历史备注展示数量允许的最大值，避免单次加载过多候选。
const noteHistoryMaxLimit = 100;

/// 历史备注当前展示数量。
final noteHistoryLimitProvider =
    StateProvider<int>((ref) => noteHistoryDefaultLimit);

/// 初始化历史备注偏好，并在用户修改时持久化及同步外观配置。
final noteHistoryPreferencesInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final savedScope = prefs.getString('noteHistoryScope');
  final savedSort = prefs.getString('noteHistorySort');
  final savedLimit = prefs.getInt('noteHistoryLimit');

  // 旧版本缺失或配置异常时使用默认值，并回写规范值保证后续导出完整。
  var scope = NoteHistoryScope.allCategories;
  if (savedScope != null) {
    try {
      scope = NoteHistoryScope.values.byName(savedScope);
    } on ArgumentError {
      scope = NoteHistoryScope.allCategories;
    }
  }
  ref.read(noteHistoryScopeProvider.notifier).state = scope;

  var sort = NoteHistorySort.frequency;
  if (savedSort != null) {
    try {
      sort = NoteHistorySort.values.byName(savedSort);
    } on ArgumentError {
      sort = NoteHistorySort.frequency;
    }
  }
  ref.read(noteHistorySortProvider.notifier).state = sort;

  var limit = noteHistoryDefaultLimit;
  if (savedLimit != null &&
      savedLimit >= noteHistoryMinLimit &&
      savedLimit <= noteHistoryMaxLimit) {
    limit = savedLimit;
  }
  ref.read(noteHistoryLimitProvider.notifier).state = limit;

  // ref.listen 不会为初始值触发回调，首次启动时主动落库供配置导出使用。
  await prefs.setString('noteHistoryScope', scope.name);
  await prefs.setString('noteHistorySort', sort.name);
  await prefs.setInt('noteHistoryLimit', limit);

  ref.listen<NoteHistoryScope>(noteHistoryScopeProvider, (prev, next) async {
    // 用户选择变化后写本机偏好。
    await prefs.setString('noteHistoryScope', next.name);
  });
  ref.listen<NoteHistorySort>(noteHistorySortProvider, (prev, next) async {
    // 用户选择变化后写本机偏好。
    await prefs.setString('noteHistorySort', next.name);
  });
  ref.listen<int>(noteHistoryLimitProvider, (prev, next) async {
    // 用户修改数量后写本机偏好。
    await prefs.setInt('noteHistoryLimit', next);
  });
});

// Header装饰样式持久化初始化
final headerDecorationStyleInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('headerDecorationStyle');
  if (saved != null) {
    ref.read(headerDecorationStyleProvider.notifier).state = saved;
  }
  ref.listen<String>(headerDecorationStyleProvider, (prev, next) async {
    await prefs.setString('headerDecorationStyle', next);
  });
});

// 头部皮肤:跟随主题色的装饰层 id;'none' = 纯主题色。见 lib/styles/header_skins.dart。
// 本地持久化。
final headerSkinProvider = StateProvider<String>((ref) => 'none');

final headerSkinInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('headerSkin');
  if (saved != null) {
    ref.read(headerSkinProvider.notifier).state = saved;
  }
  ref.listen<String>(headerSkinProvider, (prev, next) async {
    await prefs.setString('headerSkin', next);
  });
});

// 收支颜色方案(v2:从 bool 升级为枚举,新增「蓝色收入/橙色支出」方案)。
//
// 早期版仅支持红色↔绿色的方向反转,语义上把"红色"作硬编码配色,
// widget 内不便分担第三种配色。现在的方案采用"枚举+显式收入/支出色"
// 的形态,新增配色只需要扩 enum,不用改 widget 接线。
//
// 持久化键保持 `incomeExpenseColorScheme`,迁移老 bool 值的兼容性靠
// [incomeExpenseColorSchemeInitProvider] 完成:启动时检测到旧值后
// 立刻回写到新 schema,之后按字符串名存储(`'redIncome'`/
// `'greenIncome'`/`'blueIncome'`)。
enum IncomeExpenseColorScheme {
  /// 红色收入 / 绿色支出(经典配色,原 `redForIncome == true`)。
  redIncome('redIncome'),

  /// 绿色收入 / 红色支出(原 `redForIncome == false`)。
  greenIncome('greenIncome'),

  /// 蓝色收入 (#477AF8) / 橙色支出 (#EE6839)。
  /// 偏好默认,无障碍对比和品牌色都兼顾。
  blueIncome('blueIncome');

  const IncomeExpenseColorScheme(this.persistenceKey);

  /// 持久化键:prefs 与云 profile sync 共用同一种字符串协议。
  /// 老版本可能存的是 bool,首次启动时迁移。
  final String persistenceKey;

  /// 该方案下「收入」应取的语义色 token。
  SchemeColor get incomeColor {
    switch (this) {
      case IncomeExpenseColorScheme.redIncome:
        return SchemeColor.error;
      case IncomeExpenseColorScheme.greenIncome:
        return SchemeColor.success;
      case IncomeExpenseColorScheme.blueIncome:
        return SchemeColor.incomeBlue;
    }
  }

  /// 该方案下「支出」应取的语义色 token。
  SchemeColor get expenseColor {
    switch (this) {
      case IncomeExpenseColorScheme.redIncome:
        return SchemeColor.success;
      case IncomeExpenseColorScheme.greenIncome:
        return SchemeColor.error;
      case IncomeExpenseColorScheme.blueIncome:
        return SchemeColor.expenseOrange;
    }
  }

  /// 把 prefs / API 读到的字符串解析回 enum;未知值兜底
  /// [blueIncome](默认),绝不抛(便于老版本/外部数据兼容)。
  static IncomeExpenseColorScheme fromKey(Object? raw) {
    if (raw is bool) {
      // 兼容老 prefs: true → redIncome, false → greenIncome。
      return raw ? IncomeExpenseColorScheme.redIncome : IncomeExpenseColorScheme.greenIncome;
    }
    if (raw is String) {
      for (final v in IncomeExpenseColorScheme.values) {
        if (v.persistenceKey == raw) return v;
      }
    }
    return IncomeExpenseColorScheme.blueIncome;
  }
}

/// 收入/支出语义色 token(`IncomeExpenseColorScheme` → 实际色)的中介枚举。
///
/// 映射在 [PiggyTokens.incomeColor]/[PiggyTokens.expenseColor] 内部完成:
/// [SchemeColor.error]/[SchemeColor.success] 走主题色 token(自动跟暗黑
/// 模式),自定义色([SchemeColor.incomeBlue]/[SchemeColor.expenseOrange])直
/// 接返回固定值 —— 明暗差异由配色自身兼顾,不二次走主题色 token。
enum SchemeColor { error, success, incomeBlue, expenseOrange }

/// 收支颜色方案Provider(默认:蓝色收入 / 橙色支出)。
final incomeExpenseColorSchemeProvider =
    StateProvider<IncomeExpenseColorScheme>(
        (ref) => IncomeExpenseColorScheme.blueIncome);

// 收支颜色方案持久化初始化(同时承担 bool → enum 的迁移,见
// [IncomeExpenseColorScheme.fromKey])。
final incomeExpenseColorSchemeInitProvider =
    FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  // 同时读 string 和 bool,新版本写 string,旧版本写的是 bool。
  final savedString = prefs.getString('incomeExpenseColorScheme');
  final savedBool = prefs.getBool('incomeExpenseColorScheme');
  final saved = savedString ?? savedBool;
  if (saved != null) {
    final current = ref.read(incomeExpenseColorSchemeProvider);
    final next = IncomeExpenseColorScheme.fromKey(saved);
    if (next != current) {
      ref.read(incomeExpenseColorSchemeProvider.notifier).state = next;
    }
  }
  ref.listen<IncomeExpenseColorScheme>(
      incomeExpenseColorSchemeProvider, (prev, next) async {
    await prefs.setString('incomeExpenseColorScheme', next.persistenceKey);
    try {
      final repository = ref.read(repositoryProvider);
      final currentLedgerId = ref.read(currentLedgerIdProvider);
      final primaryColor = ref.read(primaryColorProvider);
      final baseCurrency = ref.read(baseCurrencyProvider);
      // 没有 BuildContext,靠 languageProvider 还原当前 App 语言(见
      // widget_manager.dart resolveWidgetLocalizations 文档)。
      final locale = ref.read(languageProvider);
      final widgetManager = WidgetManager();
      await widgetManager.updateAllWidgetsLocalized(
        repository,
        currentLedgerId,
        primaryColor,
        explicitLocale: locale,
        colorScheme: next,
        baseCurrency: baseCurrency,
      );
    } catch (e) {
      // Silently fail
    }

  });
});

// 用户显示名(昵称)。本地真值存 prefs 'displayName';只存本地。空串 = 未设置。
final displayNameProvider = StateProvider<String>((ref) => '');

// 显示名持久化初始化:启动加载 prefs + 监听变化写回本地。
// 完全照搬 themeMode / compactAmount 的写法。
final displayNameInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('displayName');
  if (saved != null) {
    ref.read(displayNameProvider.notifier).state = saved;
  }
  ref.listen<String>(displayNameProvider, (prev, next) async {
    await prefs.setString('displayName', next);
  });
});