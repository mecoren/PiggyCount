// PiggyCount 同步功能端到端测试辅助入口（临时文件，不属于正式 App 构建）。
//
// 用途：在真机/模拟器上驱动**与 App 完全相同的 Repository + 同步栈**，
// 完成「批量造数 / 数据指纹导出 / 定向变更」三件事，配合 UI 按钮完成
// 跨设备同步一致性验证。
//
// 运行方式：
//   flutter run -d <device> --flavor dev -t tool/sync_e2e/main.dart \
//     --dart-define=E2E_CMD=probe
// 可选 define：E2E_LEDGERS（账本数，默认 8）、E2E_TX（每账本交易数，默认 5000）
//
// 命令：
//   probe  只读探测：当前激活后端、各后端配置是否存在、库内行数、E2EE 状态
//   seed   批量造数（幂等：已存在 [E2E] 前缀账本则跳过）
//   mutate 在指定账本上做增/改/删，用于验证双向同步
//   dump   导出每个账本快照指纹 + 归一化 payload 落盘，供跨设备逐字节比对
//
// 安全约束：本文件**从不写入、修改或删除任何云服务配置**，只读。
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter/widgets.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart'
    show CloudBackendType;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/encryption_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';

const String _cmd = String.fromEnvironment('E2E_CMD', defaultValue: 'probe');
const int _ledgerCount = int.fromEnvironment('E2E_LEDGERS', defaultValue: 8);
const int _txPerLedger = int.fromEnvironment('E2E_TX', defaultValue: 5000);

/// 逗号分隔的账本 syncId 列表：造数时按顺序复用这些身份，
/// 使上传覆盖云端**既有槽位**而不是新增孤儿槽位（避免云端槽位翻倍）。
const String _syncIdsCsv = String.fromEnvironment('E2E_SYNC_IDS');

const String _e2ePrefix = '[E2E]';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  final out = <String, dynamic>{'cmd': _cmd};
  try {
    switch (_cmd) {
      case 'probe':
        await _probe(container, out);
      case 'seed':
        await _seed(container, out);
      case 'mutate':
        await _mutate(container, out);
      case 'dump':
        await _dump(container, out);
      case 'wipe':
        await _wipe(container, out);
      case 'set-backend':
        await _setBackend(container, out);
      case 'checks':
        await _checks(container, out);
      case 'netcheck':
        // 后端可达性探测：分别试 WebDAV / S3 端点，记录状态码与错误
        final st = container.read(cloudServiceStoreProvider);
        final wd = await st.loadWebdav();
        final s3 = await st.loadS3();
        final probes = <Map<String, dynamic>>[];
        if (wd?.webdavUrl != null && wd!.webdavUrl!.isNotEmpty) {
          probes.add(await _probeUrl('webdav', wd.webdavUrl!));
        }
        if (s3?.s3Endpoint != null && s3!.s3Endpoint!.isNotEmpty) {
          var ep = s3.s3Endpoint!;
          if (!ep.startsWith('http')) {
            ep = 'https://$ep';
          }
          probes.add(await _probeUrl('s3', ep));
        }
        out['probes'] = probes;
      case 'set-ledger':
        // 修正 current_ledger_id 指向一个真实存在的账本（仅 prefs，
        // 不触碰任何云配置）。清库/换库后 UI 才能正常渲染同步页。
        final prefs = await SharedPreferences.getInstance();
        final row = await container
            .read(databaseProvider)
            .customSelect('SELECT MIN(id) AS id FROM ledgers')
            .getSingleOrNull();
        final ledgerId = row?.read<int?>('id');
        if (ledgerId != null) {
          await prefs.setInt('current_ledger_id', ledgerId);
        }
        out['currentLedgerId'] = ledgerId;
      case 'rename':
        // 按 syncId 精确改名一个账本：用于构造「云端账本名与本地不同」的
        // 启动检查场景（本地改名 + 上传 → 另一端启动应出现信息提示）
        final syncId = const String.fromEnvironment('E2E_SYNC_ID');
        final newName = const String.fromEnvironment('E2E_NEW_NAME');
        final repo = container.read(repositoryProvider);
        final all = await repo.getAllLedgers();
        final target = all.firstWhere((l) => l.syncId == syncId);
        final before = target.name;
        await repo.updateLedgerName(id: target.id, name: newName);
        out['renamed'] = {
          'id': target.id,
          'syncId': syncId,
          'from': before,
          'to': newName,
        };
      case 'reset':
        // 组合命令：清业务数据 →（可选）造数 → 切换激活后端
        await _wipe(container, out);
        if (const bool.fromEnvironment('E2E_SEED', defaultValue: true)) {
          await _seed(container, out);
        }
        if (const String.fromEnvironment('E2E_BACKEND').isNotEmpty) {
          await _setBackend(container, out);
        }
      default:
        out['error'] = '未知命令: $_cmd';
    }
  } catch (e, st) {
    out['error'] = '$e';
    out['stack'] = '$st';
  }

  // 结果双通道输出：① print 走 VM Service 回传给 flutter run；② 落盘到
  // 应用文档目录 e2e-result/，可通过 run-as pull 取回（更可靠）。
  final encoded = const JsonEncoder().convert(out);
  await _writeResult(encoded);
  print('###E2E_BEGIN###');
  print(encoded);
  print('###E2E_END###');
  container.dispose();
  await Future<void>.delayed(const Duration(seconds: 2));
  exit(0);
}

