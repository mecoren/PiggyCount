import 'dart:math';

import '../core/exceptions.dart';

/// Retry configuration
class RetryConfig {
  /// Maximum number of retry attempts
  final int maxAttempts;

  /// Initial delay between retries
  final Duration initialDelay;

  /// Maximum delay between retries
  final Duration maxDelay;

  /// Backoff multiplier (exponential backoff)
  final double backoffMultiplier;

  /// List of exception types that should trigger a retry
  final List<Type>? retryableExceptions;

  /// Callback to determine if an exception should trigger a retry
  final bool Function(Exception)? shouldRetry;

  const RetryConfig({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.backoffMultiplier = 2.0,
    this.retryableExceptions,
    this.shouldRetry,
  });

  /// Default configuration for network operations
  static const network = RetryConfig(
    maxAttempts: 3,
    initialDelay: Duration(seconds: 1),
    maxDelay: Duration(seconds: 10),
    backoffMultiplier: 2.0,
  );

  /// Aggressive retry for critical operations
  static const aggressive = RetryConfig(
    maxAttempts: 5,
    initialDelay: Duration(milliseconds: 500),
    maxDelay: Duration(seconds: 20),
    backoffMultiplier: 2.0,
  );

  /// Conservative retry for non-critical operations
  static const conservative = RetryConfig(
    maxAttempts: 2,
    initialDelay: Duration(seconds: 2),
    maxDelay: Duration(seconds: 5),
    backoffMultiplier: 1.5,
  );
}

/// Retry helper for executing operations with automatic retry logic
class RetryHelper {
  /// 用于重试间隔 jitter（P3-3）
  static final Random _random = Random();
  /// Execute an operation with automatic retry on failure
  ///
  /// [operation] - The async operation to execute
  /// [config] - Retry configuration (defaults to network config)
  /// [onRetry] - Optional callback invoked before each retry
  ///
  /// Returns the result of the successful operation.
  /// Throws the last exception if all retries are exhausted.
  ///
  /// 注意：本方法只捕获 [Exception]，不捕获 [Error]。Error 类型（如
  /// StackOverflowError、StateError）通常表示编程 bug，重试无意义，
  /// 应直接暴露给调用方修复代码。
  ///
  /// Example:
  /// ```dart
  /// final result = await RetryHelper.execute(
  ///   () => httpClient.get(url),
  ///   config: RetryConfig.network,
  ///   onRetry: (attempt, error) {
  ///     print('Retry attempt $attempt after error: $error');
  ///   },
  /// );
  /// ```
  static Future<T> execute<T>(
    Future<T> Function() operation, {
    RetryConfig config = RetryConfig.network,
    void Function(int attempt, Exception error)? onRetry,
  }) async {
    int attempt = 0;
    Duration currentDelay = config.initialDelay;
    Exception? lastException;

    while (attempt < config.maxAttempts) {
      attempt++;

      try {
        return await operation();
      } on Exception catch (e) {
        lastException = e;

        // Check if we should retry this exception
        if (!_shouldRetryException(e, config)) {
          rethrow;
        }

        // Check if we've exhausted all attempts
        if (attempt >= config.maxAttempts) {
          rethrow;
        }

        // Notify retry callback
        onRetry?.call(attempt, e);

        // P3-3：等待前加入 0~25% 随机 jitter，避免多端同时重试
        // 产生重试风暴（thundering herd）。
        final jitterMs =
            (currentDelay.inMilliseconds * (0.25 * _random.nextDouble()))
                .round();
        await Future.delayed(
            currentDelay + Duration(milliseconds: jitterMs));

        // Calculate next delay with exponential backoff
        currentDelay = Duration(
          milliseconds: (currentDelay.inMilliseconds * config.backoffMultiplier)
              .round()
              .clamp(0, config.maxDelay.inMilliseconds),
        );
      }
    }

    // This should never be reached, but just in case
    throw lastException ??
        CloudSyncException('Retry exhausted with no exception recorded');
  }

  /// Execute an operation with a simple retry count
  ///
  /// Simplified version that only accepts max attempts.
  ///
  /// Example:
  /// ```dart
  /// final result = await RetryHelper.executeSimple(
  ///   () => cloudStorage.upload(data),
  ///   maxAttempts: 3,
  /// );
  /// ```
  static Future<T> executeSimple<T>(
    Future<T> Function() operation, {
    int maxAttempts = 3,
  }) async {
    return execute(
      operation,
      config: RetryConfig(maxAttempts: maxAttempts),
    );
  }

  /// Execute with exponential backoff
  ///
  /// Uses exponential backoff strategy with configurable parameters.
  ///
  /// Example:
  /// ```dart
  /// final result = await RetryHelper.executeWithBackoff(
  ///   () => api.call(),
  ///   maxAttempts: 5,
  ///   initialDelay: Duration(milliseconds: 500),
  ///   maxDelay: Duration(seconds: 30),
  /// );
  /// ```
  static Future<T> executeWithBackoff<T>(
    Future<T> Function() operation, {
    int maxAttempts = 3,
    Duration initialDelay = const Duration(seconds: 1),
    Duration maxDelay = const Duration(seconds: 30),
    double backoffMultiplier = 2.0,
  }) async {
    return execute(
      operation,
      config: RetryConfig(
        maxAttempts: maxAttempts,
        initialDelay: initialDelay,
        maxDelay: maxDelay,
        backoffMultiplier: backoffMultiplier,
      ),
    );
  }

  /// Check if an exception should trigger a retry
  static bool _shouldRetryException(Exception exception, RetryConfig config) {
    // Use custom shouldRetry callback if provided
    if (config.shouldRetry != null) {
      return config.shouldRetry!(exception);
    }

    // Check against retryable exception types if provided
    // 注意：Dart 的 [Type] 对象不支持运行时子类型判断（dart:mirrors 在
    // Flutter 不可用），因此列表只能精确匹配 runtimeType，无法"遍历继承链"。
    // 为满足 C-M13"子类也能重试"的目标，列表未命中时不立即返回 false，
    // 而是继续走下方默认 is 检查——内建异常层次（CloudStorageException 等）
    // 天然覆盖其所有子类；自定义类型层次请用 [RetryConfig.shouldRetry] 回调。
    if (config.retryableExceptions != null) {
      if (config.retryableExceptions!
          .any((type) => exception.runtimeType == type)) {
        return true;
      }
      // 列表未命中：继续走默认 is 检查以覆盖子类场景
    }

    // Default behavior: retry on CloudStorageException but not on auth errors
    if (exception is CloudNotAuthenticatedException) {
      return false;
    }

    if (exception is CloudConfigurationException) {
      return false;
    }

    if (exception is CloudAuthException) {
      return false;
    }

    // P2-9：文件/对象不存在（404）是确定性错误，重试必然再次失败，
    // 不应消耗重试次数与网络往返。
    if (exception is CloudFileNotFoundException) {
      return false;
    }

    if (exception is CloudStorageException) {
      return true;
    }

    // By default, don't retry unknown exceptions
    return false;
  }
}
