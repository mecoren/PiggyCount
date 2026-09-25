/// v46 自定义字段仓储契约（LocalCustomFieldRepository）。
///
/// 重点保护两件事：
/// 1. **按账本隔离**：账本 A 的字段在账本 B 不可见、不可撞名；
/// 2. **值的三态语义**：null = 不改动、空 map = 清空、非空 = 覆盖 ——
///    批量改备注/改分类这类"不涉及自定义字段"的路径绝不能顺手清空值。
///
/// tracker 注入 null（快照链路正常装配就是无 tracker）：变更登记路径
/// 必须优雅跳过，不得抛。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/exceptions.dart';
import 'package:piggycount/data/repositories/local/local_custom_field_repository.dart';

void main() {
  late PiggyDatabase db;
  late LocalCustomFieldRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalCustomFieldRepository(db, trackerGetter: () => null);
  });

  tearDown(() async => db.close());

  Future<void> seedLedgers() async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'A', 'CNY')");
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (2, 'B', 'CNY')");
  }

  Future<int> seedTx(int id, int ledgerId, {String? valuesJson}) async {
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, custom_values_json) "
        "VALUES ($id, $ledgerId, 'expense', 10.0, ${valuesJson == null ? 'NULL' : "'$valuesJson'"})");
    return id;
  }

  group('字段定义 CRUD', () {
    test('创建：自动补 syncId，可按账本读回', () async {
      await seedLedgers();
      final id = await repo.createDefinition(
          ledgerId: 1, name: '税费', fieldType: 'amount');

      final row = await repo.getDefinitionById(id);
      expect(row, isNotNull);
      expect(row!.name, '税费');
      expect(row.fieldType, 'amount');
      expect(row.ledgerId, 1);
      expect(row.syncId, isNotNull);
      expect(row.syncId!.isNotEmpty, isTrue);
    });

    test('同账本撞同名抛 DuplicateNameException', () async {
      await seedLedgers();
      await repo.createDefinition(ledgerId: 1, name: '税费', fieldType: 'amount');

      expect(
        () => repo.createDefinition(
            ledgerId: 1, name: '税费', fieldType: 'text'),
        throwsA(isA<DuplicateNameException>()),
      );
    });

    test('不同账本可以同名（按账本隔离）', () async {
      await seedLedgers();
      final a = await repo.createDefinition(
          ledgerId: 1, name: '税费', fieldType: 'amount');
      final b = await repo.createDefinition(
          ledgerId: 2, name: '税费', fieldType: 'text');

      expect(a, isNot(b));
      expect(await repo.getDefinitionsForLedger(1), hasLength(1));
      expect(await repo.getDefinitionsForLedger(2), hasLength(1));
    });

    test('改名撞同账本已有名抛异常；改成新名成功', () async {
      await seedLedgers();
      await repo.createDefinition(ledgerId: 1, name: '税费', fieldType: 'amount');
      final id2 = await repo.createDefinition(
          ledgerId: 1, name: '运费', fieldType: 'amount');

      expect(
        () => repo.updateDefinition(id2, name: '税费'),
        throwsA(isA<DuplicateNameException>()),
      );

      await repo.updateDefinition(id2, name: '物流费');
      expect((await repo.getDefinitionById(id2))!.name, '物流费');
    });

    test('排序：updateDefinitionSortOrders 后按 sortOrder 返回', () async {
      await seedLedgers();
      final a = await repo.createDefinition(
          ledgerId: 1, name: 'A', fieldType: 'text');
      final b = await repo.createDefinition(
          ledgerId: 1, name: 'B', fieldType: 'text');
      final c = await repo.createDefinition(
          ledgerId: 1, name: 'C', fieldType: 'text');

      // 反序：C, A, B
      await repo.updateDefinitionSortOrders([
        (id: c, sortOrder: 0),
        (id: a, sortOrder: 1),
        (id: b, sortOrder: 2),
      ]);

      final list = await repo.getDefinitionsForLedger(1);
      expect(list.map((f) => f.name).toList(), ['C', 'A', 'B']);
    });

    test('isFieldNameDuplicate 支持排除自身', () async {
      await seedLedgers();
      final id = await repo.createDefinition(
          ledgerId: 1, name: '税费', fieldType: 'amount');

      expect(
          await repo.isFieldNameDuplicate(ledgerId: 1, name: '税费'), isTrue);
      expect(
          await repo.isFieldNameDuplicate(
              ledgerId: 1, name: '税费', excludeId: id),
          isFalse);
      expect(
          await repo.isFieldNameDuplicate(ledgerId: 2, name: '税费'), isFalse);
    });

    test('upsertDefinition：syncId 优先锚定，其次按名匹配', () async {
      await seedLedgers();
      final id = await repo.createDefinition(
          ledgerId: 1,
          name: '税费',
          fieldType: 'amount',
          syncId: 'cf-1');

      // 同 syncId 不同名 → 仍命中同一行（跨设备 rename 场景）
      final again = await repo.upsertDefinition(
          ledgerId: 1, name: '税', fieldType: 'amount', syncId: 'cf-1');
      expect(again, id);

      // 同名无 syncId → 命中已存在行，不新建
      final byName = await repo.upsertDefinition(
          ledgerId: 1, name: '税费', fieldType: 'amount');
      expect(byName, id);
      expect(await repo.getDefinitionsForLedger(1), hasLength(1));
    });
  });

  group('交易值读写（三态语义）', () {
    test('setValuesForTransaction(null) = 不改动', () async {
      await seedLedgers();
      final txId = await seedTx(100, 1, valuesJson: '{"cf-1":12.5}');

      await repo.setValuesForTransaction(txId, null);

      final values = await repo.getValuesForTransaction(txId);
      expect(values['cf-1'], 12.5);
    });

    test('setValuesForTransaction({}) = 清空（列写 NULL）', () async {
      await seedLedgers();
      final txId = await seedTx(100, 1, valuesJson: '{"cf-1":12.5}');

      await repo.setValuesForTransaction(txId, const {});

      expect(await repo.getValuesForTransaction(txId), isEmpty);
      final row =
          await (db.select(db.transactions)..where((t) => t.id.equals(txId)))
              .getSingle();
      expect(row.customValuesJson, isNull);
    });

    test('setValuesForTransaction(非空) = 覆盖写入', () async {
      await seedLedgers();
      final txId = await seedTx(100, 1, valuesJson: '{"cf-1":12.5}');

      await repo.setValuesForTransaction(txId, {'cf-1': 20.0, 'cf-2': 'note'});

      final values = await repo.getValuesForTransaction(txId);
      expect(values['cf-1'], 20.0);
      expect(values['cf-2'], 'note');
    });

    test('getValuesForTransactions 批量：无值交易不出现在结果里', () async {
      await seedLedgers();
      await seedTx(100, 1, valuesJson: '{"cf-1":1.0}');
      await seedTx(101, 1);
      await seedTx(102, 1, valuesJson: '{"cf-1":3.0}');

      final map = await repo.getValuesForTransactions([100, 101, 102]);
      expect(map.keys.toSet(), {100, 102});
      expect(map[100]!['cf-1'], 1.0);
    });

    test('countTransactionsWithValues 只数有值的行', () async {
      await seedLedgers();
      await seedTx(100, 1, valuesJson: '{"cf-1":1.0}');
      await seedTx(101, 1);
      await seedTx(102, 2, valuesJson: '{"cf-1":3.0}');

      expect(await repo.countTransactionsWithValues(1), 1);
      expect(await repo.countTransactionsWithValues(2), 1);
    });
  });

  group('删除定义连带清理值', () {
    test('删除字段时该账本下的值一并清掉，其他账本不受影响', () async {
      await seedLedgers();
      final id = await repo.createDefinition(
          ledgerId: 1, name: '税费', fieldType: 'amount', syncId: 'cf-1');
      await seedTx(100, 1, valuesJson: '{"cf-1":12.5,"cf-other":"keep"}');
      await seedTx(101, 1, valuesJson: '{"cf-1":1.0}');
      // 另一账本的同名 syncId 值不该被动
      await seedTx(200, 2, valuesJson: '{"cf-1":9.9}');

      await repo.deleteDefinition(id);

      expect(await repo.getDefinitionById(id), isNull);
      final v100 = await repo.getValuesForTransaction(100);
      expect(v100.containsKey('cf-1'), isFalse);
      expect(v100['cf-other'], 'keep'); // 其他字段的值保留
      expect(await repo.getValuesForTransaction(101), isEmpty);
      // 账本 2 的值不受影响
      expect((await repo.getValuesForTransaction(200))['cf-1'], 9.9);
    });
  });

  group('监听', () {
    test('watchDefinitionsForLedger 按 sortOrder 发射', () async {
      await seedLedgers();
      final a = await repo.createDefinition(
          ledgerId: 1, name: 'A', fieldType: 'text', sortOrder: 1);
      await repo.createDefinition(
          ledgerId: 1, name: 'B', fieldType: 'text', sortOrder: 0);

      final first = await repo.watchDefinitionsForLedger(1).first;
      expect(first.map((f) => f.name).toList(), ['B', 'A']);

      await repo.updateDefinitionSortOrders([(id: a, sortOrder: -1)]);
      final second =
          await repo.watchDefinitionsForLedger(1).firstWhere((l) => l.first.name == 'A');
      expect(second.first.name, 'A');
    });
  });
}
