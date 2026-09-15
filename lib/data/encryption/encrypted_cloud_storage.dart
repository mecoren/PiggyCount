import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import '../../services/system/logger_service.dart';
import 'ciphertext_format.dart';
import '../../domain/encryption/encryption_service.dart';

/// 加密版 [CloudStorageService] 装饰器
///
/// 包装任意 [CloudStorageService] 实现（S3 / WebDAV / Supabase / iCloud），
/// 在上传/下载时自动加解密，对上层完全透明。
///
/// 行为契约：
/// - [upload]：调用 [EncryptionService.encrypt] 加密后传给 inner；
///   加密未开启时 encrypt 返回原文，等价于透传。
/// - [download]：从 inner 取回数据；为 null 时返回 null；
///   否则调用 [EncryptionService.decrypt]，按 magic header 自动识别密文/legacy 明文。
/// - [delete] / [list] / [exists]：完全透传，不接触加密。
/// - 元数据（审计 P1）：E2EE 开启时不允许业务元数据以明文上云
///   （S3 x-amz-meta-* / WebDAV sidecar 对存储服务商完全可见，
///   泄漏账本名/币种/余额/条数/指纹）。上传前把整个 metadata 序列化为
///   单个加密信封键 [encMetaKey]；[getMetadata] 读到该键时解密还原。
///   - 未开启加密：行为与历史版本一致（明文透传，不包装）；
///   - 旧版写入的明文元数据（无信封键）：读取端原样返回（向后兼容）；
///   - 信封解密失败（密钥不匹配等）：降级返回原始 map，调用方按
///     「无指纹」走全量下载兜底，不抛异常阻断状态检查。
class EncryptedCloudStorageService
    implements
        CloudStorageService,
        BinaryCapableStorage,
        ConditionalWriteStorage {
  final CloudStorageService inner;
  final EncryptionService encryptionService;

  EncryptedCloudStorageService({
    required this.inner,
    required this.encryptionService,
  });

  /// 条件写能力如实申报（方案C）：inner 支持（S3/WebDAV）才支持。
  /// 加密发生在上传前、条件头作用在密文对象上，二者正交不冲突。
  @override
  bool get supportsConditionalWrite => inner.conditionalOrNull != null;

  /// 元数据加密信封键。
  ///
  /// S3 链路传输层会把 x-amz-meta-* 头名转小写、写入端也显式小写；
  /// WebDAV sidecar 保留原始键名。读取端一律大小写无关匹配以兼容两类后端。
  ///
  /// 公开静态常量：密钥轮换（EncryptionServiceImpl._preservedMetadata）与
  /// 单元测试需要按同一键名识别/重包信封。
  ///
  /// 2026-09-15 实测修复：旧键 `_encmeta` 会让 S3 请求携带
  /// `x-amz-meta-_encmeta`（头名含下划线）。OSS 等 S3 兼容网关
  /// （nginx 系 `underscores_in_headers off` 默认行为）会丢弃下划线头，
  /// 而签名器把所有 x-amz-* 头计入 SignedHeaders → 服务端收到的请求
  /// 缺少已签名头 → 恒定 403 "Not all the signed headers are found in
  /// the request"。故改为连字符键名 `pc-encmeta`；旧键仅在读取端兼容。
  static const String encMetaKey = 'pc-encmeta';

  /// 旧版信封键（下划线头名，见 [encMetaKey] 注释）。仅读取端兼容：
  /// 旧版 E2EE 写入的云端对象元数据仍能解出指纹，避免触发全量下载兜底。
  static const String legacyEncMetaKey = '_encmeta';

  /// 上传前的元数据处理：
  /// - null/空 → 原样返回 null；
  /// - 加密未开启 → 原样透传（与历史行为一致）；
  /// - 加密开启 → 整包序列化加密进单个 [encMetaKey] 信封。
  Future<Map<String, String>?> _wrapMetadata(
      Map<String, String>? metadata) async {
    if (metadata == null || metadata.isEmpty) return metadata;
    if (!await encryptionService.isEnabled) return metadata;
    final envelope = await encryptionService.encrypt(jsonEncode(metadata));
    return {encMetaKey: envelope};
  }

  /// 读取端的元数据还原：
  /// - 无信封键（旧版明文元数据）→ 原样返回；
  /// - 有信封键且解密成功 → 返回解密后的原始键值对；
  /// - 解密失败（密钥不匹配/损坏）→ 降级返回原始 map，绝不抛异常
  ///   （getStatus 等调用方拿不到指纹会自动退回全量下载路径）。
  Future<Map<String, dynamic>?> _unwrapMetadata(
      Map<String, dynamic>? metadata) async {
    if (metadata == null || metadata.isEmpty) return metadata;

    String? envelope;
    for (final entry in metadata.entries) {
      final key = entry.key.toLowerCase();
      if (key == encMetaKey || key == legacyEncMetaKey) {
        envelope = entry.value?.toString();
        break;
      }
    }
    if (envelope == null) return metadata;

    try {
      // 密钥不可用时 decrypt 抛 EncryptionNotConfiguredException /
      // DecryptionException，统一落入下方降级分支
      final plain = await encryptionService.decrypt(envelope);
      final decoded = jsonDecode(plain);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      // 信封内容非对象（异常产物）：降级原样返回
      return metadata;
    } catch (e) {
      // LOG-03：此前完全静默 —— 密钥错配/信封损坏时装饰器把含密文的
      // 原始 map 当无指纹数据返回，上层永远走全量下载兜底，流量异常
      // 但日志零线索。P2-9（2026-09-11）：debugPrint 升级为应用日志
      // warning —— release 构建可留痕，长期密钥错配可被健康排查发现
      //（不含密文内容）。
      logger.warning('CloudSync',
          '元数据信封解密失败（降级原样返回，指纹不可用，上层将走全量'
          '下载；若持续出现请核对加密密码是否在所有设备一致）: $e');
      return metadata;
    }
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    // 加密未开启时 encrypt 返回原文，等价于透传
    final payload = await encryptionService.encrypt(data);
    await inner.upload(
        path: path, data: payload, metadata: await _wrapMetadata(metadata));
  }

  /// 二进制加密口径：字节 base64 封入文本信封后走既有字符串加密路径，
  /// 云端产物与现有同步文件同格式（BEECRYPT1: 密文 / 未开启时 base64 文本）。
  /// 注意：实现本接口后 CloudStorageBinaryExt 会分派到这里而非穿透 inner
  /// 的真字节路径 —— 加密场景下云端必然是密文，符合端到端加密预期。
  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    final payload = await encryptionService.encrypt(base64Encode(bytes));
    await inner.upload(
        path: path, data: payload, metadata: await _wrapMetadata(metadata));
  }

  @override
  Future<void> uploadBinaryConditional({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
    String? ifMatchEtag,
    bool ifNoneMatch = false,
  }) async {
    final conditional = inner.conditionalOrNull;
    if (conditional == null) {
      // 能力申报已挡住常规路径；防御性兜底保证语义明确
      throw UnsupportedError(
          'Underlying storage does not support conditional writes: $path');
    }
    // P0-2 修复：条件写的密文形态必须与 [upload]（文本形态 encrypt(原文)）
    // 对齐，而非 [uploadBinary] 的 encrypt(base64(bytes))。
    //
    // 唯一调用方 CloudSyncManager.upload 传入的 bytes 是「明文 JSON 的
    // utf8 字节」。旧实现按 uploadBinary 口径先 base64 再加密，存储形态
    // 变成 encrypt(base64(明文)) —— 而 download() 对密文 decrypt 后直接
    // 返回，读到的是 base64 文本而非 JSON：E2EE + 条件写后端（S3 恒走
    // 条件写路径）下，该账本所有 download / 恢复 / 完整性校验全部损坏
    // （jsonDecode 必抛 FormatException）。
    //
    // bytes 可解为 UTF-8 文本（manager 契约内恒成立）→ 与 upload 同形态；
    // 意外的非文本字节（防御）→ 维持 uploadBinary 的 base64 形态，
    // downloadBinary 侧两种形态均可读（见其注释）。
    final asText = _tryUtf8Decode(bytes);
    final String payload;
    if (asText != null) {
      payload = await encryptionService.encrypt(asText);
    } else {
      payload = await encryptionService.encrypt(base64Encode(bytes));
    }
    await conditional.uploadBinaryConditional(
      path: path,
      bytes: utf8.encode(payload),
      metadata: await _wrapMetadata(metadata),
      ifMatchEtag: ifMatchEtag,
      ifNoneMatch: ifNoneMatch,
    );
  }

  @override
  Future<String?> download({required String path}) async {
    final data = await inner.download(path: path);
    if (data == null) return null;
    // decrypt 自动识别 BEECRYPT1: 密文和 legacy 明文
    return encryptionService.decrypt(data);
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    // 审计 A1：优先取**原始字节**再按形态分流，而不是恒经 inner.download
    // 的文本路径 —— E2EE 开启前以原生二进制上传的旧附件对象（L4 路径）
    // 不是合法 UTF-8，旧实现 inner.download 直接抛 FormatException，
    // 该对象在加密设备上永久不可下载。
    //
    // 云端对象的两种来源：
    // ① 本装饰器 uploadBinary 写入的密文信封（BEECRYPT1 文本 = 加密后的
    //    base64）→ 解密得 base64 明文 → 解码；
    // ② E2EE 开启前的原生二进制 / legacy 明文 base64 文本 → 原样字节返回
    //    （②的最终正确性由调用方 sha256 终审兜底，误判不会落脏数据）。
    List<int>? raw;
    final binInner =
        inner is BinaryCapableStorage ? inner as BinaryCapableStorage : null;
    if (binInner != null) {
      raw = await binInner.downloadBinary(path: path);
    } else {
      final text = await inner.download(path: path);
      raw = text == null ? null : utf8.encode(text);
    }
    if (raw == null) return null;

    final asText = _tryUtf8Decode(raw);
    if (asText != null && CiphertextFormat.isEncrypted(asText)) {
      // 形态①：密文信封。decrypt 自动识别 magic header；解密产物为
      // base64 明文（uploadBinary 的写入格式），解码失败属信封损坏。
      final plain = await encryptionService.decrypt(asText);
      return Uint8List.fromList(base64Decode(plain));
    }
    if (asText != null) {
      // 可解为文本但非密文：兼容 legacy「明文 base64 文本」上传形态
      // （非 BinaryCapable 后端兜底时期写入）。仅当整体是合法 base64 时
      // 解码，否则视为内容恰为纯文本的原生对象，原样字节返回。
      final compact = asText.replaceAll(RegExp(r'\s'), '');
      if (compact.isNotEmpty &&
          compact.length % 4 == 0 &&
          RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(compact)) {
        try {
          return Uint8List.fromList(base64Decode(compact));
        } catch (_) {
          // 非法 base64：落入下方原样返回
        }
      }
    }
    // 形态②（或无法归类的对象）：原样字节。图片/视频等二进制内容的
    // 首字节几乎必然落在 UTF-8 非法区/非 base64 字符集，不会误入上方分支。
    return Uint8List.fromList(raw);
  }

  /// 尝试 UTF-8 解码；含非法序列（典型如二进制内容）时返回 null。
  static String? _tryUtf8Decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> delete({required String path}) async {
    await inner.delete(path: path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    return inner.list(path: path);
  }

  @override
  Future<bool> exists({required String path}) async {
    return inner.exists(path: path);
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    final file = await inner.getMetadata(path: path);
    if (file == null) return null;
    final unwrapped = await _unwrapMetadata(file.metadata);
    if (identical(unwrapped, file.metadata)) return file;
    return CloudFile(
      name: file.name,
      path: file.path,
      size: file.size,
      lastModified: file.lastModified,
      metadata: unwrapped,
      // 方案C：ETag 与加密正交，装饰时必须透传，否则上层拿不到
      // 条件写锚点，乐观并发静默退化为盲上传
      eTag: file.eTag,
    );
  }
}
