import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import 'icloud_method_channel_contract.dart';

/// iCloud storage service implementation
///
/// P0-2 测试注入口：[_methodChannel] 的类型放宽为 method 兼容契约
/// （生产恒传 ICloudMethodChannel，测试注入 FakeICloudMethodChannel），
/// 使 _isNotFoundError 的错误分类可单测。
///
/// 2026-09-11 归一化批次（对照 docs/sync-comprehensive-audit-2026-09-10.md）：
/// - P1-5：实现 [BinaryCapableStorage] —— 此前未实现，附件/ZIP 备份恒走
///   core 兜底（upload(data: base64Encode(bytes))），叠加本类 upload 内的
///   第二次 base64Encode(utf8.encode(...)) 后磁盘对象是 base64 文本
///   （+33% 体积）。实现后 binary 路径单次编码直达原生契约（原生解码后
///   落盘原始字节），downloadBinary 带旧格式嗅探兼容（实现 Binary 之前
///   落盘的 base64 文本对象仍可正确读回）。
/// - P1-8：幂等读重试（download/downloadBinary/list/exists/getMetadata/
///   delete），对齐 WebDAV/Supabase 的 2 次、400/800ms ±50% 真随机
///   jitter —— iCloud 原生 daemon 未就绪/瞬时竞态是常态而非异常。
class ICloudStorageService
    implements CloudStorageService, BinaryCapableStorage,
        ConditionalWriteStorage {
  final ICloudMethodChannelLike _methodChannel;

  ICloudStorageService(this._methodChannel);

  /// P1-8：重试参数（对齐 WebDAV `_retryIdempotent`）。
  static const _maxRetries = 2;
  final Random _retryRandom = Random();

  /// P1-8：幂等操作自动重试。
  ///
  /// 可重试判定：非「文件不存在」（那是确定性结果）的瞬时失败 ——
  /// method channel 层的 PlatformException 多为 iCloud daemon 瞬时
  /// 未就绪/容器竞态。NOT_FOUND 类错误立即上抛由调用方按幂等语义
  /// 转换，不消耗重试预算。
  Future<T> _retryIdempotent<T>(Future<T> Function() op) async {
    var attempt = 0;
    while (true) {
      try {
        return await op();
      } catch (e) {
        final retriable = attempt < _maxRetries && !_isNotFoundError(e);
        if (!retriable) rethrow;
        attempt++;
        // 指数退避 + 真随机抖动：400ms、800ms（各 ±50%），与
        // WebDAV/Supabase 同参数表（sync-reliability-params.md）
        final baseMs = 400 * (1 << (attempt - 1));
        final jitter = _retryRandom.nextInt(baseMs ~/ 2 + 1);
        await Future<void>.delayed(
            Duration(milliseconds: baseMs ~/ 2 + jitter));
      }
    }
  }

  /// Safely convert a dynamic map to Map<String, dynamic>
  Map<String, dynamic>? _convertToStringDynamicMap(dynamic value) {
    if (value == null) return null;
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return null;
  }

  /// 判断异常是否表示「文件/目录不存在」
  ///
  /// 优先检查 [PlatformException.code]（原生层返回的结构化错误码），
  /// 其次检查 message 中的关键词（兼容未规范 code 的原生实现）。
  /// 命中返回 true，调用方据此返回 null / 空列表 / false（幂等语义）；
  /// 未命中时调用方应抛出异常，避免把网络中断、权限不足误判为「不存在」。
  ///
  /// P0-2 修复（对齐 WebDAV WD-M3 审计口径）：此前 message 兜底含
  /// `contains('404')` 纯数字子串匹配 —— 异常消息内嵌 host:port
  /// （如 `:8404`）或对象名含 "404" 时，**任何网络/权限错误都会被误判
  /// 为「不存在」** → exists()=false → 调用方触发覆盖上传，静默盖掉云端
  /// 数据。WebDAV 侧同款问题已修（有结构化信息只看状态码；无结构化信息
  /// 仅措辞匹配、绝不做数字子串匹配），iCloud 侧同步收口：
  /// - code 判定收紧为精确值（原生侧约定错误码枚举），不再 contains；
  /// - message 兜底删除全部数字子串，仅保留明确的「不存在」措辞。
  /// ICL-1（2026-09-12 P1）：lastModified 归一化为弱 eTag 锚点。
  ///
  /// iCloud 原生无 ETag 概念，CloudFile.eTag 此前恒 null →
  /// transactions_sync_manager 冲突探测拿到的 cloudETag 恒为空，
  /// 并发防护只剩「盲上传 + 写后校验」（两机并发静默 last-writer-wins）。
  /// 最小接线：lastModified（秒级文件系统精度）以 ISO 字符串透出，
  /// 供上层 If-Match 语义做弱锚点——同秒并发窗口仍不可分辨（诚实
  /// 边界），但跨秒的两机先后写入从此可被冲突探测识别。原生侧
  /// 无条件写语义不变，锚点比对失败由 manager 层按 unknown 冲突
  /// 上浮（用户对比合并/确认覆盖），不会静默丢数据。
  String? _lastModifiedEtag(Object? raw) {
    if (raw == null) return null;
    final parsed = DateTime.tryParse(raw as String);
    // 以 UTC ISO 精确到秒：同文件同 lastModified 必然同 eTag（往返
    // 稳定），原生 lastModified 精度即秒级，不引入伪精度
    return parsed?.toUtc().toIso8601String();
  }

  bool _isNotFoundError(Object e) {
    if (e is PlatformException) {
      final code = e.code.toLowerCase();
      const notFoundCodes = {
        '404',
        'notfound',
        'not_found',
        'no_such_file',
        'file_not_found',
        'filenotfound',
        'nsfilenosuchfileerror',
        'nsfilereadnosuchfileerror',
      };
      if (notFoundCodes.contains(code)) {
        return true;
      }
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('not found') ||
        msg.contains('does not exist') ||
        msg.contains('nsfilereadnosuchfileerror') ||
        msg.contains('nsfilenosuchfileerror');
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    try {
      // Encode data as Base64 for the method channel contract
      // （原生侧 Data(base64Encoded:) 解码后落盘 utf8 明文 —— 文本路径
      // 落盘即明文，无体积膨胀；base64 只是 channel 传输层编码）
      final encodedData = base64Encode(utf8.encode(data));

      await _methodChannel.uploadFile(
        path: path,
        data: encodedData,
        metadata: metadata,
      );
    } catch (e) {
      throw CloudStorageException('Upload failed: $e', e);
    }
  }

  /// P1-5：原生字节上传 —— 单次 base64（channel 契约），原生解码后
  /// 落盘**原始字节**。此前该后端未实现 BinaryCapableStorage，
  /// [CloudStorageBinaryExt.uploadBinaryOrFallback] 先 base64 一次、
  /// 本类 upload 再编码一次，磁盘对象是 base64 文本（+33% 体积）。
  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    try {
      final encoded = base64Encode(bytes);
      await _methodChannel.uploadFile(
        path: path,
        data: encoded,
        metadata: metadata,
      );
    } catch (e) {
      throw CloudStorageException('UploadBinary failed: $e', e);
    }
  }

  /// ICL-1（2026-09-12 P1）延伸：读后比对近似条件写（对齐 Supabase
  /// P1-1 模式）。iCloud 原生无 If-Match 语义，本实现以「重读 lastModified
  /// 锚点 → 比对 → 写入」收窄并发窗口：
  /// - [ifMatchEtag]：锚点取 getMetadata 透出的 eTag（lastModified 的
  ///   UTC ISO 归一化形态）。比对不一致（或锚点缺失于已存在对象）→
  ///   抛 [CloudPreconditionFailedException]，本次不落盘；
  /// - [ifNoneMatch]：探测对象存在即抛条件失败（create-only 语义）；
  /// - 窗口内（比对 → 落盘）他机写入仍可能被覆盖 —— 非原子，与
  ///   Supabase 实现同款取舍，由 manager 层写后校验兜底
  ///   （verified=false → softFail，脏标记不清）。
  ///
  /// 诚实边界：lastModified 秒级精度，同秒并发窗口锚点不可分辨
  /// （比对会误判「未变」放行）；跨秒的两机先后写入可被正确拦截。
  @override
  bool get supportsConditionalWrite => true;

  @override
  Future<void> uploadBinaryConditional({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
    String? ifMatchEtag,
    bool ifNoneMatch = false,
  }) async {
    if (ifMatchEtag != null && ifNoneMatch) {
      throw ArgumentError('ifMatchEtag 与 ifNoneMatch 互斥');
    }

    final current = await getMetadata(path: path);

    if (ifNoneMatch) {
      if (current != null) {
        throw CloudPreconditionFailedException(
            path, '远端对象已存在（create-only 条件失败）');
      }
    } else if (ifMatchEtag != null) {
      if (current == null) {
        // 远端不存在同样算条件失败（对齐接口契约：探测时存在、写入时
        // 消失 = 中途被并发改动/删除，按冲突处理）
        throw CloudPreconditionFailedException(path, '远端对象已不存在（条件锚点失效）');
      }
      final currentEtag = current.eTag;
      if (currentEtag == null || currentEtag != ifMatchEtag) {
        throw CloudPreconditionFailedException(
            path, '远端对象已被并发修改（锚点 $ifMatchEtag ≠ 当前 $currentEtag）');
      }
    }

    await uploadBinary(path: path, bytes: bytes, metadata: metadata);
  }

  /// P1-5：原生字节下载（带旧格式嗅探）。
  ///
  /// channel 返回磁盘字节的 base64；本方法解码为原始字节后做一层
  /// **旧格式嗅探**：实现 BinaryCapableStorage 之前经兜底路径写入的
  /// 对象，磁盘内容是「真实内容的 base64 文本」—— 解码出的字节若
  /// 恰为合法 UTF-8 且整体是合法 base64 串，按旧格式解包返回内层字节；
  /// 否则按新格式（原始字节）原样返回。二进制附件（图片/ZIP）几乎
  /// 不可能整段通过 UTF-8 + base64 双重校验，误判面极窄，且调用方
  /// （附件 sha256 终审 / ZIP 魔数探测）持有最终裁决权。
  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    Uint8List bytes;
    try {
      final encoded = await _retryIdempotent(
          () => _methodChannel.downloadFile(path: path));
      if (encoded == null) return null;
      bytes = base64Decode(encoded);
    } catch (e) {
      if (_isNotFoundError(e)) return null;
      throw CloudStorageException('DownloadBinary failed: $e', e);
    }
    return _unwrapLegacyBase64Text(bytes);
  }

  /// 旧格式嗅探：合法 UTF-8 且整体合法 base64 → 解包内层字节。
  ///
  /// N-9 修复（2026-09-12）：第一闸从 `String.fromCharCodes`（任意字节
  /// 均成功，无 UTF-8 校验）改为严格 `utf8.decode` try/catch —— 与
  /// 加密装饰器 `_tryUtf8Decode` 同款。旧 base64 文本对象本来就是合法
  /// UTF-8（纯 ASCII），行为不变；全 ASCII 且恰为合法 base64 的**新格式
  /// 原始二进制**此前会被误解包返回内层垃圾（附件 sha256 终审兜底不落
  /// 脏数据，但表现为「附件永远补不齐」难以诊断），严格 UTF-8 闸后该
  /// 歧义面归零（二进制附件几乎必含非 UTF-8 字节序列）。
  static Uint8List _unwrapLegacyBase64Text(Uint8List bytes) {
    final String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      return bytes; // 非 UTF-8 → 新格式原始二进制，原样返回
    }
    // 快速排除：base64 字符集之外的字符（含中文文本/控制字符）
    final isBase64Chars = text.isNotEmpty &&
        !text.contains(RegExp(r'[^A-Za-z0-9+/=\s]'));
    if (!isBase64Chars) return bytes;
    try {
      final decoded = base64Decode(text.replaceAll(RegExp(r'\s'), ''));
      return Uint8List.fromList(decoded);
    } catch (_) {
      return bytes; // 合法文本但非 base64 → 新格式原样返回
    }
  }

  @override
  Future<String?> download({required String path}) async {
    try {
      final encodedData = await _retryIdempotent(
          () => _methodChannel.downloadFile(path: path));

      if (encodedData == null) {
        return null;
      }

      // Decode Base64 data
      final bytes = base64Decode(encodedData);
      return utf8.decode(bytes);
    } catch (e) {
      // 文件不存在时返回 null（幂等语义），其他错误抛出
      if (_isNotFoundError(e)) {
        return null;
      }
      throw CloudStorageException('Download failed: $e', e);
    }
  }

  /// delete 是幂等操作（NOT_FOUND 视为成功），纳入 P1-8 重试。
  @override
  Future<void> delete({required String path}) async {
    try {
      await _retryIdempotent(() => _methodChannel.deleteFile(path: path));
    } catch (e) {
      // 忽略「文件不存在」错误（幂等删除），其他错误抛出
      if (!_isNotFoundError(e)) {
        throw CloudStorageException('Delete failed: $e', e);
      }
    }
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    try {
      final files = await _retryIdempotent(
          () => _methodChannel.listFiles(path: path));
      return files.map((fileInfo) {
        return CloudFile(
          name: fileInfo['name'] as String,
          path: fileInfo['path'] as String,
          size: fileInfo['size'] as int?,
          lastModified: fileInfo['lastModified'] != null
              ? DateTime.tryParse(fileInfo['lastModified'] as String)
              : null,
          metadata: _convertToStringDynamicMap(fileInfo['metadata']),
          // ICL-1：lastModified 归一化为 eTag（弱锚点形态）
          eTag: _lastModifiedEtag(fileInfo['lastModified']),
        );
      }).toList();
    } catch (e) {
      // 目录不存在时返回空列表（幂等语义），其他错误抛出
      if (_isNotFoundError(e)) {
        return [];
      }
      throw CloudStorageException('List failed: $e', e);
    }
  }

  @override
  Future<bool> exists({required String path}) async {
    try {
      return await _retryIdempotent(
          () => _methodChannel.fileExists(path: path));
    } catch (e) {
      // 仅在文件不存在（404/NSFileNoSuchFileError）时返回 false；
      // 其他错误（网络中断、iCloud 未启用等）必须抛出，避免调用方
      // 误判文件不存在而触发覆盖上传等危险操作。
      if (_isNotFoundError(e)) {
        return false;
      }
      throw CloudStorageException('Failed to check file existence: $e', e);
    }
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    try {
      final metadata = await _retryIdempotent(
          () => _methodChannel.getFileMetadata(path: path));
      if (metadata == null) {
        return null;
      }

      return CloudFile(
        name: metadata['name'] as String,
        path: metadata['path'] as String,
        size: metadata['size'] as int?,
        lastModified: metadata['lastModified'] != null
            ? DateTime.tryParse(metadata['lastModified'] as String)
            : null,
        metadata: _convertToStringDynamicMap(metadata['customMetadata']),
        // ICL-1：lastModified 归一化为 eTag（弱锚点形态）
        eTag: _lastModifiedEtag(metadata['lastModified']),
      );
    } catch (e) {
      if (_isNotFoundError(e)) {
        return null;
      }
      throw CloudStorageException('Get metadata failed: $e', e);
    }
  }
}
