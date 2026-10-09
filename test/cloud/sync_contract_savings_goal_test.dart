/// v12 储蓄目标的**同步契约守门**（照 `sync_contract_holdings_test.dart` 的四条锁定）。
///
/// 现有 `sync_contract_coverage_test.dart` 只从**交易段**派生指纹白名单 —— 实体段
/// 的字段漂移它看不见。本文件补上储蓄目标这条盲区，锁死四件事：
///
/// 1. **导出字段 ↔ 指纹白名单一字不差**（键集合由两份源码**派生**，不是手抄副本）；
/// 2. **本地专有列绝不进快照 / 指纹** —— `updatedAt` / `createdAt` / `id` /
///    `accountId` / `ledgerId` 一旦进指纹，本机一次无关 UPDATE 或换设备后自增 id
///    不同，都会让跨设备指纹永久不相等；
/// 3. **每个可同步字段都真的影响指纹**；
/// 4. **实体删除语义**：对端删掉的目标能被识别、默认不勾选、勾了能落地；而
///    **旧格式（v11 及更早）快照整段没有 savingsGoals** 时绝不能把本地目标全判成
///    「对端已删」（那是一次点选删光所有目标）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

/// 从源码里 `anchor` 之后第一个 `{` 起的**配平块**中，抽取所有 `'key':` 形态的键。
///
/// 用派生而不是手写清单：这条测试的全部价值就在于「实现变了、测试会红」，
/// 抄一份白名单就退化成了同义反复。
Set<String> _deriveKeys(String source, String anchor) {
  final at = source.indexOf(anchor);
  if (at <= 0) {
    throw StateError('源码锚点未找到（实现结构已变，需更新派生逻辑）: $anchor');
  }
  final open = source.indexOf('{', at);
  var depth = 0;
  var end = -1;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) {
        end = i;
        break;
      }
    }
  }
  if (end <= open) throw StateError('大括号不配平: $anchor');
  final block = source.substring(open, end);
  return RegExp(r"'([A-Za-z_][A-Za-z0-9_]*)'\s*:")
      .allMatches(block)
      .map((m) => m.group(1)!)
      .toSet();
}

/// 储蓄目标**导出**字段（`transactions_json.dart` 的 savingsGoalItems 段）
Set<String> deriveSavingsGoalExportKeys() => _deriveKeys(
      File('lib/cloud/transactions_json.dart').readAsStringSync(),
      'final savingsGoalItems = ledgerSavingsGoals',
    );

/// 储蓄目标**指纹白名单**（`sync_fingerprint.dart` 的 savingsGoalCanon 段）
Set<String> deriveSavingsGoalCanonKeys() => _deriveKeys(
      File('lib/cloud/sync_fingerprint.dart').readAsStringSync(),
      'final savingsGoalCanon = savingsGoals',
    );

