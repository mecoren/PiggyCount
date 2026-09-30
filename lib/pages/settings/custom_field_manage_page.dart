import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../data/models/custom_field_values.dart';
import '../../data/repositories/exceptions.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/custom_field_providers.dart';
import '../../providers/database_providers.dart';
import '../../services/billing/post_processor.dart';
import '../../styles/tokens.dart';
import '../../widgets/biz/app_empty.dart';
import '../../widgets/ui/ui.dart';

/// v46 自定义字段管理页（按账本）。
///
/// 增删改字段定义 + 拖拽排序。定义按账本隔离，页头副标题与空态文案都强调
/// 「本账本」以免用户误以为全局生效。
class CustomFieldManagePage extends ConsumerStatefulWidget {
  const CustomFieldManagePage({super.key});

  @override
  ConsumerState<CustomFieldManagePage> createState() =>
      _CustomFieldManagePageState();
}

class _CustomFieldManagePageState extends ConsumerState<CustomFieldManagePage> {
  /// 拖拽进行中的本地顺序（乐观更新）。
  ///
  /// 定义流来自 Drift，写库到 re-emit 之间有一个异步窗口；不挂本地覆盖的话
  /// 手指抬起后会先闪回旧顺序。落库完成 / 下一次流更新即清空。
  List<CustomFieldDefinition>? _pendingOrder;

  /// 增删改进行中：防连点（参照 tag 管理页 U15 的处理）。
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final definitionsAsync = ref.watch(customFieldDefinitionsProvider(ledgerId));

