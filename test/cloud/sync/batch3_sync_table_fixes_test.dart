// 批次3（不含 T1）同步表修复回归：
// - T5：local_changes.action 写入归一化（create/update → upsert），
//   v35 部分唯一索引恢复同实体未推送行去重能力
// - T7：server_marker 行纳入 cleanupPushedChanges 双保留窗清理
// - T8：pull apply 的 happenedAt 键存在但解析失败 → update 保留本地日期
// - T9：附件 localSha256 上传前按需回填（backfillAttachmentSha256）

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync/sync_engine.dart';
import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

import '_fakes/fake_piggycount_cloud_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late ChangeTracker tracker;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    tracker = ChangeTracker(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('T5：action 归一化', () {
    test('normalizeAction 映射表', () {
      expect(ChangeTracker.normalizeAction('create'), 'upsert');
      expect(ChangeTracker.normalizeAction('update'), 'upsert');
      expect(ChangeTracker.normalizeAction('upsert'), 'upsert');
      expect(ChangeTracker.normalizeAction('delete'), 'delete',
          reason: 'delete 有专属消费方（push 序列化 / orphan_scanner），保持原值');
      expect(ChangeTracker.normalizeAction(ChangeTracker.serverMarkerAction),
          ChangeTracker.serverMarkerAction,
          reason: 'server_marker 有专属清理策略，保持原值');
    });

    test('record*Change 写入的 create/update 统一落库为 upsert', () async {
      await tracker.recordUserGlobalChange(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'acc-1',
        action: 'create',
      );
      final rows = await (db.select(db.localChanges)).get();
      expect(rows.single.action, 'upsert');

      // 已推送后退出部分索引 → 二次编辑可再插一行（仍归一化为 upsert）
      await tracker.markPushed([rows.single.id]);
      await tracker.recordUserGlobalChange(
        entityType: 'account',
        entityId: 1,
        entitySyncId: 'acc-1',
        action: 'update',
      );
      final all = await (db.select(db.localChanges)).get();
      expect(all.length, 2);
      expect(all.every((r) => r.action == 'upsert'), isTrue);
    });

    test('统一词汇后 v35 部分唯一索引真正去重同实体未推送行', () async {
      await tracker.recordUserGlobalChange(
        entityType: 'tag',
        entityId: 7,
        entitySyncId: 'tag-1',
        action: 'create',
      );
      // 同实体再来一次 update：归一化后与首行同 (type, syncId, action)
      // → insertOrIgnore 命中部分唯一索引静默合并
      await tracker.recordUserGlobalChange(
        entityType: 'tag',
        entityId: 7,
        entitySyncId: 'tag-1',
        action: 'update',
      );

      final unpushed = await tracker.getUnpushedChangesForLedger(0);
      expect(unpushed.length, 1,
          reason: 'T5 前 create+update 会共存两条未推送行（推送冗余）');
    });

    test('recordBatch 同样归一化', () async {
      await tracker.recordBatch([
        LocalChangesCompanion.insert(
          entityType: 'transaction',
          entityId: 11,
          entitySyncId: 'tx-b1',
          ledgerId: 1,
          action: 'create',
        ),
        LocalChangesCompanion.insert(
          entityType: 'transaction',
          entityId: 12,
          entitySyncId: 'tx-b2',
          ledgerId: 1,
          action: 'update',
        ),
        LocalChangesCompanion.insert(
          entityType: 'transaction',
          entityId: 13,
          entitySyncId: 'tx-b3',
          ledgerId: 1,
          action: 'delete',
        ),
      ]);

      final rows = await (db.select(db.localChanges)
            ..where((c) => c.ledgerId.equals(1)))
          .get();
      final actionOf = {for (final r in rows) r.entitySyncId: r.action};
      expect(actionOf['tx-b1'], 'upsert');
      expect(actionOf['tx-b2'], 'upsert');
      expect(actionOf['tx-b3'], 'delete', reason: 'delete 不参与归一化');
    });
  });

  group('T7：server_marker 双保留窗清理', () {
    Future<LocalChange> insertPushedRow({
      required String entitySyncId,
      required String action,
      required DateTime pushedAt,
    }) async {
      final id = await db.into(db.localChanges).insert(
            LocalChangesCompanion.insert(
              entityType: 'account',
              entityId: 1,
              entitySyncId: entitySyncId,
              ledgerId: 0,
              action: action,
              pushedAt: d.Value(pushedAt),
            ),
          );
      return (await (db.select(db.localChanges)
                ..where((c) => c.id.equals(id)))
              .getSingle());
    }

    test('业务行超 7 天清理；标记行 8~30 天窗口内豁免、超 30 天清理', () async {
      final now = DateTime.now();
      final oldBusiness = await insertPushedRow(
        entitySyncId: 'biz-old',
        action: 'upsert',
        pushedAt: now.subtract(const Duration(days: 8)),
      );
      final recentBusiness = await insertPushedRow(
        entitySyncId: 'biz-new',
        action: 'upsert',
        pushedAt: now.subtract(const Duration(days: 2)),
      );
      final youngMarker = await insertPushedRow(
        entitySyncId: 'marker-young',
        action: ChangeTracker.serverMarkerAction,
        pushedAt: now.subtract(const Duration(days: 10)),
      );
      final ancientMarker = await insertPushedRow(
        entitySyncId: 'marker-ancient',
        action: ChangeTracker.serverMarkerAction,
        pushedAt: now.subtract(const Duration(days: 31)),
      );
      final unpushed = await db.into(db.localChanges).insert(
            LocalChangesCompanion.insert(
              entityType: 'account',
              entityId: 2,
              entitySyncId: 'biz-unpushed',
              ledgerId: 0,
              action: 'upsert',
              createdAt: d.Value(now.subtract(const Duration(days: 40))),
            ),
          );

      final deleted = await tracker.cleanupPushedChanges();

      expect(deleted, 2, reason: '只清「业务>7天」和「标记>30天」两类');
      final remain = await (db.select(db.localChanges)).get();
      final remainIds = remain.map((r) => r.id).toSet();
      expect(remainIds, containsAll([recentBusiness.id, youngMarker.id, unpushed]),
          reason: '新业务行、窗口内标记行、未推送行都必须存活');
      expect(remainIds.contains(oldBusiness.id), isFalse);
      expect(remainIds.contains(ancientMarker.id), isFalse);
    });

    test('标记行在默认 30 天窗内不被 7 天清理误删（M2 防重推保护仍在）', () async {
      final now = DateTime.now();
      await insertPushedRow(
        entitySyncId: 'marker-15d',
        action: ChangeTracker.serverMarkerAction,
        pushedAt: now.subtract(const Duration(days: 15)),
      );

      await tracker.cleanupPushedChanges(); // 默认参数

      final remain = await (db.select(db.localChanges)).get();
      expect(remain, hasLength(1));
      expect(remain.single.entitySyncId, 'marker-15d');
    });
  });

  group('T9：附件 localSha256 上传前按需回填', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pc_t9_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<int> writeAttachmentRow(String fileName) async {
      return db.into(db.transactionAttachments).insert(
            TransactionAttachmentsCompanion.insert(
              transactionId: 1,
              fileName: fileName,
            ),
          );
    }

    test('文件存在 → 计算 sha256 并回调落库；文件缺失 → 保持 NULL', () async {
      final bytes = Uint8List.fromList(utf8.encode('attachment-bytes'));
      final f = File('${tempDir.path}/sha_a.jpg');
      await f.writeAsBytes(bytes);
      final expectedSha = crypto.sha256.convert(bytes).toString();

      final idWithFile = await writeAttachmentRow('sha_a.jpg');
      final idMissingFile = await writeAttachmentRow('ghost.jpg');

      final resolved = <(int, String)>[];
      final filled = await backfillAttachmentSha256(
        db: db,
        // 模拟 repo.updateAttachmentLocalSha256 的真实落库行为
        onResolved: (id, sha) async {
          resolved.add((id, sha));
          await (db.update(db.transactionAttachments)
                ..where((a) => a.id.equals(id)))
              .write(TransactionAttachmentsCompanion(
                  localSha256: d.Value(sha)));
        },
        txIds: const [1],
        attachmentsDir: tempDir,
      );

      expect(filled, 1);
      expect(resolved, [(idWithFile, expectedSha)]);
      expect(resolved.first.$2, hasLength(64));

      final rows = await (db.select(db.transactionAttachments)).get();
      final byId = {for (final r in rows) r.id: r};
      expect(byId[idWithFile]!.localSha256, expectedSha);
      expect(byId[idMissingFile]!.localSha256, isNull,
          reason: '孤儿行保持 NULL，交由启动任务下次再试');
    });

    test('txIds 为空或无 NULL 行时零工作直接返回', () async {
      await writeAttachmentRow('a.jpg');
      // 先手动回填该行
      await db.customStatement(
          'UPDATE transaction_attachments SET local_sha256 = ? WHERE local_sha256 IS NULL',
          ['x']);

      var called = false;
      final filled = await backfillAttachmentSha256(
        db: db,
        onResolved: (_, __) async => called = true,
        txIds: const [1],
        attachmentsDir: tempDir,
      );
      expect(filled, 0);
      expect(called, isFalse);

      final empty = await backfillAttachmentSha256(
        db: db,
        onResolved: (_, __) async {},
        txIds: const [],
        attachmentsDir: tempDir,
      );
      expect(empty, 0);
    });
  });

  group('T8：happenedAt 解析失败不覆盖本地日期', () {
    late FakePiggyCountCloudProvider provider;
    late SyncEngine engine;
    late LocalRepository repo;

    // 注意：AppCursorStore 以 (baseUrl|userId|deviceId) 为 key 持久化到
    // SharedPreferences（单例缓存跨测试存活）。两个用例必须使用不同的
    // userId，否则前一个用例 commit 的 cursor 会让后一个从 since>0 拉取。
    void buildEngine(String userId) {
      provider = FakePiggyCountCloudProvider(userId: userId);
      repo = LocalRepository(db, changeTracker: tracker);
      engine = SyncEngine(
          db: db, provider: provider, changeTracker: tracker, repo: repo);
    }

    Future<void> seedLedgerAndTx() async {
      await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', syncId: const d.Value('L1')));
      await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 100,
              happenedAt: d.Value(DateTime.parse('2026-05-01T10:00:00Z')),
              syncId: const d.Value('tx-X'),
            ),
          );
    }

    Map<String, dynamic> payload(Map<String, dynamic> overrides) =>
        {
          'syncId': 'tx-X',
          'type': 'expense',
          'amount': 55,
          'happenedAt': '2026-05-01T10:00:00Z',
          ...overrides,
        };

    test('脏 happenedAt（键存在但值非法）→ 金额更新、日期保留', () async {
      buildEngine('t8-user-dirty');
      await seedLedgerAndTx();
      provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'tx-X',
        ledgerId: 'L1',
        payload: payload({'happenedAt': 'not-a-date'}),
      );

      expect(await engine.pull(''), 1);
      final tx = (await db.select(db.transactions).get()).single;
      expect(tx.amount, 55, reason: '合法字段正常应用');
      // drift 读回为本地时区表示，统一转 UTC 比较同一瞬间
      expect(tx.happenedAt.toUtc(), DateTime.parse('2026-05-01T10:00:00Z'),
          reason: 'T8 前 tryParse 失败会兜底 DateTime.now() 覆盖本地日期');
    });

    test('合法 happenedAt 照常覆盖（守卫不误伤正常链路）', () async {
      buildEngine('t8-user-valid');
      await seedLedgerAndTx();
      provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'tx-X',
        ledgerId: 'L1',
        payload: payload({'happenedAt': '2026-06-15T08:30:00Z'}),
      );

      expect(await engine.pull(''), 1);
      final tx = (await db.select(db.transactions).get()).single;
      expect(tx.happenedAt.toUtc(), DateTime.parse('2026-06-15T08:30:00Z'));
    });
  });
}
