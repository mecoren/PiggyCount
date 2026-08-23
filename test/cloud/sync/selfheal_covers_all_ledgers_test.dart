// 致命 S2：自愈必须让「全部本地账本」以云端快照为准，
// 而不是只恢复 stuckChanges 涉及账本后把游标推到头部、
// 让健康账本(ledger-b)的待拉增量被永久跳过。
import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync/sync_engine.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/encryption/aes_gcm_cipher.dart';
import 'package:piggycount/data/encryption/argon2_key_derivation.dart';
import 'package:piggycount/data/encryption/encryption_service_impl.dart';
import 'package:piggycount/data/encryption/secure_key_storage.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

import '_fakes/fake_piggycount_cloud_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('自愈后：受影响账本与健康账本都以快照恢复，游标推进到头部', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 本地两个账本 + 共享分类
    await db.into(db.ledgers).insert(
        LedgersCompanion.insert(name: 'A', syncId: const Value('ledger-a')));
    await db.into(db.ledgers).insert(
        LedgersCompanion.insert(name: 'B', syncId: const Value('ledger-b')));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        name: 'C', kind: 'expense', syncId: const Value('C')));

    final enc = EncryptionServiceImpl(
      storage: SecureKeyStorage(),
      keyDerivation: const Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );
    final changeTracker = ChangeTracker(db);
    final repo = LocalRepository(db, changeTracker: changeTracker);
    final provider = FakePiggyCountCloudProvider();
    final engine = SyncEngine(
      db: db,
      provider: provider,
      changeTracker: changeTracker,
      repo: repo,
      encryptionService: enc,
    );

    // 开启加密 → 旧密钥密文(change#1) → 改密(本地换新钥，服务端密文仍是旧钥)
    await enc.enable(password: 'password1A');
    Map<String, dynamic> txPayload(String syncId, double amount) => {
          'syncId': syncId,
          'type': 'expense',
          'amount': amount,
          'happenedAt': '2026-05-01T10:00:00Z',
          'categoryName': 'C',
          'categoryKind': 'expense',
          'categoryId': 'C',
        };
    final oldKeyCipher =
        await enc.encrypt(jsonEncode(txPayload('tx-old-a', 111)));
    await enc.changePassword(
        oldPassword: 'password1A', newPassword: 'password2Bx');

    // change#1：旧钥密文（将触发解密失败）
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-old-a',
      ledgerId: 'ledger-a',
      payload: {'__encrypted__': true, 'ciphertext': oldKeyCipher},
    );
    // change#2：健康账本 ledger-b 的新钥密文（旧行为下会被游标跳越永久丢失）
    final healthyB = await enc.encrypt(jsonEncode(txPayload('tx-new-b', 222)));
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-new-b',
      ledgerId: 'ledger-b',
      payload: {'__encrypted__': true, 'ciphertext': healthyB},
    );

    // 为两个账本各准备云端全量快照（fullPull 数据源，path=账本 syncId）
    String snapshot(String txId, double amount) => jsonEncode({
          'version': 6,
          'exportedAt': '2026-05-02T00:00:00Z',
          'ledgerName': 'L',
          'currency': 'CNY',
          'monthStartDay': 1,
          'accounts': [],
          'categories': [
            {
              'syncId': 'C',
              'name': 'C',
              'kind': 'expense',
              'level': 1,
            }
          ],
          'tags': [],
          'items': [
            {
              'syncId': txId,
              'type': 'expense',
              'amount': amount,
              'happenedAt': '2026-05-01T10:00:00Z',
              'note': 'restored',
              'categoryName': 'C',
              'categoryKind': 'expense',
              'categoryId': 'C',
            }
          ],
        });
    provider.storage
        .upload(path: 'ledger-a', data: snapshot('tx-old-a', 111));
    provider.storage
        .upload(path: 'ledger-b', data: snapshot('tx-new-b', 222));
    provider.pushFakeLedgerSnapshot(ledgerId: 'ledger-a');
    provider.pushFakeLedgerSnapshot(ledgerId: 'ledger-b');

    // Act：直接触发自愈（stuck = change#1，旧钥密文那条）
    final page = await provider.pullChanges(since: 0, limit: 100);
    expect(page.changes, hasLength(2));
    await engine.debugRunStuckPullRecovery([page.changes.first]);

    // Assert 1：健康账本 B 的交易已从快照恢复（旧行为：缺失）
    final bRows = await (db.select(db.transactions)
          ..where((t) => t.syncId.equals('tx-new-b')))
        .get();
    expect(bRows, hasLength(1), reason: 'S2 核心断言：健康账本增量不得被跳过');

    // Assert 2：受影响账本 A 也已恢复
    final aRows = await (db.select(db.transactions)
          ..where((t) => t.syncId.equals('tx-old-a')))
        .get();
    expect(aRows, hasLength(1));

    // Assert 3：游标已在头部——再推一条新 change(#3)，pull 只应用它
    final fresh = await enc.encrypt(jsonEncode(txPayload('tx-fresh', 333)));
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-fresh',
      ledgerId: 'ledger-b',
      payload: {'__encrypted__': true, 'ciphertext': fresh},
    );
    final applied = await engine.pull('');
    expect(applied, 1, reason: '游标若仍停留在旧位置会重复应用历史变更');

    await db.close();
  });
}
