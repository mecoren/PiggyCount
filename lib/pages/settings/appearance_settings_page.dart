import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../models/note_history.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../../utils/currencies.dart';
import '../../widgets/currency/currency_picker_sheet.dart';
import './personalize_page.dart';
import './font_settings_page.dart';
import './widget_management_page.dart';
import './app_lock_settings_page.dart';
import './header_skin_page.dart';
import '../../styles/header_skins.dart';
import '../../l10n/app_localizations.dart';
import '../currency/exchange_rate_page.dart';
import '../../utils/ui_scale_extensions.dart';

/// 外观设置二级页面
class AppearanceSettingsPage extends ConsumerWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLanguage = ref.watch(languageProvider);
    final themeMode = ref.watch(themeModeProvider);
    final l10n = AppLocalizations.of(context);

    String languageDisplay;
    if (currentLanguage == null) {
      languageDisplay = l10n.languageSystemDefault;
    } else {
      switch (currentLanguage.languageCode) {
        case 'zh':
          languageDisplay = l10n.languageChinese;
          break;
        case 'en':
          languageDisplay = l10n.languageEnglish;
          break;
        case 'ko':
          languageDisplay = '한국어';
          break;
        default:
          languageDisplay = currentLanguage.languageCode;
      }
    }

    // 主题模式显示文本
    String themeModeDisplay;
    switch (themeMode) {
      case ThemeMode.light:
        themeModeDisplay = l10n.appearanceThemeModeLight;
        break;
      case ThemeMode.dark:
        themeModeDisplay = l10n.appearanceThemeModeDark;
        break;
      default:
        themeModeDisplay = l10n.appearanceThemeModeSystem;
    }

    // 头部皮肤显示名
    final headerSkin = ref.watch(headerSkinProvider);
    final skinDisplay = headerSkin == kHeaderSkinNone
        ? l10n.headerSkinNone
        : (headerSkinById(headerSkin)?.nameOf(l10n) ?? l10n.headerSkinNone);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.appearanceSettingsPageTitle,
        showBack: true,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          PiggyTokens.topScrollablePadding(context, extra: 16),
          16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          // 纯样式:外观模式 / 主题色 / 皮肤 / 显示缩放
          SettingsCard(
            children: [
              // 外观模式
              SettingsNavItem(
                icon: Icons.brightness_6_outlined,
                title: l10n.appearanceThemeMode,
                subtitle: themeModeDisplay,
                onTap: () => _showThemeModeSheet(context, ref),
              ),
              // 主题色设置
              SettingsNavItem(
                icon: Icons.brush_outlined,
                title: l10n.personalizeTitle,
                subtitle: l10n.personalizeSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PersonalizePage()),
                  );
                },
              ),
              // 皮肤
              SettingsNavItem(
                icon: Icons.wallpaper_outlined,
                title: l10n.headerSkinTitle,
                subtitle: skinDisplay,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HeaderSkinPage()),
                  );
                },
              ),
              // 显示缩放
              SettingsNavItem(
                icon: Icons.zoom_out_map_outlined,
                title: l10n.mineDisplayScale,
                subtitle: l10n.mineDisplayScaleSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FontSettingsPage()),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 功能:金额格式 / 交易时间 / 收支配色(影响数据呈现,非纯外观)
          SettingsCard(
            children: [
              // 金额显示格式
              SettingsNavItem(
                icon: Icons.money_outlined,
                title: l10n.appearanceAmountFormat,
                subtitle: ref.watch(compactAmountProvider)
                    ? l10n.appearanceAmountFormatCompact
                    : l10n.appearanceAmountFormatFull,
                onTap: () => _showAmountFormatSheet(context, ref),
              ),
              // 显示交易时间
              SettingsToggleItem(
                icon: Icons.schedule_outlined,
                title: l10n.appearanceShowTransactionTime,
                subtitle: l10n.appearanceShowTransactionTimeDesc,
                value: ref.watch(showTransactionTimeProvider),
                onChanged: (value) {
                  ref.read(showTransactionTimeProvider.notifier).state = value;
                },
              ),
              // 快捷记账模式（P1-E）：管「记一笔」的落点，与上面几项同属
              // 「记一笔表单/账单列表」层面的偏好。留这个开关是 AC-R4 的落点：
              // 关闭后行为必须与改动前完全一致（quickMode 不进任何新分支）。
              SettingsToggleItem(
                icon: Icons.bolt_outlined,
                title: l10n.appearanceQuickEntryMode,
                subtitle: l10n.appearanceQuickEntryModeDesc,
                value: ref.watch(quickEntryModeEnabledProvider),
                onChanged: (value) {
                  ref.read(quickEntryModeEnabledProvider.notifier).state =
                      value;
                },
              ),
              // 备注显示方式
              SettingsNavItem(
                icon: Icons.notes_outlined,
                title: l10n.appearanceNoteDisplay,
                subtitle: ref.watch(noteDisplayModeProvider) == 'note'
                    ? l10n.appearanceNoteDisplayNote
                    : l10n.appearanceNoteDisplayCategory,
                onTap: () => _showNoteDisplaySheet(context, ref),
              ),
              // 历史备注偏好
              SettingsNavItem(
                icon: Icons.history_outlined,
                title: l10n.appearanceNoteHistory,
                subtitle: _noteHistorySummary(ref, l10n),
                onTap: () => _showNoteHistoryDialog(context, ref, l10n),
              ),
              // 收支颜色方案
              SettingsNavItem(
                icon: Icons.palette_outlined,
                title: l10n.appearanceColorScheme,
                subtitle: _colorSchemeSubtitle(ref, l10n),
                onTap: () => _showColorSchemeSheet(context, ref),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 多币种:主币种 / 汇率管理
          SettingsCard(
            children: [
              // 主币种
              SettingsNavItem(
                icon: Icons.payments_outlined,
                title: l10n.baseCurrencyLabel,
                subtitle: displayCurrency(
                    ref.watch(baseCurrencyProvider).toUpperCase(), context),
                onTap: () => _pickBaseCurrency(context, ref),
              ),
              // 汇率管理
              SettingsNavItem(
                icon: Icons.currency_exchange,
                title: l10n.exchangeRatePageTitle,
                subtitle: l10n.exchangeRateEntrySubtitle,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ExchangeRatePage(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 通用:语言 / 桌面小组件 / 应用锁
          SettingsCard(
            children: [
              // 语言设置 —— 底部抽屉单选，选中即应用
              SettingsNavItem(
                icon: Icons.language_outlined,
                title: l10n.mineLanguageSettings,
                subtitle: languageDisplay,
                onTap: () => _showLanguageSheet(context, ref),
              ),
              // 桌面小组件
              SettingsNavItem(
                icon: Icons.widgets_outlined,
                title: l10n.widgetManagement,
                subtitle: l10n.widgetManagementDesc,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const WidgetManagementPage()),
                  );
                },
              ),
              // 应用锁
              SettingsNavItem(
                icon: Icons.lock_outline,
                title: l10n.appLockTitle,
                subtitle: l10n.appLockDesc,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const AppLockSettingsPage()),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 主币种选择 —— 弹 sheet 选完后应用
  Future<void> _pickBaseCurrency(BuildContext context, WidgetRef ref) async {
    final current = ref.read(baseCurrencyProvider).toUpperCase();
    final primary = ref.read(primaryColorProvider);
    final picked = await showCurrencyPickerSheet(
      context,
      selected: current,
      primaryColor: primary,
    );
    if (picked == null || !context.mounted) return;
    await applyBaseCurrencySelection(context, ref, picked);
  }

  /// 语言选择 —— 底部抽屉单选（与超时/主币种等选择交互同口径）。
  /// 选中即应用并收起；应用后延迟刷新桌面小组件，等 locale 变化生效。
  void _showLanguageSheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    // 选项语种名沿用原语言设置页口径：官方文案走 l10n，
    // 繁中/韩文用原生名（目标语言用户才看得懂，不随界面语言变化）。
    // 前置徽标：每种语言用它自己的原生字符（中/繁/EN/한），
    // null（跟随系统）用设置图标。Material 没有按语言区分的图标，
    // 原生字符徽标是语言选择器的通用做法，语义一一对应。
    showPiggyOptionSheet<Locale?>(
      context: context,
      title: l10n.languageTitle,
      selected: ref.read(languageProvider),
      highlightColor: ref.read(primaryColorProvider),
      onSelected: (locale) {
        ref.read(languageProvider.notifier).setLanguage(locale);
        // 延迟更新小组件，等待 locale 变化生效；延迟回调属于
        // async gap，先校验页面 context 再使用（抽屉已收起）
        Future.delayed(const Duration(milliseconds: 100), () {
          if (context.mounted) {
            updateAppWidget(ref, context);
          }
        });
      },
      options: [
        PiggyOptionSheetItem(
          value: null,
          title: l10n.languageSystemDefault,
          icon: Icons.settings_suggest_outlined,
        ),
        PiggyOptionSheetItem(
          value: const Locale('zh'),
          title: l10n.languageChinese,
          badge: '中',
        ),
        PiggyOptionSheetItem(
          value: const Locale('zh', 'TW'),
          title: '繁體中文',
          badge: '繁',
        ),
        PiggyOptionSheetItem(
          value: const Locale('en'),
          title: l10n.languageEnglish,
          badge: 'EN',
        ),
        PiggyOptionSheetItem(
          value: const Locale('ko'),
          title: '한국어',
          badge: '한',
        ),
      ],
    );
  }

  /// 外观模式选择 —— 悬浮卡片式底部抽屉单选（组件 widgets/ui/option_sheet）。
  void _showThemeModeSheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    showPiggyOptionSheet<ThemeMode>(
      context: context,
      title: l10n.appearanceThemeMode,
      selected: ref.read(themeModeProvider),
      highlightColor: ref.read(primaryColorProvider),
      onSelected: (mode) => ref.read(themeModeProvider.notifier).state = mode,
      // 跟随系统沿用语言抽屉的 settings_suggest，语义一一对应。
      options: [
        PiggyOptionSheetItem(
          value: ThemeMode.system,
          title: l10n.appearanceThemeModeSystem,
          icon: Icons.settings_suggest_outlined,
        ),
        PiggyOptionSheetItem(
          value: ThemeMode.light,
          title: l10n.appearanceThemeModeLight,
          icon: Icons.light_mode_outlined,
        ),
        PiggyOptionSheetItem(
          value: ThemeMode.dark,
          title: l10n.appearanceThemeModeDark,
          icon: Icons.dark_mode_outlined,
        ),
      ],
    );
  }

  /// 金额显示格式选择 —— 悬浮卡片式底部抽屉单选（组件 widgets/ui/option_sheet）。
  void _showAmountFormatSheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    showPiggyOptionSheet<bool>(
      context: context,
      title: l10n.appearanceAmountFormat,
      selected: ref.read(compactAmountProvider),
      highlightColor: ref.read(primaryColorProvider),
      onSelected: (compact) =>
          ref.read(compactAmountProvider.notifier).state = compact,
      options: [
        PiggyOptionSheetItem(
          value: false,
          title: l10n.appearanceAmountFormatFull,
          desc: l10n.appearanceAmountFormatFullDesc,
          icon: Icons.format_list_numbered_outlined,
        ),
        PiggyOptionSheetItem(
          value: true,
          title: l10n.appearanceAmountFormatCompact,
          desc: l10n.appearanceAmountFormatCompactDesc,
          icon: Icons.compress_outlined,
        ),
      ],
    );
  }

  /// 备注显示方式选择 —— 悬浮卡片式底部抽屉单选（组件 widgets/ui/option_sheet）。
  void _showNoteDisplaySheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    showPiggyOptionSheet<String>(
      context: context,
      title: l10n.appearanceNoteDisplay,
      selected: ref.read(noteDisplayModeProvider),
      highlightColor: ref.read(primaryColorProvider),
      onSelected: (mode) =>
          ref.read(noteDisplayModeProvider.notifier).state = mode,
      options: [
        PiggyOptionSheetItem(
          value: 'category',
          title: l10n.appearanceNoteDisplayCategory,
          desc: l10n.appearanceNoteDisplayCategoryDesc,
          icon: Icons.label_outline,
        ),
        PiggyOptionSheetItem(
          value: 'note',
          title: l10n.appearanceNoteDisplayNote,
          desc: l10n.appearanceNoteDisplayNoteDesc,
          icon: Icons.notes_outlined,
        ),
      ],
    );
  }

  /// 返回历史备注范围和排序方式的摘要文本。
  String _noteHistorySummary(WidgetRef ref, AppLocalizations l10n) {
    final scope = ref.watch(noteHistoryScopeProvider);
    final sort = ref.watch(noteHistorySortProvider);
    final scopeText = scope == NoteHistoryScope.currentCategory
        ? l10n.appearanceNoteHistoryScopeCurrentCategory
        : l10n.appearanceNoteHistoryScopeAllCategories;
    final sortText = sort == NoteHistorySort.recent
        ? l10n.appearanceNoteHistorySortRecent
        : l10n.appearanceNoteHistorySortFrequency;
    final limit = ref.watch(noteHistoryLimitProvider);
    return '$scopeText · $sortText · ${l10n.appearanceNoteHistoryLimit} $limit';
  }

  /// 显示历史备注范围和排序方式的个性化设置对话框。
  void _showNoteHistoryDialog(
      BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    var selectedScope = ref.read(noteHistoryScopeProvider);
    var selectedSort = ref.read(noteHistorySortProvider);
    var limitError = false;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AppDialogShell(
          wide: true,
          title: Text(
            l10n.appearanceNoteHistory,
            style: TextStyle(color: PiggyTokens.textPrimary(context)),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.appearanceNoteHistoryScope,
                  style: TextStyle(
                    color: PiggyTokens.textSecondary(context),
                    fontSize: PiggyTextTokens.fs13.scaled(context, ref),
                  ),
                ),
                RadioGroup<NoteHistoryScope>(
                  groupValue: selectedScope,
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => selectedScope = value);
                    ref.read(noteHistoryScopeProvider.notifier).state = value;
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      RadioListTile<NoteHistoryScope>(
                        value: NoteHistoryScope.allCategories,
                        title:
                            Text(l10n.appearanceNoteHistoryScopeAllCategories),
                        contentPadding: EdgeInsets.zero,
                      ),
                      RadioListTile<NoteHistoryScope>(
                        value: NoteHistoryScope.currentCategory,
                        title: Text(
                            l10n.appearanceNoteHistoryScopeCurrentCategory),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 8.scaled(context, ref)),
                Text(
                  l10n.appearanceNoteHistorySort,
                  style: TextStyle(
                    color: PiggyTokens.textSecondary(context),
                    fontSize: PiggyTextTokens.fs13.scaled(context, ref),
                  ),
                ),
                RadioGroup<NoteHistorySort>(
                  groupValue: selectedSort,
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => selectedSort = value);
                    ref.read(noteHistorySortProvider.notifier).state = value;
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      RadioListTile<NoteHistorySort>(
                        value: NoteHistorySort.frequency,
                        title: Text(l10n.appearanceNoteHistorySortFrequency),
                        contentPadding: EdgeInsets.zero,
                      ),
                      RadioListTile<NoteHistorySort>(
                        value: NoteHistorySort.recent,
                        title: Text(l10n.appearanceNoteHistorySortRecent),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 12.scaled(context, ref)),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.appearanceNoteHistoryLimit,
                            style: TextStyle(
                              color: PiggyTokens.textPrimary(context),
                            ),
                          ),
                          SizedBox(height: 2.scaled(context, ref)),
                          Text(
                            l10n.appearanceNoteHistoryLimitHint,
                            style: TextStyle(
                              color: PiggyTokens.textSecondary(context),
                              fontSize: PiggyTextTokens.fs12.scaled(context, ref),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 12.scaled(context, ref)),
                    SizedBox(
                      width: 72.scaled(context, ref),
                      child: TextFormField(
                        initialValue:
                            ref.read(noteHistoryLimitProvider).toString(),
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ).scaled(context, ref),
                        ),
                        onChanged: (value) {
                          final limit = int.tryParse(value);
                          final isValid = limit != null &&
                              limit >= noteHistoryMinLimit &&
                              limit <= noteHistoryMaxLimit;
                          setDialogState(() => limitError = !isValid);
                          if (isValid) {
                            ref.read(noteHistoryLimitProvider.notifier).state =
                                limit;
                          }
                        },
                      ),
                    ),
                  ],
                ),
                if (limitError)
                  Padding(
                    padding: const EdgeInsets.only(top: 4).scaled(context, ref),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        l10n.appearanceNoteHistoryLimitInvalid,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: PiggyTokens.error(context),
                          fontSize: PiggyTextTokens.fs12.scaled(context, ref),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.commonClose),
            ),
          ],
        ),
      ),
    );
  }

  /// 把当前方案的文案翻译成一层摘要,显示在个性化设置卡的副标题位
  /// (默认显示当前选中的方案名)。三套方案可见后,直接对应
  /// `_showColorSchemeSheet` 里的 3 个 options 条目。
  String _colorSchemeSubtitle(WidgetRef ref, AppLocalizations l10n) {
    switch (ref.watch(incomeExpenseColorSchemeProvider)) {
      case IncomeExpenseColorScheme.redIncome:
        return l10n.appearanceColorSchemeOn;
      case IncomeExpenseColorScheme.greenIncome:
        return l10n.appearanceColorSchemeOff;
      case IncomeExpenseColorScheme.blueIncome:
        return l10n.appearanceColorSchemeBlue;
    }
  }

  /// 收支颜色方案选择 —— 悬浮卡片式底部抽屉单选（组件 widgets/ui/option_sheet）。
  void _showColorSchemeSheet(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    showPiggyOptionSheet<IncomeExpenseColorScheme>(
      context: context,
      title: l10n.appearanceColorScheme,
      selected: ref.read(incomeExpenseColorSchemeProvider),
      highlightColor: ref.read(primaryColorProvider),
      onSelected: (scheme) =>
          ref.read(incomeExpenseColorSchemeProvider.notifier).state = scheme,
      options: [
        PiggyOptionSheetItem(
          value: IncomeExpenseColorScheme.redIncome,
          title: l10n.appearanceColorSchemeOn,
          desc: l10n.appearanceColorSchemeOnDesc,
          icon: Icons.trending_up,
        ),
        PiggyOptionSheetItem(
          value: IncomeExpenseColorScheme.greenIncome,
          title: l10n.appearanceColorSchemeOff,
          desc: l10n.appearanceColorSchemeOffDesc,
          icon: Icons.trending_down,
        ),
        PiggyOptionSheetItem(
          value: IncomeExpenseColorScheme.blueIncome,
          title: l10n.appearanceColorSchemeBlue,
          desc: l10n.appearanceColorSchemeBlueDesc,
          icon: Icons.palette_outlined,
        ),
      ],
    );
  }
}
