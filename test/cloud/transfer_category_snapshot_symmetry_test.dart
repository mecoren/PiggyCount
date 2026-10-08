/// 转账分类在快照中的**导出/恢复对称性**守门测试。
///
/// 【缺陷形状】（2026-10-02 真机双后端复现：S3 与 WebDAV 各 8 账本 × 5000 笔）
/// 转账行主表会残留虚拟转账分类 id（`SeedService.createTransferCategory`），
/// 而「转账无分类语义」这条口径在四处实现里只有三处落地：
///   * 指纹 `sync_fingerprint.dart`：`isTransfer ? '' : …` 归空；
///   * diff `sync_diff_service.dart`：两侧归空比较；
///   * 写库 `data_import_service.dart:1757` / `sync_diff_service.dart:860`：
///     `type == 'transfer' ? null : categoryId`；
///   * **导出**（本文件的守门对象）此前原样输出 `catInfo`，未归空。
///
/// 后果是**静默不对称**：源端快照写 `"categoryName":"Transfer"`，恢复端落 NULL
/// 后再导出写 `null` → 两端 payload **字节永久不同**，而指纹相同、diff 为空，
/// 于是既不被告警也永不收敛（差异被指纹掩盖，肉眼与既有测试都发现不了）。
///
/// 【本文件锁三件事】
///   Tier 1 导出侧：转账行 `categoryName/categoryKind` 必须为 null（且非转账行不受影响）；
///   Tier 2 恢复侧：快照携带转账分类时的转账行落库 `category_id` 为 NULL（现状语义）；
///   Tier 3 闭环：export → restore → 再 export 的 payload **逐字节相等**
///            （这是唯一能抓住本缺陷形状的断言：指纹相等不算收敛，字节相等才算）。
library;

import 'dart:convert';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

/// 规范化：剔除每次导出都会变化的 `exportedAt`，其余**保持原样、不排序**——
/// 排序会掩盖「两端 item 顺序不同」这类真实的字节差异。
String _canonical(String jsonStr) {
  final map = (jsonDecode(jsonStr) as Map).cast<String, dynamic>();
  map.remove('exportedAt');
  return jsonEncode(map);
}

Map<String, dynamic> _payload(String jsonStr) =>
    (jsonDecode(jsonStr) as Map).cast<String, dynamic>();

List<Map<String, dynamic>> _items(String jsonStr) =>
    (_payload(jsonStr)['items'] as List).cast<Map<String, dynamic>>();

