import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync/sync_engine.dart';
import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

import '_fakes/fake_piggycount_cloud_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('导出快照包含 attachments 且顶层含官方 v8 键（budgets/recurring/exchangeRateOverrides）',
      () async {
    SharedPreferences.setMockInitialValues({});
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ct = ChangeTracker(db);
    final provider = FakePiggyCountCloudProvider();
    final engine = SyncEngine(
        db: db,
        provider: provider,
        changeTracker: ct,
        repo: LocalRepository(db, changeTracker: ct));

    final ledgerId = await db.into(db.ledgers).insert(
        LedgersCompanion.insert(name: 'L', syncId: const Value('L1')));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        name: 'C', kind: 'expense', syncId: const Value('C')));

    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 12.0,
            happenedAt: Value(DateTime.parse('2026-05-01T10:00:00Z')),
            syncId: const Value('tx-with-file'),
          ),
        );
    // 附件行（列名与 db.dart 一致）
    await db.customStatement(
      "INSERT INTO transaction_attachments (transaction_id, file_name, "
      "original_name, file_size, sort_order) VALUES (?, ?, ?, ?, ?)",
      [txId, 'receipt.jpg', 'receipt.jpg', 2048, 0],
    );

    // 带分类的预算 + 周期规则：验证 M13 的 categoryName 锚与 version=8
    await db.into(db.budgets).insert(BudgetsCompanion.insert(
          ledgerId: ledgerId,
          type: const Value('category'),
          categoryId: const Value(1),
          amount: 100.0,
          syncId: const Value('B1'),
        ));
    await db.into(db.recurringTransactions).insert(
          RecurringTransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 9.9,
            frequency: 'monthly',
            startDate: DateTime.parse('2026-05-01T00:00:00Z'),
            categoryId: const Value(1),
            syncId: const Value('R1'),
          ),
        );

    final json = await engine.debugExportLedgerJson(ledgerId);
    final decoded = jsonDecode(json) as Map<String, dynamic>;

    expect(decoded['version'], 9, reason: 'v9：引擎快照必须声明 v9（ledgerSyncId + 镜像删除门槛）');
    // v9：账本身份锚点必须随引擎快照传播
    expect(decoded['ledgerSyncId'], 'L1',
        reason: 'v9：顶层 ledgerSyncId 缺失会让恢复端无法回填 sync_id');
    expect(decoded.containsKey('budgets'), isTrue, reason: 'S5：预算键缺失');
    // M13：段键对齐官方导出器（解析器只认 'recurring'/'exchangeRateOverrides'）
    expect(decoded.containsKey('recurring'), isTrue,
        reason: 'M13：周期段键必须是官方的 recurring');
    expect(decoded.containsKey('recurrings'), isFalse,
        reason: 'M13：旧键 recurrings 会被解析器静默忽略，不得再产出');
    expect(decoded.containsKey('exchangeRateOverrides'), isTrue,
        reason: 'M13：汇率覆盖段键必须是官方的 exchangeRateOverrides');

    // M13：预算/周期的 categoryName 锚（解析器按 name 反查分类）
    final budgets =
        (decoded['budgets'] as List).cast<Map<String, dynamic>>();
    expect(budgets.single['categoryName'], 'C',
        reason: 'M13：category 预算缺 categoryName 会在恢复端降级为 total');
    final recurrings =
        (decoded['recurring'] as List).cast<Map<String, dynamic>>();
    expect(recurrings.single['categoryName'], 'C',
        reason: 'M13：周期规则缺 categoryName 会丢分类关联');

    final items = (decoded['items'] as List).cast<Map<String, dynamic>>();
    expect(items.single['attachments'], isA<List>(),
        reason: 'S5 核心：items 必须携带附件元数据');
    expect((items.single['attachments'] as List).single['fileName'],
        'receipt.jpg');
  });

  test('parseJsonToImportData 兼容旧引擎快照键名 recurrings/rateOverrides（M13 存量自愈）',
      () async {
    SharedPreferences.setMockInitialValues({});
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 模拟 M13 修复前上传的旧引擎快照：version=6 + 旧段键
    final legacy = jsonEncode({
      'version': 6,
      'ledgerName': 'Legacy',
      'currency': 'CNY',
      'count': 0,
      'accounts': [],
      'categories': [],
      'tags': [],
      'items': [],
      'budgets': [
        {'syncId': 'B1', 'type': 'total', 'amount': 50.0}
      ],
      'recurrings': [
        {
          'syncId': 'R1',
          'type': 'expense',
          'amount': 1.0,
          'frequency': 'monthly',
          'startDate': '2026-01-01T00:00:00.000Z',
        }
      ],
      'rateOverrides': [
        {'baseCurrency': 'USD', 'quoteCurrency': 'CNY', 'rate': '7.2'}
      ],
    });

    final parsed = parseJsonToImportData(legacy);
    expect(parsed.recurrings.single.syncId, 'R1',
        reason: '旧键 recurrings 必须仍能解析（存量云端快照自愈）');
    expect(parsed.rateOverrides.single.baseCurrency, 'USD',
        reason: '旧键 rateOverrides 必须仍能解析（存量云端快照自愈）');
    expect(parsed.budgets.single.syncId, 'B1');
  });
}
