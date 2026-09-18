/// REC-01/02/03/04 回归测试：周期实例去重键日期归一化 + 周期规则导入单条隔离。
///
/// 背景（docs/security-and-ui-audit-2026-08-22.md）：
/// - REC-01：JSON 导出 `.toUtc()` / 导入 `.toLocal()`，跨时区恢复时精确
///   毫秒匹配必然失配 → 去重键改为 (recurringId, 本地日历日)；
/// - REC-02：daily/weekly 首笔实例继承 startDate 时刻（非 0 点）→ 同日
///   归一后可与生成器 0 点系实例互相识别；
/// - REC-03：importRecurrings 原 try 包住整个循环，一条规则失败中断其后
///   全部规则 → 改为单条隔离；
/// - REC-04：导入前批量预加载去重键，循环内 O(1) 查内存（功能正确性由
///   本文件用例覆盖；批内去重为附带能力，单独验证）。
library;
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late DataImportService service;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = DataImportService();
  });

  tearDown(() async => db.close());

  Future<void> seedLedger() async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
  }

  Future<List<Transaction>> allTx() =>
      (db.select(db.transactions)..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  ImportRecurring dailyRule({String? syncId, String? note}) => ImportRecurring(
        syncId: syncId,
        type: 'expense',
        amount: 10,
        frequency: 'daily',
        interval: 1,
        startDate: DateTime(2026, 7, 1),
        note: note,
      );

  /// 导入一条规则并返回其本地 id
  Future<int> seedRule(String syncId, {String? note}) async {
    final map = await service.importRecurrings(
      repo,
      1,
      [dailyRule(syncId: syncId, note: note)],
      accountNameToId: {},
      categoryCache: {},
    );
    final id = map[syncId];
    expect(id, isNotNull, reason: '规则 $syncId 应导入成功');
    return id!;
  }

  group('REC-01/02: 周期实例去重按本地日历日归一', () {
    test('同日不同时刻判重命中(非 0 点实例 vs 0 点实例)', () async {
      await seedLedger();
      final ruleId = await seedRule('rec-1');

      // 模拟本机 generator 先生成一笔非 0 点实例(daily 首笔继承时刻)
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        happenedAt: DateTime(2026, 7, 1, 14, 30),
        recurringId: ruleId,
      );

      // 恢复侧同日 0 点实例 → 应被识别为重复跳过
      final r = await service.importTransactions(
        repo,
        1,
        [
          ImportTransaction(
            type: 'expense',
            amount: 10,
            happenedAt: DateTime(2026, 7, 1),
            recurringSyncId: 'rec-1',
            syncId: 'restore-1',
          ),
        ],
        accountNameToId: {},
        categoryCache: {},
        tagNameToId: {},
        recurringSyncIdToId: {'rec-1': ruleId},
      );
      expect(r.inserted, 0, reason: '同日历日实例应判重跳过');
      expect(r.skippedRecurring, 1);
      expect((await allTx()).length, 1);
    });

    test('不同日期不误判', () async {
      await seedLedger();
      final ruleId = await seedRule('rec-1');

      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        happenedAt: DateTime(2026, 7, 1, 14, 30),
        recurringId: ruleId,
      );

      final r = await service.importTransactions(
        repo,
        1,
        [
          ImportTransaction(
            type: 'expense',
            amount: 10,
            happenedAt: DateTime(2026, 7, 2),
            recurringSyncId: 'rec-1',
            syncId: 'restore-next-day',
          ),
        ],
        accountNameToId: {},
        categoryCache: {},
        tagNameToId: {},
        recurringSyncIdToId: {'rec-1': ruleId},
      );
      expect(r.inserted, 1, reason: '次日实例是真实新数据，不得误杀');
      expect(r.skippedRecurring, 0);
    });

    test('批内去重:同一批次两笔同日实例只落一笔(REC-04 附带能力)', () async {
      await seedLedger();
      final ruleId = await seedRule('rec-1');

      final r = await service.importTransactions(
        repo,
        1,
        [
          ImportTransaction(
            type: 'expense',
            amount: 10,
            happenedAt: DateTime(2026, 7, 1, 8, 0),
            recurringSyncId: 'rec-1',
            syncId: 'batch-a',
          ),
          ImportTransaction(
            type: 'expense',
            amount: 10,
            happenedAt: DateTime(2026, 7, 1, 9, 30),
            recurringSyncId: 'rec-1',
            syncId: 'batch-b',
          ),
        ],
        accountNameToId: {},
        categoryCache: {},
        tagNameToId: {},
        recurringSyncIdToId: {'rec-1': ruleId},
      );
      expect(r.inserted, 1);
      expect(r.skippedRecurring, 1, reason: 'flush 前第二笔也应命中批内集合');
    });
  });

  group('REC-05: 同日多笔合法交易不得凭同日键误杀', () {
    test('同日同金额但备注不同 → 两笔都落库(tx-hist-day-rent54 回归)', () async {
      await seedLedger();
      final ruleId = await seedRule('rec-1');

      // 本机 generator 先生成同日实例(00:00, 无备注)
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 3500,
        happenedAt: DateTime(2026, 8, 1),
        recurringId: ruleId,
      );

      // 源端快照携带同日不同备注的实例(08:00, 历史房租-54 场景)
      final r = await service.importTransactions(
        repo,
        1,
        [
          ImportTransaction(
            type: 'expense',
            amount: 3500,
            happenedAt: DateTime(2026, 8, 1, 8, 0),
            recurringSyncId: 'rec-1',
            syncId: 'rent-54',
            note: '历史房租-54',
          ),
        ],
        accountNameToId: {},
        categoryCache: {},
        tagNameToId: {},
        recurringSyncIdToId: {'rec-1': ruleId},
      );
      expect(r.inserted, 1, reason: '备注不同=同日多笔合法交易，必须落库');
      expect(r.skippedRecurring, 0);
      expect((await allTx()).length, 2);
    });

    test('同日同备注但金额不同 → 落库', () async {
      await seedLedger();
      final ruleId = await seedRule('rec-1');

      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 3500,
        happenedAt: DateTime(2026, 8, 1),
        recurringId: ruleId,
        note: '房租',
      );

      final r = await service.importTransactions(
        repo,
        1,
        [
          ImportTransaction(
            type: 'expense',
            amount: 2800,
            happenedAt: DateTime(2026, 8, 1, 12, 0),
            recurringSyncId: 'rec-1',
            syncId: 'rent-discount',
            note: '房租',
          ),
        ],
        accountNameToId: {},
        categoryCache: {},
        tagNameToId: {},
        recurringSyncIdToId: {'rec-1': ruleId},
      );
      expect(r.inserted, 1, reason: '金额不同=合法的多笔交易');
      expect(r.skippedRecurring, 0);
      expect((await allTx()).length, 2);
    });

    test('同日同金额同备注 → 仍判重(generator vs 源端同源实例)', () async {
      await seedLedger();
      final ruleId = await seedRule('rec-1', note: '房租');

      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 3500,
        happenedAt: DateTime(2026, 8, 1),
        recurringId: ruleId,
        note: '房租',
      );

      final r = await service.importTransactions(
        repo,
        1,
        [
          ImportTransaction(
            type: 'expense',
            amount: 3500,
            happenedAt: DateTime(2026, 8, 1, 8, 0),
            recurringSyncId: 'rec-1',
            syncId: 'restore-same',
            note: '房租',
          ),
        ],
        accountNameToId: {},
        categoryCache: {},
        tagNameToId: {},
        recurringSyncIdToId: {'rec-1': ruleId},
      );
      expect(r.inserted, 0, reason: '同源实例(amount+note相同)仍应判重');
      expect(r.skippedRecurring, 1);
      expect((await allTx()).length, 1);
    });

    test('同 syncId 重复恢复 → 按 syncId 判重跳过', () async {
      await seedLedger();
      final ruleId = await seedRule('rec-1');

      final r = await service.importTransactions(
        repo,
        1,
        [
          ImportTransaction(
            type: 'expense',
            amount: 10,
            happenedAt: DateTime(2026, 7, 1, 8, 0),
            recurringSyncId: 'rec-1',
            syncId: 'dup-1',
            note: 'A',
          ),
          ImportTransaction(
            type: 'expense',
            amount: 999,
            happenedAt: DateTime(2026, 7, 1, 9, 0),
            recurringSyncId: 'rec-1',
            syncId: 'dup-1',
            note: 'B',
          ),
        ],
        accountNameToId: {},
        categoryCache: {},
        tagNameToId: {},
        recurringSyncIdToId: {'rec-1': ruleId},
      );
      expect(r.inserted, 1, reason: '同 syncId=同一实体，第二次必须跳过');
      expect(r.skippedRecurring, 1);
      expect((await allTx()).length, 1);
    });
  });

  group('REC-03: 单条周期规则失败不中断其余规则', () {
    test('失败规则被跳过，其前后的规则正常入库并进入映射', () async {
      await seedLedger();
      final failingRepo = _FailOnNoteRepo(db, 'boom');

      final map = await service.importRecurrings(
        failingRepo,
        1,
        [
          dailyRule(syncId: 'r-ok1', note: 'fine1'),
          dailyRule(syncId: 'r-bad', note: 'boom'),
          dailyRule(syncId: 'r-ok2', note: 'fine2'),
        ],
        accountNameToId: {},
        categoryCache: {},
      );

      expect(map.containsKey('r-bad'), isFalse,
          reason: '失败规则的 syncId 不应进入映射');
      expect(map['r-ok1'], isNotNull, reason: '失败之前的规则应已入库');
      expect(map['r-ok2'], isNotNull,
          reason: '失败之后的规则必须继续导入(修复点)');
      final rules =
          await failingRepo.getRecurringTransactionsByLedger(1);
      expect(rules.length, 2);
    });

    test('下游交易:失败规则锚点以 null 落库，其余正常解析', () async {
      await seedLedger();
      final failingRepo = _FailOnNoteRepo(db, 'boom');

      final map = await service.importRecurrings(
        failingRepo,
        1,
        [
          dailyRule(syncId: 'r-ok1', note: 'fine1'),
          dailyRule(syncId: 'r-bad', note: 'boom'),
          dailyRule(syncId: 'r-ok2', note: 'fine2'),
        ],
        accountNameToId: {},
        categoryCache: {},
      );

      final d1 = DateTime(2026, 7, 10);
      final d2 = DateTime(2026, 7, 11);
      final d3 = DateTime(2026, 7, 12);
      final r = await service.importTransactions(
        failingRepo,
        1,
        [
          ImportTransaction(
              type: 'expense',
              amount: 1,
              happenedAt: d1,
              recurringSyncId: 'r-ok1'),
          ImportTransaction(
              type: 'expense',
              amount: 2,
              happenedAt: d2,
              recurringSyncId: 'r-bad'),
          ImportTransaction(
              type: 'expense',
              amount: 3,
              happenedAt: d3,
              recurringSyncId: 'r-ok2'),
        ],
        accountNameToId: {},
        categoryCache: {},
        tagNameToId: {},
        recurringSyncIdToId: map,
      );
      expect(r.inserted, 3, reason: '坏规则不阻断交易本身落库');

      final txs = await allTx();
      final byDate = {for (final t in txs) t.happenedAt: t};
      expect(byDate[d1]!.recurringId, map['r-ok1']);
      expect(byDate[d2]!.recurringId, isNull,
          reason: '失败规则的交易无锚点落库(已知语义，靠日志告警暴露)');
      expect(byDate[d3]!.recurringId, map['r-ok2']);
    });
  });
}

/// 在 addRecurringTransaction 时对指定 note 抛异常的仓储包装，
/// 用于模拟"某条周期规则落库失败"(REC-03)。
class _FailOnNoteRepo extends LocalRepository {
  final String failNote;

  _FailOnNoteRepo(super.db, this.failNote);

  @override
  Future<int> addRecurringTransaction({
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    String? note,
    required String frequency,
    required int interval,
    int? dayOfMonth,
    int? dayOfWeek,
    int? monthOfYear,
    required DateTime startDate,
    DateTime? endDate,
    bool enabled = true,
    String? syncId,
    String? currencyCode,
  }) async {
    if (note == failNote) {
      throw Exception('simulated rule failure for note=$failNote');
    }
    return super.addRecurringTransaction(
      ledgerId: ledgerId,
      type: type,
      amount: amount,
      categoryId: categoryId,
      accountId: accountId,
      toAccountId: toAccountId,
      note: note,
      frequency: frequency,
      interval: interval,
      dayOfMonth: dayOfMonth,
      dayOfWeek: dayOfWeek,
      monthOfYear: monthOfYear,
      startDate: startDate,
      endDate: endDate,
      enabled: enabled,
      syncId: syncId,
      currencyCode: currencyCode,
    );
  }
}
