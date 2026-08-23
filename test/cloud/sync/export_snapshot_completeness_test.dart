import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync/sync_engine.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

import '_fakes/fake_piggycount_cloud_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('导出快照包含 attachments 且顶层含 budgets/recurrings/rateOverrides 键',
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

    final json = await engine.debugExportLedgerJson(ledgerId);
    final decoded = jsonDecode(json) as Map<String, dynamic>;

    expect(decoded.containsKey('budgets'), isTrue, reason: 'S5：预算键缺失');
    expect(decoded.containsKey('recurrings'), isTrue, reason: 'S5：周期键缺失');
    expect(decoded.containsKey('rateOverrides'), isTrue,
        reason: 'S5：汇率覆盖键缺失');

    final items = (decoded['items'] as List).cast<Map<String, dynamic>>();
    expect(items.single['attachments'], isA<List>(),
        reason: 'S5 核心：items 必须携带附件元数据');
    expect((items.single['attachments'] as List).single['fileName'],
        'receipt.jpg');
  });
}
