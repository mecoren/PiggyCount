// 回归（2026-10-25）：种子数据用确定性 syncId，重复执行 seedDatabase
//（重进欢迎引导、二次 ensureSeed）曾撞 ledgers.sync_id 唯一约束崩溃。
// 要求 seed 幂等：二次执行不抛异常、账本/分类不重复。

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/services/data/seed_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('seedDatabase 可重复执行（幂等）', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    try {
      await SeedService.seedDatabase(db, l10n);
      final ledgers1 = await db.select(db.ledgers).get();
      final categories1 = await db.select(db.categories).get();
      expect(ledgers1.length, 1);
      expect(categories1, isNotEmpty);

      // 二次执行不得抛 UNIQUE 约束异常
      await SeedService.seedDatabase(db, l10n);
      final ledgers2 = await db.select(db.ledgers).get();
      final categories2 = await db.select(db.categories).get();

      expect(ledgers2.length, 1);
      expect(categories2.length, categories1.length);
    } finally {
      await db.close();
    }
  });
}
