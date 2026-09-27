/// P0：**指纹白名单 ↔ 增量 diff 覆盖字段** 的自动一致性检查。
///
/// 【为什么需要】
/// 这类缺陷已经出现两次，形状完全相同：
///   * 审计 S11：指纹已纳入**附件清单**，`_compareTx` 不比附件；
///   * D-1（2026-09-27）：指纹已纳入 `categoryName/categoryKind`，`_compareTx`
///     不比分类。
/// 共同后果不是"静默不同步"这么轻 —— 指纹说「不同」而 diff 说「没变化」，
/// 于是：① 同步状态卡永久显示"本地与云端有差异"，用户点「下载同步」一条变更
/// 都点不出来（**UI 无法自愈**）；② merge-then-publish 把本地旧值回传覆盖云端，
/// 两端形成永久 ping-pong。
///
/// 光靠给分类/附件各补一个用例不够 —— 白名单里还有 20 个键。本文件把它变成
/// **穷举检查**：白名单键由 `sync_fingerprint.dart` 源码**派生**，每个键都必须
/// 有对应的"只改它"的夹具，否则测试直接失败（新增字段无处可藏）。
///
/// 【两层断言】
///   Tier 1：指纹必须随该键变化（否则该字段根本不参与同步检测）；
///   Tier 2：`computeDiff` 必须报 modified（否则用户点不出来 —— D-1 的形状）。
/// Tier 2 允许一张**显式豁免表**，每条豁免都必须写明理由并在此处可复核。
/// 空豁免表意味着 22 个键全部被 diff 覆盖。
library;

import 'dart:io';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

