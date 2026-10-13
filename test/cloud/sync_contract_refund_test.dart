/// v56 退款关联 + 报销状态（F1-b）**同步契约守门**
/// （照 `sync_contract_custom_field_test.dart` 的四条锁定结构）。
///
/// 背景：`prd/refund_reimbursement` —— `transactions` 新增 `refund_of_id`
/// （自引用 1:1）+ `reimburse_status`（三态）。两列必须进快照才能多设备存活，
/// 快照格式版本同批 13→14。本文件锁死：
///
/// 1. **契约键存在性**：`refundSyncId`（仅非 null 写键）/ `reimburseStatus`
///    （恒写）在导出侧与指纹白名单两侧都在；本地列名形式绝不出现；
/// 2. **每个字段单独变化都改变指纹**（漏一个 → 判 inSync → 永不传播）；
/// 3. **旧快照缺键归一口径**：缺 `refundSyncId` ≡ 无关联、缺
///    `reimburseStatus` ≡ `'none'` —— 这是 v14 升级门控
///    （`shouldRepublishSnapshotForFormatUpgrade`）能对无退款/报销账本
///    一次性收敛的前提；
/// 4. **跨设备往返**：A 导出 → B 导入 → B 再导出指纹相同，且退款行的
///    `refundSyncId` 被解析成 **B 本地的** 原交易 id（两阶段回填，
///    含前向引用的乱序快照）；
/// 5. **P1-2 成对断言**：diff 检测到 ↔ apply 应用得下去 ↔ 再 diff 为空。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

