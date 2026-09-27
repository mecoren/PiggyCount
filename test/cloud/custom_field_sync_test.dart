/// v46 自定义字段的快照往返与指纹契约。
///
/// 覆盖三条最容易出事的路径：
/// 1. 导出：无值交易写**空对象** `customValues: {}`（**D-3 修复** —— 曾"仅非空
///    才写键"，导致用户清空自定义字段值的动作无法被快照表达：清空后键消失，
///    diff 的「缺键不改动」守卫识别不到，而指纹仍判不同 → 永久不收敛且会被
///    对端回滚。空对象与缺键的指纹相同，故不产生"缺失 vs 显式空"的分裂）；
/// 2. 解析：旧快照缺顶层 `customFields` / item 内缺 `customValues` 时优雅
///    降级为空（兼容旧客户端产物）；
/// 3. 指纹：**只**改自定义字段值或只改定义时，指纹必须变化 —— 否则
///    getStatus 判 inSync，改动永不跨设备传播（v45 踩过的坑）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';

import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  // exportTransactionsJson 会走 logger（LoggerService 单例在构造时挂
  // MethodChannel），裸 Dart 测试必须先初始化 binding，否则在
  // setMethodCallHandler 上断言失败。
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<void> seedLedger() => db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

  Future<void> seedField({String name = '税费', String type = 'amount'}) async {
    await db.into(db.customFieldDefinitions).insert(
          CustomFieldDefinitionsCompanion.insert(
            ledgerId: 1,
            name: name,
            fieldType: type,
            syncId: const Value('cf-1'),
            sortOrder: const Value(0),
          ),
        );
  }

  /// 插入一笔交易。
  ///
  /// `originalAmount` 显式写成本次 amount：v45 的两条路径口径是「每条明细都有
  /// 原始金额」（写入侧与快照导入侧都 `?? amount` 兜底），只有**导出侧**刻意
  /// 「仅非空才写键」。若这里留 null，A→B→A 往返会因为 B 端兜底填值而产生一次
  /// 指纹变化 —— 那是 v45 的既有行为，不是自定义字段引入的，别让它干扰本用例
  /// 要守的收敛性。
  Future<void> seedTx({
    required int id,
    required String syncId,
    String? valuesJson,
    double amount = 100.0,
  }) async {
    await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            id: Value(id),
            ledgerId: 1,
            type: 'expense',
            amount: amount,
            originalAmount: Value(amount),
            syncId: Value(syncId),
            customValuesJson: Value(valuesJson),
          ),
        );
  }

  Map<String, dynamic> payloadOf(String jsonStr) =>
      jsonDecode(jsonStr) as Map<String, dynamic>;

  group('导出', () {
    test('顶层带 customFields；有值交易带 customValues', () async {
      await seedLedger();
      await seedField();
      await seedTx(id: 100, syncId: 'tx-1', valuesJson: '{"cf-1":12.5}');

      final exported = await exportTransactionsJson(db, 1);
      final payload = payloadOf(exported.jsonStr);

      final fields = payload['customFields'] as List;
      expect(fields, hasLength(1));
      expect(fields.first['syncId'], 'cf-1');
      expect(fields.first['name'], '税费');
      expect(fields.first['fieldType'], 'amount');

      final items = payload['items'] as List;
      expect(items, hasLength(1));
      expect(items.first['customValues'], {'cf-1': 12.5});
    });

    test('无值交易写空对象（D-3：让「清空」可被快照表达）', () async {
      await seedLedger();
      await seedField();
      await seedTx(id: 100, syncId: 'tx-1');

      final exported = await exportTransactionsJson(db, 1);
      final items = payloadOf(exported.jsonStr)['items'] as List;

      // 不能省掉该键：省掉后「用户清空了值」与「真·旧快照不认识该字段」
      // 无法区分，diff 的「缺键不改动」会让清空永不传播（且被对端回滚）。
      expect(items.first.containsKey('customValues'), isTrue,
          reason: '缺键 = 旧快照；新版快照必须显式表达"确无值"');
      expect(items.first['customValues'], isEmpty);

      // 且空对象与缺键在指纹口径下等价 —— 这是"始终写键"不会引入
      // 「缺失 vs 显式空」永久 outOfSync 的前提。
      expect(
        CustomFieldValueCodec.canonical(const <String, dynamic>{}),
        CustomFieldValueCodec.canonical(null),
      );
    });

    test('定义为空 → customFields 为空数组（顶层键始终存在）', () async {
      await seedLedger();
      await seedTx(id: 100, syncId: 'tx-1');

      final exported = await exportTransactionsJson(db, 1);
      final payload = payloadOf(exported.jsonStr);

      expect(payload['customFields'], isEmpty);
      expect(payload['customFields'], isA<List>());
    });
  });

  group('解析', () {
    test('往返：定义与值都能解析回来', () async {
      await seedLedger();
      await seedField();
      await seedTx(id: 100, syncId: 'tx-1', valuesJson: '{"cf-1":12.5}');

      final exported = await exportTransactionsJson(db, 1);
      final parsed = parseJsonToImportData(exported.jsonStr);

      expect(parsed.customFields, hasLength(1));
      expect(parsed.customFields.first.syncId, 'cf-1');
      expect(parsed.customFields.first.name, '税费');
      expect(parsed.customFields.first.fieldType, 'amount');

      expect(parsed.transactions, hasLength(1));
      expect(parsed.transactions.first.customValues, {'cf-1': 12.5});
    });

    test('旧快照（无 customFields 顶层键 / item 无 customValues）→ 空，不报错',
        () async {
      await seedLedger();
      await seedTx(id: 100, syncId: 'tx-1');

      final exported = await exportTransactionsJson(db, 1);
      final payload = payloadOf(exported.jsonStr);
      payload.remove('customFields');
      for (final it in payload['items'] as List) {
        (it as Map).remove('customValues');
      }

      final parsed = parseJsonToImportData(jsonEncode(payload));
      expect(parsed.customFields, isEmpty);
      expect(parsed.transactions.first.customValues, isNull);
    });

    test('未知 fieldType 退回 text（渲染端不会拿到无输入分支的类型）', () async {
      await seedLedger();
      await seedTx(id: 100, syncId: 'tx-1');

      final exported = await exportTransactionsJson(db, 1);
      final payload = payloadOf(exported.jsonStr);
      payload['customFields'] = [
        {'syncId': 'cf-x', 'name': '未知类型', 'fieldType': 'weird', 'sortOrder': 0},
      ];

      final parsed = parseJsonToImportData(jsonEncode(payload));
      expect(parsed.customFields.single.fieldType, 'text');
    });

    test('customFields 缺 name 的条目被跳过并计入 skippedItems', () async {
      await seedLedger();
      await seedTx(id: 100, syncId: 'tx-1');

      final exported = await exportTransactionsJson(db, 1);
      final payload = payloadOf(exported.jsonStr);
      payload['customFields'] = [
        {'fieldType': 'amount'},
        {'name': '合法', 'fieldType': 'amount', 'syncId': 'cf-ok'},
      ];

      final parsed = parseJsonToImportData(jsonEncode(payload));
      expect(parsed.customFields, hasLength(1));
      expect(parsed.customFields.single.name, '合法');
      expect(parsed.skippedItems['customFields'], 1);
    });
  });

  group('内容指纹', () {
    test('「无 customValues 键」与「显式空对象」同指纹（兼容旧快照）', () async {
      await seedLedger();
      await seedField();
      await seedTx(id: 100, syncId: 'tx-1');

      final exported = await exportTransactionsJson(db, 1);
      // D-3 修复后，新版快照本身就带显式空对象；这里**手工去掉键**构造
      // "真·旧快照"作对照。两者同指纹，是"始终写键"不会引入
      // 「缺失 vs 显式空」永久 outOfSync 的前提（也是这条修复的安全依据）。
      final withEmpty = payloadOf(exported.jsonStr);
      final legacy = payloadOf(exported.jsonStr);
      for (final it in legacy['items'] as List) {
        (it as Map).remove('customValues');
      }

      expect((withEmpty['items'] as List).first['customValues'], isEmpty);
      expect(
          (legacy['items'] as List).first.containsKey('customValues'), isFalse);
      expect(contentFingerprintFromMap(legacy),
          contentFingerprintFromMap(withEmpty));
    });

    test('旧快照缺顶层 customFields 键 → 与空数组同指纹', () async {
      await seedLedger();
      await seedTx(id: 100, syncId: 'tx-1');

      final exported = await exportTransactionsJson(db, 1);
      final baseline = payloadOf(exported.jsonStr);
      final legacy = payloadOf(exported.jsonStr);
      legacy.remove('customFields');

      expect(contentFingerprintFromMap(legacy),
          contentFingerprintFromMap(baseline));
    });

    test('只改自定义字段值 → 指纹必须变化（否则永不传播）', () async {
      await seedLedger();
      await seedField();
      await seedTx(id: 100, syncId: 'tx-1', valuesJson: '{"cf-1":12.5}');

      final before =
          contentFingerprintFromMap(payloadOf((await exportTransactionsJson(db, 1)).jsonStr));

      await db.customStatement(
          "UPDATE transactions SET custom_values_json = '{\"cf-1\":99.0}' WHERE id = 100");

      final after =
          contentFingerprintFromMap(payloadOf((await exportTransactionsJson(db, 1)).jsonStr));

      expect(after, isNot(before));
    });

    test('只改定义（名称/类型/排序）→ 指纹必须变化', () async {
      await seedLedger();
      await seedField();
      await seedTx(id: 100, syncId: 'tx-1');

      final before =
          contentFingerprintFromMap(payloadOf((await exportTransactionsJson(db, 1)).jsonStr));

      await db.customStatement(
          "UPDATE custom_field_definitions SET name = '物流费' WHERE sync_id = 'cf-1'");

      final after =
          contentFingerprintFromMap(payloadOf((await exportTransactionsJson(db, 1)).jsonStr));

      expect(after, isNot(before));
    });

    test('自定义字段值键顺序抖动不产生假指纹差异', () async {
      await seedLedger();
      await seedField();
      await seedTx(id: 100, syncId: 'tx-1', valuesJson: '{"cf-1":1.0}');

      final exported = await exportTransactionsJson(db, 1);
      final reordered = payloadOf(exported.jsonStr);
      (reordered['items'] as List).first['customValues'] = {
        'cf-2': 'x',
        'cf-1': 1.0,
      };
      final other = payloadOf(exported.jsonStr);
      (other['items'] as List).first['customValues'] = {
        'cf-1': 1,
        'cf-2': 'x',
      };

      expect(contentFingerprintFromMap(reordered),
          contentFingerprintFromMap(other));
    });
  });

  group('端到端：双端快照往返', () {
    test('A 端导出 → B 端恢复 → B 端再导出：定义/值落库且指纹一致', () async {
      // —— A 端：有一个字段 + 一笔带值的交易 ——
      await seedLedger();
      await seedField();
      await seedTx(id: 100, syncId: 'tx-1', valuesJson: '{"cf-1":12.5}');
      final fromA = await exportTransactionsJson(db, 1);

      // —— B 端：独立库，先有同名空账本，再按快照恢复 ——
      final dbB = PiggyDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => dbB.close());
      await dbB.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final repoB = LocalRepository(dbB);

      await restoreLedgerFromJson(
        db: dbB,
        repo: repoB,
        ledgerId: 1,
        jsonStr: fromA.jsonStr,
      );

      // 定义落库（syncId 保留 = 交易值的键锚定不漂移）
      final defs = await dbB.select(dbB.customFieldDefinitions).get();
      expect(defs, hasLength(1));
      expect(defs.single.syncId, 'cf-1');
      expect(defs.single.name, '税费');
      expect(defs.single.fieldType, 'amount');

      // 值落库
      final txB = (await dbB.select(dbB.transactions).get()).single;
      expect(CustomFieldValueCodec.decode(txB.customValuesJson), {'cf-1': 12.5});

      // B 端再导出 → 与 A 端指纹逐位一致（收敛，无幻影差异）
      final fromB = await exportTransactionsJson(dbB, 1);

      // 失败时把逐字段差异打出来（收敛问题最难凭空猜）
      final pa = payloadOf(fromA.jsonStr);
      final pb = payloadOf(fromB.jsonStr);
      final ia = Map<String, dynamic>.from((pa['items'] as List).first as Map);
      final ib = Map<String, dynamic>.from((pb['items'] as List).first as Map);
      final diff = <String>[];
      for (final k in {...ia.keys, ...ib.keys}) {
        if ('${ia[k]}' != '${ib[k]}') diff.add('$k: ${ia[k]} vs ${ib[k]}');
      }
      for (final k in {...pa.keys, ...pb.keys}) {
        if (k == 'items' || k == 'contentFingerprint' || k == 'exportedAt') {
          continue;
        }
        if (jsonEncode(pa[k]) != jsonEncode(pb[k])) {
          diff.add('top-level $k: ${jsonEncode(pa[k])} vs ${jsonEncode(pb[k])}');
        }
      }
      expect(diff, isEmpty, reason: 'A/B 快照逐字段应一致');

      expect(fromB.fingerprint, fromA.fingerprint);
    });

    test('快照里云端删掉的字段定义，恢复时在本地镜像删除', () async {
      // 本地先有一个"云端已删"的字段（含 syncId，模拟曾经同步过）
      await seedLedger();
      await db.into(db.customFieldDefinitions).insert(
            CustomFieldDefinitionsCompanion.insert(
              ledgerId: 1,
              name: '已废弃字段',
              fieldType: 'text',
              syncId: const Value('cf-gone'),
            ),
          );
      await seedTx(id: 100, syncId: 'tx-1');

      // 云端快照里没有这个定义（只保留了同步 id，但字段不在）
      final snapshot = payloadOf((await exportTransactionsJson(db, 1)).jsonStr);
      snapshot['customFields'] = <Map<String, dynamic>>[];
      final jsonNoFields = jsonEncode(snapshot);

      await restoreLedgerFromJson(
        db: db,
        repo: LocalRepository(db),
        ledgerId: 1,
        jsonStr: jsonNoFields,
      );

      expect(await db.select(db.customFieldDefinitions).get(), isEmpty,
          reason: 'v8+ 快照是"真覆盖"：云端删掉的字段不能在本地阴魂不散');
    });

    test('无 syncId 的本地字段不被云端"缺席"误删', () async {
      await seedLedger();
      await db.into(db.customFieldDefinitions).insert(
            CustomFieldDefinitionsCompanion.insert(
              ledgerId: 1,
              name: '本地新建未上传',
              fieldType: 'text',
              // syncId 缺省 null：用户刚建、还没推过云，云端缺席不代表用户删过
            ),
          );
      await seedTx(id: 100, syncId: 'tx-1');

      final snapshot = payloadOf((await exportTransactionsJson(db, 1)).jsonStr);
      snapshot['customFields'] = <Map<String, dynamic>>[];

      await restoreLedgerFromJson(
        db: db,
        repo: LocalRepository(db),
        ledgerId: 1,
        jsonStr: jsonEncode(snapshot),
      );

      final rows = await db.select(db.customFieldDefinitions).get();
      expect(rows, hasLength(1));
      expect(rows.single.name, '本地新建未上传');
    });
  });
}
