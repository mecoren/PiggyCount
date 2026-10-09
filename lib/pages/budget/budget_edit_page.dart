import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../services/billing/post_processor.dart';
import '../../services/data/category_service.dart';
import '../../styles/tokens.dart';
import '../../utils/currencies.dart';
import '../../widgets/ui/ui.dart';

/// 以底部抽屉形式弹出预算编辑器（新建 / 编辑通用）
///
/// 唯一入口：新建（总预算 / 分类预算）与编辑都走项目统一的**悬浮卡片表单抽屉**
/// （[PiggyFormSheet]：居中标题 + 卡片内滚动表单 + 底部「取消｜保存」双等宽按钮），
/// 与云同步配置表单（`cloud_service_page.dart` 的 Supabase / WebDAV / S3 三表单）/
/// 加密设置密码 / 账户编辑同款。表单逻辑仍在本文件的 [BudgetEditPage]。
///
/// 编辑态的「删除」渲染在表单主体末尾、「取消｜保存」之上；保存 / 删除都走
/// `Navigator.pop`，调用方据返回值决定要不要连带刷新上一层。
Future<bool?> showBudgetFormBottomSheet(
  BuildContext context, {
  Budget? budget,
  bool isCategory = false,
}) {
  return showPiggyFormSheet<bool>(
    context,
    builder: (_) => BudgetEditPage(budget: budget, isCategory: isCategory),
  );
}

/// 预算编辑表单（悬浮卡片抽屉内容）
class BudgetEditPage extends ConsumerStatefulWidget {
  final Budget? budget;
  final bool isCategory;

  const BudgetEditPage({
    this.budget,
    this.isCategory = false,
    super.key,
  });

  @override
  ConsumerState<BudgetEditPage> createState() => _BudgetEditPageState();
}

class _BudgetEditPageState extends ConsumerState<BudgetEditPage> {
  final _amountController = TextEditingController();
  late String _type;
  int? _selectedCategoryId;
  String? _selectedCategoryName;
  String? _selectedCategoryIcon;
  int _startDay = 1;
  bool _isLoading = false;
  bool _hasTotalBudget = false; // 是否已存在总预算

