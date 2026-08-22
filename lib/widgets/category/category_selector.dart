import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../providers.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/shared_ledger_providers.dart';
import '../../utils/category_utils.dart';
import '../../utils/shared_ledger_picker_filter.dart';
import '../../styles/tokens.dart';
import '../category_icon.dart';
import '../../pages/category/category_manage_page.dart';

/// 分类选择器组件
/// 用于选择收入或支出分类，支持二级分类原地展开
class CategorySelector extends ConsumerStatefulWidget {
  /// 分类类型：'expense' 或 'income'
  final String kind;

  /// 分类选择回调
  final ValueChanged<Category> onCategorySelected;

  /// 初始选中的分类ID（可选）
  final int? initialCategoryId;

  /// 外部滚动控制器（可选）。
  ///
  /// 底部抽屉场景传入 [ExpandableBottomSheet] 提供的控制器后，本组件的主
  /// [ListView] 会驱动抽屉伸缩（上滑扩至全屏、下滑回弹至原样）。为 null
  /// 时（全屏编辑页）保持默认 primary 滚动行为。
  final ScrollController? scrollController;

  const CategorySelector({
    super.key,
    required this.kind,
    required this.onCategorySelected,
    this.initialCategoryId,
    this.scrollController,
  });

  @override
  ConsumerState<CategorySelector> createState() => _CategorySelectorState();
}

class _CategorySelectorState extends ConsumerState<CategorySelector> {
  int? _expandedCategoryId; // 当前展开的一级分类ID
  int? _selectedId; // 记录当前点击的分类用于高亮
  bool _scrolled = false; // 标记是否已滚动
  final Map<int, GlobalKey> _keys = {}; // 分类ID到GlobalKey的映射

  @override
  void initState() {
    super.initState();
    // 如果有初始分类ID，需要在数据加载后设置选中状态和展开状态
    if (widget.initialCategoryId != null) {
      _selectedId = widget.initialCategoryId;
      _initializeExpandedState();
    }
  }

  Future<void> _initializeExpandedState() async {
    if (widget.initialCategoryId == null) return;

    final repo = ref.read(repositoryProvider);
    final initialId = widget.initialCategoryId!;

    // §7 共享账本:initialCategoryId 是 synthetic 负数时,主表 getCategoryById
    // 查不到 → 走 SharedLedgerCategories 反查,通过 parent_sync_id 派生 parent
    // 的 synthetic id,正确展开父分类。
    if (initialId < 0 && repo is LocalRepository) {
      final ctxLedgerId = ref.read(currentLedgerIdProvider);
      final ctx = await repo.db.loadLedgerPickerContext(ctxLedgerId);
      final ledgerSyncId = ctx?.ledgerSyncId;
      if (ledgerSyncId != null) {
        final rows = await (repo.db.select(repo.db.sharedLedgerCategories)
              ..where((t) => t.ledgerSyncId.equals(ledgerSyncId)))
            .get();
        for (final s in rows) {
          if (syntheticIdForSyncId(s.syncId) == initialId) {
            if ((s.level) == 2 &&
                s.parentSyncId != null &&
                s.parentSyncId!.isNotEmpty) {
              setState(() {
                _expandedCategoryId = syntheticIdForSyncId(s.parentSyncId!);
              });
            }
            return;
          }
        }
      }
      return;
    }

    final initialCategory = await repo.getCategoryById(initialId);
    if (initialCategory != null &&
        initialCategory.level == 2 &&
        initialCategory.parentId != null) {
      // 如果是二级分类，展开其父分类
      setState(() {
        _expandedCategoryId = initialCategory.parentId;
      });
    }
  }

  /// §7 共享账本 picker 过滤 — Editor + 共享账本 只显示 Owner 的 SharedLedger
  /// 行,按 kind 过滤;单人账本 / Owner 视角走主表 getTopLevelCategories。
  Future<List<Category>> _loadFilteredTopLevel() async {
    final repo = ref.read(repositoryProvider);
    final cats = await repo.getTopLevelCategories(widget.kind);
    if (repo is! LocalRepository) return cats;
    final currentLedgerId = ref.read(currentLedgerIdProvider);
    final ctx = await repo.db.loadLedgerPickerContext(currentLedgerId);
    return repo.db.filterCategoriesForLedger(cats, ctx, kind: widget.kind);
  }

