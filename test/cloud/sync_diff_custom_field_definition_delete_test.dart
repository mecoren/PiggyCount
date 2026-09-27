/// D-4 回归测试：**删除自定义字段定义**必须跨设备传播。
///
/// 缺陷形状：全量恢复路径有 `_mirrorDeleteAbsentEntities`（version ≥ 8 门控，
/// 其中就含自定义字段分支），而**增量合并路径只调 `importCustomFields`**
/// （upsert-only、无删除分支）→ 对端已删的定义在本地"阴魂不散"。
/// 设备端实测：A 删 8 个定义 → B「下载同步」**零变更** → B merge-then-publish
/// 又把它们写回云端 → A 再同步时 8 个定义**全部回来**。
///
/// 本文件锁定三件事：
///   1. 云端缺席 + 本地有 syncId → 定义被删，**且引用它的值被连带清掉**
///      （合并路径的交易行是保留的，不像恢复路径整体重导 —— 不清就留孤儿键：
///      定义没了、值键既渲染不出又会让快照带幽灵字段）；
///   2. 旧快照（version null / < 8）→ **不删**（旧快照可能根本不携带
///      `customFields` 段，"云端缺席"不具备删除语义）；
///   3. 无 syncId 的本地新建字段 → **不删**（云端缺席不代表用户删过它）。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
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
    await db.customStatement(
        "INSERT INTO categories (id, name, kind, level, sort_order, sync_id) "
        "VALUES (1, '餐饮', 'expense', 2, 0, 'cat-food')");
  }

  Future<void> seedField({String? syncId = 'cf-1'}) =>
      db.into(db.customFieldDefinitions).insert(
            CustomFieldDefinitionsCompanion.insert(
              ledgerId: 1,
              name: '税费',
              fieldType: 'amount',
              syncId: d.Value(syncId),
              sortOrder: const d.Value(0),
            ),
          );

  Future<void> seedLocalTx({String? valuesJson}) async =>
      db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 100,
            categoryId: const d.Value(1),
            happenedAt: d.Value(baseTime),
            syncId: const d.Value('tx-1'),
            currencyCode: const d.Value('CNY'),
            nativeAmount: const d.Value(100),
            customValuesJson: d.Value(valuesJson),
          ));

  Future<int> defCount() async =>
      (await db.select(db.customFieldDefinitions).get()).length;

  Future<String?> localValues() async =>
      (await (db.select(db.transactions)
                ..where((t) => t.syncId.equals('tx-1')))
              .getSingle())
          .customValuesJson;

  /// 云端快照的元数据段。`customFields` 默认空 = 云端已经不携带该定义。
  const importMeta = ImportData(
    categories: [
      ImportCategory(name: '餐饮', kind: 'expense', level: 2, sortOrder: 0),
    ],
    accounts: [ImportAccount(name: '现金', syncId: 'acc-cash')],
  );

  group('D-4 删除字段定义必须跨设备传播', () {
    test('云端缺席 + 本地有 syncId → 定义被删，且值被连带清掉（不留孤儿键）', () async {
      await seedLedger();
      await seedField(); // 本地有 syncId 的定义
      await seedLocalTx(valuesJson: '{"cf-1":12.5}');

      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: const [], // 定义合并与交易差异无关
        importData: const ImportData(
          version: 8,
          categories: [
            ImportCategory(name: '餐饮', kind: 'expense', level: 2, sortOrder: 0),
          ],
          accounts: [ImportAccount(name: '现金', syncId: 'acc-cash')],
        ),
      );

      expect(await defCount(), 0,
          reason: '云端已删且快照是 v8+ → 必须镜像删除，'
              '否则"删掉的字段又出现"，且会被对端回传写回云端');
      expect(CustomFieldValueCodec.decode(await localValues()), isEmpty,
          reason: '合并路径的交易行是保留的，值必须被连带清掉，'
              '否则留下孤儿键（定义没了，键渲染不出、只污染快照）');
    });

    test('旧快照（缺 version / version < 8）→ 不删（云端缺席不具删除语义）', () async {
      await seedLedger();
      await seedField();
      await seedLocalTx(valuesJson: '{"cf-1":12.5}');

      // 旧客户端产物：不带 version，也不带 customFields 段
      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: const [],
        importData: importMeta,
      );

      expect(await defCount(), 1,
          reason: '旧快照"缺席"不等于"用户删过" —— 删了会毁掉本地字段定义');
      expect(CustomFieldValueCodec.decode(await localValues()), {'cf-1': 12.5},
          reason: '值也必须原样保留');

      // version=7（v8 门控之前）同样不删
      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: const [],
        importData: const ImportData(version: 7),
      );
      expect(await defCount(), 1);
    });

    test('无 syncId 的本地新建字段 → 不删（尚未上传，云端缺席不可信）', () async {
      await seedLedger();
      await seedField(syncId: null); // 本机新建、还没上传过
      await seedLocalTx();

      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: const [],
        importData: const ImportData(version: 8),
      );

      expect(await defCount(), 1,
          reason: '无 syncId = 本机新建，云端"缺席"不代表用户删过它（同 tags 的保守规则）');
    });

    test('云端仍在的定义 → 保留（不得误删）', () async {
      await seedLedger();
      await seedField();
      await seedLocalTx(valuesJson: '{"cf-1":12.5}');

      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: const [],
        importData: const ImportData(
          version: 8,
          customFields: [
            ImportCustomField(
                name: '税费', fieldType: 'amount', syncId: 'cf-1', sortOrder: 0),
          ],
        ),
      );

      expect(await defCount(), 1, reason: '云端还带着这个定义，不能删');
      expect(CustomFieldValueCodec.decode(await localValues()), {'cf-1': 12.5});
    });
  });
}
