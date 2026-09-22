/// CT-1（2026-09-21，(b) 路线第二段）：方向仲裁证据改用 v40 业务表触碰列。
///
/// 旧实现读 `local_changes`（MAX(created_at) + 未推送行数），但生产快照装配
/// 不注入 ChangeTracker → 该表恒空 → `trusted` 恒 false → 方向仲裁在生产上
/// 永久退化为 'unknown'（每次上传差异都弹人工确认）。
///
/// 本文件验证新口径：
/// - 证据时间 `at` 来自业务表触碰列/创建列（真实写时刻），且单位换算正确；
/// - `trusted` 仍是「本地确有未上云内容」的内容性断言，三条证据任一成立；
/// - 新增的第三条用**同机时钟锚点**（本机上次成功上传时刻）证明，避免
///   跨设备时钟偏移进入「静默放行覆盖云端」这一破坏性方向。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_metrics_service.dart';
import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late TransactionsSyncManager manager;

  /// 账本行的 created_at 也是「本机写入痕迹」之一（快照内容含账本元数据），
  /// 故测试统一显式指定为某个过去时刻，避免默认值（now）污染断言。
  final past = DateTime.now().subtract(const Duration(hours: 1));

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
          createdAt: d.Value(past),
        ));
  });

  tearDown(() async {
    await db.close();
  });

  /// 登记一条「快照上传成功」指标行 = 本机上次成功上传锚点。
  Future<void> insertUploadAnchor(DateTime ts) async {
    await db.into(db.syncOpLog).insert(SyncOpLogCompanion.insert(
          ts: d.Value(ts),
          backend: 's3',
          scenario: SyncOpScenario.snapshotUpload.label,
          outcome: SyncOpOutcome.success.label,
          ledgerId: const d.Value(1),
        ));
  }

  /// 通过 v40 触发器留下 updated_at 戳（先 INSERT 再 UPDATE —— 触发器不覆盖
  /// INSERT，这正是本次要处理的现实：纯新增不留持久墙钟）。
  Future<void> touchTransaction() async {
    final id = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 10.0,
            happenedAt: d.Value(DateTime(2026, 8, 1)),
            syncId: const d.Value('ev-tx-1'),
          ),
        );
    await (db.update(db.transactions)..where((t) => t.id.equals(id)))
        .write(const TransactionsCompanion(amount: d.Value(11.0)));
  }

  Future<({DateTime? at, bool trusted})> evidence() =>
      manager.localChangeEvidenceForTesting(1);

  group('CT-1: 证据源改用业务表触碰列', () {
    test('仅有历史痕迹、无上传锚点 → at 有值但 trusted=false（不构成'
        '「有未上云内容」的证明）', () async {
      final e = await evidence();
      expect(e.at, isNotNull, reason: '账本 created_at 即一条真实写时刻');
      expect(e.trusted, isFalse,
          reason: '本机从未上传过该账本 → 同机锚点缺失，跨设备情形无法判定，'
              '必须保持不可信（保守多弹窗，绝不静默放行覆盖）');
    });

    test('持久痕迹晚于上次成功上传锚点 → trusted=true（本次改造的核心能力）',
        () async {
      await insertUploadAnchor(DateTime.now().subtract(const Duration(minutes: 30)));

      // 锚点之前无任何新痕迹：本机自上次上传后没写过 → 不可信
      expect((await evidence()).trusted, isFalse,
          reason: '写入痕迹（1 小时前的账本 created_at）早于锚点（30 分钟前）→ '
              '本地无未上云内容，此时指纹不同只能是他机更新');

      // 触碰业务表 → 触发器盖章 now() > 锚点
      await touchTransaction();

      final e = await evidence();
      expect(e.trusted, isTrue,
          reason: '本机在上次成功上传之后又写过本快照内容 ⟹ 本地确有未上云内容');
      expect(e.at!.isAfter(DateTime.now().subtract(const Duration(minutes: 5))),
          isTrue,
          reason: 'at 必须落在当下（顺带钉死 epoch 秒→毫秒的时间单位换算：'
              '换错单位会让 at 偏到 1970 或 +5 万年）');
    });

    test('锚点晚于写入痕迹 → trusted=false（c 的负例，避免误判本地更新）', () async {
      await touchTransaction(); // 痕迹 = now
      await insertUploadAnchor(DateTime.now().add(const Duration(minutes: 5)));

      expect((await evidence()).trusted, isFalse,
          reason: '上次上传晚于最后一次本地写 → 本地内容已随那次上传上云，'
              '不构成「未上云内容」');
    });

    test('本 session 写入登记（markLocalChanged）→ trusted=true（原有语义不回退）',
        () async {
      manager.markLocalChanged(ledgerId: 1);
      final e = await evidence();
      expect(e.trusted, isTrue);
      expect(e.at!.difference(DateTime.now()).abs().inSeconds, lessThan(5));
    });

    test('local_changes 未推送行 → trusted=true（原有语义，测试装配/未来 tracker）',
        () async {
      await db.into(db.localChanges).insert(LocalChangesCompanion.insert(
            entityType: 'transaction',
            entityId: 1,
            entitySyncId: 'sync-1',
            ledgerId: 1,
            action: 'upsert',
          ));
      expect((await evidence()).trusted, isTrue);
    });

    test('at 取各源最大值（多源合并语义）', () async {
      await touchTransaction(); // 持久痕迹 ≈ now
      manager.markLocalChanged(ledgerId: 1); // 内存 ≈ now（更晚或相同）
      final e = await evidence();
      expect(e.at!.difference(DateTime.now()).abs().inSeconds, lessThan(5),
          reason: 'at 必须是所有候选写时刻里的最大值，而非某一路来源');
    });
  });
}
