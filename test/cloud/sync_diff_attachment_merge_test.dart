/// H1 回归测试：附件差异贯通 diff/merge。
///
/// 背景（审计 S11 的遗留半截）：指纹已纳入附件清单，但 computeDiff 不比较
/// 附件、modified 合并不写附件 —— 「只加/删/换附件」的变更被检测为
/// cloudNewer 后却合并不了任何东西，且 merge-then-publish 会把无附件快照
/// 回传覆盖云端，两台设备互相覆盖形成永久 ping-pong。
///
/// 修复后：
/// - computeDiff 对「仅附件不同」的交易产出 modified 变更（详情含"附件变更"）
/// - applySyncChanges 经 updateTransactionsBatchBySyncId 整体替换本地
///   transaction_attachments 行（快照全量清单语义：空表=显式清空）
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late SyncDiffService service;

  final baseTime = DateTime.utc(2026, 7, 1, 10, 0, 0);

  Future<int> insertLocalTx({
    required String syncId,
    List<({String fileName, String? sha})> attachments = const [],
  }) async {
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 12.5,
            happenedAt: d.Value(baseTime),
            syncId: d.Value(syncId),
          ),
        );
    for (final a in attachments) {
      await db.into(db.transactionAttachments).insert(
            TransactionAttachmentsCompanion.insert(
              transactionId: txId,
              fileName: a.fileName,
              localSha256: d.Value(a.sha),
              sortOrder: const d.Value(0),
            ),
          );
    }
    return txId;
  }

  ImportTransaction cloudTx({
    List<ImportAttachment>? attachments,
  }) =>
      ImportTransaction(
        type: 'expense',
        amount: 12.5,
        // 真实管线里 export 写 UTC ISO、parseJsonToImportData 转 toLocal，
        // drift 读回也是本地时区 —— 测试直接用 toLocal() 对齐墙钟，
        // 隔离出"只有附件不同"的目标场景。
        happenedAt: baseTime.toLocal(),
        syncId: 'tx-att-1',
        attachments: attachments,
      );

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = SyncDiffService();
  });

  tearDown(() async => db.close());

  Future<void> seedLedger() async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
  }

  test('computeDiff 检测出仅附件不同的交易（modified + 附件变更详情）', () async {
    await seedLedger();
    await insertLocalTx(
      syncId: 'tx-att-1',
      attachments: [(fileName: 'a.jpg', sha: 'hash-a')],
    );

    final preview = await service.computeDiff(
      repo: repo,
      ledgerId: 1,
      cloudTransactions: [
        cloudTx(attachments: [
          const ImportAttachment(fileName: 'b.jpg', sha256: 'hash-b'),
        ]),
      ],
    );

    expect(preview, isNotNull);
    expect(preview!.changes, hasLength(1));
    final change = preview.changes.single;
    expect(change.type, SyncChangeType.modified);
    expect(change.selected, isTrue, reason: 'modified 默认选中');
    expect(
      change.diffDetails.any((s) => s.contains('附件变更')),
      isTrue,
      reason: '交易标量字段完全一致时必须靠附件比较识别出 modified，'
          '否则附件-only 差异永远无法传播',
    );
  });

  test('applySyncChanges 用云端清单整体替换本地附件行', () async {
    await seedLedger();
    final txId = await insertLocalTx(
      syncId: 'tx-att-1',
      attachments: [
        (fileName: 'a.jpg', sha: 'hash-a'),
        (fileName: 'c.jpg', sha: 'hash-c'),
      ],
    );

    final result = await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: [
        SyncChange(
          type: SyncChangeType.modified,
          cloudTransaction: cloudTx(attachments: [
            const ImportAttachment(fileName: 'b.jpg', sha256: 'hash-b'),
          ]),
          localTransaction: await repo.getTransactionById(txId),
        ),
      ],
      importData: ImportData(transactions: []),
    );

    expect(result.totalCount, greaterThan(0));
    final atts = await (db.select(db.transactionAttachments)
          ..where((a) => a.transactionId.equals(txId)))
        .get();
    expect(atts, hasLength(1), reason: '本地清单必须被云端清单整体替换');
    expect(atts.single.fileName, 'b.jpg');
    expect(atts.single.localSha256, 'hash-b',
        reason: 'sha256 落 localSha256 列，供 attachments/<sha>.bin 后台补齐');
  });

  test('云端无附件（显式空表）→ 清空本地附件行（删除语义贯通）', () async {
    await seedLedger();
    final txId = await insertLocalTx(
      syncId: 'tx-att-1',
      attachments: [(fileName: 'a.jpg', sha: 'hash-a')],
    );

    await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: [
        SyncChange(
          type: SyncChangeType.modified,
          cloudTransaction: cloudTx(attachments: const []),
          localTransaction: await repo.getTransactionById(txId),
        ),
      ],
      importData: ImportData(transactions: []),
    );

    final atts = await (db.select(db.transactionAttachments)
          ..where((a) => a.transactionId.equals(txId)))
        .get();
    expect(atts, isEmpty,
        reason: '快照是全量清单：云端条目为空表代表显式删除，不是"保持原样"，'
            '否则 A 端删附件后 B 端永不收敛');
  });

  test('附件一致时不产生伪 modified（幂等收敛）', () async {
    await seedLedger();
    await insertLocalTx(
      syncId: 'tx-att-1',
      attachments: [(fileName: 'b.jpg', sha: 'hash-b')],
    );

    final preview = await service.computeDiff(
      repo: repo,
      ledgerId: 1,
      cloudTransactions: [
        cloudTx(attachments: [
          const ImportAttachment(fileName: 'b.jpg', sha256: 'hash-b'),
        ]),
      ],
    );

    expect(preview!.isEmpty, isTrue,
        reason: '合并应用后两端内容一致，再次检查不得再报 modified，'
            '否则 merge-then-publish 每轮都重复执行');
  });
}
