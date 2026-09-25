/// v46 迁移（账本自定义字段）语义：
///
/// - 新增 `custom_field_definitions` 表（按账本独立的字段定义）；
/// - `transactions` 新增可空列 `custom_values_json`（{fieldSyncId: value}）；
/// - **纯新增、零回填**：存量行的值列保持 NULL = 该笔没有自定义字段值，
///   导出结果与 v45 逐字节一致。刻意不回填成 `{}` —— 那会让「旧快照无此键」
///   与「显式空对象」指纹不等价，引发永不收敛的假冲突（v45 同款教训）。
///
/// in-memory db 由 create_all 建出 v46 全 schema，这里验证 DDL 形态与
/// 存量行零改动；onUpgrade 的 v46 块与 onCreate 的索引保持同构。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';

import 'package:piggycount/data/db.dart';

void main() {
  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<void> seedLedger() => db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

  test('v46 schema：custom_field_definitions 表与列齐全', () async {
    final cols = await db
        .customSelect('PRAGMA table_info(custom_field_definitions)')
        .get();
    final byName = {for (final r in cols) r.read<String>('name'): r};

    expect(
      byName.keys,
      containsAll([
        'id',
        'ledger_id',
        'name',
        'field_type',
        'sort_order',
        'created_at',
        'sync_id',
        'updated_at',
      ]),
    );
    // ledger_id / name / field_type 必填（NOT NULL），其余可空或有默认。
    expect(byName['ledger_id']!.read<int>('notnull'), 1);
    expect(byName['name']!.read<int>('notnull'), 1);
    expect(byName['field_type']!.read<int>('notnull'), 1);
    expect(byName['sync_id']!.read<int>('notnull'), 0);
    expect(byName['updated_at']!.read<int>('notnull'), 0);
  });

  test('v46 schema：transactions 带可空 custom_values_json 列', () async {
    final cols =
        await db.customSelect('PRAGMA table_info(transactions)').get();
    final byName = {for (final r in cols) r.read<String>('name'): r};

    expect(byName.keys, contains('custom_values_json'));
    // 必须可空：存量行不回填，NULL = 该笔没有任何自定义字段值。
    expect(byName['custom_values_json']!.read<int>('notnull'), 0);
  });

  test('v46 索引：ledger 查询索引 + sync_id 唯一索引都在', () async {
    final idx = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='index' "
        "AND tbl_name='custom_field_definitions'").get();
    final names = idx.map((r) => r.read<String>('name')).toSet();

    expect(names, contains('idx_custom_field_definitions_ledger'));
    expect(names, contains('uq_custom_field_definitions_sync_id'));
  });

  test('v46 触发器：updated_at 触碰触发器随 v40 helper 建出', () async {
    final trg = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='trigger' "
        "AND name='trg_custom_field_definitions_touch_updated_at'").get();
    expect(trg, isNotEmpty);
  });

  test('存量行零改动：新列保持 NULL（不做 {} 回填）', () async {
    await seedLedger();
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount) "
        "VALUES (100, 1, 'expense', 12.0)");

    final row = (await db.select(db.transactions).get()).single;
    expect(row.customValuesJson, isNull);
  });

  test('字段定义可插入并读回（syncId 作为值键的锚点）', () async {
    await seedLedger();
    final id = await db.into(db.customFieldDefinitions).insert(
          CustomFieldDefinitionsCompanion.insert(
            ledgerId: 1,
            name: '税费',
            fieldType: 'amount',
            syncId: const Value('cf-sync-1'),
          ),
        );

    final row = await (db.select(db.customFieldDefinitions)
          ..where((f) => f.id.equals(id)))
        .getSingle();
    expect(row.name, '税费');
    expect(row.fieldType, 'amount');
    expect(row.syncId, 'cf-sync-1');
    expect(row.ledgerId, 1);
  });

  test('updated_at 触碰触发器：UPDATE 未显式写该列时自动盖章', () async {
    await seedLedger();
    final id = await db.into(db.customFieldDefinitions).insert(
          CustomFieldDefinitionsCompanion.insert(
            ledgerId: 1,
            name: '运费',
            fieldType: 'amount',
            syncId: const Value('cf-sync-2'),
          ),
        );
    final before = await (db.select(db.customFieldDefinitions)
          ..where((f) => f.id.equals(id)))
        .getSingle();
    expect(before.updatedAt, isNull);

    await (db.update(db.customFieldDefinitions)..where((f) => f.id.equals(id)))
        .write(const CustomFieldDefinitionsCompanion(name: Value('运费2')));

    final after = await (db.select(db.customFieldDefinitions)
          ..where((f) => f.id.equals(id)))
        .getSingle();
    expect(after.updatedAt, isNotNull);
  });
}
