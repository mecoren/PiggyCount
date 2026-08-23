// EncryptionServiceImpl.enableFromCloud 多设备加入流程单元测试
//
// 锁死多设备加入契约（设计文档 /prd/encryption/multi_device_join_design.md）：
// - TC-M1: 云端无文件 → 回退到 enable，生成新 salt
// - TC-M2: 云端只有 legacy 明文 → 回退到 enable
// - TC-M3: 云端有 BEECRYPT1 密文 + 正确密码 → 提取 salt 加入成功
// - TC-M4: 云端有 BEECRYPT1 密文 + 错误密码 → 抛 ArgumentError，不写 secure storage
// - TC-M5: 加入后能解密云端所有同 salt 密文
// - TC-M6: 加入后 verifier 可通过 verifyPassword 验证
// - TC-M7: list 抛异常 → 抛 EnableFromCloudProbeFailedException（US-3 探测失败不自动回退）
// - TC-M8: list 成功但 download 抛异常 → 透传异常
//
// 多设备模拟方式：
// - deviceA: EncryptionServiceImpl + InMemorySecureKeyStorage_A
// - deviceB: EncryptionServiceImpl + InMemorySecureKeyStorage_B（独立实例，模拟新设备）
// - cloud: FakeCloudStorageService（A 上传密文，B 从中提取 salt）

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/encryption/aes_gcm_cipher.dart';
import 'package:piggycount/data/encryption/argon2_key_derivation.dart';
import 'package:piggycount/data/encryption/encryption_service_impl.dart';
import 'package:piggycount/data/encryption/secure_key_storage.dart';
import 'package:piggycount/domain/encryption/encryption_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemorySecureKeyStorage deviceAStorage;
  late EncryptionServiceImpl deviceA;
  late InMemorySecureKeyStorage deviceBStorage;
  late EncryptionServiceImpl deviceB;
  late FakeCloudStorageService cloud;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    deviceAStorage = InMemorySecureKeyStorage();
    deviceA = EncryptionServiceImpl(
      storage: deviceAStorage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );
    deviceBStorage = InMemorySecureKeyStorage();
    deviceB = EncryptionServiceImpl(
      storage: deviceBStorage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );
    cloud = FakeCloudStorageService();
  });

  /// 构造一个标准的设备 A 加密上传场景：
  /// deviceA enable(password) → 加密 ledger_1.json → 上传到 cloud
  Future<void> _simulateDeviceAUpload({
    required String password,
    String ledgerContent = '{"version":6,"items":[{"amount":99.9}]}',
    String ledgerPath = 'ledger_1.json',
  }) async {
    await deviceA.enable(password: password);
    final encrypted = await deviceA.encrypt(ledgerContent);
    cloud.stored[ledgerPath] = encrypted;
    cloud.listFiles = cloud.stored.keys
        .map((name) => CloudFile(name: name, path: name))
        .toList();
  }

  group('TC-M1: 首设备场景 - 云端无文件', () {
    test('enableFromCloud 回退到 enable，生成新 salt，enabled=true', () async {
      // 云端无任何文件
      cloud.listFiles = const [];

      await deviceB.enableFromCloud(
        password: 'MyPassw0rd',
        cloudStorage: cloud,
      );

      expect(await deviceB.isEnabled, isTrue);
      expect(await deviceBStorage.getKey(), isNotNull);
      expect(await deviceBStorage.getSalt(), isNotNull);
      expect(await deviceBStorage.getVerifier(), isNotNull);
      expect(deviceB.activeSalt, isNotNull);
      expect(deviceB.activeSalt!.length, 16);
    });

    test('allowFallbackToEnable=false 且云端无密文 → 抛探测失败异常，不写 secure storage',
        () async {
      // salt_mismatch 恢复场景：调用方已确认云端存在密文，
      // 禁止回退 enable 生成新 salt（否则本地 salt 与云端永远不匹配）。
      cloud.listFiles = const [];

      expect(
        () => deviceB.enableFromCloud(
          password: 'MyPassw0rd',
          cloudStorage: cloud,
          allowFallbackToEnable: false,
        ),
        throwsA(isA<EnableFromCloudProbeFailedException>()),
      );

      // 不应写入任何密钥（未被污染）
      expect(await deviceB.isEnabled, isFalse);
      expect(await deviceBStorage.getKey(), isNull);
      expect(await deviceBStorage.getSalt(), isNull);
      expect(await deviceBStorage.getVerifier(), isNull);
      expect(deviceB.activeSalt, isNull);
    });

    test('allowFallbackToEnable=false 且云端仅 legacy 明文 → 抛探测失败异常，不污染本地',
        () async {
      cloud.stored['ledger_1.json'] = '{"version":5,"items":[]}';
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
      ];

      expect(
        () => deviceB.enableFromCloud(
          password: 'MyPassw0rd',
          cloudStorage: cloud,
          allowFallbackToEnable: false,
        ),
        throwsA(isA<EnableFromCloudProbeFailedException>()),
      );

      expect(await deviceB.isEnabled, isFalse);
      expect(await deviceBStorage.getKey(), isNull);
      expect(deviceB.activeSalt, isNull);
    });
  });

  group('TC-M2: 首设备场景 - 云端只有 legacy 明文', () {
    test('enableFromCloud 回退到 enable', () async {
      // 云端只有 legacy 明文（无 BEECRYPT1 前缀）
      cloud.stored['ledger_1.json'] = '{"version":5,"items":[]}';
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
      ];

      await deviceB.enableFromCloud(
        password: 'MyPassw0rd',
        cloudStorage: cloud,
      );

      expect(await deviceB.isEnabled, isTrue);
      expect(await deviceBStorage.getKey(), isNotNull);
      // 回退到 enable 应生成新 salt（非从云端提取，因云端无密文）
      expect(deviceB.activeSalt, isNotNull);
    });
  });

  group('TC-M3: 新设备加入 - 云端有 BEECRYPT1 密文 + 正确密码', () {
    test('提取 salt，派生 key，验证通过，secure storage 写入，enabled=true', () async {
      // 1. 设备 A 加密上传
      await _simulateDeviceAUpload(password: 'SharedPass7');

      // 2. 设备 B 加入（使用相同密码）
      await deviceB.enableFromCloud(
        password: 'SharedPass7',
        cloudStorage: cloud,
      );

      // 3. 验证 deviceB 状态
      expect(await deviceB.isEnabled, isTrue);
      expect(await deviceB.hasActiveKey, isTrue);
      expect(await deviceBStorage.getKey(), isNotNull);
      expect(await deviceBStorage.getSalt(), isNotNull);
      expect(await deviceBStorage.getVerifier(), isNotNull);

      // 4. 关键：deviceB 的 salt 应与 deviceA 一致（从云端密文头提取）
      expect(deviceB.activeSalt, isNotNull);
      expect(
        _listEquals(deviceB.activeSalt!, deviceA.activeSalt!),
        isTrue,
        reason: 'deviceB 的 salt 应从云端密文头提取，与 deviceA 一致',
      );
    });

    test('deviceB 的 key 应与 deviceA 一致（同密码 + 同 salt 派生）', () async {
      await _simulateDeviceAUpload(password: 'SharedPass7');

      await deviceB.enableFromCloud(
        password: 'SharedPass7',
        cloudStorage: cloud,
      );

      final keyA = await deviceAStorage.getKey();
      final keyB = await deviceBStorage.getKey();
      expect(keyA, isNotNull);
      expect(keyB, isNotNull);
      expect(_listEquals(keyA!, keyB!), isTrue);
    });
  });

  group('TC-M4: 新设备加入 - 错误密码', () {
    test('抛 ArgumentError，secure storage 未写入', () async {
      // 设备 A 用 'CorrectPass1' 加密
      await _simulateDeviceAUpload(password: 'CorrectPass1');

      // 设备 B 用错误密码加入
      expect(
        () => deviceB.enableFromCloud(
          password: 'WrongPass9',
          cloudStorage: cloud,
        ),
        throwsA(isA<ArgumentError>()),
      );

      // secure storage 不应被写入
      expect(await deviceBStorage.getKey(), isNull);
      expect(await deviceBStorage.getSalt(), isNull);
      expect(await deviceBStorage.getVerifier(), isNull);
      expect(deviceB.activeSalt, isNull);
    });
  });

  group('TC-M5: 加入后能解密云端所有同 salt 密文', () {
    test('deviceB 加入后可解密 deviceA 上传的多个密文', () async {
      // 1. 设备 A 加密上传多个账本
      await deviceA.enable(password: 'SharedPass7');
      const content1 = '{"version":6,"items":[{"amount":100}]}';
      const content2 = '{"version":6,"items":[{"amount":200}]}';
      cloud.stored['ledger_1.json'] = await deviceA.encrypt(content1);
      cloud.stored['ledger_2.json'] = await deviceA.encrypt(content2);
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      // 2. 设备 B 加入
      await deviceB.enableFromCloud(
        password: 'SharedPass7',
        cloudStorage: cloud,
      );

      // 3. 设备 B 应能解密所有密文
      final raw1 = cloud.stored['ledger_1.json']!;
      final raw2 = cloud.stored['ledger_2.json']!;
      expect(await deviceB.decrypt(raw1), content1);
      expect(await deviceB.decrypt(raw2), content2);
    });
  });

  group('TC-M3b: 混合 salt 场景 - 云端存在旧/新密码各自加密的密文', () {
    test('输入新密码（正确）→ 遍历所有密文，用新 salt 密文验证成功激活', () async {
      // 场景还原：A 设备改密后云端存在混合 salt
      // - ledger_1.json：旧密码（oldpassword）加密（改密时重加密失败遗留）
      // - ledger_2.json：新密码（newpassword）加密（改密时重加密成功）
      // 用户在新设备 B 输入新密码（正确），即使第一个密文是旧 salt，
      // enableFromCloud 也应遍历到新 salt 密文验证通过，而非误报密码错误。
      final oldDevice = EncryptionServiceImpl(
        storage: InMemorySecureKeyStorage(),
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      await oldDevice.enable(password: 'OldPassw0rd');
      cloud.stored['ledger_1.json'] = await oldDevice.encrypt(
          '{"version":6,"items":[{"amount":10}]}');

      final newDevice = EncryptionServiceImpl(
        storage: InMemorySecureKeyStorage(),
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      await newDevice.enable(password: 'NewPassw0rd1');
      cloud.stored['ledger_2.json'] = await newDevice.encrypt(
          '{"version":6,"items":[{"amount":20}]}');

      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      // 设备 B 输入新密码（正确）
      await deviceB.enableFromCloud(
        password: 'NewPassw0rd1',
        cloudStorage: cloud,
      );

      // 激活成功：salt 取自新 salt 密文（与 newDevice 一致）
      expect(await deviceB.isEnabled, isTrue);
      expect(await deviceBStorage.getKey(), isNotNull);
      expect(deviceB.activeSalt, isNotNull);
      expect(
        _listEquals(deviceB.activeSalt!, newDevice.activeSalt!),
        isTrue,
        reason: 'B 的 salt 应取自新密码加密的密文（与 newDevice 一致）',
      );
      // B 能解密新 salt 密文
      expect(
        await deviceB.decrypt(cloud.stored['ledger_2.json']!),
        '{"version":6,"items":[{"amount":20}]}',
      );
    });

    test('输入旧密码（另一正确密码）→ 用旧 salt 密文验证成功激活', () async {
      final oldDevice = EncryptionServiceImpl(
        storage: InMemorySecureKeyStorage(),
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      await oldDevice.enable(password: 'OldPassw0rd');
      cloud.stored['ledger_1.json'] = await oldDevice.encrypt(
          '{"version":6,"items":[{"amount":10}]}');

      final newDevice = EncryptionServiceImpl(
        storage: InMemorySecureKeyStorage(),
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      await newDevice.enable(password: 'NewPassw0rd1');
      cloud.stored['ledger_2.json'] = await newDevice.encrypt(
          '{"version":6,"items":[{"amount":20}]}');
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      // 输入旧密码：遍历到 ledger_1.json（旧 salt）验证通过
      await deviceB.enableFromCloud(
        password: 'OldPassw0rd',
        cloudStorage: cloud,
      );

      expect(await deviceB.isEnabled, isTrue);
      expect(
        _listEquals(deviceB.activeSalt!, oldDevice.activeSalt!),
        isTrue,
        reason: 'B 的 salt 应取自旧密码加密的密文（与 oldDevice 一致）',
      );
    });

    test('所有密文都无法用输入密码解密 → 抛 ArgumentError，不写 secure storage', () async {
      // 两个密文都是别的密码加密，用户输入完全错误的密码
      final oldDevice = EncryptionServiceImpl(
        storage: InMemorySecureKeyStorage(),
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      await oldDevice.enable(password: 'LegacyPass1');
      cloud.stored['ledger_1.json'] = await oldDevice.encrypt(
          '{"version":6,"items":[{"amount":10}]}');

      final newDevice = EncryptionServiceImpl(
        storage: InMemorySecureKeyStorage(),
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      await newDevice.enable(password: 'LegacyPass2');
      cloud.stored['ledger_2.json'] = await newDevice.encrypt(
          '{"version":6,"items":[{"amount":20}]}');
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      expect(
        () => deviceB.enableFromCloud(
          password: 'TotallyWrong1',
          cloudStorage: cloud,
        ),
        throwsA(isA<ArgumentError>()),
      );

      expect(await deviceBStorage.getKey(), isNull);
      expect(await deviceBStorage.getSalt(), isNull);
      expect(deviceB.activeSalt, isNull);
    });

    test('混合密文中有一个格式损坏 + 一个新 salt 密文 → 仍能激活（跳过损坏密文）', () async {
      // 第一个密文是损坏的（非合法 BEECRYPT1 结构），第二个是新 salt 密文。
      // enableFromCloud 应跳过损坏密文，用新 salt 密文验证成功。
      cloud.stored['ledger_1.json'] = 'BEECRYPT1:brokenbase64!!!:notvalid';
      final newDevice = EncryptionServiceImpl(
        storage: InMemorySecureKeyStorage(),
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      await newDevice.enable(password: 'NewPassw0rd1');
      cloud.stored['ledger_2.json'] = await newDevice.encrypt(
          '{"version":6,"items":[{"amount":20}]}');
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      await deviceB.enableFromCloud(
        password: 'NewPassw0rd1',
        cloudStorage: cloud,
      );

      expect(await deviceB.isEnabled, isTrue);
      expect(
        _listEquals(deviceB.activeSalt!, newDevice.activeSalt!),
        isTrue,
      );
    });

    test('密文格式非法（无法通过 isEncrypted 识别）→ 视为无密文，恢复模式禁止回退时抛探测失败',
        () async {
      // 'BEECRYPT1:brokenbase64!!!:notvalid' 的 base64 非法，
      // isEncrypted 判定为非密文 → 被跳过 → candidates 为空 → 走"无密文"分支。
      // salt_mismatch 恢复场景（allowFallbackToEnable=false）抛探测失败异常。
      cloud.stored['ledger_1.json'] = 'BEECRYPT1:brokenbase64!!!:notvalid';
      cloud.stored['ledger_2.json'] = 'BEECRYPT1:also:broken';
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      expect(
        () => deviceB.enableFromCloud(
          password: 'MyPassw0rd',
          cloudStorage: cloud,
          allowFallbackToEnable: false,
        ),
        throwsA(isA<EnableFromCloudProbeFailedException>()),
      );

      expect(await deviceBStorage.getKey(), isNull);
    });
  });

  group('TC-M6: 加入后 verifier 可通过 verifyPassword 验证', () {
    test('verifyPassword 正确密码返回 true', () async {
      await _simulateDeviceAUpload(password: 'SharedPass7');

      await deviceB.enableFromCloud(
        password: 'SharedPass7',
        cloudStorage: cloud,
      );

      expect(await deviceB.verifyPassword('SharedPass7'), isTrue);
    });

    test('verifyPassword 错误密码返回 false', () async {
      await _simulateDeviceAUpload(password: 'SharedPass7');

      await deviceB.enableFromCloud(
        password: 'SharedPass7',
        cloudStorage: cloud,
      );

      expect(await deviceB.verifyPassword('WrongPass9'), isFalse);
    });
  });

  group('TC-M7: list 抛异常 - 抛 EnableFromCloudProbeFailedException（US-3）', () {
    test('list 抛异常 → enableFromCloud 抛 EnableFromCloudProbeFailedException，不自动回退 enable',
        () async {
      cloud.throwOnList = true;

      // US-3: 探测失败不应静默回退 enable()，否则会生成新 salt 并 reEncrypt
      // 全量云端数据，孤立其他持有旧 salt 的设备。
      // 应抛异常让 UI 引导用户确认是否以首设备身份继续。
      expect(
        () => deviceB.enableFromCloud(
          password: 'MyPassw0rd',
          cloudStorage: cloud,
        ),
        throwsA(isA<EnableFromCloudProbeFailedException>()),
      );

      // 不应写入 secure storage（未开启加密）
      expect(await deviceB.isEnabled, isFalse);
      expect(await deviceBStorage.getKey(), isNull);
      expect(await deviceBStorage.getSalt(), isNull);
      expect(deviceB.activeSalt, isNull);
    });
  });

  group('TC-M8: list 成功但 download 抛异常 - 透传异常', () {
    test('download 抛异常 → enableFromCloud 透传', () async {
      // 云端有文件但 download 抛异常
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
      ];
      cloud.throwOnDownload = true;

      expect(
        () => deviceB.enableFromCloud(
          password: 'MyPassw0rd',
          cloudStorage: cloud,
        ),
        throwsA(isA<Exception>()),
      );

      // 不应写入 secure storage
      expect(await deviceBStorage.getKey(), isNull);
      expect(await deviceBStorage.getSalt(), isNull);
    });
  });

  group('enableFromCloud 边界', () {
    test('密码为空抛 ArgumentError', () async {
      expect(
        () => deviceB.enableFromCloud(
          password: '',
          cloudStorage: cloud,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('密码过短（< 6 字符）抛 ArgumentError', () async {
      expect(
        () => deviceB.enableFromCloud(
          password: '12345',
          cloudStorage: cloud,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('云端有密文但不是 ledger_*.json（如 readme.txt）→ 跳过，回退到 enable', () async {
      // 设备 A 加密一个非 ledger 文件
      await deviceA.enable(password: 'MyPassw0rd');
      cloud.stored['readme.txt'] = await deviceA.encrypt('some content');
      cloud.listFiles = [
        CloudFile(name: 'readme.txt', path: 'readme.txt'),
      ];

      await deviceB.enableFromCloud(
        password: 'MyPassw0rd',
        cloudStorage: cloud,
      );

      // 因未找到 ledger_*.json 密文 → 回退到 enable
      expect(await deviceB.isEnabled, isTrue);
    });
  });
}

/// 列表逐元素比较（List<int> 等值）
bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 内存版 CloudStorageService，用于多设备测试
class FakeCloudStorageService implements CloudStorageService {
  /// 模拟云端存储的文件（path → content）
  final Map<String, String> stored = {};

  /// list 返回的文件列表
  List<CloudFile> listFiles = const [];

  /// 控制 list 是否抛异常（模拟网络失败）
  bool throwOnList = false;

  /// 控制 download 是否抛异常（模拟网络失败）
  bool throwOnDownload = false;

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    stored[path] = data;
  }

  @override
  Future<String?> download({required String path}) async {
    if (throwOnDownload) {
      throw Exception('download failed: $path');
    }
    return stored[path];
  }

  @override
  Future<void> delete({required String path}) async {
    stored.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    if (throwOnList) {
      throw Exception('list failed');
    }
    return listFiles;
  }

  @override
  Future<bool> exists({required String path}) async {
    return stored.containsKey(path);
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    if (stored.containsKey(path)) {
      return CloudFile(name: path, path: path, size: stored[path]!.length);
    }
    return null;
  }
}

/// 内存版 SecureKeyStorage，用于单元测试
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
  Future<void> clearAll() async {
    _store.clear();
  }
}
