import 'dart:convert';
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
/// 装配位置（见 TransactionsSyncManager._initialize）：
/// `rawStorage → [GzipCloudStorageService] → [EncryptedCloudStorageService]`
/// —— 压缩发生在**明文**上、加密发生在**压缩后**（顺序与备份链路
/// 「ZIP → 加密」一致，压明文才有效）。加密未开启时**不装配**：
/// - 历史明文对象永不压缩，旧版本 App / 外部工具可读性不受升级影响；
/// - 压缩形态只出现在「云端本就只见密文」的 E2EE 场景，无回滚风险。
///
/// 兼容契约（download 嗅探三态）：
/// - gzip 魔数（1f 8b 08）→ 解压返回；
/// - BEECRYPT1 密文信封 → 原样透传（加密层在上层，本层不碰）；
/// - 其余（旧明文 JSON / rekey 直写的未压缩密文）→ 原样透传。
/// 嗅探是字节级判定，gzip 合法 JSON/明文密文以首字节区分，无误判面。
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
      final decompressed = GZipDecoder().decodeBytes(bytes);
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
    // 密文信封透传：本层在加密层之下，正常装配下 upload 收到的
    // 已是密文（加密层先压后密的镜像路径不会出现），防御性透传
    // 避免对密文做无意义的压缩尝试
    if (data.startsWith(_ciphertextPrefix)) {
      return inner.upload(path: path, data: data, metadata: metadata);
    }
    final bytes = Uint8List.fromList(utf8.encode(data));
    if (bytes.length < minCompressSize) {
      return inner.upload(path: path, data: data, metadata: metadata);
    }
    final compressed = GZipEncoder().encode(bytes);
    if (compressed == null ||
        compressed.length >= bytes.length * maxCompressionRatio) {
      // 压缩无收益（高熵内容/极短文本）：存原文，读取端嗅探兼容
      return inner.upload(path: path, data: data, metadata: metadata);
    }
    compressionLogger?.info(
        '[Gzip] $path: ${bytes.length}B → ${compressed.length}B '
        '(${(compressed.length * 100 / bytes.length).toStringAsFixed(0)}%)');
    return inner.upload(
      path: path,
      // gzip 字节流经 Latin-1 桥无损过文本通道（见 _bytesToText 注释）
      data: _bytesToText(compressed),
      metadata: metadata,
    );
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
    if (conditional != null) {
      await conditional.uploadBinaryConditional(
        path: path,
        bytes: bytes,
        metadata: metadata,
        ifMatchEtag: ifMatchEtag,
        ifNoneMatch: ifNoneMatch,
      );
      return;
    }
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
