/// D-3 回归测试：自定义字段值「**清空**」必须跨设备传播。
///
/// 缺陷形状与 D-2 同族、与 D-1 同构：
///   导出侧曾「仅非空才写键」→ 用户清空值后快照里**没有** `customValues` 键
///   → `_compareTx` 的「缺键不改动」守卫识别不到 → 而指纹仍按 canonical 比较
///   （有值 vs 空 → 不同）→ **指纹说不同、diff 说无变化**：
///     * 同步状态卡永久显示有差异，点「下载同步」一条都点不出来；
///     * 对端 merge-then-publish 会把云端覆盖回旧值，本端再同步时
///       **刚清空的值被静默恢复**（设备端实测：A 清空 16 个值 → B 同步后回传
///       → A 再同步 `修改=2×8`，16 个值全部回来了）。
///
/// 修法（见 `transactions_json.dart` 该键处注释）：导出侧**始终写键**，
/// 让「键是否存在」自然区分两种语义 ——
///   * 空对象 = 新版快照的「确无值」→ 按 ① 严格比较（可清空本地）；
///   * 缺键   = 真·旧快照（不认识该字段）→ 维持 ②「不改动本地已填值」。
///
/// 本文件锁定四件事：清空必须判 modified / 应用后真清掉且收敛 /
/// 旧快照缺键仍安全 / 解析层能把两者区分开（修复的枢轴）。
library;

