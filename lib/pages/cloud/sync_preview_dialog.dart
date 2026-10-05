import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../cloud/sync_diff_service.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/currencies.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/ui/dialog.dart';

/// 同步预览弹窗
///
/// 展示新增/修改/删除的变更列表，支持分项勾选
/// 返回用户选中的 `List<SyncChange>` 或 null（取消）
Future<List<SyncChange>?> showSyncPreviewDialog(
  BuildContext context, {
  required SyncPreview preview,
  required Color primaryColor,
}) {
  return showDialog<List<SyncChange>>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _SyncPreviewDialog(
      preview: preview,
      primaryColor: primaryColor,
    ),
  );
}

class _SyncPreviewDialog extends ConsumerStatefulWidget {
  final SyncPreview preview;
  final Color primaryColor;

  const _SyncPreviewDialog({
    required this.preview,
    required this.primaryColor,
  });

  @override
  ConsumerState<_SyncPreviewDialog> createState() => _SyncPreviewDialogState();
}

class _SyncPreviewDialogState extends ConsumerState<_SyncPreviewDialog> {
  late List<SyncChange> changes;

  @override
  void initState() {
    super.initState();
    changes = widget.preview.changes;
  }

  int get selectedCount => changes.where((c) => c.selected).length;
  bool get allSelected => changes.every((c) => c.selected);

