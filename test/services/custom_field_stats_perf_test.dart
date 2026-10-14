/// 洞察自定义字段聚合 —— 4 万交易规模性能抽验（上线清单 #8）。
///
/// 证明两件事：
/// 1. **聚合一趟完成**：[CustomFieldStatsService.aggregateDetail] 对 4 万行
///    （约 6 成带自定义字段值、5 字段）单次调用在时限内返回，不存在按行
///    反复查询或二次遍历的 N+1 形态；
/// 2. **规模正确性**：大输入下的求和/填写率/值桶计数与逐行构造的期望值
///    精确一致（性能优化不能换口径）。
///
/// 时限取 5s：flutter test 走 JIT debug，比 release 慢一个量级；正常实现
/// 本用例约百毫秒级，5s 上限只拦病态复杂度（如误写成 O(n²) 或 4 万次
/// JSON 全量重解码），不因 CI 抖动误报。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/services/custom_field_stats_service.dart';

void main() {
  test('4 万行 × 5 字段：一趟聚合时限内完成且口径精确', () {
    const rowCount = 40000;
    final defs = [
      CustomFieldDefinition(
          id: 1, ledgerId: 1, name: '押金', fieldType: CustomFieldType.amount,
          sortOrder: 0, createdAt: DateTime(2026, 1, 1), syncId: 'f-amt', isRequired: false),
      CustomFieldDefinition(
          id: 2, ledgerId: 1, name: '入住日', fieldType: CustomFieldType.date,
          sortOrder: 1, createdAt: DateTime(2026, 1, 1), syncId: 'f-date', isRequired: false),
      CustomFieldDefinition(
          id: 3, ledgerId: 1, name: '备注', fieldType: CustomFieldType.text,
          sortOrder: 2, createdAt: DateTime(2026, 1, 1), syncId: 'f-text', isRequired: false),
      CustomFieldDefinition(
          id: 4, ledgerId: 1, name: '渠道', fieldType: CustomFieldType.singleSelect,
          sortOrder: 3, createdAt: DateTime(2026, 1, 1), syncId: 'f-sel', isRequired: false,
          optionsJson: CustomFieldOptionsCodec.encode(const ['a', 'b'])),
      CustomFieldDefinition(
          id: 5, ledgerId: 1, name: '标签', fieldType: CustomFieldType.multiSelect,
          sortOrder: 4, createdAt: DateTime(2026, 1, 1), syncId: 'f-multi', isRequired: false,
          optionsJson: CustomFieldOptionsCodec.encode(const ['x', 'y'])),
    ];

    // 口径设计：行号 i 偶数 = 有值行（5 成），值内容按 i 确定性构造，
    // 期望值可逐行推导，规模正确性断言不依赖被测实现。
    final rows = <({String type, double nativeAmount, String? customValuesJson})>[];
    var expectFilled = 0;
    var expectSum = 0.0;
    final expectSelCount = <String, int>{};
    for (var i = 0; i < rowCount; i++) {
      if (i.isEven) {
        final amt = (i % 1000) / 10.0;
        final sel = i % 4 == 0 ? 'a' : 'b';
        expectFilled++;
        expectSum += amt;
        expectSelCount[sel] = (expectSelCount[sel] ?? 0) + 1;
        rows.add((
          type: i % 4 == 0 ? 'expense' : 'income',
          nativeAmount: amt,
          customValuesJson:
              '{"f-amt":$amt,"f-text":"t$i","f-sel":"$sel","f-multi":["x"]}',
        ));
      } else {
        rows.add((type: 'expense', nativeAmount: 1.0, customValuesJson: null));
      }
    }

    final sw = Stopwatch()..start();
    final stats = CustomFieldStatsService.aggregateDetail(
      defs: defs,
      totalCount: rowCount,
      rows: rows,
    );
    sw.stop();
    // ignore: avoid_print
    print('aggregateDetail(40000 rows × 5 fields): ${sw.elapsedMilliseconds}ms');

    expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
        reason: '聚合一趟完成：4 万行应在时限内返回（实际 ${sw.elapsedMilliseconds}ms）');
    expect(stats, hasLength(5));

    final amt = stats[0] as AmountFieldStats;
    expect(amt.filledCount, expectFilled);
    expect(amt.totalCount, rowCount);
    expect(amt.valueSum, closeTo(expectSum, 0.001));
    expect(amt.dist.map((b) => b.count).fold<int>(0, (a, b) => a + b), expectFilled);

    final sel = stats[3] as TextLikeFieldStats;
    final selMap = {for (final v in sel.values) v.label: v.count};
    expect(selMap['a'], expectSelCount['a']);
    expect(selMap['b'], expectSelCount['b']);
  });
}
