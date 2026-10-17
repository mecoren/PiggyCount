/// 设备真实引擎上的回收站闭环（E2）。
///
/// 覆盖「软删 → 主表不可见 / 回收站可见 → 恢复整行回来 → 再次软删 →
/// 彻底删除」这条高风险链路。宿主侧已有
/// `test/data/recycle_bin_round_trip_test.dart` 的详细字段比对；这里只把
/// 关键闭环搬到设备实际加载的 SQLite 引擎上跑一遍，防止「宿主内存库绿、
/// 设备引擎行为不同」的漏网。
///
/// 运行：
/// ```
/// flutter test integration_test/recycle_bin_device_test.dart -d <device>
/// ```
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
  });

  tearDown(() async => db.close());

  testWidgets('软删 → 回收站 → 恢复 → 彻底删除在设备引擎上闭环', (tester) async {
    final food = await db.into(db.categories).insert(
        CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 30,
            note: const d.Value('午饭'),
            categoryId: d.Value(food),
            happenedAt: d.Value(DateTime(2026, 10, 1, 12)),
          ),
        );

    // 1) 软删：主表不可见，回收站可见。
    expect(await repo.softDeleteTransaction(txId), isTrue);
    expect(await repo.getTransactionsByLedger(1), isEmpty,
        reason: '软删后交易不能再出现在主表读路径');
    final deleted = await repo.getDeletedTransactions(ledgerId: 1);
    expect(deleted.map((d) => d.txId), contains(txId));

    // 2) 恢复：整行回到主表，关键字段原样。
    expect(await repo.restoreDeletedTransaction(txId), isTrue);
    final restored = (await repo.getTransactionsByLedger(1)).single;
    expect(restored.id, txId);
    expect(restored.note, '午饭');
    expect(restored.amount, 30);
    expect(restored.categoryId, food);
    expect(await repo.getDeletedTransactions(ledgerId: 1), isEmpty);

    // 3) 再软删 + 彻底删除：两张表都不留残留。
    expect(await repo.softDeleteTransaction(txId), isTrue);
    await repo.purgeDeletedTransaction(txId);
    expect(await repo.getTransactionsByLedger(1), isEmpty);
    expect(await repo.getDeletedTransactions(ledgerId: 1), isEmpty);
  });

  testWidgets('恢复时原 id 被占用 → 拒绝且不误删占用者', (tester) async {
    final first = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 10,
            happenedAt: d.Value(DateTime(2026, 10, 1)),
          ),
        );
    expect(await repo.softDeleteTransaction(first), isTrue);

    // 用同 id 插一笔「占用者」（模拟恢复前 id 已被新数据复用）。
    await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            id: d.Value(first),
            ledgerId: 1,
            type: 'expense',
            amount: 99,
            happenedAt: d.Value(DateTime(2026, 10, 2)),
          ),
        );

    expect(await repo.restoreDeletedTransaction(first), isFalse,
        reason: 'id 被占用时必须拒绝恢复');
    final occupant = (await repo.getTransactionsByLedger(1)).single;
    expect(occupant.id, first);
    expect(occupant.amount, 99, reason: '拒绝恢复不得动到占用者');
    expect((await repo.getDeletedTransactions(ledgerId: 1)).length, 1,
        reason: '拒绝恢复后，回收站条目应原样保留');
  });
}
