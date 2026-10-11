/// v54 迁移（自定义字段「单选/多选」选项列）语义：
///
/// - `custom_field_definitions` 新增可空列 `options_json`（JSON 字符串数组，
///   仅 singleSelect / multiSelect 使用）；
/// - **纯新增、零回填**：存量行（amount / text / date）保持 NULL = 无选项，
///   导出结果与 v53 逐字节一致（导出侧按「无选项」写空数组）。
///
/// in-memory db 由 create_all 建出 v54 全 schema，这里验证 DDL 形态与存量行
/// 零改动；onUpgrade 的 v54 块用 _addColumnIfMissing 幂等加列。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/data/repositories/local/local_custom_field_repository.dart';

void main() {
  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  test('v54 schema：custom_field_definitions 带可空 options_json 列', () async {
    final cols = await db
        .customSelect('PRAGMA table_info(custom_field_definitions)')
        .get();
    final byName = {for (final r in cols) r.read<String>('name'): r};

    expect(byName.keys, contains('options_json'));
    // 必须可空：存量行不回填，NULL = 无选项。
    expect(byName['options_json']!.read<int>('notnull'), 0);
  });

  test('存量行零改动：options_json 保持 NULL（不做 [] 回填）', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await db.customStatement(
        "INSERT INTO custom_field_definitions (ledger_id, name, field_type, sort_order) "
        "VALUES (1, '税费', 'amount', 0)");

    final row = (await db.select(db.customFieldDefinitions).get()).single;
    expect(row.optionsJson, isNull);
  });

  test('选项经 codec 编解码：空 → NULL，有值 → JSON 数组', () async {
    final repo = LocalCustomFieldRepository(db, trackerGetter: () => null);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    final id = await repo.createDefinition(
      ledgerId: 1,
      name: '状态',
      fieldType: CustomFieldType.singleSelect,
      options: ['已报销', '未报销'],
    );
    final row = await repo.getDefinitionById(id);
    expect(row!.optionsJson, '["已报销","未报销"]');
    expect(CustomFieldOptionsCodec.decode(row.optionsJson), ['已报销', '未报销']);

    // 空选项 → 列写 NULL。
    await repo.updateDefinition(id, options: const []);
    expect((await repo.getDefinitionById(id))!.optionsJson, isNull);
  });
}