  bool get _isEditing => widget.budget != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _type = widget.budget!.type;
      _amountController.text = widget.budget!.amount.toStringAsFixed(0);
      _selectedCategoryId = widget.budget!.categoryId;
      _startDay = widget.budget!.startDay;
    } else {
      _type = widget.isCategory ? 'category' : 'total';
      // 检查是否已存在总预算
      _checkTotalBudgetExists();
    }
  }

  Future<void> _checkTotalBudgetExists() async {
    final totalBudget = await ref.read(totalBudgetProvider.future);
    if (mounted && totalBudget != null) {
      setState(() {
        _hasTotalBudget = true;
        // 如果已存在总预算，默认选择分类预算
        if (_type == 'total') {
          _type = 'category';
        }
      });
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  /// 表单分区标题（与账户编辑抽屉同一口径：字段直接浮在抽屉卡片底上，
  /// 不再套一层主题色描边卡片 —— 那会变成卡片套卡片，见 `SectionCard.flat`）
  TextStyle _sectionTitle(BuildContext context) => TextStyle(
        fontSize: PiggyTextTokens.fs14,
        fontWeight: FontWeight.w600,
        color: PiggyTokens.textPrimary(context),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final currencyCode =
        ref.watch(currentLedgerProvider).asData?.value?.currency ?? 'CNY';
    final currencySymbol = getCurrencySymbol(currencyCode);

    return PiggyFormSheet(
      title: _isEditing ? l10n.budgetEditTitle : l10n.budgetAddTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: _saveBudget,
      confirmBusy: _isLoading,
      // 删除（仅编辑态）：固定在「取消｜保存」之上的常驻层，与其它编辑抽屉一致。
      deleteLabel: _isEditing ? l10n.commonDelete : null,
      onDelete: _deleteBudget,
      deleteBusy: _isLoading,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 预算类型（仅新建；编辑态类型不可改）
          if (!_isEditing) ...[
            Text(l10n.budgetPeriodLabel, style: _sectionTitle(context)),
            const SizedBox(height: PiggyDimens.p12),
            Row(
              children: [
                Expanded(
                  child: _buildTypeOption(
                    context,
                    l10n.budgetTypeTotalLabel,
                    'total',
                    Icons.account_balance_wallet_outlined,
                    disabled: _hasTotalBudget, // 已有总预算时禁用
                  ),
                ),
                const SizedBox(width: PiggyDimens.p12),
                Expanded(
                  child: _buildTypeOption(
                    context,
                    l10n.budgetTypeCategoryLabel,
                    'category',
                    Icons.category_outlined,
                  ),
                ),
              ],
            ),
            const SizedBox(height: PiggyDimens.p20),
          ],
          // 分类选择（仅分类预算）
          if (_type == 'category') ...[
            _buildCategorySelector(context, l10n),
            const SizedBox(height: PiggyDimens.p20),
          ],
          // 预算金额
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
            ],
            style: const TextStyle(fontSize: PiggyTextTokens.fs16),
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.budgetAmountLabel,
              hint: l10n.budgetAmountHint,
              prefix: '$currencySymbol ',
            ),
          ),
          // 预算周期跟随「账本设置 → 每月起始日」(period-start-date 设计 D5),
          // 不再提供 per-budget 起始日;独立覆盖若有需求走二期新列。
          //
        ],
      ),
    );
  }

  Widget _buildTypeOption(
    BuildContext context,
    String label,
    String type,
    IconData icon, {
    bool disabled = false,
  }) {
    final isSelected = _type == type;
    final active = isSelected && !disabled;
    final primary = ref.watch(primaryColorProvider);

    return InkWell(
      onTap: disabled ? null : () => setState(() => _type = type),
      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Container(
          padding: const EdgeInsets.all(PiggyDimens.p16),
          decoration: BoxDecoration(
            color: active
                ? primary.withValues(alpha: 0.1)
                : PiggyTokens.surface(context),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            // 高亮只给选中项：未选中走中性描边，否则两张卡片看起来都是选中态
            border: Border.all(
              color: active ? primary : PiggyTokens.borderStrong(context),
              width: active ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 32,
                color: active ? primary : PiggyTokens.iconSecondary(context),
              ),
              const SizedBox(height: PiggyDimens.p8),
              Text(
                label,
                style: TextStyle(
                  fontSize: PiggyTextTokens.fs14,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? primary : PiggyTokens.textSecondary(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分类选择行：表单抽屉里走描边式浮动标签（[piggyOutlinedDecoration]），
  /// 与账户编辑抽屉的币种选择同款，不再自绘主题色描边容器。
  Widget _buildCategorySelector(BuildContext context, AppLocalizations l10n) {
    final hasCategory = _selectedCategoryId != null;

    return InkWell(
      onTap: _selectCategory,
      borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
      child: InputDecorator(
        decoration: piggyOutlinedDecoration(
          context,
          label: l10n.budgetCategoryLabel,
        ),
        child: Row(
          children: [
            if (hasCategory) ...[
              Icon(
                CategoryService.getCategoryIcon(_selectedCategoryIcon),
                size: 20,
                color: PiggyTokens.primary(context),
              ),
              const SizedBox(width: PiggyDimens.p12),
              Expanded(
                child: Text(
                  _selectedCategoryName ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                ),
              ),
            ] else ...[
              Icon(
                Icons.add_circle_outline,
                size: 20,
                color: PiggyTokens.iconTertiary(context),
              ),
              const SizedBox(width: PiggyDimens.p12),
              Expanded(
                child: Text(
                  l10n.budgetCategoryHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: PiggyTextTokens.fs16,
                    color: PiggyTokens.textTertiary(context),
                  ),
                ),
              ),
            ],
            Icon(
              Icons.expand_more,
              size: 18,
              color: PiggyTokens.iconTertiary(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectCategory() async {
    final repo = ref.read(repositoryProvider);
    final categories = await repo.getAllCategories();

    // 只显示支出类父分类
    final expenseCategories = categories
        .where((c) => c.kind == 'expense' && c.parentId == null)
        .toList();

    if (!mounted) return;

    final selected = await showPiggyPickerSheet<Category>(
      context,
      builder: (bctx) => PiggyPickerSheet(
        title: AppLocalizations.of(context).budgetCategoryLabel,
        // 点选即应用并收起，无待提交选中态 → 顶栏只留 X + 标题
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        child: ListView.builder(
          itemCount: expenseCategories.length,
          itemBuilder: (context, index) {
            final category = expenseCategories[index];
            return ListTile(
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                ),
                child: Icon(
                  CategoryService.getCategoryIcon(category.icon),
                  color: PiggyTokens.primary(context),
                ),
              ),
              title: Text(category.name),
              trailing: _selectedCategoryId == category.id
                  ? Icon(
                      Icons.check_circle,
                      color: PiggyTokens.primary(context),
                    )
                  : null,
              onTap: () => Navigator.pop(bctx, category),
            );
          },
        ),
      ),
    );

    if (selected != null) {
      setState(() {
        _selectedCategoryId = selected.id;
        _selectedCategoryName = selected.name;
        _selectedCategoryIcon = selected.icon;
      });
    }
  }

  Future<void> _saveBudget() async {
    final l10n = AppLocalizations.of(context);
    final amountText = _amountController.text.trim();

    if (amountText.isEmpty) {
      showToast(context, l10n.budgetAmountHint);
      return;
    }

    final amount = double.tryParse(amountText);
    if (amount == null || amount <= 0) {
      showToast(context, l10n.budgetAmountHint);
      return;
    }

    if (_type == 'category' && _selectedCategoryId == null) {
      showToast(context, l10n.budgetCategoryHint);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final repo = ref.read(repositoryProvider);
      final ledgerId = ref.read(currentLedgerIdProvider);

      if (_isEditing) {
        await repo.updateBudget(
          widget.budget!.id,
          amount: amount,
          startDay: _startDay,
        );
      } else {
        await repo.createBudget(
          ledgerId: ledgerId,
          type: _type,
          categoryId: _selectedCategoryId,
          amount: amount,
          startDay: _startDay,
        );
      }

      // 刷新预算数据
      ref.read(budgetRefreshProvider.notifier).state++;

      // 触发一次 sync:预算变更走 changeTracker 已经记在表里了,但
      // PostProcessor.sync 只在 tx 写入时才调。如果用户只改预算不加交易,
      // 那条 change 会压在本地没 push 出去 → B 端 / web 看不到。这里手动
      // 推一下,不阻塞 UI。
      unawaited(PostProcessor.sync(ref, ledgerId: ledgerId));

      if (mounted) {
        showToast(context, l10n.budgetSaveSuccess);
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        showToast(context, e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _deleteBudget() async {
    final l10n = AppLocalizations.of(context);

    // 不可恢复的实体删除 → 单次危险确认（3 秒时停，取消｜删除分栏、确认侧
    // error 色），口径见 AGENTS.md「破坏性操作确认分档」。
    final confirmed = await showDangerConfirmDialog(
      context,
      title: l10n.commonDelete,
      message: l10n.budgetDeleteConfirm,
      okLabel: l10n.commonDelete,
      countdownSeconds: 3,
    );

    if (!confirmed) return;

    try {
      final repo = ref.read(repositoryProvider);
      final ledgerId = ref.read(currentLedgerIdProvider);
      await repo.deleteBudget(widget.budget!.id);

      // 刷新预算数据
      ref.read(budgetRefreshProvider.notifier).state++;

      // 跟保存路径一样:删预算也要 flush 一次 sync,否则 B 端 / web 永远
      // 看到幽灵预算。
      unawaited(PostProcessor.sync(ref, ledgerId: ledgerId));

      if (mounted) {
        showToast(context, l10n.budgetDeleteSuccess);
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        showToast(context, e.toString());
      }
    }
  }
}
