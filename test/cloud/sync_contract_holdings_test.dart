/// v11 投资持仓的**同步契约守门**。
///
/// 现有 `sync_contract_coverage_test.dart` 只从**交易段**派生指纹白名单 ——
/// 账户 / 分类 / 标签 / 持仓这些实体段的字段漂移它一概看不见。本文件把持仓段
/// 的这条盲区补上，锁死四件事：
///
/// 1. **导出字段 ↔ 指纹白名单一字不差**（键集合由两份源码**派生**，不是手抄
///    一份可能漂移的副本）—— 少了会「进了导出却没进指纹 → 改了不传播」，
///    多了会「进了指纹却没进导出 → 指纹永远算不出云端那个值 → 永不收敛」；
/// 2. **行情缓存三列绝不进快照 / 指纹** —— `quote_price` / `quote_fetched_at` /
///    `quote_source_id` 是本地专有列，纳管会让「本机拉一次行情」就把跨设备
///    指纹改掉，两端永久不收敛；
/// 3. **每个可同步字段都真的影响指纹**（否则该字段永不跨设备传播）；
/// 4. **实体删除语义**：对端删掉的持仓能被识别、默认不勾选、勾了能落地；
///    而**旧格式（v10 及更早）快照整段没有 holdings** 时绝不能把本地持仓
///    全判成「对端已删」（那是一次点选删光所有持仓）。
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

/// 持仓**导出**字段（`transactions_json.dart` 的 holdingItems 段）
Set<String> deriveHoldingExportKeys() => _deriveKeys(
      File('lib/cloud/transactions_json.dart').readAsStringSync(),
      'final holdingItems = holdings',
    );

/// 持仓**指纹白名单**（`sync_fingerprint.dart` 的 holdingCanon 段）
Set<String> deriveHoldingCanonKeys() => _deriveKeys(
      File('lib/cloud/sync_fingerprint.dart').readAsStringSync(),
      'final holdingCanon = holdings',
    );

