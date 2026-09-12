/// 2026-09-11 归一化批次回归（对照 docs/sync-comprehensive-audit-2026-09-10.md）：
///
/// - P1-5：BinaryCapableStorage 实现 —— 旧实现缺席时
///   CloudStorageBinaryExt.uploadBinaryOrFallback 走 base64 文本兜底，
///   叠加 iCloud upload 的二次编码后磁盘对象是 base64 文本（+33% 体积）；
///   实现 uploadBinary/downloadBinary 后附件/ZIP 走单次编码 + 原始字节。
/// - P1-5 嗅探：downloadBinary 兼容「实现 Binary 之前落盘的 base64
///   文本对象」（解包内层字节），新格式（原始字节）原样返回。
/// - P1-8：幂等读重试 —— 瞬时故障（iCloud daemon 未就绪）2 次重试后
///   成功；「文件不存在」确定性错误不消耗重试预算。
///
/// 可编程假桩：逐调用序列注入异常/返回值，精确模拟「前两次失败第三次
/// 成功」的重试场景与旧格式内容。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_icloud/src/icloud_method_channel_contract.dart';
import 'package:flutter_cloud_sync_icloud/src/icloud_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptedChannel implements ICloudMethodChannelLike {
  /// 按序抛出的异常（尾部循环最后一个）；空 = 永不抛
  final List<Object?> downloadErrors;

  /// downloadFile 返回的 base64 内容（download 成功轮用）
  final String? downloadReturn;

  int downloadCalls = 0;
  int existsCalls = 0;

  _ScriptedChannel({
    this.downloadErrors = const [],
    this.downloadReturn,
  });

  @override
  Future<String?> downloadFile({required String path}) async {
    final idx = downloadCalls < downloadErrors.length
        ? downloadCalls
        : downloadErrors.length - 1;
    final err = downloadErrors.isEmpty ? null : downloadErrors[idx];
    downloadCalls++;
    if (err != null) throw err;
    return downloadReturn;
  }

  @override
  Future<bool> fileExists({required String path}) async {
    existsCalls++;
    return true;
  }

  @override
  Future<void> deleteFile({required String path}) async {}

  @override
  Future<Map<String, dynamic>?> getFileMetadata({required String path}) async {
    return null;
  }

  @override
  Future<List<Map<String, dynamic>>> listFiles({required String path}) async {
    return const [];
  }

  @override
  Future<void> uploadFile({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {}
}

void main() {
  group('P1-5: BinaryCapableStorage 能力分派', () {
    test('ICloudStorageService is BinaryCapableStorage —— '
        'uploadBinaryOrFallback 自动分派到真字节路径（不再 base64 文本兜底）',
        () {
      final svc = ICloudStorageService(_ScriptedChannel());
      expect(svc, isA<BinaryCapableStorage>());
    });

    test('downloadBinary 新格式（原始字节）：channel 返回字节串的 base64，'
        '原样解出（不再二次解包）', () async {
      // 磁盘上是新格式：真实二进制内容（ZIP 魔数开头，非合法 base64 文本）
      final raw = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF]);
      final svc = ICloudStorageService(_ScriptedChannel(
        downloadReturn: base64Encode(raw),
      ));
      final out = await svc.downloadBinary(path: 'attachments/x.bin');
      expect(out, raw);
    });

    test('downloadBinary 旧格式嗅探：磁盘是 base64 文本 → 解包内层字节',
        () async {
      // 旧兜底路径落盘：真实内容的 base64 文本
      final inner = Uint8List.fromList([1, 2, 3, 4, 5]);
      final legacyText = base64Encode(inner);
      final svc = ICloudStorageService(_ScriptedChannel(
        downloadReturn: base64Encode(utf8.encode(legacyText)),
      ));
      final out = await svc.downloadBinary(path: 'attachments/old.bin');
      expect(out, inner);
    });

    test('downloadBinary 404 → null（幂等语义）', () async {
      final svc = ICloudStorageService(_ScriptedChannel(
        downloadErrors: [PlatformException(code: 'NOT_FOUND')],
      ));
      expect(await svc.downloadBinary(path: 'a.bin'), isNull);
    });
  });

  group('P1-8: 幂等读重试', () {
    test('download 瞬时故障 2 次 → 第 3 次成功（对齐 WebDAV 2 次重试）',
        () async {
      final channel = _ScriptedChannel(
        downloadErrors: [
          PlatformException(code: 'UPLOAD_ERROR', message: 'daemon busy 1'),
          PlatformException(code: 'DOWNLOAD_ERROR', message: 'daemon busy 2'),
          null, // 第 3 次成功
        ],
        downloadReturn: base64Encode(utf8.encode('ok')),
      );
      final svc = ICloudStorageService(channel);
      final result = await svc.download(path: 'a.json');
      expect(result, 'ok');
      expect(channel.downloadCalls, 3);
    });

    test('瞬时故障 3 次仍失败 → 上抛（重试预算 1+2 用尽）', () async {
      final channel = _ScriptedChannel(
        downloadErrors: [
          PlatformException(code: 'DOWNLOAD_ERROR', message: 'busy 1'),
          PlatformException(code: 'DOWNLOAD_ERROR', message: 'busy 2'),
          PlatformException(code: 'DOWNLOAD_ERROR', message: 'busy 3'),
        ],
      );
      final svc = ICloudStorageService(channel);
      await expectLater(
        svc.download(path: 'a.json'),
        throwsA(isA<CloudStorageException>()),
      );
      expect(channel.downloadCalls, 3);
    });

    test('NOT_FOUND 是确定性结果 → 不消耗重试预算（1 次调用即返回 null）',
        () async {
      final channel = _ScriptedChannel(
        downloadErrors: [PlatformException(code: 'NOT_FOUND')],
      );
      final svc = ICloudStorageService(channel);
      expect(await svc.download(path: 'a.json'), isNull);
      expect(channel.downloadCalls, 1);
    });
  });

  group('N-9: 旧格式嗅探第一闸改严格 UTF-8 校验', () {
    test('含非 UTF-8 字节序列的二进制（全 base64 字符集不可判）→ 原样返回',
        () async {
      // 新格式原始二进制：含 0x80（UTF-8 非法首字节）—— 旧实现
      // String.fromCharCodes 后靠字符集正则把关，但该字节不在 base64
      // 字符集内本就不会解包；构造 UTF-8 非法但全 ASCII 字符集内的
      // 形态：0xFF 排除在 base64 字符集外，真正歧义面是纯 ASCII。
      // 本用例锁定「UTF-8 非法即原样」的第一闸行为：
      final raw = Uint8List.fromList([0x80, 0x81, 0x00, 0x50, 0x4B]);
      final svc = ICloudStorageService(_ScriptedChannel(
        downloadReturn: base64Encode(raw),
      ));
      final out = await svc.downloadBinary(path: 'attachments/bin.bin');
      expect(out, raw,
          reason: 'N-9: 非 UTF-8 字节在第一闸即原样返回，不再进字符集判定');
    });

    test('纯 ASCII 且恰为合法 base64 的新格式文本对象 → 仍解包（歧义残留声明）',
        () async {
      // 该形态在 UTF-8 闸下不可区分（文本的 base64 vs 恰似文本的字节），
      // sha256 终审是最终裁决 —— 行为与旧实现一致，属已知取舍非回归。
      const asciiText = 'SGVsbG8gd29ybGQh'; // 'Hello world!' 的 base64
      final svc = ICloudStorageService(_ScriptedChannel(
        downloadReturn: base64Encode(utf8.encode(asciiText)),
      ));
      final out = await svc.downloadBinary(path: 'a.bin');
      expect(out, utf8.encode('Hello world!'),
          reason: '纯 ASCII 合法 base64 仍按旧格式解包（兼容优先）');
    });

    test('UTF-8 合法但含非 base64 字符（中文文本）→ 原样字节返回', () async {
      const text = '同步账本数据检查';
      final svc = ICloudStorageService(_ScriptedChannel(
        downloadReturn: base64Encode(utf8.encode(text)),
      ));
      final out = await svc.downloadBinary(path: 'a.txt');
      expect(out, utf8.encode(text),
          reason: '合法 UTF-8 中文文本不是旧 base64 格式，原样返回');
    });

    test('旧 base64 文本对象（含 padding 与换行）→ 解包行为不变', () async {
      // 旧实现允许 base64 中含空白（\s 正则剔除）；严格 UTF-8 闸后
      // 合法 UTF-8 的空白文本依旧走到解包分支，兼容保持。
      final inner = Uint8List.fromList(List.generate(64, (i) => i));
      final legacyText = base64Encode(inner).replaceAllMapped(
          RegExp(r'(.{20})'), (m) => '${m[1]}\n'); // 每 20 字符插换行
      final svc = ICloudStorageService(_ScriptedChannel(
        downloadReturn: base64Encode(utf8.encode(legacyText)),
      ));
      final out = await svc.downloadBinary(path: 'old2.bin');
      expect(out, inner,
          reason: '旧格式（RFC 2045 带换行的 base64 文本）解包兼容');
    });
  });
}
