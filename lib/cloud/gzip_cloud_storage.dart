import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

/// Gzip 压缩版 [CloudStorageService] 装饰器（P2-2③）。
///
/// 设计定位：**仅文本快照（ledger_*.json）的传输层压缩**——大账本
/// JSON（几百 KB~MB 级）gzip 压缩率典型 5~8 倍，弱网上传/下载的
/// 耗时与流量同比例下降；附件 `.bin`（已内容寻址的二进制）与
/// 元数据读取不参与（压缩收益小且有格式风险）。
///
/// 装配位置（见 TransactionsSyncManager._initialize 与
/// [EncryptedCloudProvider.outerStorageWrapper]）：
/// `rawStorage → [EncryptedCloudStorageService] → [GzipCloudStorageService]`
/// —— 本层在**加密层之外**（最靠近调用方），压缩发生在**明文**上、加密发生
/// 在压缩后（顺序与备份链路「ZIP → 加密」一致，压明文才有效）。加密未开启
/// 时**不装配**：
/// - 历史明文对象永不压缩，旧版本 App / 外部工具可读性不受升级影响；
/// - 压缩形态只出现在「云端本就只见密文」的 E2EE 场景，无回滚风险。
///
/// 方向说明（审计 P1，2026-09-20 修复）：旧实现的注释同样宣称「压缩发生在
/// 明文上」，但实际装配把本层放在加密层**之下**（Encrypted(Gzip(raw))）——
/// 上传时加密层先产出 BEECRYPT1 密文，本层的密文透传短路被命中 → **永不压缩**，
/// 该特性在生产完全失效（仅被测试假阳性掩盖）。现由 outerStorageWrapper 保证
/// 本层在外层；并且 [uploadBinaryConditional]（S3 恒走的条件写路径）也一并
/// 压缩 —— 否则条件写会绕过本层，压缩同样形同虚设。
///
/// 兼容契约（download 嗅探三态）：
/// - gzip 魔数（1f 8b 08）→ 解压返回（本层压缩产物）；
/// - BEECRYPT1 密文信封 → 原样透传（加密层在外层，正常装配下不会命中；
///   保留为防御，避免异常装配/旧对象走到无意义压缩分支）；
/// - 其余（旧明文 JSON / rekey 直写的未压缩明文）→ 原样透传。
/// 嗅探是字节级判定，gzip 与明文 JSON 以首字节区分，无误判面。
///
/// rekey 全量重加密（encryption_service_impl._reEncryptCloudDataWithKeys）
/// 使用 **rawStorage**（不经本装饰器）：下载旧密文/上传新密文均为
/// 未压缩形态，其「密文/明文/二进制」三分支逻辑不受影响——本装饰器
/// 写的对象它重加密后变回未压缩，下载端嗅探继续透传，往返恒安全。
class GzipCloudStorageService
    implements CloudStorageService, BinaryCapableStorage, ConditionalWriteStorage {
  final CloudStorageService inner;

  /// 压缩统计日志注入口（对齐 Supabase storageLogger / S3 downgradeLogger
  /// 模式）：由 provider 装配处注入；未注入时静默（测试无感）。
  static CloudSyncLogger? compressionLogger;

  /// 文本小于该字节数不压缩（gzip 头 10 字节 + 开销可能让小对象
  /// 反而变大；小对象压缩收益低于 CPU 成本）。
  static const int minCompressSize = 2048;

  /// 压缩比低于该值（compressed/raw）放弃压缩、存原文 —— 空间
  /// 换流量的阈值：高度重复的 JSON 通常 10% 以下，保险起见 60%。
  static const double maxCompressionRatio = 0.6;

  GzipCloudStorageService({required this.inner});

  /// gzip 魔数：1f 8b + deflate 方法 08。
  static bool _isGzip(Uint8List bytes) =>
      bytes.length > 3 &&
      bytes[0] == 0x1f &&
      bytes[1] == 0x8b &&
      bytes[2] == 0x08;

  /// BEECRYPT1 密文信封前缀（透传给上层加密装饰器解密）。
  static const String _ciphertextPrefix = 'BEECRYPT1:';

  /// 二进制 gzip 流 ↔ 文本层的无损桥：Latin-1（每字节一码点）编码
  /// 保证 0-255 全域字节经文本通道往返不损失——UTF-8 会把 >0x7F 的
  /// 字节重编码成多字节序列，解不出原 gzip 流（早期实现的真实 bug）。
  static String _bytesToText(List<int> bytes) => String.fromCharCodes(bytes);

  static Uint8List _textToBytes(String text) {
    final out = Uint8List(text.length);
    for (var i = 0; i < text.length; i++) {
      out[i] = text.codeUnitAt(i) & 0xff;
    }
    return out;
  }

  @override
  Future<String?> download({required String path}) async {
    final text = await inner.download(path: path);
    if (text == null) return null;
    final bytes = _textToBytes(text);
    if (!_isGzip(bytes)) return text;
    try {
      // 纯 Dart gzip 解压是 CPU 密集同步操作，多 MB 快照在主 isolate
      // 会卡 UI 数百 ms——移入后台 isolate（encode 同理，见下）。
      final decompressed =
          await Isolate.run(() => GZipDecoder().decodeBytes(bytes));
      return utf8.decode(decompressed);
    } catch (e) {
      // 魔数命中但解压失败（半截对象/网关截断）：按损坏数据上抛，
      // 与完整性硬校验的「恢复中止优于吃坏数据」口径一致
      throw CloudStorageException('gzip 解压失败: $path', e);
    }
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    // 密文信封透传：正常装配下本层在加密层之外，upload 收到的是明文；
    // 保留该守卫作为防御（异常装配/旧对象），避免对密文做无意义压缩。
    if (data.startsWith(_ciphertextPrefix)) {
      return inner.upload(path: path, data: data, metadata: metadata);
    }
    final compressed = await _compressIfBeneficial(
        Uint8List.fromList(utf8.encode(data)), path: path);
    if (compressed == null) {
      // 压缩无收益（高熵内容/极短文本）：存原文，读取端嗅探兼容
      return inner.upload(path: path, data: data, metadata: metadata);
    }
    return inner.upload(
      path: path,
      // gzip 字节流经 Latin-1 桥无损过文本通道（见 _bytesToText 注释）
      data: _bytesToText(compressed),
      metadata: metadata,
    );
  }

  /// 压缩收益判定：小于 [minCompressSize] 或压缩比不达
  /// [maxCompressionRatio] 时返回 null（调用方存原文，读取端嗅探兼容）。
  /// 命中时记录压缩统计日志。gzip 编码移入后台 isolate（CPU 密集，
  /// 多 MB JSON 主线程压缩会卡 UI 数百 ms）。
  Future<Uint8List?> _compressIfBeneficial(Uint8List bytes,
      {String? path}) async {
    if (bytes.length < minCompressSize) return null;
    final compressed = await Isolate.run(() => GZipEncoder().encode(bytes));
    if (compressed == null ||
        compressed.length >= bytes.length * maxCompressionRatio) {
      return null;
    }
    if (path != null) {
      compressionLogger?.info(
          '[Gzip] $path: ${bytes.length}B → ${compressed.length}B '
          '(${(compressed.length * 100 / bytes.length).toStringAsFixed(0)}%)');
    }
    return compressed is Uint8List ? compressed : Uint8List.fromList(compressed);
  }

  // ---- 以下全部透传：附件二进制不压缩（内容寻址、多为图片等已压缩
  // 格式）；元数据/列举/删除/存在性与内容形态无关 ----
  //
  // 能力接口（BinaryCapableStorage / ConditionalWriteStorage）必须
  // 镜像透传：装配链 raw → Gzip → Encrypted 中，gzip 层若不实现
  // Binary，CloudStorageBinaryExt 会让附件退化 base64 文本（+33%）；
  // 若不实现 Conditional，条件写锚点在上层解绑（manager 判定不支持
  // → 盲写）。条件写能力按 inner 如实申报（本层不引入也不消除能力）。

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) {
    if (inner is BinaryCapableStorage) {
      return (inner as BinaryCapableStorage)
          .uploadBinary(path: path, bytes: bytes, metadata: metadata);
    }
    // inner 无原生二进制能力：与 CloudStorageBinaryExt 兜底同款
    // base64 文本路径（gzip 层不压缩二进制，见类注释）
    return inner.upload(
        path: path, data: base64Encode(bytes), metadata: metadata);
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    if (inner is BinaryCapableStorage) {
      return (inner as BinaryCapableStorage).downloadBinary(path: path);
    }
    final text = await inner.download(path: path);
    if (text == null) return null;
    try {
      return Uint8List.fromList(base64Decode(text));
    } catch (e) {
      throw CloudStorageException('Invalid base64 payload: $path', e);
    }
  }

  @override
  bool get supportsConditionalWrite =>
      inner.conditionalOrNull != null;

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
      // inner 无条件写能力：等价于上层（manager）判不支持时的盲写降级。
      // 二进制降 base64 文本（同 CloudStorageBinaryExt 兜底语义）。
      if (ifMatchEtag != null && ifNoneMatch) {
        throw ArgumentError('ifMatchEtag 与 ifNoneMatch 互斥');
      }
      if (inner is BinaryCapableStorage) {
        return (inner as BinaryCapableStorage)
            .uploadBinary(path: path, bytes: bytes, metadata: metadata);
      }
      return inner.upload(
          path: path, data: base64Encode(bytes), metadata: metadata);
    }

    // 审计 P1：条件写路径必须同样压缩。S3 后端恒走条件写（有 eTag 锚点），
    // 若此处不压缩，主上传路径会整体绕过 gzip，压缩特性形同虚设。manager
    // 传入的 bytes 是「明文 JSON 的 utf8 字节」，压缩后经 Latin-1 桥交给
    // 内层加密装饰器加密 —— 与 upload 路径的明文形态一致，download 侧
    // 嗅探解压可原样还原。
    final compressed = await _compressIfBeneficial(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        path: path);
    if (compressed == null) {
      await conditional.uploadBinaryConditional(
        path: path,
        bytes: bytes,
        metadata: metadata,
        ifMatchEtag: ifMatchEtag,
        ifNoneMatch: ifNoneMatch,
      );
      return;
    }
    await conditional.uploadBinaryConditional(
      path: path,
      bytes: utf8.encode(_bytesToText(compressed)),
      metadata: metadata,
      ifMatchEtag: ifMatchEtag,
      ifNoneMatch: ifNoneMatch,
    );
  }

  @override
  Future<void> delete({required String path}) => inner.delete(path: path);

  @override
  Future<List<CloudFile>> list({required String path}) => inner.list(path: path);

  @override
  Future<bool> exists({required String path}) => inner.exists(path: path);

  @override
  Future<CloudFile?> getMetadata({required String path}) =>
      inner.getMetadata(path: path);
}
