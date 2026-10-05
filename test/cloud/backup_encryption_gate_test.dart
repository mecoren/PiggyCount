/// 云备份强制加密门禁回归（安全加固）：
/// 未开启端到端加密时**禁止**创建云端明文备份。
///
/// 锁死语义：
/// 1. 未开启 E2EE → 抛 [BackupRequiresEncryptionException]，且不上传任何对象；
/// 2. 未注入加密服务（null）同样 fail-closed，不因构造遗漏放行明文；
/// 3. 门禁在 `_busy` 置位前触发 → 异常后不残留互斥态（可再次调用，
///    仍是同一门禁异常而非 StateError）；
/// 4. 已开启 E2EE 时正常备份，门禁不误伤。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/backup/cloud_backup_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/domain/encryption/encryption_service.dart';

/// 记录上传次数的假存储（只实现 upload，二进制路径回退到它）。
class _FakeStorage extends fcs.NoopStorageService {
  final Map<String, String> files = {};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    files[path] = data;
  }
}

/// 可控开关的假加密服务。
class _FakeEncryption implements EncryptionService {
  _FakeEncryption(this._enabled);

  final bool _enabled;

  @override
  Future<bool> get isEnabled => Future.value(_enabled);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late _FakeStorage storage;
  late Directory tempRoot;
  late Directory docsDir;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    storage = _FakeStorage();
    tempRoot = await Directory.systemTemp.createTemp('pc_backup_gate');
    docsDir = Directory('${tempRoot.path}/docs');
    await docsDir.create(recursive: true);
  });

  tearDown(() async {
    await db.close();
    await tempRoot.delete(recursive: true);
  });

  CloudBackupService buildService(EncryptionService? enc) => CloudBackupService(
        db: db,
        repo: repo,
        storageResolver: () async => storage,
        encryptionService: enc,
        documentsDir: () async => docsDir,
      );

  Future<int> addLedger() =>
      db.into(db.ledgers).insert(LedgersCompanion.insert(name: 'Main'));

  test('未开启 E2EE：createBackup 抛门禁异常且不上传任何对象', () async {
    await addLedger();
    final service = buildService(_FakeEncryption(false));

    await expectLater(service.createBackup(),
        throwsA(isA<BackupRequiresEncryptionException>()));
    expect(storage.files, isEmpty, reason: '禁止创建明文备份，不应有任何上传');
  });

  test('门禁失败复位互斥态：异常后再次调用仍是门禁异常（不残留 busy）', () async {
    await addLedger();
    final service = buildService(_FakeEncryption(false));

    await expectLater(service.createBackup(),
        throwsA(isA<BackupRequiresEncryptionException>()));
    // 互斥锁在入口同步置位、门禁失败时复位；若未复位，第二次会得到
    // StateError（已有备份进行中）而不是门禁异常 —— 这条钉死复位语义。
    await expectLater(service.createBackup(),
        throwsA(isA<BackupRequiresEncryptionException>()));
  });

  test('未注入加密服务（null）：fail-closed，同样拒绝', () async {
    await addLedger();
    final service = buildService(null);

    await expectLater(service.createBackup(),
        throwsA(isA<BackupRequiresEncryptionException>()));
    expect(storage.files, isEmpty);
  });

  test('已开启 E2EE：正常备份，门禁不误伤', () async {
    final id = await addLedger();
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
        ledgerId: id, type: 'expense', amount: 10));
    final service = buildService(_FakeEncryption(true));

    final out = await service.createBackup();

    expect(out.ledgers, 1);
    expect(storage.files.keys.single,
        startsWith('piggycount-bak/PiggyCount-'));
  });
}