import 'dart:convert';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/cloud/transactions_json.dart';
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

  Future<void> seedField() => db.into(db.customFieldDefinitions).insert(
        CustomFieldDefinitionsCompanion.insert(
          ledgerId: 1,
          name: '税费',
          fieldType: 'amount',
          syncId: const d.Value('cf-1'),
          sortOrder: const d.Value(0),
        ),
      );

  /// 本地交易。`valuesJson` 为 null = 该笔没有值（列 NULL）。
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

  /// 云端条目。`customValues` 为 null = 快照**未携带该键**（真·旧快照）。
  ImportTransaction cloudTx({Map<String, dynamic>? customValues}) =>
      ImportTransaction(
        type: 'expense',
        amount: 100,
        categoryName: '餐饮',
        categoryKind: 'expense',
        happenedAt: baseTime.toLocal(),
        syncId: 'tx-1',
        currencyCode: 'CNY',
        nativeAmount: 100,
        customValues: customValues,
      );

  /// 真实快照恒带全量分类/账户；缺了它们 modified 路径的
  /// `_resolveCategoryId` 会解析失败并清空本地外键，干扰本用例要守的字段。
  const importMeta = ImportData(
    categories: [
      ImportCategory(name: '餐饮', kind: 'expense', level: 2, sortOrder: 0),
    ],
    accounts: [ImportAccount(name: '现金', syncId: 'acc-cash')],
  );

  Future<String?> localValues() async =>
      (await (db.select(db.transactions)
                ..where((t) => t.syncId.equals('tx-1')))
              .getSingle())
          .customValuesJson;

  group('D-3 清空自定义字段值必须跨设备传播', () {
    test('【本修复的守门用例】A 清空后导出的快照，必须让 B 判出 modified', () async {
      // 这一条**必须走导出侧**才守得住 D-3：上面几条用"云端带显式空对象"
      // 在修复前也会通过（diff 侧的 `cloud.customValues != null` 本来就认
      // 空对象）—— 缺陷在于**导出从来没产出过这个空对象**。
      //
      // —— A 端（独立库）：本来有值，被用户清空（列 NULL） ——
      final dbA = PiggyDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => dbA.close());
      await dbA.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      await dbA.customStatement(
          "INSERT INTO categories (id, name, kind, level, sort_order, sync_id) "
          "VALUES (1, '餐饮', 'expense', 2, 0, 'cat-food')");
      await dbA.into(dbA.customFieldDefinitions).insert(
            CustomFieldDefinitionsCompanion.insert(
              ledgerId: 1,
              name: '税费',
              fieldType: 'amount',
              syncId: const d.Value('cf-1'),
              sortOrder: const d.Value(0),
            ),
          );
      await dbA.into(dbA.transactions).insert(TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 100,
            categoryId: const d.Value(1),
            happenedAt: d.Value(baseTime),
            syncId: const d.Value('tx-1'),
            currencyCode: const d.Value('CNY'),
            nativeAmount: const d.Value(100),
            customValuesJson: const d.Value(null), // 已被用户清空
          ));
      final fromA = await exportTransactionsJson(dbA, 1);

      // —— B 端：本地仍是旧值 ——
      await seedLedger();
      await seedField();
      await seedLocalTx(valuesJson: '{"cf-1":12.5}');

      final parsed = parseJsonToImportData(fromA.jsonStr);
      expect(parsed.transactions.single.customValues, isNotNull,
          reason: 'A 的快照必须显式表达"该行确无值"（空对象），'
              '否则 parse 出来是 null → diff 退回"缺键不改动"');
      expect(parsed.transactions.single.customValues, isEmpty);

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: parsed.transactions,
      );
      expect(preview!.modifiedCount, 1,
          reason: '导出侧若省掉空键，这里恒为 0 → 清空永不传播、且被回滚（D-3 本体）');
    });

    test('云端显式空对象 vs 本地有值 → 必须判 modified', () async {
      await seedLedger();
      await seedField();
      await seedLocalTx(valuesJson: '{"cf-1":12.5}');

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        // 新版快照的"清空"形态：显式空对象
        cloudTransactions: [cloudTx(customValues: const {})],
      );

      expect(preview, isNotNull);
      expect(preview!.modifiedCount, 1,
          reason: '清空必须被判 modified —— 否则该改动永不传播（且会被对端回滚）');
      expect(preview.changes.single.diffDetails.join(), contains('自定义字段值'));
    });

    test('应用后本地值真被清掉，且再 diff 为空（收敛）', () async {
      await seedLedger();
      await seedField();
      await seedLocalTx(valuesJson: '{"cf-1":12.5}');

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloudTx(customValues: const {})],
      );
      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview!.changes,
        importData: importMeta,
      );

      expect(CustomFieldValueCodec.decode(await localValues()), isEmpty,
          reason: '只检测不应用 = 每轮都提示有变更却点不下去，比不同步更差');

      final again = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloudTx(customValues: const {})],
      );
      expect(again!.isEmpty, isTrue,
          reason: '应用后必须收敛，否则每轮 merge-then-publish 反复覆盖。'
              '残留=${again.changes.map((e) => e.diffDetails).toList()}');
    });

    test('旧快照（缺键）仍不得清空本地已填值 —— 策略②的既有保障不能破', () async {
      await seedLedger();
      await seedField();
      await seedLocalTx(valuesJson: '{"cf-1":12.5}');

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloudTx(customValues: null)], // 真·旧快照
      );

      expect(preview!.isEmpty, isTrue,
          reason: '缺键 = 旧快照不认识该字段，不能因此判差异并抹掉本地已填值');
      expect(CustomFieldValueCodec.decode(await localValues()), {'cf-1': 12.5},
          reason: '本地已填值必须原样保留');
    });

    test('解析：空对象 → 空 map、缺键 → null（区分新旧快照的枢轴）', () async {
      final base = {
        'type': 'expense',
        'amount': 100.0,
        'happenedAt': baseTime.toUtc().toIso8601String(),
        'syncId': 'tx-1',
      };

      final withEmpty = parseJsonToImportData(jsonEncode({
        'items': [
          {...base, 'customValues': <String, dynamic>{}},
        ],
      }));
      expect(withEmpty.transactions.single.customValues, isNotNull,
          reason: '显式空对象必须保留为"非 null" —— 否则 diff 侧无从与旧快照区分');
      expect(withEmpty.transactions.single.customValues, isEmpty);

      final legacy = parseJsonToImportData(jsonEncode({
        'items': [base],
      }));
      expect(legacy.transactions.single.customValues, isNull,
          reason: '缺键必须落到 null（= 不改动），否则旧快照会抹掉本地已填值');
    });
  });
}
