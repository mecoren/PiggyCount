// v44 回收站（F1）行为回归：软删 / 列表 / 恢复 / 就地彻底删除 / 账本级清理。
//
// 这套断言钉的是"搬行而不是加列"这个设计的四条命门：
// 1. 软删后交易对所有既有读路径不可见（行真的不在了 → 余额/统计/预算/首页
//    列表自动正确，不依赖 75 处读路径各加一个 deleted_at IS NULL 谓词）；
// 2. 标签行与附件行原地保留（恢复才有得还，且 30 天附件文件 GC 以附件行为
//    引用依据，删了行就等于把用户的图删了）；
// 3. 恢复无损（除 updated_at 会被 trg_transactions_touch_updated_at 重新盖，
//    这是想要的：恢复后这笔应当重新推给对端）；
// 4. 彻底删除与账本级清理（删账本 / 清空）连带归档行与物理文件一起走。
library;

import 'dart:io';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/maintenance/orphan_scanner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late Directory tempDir;
  late Directory attDir;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    // 故意不注入 changeTracker —— 与 repositoryProvider 的装配一致。
    repo = LocalRepository(db);
    tempDir = await Directory.systemTemp.createTemp('recycle_bin_test');
    attDir = Directory('${tempDir.path}/attachments');
    await attDir.create(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(
      documents: tempDir.path,
      temporary: tempDir.path,
    );
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  Future<int> seedLedger(int id) async {
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: d.Value(id),
          name: '账本$id',
          syncId: d.Value('ledger-$id'),
        ));
    return id;
  }

  /// 建一笔带标签 + 附件（含物理文件）的交易，返回交易 id。
  Future<int> seedFullTx(int ledgerId, String syncId,
      {int? id, double amount = 88.5, String type = 'expense'}) async {
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            id: id == null ? const d.Value.absent() : d.Value(id),
            ledgerId: ledgerId,
            type: type,
            amount: amount,
            note: d.Value('晚餐 $syncId'),
            currencyCode: const d.Value('CNY'),
            happenedAt: d.Value(DateTime.utc(2026, 9, 19, 18)),
            syncId: d.Value(syncId),
          ),
        );
    final tagId = await db.into(db.tags).insert(TagsCompanion.insert(
          name: 'tag-$syncId',
          syncId: d.Value('tag-sync-$syncId'),
        ));
    await db.into(db.transactionTags).insert(
        TransactionTagsCompanion.insert(transactionId: txId, tagId: tagId));
    await db.into(db.transactionAttachments).insert(
          TransactionAttachmentsCompanion.insert(
            transactionId: txId,
            fileName: '$syncId.jpg',
            localSha256: d.Value('sha-$syncId'),
          ),
        );
    await File('${attDir.path}/$syncId.jpg').writeAsString('bytes');
    return txId;
  }

  Future<List<Transaction>> liveTxs({int? ledgerId}) {
    final q = db.select(db.transactions);
    if (ledgerId != null) q.where((t) => t.ledgerId.equals(ledgerId));
    return q.get();
  }

  test('软删：交易搬进归档表，标签/附件行与物理文件原地保留', () async {
    await seedLedger(2);
    final txId = await seedFullTx(2, 'tx-a');

    expect(await repo.softDeleteTransaction(txId), isTrue);

    expect(await liveTxs(), isEmpty, reason: '行必须真的不在 transactions 里');
    final archived = await repo.getDeletedTransactions();
    expect(archived.single.txId, txId);
    expect(archived.single.ledgerId, 2);
    expect(archived.single.syncId, 'tx-a');
    expect(archived.single.payload, contains('"amount":88.5'));

    expect(await db.select(db.transactionTags).get(), hasLength(1),
        reason: '标签行是恢复时要用的，删了就等于恢复后丢标签');
    expect(await db.select(db.transactionAttachments).get(), hasLength(1),
        reason: '30 天附件 GC 按附件行判存活，删行会连带删掉用户的图');
    expect(await File('${attDir.path}/tx-a.jpg').exists(), isTrue);
  });

  test('软删后对全部读路径不可见（列表 / 区间合计 / 带分类流）', () async {
    await seedLedger(2);
    final txId = await seedFullTx(2, 'tx-a', amount: 120);

    final (_, expenseBefore) = await repo.totalsInRange(
      ledgerId: 2,
      start: DateTime.utc(2026, 9, 1),
      end: DateTime.utc(2026, 9, 30),
    );
    expect(expenseBefore, 120);

    await repo.softDeleteTransaction(txId);

    expect(await repo.getTransactionsByLedger(2), isEmpty);
    expect(await repo.transactionsWithCategoryAll(ledgerId: 2).first, isEmpty);
    final (_, expenseAfter) = await repo.totalsInRange(
      ledgerId: 2,
      start: DateTime.utc(2026, 9, 1),
      end: DateTime.utc(2026, 9, 30),
    );
    expect(expenseAfter, 0, reason: '回收站里的钱不能还计入支出');
  });

  test('恢复：整行原样回到 transactions，标签/附件重新挂上', () async {
    await seedLedger(2);
    final txId = await seedFullTx(2, 'tx-a');
    final original = (await db.select(db.transactions).get()).single;

    await repo.softDeleteTransaction(txId);
    expect(await repo.restoreDeletedTransaction(txId), isTrue);

    final restored = (await (db.select(db.transactions)
              ..where((t) => t.id.equals(txId)))
            .get())
        .single;
    // 整行逐字段相等（drift 生成的 ==）。updated_at 例外：
    // trg_transactions_touch_updated_at 会在 INSERT 时重新盖一次，而恢复后
    // 这笔本就该重新推给对端 —— 那是想要的行为，不是失真。
    expect(restored.copyWith(updatedAt: d.Value(original.updatedAt)), original);

    expect(await repo.getDeletedTransactions(), isEmpty);
    expect(await db.select(db.transactionTags).get(), hasLength(1));
    expect(await db.select(db.transactionAttachments).get(), hasLength(1));
    expect(await File('${attDir.path}/tx-a.jpg').exists(), isTrue);
  });

  test('恢复遇到原 id 被占用则拒绝，归档行保留', () async {
    await seedLedger(2);
    final txId = await seedFullTx(2, 'tx-a');
    await repo.softDeleteTransaction(txId);

    // 非常规来源（导入/换库）把同一个 int id 占了
    await seedFullTx(2, 'tx-b', id: txId);

    expect(await repo.restoreDeletedTransaction(txId), isFalse,
        reason: '换 id 落回去等于把标签/附件丢在原地，宁可拒绝');
    expect(await repo.getDeletedTransactions(), hasLength(1));
    expect(await db.select(db.transactions).get(), hasLength(1),
        reason: '拒绝恢复不能顺手把占用者删掉');
  });

  test('就地彻底删除：归档行 + 标签行 + 附件行 + 物理文件一起走', () async {
    await seedLedger(2);
    final txId = await seedFullTx(2, 'tx-a');
    await repo.softDeleteTransaction(txId);

    await repo.purgeDeletedTransaction(txId);

    expect(await repo.getDeletedTransactions(), isEmpty);
    expect(await db.select(db.transactionTags).get(), isEmpty);
    expect(await db.select(db.transactionAttachments).get(), isEmpty);
    expect(await File('${attDir.path}/tx-a.jpg').exists(), isFalse,
        reason: '彻底删除必须连文件一起清，否则就是磁盘泄漏');
  });

  test('删除账本连带清空其回收站条目，不影响其他账本', () async {
    await seedLedger(2);
    await seedLedger(3);
    final doomed = await seedFullTx(2, 'tx-a');
    final kept = await seedFullTx(3, 'tx-b');

    await repo.softDeleteTransaction(doomed);
    await repo.softDeleteTransaction(kept);
    expect(await repo.getDeletedTransactions(), hasLength(2));

    await repo.deleteLedger(2);

    final left = await repo.getDeletedTransactions();
    expect(left.single.txId, kept);
    expect(left.single.ledgerId, 3);
    expect(await db.select(db.transactionAttachments).get(), hasLength(1),
        reason: '账本 3 的归档附件行不能被子级联误删');
  });

  test('清空账本连带清空其回收站条目（无 tracker 分支同样生效）', () async {
    await seedLedger(2);
    final archived = await seedFullTx(2, 'tx-a');
    await seedFullTx(2, 'tx-b');

    await repo.softDeleteTransaction(archived);
    expect(await repo.getDeletedTransactions(ledgerId: 2), hasLength(1));

    await repo.clearLedgerTransactions(2);

    expect(await liveTxs(ledgerId: 2), isEmpty);
    expect(await repo.getDeletedTransactions(), isEmpty,
        reason: '清空后还能从垃圾箱捞回来 = 没清空');
  });

  test('软删不存在的交易返回 false（不抛）', () async {
    expect(await repo.softDeleteTransaction(9999), isFalse);
    expect(await repo.restoreDeletedTransaction(9999), isFalse);
    await repo.purgeDeletedTransaction(9999);
    expect(await repo.getDeletedTransactions(), isEmpty);
  });

  test('回收站里的附件/标签行不被孤儿扫描当成孤儿', () async {
    await seedLedger(2);
    final txId = await seedFullTx(2, 'tx-a');
    await repo.softDeleteTransaction(txId);

    final scanner = OrphanScanner(db: db);
    expect(await scanner.scanAttachmentMissingTx(), isEmpty,
        reason: '报成孤儿 → 清理页会把恢复要用的附件行删掉');
    expect(await scanner.scanTxTagMissingTx(), isEmpty);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String documents;
  final String temporary;
  _FakePathProvider({required this.documents, required this.temporary});

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getTemporaryPath() async => temporary;
}
