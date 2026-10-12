/// P1-E 快捷记账模式 —— provider 层（当前只剩「模式开关」）。
///
/// 需求/设计见 `prd/p1e_quick_entry_mode/{requirements,design}.md`。
///
/// 历史：这里曾定义 `quickEntryLastCategoryProvider`（「记忆上次分类」，无时间
/// 窗）。它已被「**5 分钟内**继承上一笔的分类与账户」取代 —— 窗口随墙钟滑动，
/// 任何缓存的 Provider 都会给出陈旧命中（5 分钟内打开过一次、6 分钟后打开仍被
/// 判命中），故改为记账页每次打开现查一次仓储
/// （`TransactionRepository.getRecentEntryDefaults`，见
/// `lib/pages/transaction/transaction_editor_page.dart` 的 `_resolveQuickInitials`）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String quickEntryModePrefKey = 'quickEntryModeEnabled';

/// 「快捷记账模式」开关（默认开）。
///
/// 范式逐字对齐 [showTransactionTimeProvider]/[showTransactionTimeInitProvider]
/// （`providers/theme_providers.dart`）—— 本项改变的是默认高频交互，
/// 必须给用户留回退到旧流程的开关，也是 AC-R4 的落点。
final quickEntryModeEnabledProvider = StateProvider<bool>((ref) => true);

/// 「快捷记账模式」开关的持久化初始化（读取 + 变更写回）。
final quickEntryModeEnabledInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool(quickEntryModePrefKey);
  if (saved != null) {
    ref.read(quickEntryModeEnabledProvider.notifier).state = saved;
  }
  ref.listen<bool>(quickEntryModeEnabledProvider, (prev, next) async {
    await prefs.setBool(quickEntryModePrefKey, next);
  });
});
