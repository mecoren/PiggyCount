/// v47 迁移（周期账单模板级自定义字段值）语义：
///
/// - `recurring_transactions` 新增可空列 `template_field_values`
///   （{fieldSyncId: value} JSON 对象，生成实例时注入）；
/// - **纯新增、零回填**：存量行保持 NULL = 模板未配置字段值，导出结果
///   与 v46 逐字节一致。刻意不回填成 `{}` —— 那会让「旧快照无此键」与
///   「显式空对象」指纹不等价，引发永不收敛的假冲突（v45/v46 同款教训）。
///
/// in-memory db 由 create_all 建出 v47 全 schema，这里验证 DDL 形态与
/// 存量行零改动；onUpgrade 的 v47 块用 _addColumnIfMissing 幂等加列。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';

void main() {
  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  test('v47 schema：recurring_transactions 带可空 template_field_values 列',
      () async {
    final cols = await db
        .customSelect('PRAGMA table_info(recurring_transactions)')
        .get();
    final byName = {for (final r in cols) r.read<String>('name'): r};

    expect(byName.keys, contains('template_field_values'));
    // 必须可空：存量行不回填，NULL = 模板未配置任何字段值。
    expect(byName['template_field_values']!.read<int>('notnull'), 0);
  });

  test('存量行零改动：template_field_values 保持 NULL（不做 {} 回填）', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await db.customStatement(
        "INSERT INTO recurring_transactions "
        "(id, ledger_id, type, amount, frequency, interval, start_date) "
        "VALUES (1, 1, 'expense', 30.0, 'monthly', 1, "
        "strftime('%s', '2026-01-10 00:00:00'))");

    final row = (await db.select(db.recurringTransactions).get()).single;
    expect(row.templateFieldValues, isNull);
  });

  test('值经 codec 编解码：编码键序稳定、空 map 落 NULL', () async {
    // 模板值的唯一编码入口是 CustomFieldValueCodec（与交易值同款）：
    // encode 负责规范化 + 键序统一（同一份值任何设备得到逐字节相同 JSON）；
    // 「1/1.0 表示统一」由 canonical 层承担（指纹/差分用），JSON 存储层
    // 保留下 double 表示。
    final encoded =
        CustomFieldValueCodec.encode({'b': 1.0, 'a': 'x', 'c': 2.5});
    expect(encoded, '{"a":"x","b":1.0,"c":2.5}');
    expect(CustomFieldValueCodec.canonical({'b': 1, 'a': 'x'}), 'a=x\u0001b=1\u0001');

    expect(CustomFieldValueCodec.encode(const {}), isNull);
    expect(CustomFieldValueCodec.encode(null), isNull);

    final decoded = CustomFieldValueCodec.decode(encoded);
    expect(decoded['a'], 'x');
    expect(decoded['b'], 1.0);
  });
}
