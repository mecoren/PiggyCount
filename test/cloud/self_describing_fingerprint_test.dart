/// 审计 TSM-P3：快照指纹自描述（'contentFingerprint' 内嵌键）。
///
/// 导出器把内容指纹写进快照本体，读取端在元数据指纹缺失/存疑时
/// （WebDAV sidecar 丢失、S3 头被网关剥离）以下载内容的内嵌值为权威，
/// 不再退化成 unknown 冲突死循环。验证三点：
/// 1. 导出产物携带内嵌指纹；
/// 2. 内嵌值 == 对同一 payload 用共享函数计算的值
///    （白名单式规范化忽略未知键 → 嵌入不改变哈希，无循环依赖）;
/// 3. 嵌入前后指纹稳定（向后兼容：旧读取端算法不受新键影响）。
library;
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_fingerprint.dart';
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

  test('导出快照携带内嵌指纹，且与共享函数计算值一致', () async {
    final ledgerId = await repo.createLedger(name: 'L', currency: 'CNY');

    final jsonStr = await exportTransactionsJson(db, ledgerId).then((e) => e.jsonStr);
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;

    final embedded = map['contentFingerprint'];
    expect(embedded, isA<String>(),
        reason: '导出必须携带 contentFingerprint 键（TSM-P3）');
    expect((embedded as String).isNotEmpty, isTrue);

    // 白名单式规范化：嵌入键自身不参与哈希 → 直接对解析后的 map 重算，
    // 结果必须与内嵌值逐字节一致
    expect(contentFingerprintFromMap(map), embedded,
        reason: '内嵌指纹应与按内容重算的指纹完全一致');
  });

  test('嵌入键不影响指纹计算（向后兼容旧读取端）', () {
    final base = <String, dynamic>{
      'items': [
        {
          'happenedAt': '2026-08-01T00:00:00.000',
          'type': 'expense',
          'amount': 10.0,
          'note': 'n',
        }
      ],
    };
    final withoutKey = contentFingerprintFromMap(base);
    final withKey = contentFingerprintFromMap({
      ...base,
      'contentFingerprint': 'deadbeef',
    });
    expect(withKey, withoutKey,
        reason: 'contentFingerprintFromMap 只读白名单键，'
            '嵌入值不得反馈进哈希（否则自描述方案产生循环依赖）');
  });
}
