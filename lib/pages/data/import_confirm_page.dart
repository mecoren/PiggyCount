import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../widgets/ui/ui.dart';
import '../../data/db.dart' as schema;
import '../../data/models/custom_field_values.dart';
import '../../l10n/app_localizations.dart';
import '../../services/import/csv_parser.dart';
import '../../utils/category_utils.dart';
import '../../services/import/bill_parser.dart';
import '../../services/import/parsers/generic_parser.dart';
import '../../services/import/parsers/alipay_parser.dart';
import '../../services/import/parsers/wechat_parser.dart';
import '../../services/import/parsers/auto_parser.dart';
import '../../services/system/logger_service.dart';
import '../../services/billing/post_processor.dart';
import '../../services/data_import_service.dart';
import '../../services/export/ledger_csv.dart' show customFieldCsvHeaderPrefix;
import '../../utils/date_parser.dart';
import '../../styles/tokens.dart';
import 'import_page.dart';

class ImportConfirmPage extends ConsumerStatefulWidget {
  final String csvText;
  final bool hasHeader;
  final BillSourceType billType;
  const ImportConfirmPage({
    super.key,
    required this.csvText,
    required this.hasHeader,
    required this.billType,
  });

  @override
  ConsumerState<ImportConfirmPage> createState() => _ImportConfirmPageState();
}

class _ImportConfirmPageState extends ConsumerState<ImportConfirmPage> {
  List<List<String>> rows = const [];
  bool parsing = true;
  // 自动识别到的表头所在行（仅当 hasHeader 为 true 时使用）
  int headerRow = 0;
  final Map<String, int?> mapping = {
    'date': null,
    'type': null,
    'amount': null,
    'currency': null, // v30 多币种:币种列(反馈10)
    'category': null,
    'sub_category': null, // 二级分类
    'account': null,
    'from_account': null,
    'to_account': null,
    'note': null,
    'tags': null, // 标签（逗号分隔）
    'attachments': null, // 附件文件名（逗号分隔）
    'custom_fields': null, // v46 自定义字段（{字段名: 值} JSON）
  };

  /// 新格式自定义字段独立列：归一化字段名 → (展示名, 列号)。
  Map<String, ({String name, int index})> _customFieldColumns = {};

  /// 导入期间用于按字段类型解码独立列（定义 + 本次确认新建）。
  Map<String, String> _customFieldNameToType = {};

  /// 用户在第一步为自定义字段列选择的目标：`__auto__` / `__skip__` / 定义 syncId。
  final Map<String, String> _customFieldTargets = {};

  /// 导入开始后解析出的「列 key → 目标字段 syncId」。
  final Map<String, String> _customFieldColumnSyncIds = {};

  static const _customFieldAuto = '__auto__';
  static const _customFieldSkip = '__skip__';
  static const _extraColumnKeyPrefix = '#col:';

  static String _extraColumnKey(int index) => '$_extraColumnKeyPrefix$index';

  bool _isExtraColumn(String key) => key.startsWith(_extraColumnKeyPrefix);

  bool importing = false;
  int ok = 0, fail = 0, skipped = 0; // skipped: 跳过的非收支类型记录
  int step = 0; // 0: 字段映射, 1: 分类映射
  bool _cancelled = false;

  /// 「后台导入」已把确认页与导入页一起 pop 掉。
  ///
  /// 本地库写入在微任务级完成，导入完成回调经常赶在退出动画结束前到达 ——
  /// 那一刻 `currentContext.mounted` **仍为 true**，但 Navigator 里已经没有
  /// 这两个路由了：再 pop 会 `Bad state: No element`（空栈 lastWhere 崩溃），
  /// 在数据页上弹完成提示也是打扰。用它把完成时的 UI 收尾整个短路掉。
  bool _poppedToBackground = false;
  List<String> distinctCategories = [];
  Map<String, int?> categoryMapping = {}; // 源分类名 -> 目标分类ID（null表示保持原名）
  Future<List<schema.Category>>? allCategoriesFuture;
  late final BillParser _billParser;

  @override
  void initState() {
    super.initState();
    // 根据账单类型选择解析器
    _billParser = _getParser(widget.billType);

    // 解析在后台 isolate 完成，避免主线程卡顿
    () async {
      final parsed = await compute(_parseRowsIsolate, widget.csvText);
      if (!mounted) return;
      setState(() {
        rows = parsed;
        parsing = false;
      });
      // 解析完成
      // 使用解析器查找表头
      if (widget.hasHeader && rows.isNotEmpty) {
        headerRow = _billParser.findHeaderRow(rows);
        if (headerRow < 0) headerRow = 0; // 兜底
      }
      _autoDetectMapping();
      // 预取分类列表供第二步选择
      allCategoriesFuture = _loadAllCategories(ref);
    }();
  }

  /// 根据账单类型获取解析器
  BillParser _getParser(BillSourceType type) {
    switch (type) {
      case BillSourceType.auto:
        return AutoBillParser();
      case BillSourceType.generic:
        return GenericBillParser();
      case BillSourceType.alipay:
        return AlipayBillParser();
      case BillSourceType.wechat:
        return WechatBillParser();
    }
  }

  void _autoDetectMapping() {
    if (rows.isEmpty || !widget.hasHeader) return;
    final headers = rows[headerRow].map((e) => e.toString().trim()).toList();

    // 使用解析器的列映射功能
    final detectedMapping = _billParser.mapColumns(headers);

    // 更新 mapping
    detectedMapping.forEach((key, index) {
      if (mapping.containsKey(key)) {
        mapping[key] = index;
      }
    });

    // 新格式：`custom_field:<字段名>` 独立列。这里只记录列位置，字段名 /
    // 类型在导入前由用户逐项确认，不做静默自动创建。
    _customFieldColumns = {};
    _customFieldTargets.clear();
    final usedByBuiltins = mapping.values.whereType<int>().toSet();
    for (var i = 0; i < headers.length; i++) {
      final header = headers[i];
      if (!header.startsWith(customFieldCsvHeaderPrefix)) continue;
      final rawName =
          header.substring(customFieldCsvHeaderPrefix.length).trim();
      if (rawName.isNotEmpty) {
        final key = rawName.toLowerCase();
        _customFieldColumns[key] = (name: rawName, index: i);
        _customFieldTargets[key] = _customFieldAuto;
      }
    }
    // 第三方 CSV 的未识别列：默认忽略，用户可在第一步主动映射成自定义字段。
    for (var i = 0; i < headers.length; i++) {
      final header = headers[i];
      if (header.isEmpty ||
          header.startsWith(customFieldCsvHeaderPrefix) ||
          usedByBuiltins.contains(i)) {
        continue;
      }
      final key = _extraColumnKey(i);
      _customFieldColumns[key] = (name: header, index: i);
      _customFieldTargets[key] = _customFieldSkip;
    }
  }