// ============ 从实现派生指纹白名单键（事务段）============
/// 与 `scripts/live_db/compare_sync_final.py` 的 `_derive_cloud_contract()`
/// 同款思路：清单由实现派生，而不是手写一份可能漂移的副本。
Set<String> deriveFingerprintKeys() {
  // 注意：本函数在 main() 阶段被调用，不能用 expect（OutsideTestException），
  // 派生失败一律抛 StateError。
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

  final whitelist = deriveFingerprintKeys();
  final baseTime = DateTime.utc(2026, 7, 1, 10, 0, 0);

  late PiggyDatabase db;
  late LocalRepository repo;
  late SyncDiffService service;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = SyncDiffService();
  });
  tearDown(() async => db.close());

  // ---------------- 默认本地状态（所有键的"未变更"基准）----------------
  Future<void> seedDefault() async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await db.customStatement(
        "INSERT INTO categories (id, name, kind, level, sort_order, sync_id) "
        "VALUES (1, '餐饮', 'expense', 2, 0, 'cat-food')");
    await db.customStatement(
        "INSERT INTO categories (id, name, kind, level, sort_order, sync_id) "
        "VALUES (2, '交通', 'expense', 2, 1, 'cat-trip')");
    await db.customStatement(
        "INSERT INTO accounts (id, ledger_id, name, type, currency, sync_id) "
        "VALUES (1, 0, '现金', 'cash', 'CNY', 'acc-cash')");
    await db.customStatement(
        "INSERT INTO accounts (id, ledger_id, name, type, currency, sync_id) "
        "VALUES (2, 0, '银行卡', 'bank', 'CNY', 'acc-bank')");
    await db.customStatement(
        "INSERT INTO tags (id, name, color, sort_order, sync_id) "
        "VALUES (1, '报销', '#f00', 0, 'tag-a')");
    await db.customStatement(
        "INSERT INTO tags (id, name, color, sort_order, sync_id) "
        "VALUES (2, '差旅', '#0f0', 1, 'tag-b')");
    await db.customStatement(
        "INSERT INTO custom_field_definitions "
        "(id, ledger_id, name, field_type, sort_order, sync_id) "
        "VALUES (1, 1, '原价', 'amount', 0, 'cf-1')");
  }

  Future<int> seedLocalTx({int? categoryId = 1, int? accountId = 1}) async {
    final id = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 100,
            categoryId: d.Value(categoryId),
            accountId: d.Value(accountId),
            happenedAt: d.Value(baseTime),
            note: const d.Value('A'),
            syncId: const d.Value('tx-1'),
            currencyCode: const d.Value('CNY'),
            nativeAmount: const d.Value(100),
          ),
        );
    return id;
  }

  Future<void> linkTag(int txId, int tagId) async {
    await db.into(db.transactionTags).insert(
        TransactionTagsCompanion.insert(transactionId: txId, tagId: tagId));
  }

  /// 云端"与本地完全一致"的默认版本；各用例只改其中一个键。
  ///
  /// ⚠️ 默认**不带标签**（本地默认也无标签）：否则每个用例都会先吃到一条
  /// "标签不同"的伪差异 → modifiedCount 恒为 1 → Tier 2 会**假通过**，
  /// 整张表就失去鉴别力。标签只在 tags / tagSyncIds 两个用例里出现。
  ImportTransaction cloudDefault() => ImportTransaction(
        type: 'expense',
        amount: 100,
        categoryName: '餐饮',
        categoryKind: 'expense',
        accountName: '现金',
        happenedAt: baseTime.toLocal(),
        note: 'A',
        syncId: 'tx-1',
        currencyCode: 'CNY',
        nativeAmount: 100,
      );

  // ============ 每个白名单键的"只改它"夹具 ============
  // 每个条目：指纹 item map 的该键取值对 + diff 侧的 (local 额外设置, cloud 变体)
  final cases = <String, _Case>{
    'happenedAt': _Case(
      itemA: {'happenedAt': '2026-07-01T10:00:00'},
      itemB: {'happenedAt': '2026-07-01T11:00:00'},
      cloud: () => _with(cloudDefault(), happenedAt: baseTime.add(const Duration(hours: 1)).toLocal()),
    ),
    'type': _Case(
      itemA: {'type': 'expense'},
      itemB: {'type': 'income'},
      cloud: () => _with(cloudDefault(), type: 'income'),
    ),
    'amount': _Case(
      itemA: {'amount': 100},
      itemB: {'amount': 200},
      cloud: () => _with(cloudDefault(), amount: 200),
    ),
    'nativeAmount': _Case(
      itemA: {'nativeAmount': 100},
      itemB: {'nativeAmount': 999},
      cloud: () => _with(cloudDefault(), nativeAmount: 999),
    ),
    'currencyCode': _Case(
      itemA: {'currencyCode': 'CNY'},
      itemB: {'currencyCode': 'USD'},
      cloud: () => _with(cloudDefault(), currencyCode: 'USD'),
    ),
    'originalAmount': _Case(
      itemA: {'originalAmount': 120},
      itemB: {'originalAmount': 130},
      local: () async => db.customStatement(
          "UPDATE transactions SET original_amount=120 WHERE sync_id='tx-1'"),
      cloud: () => _with(cloudDefault(), originalAmount: 130),
    ),
    'customValues': _Case(
      itemA: {'customValues': {'cf-1': 1.0}},
      itemB: {'customValues': {'cf-1': 2.0}},
      local: () async => db.customStatement(
          'UPDATE transactions SET custom_values_json=\'{"cf-1":1.0}\' '
          "WHERE sync_id='tx-1'"),
      cloud: () => _with(cloudDefault(), customValues: const {'cf-1': 2.0}),
    ),
    'excludeFromStats': _Case(
      itemA: {'excludeFromStats': false},
      itemB: {'excludeFromStats': true},
      cloud: () => _with(cloudDefault(), excludeFromStats: true),
    ),
    'excludeFromBudget': _Case(
      itemA: {'excludeFromBudget': false},
      itemB: {'excludeFromBudget': true},
      cloud: () => _with(cloudDefault(), excludeFromBudget: true),
    ),
    'categoryName': _Case(
      itemA: {'categoryName': '餐饮', 'categoryKind': 'expense'},
      itemB: {'categoryName': '交通', 'categoryKind': 'expense'},
      cloud: () => _with(cloudDefault(), categoryName: '交通'),
    ),
    'categoryKind': _Case(
      itemA: {'categoryName': '餐饮', 'categoryKind': 'expense'},
      itemB: {'categoryName': '餐饮', 'categoryKind': 'income'},
      cloud: () => _with(cloudDefault(), categoryKind: 'income'),
    ),
    'note': _Case(
      itemA: {'note': 'A'},
      itemB: {'note': 'B'},
      cloud: () => _with(cloudDefault(), note: 'B'),
    ),
    'tags': _Case(
      itemA: {'tags': '报销'},
      itemB: {'tags': '差旅'},
      local: () async => linkTag(await _txId(db), 1),
      cloud: () => _with(cloudDefault(), tagNames: const ['差旅']),
    ),
    'tagSyncIds': _Case(
      itemA: {'tagSyncIds': ['tag-a']},
      itemB: {'tagSyncIds': ['tag-b']},
      local: () async => linkTag(await _txId(db), 1),
      // 同名('报销')不同 syncId —— 检查差异是否只由 syncId 决定
      cloud: () => _with(cloudDefault(),
          tagNames: const ['报销'], tagSyncIds: const ['tag-b']),
      // 标签身份由 tags 元数据合并（importTags 按名/syncId 采纳云端身份）收敛，
      // 且交易的标签关联走本地 tag_id，因此该键不需要 diff 报 modified。
      exempt: '标签身份由 importTags 元数据合并收敛；交易关联经本地 tag_id 自然跟随，'
          '故无需 _compareTx 报 modified',
    ),
    'categorySyncIdOverride': _Case(
      itemA: {'categorySyncIdOverride': 'cat-food'},
      itemB: {'categorySyncIdOverride': 'cat-trip'},
      local: () async => db.customStatement(
          "UPDATE transactions SET category_sync_id_override='cat-food', "
          "category_id=NULL WHERE sync_id='tx-1'"),
      cloud: () => _with(cloudDefault(),
          categoryName: null, categoryKind: null, categorySyncIdOverride: 'cat-trip'),
    ),
    'accountSyncIdOverride': _Case(
      itemA: {'accountSyncIdOverride': 'acc-cash'},
      itemB: {'accountSyncIdOverride': 'acc-bank'},
      local: () async => db.customStatement(
          "UPDATE transactions SET account_sync_id_override='acc-cash', "
          "account_id=NULL WHERE sync_id='tx-1'"),
      cloud: () => _with(cloudDefault(),
          accountName: null, accountSyncIdOverride: 'acc-bank'),
    ),
    'toAccountSyncIdOverride': _Case(
      itemA: {'toAccountSyncIdOverride': 'acc-cash'},
      itemB: {'toAccountSyncIdOverride': 'acc-bank'},
      local: () async {
        await db.customStatement(
            "UPDATE transactions SET type='transfer', category_id=NULL, "
            "to_account_id=2, to_account_sync_id_override='acc-cash' "
            "WHERE sync_id='tx-1'");
      },
      cloud: () => _with(cloudDefault(),
          type: 'transfer',
          categoryName: null,
          categoryKind: null,
          tagNames: null,
          toAccountName: null,
          toAccountSyncIdOverride: 'acc-bank'),
    ),
    'accountName': _Case(
      itemA: {'accountName': '现金'},
      itemB: {'accountName': '银行卡'},
      cloud: () => _with(cloudDefault(), accountName: '银行卡'),
    ),
    'fromAccountName': _Case(
      itemA: {'fromAccountName': '现金'},
      itemB: {'fromAccountName': '银行卡'},
      local: () async => db.customStatement(
          "UPDATE transactions SET type='transfer', category_id=NULL "
          "WHERE sync_id='tx-1'"),
      cloud: () => _with(cloudDefault(),
          type: 'transfer',
          categoryName: null,
          categoryKind: null,
          tagNames: null,
          fromAccountName: '银行卡'),
    ),
    'toAccountName': _Case(
      itemA: {'toAccountName': '银行卡'},
      itemB: {'toAccountName': '现金'},
      local: () async => db.customStatement(
          "UPDATE transactions SET type='transfer', category_id=NULL, "
          "to_account_id=2 WHERE sync_id='tx-1'"),
      cloud: () => _with(cloudDefault(),
          type: 'transfer',
          categoryName: null,
          categoryKind: null,
          tagNames: null,
          toAccountName: '现金'),
    ),
    'recurringSyncId': _Case(
      itemA: {'recurringSyncId': ''},
      itemB: {'recurringSyncId': 'rec-1'},
      local: () async => db.customStatement(
          "INSERT INTO recurring_transactions (id, ledger_id, sync_id, type, "
          "amount, frequency, interval, start_date, enabled, created_at, "
          "updated_at) VALUES (1, 1, 'rec-1', 'expense', 10, 'monthly', 1, "
          "1798761600, 1, 1798761600, 1798761600)"),
      cloud: () => _with(cloudDefault(), recurringSyncId: 'rec-1'),
    ),
    'attachments': _Case(
      // 指纹读的是清单元素的 (sha256|cloudSha256, fileName, sortOrder)，
      // 不是裸字符串 —— 夹具必须给它 Map，否则两边都归一到空串、指纹相同。
      itemA: {
        'attachments': [
          {'sha256': 'sha-a', 'fileName': 'a.jpg', 'sortOrder': 0}
        ]
      },
      itemB: {
        'attachments': [
          {'sha256': 'sha-b', 'fileName': 'b.jpg', 'sortOrder': 0}
        ]
      },
      local: () async => db.into(db.transactionAttachments).insert(
            TransactionAttachmentsCompanion.insert(
              transactionId: await _txId(db),
              fileName: 'a.jpg',
              localSha256: const d.Value('sha-a'),
              sortOrder: const d.Value(0),
            ),
          ),
      cloud: () => _with(cloudDefault(),
          attachments: [const ImportAttachment(fileName: 'b.jpg', sha256: 'sha-b')]),
    ),
  };

  group('派生自实现的指纹白名单键集合', () {
    test('夹具必须穷举覆盖白名单（新增字段无处可藏）', () {
      final missing = whitelist.difference(cases.keys.toSet());
      expect(missing, isEmpty,
          reason: '指纹白名单里有键没有配套夹具：$missing —— 新增同步字段时，'
              '请在本文件补"只改该字段"的用例，否则该字段可能"指纹有、diff 没有"');
    });

    test('夹具不得包含白名单以外的键（白名单删字段时同步清理）', () {
      final extra = cases.keys.toSet().difference(whitelist);
      expect(extra, isEmpty,
          reason: '夹具里有键已不在指纹白名单：$extra —— 请同步清理');
    });

    test('Tier 2 豁免必须写明非空理由（豁免是可复核的例外，不是"懒得做"）', () {
      for (final e in cases.entries) {
        if (e.value.exempt == null) continue;
        expect(e.value.exempt!.trim(), isNotEmpty,
            reason: '${e.key} 的豁免必须写明理由');
        expect(e.value.exempt!.length, greaterThan(12),
            reason: '${e.key} 的豁免理由过于简略，无法复核');
      }
    });
  });

  group('Tier 1：指纹必须随每个白名单键变化', () {
    for (final key in whitelist) {
      test('$key → 指纹变化', () {
        final c = cases[key]!;
        final a = contentFingerprintFromMap({
          'items': [
            {
              'happenedAt': '2026-07-01T10:00:00',
              'type': 'expense',
              'amount': 100,
              ...c.itemA,
            }
          ]
        });
        final b = contentFingerprintFromMap({
          'items': [
            {
              'happenedAt': '2026-07-01T10:00:00',
              'type': 'expense',
              'amount': 100,
              ...c.itemB,
            }
          ]
        });
        expect(a, isNot(equals(b)),
            reason: '$key 未参与指纹 —— 只改它时两端指纹相同 → 判 inSync → '
                '该字段永不跨设备传播');
      });
    }
  });

  group('Tier 2：computeDiff 必须能报出每个白名单键的差异', () {
    for (final key in whitelist) {
      final c = cases[key]!;
      if (c.exempt != null) {
        test('$key → 显式豁免（${c.exempt}）', () async {
          // 豁免也要跑一遍，确认它确实"不报 modified"，避免豁免过期后无人察觉
          await seedDefault();
          await seedLocalTx();
          if (c.local != null) await c.local!();
          final preview = await service.computeDiff(
              repo: repo, ledgerId: 1, cloudTransactions: [c.cloud()]);
          final details = preview!.changes.map((e) => e.diffDetails).toList();
          expect(preview.modifiedCount, 0,
              reason: '该键已被豁免"必须报 modified"，若现在开始报了，'
                  '请删除该用例的 exempt 并让它进入严格断言。实际 changes=$details');
        });
        continue;
      }
      test('$key → 产出 modified（D-1 形状的守门人）', () async {
        await seedDefault();
        await seedLocalTx();
        if (c.local != null) await c.local!();

        final preview = await service.computeDiff(
            repo: repo, ledgerId: 1, cloudTransactions: [c.cloud()]);

        expect(preview, isNotNull);
        // 把实际 diffDetails 带进失败信息 —— 否则只看到 "Expected 1 / Actual 0"
        // 无法判断是目标键没比、还是夹具引入/漏掉了别的差异。
        final details =
            preview!.changes.map((e) => e.diffDetails).toList();
        expect(preview.modifiedCount, 1,
            reason: '$key 在指纹白名单里但 computeDiff 没报差异 —— 这正是 D-1/'
                'S11 的形状：状态卡说"有差异"，用户点「下载同步」点不出任何变更，'
                '且 merge-then-publish 会把本地旧值回传覆盖云端形成永久 ping-pong。'
                '修 _compareTx 或在用例里写明豁免理由。实际 changes=$details');
      });
    }
  });

  // ============ P1-2：锚点差异「检测到了还必须应用得下去」 ============
  //
  // 只加检测不加写入，体验会从"静默不同步"恶化成"每轮都提示有变更、点了也没用"
  // （同一批变更永远在预览里，指纹永不收敛）。本组锁定检测与应用成对。
  group('P1-2：周期锚点差异的应用必须收敛', () {
    Future<void> seedRule(String syncId) async {
      await db.customStatement(
          "INSERT INTO recurring_transactions (id, ledger_id, sync_id, type, "
          "amount, frequency, interval, start_date, enabled, created_at, "
          "updated_at) VALUES (1, 1, '$syncId', 'expense', 10, 'monthly', 1, "
          "1798761600, 1, 1798761600, 1798761600)");
    }

    test('云端有锚点、本地无 → 应用后本地写回锚点，再 diff 为空', () async {
      await seedDefault();
      await db.customStatement("DELETE FROM recurring_transactions");
      await seedLocalTx(); // 本地 recurring_id 为 NULL

      final cloud = _with(cloudDefault(), recurringSyncId: 'rec-1');
      final preview = await service.computeDiff(
          repo: repo, ledgerId: 1, cloudTransactions: [cloud]);
      expect(preview!.modifiedCount, 1, reason: '锚点差异必须被检测到');

      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview.changes,
        // 锚点解析依赖快照里的周期规则清单（importRecurrings 产出 syncId→id 映射）；
        // 分类/账户清单也必须带上 —— 真实快照是「全量 user-global 分类/账户」，
        // 缺了它们 `_resolveCategoryId/_resolveAccountId` 会解析失败并**清空**
        // 本地外键（modified 路径直接写 `categoryId`，不是"缺键不改动"语义）。
        importData: ImportData(
          categories: const [
            ImportCategory(name: '餐饮', kind: 'expense', level: 2, sortOrder: 0),
            ImportCategory(name: '交通', kind: 'expense', level: 2, sortOrder: 1),
          ],
          accounts: const [ImportAccount(name: '现金', syncId: 'acc-cash')],
          recurrings: [
            ImportRecurring(
              syncId: 'rec-1',
              type: 'expense',
              amount: 10,
              frequency: 'monthly',
              interval: 1,
              startDate: DateTime(2026, 1, 1),
            ),
          ],
        ),
      );

      final row = await (db.select(db.transactions)
            ..where((t) => t.syncId.equals('tx-1')))
          .getSingle();
      expect(row.recurringId, isNotNull,
          reason: '应用阶段必须把云端锚点写回本地，否则差异被检测出来却应用不了');

      final again = await service.computeDiff(
          repo: repo, ledgerId: 1, cloudTransactions: [cloud]);
      final rest = again!.changes.map((e) => e.diffDetails).toList();
      expect(again.isEmpty, isTrue,
          reason: '应用后必须收敛，否则每轮都报同一批变更。残留 changes=$rest');
    });

    test('云端无锚点、本地有 → 应用后本地清空锚点，再 diff 为空', () async {
      await seedDefault();
      await seedRule('rec-1');
      await seedLocalTx();
      await db.customStatement(
          "UPDATE transactions SET recurring_id=1 WHERE sync_id='tx-1'");

      final cloud = cloudDefault(); // 云端未携带 recurringSyncId
      final preview = await service.computeDiff(
          repo: repo, ledgerId: 1, cloudTransactions: [cloud]);
      expect(preview!.modifiedCount, 1);

      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview.changes,
        importData: const ImportData(
          categories: [
            ImportCategory(name: '餐饮', kind: 'expense', level: 2, sortOrder: 0),
          ],
          accounts: [ImportAccount(name: '现金', syncId: 'acc-cash')],
        ),
      );

      final row = await (db.select(db.transactions)
            ..where((t) => t.syncId.equals('tx-1')))
          .getSingle();
      expect(row.recurringId, isNull, reason: '云端无锚点即"这笔不是周期实例"');

      final again = await service.computeDiff(
          repo: repo, ledgerId: 1, cloudTransactions: [cloud]);
      final rest = again!.changes.map((e) => e.diffDetails).toList();
      expect(again.isEmpty, isTrue, reason: '残留 changes=$rest');
    });
  });
}

