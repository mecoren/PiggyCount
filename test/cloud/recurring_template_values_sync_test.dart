/// v47 周期账单模板级自定义字段值的云同步一致性回归。
///
/// 关键约束（对齐 transactions_json 既有防漂移注释）：
/// - 导出**只在非空时写 `templateFieldValues` 键**，未配置模板与旧版 JSON
///   逐字节一致；
/// - 该键必须进 `contentFingerprintFromMap` 的 recurring 白名单，否则
///   「只改模板值」两端指纹相同 → 判 inSync → 该字段永不跨设备传播；
/// - 键缺失与显式 null 必须产生同一指纹（旧快照兼容）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart' show dataImportService;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  Map<String, dynamic> recurring({Object? templateValues}) => {
        'syncId': 'rc-1',
        'type': 'expense',
        'amount': 30,
        'frequency': 'monthly',
        'interval': 1,
        'startDate': '2026-01-10T00:00:00.000Z',
        if (templateValues != null) 'templateFieldValues': templateValues,
      };
  Map<String, dynamic> payload(Map<String, dynamic> rc) => {
        // contentFingerprintFromMap 对 items 是硬 cast（白名单式规范化从交易
        // 数组开始），指纹单元测试必须携带空 items。
        'items': const [],
        'recurring': [rc],
      };

  group('contentFingerprintFromMap：templateFieldValues 参与指纹', () {
    test('改动模板值 → 指纹变化（否则永不跨设备传播）', () {
      final a = contentFingerprintFromMap(payload(recurring()));
      final b = contentFingerprintFromMap(
          payload(recurring(templateValues: {'f1': 'A'})));
      expect(a, isNot(equals(b)));
    });

    test('键缺失 与 显式 null 指纹相同（旧快照兼容）', () {
      final missing = contentFingerprintFromMap(payload(recurring()));
      final explicitNull = contentFingerprintFromMap(payload({
        ...recurring(),
        'templateFieldValues': null,
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
      // 已配置模板值
      await db.customStatement(
          "INSERT INTO recurring_transactions "
          "(id, ledger_id, sync_id, type, amount, frequency, interval, "
          "start_date, template_field_values) "
          "VALUES (1, $ledgerId, 'rc-1', 'expense', 30.0, 'monthly', 1, "
          "strftime('%s', '2026-01-10 00:00:00'), '{\"f1\":\"A\"}')");
      // 未配置（存量语义）
      await db.customStatement(
          "INSERT INTO recurring_transactions "
          "(id, ledger_id, sync_id, type, amount, frequency, interval, start_date) "
          "VALUES (2, $ledgerId, 'rc-2', 'expense', 50.0, 'monthly', 1, "
          "strftime('%s', '2026-01-10 00:00:00'))");
    });

    tearDown(() async => db.close());

    test('有值模板写键；NULL 模板省略键', () async {
      final exported = await exportTransactionsJson(db, ledgerId);
      final json = jsonDecode(exported.jsonStr) as Map<String, dynamic>;
      final items = (json['recurring'] as List).cast<Map<String, dynamic>>();

      final filled = items.firstWhere((e) => e['syncId'] == 'rc-1');
      final nullRow = items.firstWhere((e) => e['syncId'] == 'rc-2');

      expect(filled['templateFieldValues'], {'f1': 'A'});
      expect(nullRow.containsKey('templateFieldValues'), isFalse);
    });

    test('parse 还原 templateFieldValues，缺失键 → null', () async {
      final exported = await exportTransactionsJson(db, ledgerId);
      final data = parseJsonToImportData(exported.jsonStr);

      final filled = data.recurrings.firstWhere((r) => r.syncId == 'rc-1');
      final empty = data.recurrings.firstWhere((r) => r.syncId == 'rc-2');

      expect(filled.templateFieldValues, {'f1': 'A'});
      expect(empty.templateFieldValues, isNull);
    });
  });

  // 与 v45 originalAmount 同款防漂移锁：恢复 → 再导出指纹必须稳定，
  // 否则缺键/空值两端各执一词 → 永不收敛的假「云端有更新」。
  // 用两个独立内存库模拟两台设备：sync_id 唯一索引是全局的，同一库内
  // 先建 A 再恢复 B 会撞 syncId（真实跨设备恢复不会有该前提）。
  group('跨设备往返：templateFieldValues 不产生假指纹冲突', () {
    late PiggyDatabase dbA;
    late PiggyDatabase dbB;

    setUp(() {
      dbA = PiggyDatabase.forTesting(NativeDatabase.memory());
      dbB = PiggyDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() async {
      await dbA.close();
      await dbB.close();
    });

    test('带值模板恢复后值一致，再导出指纹与源端一致', () async {
      final ledgerA = await dbA.into(dbA.ledgers).insert(
          LedgersCompanion.insert(
            name: 'L',
            monthStartDay: const Value(1),
          ));
      await dbA.customStatement(
          "INSERT INTO recurring_transactions "
          "(id, ledger_id, sync_id, type, amount, frequency, interval, "
          "start_date, template_field_values) "
          "VALUES (1, $ledgerA, 'rc-1', 'expense', 30.0, 'monthly', 1, "
          "strftime('%s', '2026-01-10 00:00:00'), '{\"f1\":\"A\"}')");
      final exportedA = await exportTransactionsJson(dbA, ledgerA);

      final ledgerB = await dbB.into(dbB.ledgers).insert(
          LedgersCompanion.insert(
            name: 'L',
            monthStartDay: const Value(1),
          ));
      await dataImportService.importData(
        LocalRepository(dbB),
        ledgerB,
        parseJsonToImportData(exportedA.jsonStr),
      );

      final restored = await (dbB.select(dbB.recurringTransactions)
            ..where((t) => t.ledgerId.equals(ledgerB)))
          .getSingle();
      expect(CustomFieldValueCodec.decode(restored.templateFieldValues),
          {'f1': 'A'});

      final exportedB = await exportTransactionsJson(dbB, ledgerB);
      expect(exportedB.fingerprint, exportedA.fingerprint);
    });

    test('NULL 模板恢复后仍 NULL，再导出指纹与源端一致', () async {
      final ledgerA = await dbA.into(dbA.ledgers).insert(
          LedgersCompanion.insert(
            name: 'L',
            monthStartDay: const Value(1),
          ));
      await dbA.customStatement(
          "INSERT INTO recurring_transactions "
          "(id, ledger_id, sync_id, type, amount, frequency, interval, start_date) "
          "VALUES (1, $ledgerA, 'rc-1', 'expense', 30.0, 'monthly', 1, "
          "strftime('%s', '2026-01-10 00:00:00'))");
      final exportedA = await exportTransactionsJson(dbA, ledgerA);

      final ledgerB = await dbB.into(dbB.ledgers).insert(
          LedgersCompanion.insert(
            name: 'L',
            monthStartDay: const Value(1),
          ));
      await dataImportService.importData(
        LocalRepository(dbB),
        ledgerB,
        parseJsonToImportData(exportedA.jsonStr),
      );

      final restored = await (dbB.select(dbB.recurringTransactions)
            ..where((t) => t.ledgerId.equals(ledgerB)))
          .getSingle();
      expect(restored.templateFieldValues, isNull);

      final exportedB = await exportTransactionsJson(dbB, ledgerB);
      expect(exportedB.fingerprint, exportedA.fingerprint);
    });
  });
}
