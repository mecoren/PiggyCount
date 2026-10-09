// 账本态自愈守卫（冷启动 + 同会话；原始报告 20261004 S3/WebDAV 双后端回归 6.5）。
//
// `current_ledger_id` 是纯 prefs 状态，账本行却可能早已消失（被对端删除后合并
// 下来 / 恢复到他人备份 / 清库重建），或者**在本会话内才出现**（启动检查的
// 「发现云端账本 → 下载」新建账本行）。解析结果必须始终收敛到**有界**的取值 ——
// 绝不能把悬空 id 原样留在 `currentLedgerIdProvider` 里：
//
// UI 侧的「无账本」守卫一律判 `currentLedgerId == 0`
// （cloud_sync_page.dart:667、share_poster_service.dart 四处、
// analytics_page.dart:576、transactions_sync_manager.dart:2558），
// 留着悬空值会**绕过全部守卫** —— 实测云同步页直接抛出裸的
// `Exception: 账本 9 不存在`（原始报告：docs/test/WebDAV同步功能测试报告_20261004.md 6.5）。
//
// 本文件守两组行为：
//  1. **冷启动采纳**：prefs 里的账本仍在 → 采纳；已消失 → 回落最小真实 id，
//     本机无账本 → 归零；
//  2. **同会话校正**（`_currentLedgerPersist` 的第二段）：账本列表任何变化
//     （导入云端账本 / 删完所有账本）立即收敛，不再等下一次冷启动 —— 旧实现
//     只在 splash 跑一次，于是「提示去云同步页手动同步 → 页面仍显示未找到账本」
//     成了一条死路。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/providers/database_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 有界轮询等异步回调落地。
  ///
  /// 为什么需要：启动采纳虽已被 [appInitProvider] await 掉，但**响应式校正**
  /// 走的是账本列表流（事件异步送达）+ 微任务写入 —— `appInitProvider.future`
  /// 完成 ≠ 校正跑完。
  Future<void> settle(bool Function() done) async {
    for (var i = 0; i < 400; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('账本态未在 2s 内收敛');
  }

  /// 起容器 → 铺账本行 → 跑一次 `appInitProvider`（内部激活
  /// `_currentLedgerPersist` 的两段逻辑），返回容器与库句柄（用例要中途改账本）。
  Future<({ProviderContainer container, PiggyDatabase db})> boot({
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

    // 1) 等账本列表流送达首个值（同会话校正的输入就绪）
    await settle(() => container.read(ledgersStreamProvider).hasValue);
    // 2) 等账本态收敛。saved=1 是本 provider 默认值，此时「没变化」就是正确结果，
    //    不必空等（旧实现的固定轮询在这里白烧 1s）。
    if (savedLedgerId != 1) {
      await settle(() => container.read(currentLedgerIdProvider) != 1);
    }
    return (container: container, db: db);
  }

  Future<int> insertLedger(PiggyDatabase db, String name) => db
      .into(db.ledgers)
      .insert(LedgersCompanion.insert(name: name, syncId: Value('L-$name')));

  test('本机一个账本都没有 → 悬空 id 归零，而不是留着绕过 UI 守卫', () async {
    // 原始现象的精确复刻：prefs 残留 9，库里 0 个账本。
    final booted = await boot(savedLedgerId: 9, seed: (_) async {});
    expect(booted.container.read(currentLedgerIdProvider), 0,
        reason: '归零后 cloud_sync_page 的无账本守卫才生效，不会抛裸异常');
  });

  test('目标账本消失但本机仍有账本 → 回落到最小真实 id', () async {
    final booted = await boot(
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
    expect(booted.container.read(currentLedgerIdProvider), 2);
  });

  test('目标账本存在 → 原样采纳，不被回落逻辑改写', () async {
    final booted = await boot(
      savedLedgerId: 2,
      seed: (db) async {
        await insertLedger(db, 'A'); // id=1
        await insertLedger(db, 'B'); // id=2
      },
    );
    expect(booted.container.read(currentLedgerIdProvider), 2);
  });

  test('同会话导入云端账本 → 当前账本自动落到导入结果，不再等冷启动', () async {
    // 新装设备：库里零账本 → splash 把悬空 id 归零，这正是云同步页显示
    // 「未找到账本」的状态（scripts/sync_regression/b_first_sync.py 也这么描述）。
    final booted = await boot(savedLedgerId: 0, seed: (_) async {});
    expect(booted.container.read(currentLedgerIdProvider), 0);

    // 复刻启动检查的「发现云端账本 → 下载」：导入路径只插账本行 + 导数据，
    // 从不动 currentLedgerIdProvider（transactions_sync_manager 的
    // _importRemoteLedgerInner，收尾只调 PostProcessor.runAfterDownload）。
    final id = await insertLedger(booted.db, '云端账本');
    await settle(() => booted.container.read(currentLedgerIdProvider) == id);

    expect(booted.container.read(currentLedgerIdProvider), id,
        reason: '不收敛 → 提示把用户支去云同步页手动同步，那个页面却仍显示「未找到账本」');
  });

  test('同会话删完最后一个账本 → 归零，不再等冷启动', () async {
    final booted = await boot(
      savedLedgerId: 1,
      seed: (db) async => insertLedger(db, '唯一'),
    );
    expect(booted.container.read(currentLedgerIdProvider), 1);

    await booted.db.delete(booted.db.ledgers).go();
    await settle(() => booted.container.read(currentLedgerIdProvider) == 0);

    expect(booted.container.read(currentLedgerIdProvider), 0,
        reason: '悬空值会绕过全部「无账本」守卫（云同步页抛「账本 1 不存在」）');
  });

  test('当前账本仍存在 → 列表增删不改写它（不替用户改选择）', () async {
    final booted = await boot(
      savedLedgerId: 1,
      seed: (db) async => insertLedger(db, 'A'),
    );
    expect(booted.container.read(currentLedgerIdProvider), 1);

    await insertLedger(booted.db, 'B'); // id=2：用户选中的仍是 1
    await settle(() =>
        booted.container.read(ledgersStreamProvider).value?.length == 2);

    expect(booted.container.read(currentLedgerIdProvider), 1);
  });
}