Future<void> _writeResult(String encoded) async {
  try {
    final dir = Directory(
      p.join((await getApplicationDocumentsDirectory()).path, 'e2e-result'),
    );
    await dir.create(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    await File(p.join(dir.path, '$_cmd-$stamp.json')).writeAsString(encoded);
    // 固定名副本：便于宿主机用固定路径取回
    await File(p.join(dir.path, '$_cmd-latest.json')).writeAsString(encoded);
  } catch (_) {
    // 结果落盘失败不影响主流程（print 通道仍可用）
  }
}

// ============================ probe ============================

Future<void> _probe(ProviderContainer c, Map<String, dynamic> out) async {
  final store = c.read(cloudServiceStoreProvider);
  final active = await store.loadActive();
  final webdav = await store.loadWebdav();
  final s3 = await store.loadS3();
  final supabase = await store.loadSupabase();

  out['activeType'] = active.type.name;
  out['activeValid'] = active.valid;
  out['webdavConfigured'] = webdav != null;
  out['webdavUrl'] = webdav?.webdavUrl;
  out['webdavRemotePath'] = webdav?.webdavRemotePath;
  out['webdavUserFilled'] = (webdav?.webdavUsername ?? '').isNotEmpty;
  out['webdavPasswordFilled'] = (webdav?.webdavPassword ?? '').isNotEmpty;
  out['s3Configured'] = s3 != null;
  out['s3Endpoint'] = s3?.s3Endpoint;
  out['s3Region'] = s3?.s3Region;
  out['s3Bucket'] = s3?.s3Bucket;
  out['s3Secure'] = s3?.s3UseSSL;
  out['s3AccessKeyFilled'] = (s3?.s3AccessKey ?? '').isNotEmpty;
  out['s3SecretKeyFilled'] = (s3?.s3SecretKey ?? '').isNotEmpty;
  out['supabaseConfigured'] = supabase != null;

  final prefs = await SharedPreferences.getInstance();
  out['pref_encEnabled'] = prefs.getBool('piggycount_enc_enabled');
  out['pref_currentLedgerId'] = prefs.getInt('current_ledger_id');
  out['pref_cloudActiveType'] = prefs.getString('cloud_active_type');
  out['pref_multiDeviceSync'] = prefs.getBool('multi_device_sync');

  final encryption = c.read(encryptionServiceProvider);
  out['encEnabled'] = await encryption.isEnabled;
  out['encHasActiveKey'] = await encryption.hasActiveKey;

  out['tables'] = await _tableCounts(c.read(databaseProvider));
  out['ledgerList'] = await _ledgerList(c.read(databaseProvider));
}

// ============================ seed ============================

Future<void> _seed(ProviderContainer c, Map<String, dynamic> out) async {
  final db = c.read(databaseProvider);
  final repo = c.read(repositoryProvider);
  final sw = Stopwatch()..start();

  // 幂等保护：已有 E2E 账本则直接返回
  final existing = await db.select(db.ledgers).get();
  final already = existing.where((l) => l.name.startsWith(_e2ePrefix)).toList();
  if (already.isNotEmpty) {
    out['skipped'] = true;
    out['reason'] = '已存在 ${already.length} 个 $_e2ePrefix 账本，跳过造数';
    out['ledgerList'] = await _ledgerList(db);
    return;
  }

  // 1) 基础种子：一级分类 + 虚拟转账分类（不建默认账本，避免多出第 9 个账本）
  await db.ensureSeed(
    currency: 'CNY',
    useHierarchicalCategories: false,
    createDefaultLedger: false,
  );

  // 2) 账户（user-global，跨账本共用）：覆盖微信/支付宝/银行卡/信用卡/多币种
  final wechatAcc = await repo.createAccount(
    ledgerId: 0,
    name: '微信支付',
    type: 'bank_card',
    currency: 'CNY',
    bankName: '微信零钱',
    note: '微信支付渠道账户',
  );
  final alipayAcc = await repo.createAccount(
    ledgerId: 0,
    name: '支付宝',
    type: 'bank_card',
    currency: 'CNY',
    bankName: '支付宝余额',
    note: '支付宝渠道账户',
  );
  final cashAcc = await repo.createAccount(
    ledgerId: 0,
    name: '现金钱包',
    type: 'cash',
    currency: 'CNY',
  );
  final debitAcc = await repo.createAccount(
    ledgerId: 0,
    name: '招商银行储蓄卡',
    type: 'bank_card',
    currency: 'CNY',
    bankName: '招商银行',
    cardLastFour: '8899',
    initialBalance: 12000.5,
  );
  final creditAcc = await repo.createAccount(
    ledgerId: 0,
    name: '中信信用卡',
    type: 'credit_card',
    currency: 'CNY',
    creditLimit: 50000,
    billingDay: 5,
    paymentDueDay: 23,
    bankName: '中信银行',
    cardLastFour: '1024',
  );
  final usdAcc = await repo.createAccount(
    ledgerId: 0,
    name: 'USD 现金',
    type: 'cash',
    currency: 'USD',
    initialBalance: 300,
  );
  final hiddenAcc = await repo.createAccount(
    ledgerId: 0,
    name: '已停用储蓄卡',
    type: 'bank_card',
    currency: 'CNY',
  );
  await repo.setAccountHidden(hiddenAcc, true);

  final accountIds = <int>[
    wechatAcc,
    alipayAcc,
    cashAcc,
    debitAcc,
    creditAcc,
    usdAcc,
  ];

  // 3) 标签（含微信/支付宝）
  final tagWechat = await repo.createTag(name: '微信支付', color: '#07C160');
  final tagAlipay = await repo.createTag(name: '支付宝', color: '#1677FF');
  final tagReimburse = await repo.createTag(name: '可报销', color: '#FF9800');
  final tagTravel = await repo.createTag(name: '出差', color: '#9C27B0');

  // 4) 分类（一级），拆成支出/收入两组供交易引用
  final categories = await repo.getAllCategories();
  final expenseCats = categories
      .where((x) => x.kind == 'expense' && x.level == 1)
      .map((x) => x.id)
      .toList();
  final incomeCats = categories
      .where((x) => x.kind == 'income' && x.level == 1)
      .map((x) => x.id)
      .toList();
  final transferCat = await db
      .customSelect("SELECT id FROM categories WHERE kind = 'transfer' LIMIT 1")
      .getSingleOrNull();
  final transferCatId = transferCat?.read<int>('id');

  // 5) 账本：1 个历史账本 + 7 个近期账本
  final now = DateTime(2026, 10, 1);
  final reuseSyncIds = _syncIdsCsv
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  final ledgerIds = <int>[];
  for (var i = 0; i < _ledgerCount; i++) {
    final isHistory = i == 0;
    final name =
        isHistory ? '$_e2ePrefix历史账本-1999至2018' : '$_e2ePrefix近期账本-第$i册';
    final id = await repo.createLedger(
      name: name,
      currency: i == 6 ? 'USD' : 'CNY',
    );
    ledgerIds.add(id);
    if (isHistory) {
      // 历史账本改月起始日，验证 ledger meta 随快照跨设备传播
      await repo.updateLedger(id: id, monthStartDay: 5);
    }
    // 复用既有账本身份（覆盖云端原槽位，不产生孤儿槽位）
    if (i < reuseSyncIds.length) {
      await (db.update(db.ledgers)..where((l) => l.id.equals(id)))
          .write(LedgersCompanion(syncId: Value(reuseSyncIds[i])));
    }
  }

  // 6) 每个账本的自定义字段定义（账本级隔离）
  final fieldKeysByLedger = <int, List<String>>{};
  for (final ledgerId in ledgerIds) {
    await repo.createDefinition(
      ledgerId: ledgerId,
      name: '商户单号',
      fieldType: 'text',
      sortOrder: 0,
    );
    await repo.createDefinition(
      ledgerId: ledgerId,
      name: '原价',
      fieldType: 'amount',
      sortOrder: 1,
    );
    await repo.createDefinition(
      ledgerId: ledgerId,
      name: '购买日期',
      fieldType: 'date',
      sortOrder: 2,
    );
    final defs = await db.customSelect(
      'SELECT sync_id FROM custom_field_definitions WHERE ledger_id = ? ORDER BY sort_order',
      variables: [Variable<int>(ledgerId)],
    ).get();
    fieldKeysByLedger[ledgerId] = defs
        .map((r) => r.read<String>('sync_id'))
        .where((s) => s.isNotEmpty)
        .toList();
  }

  // 7) 预算 / 周期规则 / 手动汇率覆盖（均随账本快照同步）
  var budgetCount = 0;
  var recurringCount = 0;
  for (final ledgerId in ledgerIds) {
    await repo.createBudget(
      ledgerId: ledgerId,
      type: 'total',
      amount: 20000,
      period: 'monthly',
      startDay: 1,
    );
    await repo.createBudget(
      ledgerId: ledgerId,
      type: 'category',
      categoryId: expenseCats[0],
      amount: 3000,
      period: 'monthly',
    );
    await repo.createBudget(
      ledgerId: ledgerId,
      type: 'category',
      categoryId: expenseCats[1],
      amount: 1500,
      period: 'monthly',
    );
    budgetCount += 3;

    await repo.addRecurringTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: 25.5,
      categoryId: expenseCats[0],
      accountId: wechatAcc,
      note: '房租月付-周期规则',
      frequency: 'monthly',
      interval: 1,
      dayOfMonth: 8,
      startDate: DateTime(2024, 1, 8),
    );
    await repo.addRecurringTransaction(
      ledgerId: ledgerId,
      type: 'income',
      amount: 18000,
      categoryId: incomeCats[0],
      accountId: debitAcc,
      note: '工资-周期规则',
      frequency: 'monthly',
      interval: 1,
      dayOfMonth: 15,
      startDate: DateTime(2024, 1, 15),
    );
    recurringCount += 2;
  }
  await repo.setOverride(base: 'CNY', quote: 'USD', rate: '0.14');
  await repo.setOverride(base: 'CNY', quote: 'JPY', rate: '20.5');
  await repo.setOverride(base: 'CNY', quote: 'EUR', rate: '0.13');

  // 8) 交易：按账本批量生成
  const merchants = [
    '美团外卖',
    '滴滴出行',
    '全家便利店',
    '永辉超市',
    '星巴克',
    '菜鸟驿站',
    '肯德基',
    '京东商城',
    '中石化加油',
    '国家电网',
  ];
  final rnd = Random(20261002);
  var totalTx = 0;
  final detail = <Map<String, dynamic>>[];
  for (var i = 0; i < ledgerIds.length; i++) {
    final ledgerId = ledgerIds[i];
    final isHistory = i == 0;
    final start = isHistory
        ? DateTime(1999, 1, 1)
        : now.subtract(Duration(days: 180 * i));
    final end = isHistory
        ? DateTime(2018, 12, 31)
        : now.subtract(Duration(days: 180 * (i - 1)));
    // 用「秒」做随机跨度：20 年按毫秒算会超过 Random.nextInt 的 2^32 上界
    final spanSeconds = end.difference(start).inSeconds;

    final companions = <TransactionsCompanion>[];
    final tagIndex = <int, List<int>>{};
    final fieldKeys = fieldKeysByLedger[ledgerId] ?? const <String>[];

    for (var j = 0; j < _txPerLedger; j++) {
      final roll = rnd.nextDouble();
      final String type;
      if (roll < 0.78) {
        type = 'expense';
      } else if (roll < 0.90) {
        type = 'income';
      } else if (roll < 0.96) {
        type = 'transfer';
      } else {
        type = 'adjustment';
      }

      final happenedAt = start.add(
        Duration(seconds: spanSeconds <= 0 ? 0 : rnd.nextInt(spanSeconds)),
      );

      int? categoryId;
      if (type == 'expense') {
        categoryId = expenseCats[rnd.nextInt(expenseCats.length)];
      } else if (type == 'income') {
        categoryId = incomeCats[rnd.nextInt(incomeCats.length)];
      } else if (type == 'transfer') {
        categoryId = transferCatId;
      }

      final accountId = accountIds[rnd.nextInt(accountIds.length)];
      int? toAccountId;
      if (type == 'transfer') {
        do {
          toAccountId = accountIds[rnd.nextInt(accountIds.length)];
        } while (toAccountId == accountId);
      }

      final double amount;
      if (type == 'transfer') {
        amount = ((rnd.nextInt(49000) + 1000) / 100);
      } else if (type == 'adjustment') {
        amount = ((rnd.nextInt(200000) - 100000) / 100);
      } else {
        amount = ((rnd.nextInt(200000) + 100) / 100);
      }

      // 微信 / 支付宝交易：历史账本用「现金/银行」口径，近期账本才带渠道备注
      String? note;
      if (!isHistory) {
        if (j % 7 == 0) {
          note = '微信支付-${merchants[j % merchants.length]}';
        } else if (j % 7 == 3) {
          note = '支付宝-${merchants[(j + 3) % merchants.length]}';
        } else if (j % 11 == 5) {
          note = '现金消费-${merchants[(j + 5) % merchants.length]}';
        }
      } else {
        note = j % 5 == 0 ? '银行取现-第${j % 100}笔' : '现金消费-1999年前后';
      }

      final tags = <int>[];
      if (!isHistory) {
        if (j % 13 == 0) tags.add(tagWechat);
        if (j % 17 == 0) tags.add(tagAlipay);
      }
      if (j % 29 == 0) tags.add(tagReimburse);
      if (j % 41 == 0) tags.add(tagTravel);
      if (tags.isNotEmpty) tagIndex[j] = tags;

      // 多币种：每 101 笔一笔 USD 原币
      final bool multiCurrency = j % 101 == 0;
      Map<String, dynamic>? customValues;
      if (fieldKeys.length >= 3) {
        if (j % 53 == 0) {
          customValues = {
            fieldKeys[0]: 'M-${100000 + j}',
            fieldKeys[1]: ((rnd.nextInt(50000) + 100) / 100),
          };
        } else if (j % 97 == 0) {
          customValues = {fieldKeys[2]: '2024-0${(j % 9) + 1}-1${j % 9}'};
        }
      }

      companions.add(
        TransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: type,
          amount: amount,
          categoryId: Value(categoryId),
          accountId: Value(accountId),
          toAccountId: Value(toAccountId),
          happenedAt: Value(happenedAt),
          note: Value(note),
          currencyCode: Value(multiCurrency ? 'USD' : null),
          nativeAmount: Value(multiCurrency ? (amount / 7.2) : null),
          originalAmount: Value(amount),
          excludeFromStats: Value(j % 997 == 0),
          excludeFromBudget: Value(j % 991 == 0),
          customValuesJson: Value(CustomFieldValueCodec.encode(customValues)),
        ),
      );
    }

    await repo.insertTransactionsBatchWithRelations(
      transactions: companions,
      tagIdsByIndex: tagIndex,
    );
    totalTx += companions.length;
    detail.add({
      'ledgerIndex': i,
      'ledgerId': ledgerId,
      'txCount': companions.length,
      'taggedTx': tagIndex.length,
      'from': start.toIso8601String(),
      'to': end.toIso8601String(),
    });
  }

  sw.stop();
  out['seeded'] = true;
  out['ledgers'] = ledgerIds.length;
  out['transactions'] = totalTx;
  out['accounts'] = accountIds.length + 1;
  out['tags'] = 4;
  out['budgets'] = budgetCount;
  out['recurring'] = recurringCount;
  out['rateOverrides'] = 3;
  out['elapsedMs'] = sw.elapsedMilliseconds;
  out['detail'] = detail;
  out['tables'] = await _tableCounts(db);
  out['ledgerList'] = await _ledgerList(db);
}