/// 断言两份快照**除 `exportedAt` 外逐字节相等**；不等时打印顶层键与 items
/// 逐字段差异后失败。
///
/// 这是「导出 ↔ 恢复」唯一能抓住静默不对称的判据：`contentFingerprint` 相等
/// **不算**收敛（转账分类、载荷顺序、预算启用态三处缺陷都是「指纹相同、字节
/// 不同」）。
void _expectSameSnapshot(String first, String second, {String? hint}) {
  if (_canonical(first) == _canonical(second)) return;

  final p1 = _payload(first), p2 = _payload(second);
  final diffs = <String>[];
  for (final k in {...p1.keys, ...p2.keys}) {
    if (k == 'exportedAt' || k == 'items') continue;
    if (jsonEncode(p1[k]) != jsonEncode(p2[k])) {
      diffs.add('$k: 源=${jsonEncode(p1[k])} 恢复端=${jsonEncode(p2[k])}');
    }
  }
  final i1 = _items(first), i2 = _items(second);
  for (var i = 0; i < i1.length && i < i2.length; i++) {
    for (final k in {...i1[i].keys, ...i2[i].keys}) {
      if (jsonEncode(i1[i][k]) != jsonEncode(i2[i][k])) {
        diffs.add('items[$i](${i1[i]['syncId']}).$k: '
            '源=${jsonEncode(i1[i][k])} 恢复端=${jsonEncode(i2[i][k])}');
      }
    }
  }
  if (i1.length != i2.length) {
    diffs.add('items 数量: 源=${i1.length} 恢复端=${i2.length}');
  }
  fail('快照不闭合${hint == null ? '' : '（$hint）'}'
      '（指纹可能相同、字节却不同 → 差异被指纹掩盖）: $diffs');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase src;
  late PiggyDatabase dst;

  /// 账本 / 分类 / 账户（user-global，ledger_id=0）四件套，两端一致。
  Future<void> seedMeta(PiggyDatabase db) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency, month_start_day, sync_id) "
        "VALUES (1, '[T]账本', 'CNY', 1, 'lg-1')");
    await db.customStatement(
        "INSERT INTO categories (id, name, kind, level, sort_order, sync_id) "
        "VALUES (1, '餐饮', 'expense', 2, 0, 'cat-food')");
    // 虚拟转账分类：转账行主表会引用它（这正是「残留 categoryId」的来源）
    await db.customStatement(
        "INSERT INTO categories (id, name, kind, level, sort_order, sync_id) "
        "VALUES (2, 'Transfer', 'transfer', 1, 1, 'cat-transfer')");
    await db.customStatement(
        "INSERT INTO accounts (id, ledger_id, name, type, currency, sync_id) "
        "VALUES (1, 0, '现金', 'cash', 'CNY', 'acc-cash')");
    await db.customStatement(
        "INSERT INTO accounts (id, ledger_id, name, type, currency, sync_id) "
        "VALUES (2, 0, '银行卡', 'bank', 'CNY', 'acc-bank')");
  }

  /// 源端交易：1 转账（带残留转账分类）+ 1 支出（带分类）+ 1 收入（无分类）。
  /// happenedAt 各不相同 —— 导出排序是 happenedAt→id，同刻会让 id 兜底排序
  /// 跨设备漂移，掩盖本测试要断言的字节口径。
  Future<void> seedTxs(PiggyDatabase db) async {
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'transfer',
          amount: 100,
          categoryId: const d.Value(2),
          accountId: const d.Value(1),
          toAccountId: const d.Value(2),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 10)),
          note: const d.Value('[T]转账'),
          syncId: const d.Value('tx-transfer'),
          currencyCode: const d.Value('CNY'),
          nativeAmount: const d.Value(100),
        ));
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: 200,
          categoryId: const d.Value(1),
          accountId: const d.Value(1),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 11)),
          note: const d.Value('[T]支出'),
          syncId: const d.Value('tx-expense'),
          currencyCode: const d.Value('CNY'),
          nativeAmount: const d.Value(200),
        ));
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'income',
          amount: 300,
          accountId: const d.Value(1),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 12)),
          note: const d.Value('[T]无分类收入'),
          syncId: const d.Value('tx-income'),
          currencyCode: const d.Value('CNY'),
          nativeAmount: const d.Value(300),
        ));
  }

  setUp(() async {
    src = PiggyDatabase.forTesting(NativeDatabase.memory());
    dst = PiggyDatabase.forTesting(NativeDatabase.memory());
    await seedMeta(src);
    await seedMeta(dst); // 目标端账本行需已存在（restoreLedgerFromJson 契约）
    await seedTxs(src);
  });

  tearDown(() async {
    await src.close();
    await dst.close();
  });

  test('Tier 1 导出侧：转账行 categoryName/categoryKind 归空，非转账行不受影响', () async {
    final json = (await exportTransactionsJson(src, 1)).jsonStr;
    final items = _items(json);

    final transfer = items.firstWhere((i) => i['type'] == 'transfer');
    expect(transfer['categoryName'], isNull,
        reason: '导出侧必须与指纹/diff/恢复三侧同口径归空；'
            '否则恢复端落 NULL 后再导出为 null，两端 payload 永久不同且指纹相同');
    expect(transfer['categoryKind'], isNull, reason: '同上（categoryKind）');

    // 归空只针对转账：不得误伤普通交易的分类口径（回归保护）
    final expense = items.firstWhere((i) => i['type'] == 'expense');
    expect(expense['categoryName'], '餐饮');
    expect(expense['categoryKind'], 'expense');
    final income = items.firstWhere((i) => i['type'] == 'income');
    expect(income['categoryName'], isNull, reason: '本地无分类 → 本来就是 null');

    // 转账的双边账户锚点必须保留（归空只动分类两键，不能把转账语义也抹掉）
    expect(transfer['fromAccountName'], '现金');
    expect(transfer['toAccountName'], '银行卡');
  });

  test('Tier 2 恢复侧：快照携带转账分类时，恢复端转账行落库 category_id 为 NULL', () async {
    // 构造「旧客户端 / 修复前快照」形态：显式带 Transfer/transfer
    final old =
        (jsonDecode((await exportTransactionsJson(src, 1)).jsonStr) as Map)
            .cast<String, dynamic>();
    final oldItems = (old['items'] as List).cast<Map<String, dynamic>>();
    final transferItem = oldItems.firstWhere((i) => i['type'] == 'transfer')
      ..['categoryName'] = 'Transfer'
      ..['categoryKind'] = 'transfer';
    expect(transferItem['categoryName'], 'Transfer');

    final restored = await restoreLedgerFromJson(
        db: dst,
        repo: LocalRepository(dst),
        ledgerId: 1,
        jsonStr: jsonEncode(old));
    expect(restored, isNotNull);
    expect(restored!.inserted, 3);

    final row = await dst
        .customSelect("SELECT category_id FROM transactions "
            "WHERE sync_id = 'tx-transfer'")
        .getSingle();
    expect(row.read<int?>('category_id'), isNull,
        reason: '转账无分类语义：恢复侧按设计写 NULL');
    // 非转账行仍应落到云端分类（分类按 kind|name 解析）
    final expRow = await dst
        .customSelect("SELECT category_id FROM transactions "
            "WHERE sync_id = 'tx-expense'")
        .getSingle();
    expect(expRow.read<int?>('category_id'), isNotNull,
        reason: '普通交易的分类解析不受本次归空影响');
  });

  test('Tier 3 闭环：export → restore → export 的 payload 逐字节相等', () async {
    final first = (await exportTransactionsJson(src, 1)).jsonStr;

    final restored = await restoreLedgerFromJson(
        db: dst, repo: LocalRepository(dst), ledgerId: 1, jsonStr: first);
    expect(restored, isNotNull);
    expect(restored!.inserted, 3);

    final second = (await exportTransactionsJson(dst, 1)).jsonStr;

    // 指纹：本就相等（转账分类被归一化），不能作为收敛判据
    expect(_payload(second)['contentFingerprint'],
        _payload(first)['contentFingerprint']);

    // 字节：缺陷形状的唯一鉴别断言
    _expectSameSnapshot(first, second, hint: '导出↔恢复逐字节');
  });

  test('Tier 3b 快照 categories 缺虚拟转账分类时：恢复不抛错、转账行仍归空', () async {
    // 极端形态（对齐 data_import_service.dart:1601「transfer 永不补建分类」）：
    // 恢复端分类缓存 miss 也不得抛错、不得为转账行凭空建分类、不得写出非空分类。
    final payload =
        (jsonDecode((await exportTransactionsJson(src, 1)).jsonStr) as Map)
            .cast<String, dynamic>();
    payload['categories'] = (payload['categories'] as List)
        .where((c) => (c as Map)['kind'] != 'transfer')
        .toList();
    final json = jsonEncode(payload);

    final restored = await restoreLedgerFromJson(
        db: dst, repo: LocalRepository(dst), ledgerId: 1, jsonStr: json);
    expect(restored, isNotNull);
    expect(restored!.inserted, 3);

    final row = await dst
        .customSelect("SELECT category_id FROM transactions "
            "WHERE sync_id = 'tx-transfer'")
        .getSingle();
    expect(row.read<int?>('category_id'), isNull);

    final reExported = _items((await exportTransactionsJson(dst, 1)).jsonStr);
    final transfer = reExported.firstWhere((i) => i['type'] == 'transfer');
    expect(transfer['categoryName'], isNull,
        reason: 'cache miss 也不得回填任何分类名（否则两端又不闭合）');
    expect(transfer['categoryKind'], isNull);
  });

  test('Tier 4 顺序口径：同 happenedAt 交易在两端插入顺序不同，导出必须逐字节一致',
      () async {
    // 缺陷形状（与转账分类同构、同属「指纹相同但字节不同」）：
    // items 的兜底排序键若是**本地自增 id**，两端 id 序列独立 →
    // 同一秒记的两笔在两端排出不同先后 → payload 字节不同，而指纹对 items
    // 做的是内容全序化（顺序无关）→ 不告警、不自愈。
    final t1 = PiggyDatabase.forTesting(NativeDatabase.memory());
    final t2 = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await t1.close();
      await t2.close();
    });
    await seedMeta(t1);
    await seedMeta(t2);

    Future<void> insertPair(PiggyDatabase db, {required bool reversed}) async {
      // 两笔同刻、同内容，唯一区别是插入顺序 → 本地 id 分布相反
      final order =
          reversed ? const ['tx-b', 'tx-a'] : const ['tx-a', 'tx-b'];
      for (final syncId in order) {
        await db.into(db.transactions).insert(TransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 100,
              categoryId: const d.Value(1),
              accountId: const d.Value(1),
              happenedAt: d.Value(DateTime.utc(2026, 7, 1, 10)),
              note: const d.Value('[T]同刻'),
              syncId: d.Value(syncId),
              currencyCode: const d.Value('CNY'),
              nativeAmount: const d.Value(100),
            ));
      }
    }

    await insertPair(t1, reversed: false); // t1: tx-a=1, tx-b=2
    await insertPair(t2, reversed: true); // t2: tx-b=1, tx-a=2

    final e1 = (await exportTransactionsJson(t1, 1)).jsonStr;
    final e2 = (await exportTransactionsJson(t2, 1)).jsonStr;

    // 指纹必然相同（这正是顺序差异能被掩盖的原因），所以必须独立守门顺序
    expect(_payload(e1)['contentFingerprint'],
        _payload(e2)['contentFingerprint']);

    expect(_items(e1).map((i) => i['syncId']).toList(),
        _items(e2).map((i) => i['syncId']).toList(),
        reason: '兜底排序键用了本地自增 id → 两端同刻交易顺序不同');
    expect(_canonical(e1), _canonical(e2));
  });

  test('Tier 5 富字段闭环：全实体类型 export → restore → export 逐字节一致', () async {
    // 把 Tier 3 的闭环断言推广到全部同步实体（账本元信息 / 多币种 / 原始金额 /
    // 自定义字段值与定义 / 标签关联 / 预算 / 周期规则 / 汇率覆盖 / 四种交易类型
    // / 账单标记），任何字段出现「一端写、另一端丢」都会在此暴露。
    // 附件不在本用例范围（需要物理文件与附件落盘链路，另有专项测试）。
    final a = PiggyDatabase.forTesting(NativeDatabase.memory());
    final b = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    await seedMeta(a); // 同一份账本/分类/账户基线
    await seedMeta(b);

    // 账本元信息：自定义每月起始日（进指纹 M2）
    await a.customStatement("UPDATE ledgers SET month_start_day = 5 WHERE id = 1");
    await b.customStatement("UPDATE ledgers SET month_start_day = 5 WHERE id = 1");

    // 标签 + 自定义字段定义（text / amount 两型）
    await a.customStatement(
        "INSERT INTO tags (id, name, color, sort_order, sync_id) "
        "VALUES (1, '报销', '#ff0000', 0, 'tag-a')");
    await a.customStatement(
        "INSERT INTO custom_field_definitions "
        "(id, ledger_id, name, field_type, sort_order, sync_id) "
        "VALUES (1, 1, '商户单号', 'text', 0, 'cf-1')");
    await a.customStatement(
        "INSERT INTO custom_field_definitions "
        "(id, ledger_id, name, field_type, sort_order, sync_id) "
        "VALUES (2, 1, '原价', 'amount', 1, 'cf-2')");

    // 预算（总预算 + 分类预算，含 startDay/enabled 差异）
    await a.customStatement(
        "INSERT INTO budgets (id, sync_id, ledger_id, type, category_id, "
        "amount, period, start_day, enabled) VALUES "
        "(1, 'bud-total', 1, 'total', NULL, 5000, 'monthly', 1, 1)");
    await a.customStatement(
        "INSERT INTO budgets (id, sync_id, ledger_id, type, category_id, "
        "amount, period, start_day, enabled) VALUES "
        "(2, 'bud-cat', 1, 'category', 1, 800, 'monthly', 5, 0)");

    // 周期规则（走 companion：start_date 是 Drift DateTime 列，raw SQL 需 epoch，
    // 直接写 ISO 串会在读取时 int.parse 崩）+ 汇率覆盖
    await a.into(a.recurringTransactions).insert(
          RecurringTransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 66.5,
            frequency: 'monthly',
            startDate: DateTime.utc(2026, 1, 15),
            syncId: const d.Value('rec-1'),
            categoryId: const d.Value(1),
            accountId: const d.Value(1),
            note: const d.Value('[T]周期'),
            dayOfMonth: const d.Value(15),
          ),
        );
    await a.customStatement(
        "INSERT INTO exchange_rate_overrides "
        "(id, sync_id, base_currency, quote_currency, rate) "
        "VALUES (1, 'fx-1', 'CNY', 'USD', '0.14')");

    // 交易：支出（全字段）+ 收入（无分类）+ 转账 + 估值调整
    await a.into(a.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: 200,
          categoryId: const d.Value(1),
          accountId: const d.Value(1),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 10)),
          note: const d.Value('[T]全字段支出'),
          syncId: const d.Value('rich-expense'),
          excludeFromStats: const d.Value(true),
          excludeFromBudget: const d.Value(true),
          currencyCode: const d.Value('USD'),
          nativeAmount: const d.Value(28.5),
          originalAmount: const d.Value(150),
          customValuesJson: const d.Value('{"cf-1":"A123","cf-2":150.0}'),
        ));
    await a.into(a.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'income',
          amount: 300,
          accountId: const d.Value(1),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 11)),
          syncId: const d.Value('rich-income'),
          currencyCode: const d.Value('CNY'),
          nativeAmount: const d.Value(300),
        ));
    await a.into(a.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'transfer',
          amount: 400,
          categoryId: const d.Value(2),
          accountId: const d.Value(1),
          toAccountId: const d.Value(2),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 12)),
          note: const d.Value('[T]转账'),
          syncId: const d.Value('rich-transfer'),
          currencyCode: const d.Value('CNY'),
          nativeAmount: const d.Value(400),
        ));
    await a.into(a.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'adjustment',
          amount: -50,
          accountId: const d.Value(1),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 13)),
          syncId: const d.Value('rich-adjust'),
          currencyCode: const d.Value('CNY'),
          nativeAmount: const d.Value(-50),
        ));

    // 标签关联（在交易入库后建立）
    await a.customStatement(
        "INSERT INTO transaction_tags (transaction_id, tag_id) "
        "SELECT id, 1 FROM transactions WHERE sync_id = 'rich-expense'");

    final first = (await exportTransactionsJson(a, 1)).jsonStr;
    final restored = await restoreLedgerFromJson(
        db: b, repo: LocalRepository(b), ledgerId: 1, jsonStr: first);
    expect(restored, isNotNull);
    expect(restored!.inserted, 4);

    // 停用状态必须随快照传播：enabled 参与快照指纹，漏传会让该账本永久
    // 「有差异」却 diff 不出任何变更（Tier 5 实测暴露的第二个缺陷形状）
    final restoredBudget = await b
        .customSelect("SELECT enabled FROM budgets WHERE sync_id = 'bud-cat'")
        .getSingle();
    expect(restoredBudget.read<int>('enabled'), 0,
        reason: '云端「已停用」的分类预算在恢复端被建成启用');

    final second = (await exportTransactionsJson(b, 1)).jsonStr;

    _expectSameSnapshot(first, second, hint: '富字段全实体');
    expect(_payload(second)['contentFingerprint'],
        _payload(first)['contentFingerprint'],
        reason: '富字段往返后两端指纹必须相同');
  });

  test('Tier 6 扩展面闭环：附件 / 自定义字段边界值 / 周期转账 / 多币种边界',
      () async {
    // Tier 5 覆盖的是主链路字段；本用例补最容易"一端写、另一端丢"的边角面：
    // 附件清单、自定义字段的 0 / 负数 / 日期 / 空值形态、周期规则为转账、
    // 多币种归一化边界。
    final a = PiggyDatabase.forTesting(NativeDatabase.memory());
    final b = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async {
      await a.close();
      await b.close();
    });
    await seedMeta(a);
    await seedMeta(b);

    // 自定义字段三型：amount / date / text
    await a.customStatement(
        "INSERT INTO custom_field_definitions "
        "(id, ledger_id, name, field_type, sort_order, sync_id) VALUES "
        "(1, 1, '原价', 'amount', 0, 'cf-amount'), "
        "(2, 1, '购买日期', 'date', 1, 'cf-date'), "
        "(3, 1, '备注', 'text', 2, 'cf-text')");

    // 1) 支出 + 转账（含多币种快照字段）
    await a.into(a.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: 10,
          categoryId: const d.Value(1),
          accountId: const d.Value(1),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 9)),
          syncId: const d.Value('ext-expense'),
          currencyCode: const d.Value('CNY'),
          nativeAmount: const d.Value(10),
        ));
    await a.into(a.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'transfer',
          amount: 20,
          accountId: const d.Value(1),
          toAccountId: const d.Value(2),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 10)),
          syncId: const d.Value('ext-transfer'),
          excludeFromStats: const d.Value(true),
          currencyCode: const d.Value('CNY'),
          nativeAmount: const d.Value(20),
        ));

    // 2) 自定义字段边界值：0 / 负数 / 日期串 / 含逗号与 emoji 的文本
    await a.into(a.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: 0,
          categoryId: const d.Value(1),
          accountId: const d.Value(1),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 11)),
          syncId: const d.Value('cf-boundary'),
          currencyCode: const d.Value('CNY'),
          nativeAmount: const d.Value(0),
          originalAmount: const d.Value(0),
          customValuesJson: const d.Value(
              '{"cf-amount":-12.5,"cf-date":"2026-07-01","cf-text":"a,b 🎉"}'),
        ));

    // 3) 附件清单行（local_sha256 是快照链的内容寻址锚点）
    await a.customStatement(
        "INSERT INTO transaction_attachments (transaction_id, file_name, "
        "original_name, file_size, width, height, sort_order, local_sha256) "
        "SELECT id, 'att_1.bin', 'receipt.jpg', 1234, 100, 200, 0, "
        "'${'a' * 64}' FROM transactions WHERE sync_id = 'cf-boundary'");

    // 4) 周期规则为转账（无分类、双边账户）
    await a.into(a.recurringTransactions).insert(
          RecurringTransactionsCompanion.insert(
            ledgerId: 1,
            type: 'transfer',
            amount: 88,
            frequency: 'monthly',
            startDate: DateTime.utc(2026, 1, 20),
            syncId: const d.Value('rec-transfer'),
            accountId: const d.Value(1),
            toAccountId: const d.Value(2),
            note: const d.Value('[T]周期转账'),
            dayOfMonth: const d.Value(20),
          ),
        );

    // 5) 多币种归一化边界：currencyCode / nativeAmount 均缺省（读取端应归一为
    //    账本本币 + 记账金额）；再补一条外币
    await a.into(a.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'income',
          amount: 5,
          accountId: const d.Value(1),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 12)),
          syncId: const d.Value('cc-default'),
        ));
    await a.into(a.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: 100,
          categoryId: const d.Value(1),
          accountId: const d.Value(1),
          happenedAt: d.Value(DateTime.utc(2026, 7, 1, 13)),
          syncId: const d.Value('cc-foreign'),
          currencyCode: const d.Value('USD'),
          nativeAmount: const d.Value(14),
        ));

    final first = (await exportTransactionsJson(a, 1)).jsonStr;
    final restored = await restoreLedgerFromJson(
        db: b, repo: LocalRepository(b), ledgerId: 1, jsonStr: first);
    expect(restored, isNotNull);
    expect(restored!.inserted, 5);

    // 附件在"新增"恢复路径必须落库（否则再次导出即丢）
    final att = await b
        .customSelect("SELECT COUNT(*) AS c, MAX(local_sha256) AS s "
            "FROM transaction_attachments")
        .getSingle();
    expect(att.read<int>('c'), 1);
    expect(att.read<String?>('s'), 'a' * 64);

    final second = (await exportTransactionsJson(b, 1)).jsonStr;
    _expectSameSnapshot(first, second, hint: '扩展面（override/附件/边界值）');
    expect(_payload(second)['contentFingerprint'],
        _payload(first)['contentFingerprint']);
  });
}
