/// 整库加密开关的状态机（R2/R5/R6）。
///
/// 这个服务是用户唯一的"事实来源"：开关显示什么、能不能点、点了之后库会不会
/// 真的变，全靠它。所以逐态钉住 —— 尤其 `keyMissing`（R5，绝不能显示成"未加密"
/// 让用户以为可以随便点）与 `pending*`（已点但未重启，不能假装已生效）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:piggycount/data/encryption/database_key_service.dart';
import 'package:piggycount/data/encryption/db_encryption_migration.dart';
import 'package:piggycount/data/encryption/db_encryption_settings.dart';
import 'package:piggycount/data/encryption/local_db_encryption_service.dart';
import 'package:piggycount/data/encryption/sqlcipher_capability.dart';

import '../support/sqlcipher_support.dart';

const String keyA =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String dbPath;
  late Map<String, String> store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dbenc_switch');
    dbPath = p.join(tmp.path, 'x.sqlite');
    store = <String, String>{};
    DatabaseKeyService.testSecureStore = store;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    DatabaseKeyService.testSecureStore = null;
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  LocalDbEncryptionService service() =>
      LocalDbEncryptionService(dbPathResolver: () async => dbPath);

  void makePlainDb() {
    final db = sqlite3.open(dbPath);
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
    db.close();
  }

  group('状态判定', () {
    /// 引擎没有加密能力时，"能不能开"这个问题的答案就是 `unsupported` ——
    /// 显示成 `disabled`（未加密）会暗示"可以打开"，而本机根本做不到。
    /// 所以除了 [LocalDbEncryptionState.keyMissing]（那是数据可读性问题，
    /// 优先于能力问题），其余状态在无能力引擎上一律收敛为 `unsupported`。
    Future<void> expectSupportedState(LocalDbEncryptionState expected) async {
      final actual = await service().state();
      expect(actual,
          SqlCipherCapability.isSupported ? expected : LocalDbEncryptionState.unsupported);
    }

    test('库还不存在 + 无密钥 → disabled', () async {
      await expectSupportedState(LocalDbEncryptionState.disabled);
    });

    test('明文库 + 无密钥 → disabled', () async {
      makePlainDb();
      await expectSupportedState(LocalDbEncryptionState.disabled);
    });

    test('开了密钥但库还是明文 → pendingEnable（不能假装已生效）', () async {
      makePlainDb();
      store[DatabaseKeyService.storageKey] = keyA;
      await expectSupportedState(LocalDbEncryptionState.pendingEnable);
    });

    test('登记关闭后 → pendingDisable', () async {
      makePlainDb();
      store[DatabaseKeyService.storageKey] = keyA;
      await const DbEncryptionSettings().requestDisable();
      // 明文库 + 关闭意图：对用户而言"正在关闭"，同样是待重启态
      await expectSupportedState(LocalDbEncryptionState.pendingDisable);
    });

    sqlCipherTest('密文库 + 有密钥 → enabled', () async {
      makePlainDb();
      await const DbEncryptionMigration()
          .prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      store[DatabaseKeyService.storageKey] = keyA;
      expect(await service().state(), LocalDbEncryptionState.enabled);
    });

    sqlCipherTest('密文库 + 无密钥（且曾启用过）→ keyMissing（R5：不能显示成"未加密"）',
        () async {
      makePlainDb();
      await const DbEncryptionMigration()
          .prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      // 与生产一致：曾开启过加密才会留下这个标记（判据靠它区分垃圾文件）
      await const DbEncryptionSettings().markEverEnabled();
      // 不往 store 里放钥匙 = 用户换机/密钥丢失
      expect(await service().state(), LocalDbEncryptionState.keyMissing);
    });

    sqlCipherTest('密文库 + 无密钥 + **没**启用过 → 不算 keyMissing（那是文件坏了）',
        () async {
      makePlainDb();
      await const DbEncryptionMigration()
          .prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      // 刻意不标记：没有加密史时不该把它解释成"加密缺钥"
      expect(await service().state(),
          isNot(LocalDbEncryptionState.keyMissing));
    });
  });

  group('开关动作', () {
    test('enable() 生成密钥但不动库文件（改库要等重启）', () async {
      makePlainDb();
      final before = File(dbPath).readAsBytesSync();

      if (!SqlCipherCapability.isSupported) {
        // 引擎不支持时必须**响亮拒绝**，而不是写一把用不上的钥匙
        await expectLater(service().enable(),
            throwsA(isA<DbEncryptionUnsupportedException>()));
        expect(store[DatabaseKeyService.storageKey], isNull,
            reason: '不支持加密时不该留下密钥（那会造成"看起来已开启"）');
        expect(await const DbEncryptionSettings().wasEverEnabled(), isFalse,
            reason: '没开成就不该留下"曾启用"标记');
        expect(File(dbPath).readAsBytesSync(), before);
        return;
      }

      await service().enable();
      expect(DatabaseKeyService.isValidKey(store[DatabaseKeyService.storageKey]!),
          isTrue);
      expect(await const DbEncryptionSettings().wasEverEnabled(), isTrue,
          reason: '开启后要留标记：万一将来密钥丢了，健康探测靠它把'
              '「加密库缺钥」与「垃圾文件」区分开');
      expect(File(dbPath).readAsBytesSync(), before,
          reason: '运行中不迁移库文件（迁移在开库前做），所以开关态是 pendingEnable');
    });

    test('requestDisable() 只登记意图，绝不先删钥（先删钥=丢数据）', () async {
      store[DatabaseKeyService.storageKey] = keyA;
      await service().requestDisable();

      expect(store[DatabaseKeyService.storageKey], keyA,
          reason: '密钥必须留到"成功解回明文"之后才删');
      expect(await const DbEncryptionSettings().isDisableRequested(), isTrue);
    });

    test('cancelDisable() 撤销意图（重启前反悔）', () async {
      store[DatabaseKeyService.storageKey] = keyA;
      await service().requestDisable();
      await service().cancelDisable();
      expect(await const DbEncryptionSettings().isDisableRequested(), isFalse);
    });

    test('enable() 会清掉先前登记的关闭意图（开启优先于陈旧的关闭）', () async {
      makePlainDb();
      await const DbEncryptionSettings().requestDisable();
      if (!SqlCipherCapability.isSupported) return; // 上面已单测过拒绝路径
      await service().enable();
      expect(await const DbEncryptionSettings().isDisableRequested(), isFalse);
    });
  });
}
