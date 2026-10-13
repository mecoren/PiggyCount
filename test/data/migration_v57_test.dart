/// v57 迁移（自定义字段「必填」列 `custom_field_definitions.is_required`）语义：
///
/// - 新增列 `is_required`（INTEGER NOT NULL DEFAULT 0）：语义是「记账（手工
///   表单）提交时该字段必须已填」。**纯新增、零回填** —— 存量字段一律
///   DEFAULT 0 = 非必填，与 v54 options_json 同款防漂移范式。
/// - 迁移用 `_addColumnIfMissing` 幂等加列（重跑安全）。
///
/// in-memory db 由 create_all 建出 v57 全 schema（列已存在），这里验证 DDL
/// 形态、存量行默认值与仓储读写往返（含 updateDefinition 三态）。
/// SQL **不再另抄字面量**：直接引用 db.dart 顶部的公开常量（测试自己抄一份
/// 的话，改实现可以悄悄骗过测试）。
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

  Future<void> seedLedger() => db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

  test('迁移 SQL 常量形态：INTEGER NOT NULL DEFAULT 0（存量零回填即非必填）',
      () {
    expect(addCustomFieldIsRequiredSql, contains('is_required INTEGER'));
    expect(addCustomFieldIsRequiredSql.toUpperCase(), contains('NOT NULL'));
    expect(addCustomFieldIsRequiredSql.toUpperCase(), contains('DEFAULT 0'));
    expect(addCustomFieldIsRequiredSql, contains('custom_field_definitions'));
  });

  test('v57 schema：custom_field_definitions 带 is_required 列（NOT NULL '
      'DEFAULT 0）', () async {
    final cols = await db
        .customSelect('PRAGMA table_info(custom_field_definitions)')
        .get();
    final byName = {for (final r in cols) r.read<String>('name'): r};

    expect(byName.keys, contains('is_required'));
    expect(byName['is_required']!.read<int>('notnull'), 1);
    expect(byName['is_required']!.read<String>('dflt_value'), '0');
  });

  test('存量行零改动：默认 isRequired = false', () async {
    await seedLedger();
    await db.customStatement(
        "INSERT INTO custom_field_definitions (ledger_id, name, field_type, sort_order) "
        "VALUES (1, '税费', 'amount', 0)");

    final row = (await db.select(db.customFieldDefinitions).get()).single;
    expect(row.isRequired, isFalse);
  });

  test('仓储往返：createDefinition 可置必填，缺省非必填', () async {
    await seedLedger();
    final repo = LocalCustomFieldRepository(db, trackerGetter: () => null);

    final idRequired = await repo.createDefinition(
      ledgerId: 1,
      name: '税费',
      fieldType: CustomFieldType.amount,
      syncId: 'cf-1',
      isRequired: true,
    );
    expect((await repo.getDefinitionById(idRequired))!.isRequired, isTrue);

    final idOptional = await repo.createDefinition(
      ledgerId: 1,
      name: '备注值',
      fieldType: CustomFieldType.text,
      syncId: 'cf-2',
    );
    expect((await repo.getDefinitionById(idOptional))!.isRequired, isFalse);
  });

  test('updateDefinition 三态：null 不改动，显式 true/false 覆盖', () async {
    await seedLedger();
    final repo = LocalCustomFieldRepository(db, trackerGetter: () => null);
    final id = await repo.createDefinition(
      ledgerId: 1,
      name: '税费',
      fieldType: CustomFieldType.amount,
      syncId: 'cf-1',
      isRequired: true,
    );

    // null = 不改动（与 options 三态同款）。
    await repo.updateDefinition(id, name: '税费A');
    expect((await repo.getDefinitionById(id))!.isRequired, isTrue,
        reason: '未传 isRequired 时不得改动既有值');

    await repo.updateDefinition(id, isRequired: false);
    expect((await repo.getDefinitionById(id))!.isRequired, isFalse);

    await repo.updateDefinition(id, isRequired: true);
    expect((await repo.getDefinitionById(id))!.isRequired, isTrue);
  });
}
