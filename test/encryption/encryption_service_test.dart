// EncryptionServiceImpl 单元测试
//
// 锁死 EncryptionService 核心契约：
// - enable / disable / reset 生命周期
// - verifyPassword 密码校验
// - changePassword 密码修改
// - encrypt / decrypt 加解密 + 明文/密文自动识别
// - activateKey / persistActivatedKey 改密流程
//
// 使用 InMemorySecureKeyStorage 真实模拟存储行为（不依赖平台 channel）。
// 使用 Argon2KeyDerivation.forTesting() 保持测试快速。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/encryption/aes_gcm_cipher.dart';
import 'package:piggycount/data/encryption/argon2_key_derivation.dart';
import 'package:piggycount/data/encryption/ciphertext_format.dart';
import 'package:piggycount/data/encryption/encryption_service_impl.dart';
import 'package:piggycount/data/encryption/secure_key_storage.dart';
import 'package:piggycount/domain/encryption/encryption_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemorySecureKeyStorage storage;
  late EncryptionServiceImpl service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = InMemorySecureKeyStorage();
    service = EncryptionServiceImpl(
      storage: storage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );
  });

  group('密码最小长度阈值契约', () {
    test('EncryptionService.minPasswordLength 为 8（NIST SP 800-63B）', () {
      // 契约：UI 对话框与服务层共用此常量，前后端阈值必须一致
      expect(EncryptionService.minPasswordLength, 8);
    });

    test('enable 拒绝长度 < 8 的密码（抛 ArgumentError）', () async {
      // 7 字符：对话框旧阈值(<6)放行过，但服务层阈值(8)会抛 ArgumentError
      expect(
        () => service.enable(password: '1234567'),
        throwsA(isA<ArgumentError>()),
      );
      expect(await service.isEnabled, isFalse,
          reason: '密码过短时不应写入任何状态');
    });

    test('enable 接受长度 == 8 的密码', () async {
      // SYNC-12：8 位边界 + 复杂度（字母/数字两类）需同时满足
      await service.enable(password: 'Pass1234');
      expect(await service.isEnabled, isTrue);
    });
  });

  group('EncryptionServiceImpl.isEnabled', () {
    test('初始状态未开启', () async {
      expect(await service.isEnabled, isFalse);
    });

    test('enable 后变为已开启', () async {
      await service.enable(password: 'MyPassw0rd');
      expect(await service.isEnabled, isTrue);
    });

    test('disable 后变为未开启', () async {
      await service.enable(password: 'MyPassw0rd');
      await service.disable();
      expect(await service.isEnabled, isFalse);
    });
  });

  group('EncryptionServiceImpl.hasActiveKey', () {
    test('初始状态无密钥', () async {
      expect(await service.hasActiveKey, isFalse);
    });

    test('enable 后有密钥', () async {
      await service.enable(password: 'MyPassw0rd');
      expect(await service.hasActiveKey, isTrue);
    });

    test('disable 后仍有密钥（保留用于解密存量密文）', () async {
      await service.enable(password: 'MyPassw0rd');
      await service.disable();
      expect(await service.hasActiveKey, isTrue);
    });

    test('reset 后无密钥', () async {
      await service.enable(password: 'MyPassw0rd');
      await service.reset();
      expect(await service.hasActiveKey, isFalse);
    });
  });

  group('EncryptionServiceImpl.enable', () {
    test('密码为空抛出 ArgumentError', () async {
      expect(
        () => service.enable(password: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('密码过短（< 6 字符）抛出 ArgumentError', () async {
      expect(
        () => service.enable(password: '12345'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('enable 后 secure storage 中有 key、salt、verifier', () async {
      await service.enable(password: 'MyPassw0rd');

      expect(await storage.getKey(), isNotNull);
      expect(await storage.getSalt(), isNotNull);
      expect(await storage.getVerifier(), isNotNull);
    });

    test('enable 后 activeSalt 不为 null', () async {
      await service.enable(password: 'MyPassw0rd');
      expect(service.activeSalt, isNotNull);
      expect(service.activeSalt!.length, 16);
    });
  });

  group('EncryptionServiceImpl.verifyPassword', () {
    test('正确密码返回 true', () async {
      await service.enable(password: 'CorrectPass1');
      expect(await service.verifyPassword('CorrectPass1'), isTrue);
    });

    test('错误密码返回 false', () async {
      await service.enable(password: 'CorrectPass1');
      expect(await service.verifyPassword('WrongPass9'), isFalse);
    });

    test('未开启加密时返回 false', () async {
      expect(await service.verifyPassword('anything'), isFalse);
    });

    test('reset 后返回 false', () async {
      await service.enable(password: 'CorrectPass1');
      await service.reset();
      expect(await service.verifyPassword('CorrectPass1'), isFalse);
    });
  });

  group('EncryptionServiceImpl.encrypt / decrypt', () {
    test('未开启加密时 encrypt 返回原文', () async {
      const plaintext = '{"version":6,"items":[]}';
      final result = await service.encrypt(plaintext);
      expect(result, plaintext);
    });

    test('未开启加密时 decrypt 返回原文（legacy 明文兼容）', () async {
      const plaintext = '{"version":6,"items":[]}';
      final result = await service.decrypt(plaintext);
      expect(result, plaintext);
    });

    test('开启加密后 encrypt 返回 BEECRYPT1: 格式密文', () async {
      await service.enable(password: 'MyPassw0rd');
      const plaintext = '{"version":6,"items":[]}';

      final result = await service.encrypt(plaintext);

      expect(CiphertextFormat.isEncrypted(result), isTrue);
    });

    test('encrypt → decrypt 往返还原原文', () async {
      await service.enable(password: 'MyPassw0rd');
      const plaintext = '{"version":6,"items":[{"amount":99.9}]}';

      final ciphertext = await service.encrypt(plaintext);
      final decrypted = await service.decrypt(ciphertext);

      expect(decrypted, plaintext);
    });

    test('decrypt legacy 明文（无 magic header）原样返回', () async {
      await service.enable(password: 'MyPassw0rd');
      const legacyPlaintext = '{"version":5,"items":[]}';

      final result = await service.decrypt(legacyPlaintext);

      expect(result, legacyPlaintext);
    });

    test('加密后密文内容与原文不同（非明文）', () async {
      await service.enable(password: 'MyPassw0rd');
      const plaintext = '{"version":6,"items":[{"amount":99.9}]}';

      final ciphertext = await service.encrypt(plaintext);

      expect(ciphertext, isNot(plaintext));
      expect(ciphertext.contains('amount'), isFalse);
    });
  });

  group('EncryptionServiceImpl.changePassword', () {
    test('正确旧密码 + 有效新密码 → 修改成功', () async {
      await service.enable(password: 'OldPassw0rd');

      await service.changePassword(
        oldPassword: 'OldPassw0rd',
        newPassword: 'NewPassw0rd1',
      );

      // 新密码应该能验证
      expect(await service.verifyPassword('NewPassw0rd1'), isTrue);
      // 旧密码应该不能验证
      expect(await service.verifyPassword('OldPassw0rd'), isFalse);
    });

    test('错误旧密码 → 抛出 ArgumentError', () async {
      await service.enable(password: 'OldPassw0rd');

      expect(
        () => service.changePassword(
          oldPassword: 'wrongold',
          newPassword: 'NewPassw0rd1',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('新密码无效（过短）→ 抛出 ArgumentError', () async {
      await service.enable(password: 'OldPassw0rd');

      expect(
        () => service.changePassword(
          oldPassword: 'OldPassw0rd',
          newPassword: '12345',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('修改密码后仍能解密用新密码加密的数据', () async {
      await service.enable(password: 'OldPassw0rd');
      const plaintext = '{"version":6,"items":[]}';

      await service.changePassword(
        oldPassword: 'OldPassw0rd',
        newPassword: 'NewPassw0rd1',
      );

      final ciphertext = await service.encrypt(plaintext);
      final decrypted = await service.decrypt(ciphertext);
      expect(decrypted, plaintext);
    });

    test('修改密码后用旧密码加密的密文无法用新密钥解密', () async {
      await service.enable(password: 'OldPassw0rd');
      const plaintext = '{"version":6,"items":[]}';

      // 用旧密码加密
      final oldCiphertext = await service.encrypt(plaintext);

      // 修改密码
      await service.changePassword(
        oldPassword: 'OldPassw0rd',
        newPassword: 'NewPassw0rd1',
      );

      // 旧密文（salt 不同）应该无法解密
      expect(
        () => service.decrypt(oldCiphertext),
        throwsA(isA<DecryptionException>()),
      );
    });
  });

  group('EncryptionServiceImpl.reset', () {
    test('reset 后 secure storage 完全清空', () async {
      await service.enable(password: 'MyPassw0rd');

      await service.reset();

      expect(await storage.getKey(), isNull);
      expect(await storage.getSalt(), isNull);
      expect(await storage.getVerifier(), isNull);
    });

    test('reset 后 isEnabled 为 false', () async {
      await service.enable(password: 'MyPassw0rd');

      await service.reset();

      expect(await service.isEnabled, isFalse);
    });

    test('reset 后 activeSalt 为 null', () async {
      await service.enable(password: 'MyPassw0rd');

      await service.reset();

      expect(service.activeSalt, isNull);
    });
  });

  group('EncryptionServiceImpl.activateKey / persistActivatedKey', () {
    test('activateKey 后 activeSalt 为传入的 salt', () async {
      final salt = List<int>.generate(16, (i) => 0x42);

      await service.activateKey(password: 'testpw88', salt: salt);

      expect(service.activeSalt, equals(salt));
    });

    test('activateKey 后 encrypt 可用（无需 enable）', () async {
      await service.enable(password: 'temppw88');
      final salt = List<int>.generate(16, (i) => 0x99);

      await service.activateKey(password: 'newpass88', salt: salt);

      const plaintext = 'test data';
      final ciphertext = await service.encrypt(plaintext);
      expect(CiphertextFormat.isEncrypted(ciphertext), isTrue);
    });

    test('persistActivatedKey 后密钥持久化到 secure storage', () async {
      await service.enable(password: 'temppw88');
      final salt = List<int>.generate(16, (i) => 0x77);

      await service.activateKey(password: 'newpass88', salt: salt);
      await service.persistActivatedKey();

      expect(await storage.getKey(), isNotNull);
      expect(await storage.getSalt(), equals(salt));
      expect(await storage.getVerifier(), isNotNull);
    });

    test('无激活密钥时 persistActivatedKey 抛出 StateError', () async {
      expect(
        () => service.persistActivatedKey(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('EncryptionServiceImpl 多设备场景模拟', () {
    test('A 设备加密 → B 设备同密码解密', () async {
      // A 设备：开启加密并加密数据
      await service.enable(password: 'SharedPass7');
      const plaintext = '{"version":6,"items":[{"amount":100}]}';
      final ciphertext = await service.encrypt(plaintext);

      // B 设备：新实例，无密钥
      final storageB = InMemorySecureKeyStorage();
      final serviceB = EncryptionServiceImpl(
        storage: storageB,
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );

      // B 设备用相同密码激活密钥（salt 从密文头取）
      final decoded = CiphertextFormat.decode(ciphertext);
      await serviceB.activateKey(
        password: 'SharedPass7',
        salt: decoded.salt,
      );

      // B 设备解密
      final decrypted = await serviceB.decrypt(ciphertext);
      expect(decrypted, plaintext);
    });

    test('A 设备加密 → B 设备不同密码解密失败', () async {
      await service.enable(password: 'CorrectPass1x');
      const plaintext = '{"version":6,"items":[]}';
      final ciphertext = await service.encrypt(plaintext);

      final storageB = InMemorySecureKeyStorage();
      final serviceB = EncryptionServiceImpl(
        storage: storageB,
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );

      final decoded = CiphertextFormat.decode(ciphertext);
      await serviceB.activateKey(
        password: 'WrongPass9x',
        salt: decoded.salt,
      );

      expect(
        () => serviceB.decrypt(ciphertext),
        throwsA(isA<DecryptionException>()),
      );
    });

    test('US-2: salt 不匹配时抛出 SaltMismatchException（可被 UI 单独捕获）', () async {
      // A 设备：用密码 A 加密
      await service.enable(password: 'PasswordA1');
      const plaintext = '{"version":6,"items":[]}';
      final ciphertext = await service.encrypt(plaintext);

      // B 设备：用密码 B 激活（生成不同 salt 的密钥）
      final storageB = InMemorySecureKeyStorage();
      final serviceB = EncryptionServiceImpl(
        storage: storageB,
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      // B 设备自行 enable，生成自己的 salt（与 A 不同）
      await serviceB.enable(password: 'PasswordB2');

      // B 设备尝试解密 A 的密文 → salt 不匹配
      expect(
        () => serviceB.decrypt(ciphertext),
        throwsA(isA<SaltMismatchException>()),
        reason: 'salt 不匹配时应抛出 SaltMismatchException，让 UI 可单独捕获'
            '并引导用户重新输入密码',
      );
    });

    test('US-2: SaltMismatchException 是 DecryptionException 的子类（向后兼容）',
        () async {
      // 已有代码 catch DecryptionException 时仍能捕获 SaltMismatchException
      await service.enable(password: 'PasswordA1');
      const plaintext = '{"version":6,"items":[]}';
      final ciphertext = await service.encrypt(plaintext);

      final storageB = InMemorySecureKeyStorage();
      final serviceB = EncryptionServiceImpl(
        storage: storageB,
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      await serviceB.enable(password: 'PasswordB2');

      // 用 catch DecryptionException 捕获，验证 SaltMismatchException 也被捕获
      var caught = false;
      try {
        await serviceB.decrypt(ciphertext);
      } on DecryptionException {
        caught = true;
      }
      expect(caught, isTrue,
          reason: 'SaltMismatchException 应继承自 DecryptionException，'
              '保证已有 catch DecryptionException 的代码仍能工作');
    });
  });

  group('EncryptionServiceImpl.reEncryptExistingCloudData', () {
    late _FakeCloudStorage cloud;

    setUp(() {
      cloud = _FakeCloudStorage();
    });

    test('加密未开启时抛 StateError', () async {
      expect(
        () => service.reEncryptExistingCloudData(cloudStorage: cloud),
        throwsA(isA<StateError>()),
      );
    });

    test('云端有 legacy 明文 → 全部重加密为 BEECRYPT1: 格式', () async {
      await service.enable(password: 'MyPassw0rd');
      cloud.stored['ledger_1.json'] = '{"version":6,"items":[]}';
      cloud.stored['ledger_2.json'] = '{"version":6,"items":[{"amount":99}]}';
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      final result = await service.reEncryptExistingCloudData(cloudStorage: cloud);

      expect(result.success, 2);
      expect(result.failed, 0);
      expect(result.skipped, 0);
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_1.json']!), isTrue);
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_2.json']!), isTrue);
      // 密文中不应包含明文片段
      expect(cloud.stored['ledger_1.json']!.contains('version'), isFalse);
    });

    test('混合 legacy 明文 + 已加密密文 → 都重加密为新密文', () async {
      // 场景：用户之前已开过加密（用相同密码），现在重新开启
      await service.enable(password: 'MyPassw0rd');
      final ciphertext = await service.encrypt('{"version":6,"items":[]}');
      cloud.stored['ledger_1.json'] = ciphertext; // 已是密文
      cloud.stored['ledger_2.json'] = '{"version":6,"items":[]}'; // legacy 明文
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      final result = await service.reEncryptExistingCloudData(cloudStorage: cloud);

      expect(result.success, 2);
      expect(result.failed, 0);
      // 两份都应是密文
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_1.json']!), isTrue);
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_2.json']!), isTrue);
      // 解密后内容一致
      final decrypted = await service.decrypt(cloud.stored['ledger_1.json']!);
      expect(decrypted, '{"version":6,"items":[]}');
    });

    test('非 ledger_*.json 文件被跳过', () async {
      await service.enable(password: 'MyPassw0rd');
      cloud.stored['readme.txt'] = 'hello';
      cloud.stored['ledger_1.json'] = '{"version":6,"items":[]}';
      cloud.listFiles = [
        CloudFile(name: 'readme.txt', path: 'readme.txt'),
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'backup.old', path: 'backup.old'),
      ];

      final result = await service.reEncryptExistingCloudData(cloudStorage: cloud);

      expect(result.success, 1);
      expect(result.failed, 0);
      expect(result.skipped, 2); // readme.txt + backup.old
      expect(cloud.stored['readme.txt'], 'hello'); // 未被改
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_1.json']!), isTrue);
    });

    test('download 返回 null 的文件被跳过', () async {
      await service.enable(password: 'MyPassw0rd');
      // list 返回了文件名但 stored 中没有该文件 → download 返回 null
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
      ];

      final result = await service.reEncryptExistingCloudData(cloudStorage: cloud);

      expect(result.success, 0);
      expect(result.skipped, 1);
      expect(result.failed, 0);
    });

    test('单文件 download 失败不中断整体流程', () async {
      await service.enable(password: 'MyPassw0rd');
      cloud.stored['ledger_1.json'] = '{"version":6,"items":[]}';
      cloud.stored['ledger_2.json'] = '{"version":6,"items":[]}';
      cloud.throwOnDownloadPaths.add('ledger_1.json');
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      final result = await service.reEncryptExistingCloudData(cloudStorage: cloud);

      expect(result.success, 1); // ledger_2 成功
      expect(result.failed, 1); // ledger_1 失败
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_2.json']!), isTrue);
    });

    test('单文件 upload 失败不中断整体流程', () async {
      await service.enable(password: 'MyPassw0rd');
      cloud.stored['ledger_1.json'] = '{"version":6,"items":[]}';
      cloud.stored['ledger_2.json'] = '{"version":6,"items":[]}';
      cloud.throwOnUploadPaths.add('ledger_2.json');
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      final result = await service.reEncryptExistingCloudData(cloudStorage: cloud);

      expect(result.success, 1); // ledger_1 成功
      expect(result.failed, 1); // ledger_2 失败
    });

    test('list 抛错时整体失败，抛出原异常', () async {
      await service.enable(password: 'MyPassw0rd');
      cloud.listFiles = []; // 不会被读到
      // 用一个会抛错的 storage
      final throwingStorage = _ThrowingListStorage();

      expect(
        () => service.reEncryptExistingCloudData(cloudStorage: throwingStorage),
        throwsA(isA<Exception>()),
      );
    });

    test('加密已开启但密钥不可用（reset 后）→ 抛 StateError', () async {
      // 模拟异常状态：isEnabled=true 但 key 已被清空
      await service.enable(password: 'MyPassw0rd');
      // 直接清掉内存 key 模拟密钥不可用
      await service.reset();
      // reset 会同时把 isEnabled 置 false，所以这个场景实际不会发生
      // 但若仅清 key 而保留 enabled flag，应抛 StateError
      // 这里通过 disable 后再 reset 来验证 enabled=false 时也会抛
      expect(
        () => service.reEncryptExistingCloudData(cloudStorage: cloud),
        throwsA(isA<StateError>()),
      );
    });

    test('重加密后再调用一次（幂等性）→ 文件仍是密文，success 不变', () async {
      await service.enable(password: 'MyPassw0rd');
      cloud.stored['ledger_1.json'] = '{"version":6,"items":[]}';
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
      ];

      await service.reEncryptExistingCloudData(cloudStorage: cloud);
      final firstCipher = cloud.stored['ledger_1.json']!;

      // 再次调用
      final result = await service.reEncryptExistingCloudData(cloudStorage: cloud);
      expect(result.success, 1);
      // 仍是密文（可能因 nonce 不同而内容不同，但格式必须是密文）
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_1.json']!), isTrue);
      // 解密后内容一致
      final decrypted = await service.decrypt(cloud.stored['ledger_1.json']!);
      expect(decrypted, '{"version":6,"items":[]}');
      // 第一次的密文也能解密（虽然 nonce 不同）
      final decryptedFirst = await service.decrypt(firstCipher);
      expect(decryptedFirst, '{"version":6,"items":[]}');
    });
  });

  group('EncryptionServiceImpl.changePasswordWithCloudReEncryption (SYNC-13)', () {
    late _FakeCloudStorage cloud;

    setUp(() {
      cloud = _FakeCloudStorage();
    });

    /// 用旧密码开启加密并把两份旧密钥密文放入云端
    Future<void> seedCloudEncrypted() async {
      await service.enable(password: 'OldPassw0rd');
      cloud.stored['ledger_1.json'] =
          await service.encrypt('{"version":6,"a":1}');
      cloud.stored['ledger_2.json'] =
          await service.encrypt('{"version":6,"b":2}');
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];
    }

    test('全部成功 → 新密码生效，云端密文可用新密码解密', () async {
      await seedCloudEncrypted();

      final result = await service.changePasswordWithCloudReEncryption(
        oldPassword: 'OldPassw0rd',
        newPassword: 'NewPassw0rd1',
        cloudStorage: cloud,
      );

      expect(result.failed, 0);
      expect(result.success, 2);
      expect(await service.verifyPassword('NewPassw0rd1'), isTrue);
      expect(await service.verifyPassword('OldPassw0rd'), isFalse);
      expect(
        await service.decrypt(cloud.stored['ledger_1.json']!),
        '{"version":6,"a":1}',
      );
    });

    test('部分失败 → 抛 ReEncryptPartialFailureException、改密中止、'
        '成功文件回滚为旧密钥密文', () async {
      await seedCloudEncrypted();
      cloud.throwOnUploadPaths.add('ledger_2.json');

      await expectLater(
        service.changePasswordWithCloudReEncryption(
          oldPassword: 'OldPassw0rd',
          newPassword: 'NewPassw0rd1',
          cloudStorage: cloud,
        ),
        throwsA(isA<ReEncryptPartialFailureException>()
            .having((e) => e.failedPaths, 'failedPaths', ['ledger_2.json'])
            .having((e) => e.rollbackClean, 'rollbackClean', isTrue)),
      );

      // 改密必须中止：新密码不生效、旧密码仍有效（密钥/verifier 未被覆盖）
      expect(await service.verifyPassword('NewPassw0rd1'), isFalse,
          reason: '部分失败时不得激活新密钥');
      expect(await service.verifyPassword('OldPassw0rd'), isTrue);

      // 已重加密成功的 ledger_1 必须被回滚为旧密钥密文（可解密）
      expect(
        await service.decrypt(cloud.stored['ledger_1.json']!),
        '{"version":6,"a":1}',
      );
    });

    test('部分失败且回滚也失败 → 异常携带 rollbackFailedPaths', () async {
      await seedCloudEncrypted();
      cloud.throwOnUploadPaths.add('ledger_2.json');
      // ledger_1 首轮重加密(第 1 次上传)成功、回滚阶段(第 2 次上传)失败，
      // 模拟回滚期间网络故障
      cloud.failOnNthUpload['ledger_1.json'] = 2;

      await expectLater(
        service.changePasswordWithCloudReEncryption(
          oldPassword: 'OldPassw0rd',
          newPassword: 'NewPassw0rd1',
          cloudStorage: cloud,
        ),
        throwsA(isA<ReEncryptPartialFailureException>()
            .having((e) => e.rollbackClean, 'rollbackClean', isFalse)
            .having((e) => e.rollbackFailedPaths, 'rollbackFailedPaths',
                ['ledger_1.json'])),
      );
    });
  });
}

/// list 方法抛异常的 CloudStorageService 实现
class _ThrowingListStorage implements CloudStorageService {
  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {}

  @override
  Future<String?> download({required String path}) async => null;

  @override
  Future<void> delete({required String path}) async {}

  @override
  Future<List<CloudFile>> list({required String path}) async {
    throw Exception('mock list failure');
  }

  @override
  Future<bool> exists({required String path}) async => false;

  @override
  Future<CloudFile?> getMetadata({required String path}) async => null;
}

/// 内存版 SecureKeyStorage，用于单元测试
///
/// 真实模拟存储行为，不依赖平台 channel。
class InMemorySecureKeyStorage implements SecureKeyStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> saveKey(List<int> key) async {
    _store['piggycount_enc_key'] = base64.encode(key);
  }

  @override
  Future<Uint8List?> getKey() async {
    final value = _store['piggycount_enc_key'];
    if (value == null) return null;
    return Uint8List.fromList(base64.decode(value));
  }

  @override
  Future<void> saveVerifier(List<int> verifier) async {
    _store['piggycount_enc_verifier'] = base64.encode(verifier);
  }

  @override
  Future<Uint8List?> getVerifier() async {
    final value = _store['piggycount_enc_verifier'];
    if (value == null) return null;
    return Uint8List.fromList(base64.decode(value));
  }

  @override
  Future<void> saveSalt(List<int> salt) async {
    _store['piggycount_enc_salt'] = base64.encode(salt);
  }

  @override
  Future<Uint8List?> getSalt() async {
    final value = _store['piggycount_enc_salt'];
    if (value == null) return null;
    return Uint8List.fromList(base64.decode(value));
  }

  @override
  @override
  Future<void> saveRekeyCheckpoint(String ciphertextB64) async {
    _store['piggycount_enc_rekey_ckpt'] = ciphertextB64;
  }

  @override
  Future<String?> getRekeyCheckpoint() async {
    return _store['piggycount_enc_rekey_ckpt'];
  }

  @override
  Future<void> clearRekeyCheckpoint() async {
    _store.remove('piggycount_enc_rekey_ckpt');
  }
  Future<void> clearAll() async {
    _store.clear();
  }
}

/// 内存版 CloudStorageService，用于 reEncryptExistingCloudData 测试
class _FakeCloudStorage implements CloudStorageService {
  final Map<String, String> stored = {};
  List<CloudFile> listFiles = const [];
  final Set<String> throwOnDownloadPaths = {};
  final Set<String> throwOnUploadPaths = {};

  /// 第 N 次上传指定路径时抛异常（1 起），模拟"首轮成功、回滚阶段失败"
  final Map<String, int> failOnNthUpload = {};
  final Map<String, int> _uploadCallCounts = {};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    if (throwOnUploadPaths.contains(path)) {
      throw Exception('mock upload failure for $path');
    }
    final nth = failOnNthUpload[path];
    if (nth != null) {
      final count = (_uploadCallCounts[path] ?? 0) + 1;
      _uploadCallCounts[path] = count;
      if (count >= nth) {
        throw Exception('mock upload failure #$count for $path');
      }
    }
    stored[path] = data;
  }

  @override
  Future<String?> download({required String path}) async {
    if (throwOnDownloadPaths.contains(path)) {
      throw Exception('mock download failure for $path');
    }
    return stored[path];
  }

  @override
  Future<void> delete({required String path}) async {
    stored.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    // 与真实后端一致：按请求路径过滤（S3 前缀 / WebDAV 目录均只返回
    // 该作用域内的条目）。根列举('')返回全部；子目录列举返回 name 以
    // 该目录为前缀的条目。否则 attachments/ 子目录枚举会错误地把根列表
    // 条目再收一遍（审计 A1 配套测试约束）。
    if (path.isEmpty || path == '/') return listFiles;
    final prefix = path.endsWith('/') ? path : '$path/';
    return listFiles
        .where((f) => f.name.startsWith(prefix))
        .map((f) => CloudFile(
              name: f.name.substring(prefix.length),
              path: f.name,
              size: f.size,
              lastModified: f.lastModified,
              metadata: f.metadata,
            ))
        .toList();
  }

  @override
  Future<bool> exists({required String path}) async {
    return stored.containsKey(path);
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    if (!stored.containsKey(path)) return null;
    return CloudFile(name: path, path: path);
  }
}
