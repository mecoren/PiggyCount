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
import './language_settings_page.dart';
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
                onTap: () => _showThemeModeDialog(context, ref, l10n),
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
                onTap: () => _showAmountFormatDialog(context, ref, l10n),
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
              // 备注显示方式
              SettingsNavItem(
                icon: Icons.notes_outlined,
                title: l10n.appearanceNoteDisplay,
                subtitle: ref.watch(noteDisplayModeProvider) == 'note'
                    ? l10n.appearanceNoteDisplayNote
                    : l10n.appearanceNoteDisplayCategory,
                onTap: () => _showNoteDisplayDialog(context, ref, l10n),
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
                onTap: () => _showColorSchemeDialog(context, ref, l10n),
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
              // 语言设置
              SettingsNavItem(
                icon: Icons.language_outlined,
                title: l10n.mineLanguageSettings,
                subtitle: languageDisplay,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const LanguageSettingsPage()),
                  );
                },
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

  /// 显示主题模式选择对话框
  void _showThemeModeDialog(
      BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final currentMode = ref.read(themeModeProvider);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: PiggyTokens.surfaceElevated(context),
        title: Text(
          l10n.appearanceThemeMode,
          style: TextStyle(color: PiggyTokens.textPrimary(context)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildModeOption(
              context,
              ref,
              title: l10n.appearanceThemeModeSystem,
              value: ThemeMode.system,
              currentValue: currentMode,
              icon: Icons.settings_suggest_outlined,
            ),
            _buildModeOption(
              context,
              ref,
              title: l10n.appearanceThemeModeLight,
              value: ThemeMode.light,
              currentValue: currentMode,
              icon: Icons.light_mode_outlined,
            ),
            _buildModeOption(
              context,
              ref,
              title: l10n.appearanceThemeModeDark,
              value: ThemeMode.dark,
              currentValue: currentMode,
              icon: Icons.dark_mode_outlined,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeOption(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required ThemeMode value,
    required ThemeMode currentValue,
    required IconData icon,
  }) {
    final isSelected = value == currentValue;
    final primaryColor = ref.watch(primaryColorProvider);

    return ListTile(
      leading: Icon(
        icon,
        color: isSelected ? primaryColor : PiggyTokens.iconSecondary(context),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isSelected ? primaryColor : PiggyTokens.textPrimary(context),
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      trailing: isSelected ? Icon(Icons.check, color: primaryColor) : null,
      onTap: () {
        ref.read(themeModeProvider.notifier).state = value;
        Navigator.pop(context);
      },
    );
  }

  /// 显示金额显示格式选择对话框
  void _showAmountFormatDialog(
      BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final isCompact = ref.read(compactAmountProvider);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: PiggyTokens.surfaceElevated(context),
        title: Text(
          l10n.appearanceAmountFormat,
          style: TextStyle(color: PiggyTokens.textPrimary(context)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildAmountFormatOption(
              context,
              ref,
              title: l10n.appearanceAmountFormatFull,
              subtitle: l10n.appearanceAmountFormatFullDesc,
              value: false,
              currentValue: isCompact,
              icon: Icons.format_list_numbered_outlined,
            ),
            _buildAmountFormatOption(
              context,
              ref,
              title: l10n.appearanceAmountFormatCompact,
              subtitle: l10n.appearanceAmountFormatCompactDesc,
              value: true,
              currentValue: isCompact,
              icon: Icons.compress_outlined,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAmountFormatOption(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String subtitle,
    required bool value,
    required bool currentValue,
    required IconData icon,
  }) {
    final isSelected = value == currentValue;
    final primaryColor = ref.watch(primaryColorProvider);

    return ListTile(
      leading: Icon(
        icon,
        color: isSelected ? primaryColor : PiggyTokens.iconSecondary(context),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isSelected ? primaryColor : PiggyTokens.textPrimary(context),
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: PiggyTextTokens.label(context),
      ),
      trailing: isSelected ? Icon(Icons.check, color: primaryColor) : null,
      onTap: () {
        ref.read(compactAmountProvider.notifier).state = value;
        Navigator.pop(context);
      },
    );
  }

  /// 显示备注显示方式选择对话框
  void _showNoteDisplayDialog(
      BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final current = ref.read(noteDisplayModeProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: PiggyTokens.surfaceElevated(context),
        title: Text(
          l10n.appearanceNoteDisplay,
          style: TextStyle(color: PiggyTokens.textPrimary(context)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildNoteDisplayOption(
              context,
              ref,
              title: l10n.appearanceNoteDisplayCategory,
              subtitle: l10n.appearanceNoteDisplayCategoryDesc,
              value: 'category',
              currentValue: current,
              icon: Icons.label_outline,
            ),
            _buildNoteDisplayOption(
              context,
              ref,
              title: l10n.appearanceNoteDisplayNote,
              subtitle: l10n.appearanceNoteDisplayNoteDesc,
              value: 'note',
              currentValue: current,
              icon: Icons.notes_outlined,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoteDisplayOption(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String subtitle,
    required String value,
    required String currentValue,
    required IconData icon,
  }) {
    final isSelected = value == currentValue;
    final primaryColor = ref.watch(primaryColorProvider);
    return ListTile(
      leading: Icon(icon,
          color:
              isSelected ? primaryColor : PiggyTokens.iconSecondary(context)),
      title: Text(
        title,
        style: TextStyle(
          color: isSelected ? primaryColor : PiggyTokens.textPrimary(context),
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: PiggyTextTokens.label(context),
      ),
      trailing: isSelected ? Icon(Icons.check, color: primaryColor) : null,
      onTap: () {
        ref.read(noteDisplayModeProvider.notifier).state = value;
        Navigator.pop(context);
      },
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
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: PiggyTokens.surfaceElevated(context),
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
                    fontSize: 13.scaled(context, ref),
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
                        title: Text(
                            l10n.appearanceNoteHistoryScopeAllCategories),
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
                    fontSize: 13.scaled(context, ref),
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
                              fontSize: 12.scaled(context, ref),
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
                          fontSize: 12.scaled(context, ref),
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
  /// `_showColorSchemeDialog` 里的 3 个 `_buildColorSchemeOption`。
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

  /// 显示收支颜色方案选择对话框
  void _showColorSchemeDialog(
      BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final currentScheme = ref.read(incomeExpenseColorSchemeProvider);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: PiggyTokens.surfaceElevated(context),
        title: Text(
          l10n.appearanceColorScheme,
          style: TextStyle(color: PiggyTokens.textPrimary(context)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildColorSchemeOption(
              context,
              ref,
              title: l10n.appearanceColorSchemeOn,
              subtitle: l10n.appearanceColorSchemeOnDesc,
              value: IncomeExpenseColorScheme.redIncome,
              currentValue: currentScheme,
              icon: Icons.trending_up,
            ),
            _buildColorSchemeOption(
              context,
              ref,
              title: l10n.appearanceColorSchemeOff,
              subtitle: l10n.appearanceColorSchemeOffDesc,
              value: IncomeExpenseColorScheme.greenIncome,
              currentValue: currentScheme,
              icon: Icons.trending_down,
            ),
            _buildColorSchemeOption(
              context,
              ref,
              title: l10n.appearanceColorSchemeBlue,
              subtitle: l10n.appearanceColorSchemeBlueDesc,
              value: IncomeExpenseColorScheme.blueIncome,
              currentValue: currentScheme,
              icon: Icons.palette_outlined,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildColorSchemeOption(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String subtitle,
    required IncomeExpenseColorScheme value,
    required IncomeExpenseColorScheme currentValue,
    required IconData icon,
  }) {
    final isSelected = value == currentValue;
    final primaryColor = ref.watch(primaryColorProvider);

    return ListTile(
      leading: Icon(
        icon,
        color: isSelected ? primaryColor : PiggyTokens.iconSecondary(context),
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isSelected ? primaryColor : PiggyTokens.textPrimary(context),
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: PiggyTextTokens.label(context),
      ),
      trailing: isSelected ? Icon(Icons.check, color: primaryColor) : null,
      onTap: () {
        ref.read(incomeExpenseColorSchemeProvider.notifier).state = value;
        Navigator.pop(context);
      },
    );
  }
}
