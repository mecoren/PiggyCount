import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../data/db.dart';
import 'database_providers.dart';

/// 标签列表刷新触发器
final tagListRefreshProvider = StateProvider<int>((ref) => 0);

/// 所有标签列表 Provider（响应式）
final allTagsStreamProvider = StreamProvider<List<Tag>>((ref) {
  ref.watch(tagListRefreshProvider);
  final repo = ref.watch(repositoryProvider);
  return repo.watchAllTags();
});

/// 所有标签列表 Provider（Future版本）
final allTagsProvider = FutureProvider<List<Tag>>((ref) async {
  ref.watch(tagListRefreshProvider);
  final repo = ref.watch(repositoryProvider);
  return await repo.getAllTags();
});

/// 当前账本可用的标签(标签是 user-scoped,全部账本共用同一份)。
final tagsForCurrentLedgerProvider = FutureProvider<List<Tag>>((ref) async {
  ref.watch(tagListRefreshProvider);
  return ref.watch(repositoryProvider).getAllTags();
});

/// 标签列表带统计信息 Provider（响应式）
/// 返回每个标签及其关联的交易数量
final tagsWithStatsProvider =
    StreamProvider<List<({Tag tag, int transactionCount})>>((ref) {
  ref.watch(tagListRefreshProvider);
  // §7 决策 v25:Owner 资源不 mirror 主表,管理页直接读主 Tags。
  final repo = ref.watch(repositoryProvider);
  return repo.watchTagsWithStats();
});

/// 交易关联的标签 Provider
/// 根据交易ID获取该交易的所有标签
final transactionTagsProvider =
    StreamProvider.family<List<Tag>, int>((ref, transactionId) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchTagsForTransaction(transactionId);
});

/// 标签详情 Provider（响应式）
final tagDetailProvider = StreamProvider.family<Tag?, int>((ref, tagId) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchTag(tagId);
});

/// 标签统计信息 Provider
/// 返回标签的交易数、总支出、总收入
final tagStatsProvider =
    FutureProvider.family<({int count, double expense, double income}), int>(
        (ref, tagId) async {
  ref.watch(tagListRefreshProvider);
  final repo = ref.watch(repositoryProvider);
  return await repo.getTagStats(tagId);
});

/// 标签下的交易列表 Provider（响应式）
final tagTransactionsProvider =
    StreamProvider.family<List<Transaction>, int>((ref, tagId) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchTransactionsByTag(tagId);
});

/// 最近使用的标签(tags ⨝ transaction_tags,按当前账本无关的 user-scoped 口径)。
final recentTagsForCurrentLedgerProvider =
    FutureProvider<List<Tag>>((ref) async {
  ref.watch(tagListRefreshProvider);
  return ref.watch(repositoryProvider).getRecentlyUsedTags(limit: 10);
});

/// 当前账本是否允许在标签选择器中创建标签。
///
/// 标签是 user-scoped,单用户账本恒可创建;仅在账本尚未加载完成时返回
/// false,避免切换账本的短窗口暴露创建入口。
final canCreateTagForCurrentLedgerProvider = Provider<bool>((ref) {
  // 切换账本触发 reload 时 Riverpod 会保留 previous value,这里只要求
  // 已有一个账本可用即可。
  final ledger = ref.watch(currentLedgerProvider).unwrapPrevious().value;
  return ledger != null;
});

/// 最近使用的标签 Provider
/// 用于标签选择器快速选择
final recentlyUsedTagsProvider = FutureProvider<List<Tag>>((ref) async {
  ref.watch(tagListRefreshProvider);
  final repo = ref.watch(repositoryProvider);
  return await repo.getRecentlyUsedTags(limit: 10);
});

/// 标签搜索结果 Provider
/// 根据关键字搜索标签
final tagSearchResultsProvider =
    FutureProvider.family<List<Tag>, String>((ref, keyword) async {
  final allTags = await ref.watch(allTagsProvider.future);

  if (keyword.isEmpty) {
    return allTags;
  }

  final lowerKeyword = keyword.toLowerCase();
  return allTags
      .where((tag) => tag.name.toLowerCase().contains(lowerKeyword))
      .toList();
});

/// 检查标签名是否重复 Provider
final isTagNameDuplicateProvider =
    FutureProvider.family<bool, ({String name, int? excludeId})>(
        (ref, params) async {
  final repo = ref.watch(repositoryProvider);
  return await repo.isTagNameDuplicate(
      name: params.name, excludeId: params.excludeId);
});
