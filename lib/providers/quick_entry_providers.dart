/// P1-E 快捷记账模式 —— provider 层。
///
/// 需求/设计见 `prd/p1e_quick_entry_mode/{requirements,design}.md`。
/// 本文件只负责「把记忆到的分类取出来并**校验**好」，UI 侧只消费结果。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_providers.dart';
import 'statistics_providers.dart';
import 'sync_providers.dart';

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

/// 快捷记账的记忆分类：`kind`（`expense` / `income`）→ **已校验**、可直接预填的分类 id。
///
/// 返回 `null` 表示没有可用记忆，调用方应**退回分类网格**（不要显示空分类的快捷态）。
///
/// 三件事都在这里做完：
/// 1. 取 R1 的 [BaseRepository.getLastUsedCategoryId]（从 `transactions` 派生，
///    不存 pref —— 理由见该方法文档）；
/// 2. **校验**（AC-R2 #4）：预填错分类的危害大于不预填，所以规则从紧 ——
///    记忆到的 id 必须还能查到该分类；
/// 3. 账本切换 / 云端同步到新数据后自动重算（watch 两个上游）。
///
/// 用法：UI 侧用 `.value` **同步**读取。想要「点击即出表单、
/// 中途没有异步等待」的效果，需在首帧后 fire-and-forget 预热一次
/// （见 `app.dart` 的预热调用）。
final quickEntryLastCategoryProvider =
    FutureProvider.family<int?, String>((ref, kind) async {
  // 云端拉下新交易后记忆应随之更新，故跟随同步代数重算。
  ref.watch(syncGenerationProvider);
  // 写后失效：**不**在各写入点逐个 `invalidate` —— 全库 grep 出的交易写入点
  // 有十来处（编辑器保存 / 明细页删除 / 分类·标签详情页 / AI 对话 /
  // 图像语音 PostProcessor / 自动化记账 / CSV 导入 / 云恢复），逐个挂线
  // 「刷新漏一处 → 记忆陈旧」的风险面很大。`statsRefreshProvider` 是这些
  // 写入点本来就**都会** bump 的粗粒度「数据变了」信号，直接跟随它重算：
  // 代价只是一次走索引且 LIMIT 有界的查询，正确性由构造保证。
  // （design.md 决策 3 原写的「唯一写入点 transaction_editor_page.dart」
  //  前提经核查不成立，已回写修正。）
  ref.watch(statsRefreshProvider);
  final ledgerId = ref.watch(currentLedgerIdProvider);
  final repo = ref.watch(repositoryProvider);

  final remembered =
      await repo.getLastUsedCategoryId(ledgerId: ledgerId, kind: kind);
  if (remembered == null) return null;

  // 分类可能已被删除 —— 删了就静默不预填，交由用户重新选。
  final category = await repo.getCategoryById(remembered);
  return category == null ? null : remembered;
});
