/// Base exception for all cloud sync errors
class CloudSyncException implements Exception {
  final String message;
  final dynamic originalError;

  CloudSyncException(this.message, [this.originalError]);

  @override
  String toString() {
    if (originalError != null) {
      return 'CloudSyncException: $message (Original error: $originalError)';
    }
    return 'CloudSyncException: $message';
  }
}

/// Thrown when user is not authenticated
class CloudNotAuthenticatedException extends CloudSyncException {
  CloudNotAuthenticatedException([String? message])
      : super(message ?? 'User not authenticated');
}

/// Thrown when cloud service configuration is invalid
class CloudConfigurationException extends CloudSyncException {
  CloudConfigurationException(super.message, [super.error]);
}

/// Thrown when storage operations fail
class CloudStorageException extends CloudSyncException {
  CloudStorageException(super.message, [super.error]);
}

/// Thrown when a file/object is not found (HTTP 404).
///
/// 契约现状（与 [CloudStorageService.download]/[getMetadata] 的
/// "missing returns null" 注释对齐）：当前各适配器（S3/WebDAV）在
/// 404 时**返回 null** 而非抛出本异常；delete 在 404 时静默成功。
/// 本异常保留给需要"显式缺失"语义的路径（如 S3 downloadFile 包装层），
/// 新代码不应假设 download/getMetadata 会抛出它 —— 判定缺失请以
/// null 返回值为准，类型捕获仅作为额外防御。
class CloudFileNotFoundException extends CloudStorageException {
  final String path;

  CloudFileNotFoundException(this.path)
      : super('File not found: $path');
}

/// Thrown when an optimistic-concurrency precondition fails (HTTP 412).
///
/// 方案C（并发全面加固）：[ConditionalWriteStorage] 实现方在
/// If-Match / If-None-Match 条件不满足时抛出本异常，表示
/// 「远端已被其他设备先行修改，本次写入未落盘」。
/// 上层应将其翻译为冲突流程（提示用户合并/强制覆盖），而非当作
/// 普通存储故障重试 —— 盲目重试只会再次失败或造成覆盖。
class CloudPreconditionFailedException extends CloudSyncException {
  final String path;

  CloudPreconditionFailedException(this.path, [String? message])
      : super(message ?? 'Precondition failed (remote changed): $path');
}

/// Thrown when authentication operations fail
class CloudAuthException extends CloudSyncException {
  CloudAuthException(super.message, [super.error]);
}