  void _toggleAll() {
    setState(() {
      final newValue = !allSelected;
      for (final c in changes) {
        c.selected = newValue;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final addedChanges =
        changes.where((c) => c.type == SyncChangeType.added).toList();
    final modifiedChanges =
        changes.where((c) => c.type == SyncChangeType.modified).toList();
    final deletedChanges =
        changes.where((c) => c.type == SyncChangeType.deleted).toList();

    return AppDialogShell(
      wide: true,
      title: Text(
        l10n.syncPreviewTitle,
        style: PiggyTextTokens.strongTitle(context).copyWith(fontSize: PiggyTextTokens.fs18),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 汇总行
            _buildSummaryRow(context, addedChanges.length,
                modifiedChanges.length, deletedChanges.length),
            const SizedBox(height: 8),
            // 全选/取消全选
            InkWell(
              onTap: _toggleAll,
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: allSelected,
                      onChanged: (_) => _toggleAll(),
                      activeColor: widget.primaryColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    allSelected
                        ? l10n.syncPreviewDeselectAll
                        : l10n.syncPreviewSelectAll,
                    style:
                        PiggyTextTokens.label(context).copyWith(fontSize: PiggyTextTokens.fs13),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Divider(color: PiggyTokens.divider(context), height: 1),
            const SizedBox(height: 4),
            // 变更列表
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (addedChanges.isNotEmpty) ...[
                      _buildSectionHeader(context, l10n.syncPreviewAdded,
                          PiggyTokens.success(context)),
                      ...addedChanges.map((c) => _buildChangeItem(context, c)),
                    ],
                    if (modifiedChanges.isNotEmpty) ...[
                      _buildSectionHeader(context, l10n.syncPreviewModified,
                          PiggyTokens.info(context)),
                      ...modifiedChanges
                          .map((c) => _buildChangeItem(context, c)),
                    ],
                    if (deletedChanges.isNotEmpty) ...[
                      _buildSectionHeader(context, l10n.syncPreviewDeleted,
                          PiggyTokens.error(context)),
                      ...deletedChanges
                          .map((c) => _buildChangeItem(context, c)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: selectedCount > 0
              ? () {
                  final selected = changes.where((c) => c.selected).toList();
                  Navigator.pop(context, selected);
                }
              : null,
          child: Text(
            l10n.syncPreviewApply(selectedCount),
            style: TextStyle(
              color: selectedCount > 0
                  ? widget.primaryColor
                  : PiggyTokens.textTertiary(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryRow(
      BuildContext context, int added, int modified, int deleted) {
    final l10n = AppLocalizations.of(context);
    return Wrap(
      spacing: 12,
      children: [
        if (added > 0)
          _buildBadge(context, l10n.syncPreviewAddedCount(added),
              PiggyTokens.success(context)),
        if (modified > 0)
          _buildBadge(context, l10n.syncPreviewModifiedCount(modified),
              PiggyTokens.info(context)),
        if (deleted > 0)
          _buildBadge(context, l10n.syncPreviewDeletedCount(deleted),
              PiggyTokens.error(context)),
      ],
    );
  }

  Widget _buildBadge(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: PiggyTextTokens.fs12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            title,
            style: PiggyTextTokens.label(context)
                .copyWith(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  /// 金额符号：交易自带币种优先（多币种账本里外币行本身就是外币金额），
  /// 缺失（存量行 / 单币种账本）则跟随主币种 —— 与首页月结卡同口径。
  /// 历史实现把符号写死成 '¥'，外币账本的整个变更预览都显示错的符号。
  String _amountSymbol(String? currencyCode) => getCurrencySymbol(
      (currencyCode?.isNotEmpty ?? false) ? currencyCode! : ref.read(baseCurrencyProvider));

  /// 实体种类 → 本地化标签。穷举 switch：新增 [SyncEntityKind] 时编译期
  /// 报错，避免默默漏一个种类（漏了就显示裸英文枚举名）。
  String _entityKindLabel(BuildContext context, SyncEntityKind kind) {
    final l10n = AppLocalizations.of(context);
    switch (kind) {
      case SyncEntityKind.account:
        return l10n.syncEntityKindAccount;
      case SyncEntityKind.category:
        return l10n.syncEntityKindCategory;
      case SyncEntityKind.tag:
        return l10n.syncEntityKindTag;
      case SyncEntityKind.budget:
        return l10n.syncEntityKindBudget;
      case SyncEntityKind.recurring:
        return l10n.syncEntityKindRecurring;
      case SyncEntityKind.rateOverride:
        return l10n.syncEntityKindRateOverride;
    }
  }

  Widget _buildChangeItem(BuildContext context, SyncChange change) {
    final dateFormat = DateFormat('MM-dd');
    String summary;
    String? detail;

    switch (change.type) {
      case SyncChangeType.added:
        final tx = change.cloudTransaction!;
        final prefix = tx.type == 'income' ? '+' : '-';
        summary =
            '${dateFormat.format(tx.happenedAt)} ${tx.categoryName ?? tx.type} $prefix${_amountSymbol(tx.currencyCode)}${tx.amount.toStringAsFixed(2)}';
        if (tx.note != null && tx.note!.isNotEmpty) {
          summary += ' ${tx.note}';
        }
        break;
      case SyncChangeType.modified:
        final tx = change.cloudTransaction!;
        final prefix = tx.type == 'income' ? '+' : '-';
        summary =
            '${dateFormat.format(tx.happenedAt)} ${tx.categoryName ?? tx.type} $prefix${_amountSymbol(tx.currencyCode)}${tx.amount.toStringAsFixed(2)}';
        if (change.diffDetails.isNotEmpty) {
          detail = change.diffDetails.join(', ');
        }
        break;
      case SyncChangeType.deleted:
        // 实体删除（账户/分类/标签/预算/周期规则/汇率覆盖）：对端已删、本地还在。
        // 与删除交易行走同一"删除"分区，但载荷完全不同 —— 必须先判
        // entityDelete，否则会对 null 的 localTransaction 强解包直接崩。
        final entity = change.entityDelete;
        if (entity != null) {
          final kindLabel = _entityKindLabel(context, entity.kind);
          // name 为空 = 该实体没有专属名字（总预算 / 无备注的周期规则），
          // 只显示种类标签，不留空引号。
          summary = entity.name.isEmpty
              ? kindLabel
              : AppLocalizations.of(context)
                  .syncPreviewEntityDeleted(kindLabel, entity.name);
          detail = AppLocalizations.of(context).syncPreviewEntityDeletedHint;
          break;
        }
        final tx = change.localTransaction!;
        final prefix = tx.type == 'income' ? '+' : '-';
        summary =
            '${dateFormat.format(tx.happenedAt)} ${tx.type} $prefix${_amountSymbol(tx.currencyCode)}${tx.amount.toStringAsFixed(2)}';
        if (tx.note != null && tx.note!.isNotEmpty) {
          summary += ' ${tx.note}';
        }
        break;
    }

    return InkWell(
      onTap: () {
        setState(() {
          change.selected = !change.selected;
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: change.selected,
                onChanged: (v) {
                  setState(() {
                    change.selected = v ?? false;
                  });
                },
                activeColor: widget.primaryColor,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary,
                    style: PiggyTextTokens.body(context).copyWith(fontSize: PiggyTextTokens.fs13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      style: PiggyTextTokens.caption(context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
