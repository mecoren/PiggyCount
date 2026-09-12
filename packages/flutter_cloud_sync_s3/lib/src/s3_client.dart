import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 's3_object_info.dart';
import 's3_signature.dart';
import 's3_exceptions.dart';

export 's3_object_info.dart';

/// S3 REST API 客户端
///
/// 实现基础的 S3 操作：
/// - PutObject: 上传对象
/// - GetObject: 下载对象
/// - DeleteObject: 删除对象
/// - HeadObject: 检查对象是否存在
/// - ListObjectsV2 / ListObjects: 列出对象
///
/// 支持两种寻址方式：
/// - path-style（默认）:      `https://endpoint[:port]/bucket/key`
/// - virtual-hosted-style:   `https://bucket.endpoint[:port]/key`
///
/// 通过 [forcePathStyle] 控制：托管云（AWS/OSS/COS/R2 等）应使用
/// virtual-hosted-style；自托管（MinIO 等）通常使用 path-style。
class S3Client {
  final String endpoint;
  final String region;
  final String accessKey;
  final String secretKey;
  final bool useSSL;
  final int? port;

  /// true 使用 path-style（`/bucket/...`）；false 使用 virtual-hosted-style（`bucket.endpoint/...`）
  final bool forcePathStyle;

  late final S3SignatureV4 _signer;
  late final http.Client _httpClient;

  /// 审计 S22 测试口：暴露签名器以断言时钟偏移写入。
  S3SignatureV4 get signerForTest => _signer;

  /// HTTP 请求超时时间（M-02 修复）
  ///
  /// 所有 S3 API 请求（put/get/delete/head/list）均受此限制，
  /// 防止服务器无响应时同步 UI 无限挂起。超时后抛 [S3NetworkException]。
  ///
  /// P1-2（上轮审计 N12 收口）：固定 30s 对**对象传输**过紧 ——
  /// 实测单账本快照 ~350KB，上行带宽 <117KB/s（移动弱网/跨境网关
  /// 常态）即确定性超时且 putObject 不重试（非幂等纪律），上传必败。
  /// 此值降级为**元数据类操作**（HEAD/list/小对象探测）的默认档；
  /// 对象传输（PUT/GET body）改走 [transferTimeoutFor]，按体积自适应
  /// （30s 基线 + 30s/MB，上限 5min，对齐 StartupSyncChecker._publishTimeout
  /// 的慢速 S3 实测结论）。
  final Duration timeout;

  /// P1-2：对象传输超时上限（对齐启动检查器 _publishTimeout=5min）。
  static const Duration _transferTimeoutCap = Duration(minutes: 5);

  /// P1-2：按传输体积计算对象传输（PUT/GET）超时。
  ///
  /// 基线 30s + 30s/MB，钳制在 [timeout, _transferTimeoutCap] 区间：
  /// - 空对象：30s（与旧行为一致，元数据级请求不受影响）；
  /// - 350KB 快照（弱网 117KB/s）：30+10.5 ≈ 40.5s（旧值 30s 必超）；
  /// - 5MB 大附件：180s（旧值 30s 必超，慢网 5MB 本就该给分钟级）；
  /// - 超大对象：封顶 5min，保留「服务器无响应可恢复」的挂起保护。
  Duration transferTimeoutFor(int contentLength) {
    final sizeMb = contentLength / (1024 * 1024);
    final dynamicMs =
        timeout.inMilliseconds + (sizeMb * 30 * 1000).round();
    return Duration(milliseconds:
        dynamicMs.clamp(timeout.inMilliseconds, _transferTimeoutCap.inMilliseconds));
  }

  /// dispose 标志：避免释放后继续使用导致状态错误
  bool _disposed = false;

  /// P5：重试延迟随机数发生器（jitter 用）。实例级，生命周期与 client 一致。
  final Random _random = Random();

  S3Client({
    required this.endpoint,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.useSSL = true,
    this.port,
    this.forcePathStyle = true,
    this.timeout = const Duration(seconds: 30),
    http.Client? httpClient,
  }) {
    _signer = S3SignatureV4(
      accessKey: accessKey,
      secretKey: secretKey,
      region: region,
    );

    _httpClient = httpClient ?? http.Client();
  }

