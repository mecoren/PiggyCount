/// TBL-M3 补全回归测试：云端新账本导入路径的汇率覆盖 syncId 回写。
///
/// 背景：`restoreLedgerFromJson` 已有 `_restoreRateOverrideSyncIds` 回写
/// （审计 TBL-M3），但云端账本发现导入走的 `importTransactionsJson →
/// importRateOverrides` 只调 `setOverride`，行不存在时生成全新 UUID，
/// 两端汇率覆盖的 syncId 身份撕裂——未来任何按 syncId 做增量 diff 的
/// 功能都配不上对。本文件验证：
/// 1. 快照携带 syncId 时回写本地行（新导入 / 覆盖本地已有身份）；
/// 2. 行已存在且 syncId 一致时幂等不重写；
/// 3. rate 存储口径与导出端一致（'7.1' 而非 '7.100000'，#4 统一）。
library;
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';import 'package:flutter_test/flutter_test.dart';
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

  Future<ExchangeRateOverride?> overrideOf(String base, String quote) async {
    final rows = await (db.select(db.exchangeRateOverrides)
          ..where((t) =>
              t.baseCurrency.equals(base) & t.quoteCurrency.equals(quote)))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  // ignore: unused_element
  Future<List<ExchangeRateOverride>> allOverrides() =>
      (db.select(db.exchangeRateOverrides)
            ..orderBy([(t) => d.OrderingTerm.asc(t.id)]))
          .get();

  test('快照携带 syncId 时回写本地行（身份对齐，不生成新 UUID）', () async {
    await service.importRateOverrides(repo, [
      const ImportRateOverride(
        baseCurrency: 'usd',
        quoteCurrency: 'cny',
        rate: 7.1,
        syncId: 'snapshot-sync-id-1',
      ),
    ]);

    final row = await overrideOf('USD', 'CNY');
    expect(row, isNotNull);
    expect(row!.syncId, 'snapshot-sync-id-1',
        reason: '导入路径必须回写快照携带的 syncId（TBL-M3 同款），'
            '否则本地生成的新 UUID 与云端身份撕裂');
  });

  test('本地已有不同 syncId 的行时，覆盖为快照身份（云端即权威）', () async {
    // 先导入一次：本地行拿到快照身份 A
    await service.importRateOverrides(repo, [
      const ImportRateOverride(
        baseCurrency: 'USD',
        quoteCurrency: 'CNY',
        rate: 7.1,
        syncId: 'sync-id-a',
      ),
    ]);
    // 用户在本地改过：行身份被保留（setOverride 复用 existing.syncId）
    // 再从云端导入：syncId 应对齐快照携带的最新身份
    await service.importRateOverrides(repo, [
      const ImportRateOverride(
        baseCurrency: 'USD',
        quoteCurrency: 'CNY',
        rate: 7.2,
        syncId: 'sync-id-b',
      ),
    ]);

    final row = await overrideOf('USD', 'CNY');
    expect(row!.rate, '7.2');
    expect(row.syncId, 'sync-id-b',
        reason: '云端新账本导入场景，云端快照是权威身份');
  });

  test('快照 syncId 与本地行一致时幂等（不重写 updatedAt）', () async {
    await service.importRateOverrides(repo, [
      const ImportRateOverride(
        baseCurrency: 'USD',
        quoteCurrency: 'CNY',
        rate: 7.1,
        syncId: 'same-sync-id',
      ),
    ]);
    final first = await overrideOf('USD', 'CNY');
    // 再导入一次同身份同值：回写应跳过（row.syncId == sid）
    await service.importRateOverrides(repo, [
      const ImportRateOverride(
        baseCurrency: 'USD',
        quoteCurrency: 'CNY',
        rate: 7.1,
        syncId: 'same-sync-id',
      ),
    ]);
    final second = await overrideOf('USD', 'CNY');
    expect(second!.syncId, 'same-sync-id');
    expect(second.updatedAt, first!.updatedAt,
        reason: '幂等导入不应触碰 updatedAt（避免虚假“已变更”信号）');
  });

  test('rate 存储口径与导出端一致：7.1 存 \'7.1\' 而非 \'7.100000\'', () async {
    await service.importRateOverrides(repo, [
      const ImportRateOverride(
        baseCurrency: 'USD',
        quoteCurrency: 'CNY',
        rate: 7.1,
        syncId: 'r1',
      ),
      const ImportRateOverride(
        baseCurrency: 'EUR',
        quoteCurrency: 'CNY',
        rate: 7.812345,
        syncId: 'r2',
      ),
    ]);

    final usd = await overrideOf('USD', 'CNY');
    final eur = await overrideOf('EUR', 'CNY');
    expect(usd!.rate, '7.1',
        reason: '导入端此前 toStringAsFixed(6) 写 \'7.100000\'，'
            '与导出端 \'7.1\' 字面不一致');
    expect(eur!.rate, '7.812345');
  });
}
