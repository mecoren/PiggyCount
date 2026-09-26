// 索引漂移守卫：**onUpgrade 里创建过的索引，必须都存在于 onCreate 建出的库**。
//
// 为什么需要这条通用守卫（而不是只测某几个索引）：
// `lib/data/db.dart` 里「索引只在 onUpgrade 历史分支建、onCreate 漏建」这个洞
// 至少发生过两次 —— 代码注释本身就记录了两次教训：
//   - `db.dart` onCreate 段：「v32/v33 索引也需在 onCreate 创建:新装 app 和
//     测试内存库走 onCreate 而非 migration,若不在 onCreate 建索引则新库永远
//     没有该索引」
//   - `db.dart` onCreate 段 v43：「此前 onUpgrade 建了该索引但 onCreate 遗漏」
// 2026-09-26 又发现第三批：v10 的 transaction_tags ×2、v11 的 budgets ×3、
// v12 的 transaction_attachments ×1（见 v48 修复型迁移）。
//
// 每次都是「onCreate 补一次、老用户靠后续迁移救」，说明逐个人工比对不可靠。
// 本测试把这条不变量机器化：**解析 db.dart 源码里 onUpgrade 段出现的所有
// `CREATE [UNIQUE] INDEX IF NOT EXISTS <name>`，断言 onCreate 建出的库里每一个
// 都存在**。新增索引时若忘了补 onCreate，该测试立刻红。
//
// 豁免：若某索引确实**只应存在于老库**（目标表已废弃等），加进 [_legacyOnlyIndexes]
// 并写明原因 —— 目前为空集。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';

/// 合法地「只存在于 onUpgrade」的索引（当前为空 —— 有豁免必须写原因）。
const _legacyOnlyIndexes = <String>{};

/// 解析 db.dart：取 `onUpgrade:` 段内出现过的所有索引名。
Set<String> _indexesCreatedInOnUpgrade(String source) {
  final upgradeStart = source.indexOf('onUpgrade:');
  final onCreateStart = source.indexOf('onCreate:');
  expect(upgradeStart, greaterThan(0), reason: '未找到 onUpgrade 段');
  expect(onCreateStart, greaterThan(upgradeStart), reason: '未找到 onCreate 段');
  final upgradeBody = source.substring(upgradeStart, onCreateStart);
  return RegExp(r'CREATE (?:UNIQUE )?INDEX IF NOT EXISTS (\w+)')
      .allMatches(upgradeBody)
      .map((m) => m.group(1)!)
      .toSet();
}

Future<Set<String>> _actualIndexes(PiggyDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type='index' "
          "AND sql IS NOT NULL")
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('onUpgrade 建过的索引必须都在 onCreate 建库中存在（防漂移）', () async {
    final src = File('lib/data/db.dart');
    expect(src.existsSync(), isTrue,
        reason: '工作目录应为包根，实际: ${Directory.current.path}');
    final declared = _indexesCreatedInOnUpgrade(src.readAsStringSync());
    // 数量下限防止「正则静默匹配不到 → 断言空集恒真 → 守卫失效」
    expect(declared.length, greaterThanOrEqualTo(20),
        reason: '解析到的索引数偏少（${declared.length}），正则或源码结构可能已变');

    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());
    final present = await _actualIndexes(db);

    final missing = declared
        .where((n) => !_legacyOnlyIndexes.contains(n) && !present.contains(n))
        .toList()
      ..sort();

    expect(
      missing,
      isEmpty,
      reason: '以下索引在 onUpgrade 建过、但 onCreate 建库中没有 —— '
          '新装用户（走 onCreate）与版本已越过对应分支的存量用户都会永久缺失：\n'
          '  ${missing.join('\n  ')}\n'
          '修法：在 onCreate 的索引补建段里补上（IF NOT EXISTS 幂等），'
          '并新增一个修复型迁移版本救存量库。',
    );
  });
}