  /// 释放资源
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _httpClient.close();
  }

  /// 校验未释放：所有公开方法入口调用，防止 dispose 后误用导致
  /// 请求发送到已关闭的 httpClient 或状态混乱
  void _checkDisposed() {
    if (_disposed) {
      throw StateError('S3Client has been disposed');
    }
  }

  /// 审计 S3-M2：ListObjects 翻页页数硬上限。
  ///
  /// 单页服务端上限 1000 对象，1000 页 ≈ 100 万对象，正常桶不会触达。
  /// 故障网关（恒 IsTruncated=true / 回放同一 token / 忽略 marker）下，
  /// 无护栏的 do-while 会无限翻页：流量与请求费用持续耗散、调用方
  /// （探测 / list / 附件清理）永久挂起。触顶即抛 [S3Exception] 显式失败。
  static const int _maxListPages = 1000;

  /// 对幂等操作执行指数退避重试，避免瞬时网络故障导致同步失败
  ///
  /// 仅重试 [S3NetworkException]（瞬时网络故障）和 5xx 服务端错误；
  /// 4xx 客户端错误（认证失败、权限不足、参数错误等）立即抛出，
  /// 避免无意义重试浪费时间和请求配额。
  /// putObject 非幂等（重复写入可能造成数据覆盖语义问题），不使用此方法。
  Future<T> _retry<T>(Future<T> Function() operation,
      {int maxRetries = 3, Set<int> neverRetryStatusCodes = const {}}) async {
    int attempt = 0;
    while (true) {
      try {
        return await operation();
      } on S3ClockSkewException {
        // 审计 S22：时钟偏差——_handleError 已按服务器时间写入签名偏移，
        // 立即用新偏移重试一次。计入 maxRetries 预算（attempt++）：
        // 偏差持续存在时终止循环，避免无限重试。
        await Future.delayed(const Duration(milliseconds: 200));
        attempt++;
        onRetryEvent?.call('时钟偏差补偿后重试（第 $attempt 次）');
        if (attempt >= maxRetries) rethrow;
      } on S3NetworkException {
        // 网络瞬时故障（SocketException/Timeout）可安全重试
        attempt++;
        onRetryEvent?.call('网络瞬时故障，第 $attempt/$maxRetries 次重试');
        if (attempt >= maxRetries) rethrow;
        // P5：指数退避 + jitter（1s/2s/4s 的 50%~100% 区间）
        await Future.delayed(retryDelayForTest(attempt));
      } on S3Exception catch (e) {
        // 5xx 状态码表示服务端临时错误，可重试；
        // 审计 S3-M3：neverRetryStatusCodes 中的状态码（如 501 Not
        // Implemented）是**确定性**失败，重试只会白耗退避延迟——调用方
        // （listObjectsDetailed）需要它立即上抛以走 V1 协议回退。
        final status = e.statusCode;
        final neverRetry =
            status != null && neverRetryStatusCodes.contains(status);
        if (!neverRetry &&
            status != null &&
            status >= 500 &&
            status < 600) {
          attempt++;
          onRetryEvent?.call('服务端 $status 错误，第 $attempt/$maxRetries 次重试');
          if (attempt >= maxRetries) rethrow;
          await Future.delayed(retryDelayForTest(attempt));
        } else {
          rethrow;
        }
      }
    }
  }

  /// P5：指数退避 + jitter（base 的 50%~100%），防止多设备在瞬时故障
  /// 后同一时刻集中重试形成 thundering herd（同步重试风暴）。
  /// attempt 从 1 起：base = 2^(attempt-1) 秒，返回 [base/2, base] 区间。
  ///
  /// 注：putObject 维持不重试——非幂等 + A-1 覆盖竞态未修，重试旧快照
  /// 会覆盖新数据，故此方法只供幂等 GET/HEAD/DELETE/LIST 用。
  /// 方法名 ForTest 后缀为测试专用约定（不依赖 @visibleForTesting 注解，
  /// 避免引入 foundation/meta 包级依赖）。
  Duration retryDelayForTest(int attempt, [Random? rng]) {
    final random = rng ?? _random;
    final baseMs = (1 << (attempt - 1)) * 1000;
    return Duration(
        milliseconds: baseMs ~/ 2 + random.nextInt(baseMs ~/ 2 + 1));
  }

  /// 网关条件写能力探测缓存（S3-W2 能力记忆）：
  /// null = 未知（尚未探测）；true = 已确认网关不支持条件头。
  ///
  /// 部分 S3 兼容网关（某些第三方对象存储）对 If-Match/If-None-Match
  /// 返回 400 + NotImplemented。首次踩坑后记忆该能力，后续上传直接
  /// 盲写（写后由 manager 的 verifyAfterUpload 兜底并发覆盖检测），
  /// 不再每次上传都白付一次失败往返。S3Client 生命周期与 provider 一致
  /// （S3Provider.initialize 重建 client 时自然重置，后端更换后重新探测）。
  bool? _conditionalWriteUnsupported;

  /// 测试口：暴露条件写能力缓存（断言降级记忆 / 重置）。
  bool? get conditionalWriteUnsupportedForTest => _conditionalWriteUnsupported;

  /// 降级回调（可选）：条件头降级为盲写时通知上层记 warning 日志。
  /// S3Client 自身不依赖日志设施（包保持零 Flutter/日志依赖），由
  /// S3StorageService 在构造时注入。
  void Function(String message)? onConditionalWriteDowngrade;

  /// LOG-02：协议级事件回调（可选）—— V2→V1 回退、时钟偏差补偿等
  /// 「继续工作但环境异常」的关键线索。S3Client 不依赖日志设施，
  /// 由 S3StorageService 构造时注入；未注入时静默（测试无感）。
  void Function(String message)? onProtocolEvent;

  /// LOG-06（P1-1 配套）：重试事件回调（可选）—— 幂等读重试与条件 PUT
  /// 安全重试的逐次痕迹。弱网排障时区分「一次成功」与「重试后成功」
  /// 依赖此回调；未注入时静默。
  void Function(String message)? onRetryEvent;

  /// PUT Object - 上传文件
  ///
  /// [metadata] 中的 key-value 对会作为 `x-amz-meta-{key}` 头发送，
  /// 供后续 HeadObject/GetMetadata 读取（C-01 修复）。
  ///
  /// 方案C（并发全面加固）条件写：
  /// - [ifMatch] 非空时携带 `If-Match: "<etag>"`（RFC 7232 引号形态），
  ///   仅当远端当前对象 ETag 与之相等才写入；不匹配返回 412 → 抛
  ///   [S3PreconditionFailedException]
  /// - [ifNoneMatch] 为 true 时携带 `If-None-Match: *`（create-only），
  ///   远端已存在同 key 对象时同样 412。与 [ifMatch] 互斥。
  ///
  /// 条件写的其余失败形态同样翻译为 [S3PreconditionFailedException]
  /// （本次写入均未落盘，语义一致）：
  /// - **404**：远端对象不存在。AWS 对 If-Match 无当前版本/仅有删除
  ///   标记的对象返回 404 NoSuchKey（MinIO 同），即「条件失败」而非
  ///   普通存储错误 —— 上层契约要求「远端不存在同样算条件失败」。
  /// - **409 ConditionalRequestConflict**：瞬时竞态，AWS 明确要求
  ///   「retry the upload」。写入未落盘、前置条件不变，重发安全；
  ///   有限重试（2 次）后仍冲突则按条件失败上抛走冲突流程。
  ///
  /// 返回服务端响应的 ETag（网关未返回时为 null），供写后校验使用。
  ///
  /// 盲写（无 If-Match/If-None-Match）不自动重试 —— 非幂等且 A-1 覆盖
  /// 竞态未修，重试旧快照会覆盖新数据，由写后校验兜底；
  /// 条件 PUT 例外（P1-1）：超时/断连时按 If-Match 锚点安全重试 ≤2 次
  ///（远端已落盘则重试吃 412 转冲突流程，不丢他机数据）。
  /// 条件写失败（412/404）更不可重试 —— 重试必然再次失败或造成覆盖。
  Future<String?> putObject({
    required String bucket,
    required String key,
    required Uint8List data,
    String? contentType,
    Map<String, String>? metadata,
    String? ifMatch,
    bool ifNoneMatch = false,
  }) async {
    _checkDisposed();
    if (ifMatch != null && ifNoneMatch) {
      throw ArgumentError('ifMatch 与 ifNoneMatch 互斥，不能同时传入');
    }
    // S3-W2 能力记忆：首次 400+NotImplemented 降级后，后续上传直接
    // 盲写，省掉每次一失败往返（写后校验仍兜底并发覆盖检测）
    if (_conditionalWriteUnsupported == true) {
      ifMatch = null;
      ifNoneMatch = false;
    }
    final uri = _buildUri(bucket, key: key);

    var headers = _signedPutHeaders(uri, data, contentType, metadata,
        ifMatch: ifMatch, ifNoneMatch: ifNoneMatch);

    // M9：时钟偏差（RequestTimeTooSkewed）时服务器**没有处理本次请求**
    // （403 拒签），与「超时但服务端已写入」的 A-1 覆盖竞态本质不同 ——
    // _handleError 已按服务器时间写入签名偏移，立即用新偏移重发是安全的，
    // 不违反 putObject 的不重试纪律。偏差最多重试 2 次，持续偏差向上抛。
    var skewRetries = 0;
    // 审计 M2：409 ConditionalRequestConflict 同理 —— 服务器未落盘本次
    // 写入，重发同一前置条件安全；最多重试 2 次，仍冲突按条件失败上抛。
    var conflictRetries = 0;
    // P1-1（2026-09-09）：条件 PUT 的瞬时网络故障安全重试计数（超时/
    // 断连）。安全性由 If-Match 锚点保证（见 on SocketException 分支
    // 注释）；盲写不重试。
    var netRetries = 0;
    // 网关能力探测：部分 S3 兼容网关（如某些 MinIO 旧版/第三方对象存储）
    // 不支持 If-Match/If-None-Match 条件头，返回 400 + NotImplemented。
    // 服务器未处理本次请求（未落盘），去掉条件头重发是安全的；盲写后由
    // 上层 manager 的写后校验（verifyAfterUpload）兜底并发覆盖检测。
    var conditionalDropped = false;
    while (true) {
      try {
        // P1-2：PUT 按体积自适应超时（350KB 快照在弱网 117KB/s 下
        // 旧固定 30s 必超时；见 transferTimeoutFor）
        final response = await _httpClient
            .put(uri, headers: headers, body: data)
            .timeout(transferTimeoutFor(data.length));

        if (response.statusCode != 200 && response.statusCode != 204) {
          // 方案C：条件写失败（远端已被其他设备先行修改/创建），
          // 本次写入未落盘，翻译为专属异常供上层走冲突流程
          if (response.statusCode == 412) {
            throw S3PreconditionFailedException(key,
                message: '条件写失败（远端已被其他设备修改）: $key');
          }
          // 网关不支持条件头：400 + NotImplemented（错误体含
          // "A header you provided implies functionality that is not
          // implemented"）。仅在携带条件头时判定，且只降级一次，
          // 防止把无关 400（如签名错误）误判为条件写不支持。
          if (response.statusCode == 400 &&
              (ifMatch != null || ifNoneMatch) &&
              !conditionalDropped &&
              _isConditionalHeaderNotSupported(response)) {
            conditionalDropped = true;
            // S3-W2 能力记忆 + warning 线索：此前每次上传都重新踩一遍
            // 坑（先发条件写、吃 400、再盲写），且静默降级排查无痕迹。
            // 首次确认后记忆能力并回调日志，后续 putObject 入口直接盲写。
            _conditionalWriteUnsupported = true;
            onConditionalWriteDowngrade?.call(
                'S3 网关不支持条件写（If-Match/If-None-Match 返回 400 '
                'NotImplemented），本次降级为盲写+写后校验，本会话后续上传'
                '直接走盲写: bucket=$bucket key=$key');
            ifMatch = null;
            ifNoneMatch = false;
            headers = _signedPutHeaders(uri, data, contentType, metadata);
            continue;
          }
          // 审计 A5：PUT 路径的桶级 404（NoSuchBucket）也要区分出来，
          // 不能落进 _handleError 的通用 404 分支丢失语义
          if (response.statusCode == 404) {
            _throwIfNoSuchBucket('PutObject', response, bucket);
            // 方案C 契约补全：条件写时远端对象不存在（并发删除先完成，
            // AWS/MinIO 对 If-Match 无当前版本返回 404 NoSuchKey）——
            // 同样是「前置条件失败、写入未落盘」，必须翻译为冲突语义，
            // 否则上层把核心并发竞态当普通存储故障处理
            final isConditional = ifMatch != null || ifNoneMatch;
            if (isConditional) {
              throw S3PreconditionFailedException(key,
                  message: '条件写失败（远端不存在，可能已被其他设备删除）: $key');
            }
          }
          // 审计 M2：409 ConditionalRequestConflict 是瞬时竞态（AWS：
          // 「On a 409 failure, retry the upload」），有限重试后仍冲突
          // 则按条件失败上抛
          if (response.statusCode == 409 &&
              (ifMatch != null || ifNoneMatch)) {
            conflictRetries++;
            if (conflictRetries <= 2) {
              await Future.delayed(
                  Duration(milliseconds: 200 * conflictRetries));
              continue;
            }
            throw S3PreconditionFailedException(key,
                message: '条件写失败（HTTP 409 冲突持续存在）: $key');
          }
          _handleError('PutObject', response);
        }
        return _normalizeEtag(response.headers['etag']);
      } on S3PreconditionFailedException {
        rethrow;
      } on S3ClockSkewException {
        skewRetries++;
        if (skewRetries > 2) rethrow;
        await Future.delayed(const Duration(milliseconds: 200));
        // 用更新后的偏移重新签名再发
        headers = _signedPutHeaders(uri, data, contentType, metadata,
            ifMatch: ifMatch, ifNoneMatch: ifNoneMatch);
      } on SocketException catch (e) {
        // P1-1（2026-09-09）：仅条件 PUT 有限安全重试。带 If-Match 锚点时
        // 「超时但服务端已落盘」的 A-1 歧态由锚点化解：远端 ETag 已变 →
        // 重试吃 412 → 翻译为冲突流程，绝不静默覆盖他机数据；未落盘则
        // 重试正常完成。盲写路径维持不重试纪律（A-1 未修，写后校验兜底）。
        if ((ifMatch != null || ifNoneMatch) && netRetries < 2) {
          netRetries++;
          onRetryEvent?.call(
              'PutObject(conditional) 网络错误，第 $netRetries/2 次安全重试: '
              '${e.message}');
          await Future.delayed(retryDelayForTest(netRetries));
          continue;
        }
        throw S3NetworkException('Network error: ${e.message}',
            originalException: e);
      } on TimeoutException {
        if ((ifMatch != null || ifNoneMatch) && netRetries < 2) {
          netRetries++;
          onRetryEvent?.call(
              'PutObject(conditional) 超时，第 $netRetries/2 次安全重试'
              '（当前预算 ${transferTimeoutFor(data.length).inSeconds}s）');
          await Future.delayed(retryDelayForTest(netRetries));
          continue;
        }
        throw S3NetworkException(
            'PutObject timed out after ${transferTimeoutFor(data.length).inSeconds}s');
      } catch (e) {
        if (e is S3Exception) rethrow;
        throw S3Exception('PutObject failed: $e',
            originalException: _asException(e));
      }
    }
  }

  /// 竞速哨兵：putObjectStream 中标识「源流已全部泵入请求体」。
  static final Object _pumpCompletedSentinel = Object();

  /// M4 修复：流式上传对象（大文件内存友好）。
  ///
  /// 与 [putObject] 的区别：body 以 [data] 边读边发，调用方（如本地
  /// 文件上传）不再需要把整个对象读入内存。签名改用
  /// `x-amz-content-sha256: UNSIGNED-PAYLOAD` —— SigV4 要求预知完整
  /// payload 的 SHA-256，流式 body 无法预计算，改只签头部不签 body
  /// （AWS 及 MinIO/OSS/COS/R2 等主流 S3 兼容服务均支持）。
  ///
  /// [contentLength] 可选：已知总长度时传入，请求以固定 Content-Length
  /// 发送（兼容性最好）；null 时传输层自动降级 chunked encoding。
  /// 注意 Content-Length 不参与签名（审计 S-A 口径），由传输层附加。
  ///
  /// 重试纪律（与 [putObject] 的差异，调用方务必知悉）：
  /// - 时钟偏差（RequestTimeTooSkewed）：[_handleError] 会写入新偏移并
  ///   抛 [S3ClockSkewException]，但**流式 body 不可重放**，本方法不
  ///   自动重试 —— 上层用新流重调本方法即自动获得补偿后的签名。
  /// - 409 ConditionalRequestConflict：同样不重试，直接按条件失败抛
  ///   [S3PreconditionFailedException]。
  ///
  /// [data] 中途失败（读文件/网络错误）→ 抛 [S3Exception]；S3 PutObject
  /// 原子性保证不会产生部分对象。条件写语义（412/404 → 条件失败）与
  /// [putObject] 完全一致。
  Future<String?> putObjectStream({
    required String bucket,
    required String key,
    required Stream<List<int>> data,
    int? contentLength,
    String? contentType,
    Map<String, String>? metadata,
    String? ifMatch,
    bool ifNoneMatch = false,
  }) async {
    _checkDisposed();
    if (ifMatch != null && ifNoneMatch) {
      throw ArgumentError('ifMatch 与 ifNoneMatch 互斥，不能同时传入');
    }
    // S3-W2 能力记忆：与 putObject 同款——已确认不支持的网关直接盲写，
    // 避免流式路径每次上传白付一次 400 失败往返（流式 body 不可重放，
    // 首次 400 后调用方须用新流重调，代价更高）
    if (_conditionalWriteUnsupported == true) {
      ifMatch = null;
      ifNoneMatch = false;
    }
    final uri = _buildUri(bucket, key: key);
    final headers = _signedStreamingPutHeaders(uri, contentType, metadata,
        ifMatch: ifMatch, ifNoneMatch: ifNoneMatch);

    final request = http.StreamedRequest('PUT', uri);
    request.headers.addAll(headers);
    // S3P-04：contentLength == 0 时也显式设置 —— 0 是合法的
    // Content-Length（空对象），不设置会让传输层退化 chunked
    // encoding，部分严格 S3 网关对 PUT 拒绝 chunked（400/411）。
    if (contentLength != null && contentLength >= 0) {
      request.contentLength = contentLength;
    }

    final pumpDone = Completer<void>();
    var sinkClosed = false;
    void closeSink() {
      if (!sinkClosed) {
        sinkClosed = true;
        request.sink.close();
      }
    }

    http.StreamedResponse response;
    StreamSubscription<List<int>>? sub;
    try {
      final responseFuture = _httpClient.send(request);
      // 让出事件循环：确保 client 的同步 finalize 段已执行
      // （IOClient.send 首行 finalize 请求体流），此后泵入的数据直接
      // 流向传输层 —— 顺序颠倒会让整个大文件缓冲进无读者的控制器。
      await Future<void>.delayed(Duration.zero);

      sub = data.listen(
        (chunk) {
          if (!sinkClosed) request.sink.add(chunk);
        },
        onDone: () {
          closeSink();
          pumpDone.complete();
        },
        onError: (Object e, StackTrace st) {
          closeSink();
          pumpDone.completeError(e, st);
        },
        cancelOnError: true,
      );

      // 竞速：正常路径「body 全部发出」（泵完成）后服务器才响应；
      // 但条件写失败（412/409）等场景服务器可能在读完全部 body 前
      // 早响应 —— 此时必须停止泵，避免无消费者的请求体在内存中
      // 无限堆积（违背流式初衷）。
      //
      // S3P-02：竞速本身必须有超时 —— 源流停滞（磁盘慢读/上游卡死
      // 不发数据也不结束）且网关半开不回响应头时，Future.any 永久
      // 阻塞，与 M-02「所有请求受超时约束」的纪律相悖。两路各自
      // 套 transferTimeoutFor(contentLength)（P1-2 体积自适应档）：
      // 源流停滞按传输时长判死，首响应超时同理；任一路超时都取消
      // 泵/清理后抛 S3NetworkException。
      //
      // N-11：contentLength 缺省（chunked 传输）时按保守上限档
      // （5min cap）计算 —— `?? 0` 会按 0 字节档（30s 基线）判死，
      // 大文件弱网流式上传确定性超时。传入超上限体积的字节数，
      // transferTimeoutFor 的 clamp 保证结果就是 _transferTimeoutCap。
      final streamTimeout =
          contentLength ?? _transferTimeoutCap.inMilliseconds * 1024 ~/ 30;
      final effectiveTimeout = transferTimeoutFor(streamTimeout);
      final first = await Future.any<Object?>([
        pumpDone.future.then<Object?>((_) => _pumpCompletedSentinel),
        responseFuture
            .then<Object?>((r) => r)
            .timeout(effectiveTimeout, onTimeout: () => throw TimeoutException(
                'PutObjectStream response timed out after '
                '${effectiveTimeout.inSeconds}s')),
      ]).timeout(effectiveTimeout, onTimeout: () => throw TimeoutException(
          'PutObjectStream source stream stalled for '
          '${effectiveTimeout.inSeconds}s'));
      if (!identical(first, _pumpCompletedSentinel)) {
        // 服务器早于泵完成响应：停止泵，吞掉泵的伴生结果
        await sub.cancel();
        sub = null;
        closeSink();
        unawaited(pumpDone.future.catchError((Object _) {}));
        response = first as http.StreamedResponse;
      } else {
        // 泵完成（body 已全部发出）→ 等服务器处理响应。
        // P1-2：按体积自适应（流式上传多为大附件，旧固定 30s 在
        // 慢网大对象下，body 发完后服务端落盘+响应的时间窗口不够）
        final effectiveTimeout = transferTimeoutFor(streamTimeout);
        response = await responseFuture.timeout(effectiveTimeout);
      }
    } on Object catch (e) {
      await sub?.cancel();
      closeSink();
      // 源流失败是根因：泵已以错误完成时优先上报源流错误
      if (pumpDone.isCompleted) {
        try {
          await pumpDone.future;
        } on Object catch (sourceError) {
          throw S3Exception('PutObjectStream 上传数据流中途失败: $sourceError',
              originalException:
                  sourceError is Exception ? sourceError : null);
        }
      }
      if (e is TimeoutException) {
        throw S3NetworkException(
            'PutObjectStream timed out after '
            '${transferTimeoutFor(contentLength ?? 10 * 1024 * 1024).inSeconds}s');
      }
      throw S3Exception('PutObjectStream failed: $e',
          originalException: e is Exception ? e : null);
    }

    try {
      if (response.statusCode == 200 || response.statusCode == 204) {
        // N-14：成功路径消费掉 body 流 —— 2xx 直接 return 会让
        // StreamedResponse.bodyStream 处于无读者状态，keep-alive 连接
        // 无法回池被弃置，高频流式上传时连接复用率下降。
        unawaited(response.stream.drain<void>().catchError((Object _) {}));
        return _normalizeEtag(response.headers['etag']);
      }
      if (response.statusCode == 412) {
        throw S3PreconditionFailedException(key,
            message: '条件写失败（远端已被其他设备修改）: $key');
      }
      if (response.statusCode == 404) {
        // 早响应时 body 可能已被服务器截断，尽力解析桶级错误
        final body = await _readErrorBody(response);
        if (body != null) _throwIfNoSuchBucket('PutObject', body, bucket);
        if (ifMatch != null || ifNoneMatch) {
          throw S3PreconditionFailedException(key,
              message: '条件写失败（远端不存在，可能已被其他设备删除）: $key');
        }
        if (body != null) _handleError('PutObject', body);
        throw S3Exception('PutObject failed (HTTP 404, no error body)',
            statusCode: 404);
      }
      if (response.statusCode == 409 && (ifMatch != null || ifNoneMatch)) {
        // 流式 body 不可重放：不自动重试，直接按条件失败上抛
        throw S3PreconditionFailedException(key,
            message: '条件写失败（HTTP 409 冲突）: $key');
      }
      // S3-W2：400 + NotImplemented 特征（网关不支持条件头）时记忆能力，
      // 流式 body 不可重放——记忆后上抛，调用方用新流重调本方法时
      // 入口即直接走盲写，不再吃第二次 400。
      if (response.statusCode == 400 &&
          (ifMatch != null || ifNoneMatch) &&
          _conditionalWriteUnsupported != true) {
        final body = await _readErrorBody(response);
        if (body != null && _isConditionalHeaderNotSupported(body)) {
          _conditionalWriteUnsupported = true;
          onConditionalWriteDowngrade?.call(
              'S3 网关不支持条件写（If-Match/If-None-Match 返回 400 '
              'NotImplemented），已记忆为盲写模式（流式 body 不可重放，'
              '请用新流重调）: bucket=$bucket key=$key');
        }
        if (body != null) _handleError('PutObject', body);
        throw S3Exception(
          'PutObject failed (HTTP ${response.statusCode}, no conditional support)',
          statusCode: response.statusCode,
        );
      }
      final body = await _readErrorBody(response);
      if (body != null) _handleError('PutObject', body);
      throw S3Exception(
        'PutObject failed (HTTP ${response.statusCode}, no error body)',
        statusCode: response.statusCode,
      );
    } on S3PreconditionFailedException {
      rethrow;
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}',
          originalException: e);
    } on S3Exception {
      rethrow;
    } catch (e) {
      if (e is S3Exception) rethrow;
      throw S3Exception('PutObject failed: $e',
          originalException: _asException(e));
    }
  }

  /// 读取错误响应体。早响应/断连时 body 流可能不可读 —— 返回 null，
  /// 调用方改抛不依赖 body 的语义化异常。
  Future<http.Response?> _readErrorBody(http.StreamedResponse response) async {
    try {
      return await http.Response.fromStream(response).timeout(timeout);
    } catch (_) {
      return null;
    }
  }

  /// 判断 400 响应是否为「网关不支持条件头」特征（S3 兼容网关的
  /// NotImplemented 语义）。匹配错误体关键字而非依赖具体错误码字段，
  /// 因为第三方网关的 XML 错误体形态各异（Code/Message 大小写不齐）。
  ///
  /// N-7 修复（2026-09-12）：裸 `notimplemented` 子串不再单独命中 ——
  /// 任何 400 错误体恰含该字样（如网关把「不支持某 x-amz-meta 头」也
  /// 报 NotImplemented）都会让 `_conditionalWriteUnsupported` 被误记，
  /// 此后本 client 全生命周期静默盲写（无 TTL 无复试探针）。收紧为：
  /// NotImplemented/Not Implemented 语义必须**配合条件头关键词**
  /// （if-match / if-none-match / a header you provided）同时出现才判定。
  bool _isConditionalHeaderNotSupported(http.Response response) {
    final body = response.body;
    if (body.isEmpty) return false;
    final lower = body.toLowerCase();
    final notImplemented = lower.contains('notimplemented') ||
        lower.contains('not implemented');
    if (!notImplemented) return false;
    return lower.contains('if-match') ||
        lower.contains('if-none-match') ||
        lower.contains('a header you provided');
  }

  /// 构造并签名流式 PUT 请求头。
  ///
  /// 与 [_signedPutHeaders] 的差异：payload 以
  /// `x-amz-content-sha256: UNSIGNED-PAYLOAD` 声明（流式 body 无法
  /// 预计算 SHA-256）；其余（metadata 编码 / If-Match 归一化 / Host /
  /// Content-Type）完全一致。
  Map<String, String> _signedStreamingPutHeaders(
      Uri uri, String? contentType, Map<String, String>? metadata,
      {String? ifMatch, bool ifNoneMatch = false}) {
    final headers = <String, String>{
      'Host': uri.authority,
      'Content-Type': contentType ?? 'application/octet-stream',
    };
    if (ifMatch != null) {
      final bare = _normalizeEtag(ifMatch) ?? ifMatch;
      headers['If-Match'] = '"$bare"';
    }
    if (ifNoneMatch) {
      headers['If-None-Match'] = '*';
    }
    if (metadata != null) {
      for (final entry in metadata.entries) {
        headers['x-amz-meta-${entry.key.toLowerCase()}'] =
            _encodeMetaValue(entry.value);
      }
    }
    return _signer.sign(
      method: 'PUT',
      uri: uri,
      headers: headers,
      payloadHashOverride: 'UNSIGNED-PAYLOAD',
    );
  }

  /// 构造并签名 PUT 请求头（M9：时钟偏差重试需用新偏移重签）。
  ///
  /// C-01 修复：将自定义 metadata 转为 x-amz-meta-* 头。
  /// 非 ASCII 值（如中文账本名）直接作为 HTTP 头值会触发 RFC 7230
  /// 校验异常（FormatException: Invalid HTTP header field value），
  /// 请求根本发不出去。故统一 base64 编码并加 'b64:' 前缀标记，
  /// 读取端 [_decodeMetaValue] 自动还原，对所有 S3 兼容服务通用。
  ///
  /// metadata 键统一小写：HTTP 头名大小写不敏感，传输层（dart:io /
  /// package:http）会把响应头名转小写，读取端拿到的键恒为小写形态。
  /// 写入端显式小写使键的存储形态确定，避免依赖各网关对大小写的
  /// 保留行为。
  ///
  /// 审计 S-A 修复：Content-Length 不再参与签名。AWS 官方 SDK 不签 CL，
  /// 一旦传输层改用 chunked 编码或代理改写 CL，签了 CL 就恒定
  /// 403 SignatureDoesNotMatch。Host/Content-Type/x-amz-* 保持参与。
  Map<String, String> _signedPutHeaders(Uri uri, Uint8List data,
      String? contentType, Map<String, String>? metadata,
      {String? ifMatch, bool ifNoneMatch = false}) {
    final headers = <String, String>{
      'Host': uri.authority,
      'Content-Type': contentType ?? 'application/octet-stream',
    };
    if (ifMatch != null) {
      // 审计 M3：RFC 7232 要求 If-Match 值为带引号的 entity-tag。
      // AWS 接受裸值，但部分严格兼容网关会回 400 InvalidArgument；
      // 统一归一化（剥引号/弱验证器前缀）后加引号最稳，且与
      // _normalizeEtag 的返回形态（裸值）形成对称往返。
      final bare = _normalizeEtag(ifMatch) ?? ifMatch;
      headers['If-Match'] = '"$bare"';
    }
    if (ifNoneMatch) {
      headers['If-None-Match'] = '*';
    }
    if (metadata != null) {
      for (final entry in metadata.entries) {
        headers['x-amz-meta-${entry.key.toLowerCase()}'] =
            _encodeMetaValue(entry.value);
      }
    }
    return _signer.sign(
      method: 'PUT',
      uri: uri,
      headers: headers,
      payloadBytes: data,
    );
  }

  /// P1-2：非流式对象下载（getObject）专用超时档。
  ///
  /// getObject 一次性把整个对象读入内存（快照 JSON，KB~数 MB 级；
  /// 大文件下载走 [downloadStream] 流式路径，不受此影响）。旧固定
  /// 30s 在 117KB/s 弱网下仅支持 ~350KB；90s 支持到 ~10MB，覆盖
  /// 万笔级账本快照的慢网下载。元数据类操作（HEAD/LIST/DELETE）与
  /// 探测仍用 [timeout]（30s），挂起保护不弱化。
  static const Duration _getObjectTimeout = Duration(seconds: 90);

  /// GET Object - 下载文件（幂等，自动重试瞬时网络故障）
  Future<Uint8List> getObject({
    required String bucket,
    required String key,
  }) async {
    _checkDisposed();
    final uri = _buildUri(bucket, key: key);

    return _retry(() async {
      // 每次尝试都重新签名：时钟偏差补偿（_handleError 已把服务器时间差
      // 写入 signer.clockOffset）后，重试请求必须携带新 x-amz-date 的签名。
      // 若复用外层旧签名，真实服务端会再次 403 RequestTimeTooSkewed，
      // 补偿形同虚设（与 listObjectsV2/V1 在闭包内重建 headers 同理）。
      final headers = _signedHeaders(uri, 'GET');
      try {
        final response = await _httpClient
            .get(uri, headers: headers)
            .timeout(_getObjectTimeout);

        if (response.statusCode == 200) {
          return response.bodyBytes;
        } else if (response.statusCode == 404) {
          // 审计 A5：404 需区分「对象不存在」与「桶不存在」——
          // 桶配错时抛 S3ObjectNotFoundException 会误导上层按
          // 「云端无备份」处理，排查方向完全错误。
          _throwIfNoSuchBucket('GetObject', response, bucket);
          throw S3ObjectNotFoundException(key);
        }
        _handleError('GetObject', response);
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}', originalException: e);
      } on TimeoutException {
        // N-11：报实际超时档（_getObjectTimeout=90s），非元数据档 timeout（30s）
        throw S3NetworkException('GetObject timed out after ${_getObjectTimeout.inSeconds}s');
      } on S3Exception {
        rethrow;
      } catch (e) {
        throw S3Exception('GetObject failed: $e', originalException: _asException(e));
      }
    });
  }

  /// M5 修复：流式下载对象（大文件内存友好）。
  ///
  /// 与 [getObject] 的区别：返回 [Stream]，调用方边收边处理（如直接
  /// 落盘），不再需要把整个对象读入内存。
  ///
  /// 超时语义分两段：
  /// - **首字节**（响应头到达）：受 [timeout] 约束，超时抛
  ///   [S3NetworkException]，且此阶段失败（网络/5xx/时钟偏差）可安全
  ///   自动重试（响应体尚未交给调用方，重发无副作用）；
  /// - **消费期**：响应流交给调用方后不做总超时（大文件传输时长无法
  ///   预知），但按 chunk 间隔检测停滞 —— 超过 [stallTimeout]（默认
  ///   `timeout * 4`）未收到任何新数据视为连接僵死，向流注入
  ///   [S3NetworkException] 并终止。
  ///
  /// 404 抛 [S3ObjectNotFoundException]（桶级 404 抛
  /// [S3BucketNotFoundException]）；其余错误同 [getObject] 语义。
  /// 消费期错误透传（可能为 [S3NetworkException] 或底层 I/O 异常），
  /// 不自动重试 —— 调用方已可能消费部分数据。
  Future<Stream<List<int>>> downloadStream({
    required String bucket,
    required String key,
    Duration? stallTimeout,
  }) async {
    _checkDisposed();
    final uri = _buildUri(bucket, key: key);

    return _retry(() async {
      // 每次尝试重新签名（时钟偏差补偿后旧签名必然再次 403，见 getObject）
      final headers = _signedHeaders(uri, 'GET');
      try {
        final response = await _httpClient
            .send(http.Request('GET', uri)..headers.addAll(headers))
            .timeout(timeout);

        if (response.statusCode == 200) {
          final effectiveStall = stallTimeout ?? timeout * 4;
          return response.stream.timeout(effectiveStall, onTimeout: (sink) {
            sink.addError(S3NetworkException(
                '下载流停滞超过 ${effectiveStall.inSeconds}s，连接可能已中断'));
            sink.close();
          });
        } else if (response.statusCode == 404) {
          final body = await _readErrorBody(response);
          if (body != null) _throwIfNoSuchBucket('GetObject', body, bucket);
          throw S3ObjectNotFoundException(key);
        }
        final body = await _readErrorBody(response);
        if (body != null) _handleError('GetObject', body);
        throw S3Exception(
          'GetObject failed (HTTP ${response.statusCode}, no error body)',
          statusCode: response.statusCode,
        );
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}',
            originalException: e);
      } on TimeoutException {
        throw S3NetworkException(
            'GetObject timed out after ${timeout.inSeconds}s');
      } on S3Exception {
        rethrow;
      } catch (e) {
        throw S3Exception('GetObject failed: $e',
            originalException: _asException(e));
      }
    });
  }

  /// DELETE Object - 删除文件（幂等，自动重试瞬时网络故障）
  Future<void> deleteObject({
    required String bucket,
    required String key,
  }) async {
    _checkDisposed();
    final uri = _buildUri(bucket, key: key);

    await _retry(() async {
      // 每次尝试重新签名（时钟偏差补偿后旧签名必然再次 403，见 getObject）
      final headers = _signedHeaders(uri, 'DELETE');
      try {
        final response = await _httpClient
            .delete(uri, headers: headers)
            .timeout(timeout);

        if (response.statusCode != 204 && response.statusCode != 200) {
          // 404 也算成功（对象已不存在）；但桶级 404（NoSuchBucket）是
          // 配置错误，不能静默当成功吞掉（审计 A5）
          if (response.statusCode != 404) {
            _handleError('DeleteObject', response);
          } else {
            _throwIfNoSuchBucket('DeleteObject', response, bucket);
          }
        }
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}', originalException: e);
      } on TimeoutException {
        throw S3NetworkException('DeleteObject timed out after ${timeout.inSeconds}s');
      } on S3Exception {
        rethrow;
      } catch (e) {
        throw S3Exception('DeleteObject failed: $e', originalException: _asException(e));
      }
    });
  }

  /// HEAD Object - 检查文件是否存在（幂等，自动重试瞬时网络故障）
  ///
  /// 仅在对象存在（200）时返回 true，对象不存在（404）时返回 false。
  /// 其他状态码（403/500 等）和网络错误会抛出 [S3Exception]，避免
  /// 调用方把「权限不足」「网络中断」误判为「文件不存在」而触发
  /// 覆盖上传等危险操作。
  Future<bool> headObject({
    required String bucket,
    required String key,
  }) async {
    _checkDisposed();
    final uri = _buildUri(bucket, key: key);

    return _retry(() async {
      // 每次尝试重新签名（时钟偏差补偿后旧签名必然再次 403，见 getObject）
      final headers = _signedHeaders(uri, 'HEAD');
      try {
        final response = await _httpClient
            .head(uri, headers: headers)
            .timeout(timeout);
        if (response.statusCode == 200) return true;
        if (response.statusCode == 404) return false;
        // 其他状态码（403/500 等）是真实错误，不能误判为「不存在」
        _handleError('HeadObject', response);
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}', originalException: e);
      } on TimeoutException {
        throw S3NetworkException('HeadObject timed out after ${timeout.inSeconds}s');
      } on S3Exception {
        rethrow;
      } catch (e) {
        throw S3Exception('HeadObject failed: $e', originalException: _asException(e));
      }
    });
  }

  /// HEAD Object 并返回完整元信息（size / lastModified / contentType / metadata）
  ///
  /// 与 [headObject] 的区别：返回 [S3HeadInfo] 携带 Content-Length、
  /// Last-Modified、自定义元数据（x-amz-meta-*）等响应头，
  /// 供 [S3StorageService.getMetadata] 使用。
  ///
  /// C-01 修复：解析 x-amz-meta-* 响应头，使 CloudSyncManager 能通过
  /// metadata 中的 fingerprint 直接判断同步状态，避免全量下载。
  ///
  /// 对象不存在（404）返回 [S3HeadInfo.notFound]（exists=false）。
  /// 其他错误抛 [S3Exception]。
  Future<S3HeadInfo> headObjectWithMetadata({
    required String bucket,
    required String key,
  }) async {
    _checkDisposed();
    final uri = _buildUri(bucket, key: key);

    return _retry(() async {
      // 每次尝试重新签名（时钟偏差补偿后旧签名必然再次 403，见 getObject）
      final headers = _signedHeaders(uri, 'HEAD');
      try {
        final response = await _httpClient
            .head(uri, headers: headers)
            .timeout(timeout);
        if (response.statusCode == 200) {
          return S3HeadInfo(
            exists: true,
            size: int.tryParse(response.headers['content-length'] ?? ''),
            lastModified: _parseHttpDate(response.headers['last-modified']),
            contentType: response.headers['content-type'],
            metadata: _extractCustomMetadata(response.headers),
            eTag: _normalizeEtag(response.headers['etag']),
          );
        }
        if (response.statusCode == 404) {
          return S3HeadInfo.notFound;
        }
        _handleError('HeadObject', response);
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}', originalException: e);
      } on TimeoutException {
        throw S3NetworkException('HeadObject timed out after ${timeout.inSeconds}s');
      } on S3Exception {
        rethrow;
      } catch (e) {
        throw S3Exception('HeadObject failed: $e', originalException: _asException(e));
      }
    });
  }

  /// 解析 HTTP 日期头（RFC 1123 格式，如 "Wed, 21 Oct 2015 07:28:00 GMT"）
  DateTime? _parseHttpDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return null;
    try {
      return HttpDate.parse(dateStr);
    } catch (_) {
      return null;
    }
  }

  /// LIST Objects - 列出对象
  ///
  /// 优先使用 ListObjectsV2（`?list-type=2`）；部分 S3 兼容网关
  /// （如阿里云 OSS S3 兼容层）不支持 V2，返回 HTTP 400/501 时
  /// 自动回退到 ListObjects V1。
  ///
  /// [maxKeys] 限制单次返回对象数量（S3 上限 1000），主要用于
  /// 连接探测等场景，避免全量列举浪费带宽。
  Future<List<String>> listObjects({
    required String bucket,
    String? prefix,
    int? maxKeys,
  }) async {
    _checkDisposed();
    final infos = await listObjectsDetailed(
      bucket: bucket,
      prefix: prefix,
      maxKeys: maxKeys,
    );
    return infos.map((e) => e.key).toList();
  }

  /// LIST Objects（含元数据）
  ///
  /// 与 [listObjects] 相同，但返回 [S3ObjectInfo] 列表，携带 size 和
  /// lastModified。供 [S3StorageService.list] 使用，避免返回硬编码的
  /// size=0 / lastModified=DateTime.now()。
  Future<List<S3ObjectInfo>> listObjectsDetailed({
    required String bucket,
    String? prefix,
    int? maxKeys,
  }) async {
    _checkDisposed();
    try {
      return await _listObjectsV2Detailed(
        bucket: bucket,
        prefix: prefix,
        maxKeys: maxKeys,
      );
    } on S3Exception catch (e) {
      if (e.statusCode == 400 || e.statusCode == 501) {
        // LOG-02：协议级降级是网关能力异常的首要排查线索，warning 留痕
        onProtocolEvent?.call(
            'ListObjectsV2 被 HTTP ${e.statusCode} 拒绝（网关不支持 V2），'
            '自动回退 ListObjects V1: bucket=$bucket prefix=$prefix');
        return _listObjectsV1Detailed(
          bucket: bucket,
          prefix: prefix,
          maxKeys: maxKeys,
        );
      }
      rethrow;
    }
  }

  /// ListObjectsV2（`?list-type=2`），返回含元数据的对象列表
  ///
  /// M-01 修复：支持分页迭代，S3 单次最多返回 1000 个对象，
  /// 当 IsTruncated=true 时用 continuation-token 继续请求，
  /// 直到所有对象都被获取。
  ///
  /// W3 修复：[maxKeys] 是**结果总数上限**而非单页大小。之前只把它作为
  /// 每页 max-keys 参数下发，do-while 只看 continuationToken，导致
  /// `listObjects(maxKeys: 1)` 连接探测实际翻页拉取全桶对象
  /// （大桶浪费流量/费用，故障网关恒返回 IsTruncated=true 时死循环）。
  ///
  /// 审计 S3-M2：[maxKeys] 为 null 的常规路径此前完全没有终止护栏——
  /// 故障网关恒返回 IsTruncated=true 时照样无限翻页。现补三重护栏：
  /// 页数硬上限、continuation-token 无推进检测、畸形响应（截断却无
  /// token）显式报错。
  Future<List<S3ObjectInfo>> _listObjectsV2Detailed({
    required String bucket,
    String? prefix,
    int? maxKeys,
  }) {
    // 审计 S3-M3：neverRetryStatusCodes 传入 501 —— Not Implemented 是
    // 确定性失败（网关不支持 ListObjectsV2），重试三次只会白耗退避延迟
    // 再走 V1 回退；应立即上抛给 listObjectsDetailed 做协议回退。
    return _retry(
      () async {
        final allObjects = <S3ObjectInfo>[];
        String? continuationToken;

        // S3-M2：翻页终止护栏状态
        String? previousToken;
        var pages = 0;

        do {
          // M2-1：页数硬上限。单页服务端上限 1000 对象，1000 页 ≈
          // 100 万对象，正常桶不会触达；故障网关不再无限翻页。
          if (++pages > _maxListPages) {
            throw S3Exception(
                'ListObjects V2 pagination exceeded $_maxListPages pages; '
                'aborting to avoid an unbounded loop');
          }
          // M2-2：token 无进展检测。网关回放同一个 continuation-token
          // 时每页返回相同内容，do-while 永不退出。token 必须单调推进。
          if (continuationToken != null &&
              continuationToken == previousToken) {
            throw S3Exception(
                'ListObjects V2 pagination stalled: server replayed the '
                'same continuation-token');
          }
          previousToken = continuationToken;

          final queryParams = <String, String>{
            'list-type': '2', // ListObjectsV2
          };
          if (prefix != null && prefix.isNotEmpty) {
            queryParams['prefix'] = prefix;
          }
          // 每页请求「还缺多少条」，由服务端钳制到其单页上限
          if (maxKeys != null) {
            queryParams['max-keys'] = '${maxKeys - allObjects.length}';
          }
          if (continuationToken != null) {
            queryParams['continuation-token'] = continuationToken;
          }

          final uri = _buildUri(bucket, queryParameters: queryParams);
          final headers = _signedHeaders(uri, 'GET');

          try {
            final response = await _httpClient
                .get(uri, headers: headers)
                .timeout(timeout);

            if (response.statusCode == 200) {
              final result = _parseListObjectsXml(response.body);
              final remaining =
                  maxKeys == null ? null : maxKeys - allObjects.length;
              if (remaining != null && result.objects.length > remaining) {
                // 服务端可能无视 max-keys 下发超量，截断到上限
                allObjects.addAll(result.objects.take(remaining));
                break; // 已达上限，无需继续翻页
              }
              allObjects.addAll(result.objects);
              // M2-3：IsTruncated=true 却未携带 NextContinuationToken 属于
              // 畸形分页响应——旧逻辑静默退出并返回**不完整列表**，下游
              // 会把残缺当全量消费（附件清理漏删/审计漏检）。显式报错。
              if (result.isTruncated) {
                final token = result.nextContinuationToken;
                if (token == null || token.isEmpty) {
                  throw S3Exception(
                      'ListObjects V2 pagination malformed: IsTruncated=true '
                      'without NextContinuationToken');
                }
                continuationToken = token;
              } else {
                continuationToken = null;
              }
            } else if (response.statusCode == 404) {
              throw S3BucketNotFoundException(bucket);
            } else {
              _handleError('ListObjects', response);
            }
          } on SocketException catch (e) {
            throw S3NetworkException('Network error: ${e.message}', originalException: e);
          } on TimeoutException {
            throw S3NetworkException('ListObjects timed out after ${timeout.inSeconds}s');
          } catch (e) {
            if (e is S3Exception) rethrow;
            throw S3Exception('ListObjects failed: $e', originalException: _asException(e));
          }
          // 达到 maxKeys 上限即停，绝不继续翻页
        } while (continuationToken != null &&
            (maxKeys == null || allObjects.length < maxKeys));

        return allObjects;
      },
      neverRetryStatusCodes: const {501},
    );
  }

  /// ListObjects V1（不带 `list-type` 参数），返回含元数据的对象列表
  ///
  /// M-01 修复：支持分页迭代，V1 用 marker 参数（上一页最后一个 key）
  /// 继续请求，直到 IsTruncated=false。
  ///
  /// W3：maxKeys 语义同 V2 路径 —— 结果总数上限，达到即停。
  ///
  /// 审计 S3-M2：终止护栏同 V2 路径 —— 页数硬上限、marker 无推进检测
  /// （网关忽略 marker 时每页返回相同内容）、畸形响应（截断却无尾 key）
  /// 显式报错。
  Future<List<S3ObjectInfo>> _listObjectsV1Detailed({
    required String bucket,
    String? prefix,
    int? maxKeys,
  }) {
    return _retry(() async {
      final allObjects = <S3ObjectInfo>[];
      String? marker;

      // S3-M2：翻页终止护栏状态
      String? previousMarker;
      var pages = 0;

      do {
        // M2-1：页数硬上限（同 V2）
        if (++pages > _maxListPages) {
          throw S3Exception(
              'ListObjects V1 pagination exceeded $_maxListPages pages; '
              'aborting to avoid an unbounded loop');
        }
        // M2-2：marker 无进展检测。网关忽略 marker 时每页返回相同内容，
        // 下一页 marker 与上一页相同，do-while 永不退出。
        if (marker != null && marker == previousMarker) {
          throw S3Exception(
              'ListObjects V1 pagination stalled: server ignored the marker '
              '(no pagination progress)');
        }
        previousMarker = marker;

        final queryParams = <String, String>{};
        if (prefix != null && prefix.isNotEmpty) {
          queryParams['prefix'] = prefix;
        }
        if (maxKeys != null) {
          queryParams['max-keys'] = '${maxKeys - allObjects.length}';
        }
        if (marker != null) {
          queryParams['marker'] = marker;
        }

        final uri = _buildUri(bucket, queryParameters: queryParams);
        final headers = _signedHeaders(uri, 'GET');

        try {
          final response = await _httpClient
              .get(uri, headers: headers)
              .timeout(timeout);

          if (response.statusCode == 200) {
            final result = _parseListObjectsXml(response.body);
            final remaining =
                maxKeys == null ? null : maxKeys - allObjects.length;
            if (remaining != null && result.objects.length > remaining) {
              allObjects.addAll(result.objects.take(remaining));
              break; // 已达上限，无需继续翻页
            }
            allObjects.addAll(result.objects);
            // V1 分页：IsTruncated=true 时，用最后一条 key 作为下次请求的 marker
            if (result.isTruncated) {
              // M2-3：截断却无尾 key 属于畸形响应——旧逻辑静默退出并
              // 返回不完整列表。显式报错（V1 亦可经 NextMarker 推进，
              // 但本实现不解析该元素，空页无法构造 marker）。
              if (result.lastKey == null) {
                throw S3Exception(
                    'ListObjects V1 pagination malformed: IsTruncated=true '
                    'without a trailing key');
              }
              marker = result.lastKey;
            } else {
              marker = null;
            }
          } else if (response.statusCode == 404) {
            throw S3BucketNotFoundException(bucket);
          } else {
            _handleError('ListObjects', response);
          }
        } on SocketException catch (e) {
          throw S3NetworkException('Network error: ${e.message}', originalException: e);
        } on TimeoutException {
          throw S3NetworkException('ListObjects timed out after ${timeout.inSeconds}s');
        } catch (e) {
          if (e is S3Exception) rethrow;
          throw S3Exception('ListObjects failed: $e', originalException: _asException(e));
        }
        // 达到 maxKeys 上限即停，绝不继续翻页
      } while (marker != null &&
          (maxKeys == null || allObjects.length < maxKeys));

      return allObjects;
    });
  }

  /// 为请求生成带签名的 headers
  ///
  /// [method] 必须与实际发送的 HTTP method 完全一致：SigV4 规范请求首行
  /// 即 HTTP method，服务端按收到的请求行重算签名，签名 method 与实际
  /// method 不一致必然 SignatureDoesNotMatch(403)。此前 HEAD/DELETE 复用
  /// GET 签名正是该错误（审计 P0）。
  Map<String, String> _signedHeaders(Uri uri, String method) {
    return _signer.sign(
      method: method,
      uri: uri,
      headers: {'Host': uri.authority},
    );
  }

  /// 构建请求 URI
  ///
  /// - path-style:      `https://endpoint[:port]/bucket/key`
  /// - virtual-hosted:  `https://bucket.endpoint[:port]/key`
  ///
  /// 返回的 [Uri.authority] 即为应签名、应发送的 Host 值（非默认端口时携带端口）。
  Uri _buildUri(String bucket, {String? key, Map<String, String>? queryParameters}) {
    final scheme = useSSL ? 'https' : 'http';
    final portStr = port != null ? ':$port' : '';
    final encodedKey = (key == null || key.isEmpty) ? '' : '/${_encodeKey(key)}';
    final host = forcePathStyle ? endpoint : '$bucket.$endpoint';
    final path = forcePathStyle ? '/$bucket$encodedKey' : encodedKey;

    var uri = Uri.parse('$scheme://$host$portStr$path');
    if (queryParameters != null && queryParameters.isNotEmpty) {
      // 与 s3_signature._createCanonicalRequest 保持逐字节一致（审计 S3-1）：
      // 使用同一严格 RFC 3986 编码器，而不是 uri.replace(queryParameters:)
      // 的 x-www-form-urlencoded 编码（空格 -> '+'）。否则带空格/子定界符
      // 的查询值会使「落网查询串」与「签名查询串」不一致，S3 SigV4 校验
      // 返回 403；字面 '+'（如 base64 continuation-token）也会被错误解码
      // 为空格。uri.replace(query:) 接收已编码串，不会二次编码。
      final encodedQuery = queryParameters.entries
          .map((e) =>
              '${S3SignatureV4.encodePathComponentRfc3986(e.key)}='
              '${S3SignatureV4.encodePathComponentRfc3986(e.value)}')
          .join('&');
      uri = uri.replace(query: encodedQuery);
    }
    return uri;
  }

  /// 解析 ListObjects 响应（XML），返回对象列表 + 分页信息
  ///
  /// M-01 修复：增加分页支持，返回 IsTruncated、NextContinuationToken（V2）
  /// 和最后一个对象的 key（V1 的 Marker），使调用方能够迭代获取全部对象。
  /// S3 ListObjects 单次最多返回 1000 个对象，不处理分页会导致多账本用户
  /// 只能看到前 1000 个文件。
  ///
  /// N-6 修复（2026-09-12）：元素匹配改 localName（xml 包的 findAllElements
  /// 按字面名匹配不剥命名空间前缀）—— 带 `<s3:Contents>` 前缀的第三方网关
  /// 响应此前解析出 0 对象 + isTruncated=false，静默返回空桶视图且 S-M1
  /// 抛错护栏不触发（解析本身成功、只是什么都找不到）。localName 匹配
  /// 对 AWS/MinIO/R2/OSS 等无前缀主流实现行为不变。
  ({List<S3ObjectInfo> objects, bool isTruncated, String? nextContinuationToken, String? lastKey})
      _parseListObjectsXml(String xmlBody) {
    try {
      final document = XmlDocument.parse(xmlBody);

      List<XmlElement> findAllLocal(XmlElement root, String localName) =>
          root.descendants
              .whereType<XmlElement>()
              .where((e) => e.name.local == localName)
              .toList();

      final objects = findAllLocal(document.rootElement, 'Contents')
          .map((element) {
        XmlElement? findChildLocal(String localName) {
          for (final child in element.children) {
            if (child is XmlElement && child.name.local == localName) {
              return child;
            }
          }
          return null;
        }
        final keyElement = findChildLocal('Key');
        final sizeElement = findChildLocal('Size');
        final modifiedElement = findChildLocal('LastModified');

        final key = keyElement?.innerText;
        if (key == null) return null;

        final sizeStr = sizeElement?.innerText;
        final size = sizeStr != null ? int.tryParse(sizeStr) : null;

        final modifiedStr = modifiedElement?.innerText;
        final lastModified = modifiedStr != null ? DateTime.tryParse(modifiedStr) : null;

        return S3ObjectInfo(key: key, size: size, lastModified: lastModified);
      }).whereType<S3ObjectInfo>().toList();

      // 分页信息（localName 匹配，理由同上）
      final isTruncated = findAllLocal(document.rootElement, 'IsTruncated')
              .firstOrNull
              ?.innerText
              .toLowerCase() ==
          'true';
      final nextContinuationToken = findAllLocal(
              document.rootElement, 'NextContinuationToken')
          .firstOrNull
          ?.innerText;
      final lastKey = objects.isNotEmpty ? objects.last.key : null;

      return (
        objects: objects,
        isTruncated: isTruncated,
        nextContinuationToken: nextContinuationToken,
        lastKey: lastKey,
      );
    } catch (e) {
      // S-M1 修复：XML 解析失败不再静默返回空列表，
      // 而是抛出异常，避免调用方误认为桶为空导致数据丢失判断错误
      throw S3Exception(
        'ListObjects XML parse failed: $e',
        originalException: e is Exception ? e : null,
      );
    }
  }

  /// C-01 修复：从 HTTP 响应头中提取 x-amz-meta-* 自定义元数据
  ///
  /// S3 将用户上传时通过 x-amz-meta-{key} 头设置的元数据原样返回，
  /// http 包将所有头名转为小写，因此用 'x-amz-meta-' 前缀匹配。
  /// 写入端已对非 ASCII 值做 base64 编码（见 [_encodeMetaValue]），
  /// 此处自动还原；不带 'b64:' 前缀的旧值原样返回以保持向后兼容。
  Map<String, String>? _extractCustomMetadata(Map<String, String> headers) {
    const prefix = 'x-amz-meta-';
    final result = <String, String>{};
    for (final entry in headers.entries) {
      if (entry.key.startsWith(prefix)) {
        final metaKey = entry.key.substring(prefix.length);
        result[metaKey] = _decodeMetaValue(entry.value);
      }
    }
    return result.isEmpty ? null : result;
  }

  /// 将 metadata 值编码为 HTTP 头安全形式。
  ///
  /// 非 ASCII 字符（如中文账本名）直接作为头值会触发 RFC 7230 校验异常，
  /// 故统一 base64 编码并加 'b64:' 前缀标记；读取端 [_decodeMetaValue]
  /// 自动还原。编码发生在签名之前，故服务端收到的也是编码值、签名一致。
  static String _encodeMetaValue(String value) {
    return 'b64:${base64.encode(utf8.encode(value))}';
  }

  /// 还原 [_encodeMetaValue] 编码的 metadata 值。
  ///
  /// 带 'b64:' 前缀的做 base64 解码；不带前缀视为历史明文值原样返回，
  /// 避免破坏旧版写入的数据。解码异常时回退原值，保证不丢数据。
  ///
  /// M8：部分网关/代理会剥掉响应头值的尾部 `=` padding。Dart 的
  /// `base64.decode` 对缺 padding 输入直接抛 FormatException，回退分支
  /// 会把「b64:密文」整串当值返回 → 指纹恒不匹配、反复全量下载。
  /// 先经 [base64.normalize] 补齐 padding 再解码即可还原。
  static String _decodeMetaValue(String value) {
    if (value.startsWith('b64:')) {
      // 'b64:' 前缀长度为 4，payload 从下标 4 开始（此前误写 substring(5)
      // 会削掉 payload 首字符导致解码永远失败、恒回退原始包装串）。
      final payload = value.substring(4);
      try {
        return utf8.decode(base64.decode(payload));
      } on FormatException {
        // 可能只是被网关剥了 padding，补齐后重试
        try {
          return utf8.decode(base64.decode(base64.normalize(payload)));
        } on FormatException {
          return value; // 真损坏：回退原值，不丢数据
        }
      }
    }
    return value;
  }

  /// 归一化 ETag：剥掉引号包装（"abc"/W/"abc" → abc），供条件写
  /// If-Match 回传与写后校验比较。缺失/空值返回 null。
  static String? _normalizeEtag(String? raw) {
    if (raw == null) return null;
    var v = raw.trim();
    if (v.startsWith('W/')) v = v.substring(2);
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    return v.isEmpty ? null : v;
  }

  /// URL 编码 Key（保留 /）
  ///
  /// 审计 S3-1：委托签名端的严格 RFC 3986 编码器，保证请求路径与
  /// canonical URI 逐字节一致（Uri.encodeComponent 不转义子定界符，
  /// 与签名端口径分裂会导致 403 SignatureDoesNotMatch）。
  String _encodeKey(String key) => S3SignatureV4.encodeKeyRfc3986(key);

  /// 404 响应体中 errorCode 为 NoSuchBucket 时抛 [S3BucketNotFoundException]。
  ///
  /// 审计 A5：桶级 404 是配置错误，与「对象不存在」语义完全不同；
  /// 混同会让上层把「桶配错」当「云端无备份/文件已删」处理。
  /// 注意：HEAD 响应无 body，协议上无法区分（headObject/headObjectWithMetadata
  /// 保持「404 = 不存在」语义，桶级错误由初始化探测的 listObjects 兜底发现）。
  void _throwIfNoSuchBucket(String operation, http.Response response,
      String bucket) {
    if (response.body.isEmpty) return;
    try {
      final document = XmlDocument.parse(response.body);
      final errorCode =
          document.findAllElements('Code').firstOrNull?.innerText;
      if (errorCode == 'NoSuchBucket') {
        throw S3BucketNotFoundException(bucket);
      }
    } on S3BucketNotFoundException {
      rethrow;
    } catch (_) {
      // XML 解析失败：按对象级 404 处理（调用方决定后续语义）
    }
  }

  /// 统一错误处理
  ///
  /// 返回类型为 [Never]：此方法永远抛出异常，不会正常返回。
  /// 调用后的代码在编译器看来不可达，便于静态分析消除死代码。
  Never _handleError(String operation, http.Response response) {
    final statusCode = response.statusCode;
    final body = response.body;

    // 尝试解析 XML 错误信息
    String? errorCode;
    String? errorMessage;
    try {
      final document = XmlDocument.parse(body);
      errorCode = document.findAllElements('Code').firstOrNull?.innerText;
      errorMessage = document.findAllElements('Message').firstOrNull?.innerText;
    } catch (_) {
      // XML 解析失败，使用原始 body
    }

    final message = errorMessage ?? _sanitizeHtmlBody(body);

    // 审计 S22：时钟偏差检测。AWS 默认容忍 ±15min，超窗后所有请求
    // 403 RequestTimeTooSkewed——旧逻辑误报成「权限不足」且不重试，
    // 同步彻底瘫痪。此处解析服务器时间写入签名偏移并抛专属异常，
    // _retry 捕获后用新偏移立即重试一次。
    if (errorCode == 'RequestTimeTooSkewed') {
      DateTime? serverTime;
      try {
        final dateHeader = response.headers['date'];
        if (dateHeader != null) {
          serverTime = HttpDate.parse(dateHeader).toUtc();
        }
      } catch (_) {
        // Date 头缺失或格式异常，无法自动补偿
      }
      if (serverTime != null) {
        _signer.clockOffset = serverTime.difference(DateTime.now().toUtc());
        // LOG-02：设备时钟与服务器偏差 >15min 是用户环境问题（改配置
        // 无用，需校时），补偿已生效但线索必须留痕
        onProtocolEvent?.call(
            '检测到设备时钟偏差（已自动补偿 '
            '${_signer.clockOffset.inMinutes} 分钟，服务器时间: '
            '${serverTime.toIso8601String()}）。若持续失败请校准系统时间');
      }
      throw S3ClockSkewException(
        '设备时钟与服务器偏差过大，已尝试校准（服务器时间: '
        '${serverTime?.toIso8601String() ?? '未知'}）。'
        '若持续失败请校准系统时间后重试',
        serverTime: serverTime,
      );
    }

    if (statusCode == 403) {
      if (errorCode == 'InvalidAccessKeyId' || errorCode == 'SignatureDoesNotMatch') {
        throw S3AuthException('Authentication failed: $message');
      } else {
        throw S3PermissionDeniedException('Permission denied: $message');
      }
    } else if (statusCode == 404) {
      // _handleError 不持有 key 信息，无法构造语义正确的
      // S3ObjectNotFoundException（需要 key），故抛通用 S3Exception。
      // 具体对象的 404 由调用方在状态码判断后自行抛出 S3ObjectNotFoundException。
      throw S3Exception('Object not found (404)', statusCode: 404);
    } else if (statusCode == 400) {
      throw S3Exception(
        '$operation failed (HTTP 400): $message. '
        'Check endpoint, useSSL, addressing style (path/virtual-hosted), '
        'or the server may not support ListObjectsV2.',
        statusCode: statusCode,
      );
    } else if (statusCode == 501) {
      throw S3Exception(
        '$operation failed (HTTP 501): $message. '
        'The server may not support this API version.',
        statusCode: statusCode,
      );
    } else {
      throw S3Exception(
        '$operation failed (HTTP $statusCode): $message',
        statusCode: statusCode,
      );
    }
  }

  /// 去除 HTML 标签并压缩空白，避免把原始 HTML 错误页直接抛给用户
  String _sanitizeHtmlBody(String body) {
    final cleaned = body
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return body.trim();
    return cleaned.length > 300 ? '${cleaned.substring(0, 300)}…' : cleaned;
  }

  /// 审计修复：安全提取原始异常。通用 catch (e) 捕获的可能是 Error
  /// （如 ArgumentError/RangeError），此前 `e as Exception?` 强转在遇到
  /// Error 时自身抛 TypeError、掩盖真正的错误；非 Exception 一律置 null。
  static Exception? _asException(Object e) => e is Exception ? e : null;
}
