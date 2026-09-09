/// P2-1（2026-09-09）：getStatus 冷启动指纹缓存单元测试。
///
/// 冷启动首轮 getStatus 曾对每个账本全量导出算指纹（大账本 CPU 重）。
/// 修复：内存指纹缓存 + 两条失效防线——
/// ① ChangeTracker 写路径回调（onLocalContentGeneration）主动失效；
/// ② local_changes 轻量校验位（MAX(id)+COUNT）兜底。
///
/// 本文件验证：缓存命中语义 / 写操作失效 / user-global 失效全部 /
/// rememberLocalFingerprint 登记（上传后复用）。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late TransactionsSyncManager manager;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    manager = TransactionsSyncManager(
      config: const fcs.CloudServiceConfig(
        type: fcs.CloudBackendType.supabase,
        name: 'test',
      ),
      db: db,
      repo: repo,
    );
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: 'L',
          currency: const d.Value('CNY'),
        ));
  });

  tearDown(() async {
    await db.close();
  });

  /// 手动登记一条 local_changes 行，模拟写路径（避开 repository 语义差异，
  /// 直接对 DB 验证缓存失效链）。
  Future<void> insertChangeRow(int ledgerId) async {
    await db.into(db.localChanges).insert(LocalChangesCompanion.insert(
          entityType: 'transaction',
          entityId: 1,
          entitySyncId: 'sync-1',
          ledgerId: ledgerId,
          action: 'upsert',
        ));
  }

  group('P2-1: 指纹缓存命中与失效', () {
    test('rememberLocalFingerprint 后getStatus 命中缓存（跳过全量导出）',
        () async {
      // 预登记指纹（模拟上传成功后的登记路径）
      await manager.rememberLocalFingerprint(1, 'fp-cached-0000');

      // getStatus 内部 _localFingerprintWithCache 应命中缓存返回该指纹
      // —— 通过私有路径间接验证：命中时 _localFpCache 不被清除
      // （导出会重算并覆盖缓存值，指纹不变即可判定走了缓存或导出
      // 结果一致——用特殊指纹值区分：导出会算出真实指纹，非 'fp-cached'）
      // 直接测 _localFingerprintWithCache 的公开语义:
      final fp1 = await managerDebugLocalFingerprint(manager, 1);
      expect(fp1, 'fp-cached-0000',
          reason: 'guard 未变时应直接复用登记的缓存指纹，跳过导出');
    });

    test('local_changes 新增行 → guard 变化 → 缓存失效重算', () async {
      await manager.rememberLocalFingerprint(1, 'fp-cached-0000');
      await insertChangeRow(1); // MAX(id) 变化

      final fp = await managerDebugLocalFingerprint(manager, 1);
      expect(fp, isNot('fp-cached-0000'),
          reason: '写操作后 guard 变化，缓存必须失效并重算真实指纹');
    });

    test('ChangeTracker 回调：记录变更 → 对应账本缓存失效', () async {
      await manager.rememberLocalFingerprint(1, 'fp-cached-0000');
      // 生产 LocalRepository 不注入 tracker（快照同步模式），但 TSM 的
      // _wireChangeTrackerGeneration 支持有 tracker 时的双保险失效——
      // 这里显式注入并手动接线，验证回调链路本身正确
      final tracker = ChangeTracker(db);
      repo.changeTracker = tracker;
      manager.wireChangeTrackerGenerationForTesting();

      await tracker.recordLedgerChange(
        entityType: 'transaction',
        entityId: 2,
        entitySyncId: 'sync-2',
        ledgerId: 1,
        action: 'update',
      );

      // 回调已失效缓存：指纹不得再是登记的旧值
      final fp = await managerDebugLocalFingerprint(manager, 1);
      expect(fp, isNot('fp-cached-0000'));
    });

    test('user-global 变更（ledgerId=0）→ 全部账本缓存失效', () async {
      await manager.rememberLocalFingerprint(1, 'fp-cached-0000');
      final tracker = ChangeTracker(db);
      repo.changeTracker = tracker;
      manager.wireChangeTrackerGenerationForTesting();

      await tracker.recordUserGlobalChange(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'acc-1',
        action: 'update',
      );

      final fp = await managerDebugLocalFingerprint(manager, 1);
      expect(fp, isNot('fp-cached-0000'),
          reason: '账户/分类/标签变更影响所有快照，任何账本的指纹缓存都要失效');
    });

    test('markLocalChanged（UI 后处理）→ 缓存失效', () async {
      await manager.rememberLocalFingerprint(1, 'fp-cached-0000');
      manager.markLocalChanged(ledgerId: 1);

      final fp = await managerDebugLocalFingerprint(manager, 1);
      expect(fp, isNot('fp-cached-0000'));
    });
  });
}

/// 测试钩子：直接调用 TSM 的 _localFingerprintWithCache。
/// 生产代码禁止使用（仅测试可见的桥接函数）。
Future<String> managerDebugLocalFingerprint(
    TransactionsSyncManager manager, int ledgerId) async {
  final r = await manager.localFingerprintForTesting(ledgerId);
  return r;
}
