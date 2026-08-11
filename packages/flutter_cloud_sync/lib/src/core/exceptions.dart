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
  CloudConfigurationException(String message, [dynamic error])
      : super(message, error);
}

/// Thrown when storage operations fail
class CloudStorageException extends CloudSyncException {
  CloudStorageException(String message, [dynamic error])
      : super(message, error);
}

/// Thrown when a file/object is not found (HTTP 404).
///
/// m-04 修复：统一各 Provider 的 404 处理，调用方通过类型匹配
/// 而非脆弱的字符串匹配判断文件是否存在。
///
/// 使用方式：
/// - Provider 的 download/getMetadata 在 404 时抛出此异常
/// - Provider 的 delete 在 404 时静默返回（幂等语义）
/// - 调用方通过 `catch (e is CloudFileNotFoundException)` 捕获
class CloudFileNotFoundException extends CloudStorageException {
  final String path;

  CloudFileNotFoundException(this.path)
      : super('File not found: $path');
}

/// Thrown when authentication operations fail
class CloudAuthException extends CloudSyncException {
  CloudAuthException(String message, [dynamic error]) : super(message, error);
}