// ============================ mutate ============================

Future<void> _mutate(ProviderContainer c, Map<String, dynamic> out) async {
  final db = c.read(databaseProvider);
  final repo = c.read(repositoryProvider);
  final ledgers = (await _ledgerList(db));
  if (ledgers.length < _ledgerCount) {
    out['error'] = '账本数量不足，先执行 seed';
    return;
  }

  // 固定选取 3 个账本做三类变更：新增 / 改名 / 删除
  final byId = [...ledgers]
    ..sort((a, b) => (a['localId'] as int).compareTo(b['localId'] as int));
  final addLedger = byId[1];
  final renameLedger = byId[3];
  final deleteLedger = byId[5];

  // a) 新增 137 笔（含微信/支付宝备注）
  final addLedgerId = addLedger['localId'] as int;
  final rnd = Random(777);
  final cats = await repo.getAllCategories();
  final expenseCats =
      cats.where((x) => x.kind == 'expense').map((x) => x.id).toList();
  final accounts = await db.select(db.accounts).get();
  final accIds = accounts.map((a) => a.id).toList();
  final companions = <TransactionsCompanion>[];
  for (var j = 0; j < 137; j++) {
    companions.add(
      TransactionsCompanion.insert(
        ledgerId: addLedgerId,
        type: 'expense',
        amount: ((rnd.nextInt(100000) + 100) / 100),
        categoryId: Value(expenseCats[rnd.nextInt(expenseCats.length)]),
        accountId: Value(accIds[rnd.nextInt(accIds.length)]),
        happenedAt: Value(
          DateTime(2026, 10, 2).add(Duration(minutes: j)),
        ),
        note: Value(j % 2 == 0 ? 'E2E变更新增-微信支付' : 'E2E变更新增-支付宝'),
        originalAmount: Value(((rnd.nextInt(100000) + 100) / 100)),
      ),
    );
  }
  await repo.insertTransactionsBatchWithRelations(transactions: companions);

  // b) 账本改名 + 改月起始日
  final renameId = renameLedger['localId'] as int;
  await repo.updateLedgerName(id: renameId, name: '$_e2ePrefix已改名-第2轮');
  await repo.updateLedger(id: renameId, monthStartDay: 15);

  // c) 删除 40 笔 + 修改 25 笔备注
  final deleteId = deleteLedger['localId'] as int;
  final txs = await repo.getTransactionsByLedger(deleteId);
  var deleted = 0;
  for (var j = 0; j < txs.length && j < 40; j++) {
    await repo.deleteTransaction(txs[j].id);
    deleted++;
  }
  var updated = 0;
  for (var j = 40; j < txs.length && j < 65; j++) {
    await repo.updateTransaction(
      id: txs[j].id,
      type: txs[j].type,
      amount: txs[j].amount,
      categoryId: txs[j].categoryId,
      note: 'E2E变更改备注-${txs[j].id}',
    );
    updated++;
  }

  out['mutated'] = true;
  out['added'] = companions.length;
  out['renamed'] = {'ledgerId': renameId, 'name': '$_e2ePrefix已改名-第2轮'};
  out['deleted'] = deleted;
  out['noteUpdated'] = updated;
  out['tables'] = await _tableCounts(db);
  out['ledgerList'] = await _ledgerList(db);
}

