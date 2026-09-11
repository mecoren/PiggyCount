/// S3 快照同步往返一致性验证（真实 app 代码）
///
/// 模拟用户在 127.0.0.1:16384 注入数据后「同步到 S3」、在 16416「从 S3 同步到本地」：
///   1. 打开真实拉取并注入过的 16384 库（scripts/live_db/live_16384.sqlite）
///   2. 对 6 个账本逐一调用 exportTransactionsJson —— 这正是 TransactionsSyncManager
///      上传到 S3 的 ledger_<id>.json 快照内容
///   3. 新建一个空库代表 16416 设备，对每个云端账本 JSON 调用 restoreLedgerFromJson
///      （即 downloadAndRestoreToCurrentLedger / downloadRemoteLedger 的落地逻辑）
///   4. 逐表比较两端数据，输出一致性报告
///
/// 注意：网络传输（storage.upload/download）被略过，直接 export→import，
/// 因为 S3 快照的内容与缺陷完全由序列化/反序列化代码决定，与传输层无关。

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

const String kSourceDbPath = 'scripts/live_db/live_16384.sqlite';
const String kReportPath = 'scripts/live_db/roundtrip_report.txt';

Future<int> _count(PiggyDatabase db, String table) async {
  final rows = await db.customSelect('SELECT COUNT(*) AS c FROM $table').get();
  return rows.first.read<int>('c')!;
}

Future<Map<String, int>> _accountTypeDist(PiggyDatabase db) async {
  final rows = await db.customSelect(
          'SELECT type, COUNT(*) AS c FROM accounts GROUP BY type')
      .get();
  return {for (final r in rows) r.read<String>('type'): r.read<int>('c')!};
}

/// 按交易类型统计。总数+金额只能间接暴露丢失，按类型断言才能一眼定位
/// "某个类型整批被吞掉"——adjustment 曾因导入白名单漏登记而全量丢失。
Future<Map<String, int>> _txTypeDist(PiggyDatabase db) async {
  final rows = await db.customSelect(
          'SELECT type, COUNT(*) AS c FROM transactions GROUP BY type')
      .get();
  return {for (final r in rows) r.read<String>('type'): r.read<int>('c')!};
}

Future<Map<int, int>> _txPerLedger(PiggyDatabase db) async {
  final rows = await db.customSelect(
          'SELECT ledger_id, COUNT(*) AS c FROM transactions GROUP BY ledger_id')
      .get();
  return {for (final r in rows) r.read<int>('ledger_id'): r.read<int>('c')!};
}

