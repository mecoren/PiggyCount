/// 字段管理页「已填写 n 笔」计数（prd/custom_field_stats_fullchain F5，阶段 4 RED）。
///
/// 口径：**全账本**（不限统计区间）——管理页表达「数据完备度」，与分析页的
/// 区间填写率是两个问题。计数按字段 syncId 逐字段统计（不是「有任一字段值
/// 的交易数」），无人填写的字段显示 0。
///
/// 定义流与计数 provider 都覆写注入（不碰 drift，避免 pending Timer）；
/// 计数查询本体在 `custom_field_repository_test` 锁契约。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/settings/custom_field_manage_page.dart';
import 'package:piggycount/providers/custom_field_providers.dart';
import 'package:piggycount/providers/database_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('zh'));
  });

  CustomFieldDefinition field({
    required int id,
    required String name,
    required String syncId,
    required String fieldType,
  }) =>
      CustomFieldDefinition(
        id: id,
        ledgerId: 1,
        name: name,
        fieldType: fieldType,
        sortOrder: id - 1,
        createdAt: DateTime(2026, 1, 1),
        syncId: syncId,
        isRequired: false,
      );

  testWidgets('字段行追加「已填写 n 笔」，0 笔也显示', (tester) async {
    final defs = [
      field(id: 1, name: '押金', syncId: 'f-amt', fieldType: CustomFieldType.amount),
      field(id: 2, name: '渠道', syncId: 'f-sel', fieldType: CustomFieldType.text),
    ];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        currentLedgerIdProvider.overrideWith((ref) => 1),
        customFieldDefinitionsProvider
            .overrideWith((ref, ledgerId) => Stream.value(defs)),
        customFieldFilledCountsProvider
            .overrideWith((ref, ledgerId) async => {'f-amt': 2}),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CustomFieldManagePage(),
      ),
    ));
    await tester.pump(const Duration(seconds: 3));

    expect(find.textContaining(l10n.customFieldFilledCount(2)), findsOneWidget);
    expect(find.textContaining(l10n.customFieldFilledCount(0)), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  });
}