/// 本地专有列 —— **任何情况下都不得**出现在快照或指纹里。
///
/// `accountId` 是本地自增外键（跨设备无意义，导出走 accountSyncId/accountName
/// 双锚点）；`ledgerId` 由快照段本身的作用域表达。
const _localOnlyKeys = <String>[
  'updatedAt',
  'createdAt',
  'id',
  'accountId',
  'ledgerId',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  // 派生失败要**在测试外**就炸掉（不能吞成空集恒真）
  final exportKeys = deriveSavingsGoalExportKeys();
  final canonKeys = deriveSavingsGoalCanonKeys();

  group('① 导出字段 ↔ 指纹白名单', () {
    test('两份源码的键集合一字不差', () {
      expect(
        canonKeys,
        exportKeys,
        reason: '导出有而指纹没有 → 改了这个字段指纹不变、永不传播；'
            '指纹有而导出没有 → 云端那个键恒缺，两端指纹永不相等',
      );
    });

    test('键数量下限（防正则静默匹配不到 → 空集恒真 → 守门失效）', () {
      expect(exportKeys.length, greaterThanOrEqualTo(11),
          reason: '储蓄目标可同步字段至少 11 个（syncId/name/targetAmount/'
              'currency/accountSyncId/accountName/savedAmount/startDate/'
              'targetDate/note/sortOrder）');
    });

    test('本地专有列不在任何一侧', () {
      for (final k in _localOnlyKeys) {
        expect(exportKeys, isNot(contains(k)),
            reason: '$k 是本地专有列，进快照会让两端内容恒不等');
        expect(canonKeys, isNot(contains(k)),
            reason: '$k 进指纹 = 本机一次无关 UPDATE 就让跨设备指纹永久不一致');
      }
    });
  });

  group('② 快照与指纹里的储蓄目标（端到端）', () {
    late PiggyDatabase db;
    late LocalRepository repo;

    setUp(() {
      db = PiggyDatabase.forTesting(NativeDatabase.memory());
      repo = LocalRepository(db);
    });

    tearDown(() async => db.close());

    /// 造一个「字段全齐」的目标（可选字段都非空 → 导出键齐全，便于逐字段改）。
    Future<int> seedFullGoal() async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      await db.into(db.accounts).insert(AccountsCompanion.insert(
            ledgerId: 0,
            name: '储蓄账户',
            type: const d.Value('bank'),
            syncId: const d.Value('acc-1'),
          ));
      return repo.createSavingsGoal(
        ledgerId: 1,
        name: '日本旅行',
        targetAmount: 20000,
        currency: 'CNY',
        accountId: 1,
        savedAmount: 3500,
        startDate: DateTime(2026, 1, 1),
        targetDate: DateTime(2027, 1, 1),
        note: '一家三口',
        sortOrder: 2,
        syncId: 'sg-1',
      );
    }

    Future<Map<String, dynamic>> exportPayload() async =>
        jsonDecode(await exportTransactionsJson(db, 1).then((e) => e.jsonStr))
            as Map<String, dynamic>;

    Future<String> fingerprintOf(Map<String, dynamic> payload) async =>
        contentFingerprintFromMap(payload);

    test('导出携带 savingsGoals 段，字段齐全且不含本地专有列', () async {
      await seedFullGoal();
      final payload = await exportPayload();
      final items =
          (payload['savingsGoals'] as List).cast<Map<String, dynamic>>();

      expect(items, hasLength(1));
      final g = items.single;
      expect(g['name'], '日本旅行');
      expect(g['targetAmount'], 20000);
      expect(g['currency'], 'CNY');
      expect(g['accountSyncId'], 'acc-1');
      expect(g['accountName'], '储蓄账户');
      expect(g['savedAmount'], 3500);
      expect(g['startDate'], isA<String>());
      expect(g['targetDate'], isA<String>());
      expect(g['note'], '一家三口');
      expect(g['sortOrder'], 2);
      expect(g['syncId'], 'sg-1');
      for (final k in _localOnlyKeys) {
        expect(g.containsKey(k), isFalse, reason: '快照不得携带本地专有列 $k');
      }
      // 导出的键集合与派生结果一致（多一个少一个都算契约破坏）
      expect(g.keys.toSet(), exportKeys);
    });

    test('每个可同步字段单独变化都改变指纹', () async {
      await seedFullGoal();
      final base = await exportPayload();
      final baseFp = await fingerprintOf(base);

      Object? mutateValue(Object? v) {
        if (v is bool) return !v;
        if (v is num) return v + 1;
        if (v is String) return '${v}x';
        return 'FILLED';
      }

      for (final key in exportKeys) {
        final payload = await exportPayload();
        final items =
            (payload['savingsGoals'] as List).cast<Map<String, dynamic>>();
        final item = items.single;
        if (item.containsKey(key)) {
          item[key] = mutateValue(item[key]);
        } else {
          item[key] = 'FILLED'; // 缺键 → 补上，同样必须影响指纹
        }

        expect(
          await fingerprintOf(payload),
          isNot(baseFp),
          reason: '改了储蓄目标字段 `$key` 指纹却不变 → 该字段永不跨设备传播',
        );
      }
    });

    test('缺 savingsGoals 段 == 空数组（旧快照向后兼容，同指纹）', () async {
      await seedFullGoal();
      final withEmpty = await exportPayload();
      final legacy = await exportPayload();

      expect((withEmpty['savingsGoals'] as List), isNotEmpty);
      // 比对「显式空数组」与「整个键缺失」两种旧快照形态。
      withEmpty['savingsGoals'] = <Map<String, dynamic>>[];
      legacy['savingsGoals'] = <Map<String, dynamic>>[];

      expect(await fingerprintOf(withEmpty), await fingerprintOf(legacy),
          reason: '缺失键与显式空数组必须归一化到同一指纹');
    });

    test('往返一致：A 导出 → B 导入 → B 再导出，指纹相同且目标落库', () async {
      await seedFullGoal();
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

      final bGoals = await repoB.getSavingsGoalsByLedger(1);
      expect(bGoals, hasLength(1));
      expect(bGoals.single.name, '日本旅行');
      expect(bGoals.single.targetAmount, 20000);
      expect(bGoals.single.savedAmount, 3500);
      expect(bGoals.single.accountId, isNotNull, reason: '账户锚点必须解析到本地账户');
      expect(bGoals.single.note, '一家三口');

      final fpB = contentFingerprintFromMap(
          jsonDecode((await exportTransactionsJson(dbB, 1)).jsonStr));
      expect(fpB, fpA, reason: '往返后指纹必须一致，否则每轮同步都判「有差异」');
    });
  });

  group('③ 实体删除语义', () {
    late PiggyDatabase db;
    late LocalRepository repo;
    late SyncDiffService service;

    setUp(() {
      db = PiggyDatabase.forTesting(NativeDatabase.memory());
      repo = LocalRepository(db);
      service = SyncDiffService();
    });

    tearDown(() async => db.close());

    Future<void> seedLedger() => db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    Future<void> seedAccount() async {
      if (await db.select(db.accounts).get().then((r) => r.isEmpty)) {
        await db.into(db.accounts).insert(AccountsCompanion.insert(
              ledgerId: 0,
              name: '储蓄账户',
              type: const d.Value('bank'),
              syncId: const d.Value('acc-1'),
            ));
      }
    }

    /// [use] 必须与随后 computeDiff 用的 repo **同一个**：变更登记挂在 repo 的
    /// ChangeTracker 上，用未注入 tracker 的 repo 建行、再拿注入 tracker 的 repo
    /// 去算，闸门④ 永远是空的（假绿）。
    Future<int> seedGoal({String syncId = 'sg-1', LocalRepository? use}) async {
      await seedAccount();
      return (use ?? repo).createSavingsGoal(
        ledgerId: 1,
        name: '日本旅行',
        targetAmount: 20000,
        currency: 'CNY',
        syncId: syncId,
      );
    }

    /// 云端元数据夹具。**带账户**是刻意的：本地账户在云端缺席会额外产出一条
    /// 「账户」删除候选，把断言口径搅浑（本文件只关心目标那一条）。
    ImportData cloud({
      int? version = 12,
      List<ImportSavingsGoal> savingsGoals = const [],
      Map<String, int> skippedItems = const {},
    }) =>
        ImportData(
          version: version,
          accounts: const [
            ImportAccount(name: '储蓄账户', type: 'bank', syncId: 'acc-1'),
          ],
          savingsGoals: savingsGoals,
          skippedItems: skippedItems,
        );

    Future<List<SyncEntityDelete>> goalCandidates(
      ImportData cloudData, {
      LocalRepository? use,
    }) async {
      final preview = await service.computeDiff(
        repo: use ?? repo,
        ledgerId: 1,
        cloudTransactions: const [],
        cloudMeta: cloudData,
      );
      return preview!.changes
          .where((c) =>
              c.isEntityDelete &&
              c.entityDelete!.kind == SyncEntityKind.savingsGoal)
          .map((c) => c.entityDelete!)
          .toList();
    }

    test('云端仍带同一 syncId → 无候选', () async {
      await seedLedger();
      await seedGoal();

      final c = await goalCandidates(cloud(savingsGoals: const [
        ImportSavingsGoal(name: '日本旅行', targetAmount: 20000, syncId: 'sg-1'),
      ]));

      expect(c, isEmpty);
    });

    test('云端（v12）已无该目标 → 产出候选且默认不勾选', () async {
      await seedLedger();
      await seedGoal();

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: const [],
        cloudMeta: cloud(),
      );
      final deletes = preview!.changes.where((c) => c.isEntityDelete).toList();

      expect(deletes, hasLength(1), reason: '账户仍在云端，只有目标该被列为删除');
      expect(deletes.single.entityDelete!.kind, SyncEntityKind.savingsGoal);
      expect(deletes.single.entityDelete!.name, '日本旅行');
      expect(deletes.single.selected, isFalse,
          reason: '删除是破坏性变更，必须用户显式勾选（SYNC-05 口径）');
    });

    test('旧格式（v11）快照整段没有 savingsGoals → 一条候选都不出', () async {
      await seedLedger();
      await seedGoal();

      final c = await goalCandidates(cloud(version: 11));

      expect(c, isEmpty,
          reason: 'v11 导出端根本没有 savingsGoals 段；把「整段缺失」当成'
              '「云端一条都没有」会让用户的全部目标变成删除候选');
    });

    test('该段解析损坏（skippedItems）→ 不出候选', () async {
      await seedLedger();
      await seedGoal();

      final c = await goalCandidates(
          cloud(skippedItems: const {'savingsGoals': 1}));

      expect(c, isEmpty);
    });

    test('本机有未推送的目标变更 → 不出候选（闸门④）', () async {
      final tracked = LocalRepository(db, changeTracker: ChangeTracker(db));
      await seedLedger();
      // 建行必须走**同一个** tracked repo，否则 local_changes 是空的，本用例假绿
      await seedGoal(use: tracked);

      final c = await goalCandidates(cloud(), use: tracked);

      expect(c, isEmpty,
          reason: '建行即生成 UUID syncId，闸门③ 挡不住「刚建未上传」；'
              '有未推送变更说明云端缺席是信息滞后，不是用户删了它');
    });

    test('勾选后真正删除，且再算 diff 收敛', () async {
      await seedLedger();
      final id = await seedGoal();

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: const [],
        cloudMeta: cloud(),
      );
      final result = await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview!.changes,
        importData: cloud(),
      );

      expect(result.entityDeletedCount, 1);
      expect(await repo.getSavingsGoal(id), isNull);

      final again = await goalCandidates(cloud());
      expect(again, isEmpty, reason: '再算一次必须收敛，否则每轮都提示、点了也没用');
    });

    test('删除账户 → 目标降级为手动模式（置空 accountId），不级联删除', () async {
      await seedLedger();
      final id = await seedGoal(use: LocalRepository(db));

      await repo.deleteAccount(1);

      final goal = await repo.getSavingsGoal(id);
      expect(goal, isNotNull,
          reason: '删账户是资产结构调整，不该顺手销毁用户的动机数据');
      expect(goal!.accountId, isNull, reason: '进度来源应降级为手动累计');
      expect(goal.savedAmount, 0);
    });
  });
}
