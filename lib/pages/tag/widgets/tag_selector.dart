import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/db.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/tag_providers.dart';
import '../../../styles/tokens.dart';
import '../../../widgets/biz/tag_chip.dart';
import '../../../widgets/ui/ui.dart';
import '../tag_edit_page.dart';

/// 标签选择器
/// 底部弹窗形式，支持多选
/// 使用 LRU（最近最少使用）算法排序：最近使用的标签排在前面
class TagSelector extends ConsumerStatefulWidget {
  /// 当前已选中的标签ID列表
  final List<int> selectedTagIds;

  /// 选择完成回调
  final void Function(List<int> selectedIds)? onConfirm;

  const TagSelector({
    super.key,
    this.selectedTagIds = const [],
    this.onConfirm,
  });

  /// 显示标签选择器
  static Future<List<int>?> show(
    BuildContext context, {
    List<int> selectedTagIds = const [],
  }) async {
    return await showModalBottomSheet<List<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TagSelector(
        selectedTagIds: selectedTagIds,
      ),
    );
  }

  @override
  ConsumerState<TagSelector> createState() => _TagSelectorState();
}

class _TagSelectorState extends ConsumerState<TagSelector> {
  late Set<int> _selectedIds;
  // 用 ValueNotifier 承载搜索词:输入时只局部重建列表区(过滤结果),
  // 不再 setState 重建整个 sheet(标题/搜索框/最近使用/全部 chip)。
  // 这是输入法卡顿根因——每个字符全量重建 + 重过滤 + 重渲染所有 TagChip。
  final ValueNotifier<String> _searchText = ValueNotifier('');

  @override
  void initState() {
    super.initState();
    _selectedIds = Set.from(widget.selectedTagIds);
  }

  @override
  void dispose() {
    _searchText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // unwrapPrevious:切账本 reload 期间沿用旧数据渲染,不闪 loading。
    final allTagsAsync =
        ref.watch(tagsForCurrentLedgerProvider).unwrapPrevious();
    final recentTagsAsync =
        ref.watch(recentTagsForCurrentLedgerProvider).unwrapPrevious();
    final canCreateTag = ref.watch(canCreateTagForCurrentLedgerProvider);
    final visibleTagIds =
        allTagsAsync.value?.map((tag) => tag.id).toSet();

    return PiggyPickerSheet(
      title: l10n.tagSelectTitle,
      subtitle: l10n.tagSelectHint,
      maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      // 等当前账本标签加载完成(或可创建新标签)后才能确认。
      confirmEnabled: canCreateTag || visibleTagIds != null,
      onConfirm: () {
        Navigator.of(context).pop(_selectedIds.toList());
      },
      child: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              // 选择器内的搜索行用无边框内嵌样式（表单输入框才用描边式）
              decoration: piggyFilledDecoration(
                context,
                hint: l10n.commonSearch,
                prefixIcon: const Icon(Icons.search, size: 20),
              ),
              onChanged: (value) => _searchText.value = value,
            ),
          ),
          const SizedBox(height: 12),

          // 内容区
          // ValueListenableBuilder 监听搜索词:按键时仅此区域重建(过滤 + 列表),
          // 标题/搜索框/选中态 chip 等其余部分保持不变,消除输入卡顿。
          Expanded(
            child: ValueListenableBuilder<String>(
              valueListenable: _searchText,
              builder: (context, searchText, _) {
                return allTagsAsync.when(
                  loading: () => Center(
                      child: PiggySpinner(
                          size: 36, color: PiggyTokens.primary(context))),
                  error: (error, stack) => Center(child: Text('$error')),
                  data: (allTags) {
                    // 过滤搜索结果
                    final filteredTags = searchText.isEmpty
                        ? allTags
                        : allTags
                            .where((t) => t.name
                                .toLowerCase()
                                .contains(searchText.toLowerCase()))
                            .toList();

                    if (filteredTags.isEmpty && allTags.isEmpty) {
                      return _buildEmptyState(
                        l10n,
                        canCreateTag: canCreateTag,
                      );
                    }

                    return ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        // 最近使用
                        if (searchText.isEmpty)
                          recentTagsAsync.when(
                            loading: () => const SizedBox.shrink(),
                            error: (_, __) => const SizedBox.shrink(),
                            data: (recentTags) {
                              if (recentTags.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return _buildSection(
                                l10n.tagSelectRecentlyUsed,
                                recentTags,
                              );
                            },
                          ),

                        // 全部标签
                        if (filteredTags.isNotEmpty)
                          _buildSection(
                            searchText.isEmpty
                                ? l10n.tagSelectAllTags
                                : '${l10n.commonSearch}结果',
                            filteredTags,
                          ),

                        // 新建标签入口。
                        if (canCreateTag) ...[
                          const SizedBox(height: 8),
                          _buildCreateNew(l10n),
                        ],
                        const SizedBox(height: 16),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(
    AppLocalizations l10n, {
    required bool canCreateTag,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.label_outline,
            size: 48,
            color: PiggyTokens.textTertiary(context),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.tagManageEmpty,
            style: TextStyle(
              color: PiggyTokens.textSecondary(context),
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _createNewTag,
            icon: const Icon(Icons.add, size: 18),
            label: Text(l10n.tagSelectCreateNew),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Tag> tags) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: PiggyTextTokens.fs13,
              fontWeight: FontWeight.w500,
              color: PiggyTokens.textSecondary(context),
            ),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: tags.map((tag) {
            final isSelected = _selectedIds.contains(tag.id);
            return TagChip(
              name: tag.name,
              color: tag.color,
              size: TagChipSize.medium,
              isSelected: isSelected,
              onTap: () {
                setState(() {
                  if (isSelected) {
                    _selectedIds.remove(tag.id);
                  } else {
                    _selectedIds.add(tag.id);
                  }
                });
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildCreateNew(AppLocalizations l10n) {
    return InkWell(
      onTap: _createNewTag,
      borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: PiggyTokens.border(context),
            style: BorderStyle.solid,
          ),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.add,
              size: 18,
              color: PiggyTokens.primary(context),
            ),
            const SizedBox(width: 8),
            Text(
              l10n.tagSelectCreateNew,
              style: TextStyle(
                color: PiggyTokens.primary(context),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _createNewTag() async {
    // 统一走表单抽屉（[showTagFormBottomSheet]），保存后回传已落库的 Tag
    final result = await showTagFormBottomSheet(context);

    // 异步返回后页面可能已卸载,先查 mounted 再动状态。
    if (!mounted) return;

    // 如果创建了新标签，自动选中
    if (result != null) {
      setState(() {
        _selectedIds.add(result.id);
      });
    }
    // 刷新标签列表
    ref.read(tagListRefreshProvider.notifier).state++;
  }
}