/// 从 `sync_fingerprint.dart` 的 items 段 return 块派生指纹白名单键
/// （锚点与 `sync_contract_coverage_test.dart` 的 deriveFingerprintKeys 一致）。
Set<String> deriveItemsCanonKeys() {
  final src = File('lib/cloud/sync_fingerprint.dart').readAsStringSync();
  final anchor = src.indexOf("'happenedAt': it[");
  if (anchor <= 0) {
    throw StateError('指纹事务段锚点未找到，派生逻辑需更新');
  }
  final start = src.lastIndexOf('return {', anchor);
  var depth = 0;
  var end = -1;
  for (var i = src.indexOf('{', start); i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) {
        end = i;
        break;
      }
    }
  }
  if (end <= start) throw StateError('指纹事务段大括号不配平');
  final block = src.substring(start, end);
  return RegExp(r"'([A-Za-z_][A-Za-z0-9_]*)'\s*:")
      .allMatches(block)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final jsonSrc = File('lib/cloud/transactions_json.dart').readAsStringSync();
  final canonKeys = deriveItemsCanonKeys();

  group('① 契约键存在性与本地专有列隔离', () {
    test('指纹白名单含 refundSyncId 与 reimburseStatus', () {
      expect(canonKeys, contains('refundSyncId'),
          reason: '漏它 → 只改退款关联时两端指纹相同 → 判 inSync → 永不传播');
      expect(canonKeys, contains('reimburseStatus'),
          reason: '漏它 → 只改报销状态时两端指纹相同 → 判 inSync → 永不传播');
    });

    test('导出侧两键都在 items 段（refundSyncId 条件写 / reimburseStatus 恒写）', () {
      expect(jsonSrc, contains("'refundSyncId': txIdToSyncId[t.refundOfId]"),
          reason: '退款关联必须翻成被冲正交易的 syncId（本地 int id 跨设备不可比）');
      expect(jsonSrc, contains("'reimburseStatus': t.reimburseStatus,"),
          reason: '报销状态恒写（同 excludeFromStats），缺键与明确 none 必须可区分');
    });

    test('本地专有列名（refund_of_id / reimburse_status）不进快照/指纹', () {
      expect(jsonSrc, isNot(contains("'refund_of_id'")),
          reason: '快照只认 syncId 形式；本地列名进快照 = 跨设备语义错乱');
      expect(jsonSrc, isNot(contains("'reimburse_status'")));
      final fpSrc = File('lib/cloud/sync_fingerprint.dart').readAsStringSync();
      expect(fpSrc, isNot(contains("'refund_of_id'")));
      expect(fpSrc, isNot(contains("'reimburse_status'")));
    });

    test('快照格式版本已抬到 15', () {
      expect(kSnapshotFormatVersion, 15,
          reason: 'items 段新增两键必须抬版本，否则升级门控永不触发；'
              'v15 为自定义字段 isRequired 的后续抬版');
    });
  });

  group('② 端到端：导出 / 指纹 / 往返', () {
    late PiggyDatabase db;
    late LocalRepository repo;

    setUp(() {
      db = PiggyDatabase.forTesting(NativeDatabase.memory());
      repo = LocalRepository(db);
    });
    tearDown(() async => db.close());

    Future<void> seedLedger() async => db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    /// 原交易（支出，syncId tx-orig）+ 退款行（收入，refund_of_id 指向它）。
    Future<void> seedRefundPair() async {
      await seedLedger();
      final originalId = await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime.utc(2026, 7, 1, 10),
        syncId: 'tx-orig',
      );
      await repo.addTransaction(
        ledgerId: 1,
        type: 'income',
        amount: 30,
        happenedAt: DateTime.utc(2026, 7, 3, 10),
        syncId: 'tx-refund',
        refundOfId: originalId,
        reimburseStatus: 'pending',
      );
    }

    Future<Map<String, dynamic>> exportPayload(PiggyDatabase target) async =>
        jsonDecode(await exportTransactionsJson(target, 1).then((e) => e.jsonStr))
            as Map<String, dynamic>;

    Map<String, dynamic> itemOf(Map<String, dynamic> payload, String syncId) =>
        (payload['items'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((e) => e['syncId'] == syncId);

    test('导出：refundSyncId 仅退款行写键，reimburseStatus 恒写', () async {
      await seedRefundPair();
      final payload = await exportPayload(db);
      final orig = itemOf(payload, 'tx-orig');
      final refund = itemOf(payload, 'tx-refund');

      expect(orig.containsKey('refundSyncId'), isFalse,
          reason: '非退款行不得写键（99% 交易无关联，恒写纯浪费）');
      expect(orig['reimburseStatus'], 'none');
      expect(refund['refundSyncId'], 'tx-orig',
          reason: '退款行必须携带被冲正交易的 syncId');
      expect(refund['reimburseStatus'], 'pending');
    });

    test('每个字段单独变化都改变指纹', () async {
      await seedRefundPair();
      final base = contentFingerprintFromMap(await exportPayload(db));

      final p1 = await exportPayload(db);
      itemOf(p1, 'tx-refund')['refundSyncId'] = 'tx-other';
      expect(contentFingerprintFromMap(p1), isNot(base),
          reason: '改了退款关联指纹却不变 → 该字段永不跨设备传播');

      final p2 = await exportPayload(db);
      itemOf(p2, 'tx-refund')['reimburseStatus'] = 'reimbursed';
      expect(contentFingerprintFromMap(p2), isNot(base),
          reason: '改了报销状态指纹却不变 → 该字段永不跨设备传播');
    });

    test('旧快照缺键归一口径（升级门控可收敛的前提）', () {
      Map<String, dynamic> oneItem(Map<String, dynamic> extra) => {
            'items': [
              {
                'happenedAt': '2026-07-01T10:00:00.000Z',
                'type': 'income',
                'amount': 30,
                ...extra,
              }
            ]
          };
      // 缺 refundSyncId ≡ 显式空串（无关联）
      expect(
        contentFingerprintFromMap(oneItem(const {})),
        contentFingerprintFromMap(oneItem(const {'refundSyncId': ''})),
        reason: '「旧快照无此键」与「显式无关联」必须同指纹',
      );
      // 缺 reimburseStatus ≡ 'none'（字段默认态）
      expect(
        contentFingerprintFromMap(oneItem(const {})),
        contentFingerprintFromMap(oneItem(const {'reimburseStatus': 'none'})),
        reason: '「旧快照无此键」与「显式 none」必须同指纹，否则无报销的账本'
            '永远过不了升级门控、每轮启动都提示有差异',
      );
    });

    test('往返一致 + 跨设备退款关联按 syncId 解析为本地 id', () async {
      await seedRefundPair();
      final exported = await exportTransactionsJson(db, 1);
      final fpA = contentFingerprintFromMap(jsonDecode(exported.jsonStr));

      final dbB = PiggyDatabase.forTesting(NativeDatabase.memory());
      addTearDown(dbB.close);
      final repoB = LocalRepository(dbB);
      await dbB.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

      await dataImportService.importData(
        repoB,
        1,
        parseJsonToImportData(exported.jsonStr),
        defaultCurrency: 'CNY',
      );

      final rowsB = await repoB.getTransactionsByLedger(1);
      final origB = rowsB.firstWhere((t) => t.syncId == 'tx-orig');
      final refundB = rowsB.firstWhere((t) => t.syncId == 'tx-refund');
      expect(refundB.refundOfId, origB.id,
          reason: '跨设备导入必须把 refundSyncId 解析成 B 本地的原交易 id'
              '（两阶段回填），否则关联在本机悬空');
      expect(refundB.reimburseStatus, 'pending');

      final fpB = contentFingerprintFromMap(
          jsonDecode((await exportTransactionsJson(dbB, 1)).jsonStr));
      expect(fpB, fpA, reason: '往返后指纹必须一致，否则每轮同步都判「有差异」');
    });

    test('前向引用回填（退款行排在原交易之前的乱序快照）', () async {
      await seedLedger();
      // 手工构造乱序 JSON：退款行在前、原交易在后 —— post-pass 必须仍能解析。
      final jsonStr = jsonEncode({
        'version': kSnapshotFormatVersion,
        'items': [
          {
            'type': 'income',
            'amount': 30,
            'happenedAt': '2026-07-03T10:00:00.000Z',
            'syncId': 'tx-refund',
            'refundSyncId': 'tx-orig',
            'reimburseStatus': 'pending',
            'currencyCode': 'CNY',
            'nativeAmount': 30,
            'excludeFromStats': false,
            'excludeFromBudget': false,
            'customValues': {},
          },
          {
            'type': 'expense',
            'amount': 100,
            'happenedAt': '2026-07-01T10:00:00.000Z',
            'syncId': 'tx-orig',
            'currencyCode': 'CNY',
            'nativeAmount': 100,
            'excludeFromStats': false,
            'excludeFromBudget': false,
            'customValues': {},
          },
        ],
      });
      await dataImportService.importData(
        repo,
        1,
        parseJsonToImportData(jsonStr),
        defaultCurrency: 'CNY',
      );

      final rows = await repo.getTransactionsByLedger(1);
      final orig = rows.firstWhere((t) => t.syncId == 'tx-orig');
      final refund = rows.firstWhere((t) => t.syncId == 'tx-refund');
      expect(refund.refundOfId, orig.id,
          reason: '乱序快照的前向引用也必须解析（插入时统一先落 NULL，'
              '末尾按 syncId 回填）');
      expect(refund.reimburseStatus, 'pending');
    });

    test('被引交易不在快照里 → 关联保持 NULL（不悬空解析失败）', () async {
      await seedLedger();
      final jsonStr = jsonEncode({
        'version': kSnapshotFormatVersion,
        'items': [
          {
            'type': 'income',
            'amount': 30,
            'happenedAt': '2026-07-03T10:00:00.000Z',
            'syncId': 'tx-refund',
            'refundSyncId': 'tx-missing',
            'reimburseStatus': 'pending',
            'currencyCode': 'CNY',
            'nativeAmount': 30,
            'excludeFromStats': false,
            'excludeFromBudget': false,
            'customValues': {},
          },
        ],
      });
      await dataImportService.importData(
        repo,
        1,
        parseJsonToImportData(jsonStr),
        defaultCurrency: 'CNY',
      );
      final refund = (await repo.getTransactionsByLedger(1)).single;
      expect(refund.refundOfId, isNull,
          reason: '被引交易本地不存在（用户只勾了退款行没勾原交易）→ 保持 NULL，'
              '与指纹口径一致（导出侧解析不到不写键）');
    });
  });

  group('③ diff 检测与应用成对（P1-2）', () {
    late PiggyDatabase db;
    late LocalRepository repo;
    late SyncDiffService service;

    setUp(() {
      db = PiggyDatabase.forTesting(NativeDatabase.memory());
      repo = LocalRepository(db);
      service = SyncDiffService();
    });
    tearDown(() async => db.close());

    Future<void> seedLedger() async => db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    /// 原交易 + 本地带关联 / 带状态的退款行（syncId tx-refund）。
    Future<void> seedPair({required bool withLink}) async {
      await seedLedger();
      final originalId = await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime.utc(2026, 7, 1, 10),
        syncId: 'tx-orig',
      );
      await repo.addTransaction(
        ledgerId: 1,
        type: 'income',
        amount: 30,
        happenedAt: DateTime.utc(2026, 7, 3, 10),
        syncId: 'tx-refund',
        refundOfId: withLink ? originalId : null,
        reimburseStatus: 'pending',
      );
    }

    /// 云端版退款行：除入参外与本地逐字段一致。
    ImportTransaction cloudRefund({String? refundSyncId, String status = 'pending'}) =>
        ImportTransaction(
          type: 'income',
          amount: 30,
          happenedAt: DateTime.utc(2026, 7, 3, 10).toLocal(),
          syncId: 'tx-refund',
          currencyCode: 'CNY',
          nativeAmount: 30,
          refundSyncId: refundSyncId,
          reimburseStatus: status,
        );

    /// 云端版原交易：与本地逐字段一致。
    ///
    /// ⚠️ 必须进云端清单 —— 真实快照里原交易与退款行同在；漏了它 diff 会产出
    /// 一条「本地有云端无」的 deleted，apply 会把原交易删掉。
    ImportTransaction cloudOriginal() => ImportTransaction(
          type: 'expense',
          amount: 100,
          happenedAt: DateTime.utc(2026, 7, 1, 10).toLocal(),
          syncId: 'tx-orig',
          currencyCode: 'CNY',
          nativeAmount: 100,
        );

    ImportData importDataFor() => const ImportData(
          categories: [],
          accounts: [],
          recurrings: [],
        );

    test('本地有关联、云端无 → 检测到，应用后清空并收敛', () async {
      await seedPair(withLink: true);
      final cloud = cloudRefund(); // refundSyncId 缺省 = 云端无关联

      final preview = await service.computeDiff(
          repo: repo, ledgerId: 1, cloudTransactions: [cloud, cloudOriginal()]);
      expect(preview!.modifiedCount, 1,
          reason: '退款关联差异必须被检测到（指纹已纳入，diff 不报 = 半截洞）');
      expect(preview.changes.single.diffDetails.any((d) => d.contains('退款关联')),
          isTrue);

      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview.changes,
        importData: importDataFor(),
      );

      final row = await (db.select(db.transactions)
            ..where((t) => t.syncId.equals('tx-refund')))
          .getSingle();
      expect(row.refundOfId, isNull, reason: '云端无关联 → 应用后本地必须清空');

      final again = await service.computeDiff(
          repo: repo, ledgerId: 1, cloudTransactions: [cloud, cloudOriginal()]);
      expect(again!.isEmpty, isTrue,
          reason: '应用后必须收敛，否则每轮都报同一批变更');
    });

    test('本地无关联、云端有 → 检测到，应用后写回本地 id 并收敛', () async {
      await seedPair(withLink: false);
      final cloud = cloudRefund(refundSyncId: 'tx-orig');

      final preview = await service.computeDiff(
          repo: repo, ledgerId: 1, cloudTransactions: [cloud, cloudOriginal()]);
      expect(preview!.modifiedCount, 1);

      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview.changes,
        importData: importDataFor(),
      );

      final rows = await repo.getTransactionsByLedger(1);
      final orig = rows.firstWhere((t) => t.syncId == 'tx-orig');
      final refund = rows.firstWhere((t) => t.syncId == 'tx-refund');
      expect(refund.refundOfId, orig.id,
          reason: '应用阶段必须把 refundSyncId 解析为本地 id 写回');

      final again = await service.computeDiff(
          repo: repo, ledgerId: 1, cloudTransactions: [cloud, cloudOriginal()]);
      expect(again!.isEmpty, isTrue);
    });

    test('报销状态云端不同 → 检测到，应用后按云端值落并收敛', () async {
      await seedPair(withLink: true);
      final cloud = cloudRefund(refundSyncId: 'tx-orig', status: 'reimbursed');

      final preview = await service.computeDiff(
          repo: repo, ledgerId: 1, cloudTransactions: [cloud, cloudOriginal()]);
      expect(preview!.modifiedCount, 1,
          reason: '报销状态差异必须被检测到');
      expect(
          preview.changes.single.diffDetails.any((d) => d.contains('报销状态')),
          isTrue);

      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview.changes,
        importData: importDataFor(),
      );

      final row = await (db.select(db.transactions)
            ..where((t) => t.syncId.equals('tx-refund')))
          .getSingle();
      expect(row.reimburseStatus, 'reimbursed');

      final again = await service.computeDiff(
          repo: repo, ledgerId: 1, cloudTransactions: [cloud, cloudOriginal()]);
      expect(again!.isEmpty, isTrue);
    });
  });
}