    final hasFields = definitionsAsync.valueOrNull?.isNotEmpty ?? false;

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.customFieldManageTitle,
        subtitle: l10n.customFieldManageSubtitle,
        showBack: true,
      ),
      floatingActionButton: hasFields
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : () => _openEditor(null),
              icon: const Icon(Icons.add),
              label: Text(l10n.customFieldAdd),
            )
          : null,
      body: Padding(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 80,
        ),
        child: definitionsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Text('${l10n.commonError}: $error'),
          ),
          data: (definitions) {
            if (definitions.isEmpty) {
              return AppEmpty(
                text: l10n.customFieldManageEmpty,
                subtext: l10n.customFieldManageEmptyHint,
                icon: Icons.playlist_add,
                action: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _openEditor(null),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.customFieldAdd),
                ),
              );
            }
            final ordered = _pendingOrder ?? definitions;
            return _buildList(ordered, l10n);
          },
        ),
      ),
    );
  }

  Widget _buildList(List<CustomFieldDefinition> definitions, AppLocalizations l10n) {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: definitions.length,
      // 排序提示：长按拖动手感不直观，给一行常驻说明（E2：接线在途键）。
      header: Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6, top: 2),
        child: Row(
          children: [
            Icon(Icons.drag_handle,
                size: 14, color: PiggyTokens.textTertiary(context)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(l10n.customFieldSortHint,
                  style: PiggyTextTokens.caption(context)
                      .copyWith(color: PiggyTokens.textTertiary(context))),
            ),
          ],
        ),
      ),
      // onReorderItem（Flutter 3.41+）：newIndex 已按「移除旧项后」校正过，
      // 调用方不必再自己 -1（旧 onReorder API 的经典 off-by-one 来源）。
      onReorderItem: (oldIndex, newIndex) =>
          _onReorder(definitions, oldIndex, newIndex),
      itemBuilder: (context, index) {
        final def = definitions[index];
        return _buildTile(def, index, l10n);
      },
    );
  }

  Widget _buildTile(
      CustomFieldDefinition def, int index, AppLocalizations l10n) {
    final typeColor = _typeColor(context, def.fieldType);
    return Container(
      key: ValueKey<int>(def.id),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: PiggyTokens.surface(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        border: Border.all(color: PiggyTokens.border(context)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        onTap: _busy ? null : () => _openEditor(def),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: typeColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusMd),
          ),
          alignment: Alignment.center,
          child: Icon(_typeIcon(def.fieldType), color: typeColor, size: 20),
        ),
        title: Text(
          def.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: PiggyTokens.textPrimary(context),
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            _typeLabel(l10n, def.fieldType),
            style: TextStyle(
              fontSize: 12,
              color: typeColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: _busy ? null : () => _delete(def, l10n),
              icon: Icon(
                Icons.delete_outline,
                color: PiggyTokens.textTertiary(context),
              ),
              tooltip: l10n.commonDelete,
            ),
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, left: 2),
                child: Icon(
                  Icons.drag_handle,
                  color: PiggyTokens.textTertiary(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------
  // 交互
  // ---------------------------------------------------------------

  Future<void> _onReorder(List<CustomFieldDefinition> definitions,
      int oldIndex, int newIndex) async {
    if (newIndex == oldIndex) return;
    final reordered = [...definitions];
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);

    setState(() => _pendingOrder = reordered);
    try {
      // 以 index 作为 sortOrder（0,1,2…）：字段数量个位数，重排即全量重写，
      // 语义最直观且不会因间隔值耗尽而需要重排压缩。
      await ref.read(repositoryProvider).updateDefinitionSortOrders([
        for (var i = 0; i < reordered.length; i++)
          (id: reordered[i].id, sortOrder: i),
      ]);
      ref.read(customFieldListRefreshProvider.notifier).state++;
      _triggerSync();
    } catch (e) {
      if (mounted) showToast(context, '${AppLocalizations.of(context).commonFailed}: $e');
    } finally {
      if (mounted) setState(() => _pendingOrder = null);
    }
  }

  Future<void> _openEditor(CustomFieldDefinition? existing) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CustomFieldEditSheet(existing: existing),
    );
    if (saved == true && mounted) {
      // E2：接线在途键 —— 建与改的成功提示区分（删除已有专用文案）。
      showToast(
        context,
        existing == null
            ? AppLocalizations.of(context).customFieldCreateSuccess
            : AppLocalizations.of(context).customFieldUpdateSuccess,
      );
      ref.read(customFieldListRefreshProvider.notifier).state++;
      _triggerSync();
    }
  }

  Future<void> _delete(CustomFieldDefinition def, AppLocalizations l10n) async {
    // 双重危险确认（各 3 秒倒计时）：删定义会连带清除本账本已记录的字段值，
    // 不可恢复，故与「清理未使用标签」同规格（tag_manage_page）。
    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: l10n.customFieldDeleteConfirmTitle,
      firstMessage: l10n.customFieldDeleteConfirmMessage(def.name),
      secondMessage: l10n.customFieldDeleteReconfirmMessage,
      countdownSeconds: 3,
    );
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).deleteDefinition(def.id);
      ref.read(customFieldListRefreshProvider.notifier).state++;
      _triggerSync();
      if (mounted) showToast(context, l10n.customFieldDeleteSuccess);
    } catch (e) {
      if (mounted) {
        showToast(context, '${l10n.commonFailed}: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 后台触发一次同步，把定义变更推到云端。
  ///
  /// 定义是 ledger-scoped 变更，必须借一个具体账本才推得出去（同 tag 编辑页
  /// 的做法）。不 await：不阻塞交互。
  void _triggerSync() {
    final ledgerId = ref.read(currentLedgerIdProvider);
    if (ledgerId > 0) {
      unawaited(PostProcessor.sync(ref, ledgerId: ledgerId));
    }
  }

  // ---------------------------------------------------------------
  // 类型展示辅助
  // ---------------------------------------------------------------

  static String _typeLabel(AppLocalizations l10n, String type) {
    switch (type) {
      case CustomFieldType.amount:
        return l10n.customFieldTypeAmount;
      case CustomFieldType.date:
        return l10n.customFieldTypeDate;
      case CustomFieldType.text:
      default:
        return l10n.customFieldTypeText;
    }
  }

  static IconData _typeIcon(String type) {
    switch (type) {
      case CustomFieldType.amount:
        return Icons.payments_outlined;
      case CustomFieldType.date:
        return Icons.event_outlined;
      case CustomFieldType.text:
      default:
        return Icons.notes_outlined;
    }
  }

  static Color _typeColor(BuildContext context, String type) {
    switch (type) {
      case CustomFieldType.amount:
        return PiggyTokens.primary(context);
      case CustomFieldType.date:
        return const Color(0xFFFF9F43);
      case CustomFieldType.text:
      default:
        return const Color(0xFF51CF66);
    }
  }
}

/// 新增 / 编辑字段的底部弹窗。
class _CustomFieldEditSheet extends ConsumerStatefulWidget {
  final CustomFieldDefinition? existing;

  const _CustomFieldEditSheet({this.existing});

  @override
  ConsumerState<_CustomFieldEditSheet> createState() =>
      _CustomFieldEditSheetState();
}

class _CustomFieldEditSheetState extends ConsumerState<_CustomFieldEditSheet> {
  late final TextEditingController _nameController;
  late String _type;
  bool _submitting = false;
  String? _error;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _type = widget.existing?.fieldType ?? CustomFieldType.amount;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canSubmit = _nameController.text.trim().isNotEmpty && !_submitting;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: PiggyTokens.surface(context),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(PiggyDimens.radius2xl),
          ),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          20 + MediaQuery.of(context).padding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: PiggyTokens.divider(context),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _isEditing ? l10n.customFieldEditTitle : l10n.customFieldAddTitle,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: PiggyTokens.textPrimary(context),
              ),
            ),
            const SizedBox(height: 18),
            _label(l10n.customFieldNameLabel),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              autofocus: true,
              maxLength: 20,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => canSubmit ? _submit() : null,
              decoration: piggyOutlinedDecoration(
                context,
                hint: l10n.customFieldNameHint,
                errorText: _error,
              ).copyWith(counterText: ''),
            ),
            const SizedBox(height: 16),
            _label(l10n.customFieldTypeLabel),
            const SizedBox(height: 8),
            _buildTypeSelector(l10n),
            const SizedBox(height: 20),
            // 底部操作：双等宽大按钮（取消描边 + 保存填充，全站统一口径）。
            PiggySheetActions(
              cancelLabel: l10n.commonCancel,
              confirmLabel: l10n.commonSave,
              onCancel: () => Navigator.of(context).pop(false),
              onConfirm: canSubmit ? _submit : null,
              confirmBusy: _submitting,
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: PiggyTokens.textSecondary(context),
        ),
      );

  /// 类型分段控件：三个等宽按钮，选中项用主色填充。
  ///
  /// 不用 Material 的 SegmentedButton 是为了与项目既有圆角/配色一致，且避免
  /// 主题差异带来的视觉跳变。
  Widget _buildTypeSelector(AppLocalizations l10n) {
    final primary = PiggyTokens.primary(context);
    final options = <({String value, String label, IconData icon})>[
      (
        value: CustomFieldType.amount,
        label: l10n.customFieldTypeAmount,
        icon: Icons.payments_outlined
      ),
      (
        value: CustomFieldType.text,
        label: l10n.customFieldTypeText,
        icon: Icons.notes_outlined
      ),
      (
        value: CustomFieldType.date,
        label: l10n.customFieldTypeDate,
        icon: Icons.event_outlined
      ),
    ];

    return Row(
      children: [
        for (final opt in options)
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: opt.value == CustomFieldType.date ? 0 : 8,
              ),
              child: GestureDetector(
                onTap: _submitting
                    ? null
                    : () => setState(() => _type = opt.value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: _type == opt.value
                        ? primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                    border: Border.all(
                      color: _type == opt.value
                          ? primary
                          : PiggyTokens.border(context),
                      width: _type == opt.value ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        opt.icon,
                        size: 18,
                        color: _type == opt.value
                            ? primary
                            : PiggyTokens.textTertiary(context),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        opt.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _type == opt.value
                              ? primary
                              : PiggyTokens.textSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.customFieldNameRequired);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final repo = ref.read(repositoryProvider);
    try {
      if (_isEditing) {
        await repo.updateDefinition(
          widget.existing!.id,
          name: name,
          fieldType: _type,
        );
      } else {
        final ledgerId = ref.read(currentLedgerIdProvider);
        final existing = await repo.getDefinitionsForLedger(ledgerId);
        await repo.createDefinition(
          ledgerId: ledgerId,
          name: name,
          fieldType: _type,
          sortOrder: existing.length,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on DuplicateNameException {
      // 仓储层是权威校验（并发下 UI 预检可能过期），这里把它翻成文案。
      if (mounted) setState(() => _error = l10n.customFieldNameDuplicate);
    } catch (e) {
      if (mounted) {
        setState(() => _error = '${l10n.commonError}: $e');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
