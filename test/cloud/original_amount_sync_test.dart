/// v45 原始金额的云同步一致性回归。
///
/// 关键约束（对齐 transactions_json 既有防漂移注释）：
/// - 导出**只在非空时写 `originalAmount` 键**，未填写行与旧版 JSON 逐字节一致；
/// - 该键必须进 `contentFingerprintFromMap` 白名单，否则「只改原始金额」
///   两端指纹相同 → 判 inSync → 该字段永不跨设备传播；
/// - 键缺失与显式 null 必须产生同一指纹（旧快照兼容）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart' show dataImportService;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  Map<String, dynamic> item({num? original}) => {
        'happenedAt': '2026-06-18T10:00:00',
        'type': 'expense',
        'amount': 100,
        if (original != null) 'originalAmount': original,
      };
  Map<String, dynamic> payload(Map<String, dynamic> it) => {
        'items': [it],
      };

  group('contentFingerprintFromMap：originalAmount 参与指纹', () {
    test('改动原始金额 → 指纹变化（否则永不跨设备传播）', () {
      final a = contentFingerprintFromMap(payload(item()));
      final b = contentFingerprintFromMap(payload(item(original: 120)));
      expect(a, isNot(equals(b)));
    });

    test('键缺失 与 显式 null 指纹相同（旧快照兼容）', () {
      final missing = contentFingerprintFromMap(payload(item()));
      final explicitNull = contentFingerprintFromMap(payload({
        'happenedAt': '2026-06-18T10:00:00',
        'type': 'expense',
        'amount': 100,
        'originalAmount': null,
      }));
      expect(missing, equals(explicitNull));
    });
  });

  group('export → parse 往返', () {
    late PiggyDatabase db;
    late int ledgerId;

    setUp(() async {
      db = PiggyDatabase.forTesting(NativeDatabase.memory());
      ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', monthStartDay: const Value(1)));
      // 已填写
      await db.customStatement(
          "INSERT INTO transactions (id, ledger_id, type, amount, original_amount) "
          "VALUES (1, $ledgerId, 'expense', 100.0, 120.0)");
      // 未填写（存量语义）
      await db.customStatement(
          "INSERT INTO transactions (id, ledger_id, type, amount) "
          "VALUES (2, $ledgerId, 'expense', 50.0)");
    });

    tearDown(() async => db.close());

    test('有值行写键；NULL 行（仅手工插库/旧快照）省略键', () async {
      final exported = await exportTransactionsJson(db, ledgerId);
      final json = jsonDecode(exported.jsonStr) as Map<String, dynamic>;
      final items = (json['items'] as List).cast<Map<String, dynamic>>();

      final filled = items.firstWhere((e) => e['amount'] == 100.0);
      final nullRow = items.firstWhere((e) => e['amount'] == 50.0);

      expect(filled['originalAmount'], 120.0);
      // v45 起写入路径与迁移都兜底，业务数据不会出现 NULL；这里的省略键
      // 是给「旧快照 / 手工插库」留的防御 —— 不写 `?? amount` 兜底值，
      // 才能让未携带该键的旧数据与显式空值产生同一指纹。
      expect(nullRow.containsKey('originalAmount'), isFalse);
    });

    test('parse 还原 originalAmount，缺失键 → null', () async {
      final exported = await exportTransactionsJson(db, ledgerId);
      final data = parseJsonToImportData(exported.jsonStr);

      final filled = data.transactions.firstWhere((t) => t.amount == 100.0);
      final empty = data.transactions.firstWhere((t) => t.amount == 50.0);

      expect(filled.originalAmount, 120.0);
      expect(empty.originalAmount, isNull);
    });
  });

  // A3：导入侧曾对缺键兜底成 `amount`（「每条明细都有原始金额」），而导出侧
  // 是「仅非空才写键」—— 两者不对称：跨设备恢复一次就把「未填写」变成
  // 「手填了等于记账金额的值」，两端指纹不同 → 用户必然看到一次假的
  // 「云端有更新」（下一轮才收敛）。本组锁定「恢复 → 再导出」指纹稳定。
  group('跨设备往返：缺失键的 originalAmount 不产生假指纹冲突', () {
    late PiggyDatabase db;

    setUp(() => db = PiggyDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() async => db.close());

    test('缺键行恢复后仍为 NULL，再导出指纹与源端一致', () async {
      // ── 源账本 A：一笔未填写原始金额的交易（旧快照语义）
      final ledgerA = await db.into(db.ledgers).insert(LedgersCompanion.insert(
            name: 'L',
            monthStartDay: const Value(1),
          ));
      await db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: ledgerA,
            type: 'expense',
            amount: 100,
            happenedAt: Value(DateTime.utc(2026, 6, 18, 10)),
          ));
      final exportedA = await exportTransactionsJson(db, ledgerA);

      // ── 目标账本 B：走「清空后导入」的恢复路径喂同一份快照
      final ledgerB = await db.into(db.ledgers).insert(LedgersCompanion.insert(
            name: 'B',
            monthStartDay: const Value(1),
          ));
      await dataImportService.importData(
        LocalRepository(db),
        ledgerB,
        parseJsonToImportData(exportedA.jsonStr),
      );

      // 恢复后列必须是 NULL，而不是被兜底成 amount。
      final restored = await (db.select(db.transactions)
            ..where((t) => t.ledgerId.equals(ledgerB)))
          .getSingle();
      expect(restored.originalAmount, isNull,
          reason: '缺键恢复后应保持「未填写」，读取/统计侧再 COALESCE 兜底');
      expect(restored.amount, 100.0);

      // B 再导出：指纹与 A 完全一致 → 不会误判「云端有更新」。
      final exportedB = await exportTransactionsJson(db, ledgerB);
      expect(exportedB.fingerprint, exportedA.fingerprint);
      final itemsB =
          (jsonDecode(exportedB.jsonStr) as Map<String, dynamic>)['items'] as List;
      expect((itemsB.single as Map<String, dynamic>).containsKey('originalAmount'),
          isFalse);
    });
  });
}
