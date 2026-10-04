// 冷启动账本态自愈守卫（20261004 S3/WebDAV 双后端回归 6.5）。
//
// `current_ledger_id` 是纯 prefs 状态，账本行却可能早已消失（被对端删除后合并
// 下来 / 恢复到他人备份 / 清库重建）。恢复逻辑的三条分支都必须收敛到**有界**的
// 取值 —— 绝不能把悬空 id 原样留在 `currentLedgerIdProvider` 里：
//
// UI 侧的「无账本」守卫一律判 `currentLedgerId == 0`
// （cloud_sync_page.dart:635、share_poster_service.dart 四处、
// analytics_page.dart:576、transactions_sync_manager.dart:2558），
// 留着悬空值会**绕过全部守卫** —— 实测云同步页直接抛出裸的
// `Exception: 账本 9 不存在`（原始报告：docs/test/WebDAV同步功能测试报告_20261004.md 6.5）。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/providers/database_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 起容器 → 铺账本行 → 跑一次 `appInitProvider`（内部激活
  /// `_currentLedgerPersist` 的恢复）。
  ///
  /// 注意 `_currentLedgerPersist` 的恢复体是 **fire-and-forget**（provider 体内
  /// 自调用 async 闭包、不被 await），所以 `appInitProvider.future` 完成 ≠ 恢复
  /// 跑完。这里用有界轮询等它落地。
  Future<ProviderContainer> boot({
    required int savedLedgerId,
    required Future<void> Function(PiggyDatabase db) seed,
  }) async {
    SharedPreferences.setMockInitialValues(
        {'current_ledger_id': savedLedgerId});
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    await seed(db);
    await container.read(appInitProvider.future);

    for (var i = 0; i < 200; i++) {
      if (container.read(currentLedgerIdProvider) != 1) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return container;
  }

  Future<int> insertLedger(PiggyDatabase db, String name) => db
      .into(db.ledgers)
      .insert(LedgersCompanion.insert(name: name, syncId: Value('L-$name')));

  test('本机一个账本都没有 → 悬空 id 归零，而不是留着绕过 UI 守卫', () async {
    // 原始现象的精确复刻：prefs 残留 9，库里 0 个账本。
    final container = await boot(savedLedgerId: 9, seed: (_) async {});
    expect(container.read(currentLedgerIdProvider), 0,
        reason: '归零后 cloud_sync_page 的无账本守卫才生效，不会抛裸异常');
  });

  test('目标账本消失但本机仍有账本 → 回落到最小真实 id', () async {
    final container = await boot(
      savedLedgerId: 9,
      seed: (db) async {
        await insertLedger(db, 'A'); // id=1
        final b = await insertLedger(db, 'B'); // id=2
        expect(b, 2);
        // 删掉 id=1，让「最小真实 id」= 2，与 provider 默认值 1 可区分，
        // 避免「恢复根本没跑」被误判成通过。
        await (db.delete(db.ledgers)..where((l) => l.id.equals(1))).go();
      },
    );
    expect(container.read(currentLedgerIdProvider), 2);
  });

  test('目标账本存在 → 原样采纳，不被回落逻辑改写', () async {
    final container = await boot(
      savedLedgerId: 2,
      seed: (db) async {
        await insertLedger(db, 'A'); // id=1
        await insertLedger(db, 'B'); // id=2
      },
    );
    expect(container.read(currentLedgerIdProvider), 2);
  });
}