// ============================ dump ============================

Future<void> _dump(ProviderContainer c, Map<String, dynamic> out) async {
  final db = c.read(databaseProvider);
  final dir = Directory(
    p.join((await getApplicationDocumentsDirectory()).path, 'e2e-dump'),
  );
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
  await dir.create(recursive: true);

  final ledgers = await db.select(db.ledgers).get();
  ledgers
      .sort((a, b) => (a.syncId ?? '${a.id}').compareTo(b.syncId ?? '${b.id}'));

  final summaries = <Map<String, dynamic>>[];
  for (final l in ledgers) {
    final exported = await exportTransactionsJson(db, l.id);
    // 归一化设备本地字段，使 payload 可跨设备逐字节比对
    final payload = jsonDecode(exported.jsonStr) as Map<String, dynamic>;
    payload.remove('exportedAt');
    payload.remove('ledgerId');
    final normalized = jsonEncode(payload);
    final fileName = 'ledger_${l.syncId ?? l.id}.json';
    await File(p.join(dir.path, fileName)).writeAsString(normalized);
    summaries.add({
      'localId': l.id,
      'syncId': l.syncId,
      'name': l.name,
      'currency': l.currency,
      'monthStartDay': l.monthStartDay,
      'txCount': exported.count,
      'balance': exported.balance,
      'fingerprint': exported.fingerprint,
      'payloadSha256': sha256.convert(utf8.encode(normalized)).toString(),
      'payloadBytes': normalized.length,
      'file': fileName,
    });
  }

  // 全账本聚合指纹：两端相等即「全部账本内容逐字节一致」
  final joined =
      summaries.map((e) => '${e['syncId']}:${e['payloadSha256']}').join('|');
  out['ledgerCount'] = summaries.length;
  out['aggregateSha256'] = sha256.convert(utf8.encode(joined)).toString();
  out['ledgers'] = summaries;
  out['tables'] = await _tableCounts(db);
  out['dumpDir'] = dir.path;
}