  bool _customFieldTargetUsedElsewhere(String syncId, String currentKey) =>
      _customFieldTargets.entries.any(
        (e) => e.key != currentKey && e.value == syncId,
      );

  @override
  Widget build(BuildContext context) {
    if (parsing) {
      return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: PiggyTitleBar(
          title: AppLocalizations.of(context).importPreparing,
          showBack: true,
        ),
        body: Padding(
          padding: EdgeInsets.only(
            top: PiggyTokens.topScrollablePadding(context),
          ),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: PiggySpinner(
                      size: 36, color: PiggyTokens.primary(context)),
                ),
              )
            ],
          ),
        ),
      );
    }
    final columnCount =
        rows.isNotEmpty ? rows[widget.hasHeader ? headerRow : 0].length : 0;
    List<DropdownMenuItem<int>> items() => List.generate(columnCount, (i) {
          final header = widget.hasHeader
              ? rows[headerRow]
              : (rows.isNotEmpty ? rows.first : const <String>[]);
          final label = (widget.hasHeader &&
                  i < header.length &&
                  header[i].trim().isNotEmpty)
              ? header[i].trim()
              : AppLocalizations.of(context).importColumnNumber(i + 1);
          return DropdownMenuItem(
              value: i, child: Text(label, overflow: TextOverflow.ellipsis));
        });

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: step == 0
            ? AppLocalizations.of(context).importConfirmMapping
            : AppLocalizations.of(context).importCategoryMapping,
        showBack: true,
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  if (step == 0) ...[
                    if (rows.isEmpty)
                      Text(AppLocalizations.of(context).importNoDataParsed),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        _mapRow(AppLocalizations.of(context).importFieldDate,
                            'date', items()),
                        _mapRow(AppLocalizations.of(context).importFieldType,
                            'type', items()),
                        _mapRow(AppLocalizations.of(context).importFieldAmount,
                            'amount', items()),
                        _mapRow(
                            AppLocalizations.of(context).importFieldCurrency,
                            'currency',
                            items()),
                        _mapRow(
                            AppLocalizations.of(context).importFieldCategory,
                            'category',
                            items()),
                        _mapRow(
                            AppLocalizations.of(context)
                                .exportCsvHeaderSubCategory,
                            'sub_category',
                            items()),
                        _mapRow(AppLocalizations.of(context).importFieldAccount,
                            'account', items()),
                        _mapRow(
                            AppLocalizations.of(context)
                                .exportCsvHeaderFromAccount,
                            'from_account',
                            items()),
                        _mapRow(
                            AppLocalizations.of(context)
                                .exportCsvHeaderToAccount,
                            'to_account',
                            items()),
                        _mapRow(AppLocalizations.of(context).importFieldNote,
                            'note', items()),
                        _mapRow(
                            AppLocalizations.of(context).exportCsvHeaderTags,
                            'tags',
                            items()),
                        _mapRow(
                            AppLocalizations.of(context)
                                .exportCsvHeaderAttachments,
                            'attachments',
                            items()),
                      ],
                    ),
                    if (_customFieldColumns.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        AppLocalizations.of(context)
                            .importCustomFieldMappingTitle,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppLocalizations.of(context)
                            .importCustomFieldMappingDesc,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: PiggyTokens.textSecondary(context)),
                      ),
                      const SizedBox(height: 8),
                      for (final entry in _customFieldColumns.entries
                          .where((e) => !_isExtraColumn(e.key)))
                        _customFieldMappingRow(
                          entry,
                          AppLocalizations.of(context),
                        ),
                      if (_customFieldColumns.keys.any(_isExtraColumn)) ...[
                        const SizedBox(height: 4),
                        Text(
                          AppLocalizations.of(context)
                              .importCustomFieldExtraColumns,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: PiggyTokens.textSecondary(context),
                                  ),
                        ),
                        const SizedBox(height: 8),
                        for (final entry in _customFieldColumns.entries
                            .where((e) => _isExtraColumn(e.key)))
                          _customFieldMappingRow(
                            entry,
                            AppLocalizations.of(context),
                          ),
                      ],
                    ],
                    const SizedBox(height: 12),
                    // 预览仅展示前 N 行，避免大文件一次性渲染导致卡顿
                    Text(AppLocalizations.of(context).importPreview,
                        style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 6),
                    SizedBox(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Builder(builder: (_) {
                          const int maxPreview = 10; // 预览最多 100 行
                          final totalRows = rows.length;
                          final dataStart =
                              widget.hasHeader ? (headerRow + 1) : 0;
                          // 保证包含表头行 + 最多 maxPreview-1 行数据。
                          // rows 为空（空 CSV / 全是空行）时 headerRow 仍是 0，
                          // 直接下标会 RangeError —— 上面的「未解析到任何数据」
                          // 提示是给用户的，这里崩了用户看到的却是报错页。
                          final header = widget.hasHeader && rows.isNotEmpty
                              ? [rows[headerRow]]
                              : <List<String>>[];
                          final body = totalRows > dataStart
                              ? () {
                                  final take = (maxPreview - header.length);
                                  final end = (dataStart + take <= totalRows)
                                      ? dataStart + take
                                      : totalRows;
                                  return rows.sublist(dataStart, end);
                                }()
                              : const <List<String>>[];
                          final limited = [...header, ...body];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _PreviewTable(rows: limited),
                              if (totalRows > limited.length)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6.0),
                                  child: Text(
                                    AppLocalizations.of(context)
                                        .importPreviewLimit(
                                            limited.length, totalRows),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            color: PiggyTokens.textTertiary(
                                                context)),
                                  ),
                                ),
                            ],
                          );
                        }),
                      ),
                    ),
                  ] else ...[
                    if (mapping['category'] == null)
                      Text(AppLocalizations.of(context)
                          .importCategoryNotSelected),
                    Text(AppLocalizations.of(context)
                        .importCategoryMappingDescription),
                    const SizedBox(height: 8),
                    FutureBuilder<List<schema.Category>>(
                      future: allCategoriesFuture,
                      builder: (context, snap) {
                        final cats = snap.data ?? [];
                        final l10n = AppLocalizations.of(context);
                        final items = <DropdownMenuItem<int?>>[
                          DropdownMenuItem(
                              value: null,
                              child: Text(l10n.importKeepOriginalName)),
                          ...cats.map((c) => DropdownMenuItem<int?>(
                                value: c.id,
                                child: Text(
                                    '${CategoryUtils.getDisplayName(c.name, context, kind: c.kind)} (${c.kind == 'income' ? l10n.categoryIncome : l10n.categoryExpense})'),
                              )),
                        ];
                        // 为每个源分类预设自动匹配（仅在首次加载时执行）
                        if (categoryMapping.values.every((v) => v == null) &&
                            cats.isNotEmpty) {
                          bool hasMatch = false;
                          for (final sourceName in distinctCategories) {
                            // 直接使用源分类名称查找匹配
                            try {
                              final matchingCategory = cats.firstWhere(
                                (c) => c.name == sourceName,
                              );
                              categoryMapping[sourceName] = matchingCategory.id;
                              hasMatch = true;
                            } catch (e) {
                              // 没有找到匹配的分类，保持为null
                            }
                          }
                          // 如果有自动匹配，触发重建以显示预设的匹配
                          if (hasMatch) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) setState(() {});
                            });
                          }
                        }

                        return Column(
                          children: [
                            for (final name in distinctCategories)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: Row(
                                  children: [
                                    Expanded(
                                        child: Text(name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis)),
                                    const SizedBox(width: 12),
                                    DropdownButton<int?>(
                                      value: categoryMapping[name],
                                      items: items,
                                      // 浮层与项目选择器同源（卡片底色 + radiusLg），
                                      // 不再吃 Material 默认底色/4px 圆角
                                      dropdownColor:
                                          PiggyTokens.surfaceElevated(context),
                                      borderRadius: BorderRadius.circular(
                                          PiggyDimens.radiusLg),
                                      onChanged: (v) => setState(
                                          () => categoryMapping[name] = v),
                                    ),
                                  ],
                                ),
                              )
                          ],
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    if (importing)
                      // gen-l10n 的占位符按**字母序**生成形参（fail, ok），
                      // 与中文文案里的出现顺序相反 —— 传错会把「成功/失败」对调。
                      Text(AppLocalizations.of(context)
                          .importProgress(fail, ok)),
                    const Spacer(),
                    if (step == 0)
                      FilledButton(
                        onPressed: () {
                          // 检查是否有分类列映射
                          // 如果没有分类列，说明可能只有转账记录，跳过分类映射步骤，直接开始导入
                          if (mapping['category'] == null) {
                            // 如果没有分类列但有转账相关列，则直接开始导入
                            if (mapping['from_account'] != null ||
                                mapping['to_account'] != null) {
                              _startImport();
                            } else {
                              showToast(
                                  context,
                                  AppLocalizations.of(context)
                                      .importSelectCategoryFirst);
                            }
                            return;
                          }
                          _buildDistinctCategories();
                          setState(() => step = 1);
                        },
                        child:
                            Text(AppLocalizations.of(context).importNextStep),
                      )
                    else ...[
                      OutlinedButton(
                        onPressed:
                            importing ? null : () => setState(() => step = 0),
                        child: Text(
                            AppLocalizations.of(context).importPreviousStep),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: importing ? null : _startImport,
                        child: Text(
                            AppLocalizations.of(context).importStartImport),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _customFieldMappingRow(
    MapEntry<String, ({String name, int index})> entry,
    AppLocalizations l10n,
  ) {
    final fields = ref.watch(customFieldsForCurrentLedgerProvider).value ??
        const <schema.CustomFieldDefinition>[];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(entry.value.name),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            key: ValueKey(
              'custom-field-map-${entry.key}-'
              '${_customFieldTargets[entry.key]}',
            ),
            initialValue: _customFieldTargets[entry.key] ?? _customFieldAuto,
            isExpanded: true,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.importCustomFieldMappingTarget,
            ),
            items: [
              DropdownMenuItem(
                value: _customFieldAuto,
                child: Text(l10n.importCustomFieldMappingAuto),
              ),
              DropdownMenuItem(
                value: _customFieldSkip,
                child: Text(l10n.importCustomFieldMappingSkip),
              ),
              for (final field in fields)
                if (field.syncId != null && field.syncId!.isNotEmpty)
                  DropdownMenuItem(
                    value: field.syncId,
                    enabled: !_customFieldTargetUsedElsewhere(
                      field.syncId!,
                      entry.key,
                    ),
                    child: Text(field.name),
                  ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _customFieldTargets[entry.key] = value;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _mapRow(String label, String key, List<DropdownMenuItem<int>> items) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: 64, child: Text(label)),
        const SizedBox(width: 8),
        SizedBox(
          width: 220,
          child: DropdownButton<int>(
            isExpanded: true,
            value: mapping[key],
            hint: Text(AppLocalizations.of(context).importAutoDetect),
            items: items,
            // 浮层与项目选择器同源（卡片底色 + radiusLg 圆角）
            dropdownColor: PiggyTokens.surfaceElevated(context),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            onChanged: (v) => setState(() => mapping[key] = v),
          ),
        ),
      ],
    );
  }

  Future<void> _startImport() async {
    // 使用根容器，保证页面被销毁后仍可更新全局进度供"我的"页展示
    final container = ProviderScope.containerOf(context, listen: false);
    final currentContext = context;
    setState(() {
      importing = true;
      ok = 0;
      fail = 0;
    });
    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);

    // v1.15.0: 获取当前账本的币种信息
    final currentLedger = await repo.getLedgerById(ledgerId);
    final ledgerCurrency = currentLedger?.currency ?? 'CNY';

    // v46 自定义字段：CSV 里该列是本 App 导出的 `{字段名: 值}` JSON，值必须
    // 落到**字段定义**上（交易上的值以定义 syncId 为键）。B4(v47)：本地没有
    // 的字段名不再直接丢弃 —— 按 CSV 值推断类型自动建定义（get-or-create），
    // 新定义的 syncId 补进映射后值即可落库。
    final customFieldDefs = await repo.getDefinitionsForLedger(ledgerId);
    final customFieldNameToSyncId = <String, String>{
      for (final f in customFieldDefs)
        if (f.syncId != null && f.syncId!.isNotEmpty)
          f.name.trim().toLowerCase(): f.syncId!,
    };
    final customFieldBySyncId = {
      for (final f in customFieldDefs)
        if (f.syncId != null && f.syncId!.isNotEmpty) f.syncId!: f,
    };

    final dataStart = widget.hasHeader ? (headerRow + 1) : 0;

    _customFieldNameToType = {
      for (final f in customFieldDefs) f.name.trim().toLowerCase(): f.fieldType,
    };
    // 第一步显式映射到已有字段的列：以用户选择为准，不再按表头名称猜。
    _customFieldColumnSyncIds.clear();
    for (final entry in _customFieldColumns.entries) {
      final target = _customFieldTargets[entry.key] ?? _customFieldAuto;
      if (target == _customFieldAuto || target == _customFieldSkip) continue;
      final def = customFieldBySyncId[target];
      if (def == null) continue; // 字段已被删除 → 退回自动匹配
      _customFieldColumnSyncIds[entry.key] = target;
      _customFieldNameToType[entry.key] = def.fieldType;
    }

    // 未知字段（旧 JSON 列与新独立列合并去重）逐项确认后创建；取消则整次
    // 导入都不开始，避免"确认到一半已经建了字段"。
    final unknown = _collectUnknownCustomFields(
      dataStart: dataStart,
      nameToSyncId: customFieldNameToSyncId,
    );
    if (unknown.isNotEmpty) {
      if (!mounted) return;
      setState(() => importing = false);
      final drafts = await showDialog<List<_CustomFieldDraft>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CustomFieldConfirmDialog(
          drafts: unknown,
          existingNames: customFieldNameToSyncId.keys.toSet(),
        ),
      );
      if (drafts == null) {
        if (mounted) setState(() => importing = false);
        return;
      }
      if (mounted) setState(() => importing = true);
      var sortOrder = customFieldDefs.length;
      for (final draft in drafts) {
        try {
          final id = await repo.upsertDefinition(
            ledgerId: ledgerId,
            name: draft.name,
            fieldType: draft.type,
            sortOrder: sortOrder++,
            options:
                CustomFieldType.hasOptions(draft.type) ? draft.options : null,
          );
          final def = await repo.getDefinitionById(id);
          final syncId = def?.syncId;
          if (syncId == null || syncId.isEmpty) {
            throw StateError('自定义字段落库后缺少 syncId');
          }
          final key = draft.name.trim().toLowerCase();
          customFieldNameToSyncId[key] = syncId;
          _customFieldNameToType[key] = draft.type;
        } catch (e) {
          // 字段建不成时继续导入会让该列值静默丢失 —— 整次导入先停下，
          // 已成功创建的字段保留（重试时会被识别为已有字段）。
          logger.warning('导入', '创建自定义字段「${draft.name}」失败: $e');
          if (mounted) {
            setState(() => importing = false);
            showToast(
              context,
              AppLocalizations.of(context)
                  .importCustomFieldCreateFailed(draft.name),
            );
          }
          return;
        }
      }
    }
    // 自动匹配的列：定义已就绪后补上列 → syncId；显式忽略的列不参与解析。
    for (final entry in _customFieldColumns.entries) {
      if (_customFieldColumnSyncIds.containsKey(entry.key)) continue;
      final target = _customFieldTargets[entry.key] ?? _customFieldAuto;
      if (target == _customFieldSkip) continue;
      final nameKey = entry.value.name.trim().toLowerCase();
      final syncId = customFieldNameToSyncId[nameKey];
      if (syncId == null) continue;
      _customFieldColumnSyncIds[entry.key] = syncId;
      _customFieldNameToType[entry.key] =
          customFieldBySyncId[syncId]?.fieldType ?? CustomFieldType.text;
    }
    final total = rows.length - dataStart;
    // 初始化全局进度
    container.read(importProgressProvider.notifier).state = ImportProgress(
      running: true,
      total: total,
      done: 0,
      ok: 0,
      fail: 0,
    );

    bool dialogOpen = true;
    // 进度弹窗（可转后台）;页面已销毁时跳过弹窗,导入流程继续后台执行
    if (currentContext.mounted) {
      showDialog(
        context: currentContext,
        barrierDismissible: false,
        builder: (dctx) {
          return Consumer(builder: (dctx, r, _) {
            final p = r.watch(importProgressProvider);
            final percent =
                p.total == 0 ? 0.0 : (p.done / p.total).clamp(0.0, 1.0);
            return AppDialogShell(
              wide: true,
              title: Text(AppLocalizations.of(context).importInProgress),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                      value: percent > 0 && percent < 1 ? percent : null),
                  const SizedBox(height: 8),
                  // 实时进度文案（每50条更新一次，足够流畅）
                  Text(
                      AppLocalizations.of(context)
                          .importProgressDetail(p.done, p.fail, p.ok, p.total),
                      style: Theme.of(dctx)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: PiggyTokens.textTertiary(context))),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    dialogOpen = false;
                    _poppedToBackground = true;
                    Navigator.of(dctx).pop();
                    // 返回到数据管理页面继续后台导入
                    if (mounted) {
                      // Pop回DataManagementPage: ImportConfirmPage -> ImportPage
                      Navigator.of(currentContext)
                          .pop(); // Close ImportConfirmPage
                      Navigator.of(currentContext)
                          .pop(); // Close ImportPage, back to DataManagementPage
                    }
                  },
                  child:
                      Text(AppLocalizations.of(context).importBackgroundImport),
                ),
                TextButton(
                  onPressed: () {
                    _cancelled = true;
                    dialogOpen = false;
                    Navigator.of(dctx).pop();
                  },
                  child: Text(AppLocalizations.of(context).importCancelImport),
                ),
              ],
            );
          });
        },
      );
    }

    // 定义进度变量
    int done = 0;

    // 收集跳过的类型（用于提示用户）
    final Map<String, int> skippedTypes = {};

    try {
      // 使用统一导入服务：将CSV数据转换为ImportData格式
      final importData = _buildImportDataFromCsv(
        rows: rows,
        dataStart: dataStart,
        mapping: mapping,
        categoryMapping: categoryMapping,
        skippedTypes: skippedTypes,
        ledgerCurrency: ledgerCurrency,
        customFieldNameToSyncId: customFieldNameToSyncId,
      );

      // 调用统一导入服务
      final result = await dataImportService.importData(
        repo,
        ledgerId,
        importData,
        defaultCurrency: ledgerCurrency,
        onProgress: (processed, progressTotal) {
          done = processed;
          // 更新全局进度
          container.read(importProgressProvider.notifier).state =
              ImportProgress(
            running: true,
            total: total,
            done: done,
            ok: ok,
            fail: fail,
          );
          if (mounted) setState(() {});
        },
      );

      ok = result.inserted;
      fail = result.failed;
      skipped = skippedTypes.values.fold(0, (a, b) => a + b);
      done = total;

      // 显式触发一次同步上推。SyncCoordinator 监听 local_changes 表已经会
      // 自动调度,这里作为兜底:provider 重建瞬间 / 边界条件下 coordinator
      // 还没就位时,UI 显式触发也能把刚导入的数据推上云端。
      // fire-and-forget:不阻塞导入完成动画。
      try {
        // ignore: unawaited_futures
        PostProcessor.syncC(container, ledgerId: ledgerId);
      } catch (_) {
        // 忽略同步触发错误,导入本身已经成功
      }
    } catch (e) {
      // 导入失败
      if (mounted) {
        showToast(context,
            AppLocalizations.of(context).importTransactionFailed('$e'));
      }
      fail = total - ok; // 更新失败数
    }

    // 即使页面已被关闭（mounted=false），也要继续更新全局进度供"我的"页展示
    // 先切换为"完成"以驱动 UI 展示成功动画/提示（不等待云上传）
    try {
      container.read(importProgressProvider.notifier).state = ImportProgress(
        running: false,
        total: total,
        done: done,
        ok: ok,
        fail: fail,
        ledgerId: ledgerId, // 设置账本ID，用于触发账本列表页面刷新
        skipped: skipped, // 跳过的记录数
        skippedTypes: skippedTypes, // 跳过的类型及数量
      );
    } catch (_) {
      // 忽略进度更新错误
    }

    // 延迟清空和刷新（不依赖页面状态，即使页面销毁也要执行）
    if (!_cancelled) {
      Future<void>.delayed(const Duration(seconds: 5), () {
        // 延长到5秒，让用户看到动画
        try {
          container.read(importProgressProvider.notifier).state =
              ImportProgress.empty;
          // 刷新"我的"页统计（笔数/天数）
          container.invalidate(countsForLedgerProvider(ledgerId));
          // 触发全局统计刷新（用于"我的"页顶部聚合信息）
          container.read(statsRefreshProvider.notifier).state++;
          // 触发一次同步状态刷新（UI 端会复用缓存避免闪烁）
          container.read(syncStatusRefreshProvider.notifier).state++;
        } catch (_) {
          // 忽略延迟刷新错误
        }
      });
    }

    // Check if context is still mounted for UI operations
    if (!currentContext.mounted) {
      return;
    }
    // 已转后台：页面已关，不得再 pop（会 pop 空栈崩溃），
    // 也不该在数据页上再弹一次完成提示。
    if (_poppedToBackground) {
      return;
    }

    // 显示导入完成提示
    final cancelledText =
        _cancelled ? AppLocalizations.of(currentContext).importCancelled : '';
    final l10nToast = AppLocalizations.of(currentContext);

    // 构建提示信息
    String message = l10nToast.importCompleted(cancelledText, fail, ok);
    bool hasSkipped = skipped > 0;

    if (hasSkipped) {
      // 显示类型不匹配的跳过记录
      final typeSkipped = skippedTypes.values.fold(0, (a, b) => a + b);

      if (typeSkipped > 0) {
        final skippedList =
            skippedTypes.entries.map((e) => '${e.key}(${e.value})').join('、');
        message +=
            '\n${l10nToast.importSkippedNonTransactionTypes(typeSkipped)}\n$skippedList';
      }
    }

    // Handle UI operations before cloud upload
    if (dialogOpen) {
      Navigator.of(currentContext).pop();
    }

    // 判断显示方式: 完全成功用toast,有失败或跳过用弹窗
    if (fail == 0 && !hasSkipped) {
      // 完全成功: 使用toast,然后关闭页面
      showToast(currentContext, message);
      // 关闭确认页 -> 返回到数据管理页面
      // Pop回DataManagementPage: ImportConfirmPage -> ImportPage
      Navigator.of(currentContext).pop(); // Close ImportConfirmPage
      Navigator.of(currentContext)
          .pop(); // Close ImportPage, back to DataManagementPage
    } else {
      // 有失败或跳过: 使用弹窗显示详细信息,等待用户确认后再关闭页面
      await showDialog(
        context: currentContext,
        builder: (ctx) => AppDialogShell(
          title: Text(l10nToast.importCompleteTitle),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10nToast.commonConfirm),
            ),
          ],
        ),
      );

      // 用户确认后再关闭页面
      if (currentContext.mounted) {
        Navigator.of(currentContext).pop(); // Close ImportConfirmPage
        Navigator.of(currentContext)
            .pop(); // Close ImportPage, back to DataManagementPage
      }
    }
    // 返回后再显式刷新一次全局统计，确保顶部汇总即时更新
    try {
      container.read(statsRefreshProvider.notifier).state++;
    } catch (_) {
      // 页面已返回/container 已释放时跳过本次统计刷新
    }

    // 导入完成后，账本列表页面会通过监听 importProgressProvider 自动刷新
    // ledgerId 已经在上面的 importProgressProvider 中设置
  }

  /// 将CSV数据转换为统一的ImportData格式
  ImportData _buildImportDataFromCsv({
    required List<List<String>> rows,
    required int dataStart,
    required Map<String, int?> mapping,
    required Map<String, int?> categoryMapping,
    required Map<String, int> skippedTypes,
    required String ledgerCurrency,
    required Map<String, String> customFieldNameToSyncId,
  }) {
    final accounts = <ImportAccount>[];
    final categories = <ImportCategory>[];
    final tags = <ImportTag>[];
    final transactions = <ImportTransaction>[];

    final accountIdx = mapping['account'];
    final fromAccountIdx = mapping['from_account'];
    final toAccountIdx = mapping['to_account'];
    final tagsIdx = mapping['tags'];

    // 收集唯一账户和标签
    final uniqueAccountNames = <String>{};
    final uniqueTagNames = <String>{};
    // 收集分类信息（用于创建分类）
    final categoryInfoMap =
        <String, ({String kind, String? icon, String? parentName})>{};

    // 第一遍：收集账户、标签、分类信息
    for (int i = dataStart; i < rows.length; i++) {
      final r = rows[i];

      String? getBy(String key) {
        final userIdx = mapping[key];
        if (userIdx != null && userIdx >= 0 && userIdx < r.length) {
          final val = r[userIdx].toString().trim();
          return val.isNotEmpty ? val : null;
        }
        return null;
      }

      // 收集账户名
      if (accountIdx != null && accountIdx < r.length) {
        final name = r[accountIdx].toString().trim();
        if (name.isNotEmpty) uniqueAccountNames.add(name);
      }
      if (fromAccountIdx != null && fromAccountIdx < r.length) {
        final name = r[fromAccountIdx].toString().trim();
        if (name.isNotEmpty) uniqueAccountNames.add(name);
      }
      if (toAccountIdx != null && toAccountIdx < r.length) {
        final name = r[toAccountIdx].toString().trim();
        if (name.isNotEmpty) uniqueAccountNames.add(name);
      }

      // 收集标签名
      if (tagsIdx != null && tagsIdx < r.length) {
        final tagsStr = r[tagsIdx].toString().trim();
        if (tagsStr.isNotEmpty) {
          for (final tagName in tagsStr.split(',')) {
            final trimmed = tagName.trim();
            if (trimmed.isNotEmpty) uniqueTagNames.add(trimmed);
          }
        }
      }

      // 解析类型用于分类收集
      final typeRaw = getBy('type') ?? 'expense';
      final typeStr = typeRaw.trim().toLowerCase();
      String? type;
      if (typeStr == '收入' ||
          typeStr == '收' ||
          typeStr == '入账' ||
          typeStr == '进账' ||
          typeStr == '入帳' ||
          typeStr == '進帳' || // 繁体
          typeStr == 'income' ||
          typeStr == 'revenue' ||
          typeStr == 'earning') {
        type = 'income';
      } else if (typeStr == '支出' ||
          typeStr == '支' ||
          typeStr == '出账' ||
          typeStr == '消费' ||
          typeStr == '花费' ||
          typeStr == '出帳' ||
          typeStr == '消費' ||
          typeStr == '花費' || // 繁体
          typeStr == 'expense' ||
          typeStr == 'spending' ||
          typeStr == 'expenditure') {
        type = 'expense';
      } else if (typeStr == '转账' || typeStr == '轉帳' || typeStr == 'transfer') {
        // 添加繁体
        type = 'transfer';
      }

      // 收集分类信息（仅非转账）
      if (type != null && type != 'transfer') {
        final categoryName = getBy('category');
        final subCategoryName = getBy('sub_category');
        final categoryIcon = getBy('category_icon');
        final subCategoryIcon = getBy('sub_category_icon');

        if (subCategoryName != null && categoryName != null) {
          // 有二级分类
          final parentKey = '$categoryName:$type';
          categoryInfoMap.putIfAbsent(
              parentKey,
              () => (
                    kind: type!,
                    icon: categoryIcon,
                    parentName: null,
                  ));
          final subKey = '$subCategoryName:$type:$categoryName';
          categoryInfoMap.putIfAbsent(
              subKey,
              () => (
                    kind: type!,
                    icon: subCategoryIcon,
                    parentName: categoryName,
                  ));
        } else if (categoryName != null) {
          // 只有一级分类（仅当用户选择"保持原名"时才需要创建）
          final chosen = categoryMapping[categoryName];
          if (chosen == null) {
            final key = '$categoryName:$type';
            categoryInfoMap.putIfAbsent(
                key,
                () => (
                      kind: type!,
                      icon: categoryIcon,
                      parentName: null,
                    ));
          }
        }
      }
    }

    // 构建账户列表
    for (final name in uniqueAccountNames) {
      accounts.add(ImportAccount(
        name: name,
        type: 'cash',
        currency: ledgerCurrency,
      ));
    }

    // 构建标签列表
    for (final name in uniqueTagNames) {
      tags.add(ImportTag(name: name));
    }

    // 构建分类列表（先一级后二级）
    final level1Categories = categoryInfoMap.entries
        .where((e) => e.value.parentName == null)
        .toList();
    final level2Categories = categoryInfoMap.entries
        .where((e) => e.value.parentName != null)
        .toList();

    for (final entry in level1Categories) {
      final parts = entry.key.split(':');
      final name = parts[0];
      final kind = parts[1];
      categories.add(ImportCategory(
        name: name,
        kind: kind,
        level: 1,
        icon: entry.value.icon,
      ));
    }
    for (final entry in level2Categories) {
      final parts = entry.key.split(':');
      final name = parts[0];
      final kind = parts[1];
      final parentName = parts[2];
      categories.add(ImportCategory(
        name: name,
        kind: kind,
        level: 2,
        icon: entry.value.icon,
        parentName: parentName,
      ));
    }

    // 第二遍：构建交易列表
    for (int i = dataStart; i < rows.length; i++) {
      final r = rows[i];

      String? getBy(String key) {
        final userIdx = mapping[key];
        if (userIdx != null && userIdx >= 0 && userIdx < r.length) {
          final val = r[userIdx].toString().trim();
          return val.isNotEmpty ? val : null;
        }
        return null;
      }

      final dateStr = getBy('date');
      final typeRaw = getBy('type') ?? 'expense';
      final amountStr = getBy('amount');
      final currencyStr = getBy('currency')?.trim().toUpperCase();
      final categoryName = getBy('category');
      final subCategoryName = getBy('sub_category');
      final accountName = getBy('account');
      final fromAccountName = getBy('from_account');
      final toAccountName = getBy('to_account');
      final note = getBy('note');
      final tagsStr = getBy('tags');
      final attachmentsStr = getBy('attachments');
      final customFieldsStr = getBy('custom_fields');
      final legacyValues = _parseCsvCustomValues(
        customFieldsStr,
        customFieldNameToSyncId,
      );
      final columnValues = _parseCustomFieldColumns(r);
      // 独立列是显式列，覆盖旧 JSON 里的同名字段（极少见的混合文件）。
      final customValues = <String, dynamic>{
        ...?legacyValues,
        ...columnValues,
      };

      // 类型识别
      final typeStr = typeRaw.trim().toLowerCase();
      String? type;
      if (typeStr == '收入' ||
          typeStr == '收' ||
          typeStr == '入账' ||
          typeStr == '进账' ||
          typeStr == '入帳' ||
          typeStr == '進帳' || // 繁体
          typeStr == 'income' ||
          typeStr == 'revenue' ||
          typeStr == 'earning') {
        type = 'income';
      } else if (typeStr == '支出' ||
          typeStr == '支' ||
          typeStr == '出账' ||
          typeStr == '消费' ||
          typeStr == '花费' ||
          typeStr == '出帳' ||
          typeStr == '消費' ||
          typeStr == '花費' || // 繁体
          typeStr == 'expense' ||
          typeStr == 'spending' ||
          typeStr == 'expenditure') {
        type = 'expense';
      } else if (typeStr == '转账' || typeStr == '轉帳' || typeStr == 'transfer') {
        // 添加繁体
        type = 'transfer';
      } else {
        // 未识别的类型：记录并跳过
        skippedTypes[typeRaw.trim()] = (skippedTypes[typeRaw.trim()] ?? 0) + 1;
        continue;
      }

      // 金额解析
      final amountClean = (amountStr ?? '0').replaceAll(RegExp(r'[¥$,+-]'), '');
      final amount = double.tryParse(amountClean)?.abs() ?? 0.0;

      // 日期解析
      final date = DateParser.parse(dateStr);

      // 解析标签名称列表
      List<String>? tagNames;
      if (tagsStr != null && tagsStr.isNotEmpty) {
        tagNames = tagsStr
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
      }

      // 解析附件文件名列表
      List<ImportAttachment>? attachments;
      if (attachmentsStr != null && attachmentsStr.isNotEmpty) {
        final fileNames = attachmentsStr
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (fileNames.isNotEmpty) {
          attachments = fileNames
              .asMap()
              .entries
              .map((entry) => ImportAttachment(
                    fileName: entry.value,
                    sortOrder: entry.key,
                  ))
              .toList();
        }
      }

      // 处理分类：支持用户映射和二级分类
      String? finalCategoryName;
      String? categoryKind;
      int? categoryId;

      if (type != 'transfer') {
        if (subCategoryName != null && categoryName != null) {
          // 有二级分类：使用二级分类名称
          finalCategoryName = subCategoryName;
          categoryKind = type;
        } else if (categoryName != null) {
          // 只有一级分类：检查用户映射
          final chosen = categoryMapping[categoryName];
          if (chosen != null) {
            // 用户选择了现有分类，使用预解析的ID
            categoryId = chosen;
          } else {
            // 保持原名
            finalCategoryName = categoryName;
            categoryKind = type;
          }
        }
      }

      transactions.add(ImportTransaction(
        type: type,
        amount: amount,
        // 币种列有值且像 ISO code(3-8 位字母)才采纳,脏值回退兜底链
        currencyCode: (currencyStr != null &&
                RegExp(r'^[A-Z]{3,8}$').hasMatch(currencyStr))
            ? currencyStr
            : null,
        categoryName: finalCategoryName,
        categoryKind: categoryKind,
        categoryId: categoryId,
        happenedAt: date,
        note: note,
        accountName: type != 'transfer' ? accountName : null,
        fromAccountName: type == 'transfer' ? fromAccountName : null,
        toAccountName: type == 'transfer' ? toAccountName : null,
        tagNames: tagNames,
        attachments: attachments,
        customValues: customValues.isEmpty ? null : customValues,
      ));
    }

    return ImportData(
      accounts: accounts,
      categories: categories,
      tags: tags,
      transactions: transactions,
    );
  }

  /// 扫描旧 JSON 列与新独立列，收集本地没有定义的字段名与示例值。
  List<_CustomFieldDraft> _collectUnknownCustomFields({
    required int dataStart,
    required Map<String, String> nameToSyncId,
  }) {
    final names = <String, ({String raw, List<String> values})>{};

    void addValue(String rawName, String value, {bool splitList = false}) {
      final trimmed = rawName.trim();
      if (trimmed.isEmpty) return;
      final key = trimmed.toLowerCase();
      if (nameToSyncId.containsKey(key)) return;
      final entry =
          names.putIfAbsent(key, () => (raw: trimmed, values: <String>[]));
      final v = value.trim();
      if (v.isEmpty) return;
      if (splitList && v.startsWith('[')) {
        try {
          final decoded = jsonDecode(v);
          if (decoded is List) {
            for (final item in decoded) {
              final s = item?.toString().trim() ?? '';
              if (s.isNotEmpty) entry.values.add(s);
            }
            return;
          }
        } catch (_) {
          // 落回原文（用户手填的逗号列表也允许后续按选项猜）。
        }
      }
      entry.values.add(v);
    }

    final legacyCol = mapping['custom_fields'];
    if (legacyCol != null) {
      for (var i = dataStart; i < rows.length; i++) {
        final r = rows[i];
        if (legacyCol >= r.length) continue;
        final cell = r[legacyCol].trim();
        if (cell.isEmpty) continue;
        Object? decoded;
        try {
          decoded = jsonDecode(cell);
        } catch (_) {
          continue;
        }
        if (decoded is! Map) continue;
        for (final e in decoded.entries) {
          addValue(e.key.toString(), e.value?.toString() ?? '');
        }
      }
    }

    for (final entry in _customFieldColumns.entries) {
      final target = _customFieldTargets[entry.key] ?? _customFieldAuto;
      if (target == _customFieldSkip ||
          _customFieldColumnSyncIds.containsKey(entry.key)) {
        continue;
      }
      for (var i = dataStart; i < rows.length; i++) {
        final r = rows[i];
        if (entry.value.index >= r.length) continue;
        addValue(
          entry.value.name,
          r[entry.value.index],
          splitList: true,
        );
      }
    }

    return [
      for (final entry in names.values)
        _CustomFieldDraft(
          name: entry.raw,
          type: _inferCustomFieldType(entry.values),
          options: _inferCustomFieldOptions(entry.values),
        ),
    ];
  }

  String _inferCustomFieldType(List<String> values) {
    final nonEmpty = values.where((v) => v.trim().isNotEmpty).toList();
    if (nonEmpty.isEmpty) return CustomFieldType.text;
    if (nonEmpty.every((v) => double.tryParse(v) != null)) {
      return CustomFieldType.amount;
    }
    if (nonEmpty.every((v) => DateTime.tryParse(v) != null)) {
      return CustomFieldType.date;
    }
    return CustomFieldType.text;
  }

  List<String> _inferCustomFieldOptions(List<String> values) {
    final out = <String>[];
    for (final v in values) {
      final s = v.trim();
      if (s.isNotEmpty && !out.contains(s)) out.add(s);
    }
    return out;
  }

  /// 解析 CSV 的「自定义字段」列（本 App 导出为 `{字段名: 值}` JSON）。
  ///
  /// 只映射到**本地已有定义**（按名称匹配，忽略大小写与首尾空白）：名称在
  /// 本地找不到定义时该值被丢弃 —— 交易上的值以定义 syncId 为键，没有定义
  /// 就没有承载它的位置（UI 也不会渲染）。
  ///
  /// 非 JSON（用户手工填写的列）静默当"没有值"处理，绝不阻断导入 ——
  /// 导入流程的健壮性优先于"猜用户想干什么"。
  Map<String, dynamic>? _parseCsvCustomValues(
    String? raw,
    Map<String, String> nameToSyncId,
  ) {
    if (raw == null || raw.isEmpty || nameToSyncId.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final out = <String, dynamic>{};
    for (final entry in decoded.entries) {
      final syncId = nameToSyncId[entry.key.toString().trim().toLowerCase()];
      if (syncId == null) continue;
      final value = CustomFieldValueCodec.normalizeValue(entry.value);
      if (value == null) continue;
      out[syncId] = value;
    }
    return out.isEmpty ? null : out;
  }

  /// 解析新格式独立列：表头已定位到列号，单元格按目标字段类型解码。
  Map<String, dynamic> _parseCustomFieldColumns(List<String> row) {
    final out = <String, dynamic>{};
    for (final entry in _customFieldColumns.entries) {
      final syncId = _customFieldColumnSyncIds[entry.key];
      if (syncId == null || entry.value.index >= row.length) continue;
      final raw = row[entry.value.index].trim();
      if (raw.isEmpty) continue;
      final type = _customFieldNameToType[entry.key] ?? CustomFieldType.text;
      final value = _decodeCustomFieldCell(raw, type);
      if (value != null) out[syncId] = value;
    }
    return out;
  }

  dynamic _decodeCustomFieldCell(String raw, String fieldType) {
    if (fieldType == CustomFieldType.multiSelect) {
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        decoded = raw.split(',');
      }
      return CustomFieldValueCodec.normalizeValue(
        decoded is List ? decoded : [decoded],
      );
    }
    if (fieldType == CustomFieldType.amount) {
      final n = double.tryParse(raw);
      return n == null ? null : CustomFieldValueCodec.normalizeValue(n);
    }
    return CustomFieldValueCodec.normalizeValue(raw);
  }

  void _buildDistinctCategories() {
    final catIdx = mapping['category'];
    if (catIdx == null) {
      distinctCategories = [];
      categoryMapping = {};
      return;
    }
    final set = <String>{};
    final dataStart = widget.hasHeader ? (headerRow + 1) : 0;
    for (int i = dataStart; i < rows.length; i++) {
      if (catIdx < rows[i].length) {
        final name = rows[i][catIdx].trim();
        if (name.isNotEmpty) set.add(name);
      }
    }
    distinctCategories = set.toList()..sort();

    // 初始化分类映射为null，后续在FutureBuilder中进行自动匹配
    categoryMapping = {for (final n in distinctCategories) n: null};
  }
}

