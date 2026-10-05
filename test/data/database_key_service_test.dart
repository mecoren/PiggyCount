/// 整库加密密钥层契约（`prd/sqlcipher_db_encryption/requirements.md` R2/R5）：
/// - 密钥是 32B 随机数的 64 位小写 hex；
/// - **不自动创建**（明文库上凭空建钥会把"假加密"变成默认）；
/// - 存量值损坏 → 视为"没有密钥"，交给 R5 引导，而不是拿废钥开库。
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/encryption/database_key_service.dart';

void main() {
  const service = DatabaseKeyService();

  setUp(() => DatabaseKeyService.testSecureStore = <String, String>{});
  tearDown(() => DatabaseKeyService.testSecureStore = null);

  group('密钥生成', () {
    test('32B 随机 → 64 位小写 hex，且两次不同', () {
      final a = DatabaseKeyService.generateHexKey();
      final b = DatabaseKeyService.generateHexKey();
      expect(a.length, 64);
      expect(DatabaseKeyService.isValidKey(a), isTrue);
      expect(a, isNot(b), reason: '每次生成必须是新随机值');
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('isValidKey 只认 64 位小写 hex', () {
      expect(DatabaseKeyService.isValidKey('a' * 64), isTrue);
      expect(DatabaseKeyService.isValidKey('A' * 64), isFalse,
          reason: '大写不算（与 toRadixString(16) 的产出保持一致）');
      expect(DatabaseKeyService.isValidKey('a' * 63), isFalse);
      expect(DatabaseKeyService.isValidKey('a' * 65), isFalse);
      expect(DatabaseKeyService.isValidKey(''), isFalse);
      expect(DatabaseKeyService.isValidKey('g' * 64), isFalse);
    });

    test('注入 Random 时结果可复现（便于排障，不代表生产用弱随机）', () {
      final k1 = DatabaseKeyService.generateHexKey(Random(42));
      final k2 = DatabaseKeyService.generateHexKey(Random(42));
      expect(k1, k2);
      expect(DatabaseKeyService.isValidKey(k1), isTrue);
    });
  });

  group('存取与生命周期', () {
    test('未启用时不自动创建', () async {
      expect(await service.loadKey(), isNull);
      // 关键负向断言：读一次不能把密钥"读"出来
      expect(DatabaseKeyService.testSecureStore, isEmpty);
    });

    test('createKey → loadKey 往返一致；deleteKey 后为 null', () async {
      final created = await service.createKey();
      expect(DatabaseKeyService.isValidKey(created), isTrue);
      expect(await service.loadKey(), created);

      await service.deleteKey();
      expect(await service.loadKey(), isNull);
    });

    test('存量值损坏（被截断）→ 视为无密钥，而不是抛异常', () async {
      DatabaseKeyService.testSecureStore![DatabaseKeyService.storageKey] = 'deadbeef';
      expect(await service.loadKey(), isNull,
          reason: '拿废密钥去开库只会得到 file is not a database，'
              '把"密钥坏了"误报成"库坏了"');
    });
  });
}