// ============================ wipe ============================

/// 清空业务数据（保留云配置 / E2EE 密钥 / prefs）。
/// 仅用于测试轮次之间的重置：不会删除数据库文件，也不触碰任何配置。
Future<void> _wipe(ProviderContainer c, Map<String, dynamic> out) async {
  final db = c.read(databaseProvider);
  const order = [
    'transaction_tags',
    'transaction_attachments',
    'deleted_transactions',
    'transactions',
    'budgets',
    'recurring_transactions',
    'custom_field_definitions',
    'tags',
    'categories',
    'accounts',
    'ledgers',
    'exchange_rate_overrides',
    'local_changes',
    'sync_op_log',
  ];
  final deleted = <String, int>{};
  for (final table in order) {
    try {
      final n = await db.customUpdate('DELETE FROM $table');
      deleted[table] = n;
    } catch (e) {
      deleted[table] = -1;
    }
  }
  out['wiped'] = deleted;
  out['tables'] = await _tableCounts(db);
}

// ========================= set-backend =========================

/// 切换「当前激活的云后端」——只改激活标记，**绝不写/删任何凭据**。
/// 等价于 App 内云服务页的「使用该后端」操作（CloudServiceStore.activate）。
Future<void> _setBackend(ProviderContainer c, Map<String, dynamic> out) async {
  const target = String.fromEnvironment('E2E_BACKEND');
  final store = c.read(cloudServiceStoreProvider);
  final before = (await store.loadActive()).type.name;
  final ok = await store.activate(switch (target) {
    's3' => CloudBackendType.s3,
    'webdav' => CloudBackendType.webdav,
    'supabase' => CloudBackendType.supabase,
    'local' => CloudBackendType.local,
    _ => throw ArgumentError('未知后端: $target'),
  });
  final after = await store.loadActive();
  out['requested'] = target;
  out['activated'] = ok;
  out['activeBefore'] = before;
  out['activeAfter'] = after.type.name;
  out['activeValid'] = after.valid;
  // 顺带确认另一后端凭据仍在（切换不得破坏既有配置）
  out['s3StillConfigured'] = (await store.loadS3()) != null;
  out['webdavStillConfigured'] = (await store.loadWebdav()) != null;
}