class _CustomFieldDraft {
  _CustomFieldDraft({
    required this.name,
    required this.type,
    required this.options,
  });

  String name;
  String type;
  final List<String> options;
}

/// 未知自定义字段逐项确认：名称可改、类型可选；单选 / 多选沿用数据中
/// 出现的值作为选项（不再静默按列值猜类型建字段）。
class _CustomFieldConfirmDialog extends StatefulWidget {
  const _CustomFieldConfirmDialog({
    required this.drafts,
    required this.existingNames,
  });

  final List<_CustomFieldDraft> drafts;
  final Set<String> existingNames;

  @override
  State<_CustomFieldConfirmDialog> createState() =>
      _CustomFieldConfirmDialogState();
}

class _CustomFieldConfirmDialogState extends State<_CustomFieldConfirmDialog> {
  late final List<TextEditingController> _controllers;
  late final List<TextEditingController> _optionControllers;
  late final List<String> _types;
  late final List<List<String>> _options;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controllers = [
      for (final d in widget.drafts) TextEditingController(text: d.name),
    ];
    _optionControllers = [
      for (final _ in widget.drafts) TextEditingController()
    ];
    _types = [for (final d in widget.drafts) d.type];
    _options = [
      for (final d in widget.drafts) [...d.options],
    ];
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final c in _optionControllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _addOption(int index) {
    final value = _optionControllers[index].text.trim();
    if (value.isEmpty) return;
    setState(() {
      if (!_options[index].contains(value)) _options[index].add(value);
      _optionControllers[index].clear();
      _error = null;
    });
  }

