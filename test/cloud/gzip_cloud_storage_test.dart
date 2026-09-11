/// P2-2③（性能批次）：gzip 压缩装饰器回归。
///
/// - 往返：大 JSON upload → download 与原文恒等（压缩路径全通）；
/// - 嗅探三态：gzip 魔数解压 / BEECRYPT1 密文透传 / 旧明文 JSON 原样；
/// - 阈值：小对象（<2KB）不压缩；高熵内容压缩比超限存原文；
/// - 能力接口：BinaryCapableStorage / ConditionalWriteStorage 按 inner
///   如实镜像（附件真字节路径不退化、条件写锚点不解绑）；
/// - raw 语义：rekey/enableFromCloud 用 rawStorage（无本装饰器）——
///   由装配链测试覆盖（本文件验证装饰器自身行为）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/cloud/gzip_cloud_storage.dart';

/// 内存假存储：记录 upload 的原始形态，download 回放存储内容。
class _MemStorage implements CloudStorageService, BinaryCapableStorage, ConditionalWriteStorage {
  final map = <String, String>{};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    map[path] = data;
  }

  @override
  Future<String?> download({required String path}) async => map[path];

  @override
  Future<void> delete({required String path}) async {
    map.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async => const [];

  @override
  Future<bool> exists({required String path}) async => map.containsKey(path);

  @override
  Future<CloudFile?> getMetadata({required String path}) async => null;

  // ---- Binary 能力：gzip 层应镜像透传到本实现 ----
  final binMap = <String, Uint8List>{};

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    binMap[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async =>
      binMap[path];

  @override
  bool get supportsConditionalWrite => true;

  final conditionalCalls = <({String path, String? ifMatch, bool ifNoneMatch})>[];

  @override
  Future<void> uploadBinaryConditional({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
    String? ifMatchEtag,
    bool ifNoneMatch = false,
  }) async {
    conditionalCalls.add((
      path: path,
      ifMatch: ifMatchEtag,
      ifNoneMatch: ifNoneMatch,
    ));
  }
}

/// 无任何能力接口的裸存储：gzip 层的能力镜像按「不支持」如实申报。
class _BareStorage implements CloudStorageService {
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
  Future<List<CloudFile>> list({required String path}) async => const [];

  @override
  Future<bool> exists({required String path}) async => false;

  @override
  Future<CloudFile?> getMetadata({required String path}) async => null;
}

void main() {
  group('P2-2③: 往返与压缩', () {
    test('大 JSON 上传被压缩、下载还原与原文恒等', () async {
      final mem = _MemStorage();
      final svc = GzipCloudStorageService(inner: mem);
      // 高度重复的 JSON（真实账本快照形态：键名/结构大量重复）
      final items = List.generate(
          200, (i) => '{"amount":$i,"note":"买咖啡日常消费备注","categoryName":"餐饮"}');
      final payload = '{"items":[${items.join(',')}],"count":200}';

      await svc.upload(path: 'ledger_1.json', data: payload);
      final stored = mem.map['ledger_1.json']!;
      // 实现侧 Latin-1 桥：String 码点 = 存储字节
      final storedBytes = Uint8List.fromList(stored.codeUnits);

      // 存储层确实是 gzip（魔数 1f 8b 08）
      expect(storedBytes[0], 0x1f);
      expect(storedBytes[1], 0x8b);
      expect(storedBytes[2], 0x08);
      // 压缩有实质收益（重复 JSON 应显著小于原文）
      expect(storedBytes.length, lessThan(payload.length * 0.6));

      final back = await svc.download(path: 'ledger_1.json');
      expect(back, payload);
    });

    test('小对象（<2KB）不压缩，原样落盘', () async {
      final mem = _MemStorage();
      final svc = GzipCloudStorageService(inner: mem);
      const payload = '{"count":1}';

      await svc.upload(path: 'ledger_1.json', data: payload);

      expect(mem.map['ledger_1.json'], payload);
    });

    test('高熵内容压缩比超限（>60%）→ 存原文', () async {
      final mem = _MemStorage();
      final svc = GzipCloudStorageService(inner: mem);
      // 高熵随机数据（模拟已加密/随机内容）：gzip 几乎不可压
      final random = List<int>.generate(4096, (i) => (i * 2654435761) >>> 24);
      final payload = String.fromCharCodes(random);

      await svc.upload(path: 'blob.bin.txt', data: payload);

      // 压缩无收益时原文落盘（嗅探端无需处理）
      expect(mem.map['blob.bin.txt'], payload);
    });

    test('BEECRYPT1 密文信封透传（防御：本层在加密层之下不重复处理）',
        () async {
      final mem = _MemStorage();
      final svc = GzipCloudStorageService(inner: mem);
      const ciphertext = 'BEECRYPT1:YWJjZA==:eHl6';

      await svc.upload(path: 'ledger_1.json', data: ciphertext);

      expect(mem.map['ledger_1.json'], ciphertext);
    });
  });

  group('P2-2③: 嗅探三态（download 兼容契约）', () {
    test('旧明文 JSON（非 gzip）原样返回', () async {
      final mem = _MemStorage();
      final svc = GzipCloudStorageService(inner: mem);
      const legacy = '{"version":8,"count":10}';
      mem.map['ledger_1.json'] = legacy;

      expect(await svc.download(path: 'ledger_1.json'), legacy);
    });

    test('rekey 直写的未压缩密文原样透传', () async {
      final mem = _MemStorage();
      final svc = GzipCloudStorageService(inner: mem);
      const rawCiphertext = 'BEECRYPT1:bmV3c2FsdA==:c2VjcmV0';
      mem.map['ledger_1.json'] = rawCiphertext;

      expect(await svc.download(path: 'ledger_1.json'), rawCiphertext);
    });

    test('gzip 魔数但解压失败 → 抛 CloudStorageException（损坏数据硬失败）',
        () async {
      final mem = _MemStorage();
      final svc = GzipCloudStorageService(inner: mem);
      // 魔数合法、后续是垃圾：Latin-1 桥形态（码点=字节）塞入假存储
      final broken = String.fromCharCodes(
          [0x1f, 0x8b, 0x08, 0x00, 0xff, 0xfe, 0x00, 0x01]);
      mem.map['ledger_1.json'] = broken;

      await expectLater(
        svc.download(path: 'ledger_1.json'),
        throwsA(isA<CloudStorageException>()),
      );
    });

    test('历史遗留：外部工具写的合法 gzip 可解压', () async {
      final mem = _MemStorage();
      final svc = GzipCloudStorageService(inner: mem);
      const payload = '{"external":"tool","count":5}';
      // Latin-1 桥形态（码点=字节），与实现侧 _bytesToText 一致
      final gz = String.fromCharCodes(GZipEncoder().encode(utf8.encode(payload))!);
      mem.map['ledger_1.json'] = gz;

      expect(await svc.download(path: 'ledger_1.json'), payload);
    });
  });

  group('P2-2③: 能力接口镜像透传', () {
    test('BinaryCapableStorage 透传 —— 附件真字节路径不退化 base64',
        () async {
      final mem = _MemStorage();
      final svc = GzipCloudStorageService(inner: mem);
      final bytes = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04]);

      await (svc as BinaryCapableStorage)
          .uploadBinary(path: 'attachments/abc.bin', bytes: bytes);

      expect(mem.binMap['attachments/abc.bin'], bytes);
      expect(await (svc as BinaryCapableStorage)
          .downloadBinary(path: 'attachments/abc.bin'), bytes);
    });

    test('ConditionalWriteStorage 按能力解析：inner 支持则透传条件头',
        () async {
      final mem = _MemStorage();
      final svc = GzipCloudStorageService(inner: mem);

      // conditionalOrNull 解析（同 manager 的判定路径）
      final conditional = (svc as CloudStorageService).conditionalOrNull;
      expect(conditional, isNotNull,
          reason: 'inner 支持 S3 条件写时 gzip 层不得解绑锚点');
      expect(svc.supportsConditionalWrite, isTrue);

      await conditional!.uploadBinaryConditional(
        path: 'ledger_1.json',
        bytes: [1],
        ifMatchEtag: 'etag-1',
      );
      expect(mem.conditionalCalls.single.ifMatch, 'etag-1');
    });

    test('inner 无条件写能力 → 如实申报不支持（manager 走写后校验兜底）',
        () async {
      final svc = GzipCloudStorageService(inner: _BareStorage());

      expect((svc as CloudStorageService).conditionalOrNull, isNull);
      expect(svc.supportsConditionalWrite, isFalse);
    });

    test('互斥参数校验透传（ifMatchEtag 与 ifNoneMatch）', () async {
      final svc = GzipCloudStorageService(inner: _BareStorage());
      await expectLater(
        svc.uploadBinaryConditional(
          path: 'a',
          bytes: [1],
          ifMatchEtag: 'e',
          ifNoneMatch: true,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