Future<Map<int, double>> _txSumPerLedger(PiggyDatabase db) async {
  final rows = await db.customSelect(
          'SELECT ledger_id, COALESCE(SUM(amount),0) AS s FROM transactions GROUP BY ledger_id')
      .get();
  return {
    for (final r in rows) r.read<int>('ledger_id'): r.read<double>('s')!
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('S3 快照往返：16384 -> S3 -> 16416 一致性', () async {
    final report = StringBuffer();
    report.writeln('===== S3 快照同步往返一致性报告 =====');
    report.writeln('源库(16384): $kSourceDbPath');
    report.writeln('时间: ${DateTime.now().toUtc().toIso8601String()}');
    report.writeln('');

    // ---- 源端（16384）：打开真实注入库 ----
    final src = PiggyDatabase.forTesting(NativeDatabase(File(kSourceDbPath)));
    final srcLedgers = await (src.select(src.ledgers)
          ..orderBy([(l) => drift.OrderingTerm.asc(l.id)]))
        .get();

    // ---- 上传到 S3：每个账本导出快照 ----
    final snapshots = <int, String>{};
    final snapshotMeta = <int, Map<String, dynamic>>{};
    for (final lg in srcLedgers) {
      final json = await exportTransactionsJson(src, lg.id).then((e) => e.jsonStr);
      snapshots[lg.id] = json;
      final m = (jsonDecode(json) as Map).cast<String, dynamic>();
      snapshotMeta[lg.id] = {
        'ledgerName': m['ledgerName'],
        'currency': m['currency'],
        'monthStartDay': m['monthStartDay'],
        'count': m['count'],
        'accounts': (m['accounts'] as List?)?.length ?? 0,
        'categories': (m['categories'] as List?)?.length ?? 0,
        'tags': (m['tags'] as List?)?.length ?? 0,
        'budgets': (m['budgets'] as List?)?.length ?? 0,
        'recurring': (m['recurring'] as List?)?.length ?? 0,
        'exchangeRateOverrides':
            (m['exchangeRateOverrides'] as List?)?.length ?? 0,
        'items': (m['items'] as List?)?.length ?? 0,
      };
      report.writeln(
          '  [S3 上传] ledger id=${lg.id} ${lg.name} -> '
          'accounts=${snapshotMeta[lg.id]!['accounts']} '
          'categories=${snapshotMeta[lg.id]!['categories']} '
          'tags=${snapshotMeta[lg.id]!['tags']} '
          'budgets=${snapshotMeta[lg.id]!['budgets']} '
          'recurring=${snapshotMeta[lg.id]!['recurring']} '
          'exchangeRateOverrides=${snapshotMeta[lg.id]!['exchangeRateOverrides']} '
          'items=${snapshotMeta[lg.id]!['items']}');
    }
    report.writeln('');

    // ---- 目标端（16416）：空库，逐账本从 S3 恢复 ----
    final dst = PiggyDatabase.forTesting(NativeDatabase.memory());
    final dstRepo = LocalRepository(dst);

    for (final lg in srcLedgers) {
      final json = snapshots[lg.id]!;
      // 新建账本行（模拟 downloadRemoteLedger 创建本地账本）
      await dst.into(dst.ledgers).insert(LedgersCompanion.insert(
            id: drift.Value(lg.id),
            name: lg.name,
            currency: drift.Value(lg.currency),
            monthStartDay: drift.Value(lg.monthStartDay),
            syncId: drift.Value(lg.id.toString()),
          ));
      try {
        final r = await restoreLedgerFromJson(
            db: dst, repo: dstRepo, ledgerId: lg.id, jsonStr: json);
        report.writeln(
            '  [S3 下载恢复] ledger id=${lg.id} ${lg.name} -> '
            'inserted=${r?.inserted} deletedDup=${r?.deletedDup}');
      } catch (e, st) {
        report.writeln(
            '  [S3 下载恢复 ERROR] ledger id=${lg.id} ${lg.name}: $e');
        report.writeln('    $st');
      }
    }
    report.writeln('');

    // ---- 一致性比较 ----
    final mismatches = <String>[];
    void check(String name, int a, int b) {
      final ok = a == b;
      if (!ok) mismatches.add('$name: 源=$a 目标=$b');
      report.writeln('  ${ok ? 'OK  ' : 'FAIL'} $name: 源=$a 目标=$b');
    }

    report.writeln('===== 逐表行数比较 =====');
    for (final t in [
      'ledgers',
      'accounts',
      'categories',
      'transactions',
      'tags',
      'budgets',
      'recurring_transactions',
      'exchange_rate_overrides',
    ]) {
      check(t, await _count(src, t), await _count(dst, t));
    }

    report.writeln('');
    report.writeln('===== 账户类型分布比较（资产类账户是否齐全）=====');
    final sa = await _accountTypeDist(src);
    final da = await _accountTypeDist(dst);
    final allTypes = {...sa.keys, ...da.keys};
    for (final ty in allTypes) {
      check('account.$ty', sa[ty] ?? 0, da[ty] ?? 0);
    }

    report.writeln('');
    report.writeln('===== 交易类型分布比较（含 adjustment 估值调整）=====');
    final stt = await _txTypeDist(src);
    final dtt = await _txTypeDist(dst);
    for (final ty in {...stt.keys, ...dtt.keys}) {
      check('txType.$ty', stt[ty] ?? 0, dtt[ty] ?? 0);
    }

    report.writeln('');
    report.writeln('===== 每账本交易数比较 =====');
    final stx = await _txPerLedger(src);
    final dtx = await _txPerLedger(dst);
    for (final id in {...stx.keys, ...dtx.keys}) {
      check('tx.ledger$id', stx[id] ?? 0, dtx[id] ?? 0);
    }

    report.writeln('');
    report.writeln('===== 每账本交易金额合计比较 =====');
    final ssum = await _txSumPerLedger(src);
    final dsum = await _txSumPerLedger(dst);
    for (final id in {...ssum.keys, ...dsum.keys}) {
      final a = ssum[id] ?? 0, b = dsum[id] ?? 0;
      final ok = (a - b).abs() < 0.01;
      if (!ok) mismatches.add('sum.ledger$id: 源=$a 目标=$b');
      report.writeln('  ${ok ? 'OK  ' : 'FAIL'} sum.ledger$id: 源=$a 目标=$b');
    }

    report.writeln('');
    if (mismatches.isEmpty) {
      report.writeln('结论：两端完全一致，八张同步表（含 budgets / '
          'recurring_transactions / exchange_rate_overrides 与资产类账户）'
          '经 S3 快照往返后均无丢失。');
    } else {
      report.writeln('结论：发现 ${mismatches.length} 处不一致：');
      for (final m in mismatches) report.writeln('  - $m');
    }

    // 落盘报告
    await File(kReportPath).writeAsString(report.toString());
    // 同时打到日志便于 CI / 终端查看
    print(report.toString());

    await src.close();
    await dst.close();

    expect(mismatches, isEmpty,
        reason: 'S3 快照往返存在不一致:\n${mismatches.join('\n')}');
  });
}