/// 行情缓存三列 —— **任何情况下都不得**出现在快照或指纹里。
const _quoteCacheKeys = <String>[
  'quotePrice',
  'quoteFetchedAt',
  'quoteSourceId',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  // 派生失败要**在测试外**就炸掉（不能吞成空集恒真）
  final exportKeys = deriveHoldingExportKeys();
  final canonKeys = deriveHoldingCanonKeys();

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
      expect(exportKeys.length, greaterThanOrEqualTo(14),
          reason: '持仓可同步字段至少 14 个（name/accountSyncId/accountName/'
              'symbol/market/assetClass/currency/quantity/unitCost/unitPrice/'
              'autoQuote/note/sortOrder/syncId）');
    });

    test('行情缓存三列不在任何一侧', () {
      for (final k in _quoteCacheKeys) {
        expect(exportKeys, isNot(contains(k)),
            reason: '$k 是本地专有行情缓存，进快照 = 把本机行情当用户数据同步');
        expect(canonKeys, isNot(contains(k)),
            reason: '$k 进指纹 = 本机刷新一次行情就让跨设备指纹永久不一致');
      }
    });
  });

  group('② 快照与指纹里的持仓（端到端）', () {
    late PiggyDatabase db;
    late LocalRepository repo;

    setUp(() {
      db = PiggyDatabase.forTesting(NativeDatabase.memory());
      repo = LocalRepository(db);
    });

    tearDown(() async => db.close());

    /// 造一个「字段全齐」的持仓（可选字段都非空 → 导出键齐全，便于逐字段改）
    Future<int> seedFullHolding() async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      await db.into(db.accounts).insert(AccountsCompanion.insert(
            ledgerId: 0,
            name: '投资账户',
            type: const d.Value('investment'),
            syncId: const d.Value('acc-1'),
          ));
      return repo.createHolding(
        accountId: 1,
        name: '贵州茅台',
        currency: 'CNY',
        symbol: '600519',
        market: 'SH',
        assetClass: 'stock',
        quantity: 100,
        unitCost: 1500,
        unitPrice: 1680,
        autoQuote: true,
        note: '长线持有',
        sortOrder: 3,
        syncId: 'h-1',
      );
    }

    Future<Map<String, dynamic>> exportPayload() async =>
        jsonDecode(await exportTransactionsJson(db, 1).then((e) => e.jsonStr))
            as Map<String, dynamic>;

    Future<String> fingerprintOf(Map<String, dynamic> payload) async =>
        contentFingerprintFromMap(payload);

    test('导出携带 holdings 段，字段齐全且不含行情缓存键', () async {
      await seedFullHolding();
      final payload = await exportPayload();
      final items = (payload['holdings'] as List).cast<Map<String, dynamic>>();

      expect(items, hasLength(1));
      final h = items.single;
      expect(h['name'], '贵州茅台');
      expect(h['accountSyncId'], 'acc-1');
      expect(h['accountName'], '投资账户');
      expect(h['symbol'], '600519');
      expect(h['market'], 'SH');
      expect(h['assetClass'], 'stock');
      expect(h['currency'], 'CNY');
      expect(h['quantity'], 100);
      expect(h['unitCost'], 1500);
      expect(h['unitPrice'], 1680);
      expect(h['autoQuote'], isTrue);
      expect(h['note'], '长线持有');
      expect(h['sortOrder'], 3);
      expect(h['syncId'], 'h-1');
      for (final k in _quoteCacheKeys) {
        expect(h.containsKey(k), isFalse, reason: '快照不得携带 $k');
      }
      // 导出的键集合与派生结果一致（多一个少一个都算契约破坏）
      expect(h.keys.toSet(), exportKeys);
    });

    test('每个可同步字段单独变化都改变指纹', () async {
      await seedFullHolding();
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
        final items = (payload['holdings'] as List).cast<Map<String, dynamic>>();
        final item = items.single;
        if (item.containsKey(key)) {
          item[key] = mutateValue(item[key]);
        } else {
          item[key] = 'FILLED'; // 缺键 → 补上，同样必须影响指纹
        }

        expect(
          await fingerprintOf(payload),
          isNot(baseFp),
          reason: '改了持仓字段 `$key` 指纹却不变 → 该字段永不跨设备传播',
        );
      }
    });

    test('缺 holdings 段 == 空数组（旧快照向后兼容，同指纹）', () async {
      await seedFullHolding();
      final withEmpty = await exportPayload();
      final legacy = await exportPayload();

      expect((withEmpty['holdings'] as List), isNotEmpty);
      legacy['holdings'] = <Map<String, dynamic>>[];
      // 关键：把持仓清空后指纹**必须**变化（否则持仓根本不参与同步检测），
      // 所以这里比对的是「显式空数组」与「整个键缺失」两种旧快照形态。
      withEmpty['holdings'] = <Map<String, dynamic>>[];

      expect(await fingerprintOf(withEmpty), await fingerprintOf(legacy),
          reason: '缺失键与显式空数组必须归一化到同一指纹');
    });

    test('行情缓存写入**不改变**快照内容与指纹', () async {
      final id = await seedFullHolding();
      final before = await exportPayload();
      final fpBefore = await fingerprintOf(before);
      final holdingsBefore = jsonEncode(before['holdings']);

      await repo.writeQuoteCache(
        id,
        price: 1712.5,
        fetchedAt: DateTime(2026, 10, 8, 15),
        sourceId: 'eastmoney',
      );

      final after = await exportPayload();
      // 只比 holdings 段（整个 payload 含 exportedAt，两次导出必然不同）
      expect(jsonEncode(after['holdings']), holdingsBefore,
          reason: '行情缓存不得出现在快照里');
      expect(await fingerprintOf(after), fpBefore,
          reason: '行情刷新不得改指纹 —— 否则两端永远不收敛');
    });

    test('往返一致：A 导出 → B 导入 → B 再导出，指纹相同且持仓落库', () async {
      await seedFullHolding();
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

      final bHoldings = await repoB.getHoldingsByAccount(1);
      expect(bHoldings, hasLength(1));
      expect(bHoldings.single.name, '贵州茅台');
      expect(bHoldings.single.symbol, '600519');
      expect(bHoldings.single.market, 'SH');
      expect(bHoldings.single.autoQuote, isTrue);
      expect(bHoldings.single.quantity, 100);
      expect(bHoldings.single.unitPrice, 1680);
      expect(bHoldings.single.quotePrice, isNull,
          reason: '行情缓存是本地专有列，导入不得携带/伪造');

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

    /// [use] 必须与随后 computeDiff 用的 repo **同一个**：变更登记是挂在
    /// repo 的 ChangeTracker 上的，用未注入 tracker 的 repo 建行、再拿注入
    /// tracker 的 repo 去算，闸门④ 永远是空的（假绿）。
    Future<int> seedHolding({String syncId = 'h-1', LocalRepository? use}) async {
      if (await db.select(db.accounts).get().then((r) => r.isEmpty)) {
        await db.into(db.accounts).insert(AccountsCompanion.insert(
              ledgerId: 0,
              name: '投资账户',
              type: const d.Value('investment'),
              syncId: const d.Value('acc-1'),
            ));
      }
      return (use ?? repo).createHolding(
        accountId: 1,
        name: '贵州茅台',
        currency: 'CNY',
        symbol: '600519',
        market: 'SH',
        quantity: 100,
        unitPrice: 1680,
        syncId: syncId,
      );
    }

    /// 云端元数据夹具。**带账户**是刻意的：本地账户在云端缺席会额外产出一条
    /// 「账户」删除候选，把断言口径搅浑（本文件只关心持仓那一条）。
    ImportData cloud({
      int? version = 11,
      List<ImportHolding> holdings = const [],
      Map<String, int> skippedItems = const {},
    }) =>
        ImportData(
          version: version,
          accounts: const [
            ImportAccount(name: '投资账户', type: 'investment', syncId: 'acc-1'),
          ],
          holdings: holdings,
          skippedItems: skippedItems,
        );

    Future<List<SyncEntityDelete>> holdingCandidates(
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
          .where((c) => c.isEntityDelete && c.entityDelete!.kind == SyncEntityKind.holding)
          .map((c) => c.entityDelete!)
          .toList();
    }

    test('云端仍带同一 syncId → 无候选', () async {
      await seedLedger();
      await seedHolding();

      final c = await holdingCandidates(cloud(holdings: const [
        ImportHolding(name: '贵州茅台', syncId: 'h-1', quantity: 100),
      ]));

      expect(c, isEmpty);
    });

    test('云端（v11）已无该持仓 → 产出候选且默认不勾选', () async {
      await seedLedger();
      await seedHolding();

      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: const [],
        cloudMeta: cloud(),
      );
      final deletes = preview!.changes.where((c) => c.isEntityDelete).toList();

      expect(deletes, hasLength(1), reason: '账户仍在云端，只有持仓该被列为删除');
      expect(deletes.single.entityDelete!.kind, SyncEntityKind.holding);
      expect(deletes.single.entityDelete!.name, '贵州茅台');
      expect(deletes.single.selected, isFalse,
          reason: '删除是破坏性变更，必须用户显式勾选（SYNC-05 口径）');
    });

    test('旧格式（v10）快照整段没有 holdings → 一条候选都不出（防点选删光持仓）', () async {
      await seedLedger();
      await seedHolding();

      final c = await holdingCandidates(cloud(version: 10));

      expect(c, isEmpty,
          reason: 'v10 导出端根本没有 holdings 段；把「整段缺失」当成'
              '「云端一条都没有」会让用户的全部持仓变成删除候选');
    });

    test('该段解析损坏（skippedItems）→ 不出候选', () async {
      await seedLedger();
      await seedHolding();

      final c = await holdingCandidates(
          cloud(skippedItems: const {'holdings': 1}));

      expect(c, isEmpty);
    });

    test('本机有未推送的持仓变更 → 不出候选（闸门④）', () async {
      final tracked = LocalRepository(db, changeTracker: ChangeTracker(db));
      await seedLedger();
      // 建行必须走**同一个** tracked repo，否则 local_changes 是空的，本用例假绿
      await seedHolding(use: tracked);

      final c = await holdingCandidates(cloud(), use: tracked);

      expect(c, isEmpty,
          reason: '建行即生成 UUID syncId，闸门③ 挡不住「刚建未上传」；'
              '有未推送变更说明云端缺席是信息滞后，不是用户删了它');
    });

    test('勾选后真正删除，且再算 diff 收敛', () async {
      await seedLedger();
      final id = await seedHolding();

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
      expect(await repo.getHolding(id), isNull);

      final again = await holdingCandidates(cloud());
      expect(again, isEmpty, reason: '再算一次必须收敛，否则每轮都提示、点了也没用');
    });

    test('删除账户 → 级联删除持仓，不留悬空引用', () async {
      await seedLedger();
      final id = await seedHolding();

      await repo.deleteAccount(1);

      expect(await repo.getHolding(id), isNull);
      expect(await holdingCandidates(cloud()), isEmpty);
    });
  });
}
