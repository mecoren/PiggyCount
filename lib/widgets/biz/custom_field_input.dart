import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/db.dart';
import '../../data/models/custom_field_values.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import '../ui/wheel_date_picker.dart';

/// v46 交易编辑器里的「自定义字段」录入分区。
///
/// 调用方（[AmountEditorSheet]）在定义为空时整块不渲染，本组件自身也做一次
/// 空判断以防御误用。输入控件按 fieldType 自适应：
/// - amount：数字键盘（仅收数字与小数点；非法串视为未填）
/// - text：普通文本，限长 100
/// - date：点击唤起项目滚轮日期选择器，右侧提供清除按钮
///
/// 值以 `{ fieldSyncId: value }` 经 [onChanged] 上抛；父级在提交时交给仓储层，
/// 由 [CustomFieldValueCodec] 统一编码落库。
class CustomFieldsSection extends StatefulWidget {
  /// 当前账本的字段定义（已按 sortOrder 排好）。
  final List<CustomFieldDefinition> definitions;

  /// 编辑既有交易时的已存值（键为 fieldSyncId）。
  final Map<String, dynamic> initialValues;

  /// 任一字段值变化时上抛全量值（父级持有提交用的最新快照）。
  final ValueChanged<Map<String, dynamic>> onChanged;

  /// v47：金额字段是否交给宿主页的**自定义数字键盘**输入。
  ///
  /// 金额表单（[AmountEditorSheet]）底部本来就有一套自制数字键盘，而
  /// [TextField] 一点就弹系统键盘 —— 两套键盘同时抢输入，且金额位的样式
  /// 也与上方的记账金额/原始金额位不一致。这三个参数是**一组**，宿主全传：
  /// - [onAmountFieldTapped]：点金额位 → 把键盘输入目标切到该字段；
  /// - [activeAmountSyncId]：当前接收输入的字段（选中态描边）；
  /// - [amountTextOverride]：金额位的显示串由宿主维护（空串 = 未填写）。
  ///
  /// 不传（模板编辑页等没有自制键盘的调用方）→ 金额字段保持 TextField 原行为。
  final ValueChanged<String>? onAmountFieldTapped;
  final String? activeAmountSyncId;
  final Map<String, String>? amountTextOverride;

  /// 字段名列宽。宿主传「原始金额」行的图标 + 标签宽度，好让金额输入位的
  /// 左边界与原始金额位对齐；默认 84 是模板编辑页等旧调用方的原值。
  final double labelWidth;

  const CustomFieldsSection({
    super.key,
    required this.definitions,
    required this.initialValues,
    required this.onChanged,
    this.onAmountFieldTapped,
    this.activeAmountSyncId,
    this.amountTextOverride,
    this.labelWidth = 84,
  });

  @override
  State<CustomFieldsSection> createState() => _CustomFieldsSectionState();
}

class _CustomFieldsSectionState extends State<CustomFieldsSection> {
  /// fieldSyncId → controller。controller 必须跨 rebuild 复用，否则每帧重建
  /// 会丢光标与输入法状态。
  final Map<String, TextEditingController> _controllers = {};

  /// 本地值快照（含日期，日期不走 controller）。
  late Map<String, dynamic> _values;

  @override
  void initState() {
    super.initState();
    _values = Map<String, dynamic>.from(
        CustomFieldValueCodec.normalize(widget.initialValues));
    _ensureControllers();
  }

