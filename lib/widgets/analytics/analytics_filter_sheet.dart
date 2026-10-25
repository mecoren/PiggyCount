import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../data/models/analytics_transaction_filter.dart';
import '../../data/models/custom_field_values.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/custom_field_providers.dart';
import '../../styles/tokens.dart';
import '../../utils/transaction_search_filter.dart';
import '../ui/ui.dart';

/// 洞察附加筛选抽屉（交易类型 + 文本 / 单选 / 多选自定义字段）。
Future<AnalyticsTransactionFilter?> showAnalyticsFilterSheet(
  BuildContext context, {
  required AnalyticsTransactionFilter initial,
}) {
  return showPiggyFormSheet<AnalyticsTransactionFilter>(
    context,
    builder: (_) => _AnalyticsFilterSheet(initial: initial),
  );
}

class _AnalyticsFilterSheet extends ConsumerStatefulWidget {
  const _AnalyticsFilterSheet({required this.initial});

  final AnalyticsTransactionFilter initial;

  @override
  ConsumerState<_AnalyticsFilterSheet> createState() =>
      _AnalyticsFilterSheetState();
}

class _AnalyticsFilterSheetState extends ConsumerState<_AnalyticsFilterSheet> {
  late Set<String> _types;
  late Map<String, String> _textValues;
  late Map<String, Set<String>> _selectValues;
  final Map<String, TextEditingController> _textControllers = {};

  @override
  void initState() {
    super.initState();
    _types = {...widget.initial.types};
    _textValues = {};
    _selectValues = {};
    for (final c in widget.initial.customFieldConditions) {
      switch (c) {
        case CustomFieldConditionContains(:final fieldSyncId, :final value):
          _textValues[fieldSyncId] = value;
          _textControllers[fieldSyncId] = TextEditingController(text: value);
        case CustomFieldConditionEq(:final fieldSyncId, :final value):
          _selectValues[fieldSyncId] = {value};
        case CustomFieldConditionAnyOf(:final fieldSyncId, :final values):
          _selectValues[fieldSyncId] = {...values};
        case CustomFieldConditionBetween():
          break;
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _textController(String syncId) =>
      _textControllers.putIfAbsent(syncId, TextEditingController.new);

  void _toggleType(String type) {
    setState(() {
      if (!_types.remove(type)) _types.add(type);
    });
  }

  void _clearAll() {
    setState(() {
      _types = {};
      _textValues = {};
      _selectValues = {};
      for (final controller in _textControllers.values) {
        controller.clear();
      }
    });
  }

  AnalyticsTransactionFilter _collect(List<CustomFieldDefinition> defs) {
    final conditions = <CustomFieldCondition>[];
    for (final d in defs) {
      final sid = d.syncId;
      if (sid == null || sid.isEmpty) continue;
      switch (d.fieldType) {
        case CustomFieldType.text:
          final value = _textValues[sid]?.trim() ?? '';
          if (value.isNotEmpty) {
            conditions.add(CustomFieldCondition.contains(
              fieldSyncId: sid,
              fieldName: d.name,
              fieldType: d.fieldType,
              value: value,
            ));
          }
        case CustomFieldType.singleSelect:
          final values = _selectValues[sid];
          if (values != null && values.isNotEmpty) {
            conditions.add(CustomFieldCondition.eq(
              fieldSyncId: sid,
              fieldName: d.name,
              fieldType: d.fieldType,
              value: values.first,
            ));
          }
        case CustomFieldType.multiSelect:
          final values = _selectValues[sid];
          if (values != null && values.isNotEmpty) {
            conditions.add(CustomFieldCondition.anyOf(
              fieldSyncId: sid,
              fieldName: d.name,
              fieldType: d.fieldType,
              values: values,
            ));
          }
        case CustomFieldType.amount:
        case CustomFieldType.date:
          break;
      }
    }
    return AnalyticsTransactionFilter(
      types: _types,
      customFieldConditions: conditions,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fields = ref.watch(customFieldsForCurrentLedgerProvider).value ??
        const <CustomFieldDefinition>[];
    final filterFields = [
      for (final d in fields)
        if (d.syncId != null &&
            d.syncId!.isNotEmpty &&
            (d.fieldType == CustomFieldType.text ||
                d.fieldType == CustomFieldType.singleSelect ||
                d.fieldType == CustomFieldType.multiSelect))
          d,
    ];

    return PiggyFormSheet(
      title: l10n.analyticsFilterTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonConfirm,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: () => Navigator.of(context).pop(_collect(fields)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _clearAll,
              style: TextButton.styleFrom(
                foregroundColor: PiggyTokens.textSecondary(context),
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: PiggyDimens.p8,
                  vertical: PiggyDimens.p8,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(l10n.searchClearFilter),
            ),
          ),
          PiggySectionLabel(l10n.analyticsFilterTypes),
          const SizedBox(height: PiggyDimens.p8),
          Wrap(
            spacing: PiggyDimens.p8,
            runSpacing: PiggyDimens.p8,
            children: [
              for (final entry in [
                (value: 'expense', label: l10n.homeExpense),
                (value: 'income', label: l10n.homeIncome),
                (value: 'transfer', label: l10n.transferTitle),
              ])
                PiggySelectChip(
                  key: ValueKey('analyticsFilterType_${entry.value}'),
                  label: entry.label,
                  selected: _types.contains(entry.value),
                  onTap: () => _toggleType(entry.value),
                ),
            ],
          ),
          if (filterFields.isNotEmpty) ...[
            const SizedBox(height: PiggyDimens.p20),
            PiggySectionLabel(l10n.analyticsFilterCustomFields),
            for (final field in filterFields) ...[
              const SizedBox(height: PiggyDimens.p12),
              Text(field.name, style: PiggyTextTokens.label(context)),
              const SizedBox(height: PiggyDimens.p8),
              _fieldInput(field, l10n),
            ],
          ],
        ],
      ),
    );
  }

  Widget _fieldInput(CustomFieldDefinition field, AppLocalizations l10n) {
    final sid = field.syncId!;
    if (field.fieldType == CustomFieldType.text) {
      return TextFormField(
        controller: _textController(sid),
        decoration: piggyOutlinedDecoration(
          context,
          label: l10n.analyticsFilterTextHint,
        ),
        onChanged: (value) => _textValues[sid] = value,
      );
    }

    final options = CustomFieldOptionsCodec.decode(field.optionsJson);
    final selected = _selectValues[sid] ?? const <String>{};
    final choices = {...options, ...selected}.toList();
    return Wrap(
      spacing: PiggyDimens.p8,
      runSpacing: PiggyDimens.p8,
      children: [
        for (final option in choices)
          PiggySelectChip(
            key: ValueKey('analyticsFilterOption_${sid}_$option'),
            label: option,
            selected: selected.contains(option),
            onTap: () => setState(() {
              final set = {...(_selectValues[sid] ?? const <String>{})};
              if (set.contains(option)) {
                set.remove(option);
              } else if (field.fieldType == CustomFieldType.singleSelect) {
                set
                  ..clear()
                  ..add(option);
              } else {
                set.add(option);
              }
              if (set.isEmpty) {
                _selectValues.remove(sid);
              } else {
                _selectValues[sid] = set;
              }
            }),
          ),
      ],
    );
  }
}