  String _typeLabel(AppLocalizations l10n, String type) => switch (type) {
        CustomFieldType.amount => l10n.customFieldTypeAmount,
        CustomFieldType.date => l10n.customFieldTypeDate,
        CustomFieldType.singleSelect => l10n.customFieldTypeSingleSelect,
        CustomFieldType.multiSelect => l10n.customFieldTypeMultiSelect,
        _ => l10n.customFieldTypeText,
      };

  void _confirm() {
    final l10n = AppLocalizations.of(context);
    final names = <String>{};
    for (var i = 0; i < _controllers.length; i++) {
      final name = _controllers[i].text.trim();
      final key = name.toLowerCase();
      if (name.isEmpty) {
        setState(() => _error = l10n.importCustomFieldNameRequired);
        return;
      }
      if (names.contains(key) || widget.existingNames.contains(key)) {
        setState(() => _error = l10n.importCustomFieldNameDuplicate(name));
        return;
      }
      names.add(key);
      if (CustomFieldType.hasOptions(_types[i]) && _options[i].isEmpty) {
        setState(() => _error = l10n.importCustomFieldOptionsRequired(name));
        return;
      }
    }
    Navigator.of(context).pop([
      for (var i = 0; i < _controllers.length; i++)
        _CustomFieldDraft(
          name: _controllers[i].text.trim(),
          type: _types[i],
          options: _options[i],
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppDialogShell(
      wide: true,
      title: Text(l10n.importCustomFieldColumnsTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.importCustomFieldColumnsDesc,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PiggyTokens.textSecondary(context),
                  ),
            ),
            const SizedBox(height: PiggyDimens.p12),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.52,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: widget.drafts.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: PiggyDimens.p12),
                itemBuilder: (context, i) {
                  return Container(
                    padding: const EdgeInsets.all(PiggyDimens.p12),
                    decoration: BoxDecoration(
                      color: PiggyTokens.surfaceElevated(context),
                      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                    ),
                    child: Column(
                      children: [
                        TextField(
                          controller: _controllers[i],
                          decoration: piggyOutlinedDecoration(
                            context,
                            label: l10n.importCustomFieldName,
                          ),
                        ),
                        const SizedBox(height: PiggyDimens.p8),
                        DropdownButtonFormField<String>(
                          initialValue: _types[i],
                          decoration: piggyOutlinedDecoration(
                            context,
                            label: l10n.importCustomFieldType,
                          ),
                          items: [
                            for (final type in CustomFieldType.all)
                              DropdownMenuItem(
                                value: type,
                                child: Text(_typeLabel(l10n, type)),
                              ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _types[i] = v);
                          },
                        ),
                        if (CustomFieldType.hasOptions(_types[i])) ...[
                          const SizedBox(height: PiggyDimens.p8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              l10n.importCustomFieldOptions(_options[i].length),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: PiggyTokens.textSecondary(context),
                                  ),
                            ),
                          ),
                          if (_options[i].isNotEmpty) ...[
                            const SizedBox(height: PiggyDimens.p8),
                            Wrap(
                              spacing: PiggyDimens.p8,
                              runSpacing: PiggyDimens.p8,
                              children: [
                                for (final option in _options[i])
                                  InputChip(
                                    label: Text(option),
                                    onDeleted: () => setState(() {
                                      _options[i].remove(option);
                                      _error = null;
                                    }),
                                  ),
                              ],
                            ),
                          ],
                          const SizedBox(height: PiggyDimens.p8),
                          TextField(
                            controller: _optionControllers[i],
                            decoration: piggyOutlinedDecoration(
                              context,
                              label: l10n.importCustomFieldAddOption,
                            ),
                            onSubmitted: (_) => _addOption(i),
                            onChanged: (_) {
                              if (_error != null) setState(() => _error = null);
                            },
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => _addOption(i),
                              child:
                                  Text(l10n.importCustomFieldAddOptionAction),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: PiggyDimens.p8),
              Text(
                _error!,
                style: TextStyle(color: PiggyTokens.error(context)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          key: const Key('import-custom-field-confirm'),
          onPressed: _confirm,
          child: Text(l10n.commonConfirm),
        ),
      ],
    );
  }
}

// isolate 入口函数：在后台解析 CSV 文本
List<List<String>> _parseRowsIsolate(String input) {
  return CsvParser.parse(input);
}

Future<List<schema.Category>> _loadAllCategories(WidgetRef ref) async {
  final repo = ref.read(repositoryProvider);
  final expenseTopLevel = await repo.getTopLevelCategories('expense');
  final incomeTopLevel = await repo.getTopLevelCategories('income');

  final allCategories = <schema.Category>[];
  allCategories.addAll(expenseTopLevel);
  allCategories.addAll(incomeTopLevel);

  // 获取所有子分类
  for (final category in [...expenseTopLevel, ...incomeTopLevel]) {
    final subCategories = await repo.getSubCategories(category.id);
    allCategories.addAll(subCategories);
  }

  return allCategories;
}

class _PreviewTable extends StatelessWidget {
  final List<List<String>> rows;
  // 预览表格: 固定单元格宽度，避免在横向滚动环境中使用 Expanded 触发布局错误
  const _PreviewTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    const double cellWidth = 140;
    return ClipRRect(
      borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: PiggyTokens.border(context)),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
        ),
        child: Column(
          children: [
            for (int r = 0; r < rows.length; r++)
              Container(
                color: r == 0
                    ? PiggyTokens.surfaceSecondary(context)
                    : PiggyTokens.surfaceElevated(context),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                child: Row(
                  children: [
                    for (final cell in rows[r])
                      SizedBox(
                        width: cellWidth,
                        child: Text(
                          cell,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: PiggyTokens.textPrimary(context),
                            fontWeight: r == 0 ? FontWeight.w600 : null,
                          ),
                        ),
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
