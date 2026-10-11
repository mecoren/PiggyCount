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

    final hasFields = definitionsAsync.value?.isNotEmpty ?? false;

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
          loading: () => Center(
            child: PiggySpinner(size: 36, color: PiggyTokens.primary(context)),
          ),
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
    // 背景 / 描边 / 圆角交给 Material（而不是外层带背景色的 DecoratedBox）：
    // ListTile 的背景与水波纹绘制在**最近的 Material** 上，套一层带背景色的
    // DecoratedBox 会把它们盖住 —— Flutter 在 debug 下抛
    // 「ListTile background color or ink splashes may be invisible」断言
    // （widget 测试里直接失败）。
    return Container(
      key: ValueKey<int>(def.id),
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: PiggyTokens.surface(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          side: BorderSide(color: PiggyTokens.border(context)),
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
              fontSize: PiggyTextTokens.fs15,
              fontWeight: FontWeight.w600,
              color: PiggyTokens.textPrimary(context),
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _typeLabel(l10n, def.fieldType),
              style: TextStyle(
                fontSize: PiggyTextTokens.fs12,
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
    // 外壳走项目统一的表单抽屉（[showPiggyFormSheet] → [PiggyFormSheet]）：
    // 悬浮卡片 + 居中标题 + 底部「取消｜保存」双等宽按钮行，卡片 chrome
    // （键盘避让 / 底部安全区 / 左右留距 / Material 圆角）由外壳统一负责。
    final saved = await showPiggyFormSheet<bool>(
      context,
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
      case CustomFieldType.singleSelect:
        return l10n.customFieldTypeSingleSelect;
      case CustomFieldType.multiSelect:
        return l10n.customFieldTypeMultiSelect;
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
      case CustomFieldType.singleSelect:
        return Icons.radio_button_checked_outlined;
      case CustomFieldType.multiSelect:
        return Icons.checklist_outlined;
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
      case CustomFieldType.singleSelect:
        return const Color(0xFF4DABF7);
      case CustomFieldType.multiSelect:
        return const Color(0xFF845EF7);
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

  /// v54 选项行：单选/多选字段的选项编辑。每行保留原始值（'' = 本次新增），
  /// 保存时据「文本被改过」判定为改名并级联更新历史已记录的值。
  late final List<_OptionRow> _optionRows;

  /// 本次编辑里被删除的**已保存**选项原文（用于保存前判定是否需要危险确认）。
  final Set<String> _removedPersisted = <String>{};

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _type = widget.existing?.fieldType ?? CustomFieldType.amount;
    final existing = widget.existing;
    _optionRows = [
      for (final o in existing == null
          ? const <String>[]
          : CustomFieldOptionsCodec.decode(existing.optionsJson))
        _OptionRow(o),
    ];
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final r in _optionRows) {
      r.dispose();
    }
    super.dispose();
  }

  void _addOption() => setState(() {
        _error = null;
        _optionRows.add(_OptionRow(''));
      });

  void _removeOption(int index) => setState(() {
        _error = null;
        final row = _optionRows.removeAt(index);
        // 仅**已保存**的选项被删才构成破坏性变更（新增行删掉无副作用）。
        if (row.original.isNotEmpty) _removedPersisted.add(row.original);
        row.dispose();
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canSubmit = _nameController.text.trim().isNotEmpty && !_submitting;

    // 外壳走项目统一的悬浮卡片表单抽屉（[PiggyFormSheet]）：居中标题 →
    // p16 → 字段 → p20 → 「取消｜保存」。间距全部取 [PiggyDimens] 令牌，
    // 不再自绘全宽平底弹层 + 顶部小把手（旧样式顶部贴边、字段挤在一起）。
    return PiggyFormSheet(
      title: _isEditing ? l10n.customFieldEditTitle : l10n.customFieldAddTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
      onCancel: () => Navigator.of(context).pop(false),
      onConfirm: canSubmit ? _submit : null,
      confirmBusy: _submitting,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label(l10n.customFieldNameLabel),
          const SizedBox(height: PiggyDimens.p8),
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
          const SizedBox(height: PiggyDimens.p16),
          _label(l10n.customFieldTypeLabel),
          const SizedBox(height: PiggyDimens.p8),
          _buildTypeSelector(l10n),
          // v54 选项编辑区（仅单选/多选类型展开）。
          if (CustomFieldType.hasOptions(_type)) ...[
            const SizedBox(height: PiggyDimens.p16),
            _label(l10n.customFieldOptionsLabel),
            const SizedBox(height: PiggyDimens.p8),
            for (var i = 0; i < _optionRows.length; i++)
              _buildOptionRow(i, l10n),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _submitting ? null : _addOption,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.customFieldAddOption),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 单个选项行：文本输入 + 删除。删除仅把该行移出本列表（历史已记录值
  /// 作为「游离值」保留，不静默清空）。
  Widget _buildOptionRow(int index, AppLocalizations l10n) {
    final row = _optionRows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: PiggyDimens.p8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: row.controller,
              enabled: !_submitting,
              maxLength: 30,
              decoration: piggyOutlinedDecoration(
                context,
                hint: l10n.customFieldOptionHint,
              ).copyWith(counterText: ''),
              onChanged: (_) => setState(() => _error = null),
            ),
          ),
          const SizedBox(width: PiggyDimens.p4),
          IconButton(
            onPressed: _submitting ? null : () => _removeOption(index),
            icon: Icon(
              Icons.remove_circle_outline,
              color: PiggyTokens.textTertiary(context),
            ),
            tooltip: l10n.commonDelete,
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Text(
        text,
        style: PiggyTextTokens.label(context).copyWith(
          fontWeight: FontWeight.w500,
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
      (
        value: CustomFieldType.singleSelect,
        label: l10n.customFieldTypeSingleSelect,
        icon: Icons.radio_button_checked_outlined
      ),
      (
        value: CustomFieldType.multiSelect,
        label: l10n.customFieldTypeMultiSelect,
        icon: Icons.checklist_outlined
      ),
    ];

    // 5 项一行放不下（每项含图标 + 文字）→ 3 列网格自动换行（3 + 2）。
    return LayoutBuilder(
      builder: (context, constraints) {
        const cols = 3;
        const gap = 8.0;
        final itemWidth = (constraints.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final opt in options)
              SizedBox(
                width: itemWidth,
                child: GestureDetector(
                  onTap: _submitting
                      ? null
                      : () => setState(() {
                            _type = opt.value;
                            // 切到选择类型且尚无选项行 → 先给一行空输入。
                            if (CustomFieldType.hasOptions(opt.value) &&
                                _optionRows.isEmpty) {
                              _optionRows.add(_OptionRow(''));
                            }
                          }),
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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: PiggyTextTokens.fs12,
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
          ],
        );
      },
    );
  }

  /// 保存前的破坏性变更判定 + 双重危险确认。
  ///
  /// 返回 false = 用户取消（抽屉保持打开，不做任何落库）。判定三类破坏性变更：
  /// ① **改字段类型**（既有字段）—— 会清空选项、历史值按新类型解读；
  /// ② **删除已保存的选项**（抽屉垃圾桶）；
  /// ③ **把选项文本清空**（保存时被剔空，等同于删除）。
  /// 新建字段无既有数据，一律不弹。
  Future<bool> _confirmDestructiveChange(AppLocalizations l10n) async {
    final existing = widget.existing;
    final hazard = detectCustomFieldEditHazard(
      isEditing: existing != null,
      originalType: existing?.fieldType ?? _type,
      newType: _type,
      removedPersistedOptions: _removedPersisted,
      clearedPersistedOptions: [
        for (final r in _optionRows)
          if (r.original.isNotEmpty && r.controller.text.trim().isEmpty)
            r.original,
      ],
    );

    // ① 改类型：影响该字段全部历史值的解读口径 + 清空选项，优先提示。
    if (hazard.typeChanged) {
      return showDoubleDangerConfirmDialog(
        context,
        title: l10n.customFieldTypeChangeConfirmTitle,
        firstMessage: l10n.customFieldTypeChangeConfirmMessage(
          existing!.name,
          _CustomFieldManagePageState._typeLabel(l10n, existing.fieldType),
          _CustomFieldManagePageState._typeLabel(l10n, _type),
        ),
        secondMessage: l10n.customFieldTypeChangeReconfirmMessage,
        countdownSeconds: 3,
      );
    }

    // ② / ③ 删除或清空已保存的选项：历史值会保留为游离值。
    if (hazard.removedOptions.isEmpty) return true;
    return showDoubleDangerConfirmDialog(
      context,
      title: l10n.customFieldOptionDeleteConfirmTitle,
      firstMessage: l10n.customFieldOptionDeleteConfirmMessage(
          hazard.removedOptions.join('、')),
      secondMessage: l10n.customFieldOptionDeleteReconfirmMessage,
      countdownSeconds: 3,
    );
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.customFieldNameRequired);
      return;
    }

    // v54 选项校验与收集：选择类型至少 1 项、不重复（保序）；其余类型清空。
    final List<String> options;
    if (CustomFieldType.hasOptions(_type)) {
      final vals = [
        for (final r in _optionRows) r.controller.text.trim(),
      ].where((v) => v.isNotEmpty).toList();
      if (vals.isEmpty) {
        setState(() => _error = l10n.customFieldOptionRequired);
        return;
      }
      if (vals.toSet().length != vals.length) {
        setState(() => _error = l10n.customFieldOptionDuplicate);
        return;
      }
      options = vals;
    } else {
      options = const [];
    }

    // 破坏性修改需**双重危险确认**（否则用户点一下保存就改了、没有感知）：
    // 改字段类型会清空选项并让历史值按新类型解读；删除/清空已保存的选项会让
    // 历史值变游离值。纯改名 / 新增选项 / 排序不弹（纯编辑语义）。
    if (!await _confirmDestructiveChange(l10n)) return;
    if (!mounted) return;

    setState(() {
      _submitting = true;
      _error = null;
    });

    final repo = ref.read(repositoryProvider);
    try {
      if (_isEditing) {
        final existing = widget.existing!;
        await repo.updateDefinition(
          existing.id,
          name: name,
          fieldType: _type,
          options: options,
        );
        // 选项改名 → 级联更新历史已记录的值（仅选择类型；新增/删除行不动）。
        final fieldSyncId = existing.syncId;
        if (CustomFieldType.hasOptions(_type) &&
            fieldSyncId != null &&
            fieldSyncId.isNotEmpty) {
          for (final row in _optionRows) {
            final from = row.original;
            final to = row.controller.text.trim();
            if (from.isEmpty || to.isEmpty || from == to) continue;
            await repo.renameOptionValue(
              ledgerId: existing.ledgerId,
              fieldSyncId: fieldSyncId,
              oldValue: from,
              newValue: to,
            );
          }
        }
      } else {
        final ledgerId = ref.read(currentLedgerIdProvider);
        final existing = await repo.getDefinitionsForLedger(ledgerId);
        await repo.createDefinition(
          ledgerId: ledgerId,
          name: name,
          fieldType: _type,
          sortOrder: existing.length,
          options: options,
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

/// v54 选项编辑行：一个可编辑文本框 + 原始值（保存时判改名）。
class _OptionRow {
  _OptionRow(this.original) : controller = TextEditingController(text: original);

  /// 编辑开始时的选项文本（'' = 本次新增，不参与改名级联）。
  final String original;
  final TextEditingController controller;

  void dispose() => controller.dispose();
}

/// 判定自定义字段编辑抽屉里的**破坏性变更**（纯函数，便于单测）。
///
/// 破坏性 = 点「保存」会让用户**没有感知**地丢配置 / 改历史值语义，需要双重危险确认：
/// - **改字段类型**（[newType] != [originalType]）：会清空选项，历史值按新类型解读，
///   优先级最高；
/// - **删除或清空已保存的选项**（[removedPersistedOptions] / [clearedPersistedOptions]
///   非空）：历史值会保留为游离值。
///
/// **不命中**：新建字段（[isEditing] == false，无既有数据）、纯改名、新增选项、排序。
({bool typeChanged, List<String> removedOptions}) detectCustomFieldEditHazard({
  required bool isEditing,
  required String originalType,
  required String newType,
  required Iterable<String> removedPersistedOptions,
  required Iterable<String> clearedPersistedOptions,
}) {
  if (!isEditing) return (typeChanged: false, removedOptions: const []);
  if (newType != originalType) {
    return (typeChanged: true, removedOptions: const []);
  }
  return (
    typeChanged: false,
    removedOptions: <String>{
      ...removedPersistedOptions,
      ...clearedPersistedOptions,
    }.toList(),
  );
}
