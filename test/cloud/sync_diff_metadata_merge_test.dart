/// account_metadata_sync_fix G1+G2 回归测试：
/// `SyncDiffService.applySyncChanges` 在交易 diff 为空（selectedChanges 为空）
/// 时，仍必须合并云端账户/分类/标签元数据。
///
/// 背景：下载链路为 downloadAndPreview → computeDiff（只比交易）→
/// applyPreviewChanges → applySyncChanges → importAccounts。当云端仅有账户
/// 变更而无交易变更时 diff 为空，若 applySyncChanges 对空变更早退，
/// importAccounts 永远不会被调用 —— 账户同步即断链。
///
/// sync_convergence_fix 追加：合并范围必须对齐指纹范围（8 类实体）。
/// 指纹覆盖 budgets/recurring/exchangeRateOverrides/monthStartDay，但
/// 合并只处理账户/分类/标签时，这些实体的云端差异永远不落本地 →
/// 本地指纹与云端永久不一致 → 每次启动都判 cloudNewer 反复弹
/// 「云端有更新」，下载却因交易无 diff 而"导入 0 条"。
library;

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

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = SyncDiffService();
  });

  tearDown(() async => db.close());

  test('selectedChanges 为空时仍导入云端账户（核心场景）', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    final result = await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: const [],
      importData: const ImportData(
        accounts: [
          ImportAccount(
            name: '理财账户',
            type: 'investment',
            initialBalance: 5000,
            syncId: 'acc-fin-001',
          ),
        ],
      ),
    );

    // 交易计数为 0，但账户必须已落地
    expect(result.totalCount, 0);
    final accounts = await repo.getAllAccounts();
    expect(accounts, hasLength(1),
        reason: '云端仅账户变更、交易无 diff 时，账户仍必须被合并到本地');
    expect(accounts[0].name, '理财账户');
    expect(accounts[0].syncId, 'acc-fin-001');
    expect(accounts[0].initialBalance, 5000);
  });

  test('空变更合并幂等：重复执行不产生重复账户', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    const importData = ImportData(
      accounts: [ImportAccount(name: '现金', syncId: 'acc-cash-001')],
    );

    await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: const [],
      importData: importData,
    );
    await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: const [],
      importData: importData,
    );

    final accounts = await repo.getAllAccounts();
    expect(accounts, hasLength(1),
        reason: '多账本下载循环会对同一份 user-global 账户重复合并，'
            'importAccounts 的 syncId/name 去重必须保证幂等');
  });

  test('空变更时也合并分类与标签元数据', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: const [],
      importData: const ImportData(
        categories: [
          ImportCategory(name: '餐饮', kind: 'expense', level: 1, sortOrder: 0),
        ],
        tags: [ImportTag(name: '报销', syncId: 'tag-001')],
      ),
    );

    final categories = await repo.getAllCategories();
    expect(categories.any((c) => c.name == '餐饮'), isTrue,
        reason: '分类与账户同理：元数据合并不应依赖交易 diff');
    final tags = await repo.getAllTags();
    expect(tags.any((t) => t.name == '报销'), isTrue);
  });

  test('空变更时也合并预算/周期规则/手动汇率/月起始日（指纹范围对齐）',
      () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    final result = await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: const [],
      // DateTime 非常量构造，ImportData 不能标 const
      importData: ImportData(
        categories: [
          ImportCategory(name: '餐饮', kind: 'expense', level: 1, sortOrder: 0),
        ],
        accounts: [ImportAccount(name: '现金', syncId: 'acc-cash-001')],
        budgets: [
          ImportBudget(
            syncId: 'bud-001',
            type: 'total',
            amount: 3000,
            period: 'monthly',
          ),
        ],
        recurrings: [
          ImportRecurring(
            syncId: 'rec-001',
            type: 'expense',
            amount: 100,
            note: '房租',
            frequency: 'monthly',
            dayOfMonth: 1,
            startDate: DateTime(2026, 1, 1),
          ),
        ],
        rateOverrides: [
          ImportRateOverride(baseCurrency: 'CNY', quoteCurrency: 'USD', rate: 7.2),
        ],
        monthStartDay: 15,
      ),
    );

    // 交易计数为 0，但指纹覆盖的 4 类元数据必须落地，
    // 否则本地指纹与云端永久不一致，启动检查死循环
    expect(result.totalCount, 0);
    final budgets = await repo.getAllBudgets(1);
    expect(budgets, hasLength(1), reason: '云端预算必须随下载合并落地');
    expect(budgets[0].syncId, 'bud-001');
    expect(budgets[0].amount, 3000);

    final recurrings = await repo.getRecurringTransactionsByLedger(1);
    expect(recurrings, hasLength(1), reason: '云端周期规则必须随下载合并落地');
    expect(recurrings[0].syncId, 'rec-001');
    expect(recurrings[0].amount, 100);

    final overrides = await repo.getOverrides('CNY');
    expect(overrides.any((o) => o.quoteCurrency == 'USD'), isTrue,
        reason: '云端手动汇率覆盖必须随下载合并落地');

    final ledger = await repo.getLedgerById(1);
    expect(ledger?.monthStartDay, 15,
        reason: '月起始日以云端快照为准回写（v8 G5 同语义）');
  });

  test('预算/周期规则合并幂等：重复执行不产生重复行', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    // DateTime 非常量构造，ImportData 不能标 const
    final importData = ImportData(
      categories: [
        ImportCategory(name: '餐饮', kind: 'expense', level: 1, sortOrder: 0),
      ],
      budgets: [
        ImportBudget(syncId: 'bud-001', type: 'total', amount: 3000),
      ],
      recurrings: [
        ImportRecurring(
          syncId: 'rec-001',
          type: 'expense',
          amount: 100,
          note: '房租',
          frequency: 'monthly',
          dayOfMonth: 1,
          startDate: DateTime(2026, 1, 1),
        ),
      ],
    );

    for (var i = 0; i < 2; i++) {
      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: const [],
        importData: importData,
      );
    }

    final budgets = await repo.getAllBudgets(1);
    expect(budgets, hasLength(1),
        reason: '多账本下载循环重复合并同一份云端数据，必须保持幂等');
    final recurrings = await repo.getRecurringTransactionsByLedger(1);
    expect(recurrings, hasLength(1));
  });

  test('transfer 类分类与本地同名共存：不抛 DuplicateNameException',
      () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    // 本地已有内置「转账」分类（kind=transfer）—— 旧实现建索引只查
    // expense/income，transfer 查不到 → 走 create → 撞 (name,kind)
    // 联合唯一约束 → 整个分类导入中止 → 指纹永不收敛
    await repo.createCategory(name: '转账', kind: 'transfer');

    final result = await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: const [],
      importData: const ImportData(
        categories: [
          ImportCategory(
              name: '转账', kind: 'transfer', level: 1, sortOrder: 0),
          ImportCategory(
              name: '餐饮', kind: 'expense', level: 1, sortOrder: 1),
        ],
      ),
    );

    expect(result.totalCount, 0);
    final all = await repo.getAllCategories();
    expect(all.where((c) => c.name == '转账'), hasLength(1),
        reason: '云端 transfer 分类必须命中本地同名行，而不是撞唯一约束');
    expect(all.where((c) => c.name == '餐饮'), hasLength(1),
        reason: '撞名前的异常中止会吞掉剩余分类导入，餐饮必须正常落地');
  });

  test('分类匹配后对齐云端 syncId（身份收敛，防指纹 ping-pong）', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    // 两台设备独立创建的同名分类各自持有不同 syncId → 指纹（含分类
    // syncId）永久不一致。合并时本地必须采纳云端身份
    await repo.createCategory(name: '餐饮', kind: 'expense', syncId: 'local-A');

    await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: const [],
      importData: const ImportData(
        categories: [
          ImportCategory(
              name: '餐饮',
              kind: 'expense',
              level: 1,
              sortOrder: 0,
              syncId: 'cloud-B'),
        ],
      ),
    );

    final all = await repo.getAllCategories();
    expect(all, hasLength(1), reason: '同名分类应命中而非新建');
    expect(all[0].syncId, 'cloud-B',
        reason: '本地 syncId 必须对齐云端，否则两端指纹永久不一致');
  });
}