  /// 构建单个一级分类网格单元（UI-05：从 GridView.itemBuilder 抽出）
  Widget _buildTopCategoryCell(
      Category topCat, Map<int, List<Category>> subCategoriesMap) {
    final children = subCategoriesMap[topCat.id] ?? [];
    final hasChildren = children.isNotEmpty;
    return _CategoryItem(
      category: topCat,
      selected: _selectedId == topCat.id,
      hasChildren: hasChildren,
      expanded: _expandedCategoryId == topCat.id,
      onTap: () {
        if (hasChildren) {
          // 有子分类，切换展开/折叠
          setState(() {
            if (_expandedCategoryId == topCat.id) {
              _expandedCategoryId = null;
            } else {
              _expandedCategoryId = topCat.id;
            }
          });
        } else {
          // 无子分类，直接选中，同时关闭展开的二级分类
          setState(() {
            _selectedId = topCat.id;
            _expandedCategoryId = null; // 关闭展开的二级分类
          });
          widget.onCategorySelected(topCat);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // §7 共享账本:WS shared_resource_change 推送后 tick bump,触发 rebuild
    // → FutureBuilder 拿到新 Future → 重查 SharedLedgerCategories。否则 A
    // 在 web/mobile 改分类名,B 这边 picker 永远显示旧名,要重启 app。
    ref.watch(sharedResourceRefreshProvider);
    return FutureBuilder<List<Category>>(
      future: _loadFilteredTopLevel(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final topLevelCategories = snapshot.data!;

        if (topLevelCategories.isEmpty) {
          return Center(
            child: Text(AppLocalizations.of(context).categoryEmpty),
          );
        }

        return FutureBuilder<Map<int, List<Category>>>(
          future: _loadSubCategories(topLevelCategories),
          builder: (context, subSnapshot) {
            if (!subSnapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }

            final subCategoriesMap = subSnapshot.data!;

            // 滚动到初始选中的分类
            if (!_scrolled && widget.initialCategoryId != null) {
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                // 获取初始分类信息以确定滚动目标
                final repo = ref.read(repositoryProvider);
                final initialCategory =
                    await repo.getCategoryById(widget.initialCategoryId!);

                if (initialCategory != null) {
                  int scrollTargetId;

                  // 如果是二级分类，滚动到父分类；否则滚动到自己
                  if (initialCategory.level == 2 &&
                      initialCategory.parentId != null) {
                    scrollTargetId = initialCategory.parentId!;
                  } else {
                    scrollTargetId = initialCategory.id;
                  }

                  final key = _keys[scrollTargetId];
                  final ctx = key?.currentContext;
                  if (ctx != null) {
                    Scrollable.ensureVisible(
                      ctx,
                      alignment: 0.0,
                      duration: const Duration(milliseconds: 250),
                    );
                    _scrolled = true;
                  }
                }
              });
            }

            // 构建显示项列表：分类网格项(放入卡片)与尾部项(设置按钮等留在卡片外)
            final categoryItems = <Widget>[];
            final trailingItems = <Widget>[];

            // 按每4个一组显示一级分类
            for (int i = 0; i < topLevelCategories.length; i += 4) {
              final endIndex = (i + 4).clamp(0, topLevelCategories.length);
              final rowItems = topLevelCategories.sublist(i, endIndex);

              // 为该行第一个分类创建key（用于滚动定位）
              final firstCategoryInRow = rowItems.first;

              // 添加网格行
              categoryItems.add(
                Container(
                  key: _keys.putIfAbsent(
                      firstCategoryInRow.id, () => GlobalKey()),
                  // UI-05：以静态网格替代 shrinkWrap GridView，
                  // 消除嵌套 viewport 的布局与构建开销
                  child: _StaticGrid(
                    crossAxisCount: 4,
                    spacing: 16,
                    runSpacing: 12,
                    childAspectRatio: 0.78,
                    children: [
                      for (final topCat in rowItems)
                        _buildTopCategoryCell(topCat, subCategoriesMap),
                    ],
                  ),
                ),
              );

              // 检查这一行中是否有展开的分类，如果有则添加二级分类容器
              for (int j = 0; j < rowItems.length; j++) {
                final topCat = rowItems[j];
                final children = subCategoriesMap[topCat.id] ?? [];
                final hasChildren = children.isNotEmpty;

                if (_expandedCategoryId == topCat.id && hasChildren) {
                  categoryItems.add(
                    const SizedBox(height: 12),
                  );
                  categoryItems.add(
                    _SubcategorySelectorCard(
                      parentCategory: topCat,
                      subCategories: children,
                      selectedId: _selectedId,
                      onSubCategoryTap: (cat) {
                        setState(() => _selectedId = cat.id);
                        widget.onCategorySelected(cat);
                      },
                    ),
                  );
                  break; // 每行只展开一个
                }
              }

              if (i + 4 < topLevelCategories.length) {
                categoryItems.add(const SizedBox(height: 16));
              }
            }

            // 添加设置按钮(留在卡片外)
            trailingItems.add(const SizedBox(height: 24));
            trailingItems.add(
              Center(
                child: InkWell(
                  onTap: () {
                    // expense: tab 0, income: tab 1
                    final tabIndex = widget.kind == 'expense' ? 0 : 1;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CategoryManagePage(
                          initialTabIndex: tabIndex,
                        ),
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(PiggyDimens.radius3xl),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.settings_outlined,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          AppLocalizations.of(context).mineCategoryManagement,
                          style: PiggyTextTokens.body(context).copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            trailingItems.add(const SizedBox(height: 12));

            // scrollController 非空(底部抽屉)时由其驱动抽屉伸缩；
            // 为 null(全屏编辑页)保持 primary 默认滚动行为
            final useSheetController = widget.scrollController != null;
            final primaryColor = Theme.of(context).colorScheme.primary;
            return ListView(
              controller: widget.scrollController,
              primary: !useSheetController,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              children: [
                // 分类网格区域卡片：边框主题色,内部背景 #f9f9f9(亮)/ 深蓝灰(暗)
                Container(
                  decoration: BoxDecoration(
                    color: PiggyTokens.surface(context),
                    borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
                    border: Border.all(color: primaryColor, width: 1.5),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: categoryItems,
                  ),
                ),
                ...trailingItems,
              ],
            );
          },
        );
      },
    );
  }

  Future<Map<int, List<Category>>> _loadSubCategories(
      List<Category> topLevelCategories) async {
    final repo = ref.read(repositoryProvider);
    final result = <int, List<Category>>{};

    // §7 共享账本:Editor 视角下父分类 id 是 synthetic 负数,主表
    // getSubCategories(parentInt) 查不到。改走 SharedLedgerCategories 表按
    // parent_sync_id 反查;非共享 / Owner 走原主表路径。
    final currentLedgerId = ref.read(currentLedgerIdProvider);
    LedgerPickerContext? ctx;
    if (repo is LocalRepository) {
      ctx = await repo.db.loadLedgerPickerContext(currentLedgerId);
    }
    final isSharedEditor = ctx?.isEditorInShared == true;

    for (final cat in topLevelCategories) {
      List<Category> children;
      if (isSharedEditor && cat.id < 0 && repo is LocalRepository) {
        children = await repo.db.getSharedSubCategoriesBySyntheticParentId(
            cat.id, ctx!.ledgerSyncId!);
      } else {
        children = await repo.getSubCategories(cat.id);
      }
      if (children.isNotEmpty) {
        result[cat.id] = children;
      }
    }

    return result;
  }
}

/// 二级分类选择器卡片
class _SubcategorySelectorCard extends ConsumerWidget {
  final Category parentCategory;
  final List<Category> subCategories;
  final int? selectedId;
  final ValueChanged<Category> onSubCategoryTap;

  const _SubcategorySelectorCard({
    required this.parentCategory,
    required this.subCategories,
    required this.selectedId,
    required this.onSubCategoryTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: PiggyTokens.surfacePopoverCard(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        // 去底色风格：去掉彩色阴影，统一用细边框区分二级分类区
        border: Border.all(color: PiggyTokens.border(context)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        // UI-05：同上，静态网格替代 shrinkWrap GridView
        child: _StaticGrid(
          crossAxisCount: 4,
          spacing: 12,
          runSpacing: 12,
          childAspectRatio: 0.84,
          children: [
            for (final subCat in subCategories)
              _CategoryItem(
                category: subCat,
                selected: selectedId == subCat.id,
                isSubCategory: true,
                onTap: () => onSubCategoryTap(subCat),
              ),
          ],
        ),
      ),
    );
  }
}

/// UI-05：静态网格助手。
///
/// 替代 `GridView.builder(shrinkWrap:true, NeverScrollableScrollPhysics)`
/// 嵌套在滚动容器内的写法——那种结构会一次性构建全部子项，还叠加
/// viewport 布局开销，builder 的懒加载完全失效。此助手用
/// LayoutBuilder + Wrap 复刻 SliverGridDelegateWithFixedCrossAxisCount
/// 的几何（等宽单元 / 固定纵横比 / 行列间距），视觉与原网格一致，
/// 但没有任何滚动语义。
class _StaticGrid extends StatelessWidget {
  final int crossAxisCount;
  final double spacing;
  final double runSpacing;
  final double childAspectRatio;
  final List<Widget> children;

  const _StaticGrid({
    required this.crossAxisCount,
    required this.spacing,
    required this.runSpacing,
    required this.childAspectRatio,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final cellWidth =
          (width - spacing * (crossAxisCount - 1)) / crossAxisCount;
      final cellHeight = cellWidth / childAspectRatio;
      return Wrap(
        spacing: spacing,
        runSpacing: runSpacing,
        children: [
          for (final child in children)
            SizedBox(width: cellWidth, height: cellHeight, child: child),
        ],
      );
    });
  }
}

/// 分类项组件
class _CategoryItem extends StatelessWidget {
  final Category category;
  final VoidCallback onTap;
  final bool selected;
  final bool isSubCategory;
  final Category? parent;
  final bool hasChildren;
  final bool expanded;

  const _CategoryItem({
    required this.category,
    required this.onTap,
    this.selected = false,
    this.isSubCategory = false,
    this.parent,
    this.hasChildren = false,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    // 去底色风格：未选中无背景，仅图标；选中用主色高亮环+主色图标
    final iconSize = isSubCategory ? 48.0 : 56.0; // 容器尺寸(点击区+徽标锚点)
    final iconGlyphSize = isSubCategory ? 28.0 : 34.0; // 实际图标(比旧值放大)
    final fontSize = isSubCategory ? 11.0 : 12.0;
    final primaryColor = Theme.of(context).colorScheme.primary;
    final iconColor =
        selected ? primaryColor : PiggyTokens.iconCategory(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: iconSize,
                height: iconSize,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // 选中态：极淡主色底 + 主色环作为高亮；未选中无任何底色
                  color: selected ? primaryColor.withValues(alpha: 0.08) : null,
                  border: selected
                      ? Border.all(color: primaryColor, width: 1.5)
                      : null,
                ),
                child: CategoryIconWidget(
                  category: category,
                  size: iconGlyphSize,
                  color: iconColor,
                ),
              ),
              // 有子分类：右下角三点指示(去底色，仅淡色图标)
              if (hasChildren && !isSubCategory)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Icon(
                    Icons.more_horiz,
                    size: 16,
                    color: PiggyTokens.iconTertiary(context),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            CategoryUtils.getDisplayName(category.name, context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: fontSize,
                  color: selected
                      ? primaryColor
                      : (isSubCategory
                          ? PiggyTokens.textSecondary(context)
                          : PiggyTokens.textPrimary(context)),
                ),
          ),
        ],
      ),
    );
  }
}
