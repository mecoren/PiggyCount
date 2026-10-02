/// D-1 / D-2 回归测试：「指纹已纳入、diff 却没比」的两处遗留半截。
///
/// 两处缺陷形状**相同**，也与审计 S11 的附件差异（指纹已纳入附件、computeDiff
/// 不比附件、merge-then-publish 互相覆盖形成永久 ping-pong）完全同构：
///
/// D-1 分类：`sync_fingerprint.dart` 早已把 `categoryName`/`categoryKind` 纳入
///     白名单，`_compareTx` 却不比较分类 →
///       * 「只改分类」在两台设备上表现为**指纹不一致但 diff 为空**：
///         同步状态卡永久显示「本地与云端有差异」，用户点「下载同步」一条变更
///         都点不出来，UI 无法自愈；
///       * merge-then-publish 会把本地旧分类回传覆盖云端 → 永久 ping-pong。
///
/// D-2 原始金额/折算金额：判定写成 `(local.originalAmount ?? 0) != cloud.…`，
///     把「本地未填写(null)」与「云端显式 0」判成相同 →
///       * 云端 0 永不落本地（0 是合法业务值：编辑器 `double.tryParse` 直接接受）；
///       * 导出侧 0 写键、null 不写键 → 两端指纹 '0.0' vs '' 不同 → 同样永不收敛。
///
/// 本文件同时锁定「**指纹口径与 diff 口径必须一致**」这一不变量：
/// 凡是进了指纹白名单的字段，diff 必须能把它判成 modified。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/cloud/sync_fingerprint.dart';
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

  /// 建两个 expense 分类：id=1 餐饮(id 供本地 tx 引用)、id=2 交通（云端目标）。
  Future<void> seedCategories() async {
    await db.customStatement(
        "INSERT INTO categories (id, name, kind, level, sort_order, sync_id) "
        "VALUES (1, '餐饮', 'expense', 2, 0, 'cat-food')");
    await db.customStatement(
        "INSERT INTO categories (id, name, kind, level, sort_order, sync_id) "
        "VALUES (2, '交通', 'expense', 2, 1, 'cat-trip')");
  }

  Future<int> insertLocalTx({
    String syncId = 'tx-1',
    int? categoryId,
    double amount = 100,
    double? originalAmount,
    double? nativeAmount,
    String type = 'expense',
  }) =>
      db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: 1,
            type: type,
            amount: amount,
            categoryId: d.Value(categoryId),
            happenedAt: d.Value(baseTime),
            syncId: d.Value(syncId),
            currencyCode: const d.Value('CNY'),
            nativeAmount: d.Value(nativeAmount ?? amount),
            originalAmount: d.Value(originalAmount),
          ));

  ImportTransaction cloudTx({
    String syncId = 'tx-1',
    String? categoryName,
    String? categoryKind,
    double amount = 100,
    double? originalAmount,
    double? nativeAmount,
    String type = 'expense',
  }) =>
      ImportTransaction(
        type: type,
        amount: amount,
        categoryName: categoryName,
        categoryKind: categoryKind,
        happenedAt: baseTime.toLocal(),
        syncId: syncId,
        currencyCode: 'CNY',
        nativeAmount: nativeAmount,
        originalAmount: originalAmount,
      );

  /// 快照里的分类清单（真实管线中每份快照都带全量 user-global 分类）。
  const importMeta = ImportData(categories: [
    ImportCategory(name: '餐饮', kind: 'expense', level: 2, sortOrder: 0),
    ImportCategory(name: '交通', kind: 'expense', level: 2, sortOrder: 1),
  ]);

  // ===================== D-1 分类 =====================
  group('D-1 分类变更必须跨设备传播', () {
    test('仅分类不同 → 产出 modified（详情含"分类"）', () async {
      await seedLedger();
      await seedCategories();
      await insertLocalTx(categoryId: 1); // 本地：餐饮

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        // 云端：交通（其余字段完全相同）
        cloudTransactions: [
          cloudTx(categoryName: '交通', categoryKind: 'expense'),
        ],
      );

      expect(preview, isNotNull);
      expect(preview!.modifiedCount, 1,
          reason: '仅改分类必须被识别为 modified，否则该变更永不跨设备传播');
      expect(preview.changes.single.diffDetails.join(), contains('分类'));
    });

    test('分类一致 → 不产生伪 modified（幂等收敛）', () async {
      await seedLedger();
      await seedCategories();
      await insertLocalTx(categoryId: 1);

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [
          cloudTx(categoryName: '餐饮', categoryKind: 'expense'),
        ],
      );

      expect(preview!.isEmpty, isTrue,
          reason: '分类相同时不得报差异，否则每轮 merge-then-publish 重复执行');
    });

    test('不同分类的 kind 不同也算差异（口径含 kind）', () async {
      await seedLedger();
      await seedCategories();
      await insertLocalTx(categoryId: 1); // expense

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [
          cloudTx(categoryName: '餐饮', categoryKind: 'income'),
        ],
      );

      expect(preview!.modifiedCount, 1,
          reason: '指纹按 (kind, name) 归集，diff 必须同口径');
    });

    test('transfer 行：本地残留 categoryId 不产生伪差异（与指纹的归空口径一致）',
        () async {
      await seedLedger();
      await seedCategories();
      // 转账行理论上不该有分类，但主表可能残留（本地新建路径不强制清空）
      await insertLocalTx(categoryId: 1, type: 'transfer');

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [
          // 导出侧**确实**对 transfer 归空（transactions_json.dart 的
          // `t.type == 'transfer' ? null : catInfo?[...]`）：categoryName/Kind
          // 都是 null。此前本行注释只是断言该行为、并无测试校验，导致导出侧
          // 漏归空（源端写 'Transfer'、恢复端写 null）长期无人发现 ——
          // 导出侧口径现由 transfer_category_snapshot_symmetry_test.dart 守门。
          cloudTx(type: 'transfer'),
        ],
      );

      expect(preview!.isEmpty, isTrue,
          reason: '导出与指纹对 transfer 一律归空，diff 也必须归空，'
              '否则转账行每轮都报一次假差异');
    });

    test('applySyncChanges 后本地分类落到云端分类，且再 diff 为空（收敛）',
        () async {
      await seedLedger();
      await seedCategories();
      final localId = await insertLocalTx(categoryId: 1);

      final cloud = cloudTx(categoryName: '交通', categoryKind: 'expense');
      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloud],
      );
      expect(preview!.modifiedCount, 1);

      final result = await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview.changes,
        importData: importMeta,
      );
      expect(result.modifiedCount, 1);

      final row = await (db.select(db.transactions)
            ..where((t) => t.id.equals(localId)))
          .getSingle();
      expect(row.categoryId, 2, reason: '本地分类必须被更新为云端的「交通」');

      final again = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloud],
      );
      expect(again!.isEmpty, isTrue,
          reason: '应用后必须收敛，否则 merge-then-publish 会每轮回传旧分类覆盖云端');
    });

    test('不变量：仅改分类必须改变指纹（指纹说不同，diff 就必须说出来）', () {
      Map<String, dynamic> payload(String name) => {
            'items': [
              {
                'happenedAt': '2026-07-01T10:00:00',
                'type': 'expense',
                'amount': 100,
                'categoryName': name,
                'categoryKind': 'expense',
              }
            ],
          };
      // 指纹确实把分类算进去（否则「只改分类」不会触发同步检测）
      expect(contentFingerprintFromMap(payload('餐饮')),
          isNot(equals(contentFingerprintFromMap(payload('交通')))));
    });
  });

  // ===================== D-2 0 值金额 =====================
  group('D-2 originalAmount / nativeAmount 的 0 值必须传播', () {
    test('云端显式 originalAmount=0、本地未填写(null) → modified', () async {
      await seedLedger();
      await insertLocalTx(); // original_amount = NULL

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloudTx(originalAmount: 0)],
      );

      expect(preview!.modifiedCount, 1,
          reason: '旧写法 (local ?? 0) != cloud 会把 NULL 与显式 0 判成相同，'
              '云端 0 永不下发；而两端指纹 "0.0" vs "" 不同 → 永久不收敛');
      expect(preview.changes.single.diffDetails.join(), contains('原始金额'));
    });

    test('云端显式 nativeAmount=0、本地未折算(null) → modified', () async {
      await seedLedger();
      await db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 100,
            happenedAt: d.Value(baseTime),
            syncId: const d.Value('tx-1'),
            currencyCode: const d.Value('CNY'),
            // native_amount 留空（NULL）
          ));

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloudTx(nativeAmount: 0)],
      );

      expect(preview!.modifiedCount, 1,
          reason: '同 originalAmount：?? 0 兜底会把显式 0 与 NULL 混淆');
      expect(preview.changes.single.diffDetails.join(), contains('折算金额'));
    });

    test('apply 后本地 original_amount 落到 0，再 diff 为空（收敛）', () async {
      await seedLedger();
      final localId = await insertLocalTx();

      final cloud = cloudTx(originalAmount: 0);
      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloud],
      );
      expect(preview!.modifiedCount, 1);

      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview.changes,
        importData: const ImportData(),
      );

      final row = await (db.select(db.transactions)
            ..where((t) => t.id.equals(localId)))
          .getSingle();
      expect(row.originalAmount, 0.0, reason: '0 是合法业务值，必须原样落库');

      final again = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloud],
      );
      expect(again!.isEmpty, isTrue, reason: '两端都是 0 后必须收敛');
    });

    test('回归：云端缺键(null) 不触发 modified（旧快照不得覆写本地已填值）',
        () async {
      await seedLedger();
      await insertLocalTx(originalAmount: 120); // 本地已填

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloudTx()], // 旧快照：缺 originalAmount 键
      );

      expect(preview!.isEmpty, isTrue,
          reason: '「本地已填 vs 云端无此键」不是差异；否则旧快照会把本地值抹平');
    });

    test('回归：本地 0、云端缺键(null) 也不触发（缺键语义是"不改动"）', () async {
      await seedLedger();
      await insertLocalTx(originalAmount: 0);

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloudTx()],
      );

      expect(preview!.isEmpty, isTrue);
    });
  });
}