// ============================ checks ============================

/// 结构化诊断：按交易类型统计行数与「分类缺失」行数、重复 syncId、
/// 各业务表规模。用于跨设备逐字段核对，避免依赖宿主机 quoting。
Future<void> _checks(ProviderContainer c, Map<String, dynamic> out) async {
  final db = c.read(databaseProvider);
  final byType = await db
      .customSelect(
        'SELECT type, COUNT(*) AS cnt, SUM(CASE WHEN category_id IS NULL THEN 1 ELSE 0 END) AS no_cat, '
        'ROUND(SUM(amount), 2) AS sum_amount FROM transactions GROUP BY type ORDER BY type',
      )
      .get();
  out['byType'] = byType
      .map((r) => {
            'type': r.read<String>('type'),
            'count': r.read<int>('cnt'),
            'nullCategory': r.read<int>('no_cat'),
            'amountSum': r.read<double>('sum_amount'),
          })
      .toList();

  final nullCatByType = await db
      .customSelect(
        'SELECT type, category_id, COUNT(*) AS cnt FROM transactions '
        'WHERE category_id IS NULL GROUP BY type',
      )
      .get();
  out['nullCategoryRows'] = nullCatByType
      .map((r) => {
            'type': r.read<String>('type'),
            'count': r.read<int>('cnt'),
          })
      .toList();

  final dupSync = await db
      .customSelect(
        'SELECT COUNT(*) AS cnt FROM (SELECT sync_id FROM transactions '
        'GROUP BY sync_id HAVING COUNT(*) > 1)',
      )
      .getSingle();
  out['duplicateTransactionSyncIds'] = dupSync.read<int>('cnt');

  final cats = await db
      .customSelect(
        'SELECT kind, COUNT(*) AS cnt FROM categories GROUP BY kind ORDER BY kind',
      )
      .get();
  out['categoriesByKind'] = cats
      .map((r) => {
            'kind': r.read<String>('kind'),
            'count': r.read<int>('cnt'),
          })
      .toList();

  final orphanCat = await db
      .customSelect(
        'SELECT COUNT(*) AS cnt FROM transactions t WHERE t.category_id IS NOT NULL '
        'AND NOT EXISTS (SELECT 1 FROM categories c WHERE c.id = t.category_id)',
      )
      .getSingle();
  out['orphanCategoryRefs'] = orphanCat.read<int>('cnt');

  out['tables'] = await _tableCounts(db);
}

