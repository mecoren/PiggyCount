/// downloadAndPreview isolate 解析改造（上线体检第六轮）的等价性回归。
///
/// 改造点：`downloadAndPreview` 此前在 UI 线程对同一份快照做两次
/// jsonDecode（一次取 version/fingerprint 元数据、一次
/// parseJsonToImportData 取业务数据），大快照下两份解析都阻塞主线程。
/// 现合并为 `parseSnapshotIsolate` 单次后台 isolate 解析。
///
/// 本测试锁定三件事：
/// 1. 元数据口径逐字段等价：version 默认 1 / contentFingerprint 缺失为
///    null / count 缺失为 null，与原主线程实现完全一致；
/// 2. 业务数据等价：ParsedSnapshot.importData 与直接调
///    parseJsonToImportData 的结果逐字段一致（真实导出快照往返）；
/// 3. 损坏输入行为一致：顶层非对象仍抛 FormatException（H1「拒绝恢复」
///    分支的上游契约不变）。
library;
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  test('真实导出快照：isolate 解析的元数据与主线程口径逐字段一致', () async {
    final ledgerId = await repo.createLedger(name: 'L', currency: 'CNY');
    final jsonStr = await exportTransactionsJson(db, ledgerId).then((e) => e.jsonStr);

    final parsed = parseSnapshotIsolate(jsonStr);
    // 与原实现的取值口径对齐：
    // (jsonDecode(jsonStr)['version'] as num?)?.toInt() ?? 1
    final legacyMap = jsonDecode(jsonStr) as Map<String, dynamic>;
    expect(parsed.version, (legacyMap['version'] as num?)?.toInt() ?? 1);
    // 审计 H6：contentFingerprint 直接内嵌取值，无默认
    expect(
        parsed.contentFingerprint, legacyMap['contentFingerprint'] as String?);
    expect(parsed.count, (legacyMap['count'] as num?)?.toInt());
  });

  test('真实导出快照：importData 与直接 parseJsonToImportData 逐字段一致',
      () async {
    final ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(
            name: 'L',
            currency: const Value('CNY'),
          ),
        );
    final accountId = await repo.createAccount(
        ledgerId: ledgerId, name: '现金', type: 'cash', currency: 'CNY');
    // 空库无默认分类，直接插入一条一级分类作为交易的分类锚点
    final categoryId = await db.customInsert(
        "INSERT INTO categories (name, kind, level, sort_order) "
        "VALUES ('餐饮', 'expense', 1, 0) RETURNING id");
    await repo.insertTransactionsBatch([
      TransactionsCompanion.insert(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 12.5,
        categoryId: Value(categoryId),
        accountId: Value(accountId),
        note: const Value('isolate 解析等价性'),
        happenedAt: Value(DateTime(2026, 9, 1, 10, 30)),
        syncId: const Value('tx-parse-equiv-1'),
      ),
    ]);

    final jsonStr = await exportTransactionsJson(db, ledgerId).then((e) => e.jsonStr);
    final parsed = parseSnapshotIsolate(jsonStr);
    final direct = parseJsonToImportData(jsonStr);

    expect(parsed.importData.accounts.length, direct.accounts.length);
    expect(parsed.importData.categories.length, direct.categories.length);
    expect(parsed.importData.tags.length, direct.tags.length);
    expect(parsed.importData.budgets.length, direct.budgets.length);
    expect(parsed.importData.recurrings.length, direct.recurrings.length);
    expect(
        parsed.importData.rateOverrides.length, direct.rateOverrides.length);
    expect(parsed.importData.ledgerSyncId, direct.ledgerSyncId);
    expect(parsed.importData.skippedItems, direct.skippedItems);

    expect(parsed.importData.transactions.length, direct.transactions.length);
    // 防空转：本用例必须真的带 1 笔交易（否则逐字段断言对空列表假通过）
    expect(parsed.importData.transactions, hasLength(1),
        reason: '插入的 1 笔交易必须出现在导出快照中');
    final p = parsed.importData.transactions.first;
    final t = direct.transactions.first;
    expect(p.type, t.type);
    expect(p.amount, t.amount);
    expect(p.note, t.note);
    expect(p.accountName, t.accountName);
    expect(p.categoryName, t.categoryName);
    expect(p.happenedAt, t.happenedAt);
    expect(p.syncId, t.syncId);
    expect(p.currencyCode, t.currencyCode);
    expect(p.nativeAmount, t.nativeAmount);
    expect(p.excludeFromStats, t.excludeFromStats);
    expect(p.excludeFromBudget, t.excludeFromBudget);
    // count 元数据与实际条目数一致（压测裁决同款口径）
    expect(parsed.count, direct.transactions.length);
  });

  test('version 缺失默认 1、count 缺失为 null（与原实现口径一致）', () {
    const minimal = '{"transactions":[],"accounts":[]}';
    final parsed = parseSnapshotIsolate(minimal);
    expect(parsed.version, 1);
    expect(parsed.count, isNull);
    expect(parsed.contentFingerprint, isNull);
    expect(parsed.importData.transactions, isEmpty);
  });

  test('顶层非 JSON 对象仍抛 FormatException（H1 拒绝恢复契约不变）', () {
    expect(() => parseSnapshotIsolate('[]'), throwsFormatException);
    expect(() => parseSnapshotIsolate('"hello"'), throwsFormatException);
  });

  test('ParsedSnapshot 可跨 isolate 传递（compute 全链路）', () async {
    final ledgerId =
        await repo.createLedger(name: 'L2', currency: 'CNY');
    final jsonStr = await exportTransactionsJson(db, ledgerId).then((e) => e.jsonStr);

    // 与生产路径同一入口：compute + 顶层函数
    final parsed = await compute(parseSnapshotIsolate, jsonStr);
    expect(parsed.importData.ledgerName, 'L2');
    expect(parsed.version, greaterThanOrEqualTo(1));
  });
}
