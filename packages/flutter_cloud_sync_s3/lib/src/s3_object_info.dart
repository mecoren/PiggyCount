/// S3 对象元信息
///
/// 用于 [S3Client.listObjectsDetailed] 和 [S3Client.headObjectWithMetadata]
/// 返回对象的完整元数据（key、size、lastModified），避免调用方拿到
/// 硬编码的 0 / DateTime.now() 等错误值。
class S3ObjectInfo {
  /// 对象 key（已剥离 bucket 前缀，逻辑路径）
  final String key;

  /// 对象大小（字节），未知时为 null
  final int? size;

  /// 对象最后修改时间，未知时为 null
  final DateTime? lastModified;

  const S3ObjectInfo({
    required this.key,
    this.size,
    this.lastModified,
  });

  @override
  String toString() =>
      'S3ObjectInfo(key: $key, size: $size, lastModified: $lastModified)';
}

/// HEAD 请求返回的对象元信息
///
/// [exists] 为 false 时其余字段为 null，表示对象不存在（404）。
/// [metadata] 携带 S3 自定义元数据（x-amz-meta-* 头），
/// 供 [S3StorageService.getMetadata] 返回给 CloudSyncManager，
/// 使其能通过 metadata 中的 fingerprint 直接判断同步状态，
/// 避免每次 getStatus 都下载全量文件。
class S3HeadInfo {
  final bool exists;
  final int? size;
  final DateTime? lastModified;
  final String? contentType;

  /// 自定义元数据（从 x-amz-meta-* 响应头解析）
  final Map<String, String>? metadata;

  const S3HeadInfo({
    required this.exists,
    this.size,
    this.lastModified,
    this.contentType,
    this.metadata,
  });

  /// 对象不存在的哨兵实例
  static const notFound = S3HeadInfo(exists: false);
}