Future<int> _txId(PiggyDatabase db) async =>
    (await (db.select(db.transactions)..limit(1)).getSingle()).id;

class _Case {
  final Map<String, dynamic> itemA;
  final Map<String, dynamic> itemB;
  final Future<void> Function()? local;
  final ImportTransaction Function() cloud;
  final String? exempt;

  const _Case({
    required this.itemA,
    required this.itemB,
    required this.cloud,
    this.local,
    this.exempt,
  });
}

/// 基于默认云交易做"只改一处"的变体。
///
/// ⚠️ **每个可选参数都必须 `= _unset` 默认值**，并统一用
/// `p == _unset ? base.p : p` 取值。漏写默认值时参数默认是 `null`，
/// 于是每个用例都会先吃到一条"该字段被清空"的伪差异 → Tier 2 恒为 1 →
/// 整张表**假通过**（初版就踩了这个坑：`note` 漏写默认值，
/// 所有用例都带一条「备注: "A" → ""」）。传 `null` 表示显式清空。
ImportTransaction _with(
  ImportTransaction base, {
  Object? type = _unset,
  Object? amount = _unset,
  Object? categoryName = _unset,
  Object? categoryKind = _unset,
  Object? accountName = _unset,
  Object? fromAccountName = _unset,
  Object? toAccountName = _unset,
  Object? happenedAt = _unset,
  Object? note = _unset,
  Object? syncId = _unset,
  Object? currencyCode = _unset,
  Object? nativeAmount = _unset,
  Object? originalAmount = _unset,
  Object? excludeFromStats = _unset,
  Object? excludeFromBudget = _unset,
  Object? categorySyncIdOverride = _unset,
  Object? accountSyncIdOverride = _unset,
  Object? toAccountSyncIdOverride = _unset,
  Object? recurringSyncId = _unset,
  Object? tagNames = _unset,
  Object? tagSyncIds = _unset,
  Object? attachments = _unset,
  Object? customValues = _unset,
}) =>
    ImportTransaction(
      type: (type == _unset ? base.type : type) as String,
      // 数值一律经 _d()：用例里写 `200` 会被 Dart 推断成 int，
      // 直接 `as double` 会抛 "type 'int' is not a subtype of type 'double'"。
      amount: _d(amount == _unset ? base.amount : amount)!,
      categoryName: (categoryName == _unset
          ? base.categoryName
          : categoryName) as String?,
      categoryKind: (categoryKind == _unset
          ? base.categoryKind
          : categoryKind) as String?,
      accountName:
          (accountName == _unset ? base.accountName : accountName) as String?,
      fromAccountName: (fromAccountName == _unset
          ? base.fromAccountName
          : fromAccountName) as String?,
      toAccountName: (toAccountName == _unset
          ? base.toAccountName
          : toAccountName) as String?,
      happenedAt:
          (happenedAt == _unset ? base.happenedAt : happenedAt) as DateTime,
      note: (note == _unset ? base.note : note) as String?,
      syncId: (syncId == _unset ? base.syncId : syncId) as String?,
      currencyCode: (currencyCode == _unset
          ? base.currencyCode
          : currencyCode) as String?,
      nativeAmount:
          _d(nativeAmount == _unset ? base.nativeAmount : nativeAmount),
      originalAmount:
          _d(originalAmount == _unset ? base.originalAmount : originalAmount),
      excludeFromStats: (excludeFromStats == _unset
          ? base.excludeFromStats
          : excludeFromStats) as bool,
      excludeFromBudget: (excludeFromBudget == _unset
          ? base.excludeFromBudget
          : excludeFromBudget) as bool,
      categorySyncIdOverride: (categorySyncIdOverride == _unset
          ? base.categorySyncIdOverride
          : categorySyncIdOverride) as String?,
      accountSyncIdOverride: (accountSyncIdOverride == _unset
          ? base.accountSyncIdOverride
          : accountSyncIdOverride) as String?,
      toAccountSyncIdOverride: (toAccountSyncIdOverride == _unset
          ? base.toAccountSyncIdOverride
          : toAccountSyncIdOverride) as String?,
      recurringSyncId: (recurringSyncId == _unset
          ? base.recurringSyncId
          : recurringSyncId) as String?,
      tagNames: (tagNames == _unset ? base.tagNames : tagNames) as List<String>?,
      tagSyncIds:
          (tagSyncIds == _unset ? base.tagSyncIds : tagSyncIds) as List<String>?,
      attachments: (attachments == _unset ? base.attachments : attachments)
          as List<ImportAttachment>?,
      customValues: (customValues == _unset ? base.customValues : customValues)
          as Map<String, dynamic>?,
    );

const Object _unset = Object();

/// 宽容数值转换：字面量 `200` 是 int，`200.0` 是 double，统一成 double。
double? _d(Object? v) => v == null ? null : (v as num).toDouble();