  @override
  void didUpdateWidget(covariant CustomFieldsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureControllers();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _ensureControllers() {
    for (final def in widget.definitions) {
      final syncId = def.syncId;
      if (syncId == null || syncId.isEmpty) continue;
      _controllers.putIfAbsent(
        syncId,
        () => TextEditingController(
          text: CustomFieldValueCodec.toDisplayString(_values[syncId]) ?? '',
        ),
      );
    }
  }

  void _setValue(String fieldSyncId, dynamic value) {
    setState(() {
      if (value == null || (value is String && value.trim().isEmpty)) {
        _values.remove(fieldSyncId);
      } else {
        _values[fieldSyncId] = value;
      }
    });
    widget.onChanged(Map<String, dynamic>.from(_values));
  }

  @override
  Widget build(BuildContext context) {
    final definitions = widget.definitions
        .where((d) => (d.syncId ?? '').isNotEmpty)
        .toList(growable: false);
    if (definitions.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
          child: Row(
            children: [
              Icon(
                Icons.playlist_add_outlined,
                size: 15,
                color: PiggyTokens.textTertiary(context),
              ),
              const SizedBox(width: 6),
              Text(
                l10n.customFieldSectionTitle,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: PiggyTokens.textTertiary(context),
                ),
              ),
            ],
          ),
        ),
        // 录入位：字段多时在本分区内滚动，而不是把下方的数字键盘顶出屏幕。
        // 上限 156dp ≈ 3 行录入位；字段少（常态 1~3 个）时不产生滚动条。
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 156),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final def in definitions) _buildRow(def, l10n),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(CustomFieldDefinition def, AppLocalizations l10n) {
    final syncId = def.syncId!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: widget.labelWidth,
            child: Text(
              def.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: PiggyTokens.textSecondary(context),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: _buildInput(def, syncId, l10n)),
        ],
      ),
    );
  }

  Widget _buildInput(
      CustomFieldDefinition def, String syncId, AppLocalizations l10n) {
    switch (def.fieldType) {
      case CustomFieldType.date:
        return _buildDateInput(syncId, l10n);
      case CustomFieldType.amount:
        // 宿主接管（记账金额表单）→ 与「原始金额」位同款的只读输入位；
        // 其余调用方（模板编辑页）仍是能弹系统键盘的 TextField。
        if (widget.onAmountFieldTapped != null &&
            widget.amountTextOverride != null) {
          return _buildAmountKeyboardInput(syncId, l10n);
        }
        return _buildTextInput(
          syncId,
          hint: l10n.customFieldAmountHint,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          parse: (text) =>
              CustomFieldValueCodec.fromInput(CustomFieldType.amount, text),
        );
      case CustomFieldType.text:
      default:
        return _buildTextInput(
          syncId,
          hint: l10n.customFieldTextHint,
          parse: (text) => text.trim().isEmpty ? null : text.trim(),
        );
    }
  }

  Widget _buildTextInput(
    String syncId, {
    required String hint,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    required dynamic Function(String text) parse,
  }) {
    final controller = _controllers.putIfAbsent(
      syncId,
      () => TextEditingController(
        text: CustomFieldValueCodec.toDisplayString(_values[syncId]) ?? '',
      ),
    );
    return SizedBox(
      height: 40,
      child: TextField(
        // 供测试与调试精确定位（表单里还有备注等其它 TextField）。
        key: ValueKey('custom_field_input_$syncId'),
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        maxLength: 100,
        style: TextStyle(
          fontSize: 14,
          color: PiggyTokens.textPrimary(context),
        ),
        decoration: InputDecoration(
          hintText: hint,
          counterText: '',
          isDense: true,
          filled: true,
          fillColor: PiggyTokens.surface(context),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
            borderSide: BorderSide(color: PiggyTokens.border(context)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
            borderSide: BorderSide(color: PiggyTokens.border(context)),
          ),
        ),
        onChanged: (text) => _setValue(syncId, parse(text)),
      ),
    );
  }

  /// 金额位的「宿主键盘」形态：与记账表单里「原始金额」位逐像素同款
  /// （填充底 + radiusLg 圆角 + 选中态主色描边 + 高 40），点击只切键盘目标，
  /// 自身不挂 TextField —— 否则系统键盘会与下方自制数字键盘并存。
  Widget _buildAmountKeyboardInput(String syncId, AppLocalizations l10n) {
    final active = widget.activeAmountSyncId == syncId;
    final primary = Theme.of(context).colorScheme.primary;
    final theme = Theme.of(context).textTheme;
    // 显示串由宿主维护（键盘输入中含未完成的小数点，不能用 double 回显）；
    // 未接入时回退到已存值。
    final value = widget.amountTextOverride?[syncId] ??
        CustomFieldValueCodec.toDisplayString(_values[syncId]) ??
        '';
    final isEmpty = value.isEmpty;

    return GestureDetector(
      key: ValueKey('custom_field_input_$syncId'),
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onAmountFieldTapped!(syncId),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 40,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: PiggyTokens.surfaceInput(context),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          border: Border.all(
            width: 1.5,
            color: active ? primary : Colors.transparent,
          ),
        ),
        child: Text(
          isEmpty ? l10n.customFieldAmountHint : value,
          key: ValueKey('custom_field_amount_value_$syncId'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: isEmpty
              ? theme.labelSmall?.copyWith(
                  color: PiggyTokens.textTertiary(context))
              : theme.bodyMedium?.copyWith(
                  color: PiggyTokens.textPrimary(context),
                  fontWeight: FontWeight.w600,
                ),
        ),
      ),
    );
  }

  Widget _buildDateInput(String syncId, AppLocalizations l10n) {
    final raw = _values[syncId];
    final date = raw is String ? DateTime.tryParse(raw) : null;
    return InkWell(
      key: ValueKey('custom_field_date_$syncId'),
      borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
      onTap: () async {
        final picked = await showWheelDatePicker(
          context,
          initial: date ?? DateTime.now(),
        );
        if (picked == null) return;
        _setValue(
          syncId,
          DateTime(picked.year, picked.month, picked.day).toIso8601String(),
        );
      },
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: PiggyTokens.surface(context),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
          border: Border.all(color: PiggyTokens.border(context)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                date == null ? l10n.customFieldDatePick : _formatDate(date),
                style: TextStyle(
                  fontSize: 14,
                  color: date == null
                      ? PiggyTokens.textTertiary(context)
                      : PiggyTokens.textPrimary(context),
                ),
              ),
            ),
            if (date != null)
              GestureDetector(
                onTap: () => _setValue(syncId, null),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: PiggyTokens.textTertiary(context),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
