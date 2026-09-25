/// v47 周期账单模板级自定义字段值：生成器注入回归。
///
/// 锁死三件事：
/// 1. 配了模板值的周期账单，生成的实例**整包携带** custom_values_json；
/// 2. 未配置模板值（NULL）的周期账单，生成实例不得写空对象（列保持 NULL）；
/// 3. 注入走 setValuesForTransaction（v46 唯一写入口），编解码经统一 codec。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data/recurring_transaction_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;
  late int ledgerId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledgerId = await repo.createLedger(name: 'test', currency: 'CNY');
  });

  tearDown(() async {
    await db.close();
  });

  test('模板值注入：生成的实例携带 {fieldSyncId: value}', () async {
    final defId = await repo.createDefinition(
      ledgerId: ledgerId,
      name: '项目',
      fieldType: 'text',
    );
    final def = (await repo.getDefinitionById(defId))!;
    final amountDefId = await repo.createDefinition(
      ledgerId: ledgerId,
      name: '税费',
      fieldType: 'amount',
    );
    final amountDef = (await repo.getDefinitionById(amountDefId))!;

    await repo.addRecurringTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 30,
      frequency: 'monthly',
      interval: 1,
      dayOfMonth: DateTime.now().day,
      startDate: DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
      templateFieldValues: {
        def.syncId!: '房租',
        amountDef.syncId!: 12.5,
      },
    );

    final generated = await RecurringTransactionService(repo)
        .generatePendingTransactions();
    expect(generated, hasLength(1));

    final values = await repo.getValuesForTransaction(generated.first.id);
    expect(values[def.syncId], '房租');
    expect(values[amountDef.syncId], 12.5);
  });

  test('模板未配置值：生成实例的自定义值为空（NULL），不写空对象', () async {
    await repo.addRecurringTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 30,
      frequency: 'monthly',
      interval: 1,
      dayOfMonth: DateTime.now().day,
      startDate: DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
    );

    final generated = await RecurringTransactionService(repo)
        .generatePendingTransactions();
    expect(generated, hasLength(1));

    final values = await repo.getValuesForTransaction(generated.first.id);
    expect(values, isEmpty);
    final row =
        await (db.select(db.transactions)..where((t) => t.id.equals(generated.first.id)))
            .getSingle();
    expect(row.customValuesJson, isNull);
  });

  test('幽灵键防御：模板里已删定义的键不注入实例', () async {
    final defId = await repo.createDefinition(
      ledgerId: ledgerId,
      name: '项目',
      fieldType: 'text',
    );
    final def = (await repo.getDefinitionById(defId))!;
    final ghostId = await repo.createDefinition(
      ledgerId: ledgerId,
      name: '将删除',
      fieldType: 'text',
    );
    final ghost = (await repo.getDefinitionById(ghostId))!;

    await repo.addRecurringTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 30,
      frequency: 'monthly',
      interval: 1,
      dayOfMonth: DateTime.now().day,
      startDate:
          DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
      templateFieldValues: {def.syncId!: 'A', ghost.syncId!: '幽灵'},
    );
    // 删字段：本地路径会顺带清模板值（v47 strip），这里直接改库模拟
    // 「云端先删、模板还没被清」的在途状态。
    await repo.deleteDefinition(ghost.id);
    await db.customStatement(
        'UPDATE recurring_transactions SET template_field_values = ? '
        'WHERE ledger_id = $ledgerId',
        [CustomFieldValueCodec.encode({def.syncId!: 'A', ghost.syncId!: '幽灵'})]);

    final generated = await RecurringTransactionService(repo)
        .generatePendingTransactions();
    expect(generated, hasLength(1));

    final values = await repo.getValuesForTransaction(generated.first.id);
    expect(values, {def.syncId: 'A'},
        reason: '已删定义的幽灵键不得注入新实例');
  });
}