/// 单次 HTTPS 探测：返回状态码或错误类型（自签证书一律放行，只为判定连通性）。
Future<Map<String, dynamic>> _probeUrl(String label, String url) async {
  final result = <String, dynamic>{'label': label, 'url': url};
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..badCertificateCallback = (_, __, ___) => true;
  final sw = Stopwatch()..start();
  try {
    final req = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    final resp = await req.close().timeout(const Duration(seconds: 10));
    await resp.drain<void>();
    result['status'] = resp.statusCode;
  } catch (e) {
    result['error'] = e.runtimeType.toString();
    result['errorDetail'] = '$e';
  } finally {
    result['elapsedMs'] = sw.elapsedMilliseconds;
    client.close(force: true);
  }
  return result;
}

// ============================ 工具 ============================

Future<Map<String, int>> _tableCounts(PiggyDatabase db) async {
  const tables = [
    'ledgers',
    'accounts',
    'categories',
    'tags',
    'transactions',
    'transaction_tags',
    'budgets',
    'custom_field_definitions',
    'recurring_transactions',
    'transaction_attachments',
    'exchange_rate_overrides',
    'local_changes',
  ];
  final result = <String, int>{};
  for (final t in tables) {
    try {
      final row =
          await db.customSelect('SELECT COUNT(*) AS c FROM $t').getSingle();
      result[t] = row.read<int>('c');
    } catch (e) {
      result[t] = -1;
    }
  }
  return result;
}

Future<List<Map<String, dynamic>>> _ledgerList(PiggyDatabase db) async {
  final rows = await db
      .customSelect(
        'SELECT l.id, l.sync_id, l.name, l.currency, l.month_start_day, '
        '(SELECT COUNT(*) FROM transactions t WHERE t.ledger_id = l.id) AS tx_count, '
        '(SELECT COALESCE(SUM(t.amount),0) FROM transactions t WHERE t.ledger_id = l.id) AS amount_sum '
        'FROM ledgers l ORDER BY l.id',
      )
      .get();
  return rows
      .map((r) => {
            'localId': r.read<int>('id'),
            'syncId': r.read<String?>('sync_id'),
            'name': r.read<String>('name'),
            'currency': r.read<String>('currency'),
            'monthStartDay': r.read<int>('month_start_day'),
            'txCount': r.read<int>('tx_count'),
            'amountSum': r.read<double>('amount_sum'),
          })
      .toList();
}
