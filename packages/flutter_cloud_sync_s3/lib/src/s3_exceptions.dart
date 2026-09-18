/// S3 相关异常基类
class S3Exception implements Exception {
  final String message;
  final int? statusCode;
  final Exception? originalException;

  S3Exception(this.message, {this.statusCode, this.originalException});

  @override
  String toString() {
    final parts = ['S3Exception: $message'];
    if (statusCode != null) {
      parts.add('(HTTP $statusCode)');
    }
    if (originalException != null) {
      parts.add('\nCaused by: $originalException');
    }
    return parts.join(' ');
  }
}

/// S3 认证异常（AccessKey 或 SecretKey 无效）
class S3AuthException extends S3Exception {
  S3AuthException(super.message, {super.originalException})
      : super(statusCode: 403);
}

/// S3 对象未找到异常
class S3ObjectNotFoundException extends S3Exception {
  final String key;

  S3ObjectNotFoundException(this.key)
      : super('Object not found: $key', statusCode: 404);
}

/// S3 Bucket 未找到异常
class S3BucketNotFoundException extends S3Exception {
  final String bucket;

  S3BucketNotFoundException(this.bucket)
      : super('Bucket not found: $bucket', statusCode: 404);
}

/// S3 网络异常
class S3NetworkException extends S3Exception {
  S3NetworkException(super.message, {super.originalException});
}

/// S3 权限不足异常
class S3PermissionDeniedException extends S3Exception {
  S3PermissionDeniedException(super.message, {super.originalException})
      : super(statusCode: 403);
}

/// 审计 S22：设备时钟与服务端偏差过大（RequestTimeTooSkewed）。
///
/// 客户端已按响应携带的服务器时间自动写入签名偏移补偿并重试；
/// 若本异常仍抛出，说明偏差持续存在或无法解析服务器时间，
/// UI 应提示用户校准系统时间。
class S3ClockSkewException extends S3Exception {
  /// 服务器时间（若可解析，UTC）
  final DateTime? serverTime;

  S3ClockSkewException(super.message, {this.serverTime})
      : super(statusCode: 403);
}

/// 条件写前置条件失败（HTTP 412 Precondition Failed）。
///
/// 方案C（并发全面加固）：putObject 携带 If-Match / If-None-Match 时，
/// 远端实际状态与前置条件不符（已被其他设备先行写入/删除），本次
/// 写入**未落盘**。调用方应翻译为冲突流程，而非盲目重试。
class S3PreconditionFailedException extends S3Exception {
  final String key;

  S3PreconditionFailedException(this.key, {String? message})
      : super(message ?? 'Precondition failed for object: $key',
            statusCode: 412);
}
