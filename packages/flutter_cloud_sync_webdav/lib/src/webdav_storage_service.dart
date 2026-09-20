library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// [_op] 超时专用异常（审计 WebDAV-T2）。
///
/// [_op] 超时此前统一抛 [CloudStorageException]，而 [WebDAVStorageService]
/// 的幂等重试把「无结构化 HTTP 状态码」一律视为连接层瞬时故障 →
/// 超时被默认可重试，单次 60s 超时最坏放大为 3×60s = 180s（服务器挂死时
/// 同步 UI 长时间卡顿）。用独立类型把「超时」从「连接层瞬时故障」中区分
/// 出来，禁止对同一挂死服务器重复等待。仍继承 [CloudStorageException]，
/// 既有 `catch (CloudStorageException)` 调用方不受影响。
class _WebDavTimeoutException extends CloudStorageException {
  _WebDavTimeoutException(super.message);
}

/// WebDAV implementation of [CloudStorageService].
class WebDAVStorageService
    implements
        CloudStorageService,
        BinaryCapableStorage,
        ConditionalWriteStorage {
  final webdav.Client _client;
  final String _remotePath;

  /// LOG-01：应用日志注入口（宿主经 WebDAVProvider.storageLogger 设置）。
  ///
  /// 此前本服务的全部关键告警（降级交换的备份还原失败/临时文件清理
  /// 失败/元数据读取失败）走 `dart:developer` 的 dev.log —— 只在
  /// `flutter run` 控制台可见，不进应用日志系统，release 构建完全
  /// 无痕迹。这些恰是「数据半落地」的高危场景，线上排障需要留痕。
  /// null（未注入，如包内单测）时退回 dev.log，行为与旧版一致。
  final CloudSyncLogger? logger;

  WebDAVStorageService(this._client, this._remotePath, {this.logger});

  /// LOG-01：统一告警出口 —— 注入 logger 时进应用日志管线（warning
  /// 级），否则退回 dev.log（旧行为）。备份还原失败（数据可能未回滚）
  /// 升级为 error 级。
  void _warn(String message, {bool critical = false}) {
    if (logger != null) {
      if (critical) {
        logger!.error(message);
      } else {
        logger!.warning(message);
      }
      return;
    }
    dev.log(
      '[WebDAV] ${critical ? 'Error' : 'Warning'}: $message',
      name: 'WebDAVStorage',
    );
  }

  /// 审计 M10：getMetadata 元数据解析缓存，键为 `fullPath\u0000eTag`。
  ///
  /// 背景：WebDAV 的元数据存在信封内嵌 meta（新格式）或 sidecar JSON
  /// （旧格式）里，两条解析路径都要求 GET 文件全文；而 getStatus /
  /// 写后校验会以缓存 TTL（30s）级别的频率反复调 getMetadata，大快照
  /// 下等于每次状态检查都全量拉一遍主文件。
  ///
  /// 依据：eTag（PROPFIND 父目录扫描已免费带回）是内容寻址的——eTag
  /// 未变 ⇒ 信封内容未变 ⇒ meta 必然相同；sidecar 为旧格式遗留，
  /// 方案C 后不再有写入方，不会脱离主文件漂移。故解析结果按
  /// (path, eTag) 缓存，命中直接复用，重复调用零下载。
  ///
  /// 边界：
  /// - 服务器不返回 getetag（审计 C2 已记录的兼容形态）→ 无缓存键，
  ///   保持逐次读取的旧行为
  /// - 解析遭遇瞬时故障（网络抖动）→ 不缓存，避免把「读失败」钉死
  ///   成「无元数据」导致后续永远拿不到 fingerprint
  /// - 容量上限 [_metaCacheLimit]（插入序淘汰），防超大桶长驻内存
  final Map<String, Map<String, dynamic>> _metaCache =
      <String, Map<String, dynamic>>{};
  static const int _metaCacheLimit = 64;

  /// M10：元数据缓存写入（先删后插刷新插入序，热点条目不被误淘汰）。
  void _cacheMeta(String key, Map<String, dynamic> meta) {
    _metaCache.remove(key);
    if (_metaCache.length >= _metaCacheLimit) {
      _metaCache.remove(_metaCache.keys.first);
    }
    _metaCache[key] = meta;
  }

  /// 审计 WD-2：已确认存在的父目录缓存（进程内，随服务实例生命周期）。
  ///
  /// [_atomicPublish] 此前每次上传都先 [_ensureDirectory] —— 一次父目录
  /// readDir（Depth-1 全量 listing）。附件目录动辄数千文件时，等于每次
  /// 上传都把父目录完整列一遍，纯开销。会话内确认过存在的目录直接跳过
  /// 探测；若目录在会话期间被外部删除，临时文件写入会吃 404，写入失败
  /// 分支负责失效缓存并重建重试（自愈语义与旧行为一致）。
  final Set<String> _ensuredDirs = <String>{};

  /// P3：WebDAV 单次操作 60s 超时。webdav_client 未暴露 dio 超时配置，
  /// 服务器无响应时 future 永不完成会让同步 UI 永久挂起，
  /// 在服务层统一包 .timeout 兜底。
  ///
  /// 测试口 [opTimeoutForTest] 可把它覆盖成毫秒级，用于验证「超时不进入
  /// 幂等重试」（否则单测需真等 60s）。命名沿用代码库 ForTest 约定。
  static Duration? opTimeoutForTest;
  static Duration get _opTimeout =>
      opTimeoutForTest ?? const Duration(seconds: 60);

  /// 审计修复：进程内自增计数器，参与上传临时文件名构造。此前仅用
  /// 毫秒时间戳，同一目标的并发上传落在同一毫秒时互相覆盖对方写了一半
  /// 的 tmp，先完成者 rename 发布的可能是对方截断的数据（与 S3 侧
  /// _tempSeq 修复同款）。时间戳 + 序号保证每次上传独占自己的 tmp。
  ///
  /// 审计 W-F：降级交换的 backup 文件名同样复用本序号 —— 此前 backup
  /// 只有毫秒时间戳，同毫秒两路并发降级交换撞名吃 412 直接失败。
  static int _tempSeq = 0;

  /// M15：上传临时文件标记（`<name>.tmp.<毫秒>_<序号>`，见 [uploadBinary]）。
  /// list() 据此过滤上传中断残留的半成品，避免被下游当有效文件消费。
  ///
  /// 审计 B7：改为「标记 + 后继数字」正则而非裸子串 —— 裸子串会误伤
  /// 合法用户文件（如 `my.tmp.data.json`），且与 exists/getMetadata 的
  /// 未过滤口径分裂出「存在却看不见」的自相矛盾状态。本服务自产的残留
  /// 文件名在标记后必然是数字时间戳/序号，`\.tmp\.\d` 精确命中且不误伤。
  static final RegExp _tempFilePattern = RegExp(r'\.tmp\.\d');

  /// 审计 WD-1：降级交换流程的备份文件标记（`<name>.old.<毫秒>`）。
  /// 备份清理失败时 list() 据此过滤，避免孤儿备份被下游当有效文件。
  /// 正则理由同 [_tempFilePattern]。
  static final RegExp _backupFilePattern = RegExp(r'\.old\.\d');

  /// 审计 W-G：内部产物判定统一入口。此前 list 过滤 `.tmp./.old.` 而
  /// exists/getMetadata 不过滤，形成「list 看不见、exists 却为 true」
  /// 的三态分裂。三个读路径一律走本判定，口径一致。
  static bool _isInternalArtifact(String name) {
    return name.endsWith('.metadata.json') ||
        _tempFilePattern.hasMatch(name) ||
        _backupFilePattern.hasMatch(name);
  }

  /// 信封格式标记（方案C / 审计 W-I 修复）。
  ///
  /// 此前主文件与 sidecar 元数据分两次 PUT：主文件落位到 sidecar 更新
  /// 完成之间存在窗口，他机此刻 download 会拿到新内容+旧指纹，
  /// CloudSyncManager.download 的完整性校验直接硬失败。信封把元数据
  /// 与数据合并进**同一个文件**原子发布，窗口归零：
  ///
  /// ```json
  /// {"fmt":"pc-wdav-env-v1","b64":false,"data":<原始内容字符串>,
  ///  "meta":{...metadata}}
  /// ```
  ///
  /// - 文本上传（manager 快照 JSON）：data 为原始文本原样嵌入
  /// - 带元数据的二进制上传：data 为 base64（b64:true），体积 +33%
  ///   仅发生在确实携带元数据的二进制上；无元数据的二进制仍写裸字节
  /// - 旧版裸文件（无信封）：下载端按原文返回，元数据回退读 sidecar，
  ///   无需任何迁移
  static const String _envelopeFmt = 'pc-wdav-env-v1';

  static String _wrapEnvelope(String data, Map<String, String>? metadata,
      {bool b64 = false}) {
    return jsonEncode({
      'fmt': _envelopeFmt,
      'b64': b64,
      'data': data,
      if (metadata != null && metadata.isNotEmpty) 'meta': metadata,
    });
  }

  /// 尝试按信封解包；非信封内容返回 null（调用方按裸数据处理）。
  static ({String data, Map<String, dynamic>? meta, bool b64})?
      _tryUnwrapEnvelope(Uint8List bytes) {
    // 快速预检：信封必以 '{' 开头，绝大多数二进制第一字节即排除
    if (bytes.isEmpty || bytes[0] != 0x7B) return null;
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null; // 非法 JSON：是裸二进制/裸文本
    }
    if (json['fmt'] != _envelopeFmt || !json.containsKey('data')) {
      return null; // 普通JSON业务数据（如老快照），不当信封拆包
    }
    return (
      data: json['data'] as String,
      meta: json['meta'] as Map<String, dynamic>?,
      b64: json['b64'] as bool? ?? false,
    );
  }

  /// P1-1（对齐 S3 适配器 P5 的真随机 jitter）：退避抖动随机源。
  /// 实例级，生命周期与 service 一致。
  final Random _retryRandom = Random();

  /// 幂等操作自动重试（对齐 S3 适配器 P5：弱网成功率）。
  ///
  /// 仅用于 read/readDir/remove 等幂等操作；write/rename/mkdir 非幂等，
  /// 绝不进入本包装。重试条件：完全无结构化 HTTP 状态码（连接层故障）
  /// 或 5xx 服务端临时错误；4xx 一律立即上抛。
  ///
  /// P1-1：jitter 此前用 `DateTime.now().microsecondsSinceEpoch % range`
  /// —— 时间戳取模**不是随机**：同一毫秒内触发的多设备/多操作退避
  /// 完全同相，thundering herd 防护名存实亡（多设备瞬时故障后同一
  /// 时刻集中重试，正是 jitter 要防的场景）。改用 [Random]（与 S3
  /// 侧 retryDelayForTest 的 P5 实现同款）。
  Future<T> _retryIdempotent<T>(Future<T> Function() operation) async {
    const maxRetries = 2; // 共 1+2 次
    var attempt = 0;
    while (true) {
      try {
        return await operation();
      } catch (e) {
        final code = _statusCodeOf(e);
        // 审计 WebDAV-T2：超时（[_WebDavTimeoutException]）不算「连接层
        // 瞬时故障」—— 重试同一挂死服务器只会重复等待（最坏 3×60s）。
        final retriable = attempt < maxRetries &&
            e is! _WebDavTimeoutException &&
            (code == null || code >= 500);
        if (!retriable) rethrow;
        attempt++;
        // LOG-06：重试逐次留痕（info 级——重试属正常自愈行为，非告警）。
        // 弱网排障需区分「一次成功」与「重试后成功」；logger 未注入时
        // 静默（测试无感）。
        logger?.info(
            '[WebDAV] 幂等操作瞬时故障${code != null ? '（HTTP $code）' : ''}，'
            '第 $attempt/$maxRetries 次重试: $e');
        // 指数退避 + 真随机抖动：base 的 [0.5×base, base] 区间均匀分布
        //（400ms → 200~400ms，800ms → 400~800ms）。
        final baseMs = 400 * (1 << (attempt - 1));
        final jitter = _retryRandom.nextInt(baseMs ~/ 2 + 1);
        await Future<void>.delayed(
            Duration(milliseconds: baseMs ~/ 2 + jitter));
      }
    }
  }

  /// 包裹单次 WebDAV 操作，超时抛 [CloudStorageException]（带操作名），
  /// 与其他网络错误走同一异常通道，调用方无需新增捕获分支。
  ///
  /// F9：超时同时通过 [CancelToken] 主动中止底层 HTTP 请求。仅靠
  /// Future.timeout 放弃等待的话，请求仍在后台继续 —— PUT 可能在超时后
  /// 才完成，把临时文件留在远端（孤儿半成品）。取消让传输层尽快终止。
  /// 注意：rename(MOVE) 的上游 client.rename 声明了 cancelToken 形参但未
  /// 向下传递（webdav_client 1.2.2 已知问题），MOVE 无法被取消，维持
  /// timeout-only；其余操作全部可取消。
  Future<T> _op<T>(String opName, Future<T> Function(CancelToken token) op) async {
    final token = CancelToken();
    var timedOut = false;
    String timeoutMessage() =>
        'WebDAV $opName 超时（${_opTimeout.inSeconds}s），请检查网络或服务器';
    final timer = Timer(_opTimeout, () {
      timedOut = true;
      token.cancel('WebDAV $opName 超时');
    });
    try {
      return await op(token).timeout(_opTimeout, onTimeout: () {
        timedOut = true;
        token.cancel('WebDAV $opName 超时');
        throw _WebDavTimeoutException(timeoutMessage());
      });
    } catch (e) {
      // 审计 WebDAV-T2：CancelToken 中止底层请求引发的异常（DioException
      // cancel 等）无结构化状态码，会被幂等重试误判为「连接层瞬时故障」。
      // 只要已进入超时窗口，一律归为超时型（不可重试）。
      if (timedOut && e is! _WebDavTimeoutException) {
        throw _WebDavTimeoutException(timeoutMessage());
      }
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  /// 幂等操作组合入口：[_op] 超时取消 + [_retryIdempotent] 自动重试
  Future<T> _opRetryable<T>(
          String opName, Future<T> Function(CancelToken token) op) =>
      _retryIdempotent(() => _op(opName, op));

  /// 写路径空 path 防御（审计 W-Y）：空字符串会拼出与目录前缀同名的
  /// 远端**文件**，破坏该前缀下所有后续目录操作的语义。写/读单文件
  /// 操作一律显式拒绝；list('') 表示列根目录，属合法用法不拦。
  void _assertNonEmptyPath(String path) {
    if (path.trim().isEmpty) {
      throw CloudConfigurationException('WebDAV path 不能为空');
    }
  }

  /// 审计 WD-Y2：文件操作拒绝以 `/` 结尾的路径 —— 尾斜杠在 WebDAV
  /// 语义里是「集合（目录）」标记：GET 一个集合，部分服务器返回
  /// 200 + HTML 目录列表，信封解包失败后**被当文件内容原样返回**，
  /// 损坏数据无声流入下游；DELETE 一个集合更可能连目录带数据整体
  /// 删除。文件操作一律显式拒绝（列目录请用 [list]）。
  void _assertFilePath(String path) {
    _assertNonEmptyPath(path);
    if (path.trim().endsWith('/')) {
      throw CloudConfigurationException(
          'WebDAV 文件操作不接受以 / 结尾的路径（如需列目录请用 list）: $path');
    }
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    _assertFilePath(path);
    final hasMeta = metadata != null && metadata.isNotEmpty;
    // 方案C（审计 W-I）：带元数据的文本上传合并为单信封文件原子发布，
    // 消除「主文件已落位、sidecar 未更新」窗口期的完整性校验硬失败。
    // 无元数据时保持裸文本写入（外部工具可直读）。
    final payload = hasMeta
        ? utf8.encode(_wrapEnvelope(data, metadata))
        : utf8.encode(data);
    await _atomicPublish(_buildPath(path), payload);
  }

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    _assertFilePath(path);
    final hasMeta = metadata != null && metadata.isNotEmpty;
    // 带元数据的二进制走 base64 信封；无元数据保持裸字节（零开销，
    // 附件/ZIP 备份等大头不受影响）
    final Uint8List payload = hasMeta
        ? utf8.encode(_wrapEnvelope(base64.encode(bytes), metadata, b64: true))
        : (bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    await _atomicPublish(_buildPath(path), payload);
  }

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
      throw ArgumentError('ifMatchEtag 与 ifNoneMatch 互斥，不能同时传入');
    }
    _assertFilePath(path);

    // 方案C：WebDAV 无标准条件 PUT（webdav_client 不透传 If-Match），
    // 以「上传前重取 eTag 比对」近似乐观锁 —— 显著收窄竞态窗口但非原子，
    // 调用方仍需配合 manager 层写后校验兜底（见 ConditionalWriteStorage 注释）。
    //
    // 审计 C2：远端状态判定必须区分「对象不存在」（entry == null，可安全
    // 放行 ifNoneMatch）与「对象存在但服务器不返回 getetag」（上游
    // webdav_client 此时给空串而非 null —— 若把空串归一化成 null 再用
    // 「etag != null」判存在，会让 ifNoneMatch 在此类服务器上盲覆盖已存在
    // 文件）。故以 entry 是否命中为准，etag 仅用于 ifMatch 的值比对；
    // etag 未知的 ifMatch 保持 fail-closed（无法验证即拒绝），不丢数据。
    final entry = await _findEntry(_buildPath(path));
    final currentETag = _normalizeETag(entry?.eTag);
    if (ifMatchEtag != null) {
      if (entry == null ||
          currentETag == null ||
          currentETag != _normalizeETag(ifMatchEtag)) {
        throw CloudPreconditionFailedException(
            path, 'WebDAV 条件写失败（远端已被其他设备修改或不存在）: $path');
      }
    }
    if (ifNoneMatch && entry != null) {
      throw CloudPreconditionFailedException(
          path, 'WebDAV 条件写失败（远端已存在同名对象）: $path');
    }

    await uploadBinary(path: path, bytes: bytes, metadata: metadata);
  }

  /// 在父目录 Depth-1 列举中查找单个文件条目（排除目录）。
  /// 「确认不存在」收敛为 null；网络/权限等真实错误原样上抛。
  ///
  /// M1：isDir 缺省与 [list] / [exists] 统一为 `?? true`（缺 resourcetype
  /// 时保守视为目录排除）—— 三处旧口径分裂（?? false vs ?? true）会让
  /// 同一文件在「服务器不返回 resourcetype」时 getMetadata 命中、
  /// exists 却为 false。
  Future<webdav.File?> _findEntry(String fullPath) async {
    final parentDir = PathHelper.dirname(fullPath);
    final fileName = PathHelper.basename(fullPath);
    try {
      final files =
          await _opRetryable('readDir', (t) => _client.readDir(parentDir, t));
      for (final f in files) {
        if (!(f.isDir ?? true) && f.name == fileName) {
          return f;
        }
      }
      return null;
    } catch (e) {
      if (_isNotFound(e)) return null;
      rethrow;
    }
  }

  /// ETag 归一化比较用：剥弱验证器前缀与引号包装
  static String? _normalizeETag(String? raw) {
    if (raw == null) return null;
    var v = raw.trim();
    if (v.startsWith('W/')) v = v.substring(2);
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    return v.isEmpty ? null : v;
  }

  /// 原子发布核心：temp PUT → overwrite MOVE → 按需降级交换（无损）。
  ///
  /// SYNC-09 / 审计 WD-1 的既有修复全部保留：
  /// - 只有「服务器不支持覆盖式 MOVE」（405/409/412）才降级，其余错误
  ///   一律原样上抛 —— 此时旧文件完好；
  /// - 降级本身为无损交换：旧文件先挪到备份位 → 新文件落位 → 成功后删
  ///   备份。任一步失败都尽力把备份挪回原位，全程不存在
  ///   「目标已删、新未落位且无备份」的窗口。
  ///
  /// 新增修复：
  /// - 审计 W-A：部分服务器对**成功**的 MOVE 返回 200，上游只认
  ///   201/204/207 会误报错误。降级判定前先探测「目标已在、临时已消失」，
  ///   命中按成功处理，消除假失败。
  /// - 审计 W-F：备份名加入进程内序号，同毫秒并发降级不再撞名吃 412。
  Future<void> _atomicPublish(String fullPath, Uint8List payload) async {
    final tempPath =
        '$fullPath.tmp.${DateTime.now().millisecondsSinceEpoch}_${_tempSeq++}';
    try {
      // 确保父目录存在（会话内已确认过的目录跳过探测，见 _ensuredDirs）
      final parentDir = PathHelper.dirname(fullPath);
      if (!_ensuredDirs.contains(parentDir)) {
        await _ensureDirectory(parentDir);
        _ensuredDirs.add(parentDir);
      }

      // 1. 先写临时文件（webdav write 需要 Uint8List，避免多余拷贝）
      try {
        await _op(
            'write', (t) => _client.write(tempPath, payload, cancelToken: t));
      } catch (e) {
        if (!_ensuredDirs.contains(parentDir) || !_isNotFound(e)) {
          rethrow;
        }
        // WD-2：会话内确认过、现在却 404 —— 目录被外部删除。失效缓存，
        // 重建目录后重试一次写入，保持与旧行为一致的自愈能力。
        _ensuredDirs.remove(parentDir);
        await _ensureDirectory(parentDir);
        _ensuredDirs.add(parentDir);
        await _op(
            'write', (t) => _client.write(tempPath, payload, cancelToken: t));
      }

      // 2. 直接覆盖 rename（overwrite=true），失败时旧文件保持原样
      try {
        await _op('rename', (_) => _client.rename(tempPath, fullPath, true));
      } catch (renameError) {
        // 审计 W-A：数据可能已经落盘（服务器对成功 MOVE 回了 200）。
        // 先核实「目标存在且临时消失」，命中直接按成功返回 —— 数据在远端
        // 是一致的（要么旧文件完好、要么新文件完整落位），绝无半成品。
        if (await _moveLandedAnyway(tempPath, fullPath)) {
          return;
        }
        // 3. 降级（仅限不支持覆盖 MOVE 的服务器）：交换式替换
        if (!_isOverwriteUnsupported(renameError)) {
          rethrow;
        }
        final backupPath =
            '$fullPath.old.${DateTime.now().millisecondsSinceEpoch}_${_tempSeq++}';
        // 旧文件挪到备份位。此步失败则旧文件仍在原位，直接向上抛
        // （外层 catch 清理临时文件即可，无数据风险）。
        await _op('rename', (_) => _client.rename(fullPath, backupPath, false));
        try {
          // 新文件落位
          await _op('rename', (_) => _client.rename(tempPath, fullPath, true));
        } catch (swapError) {
          // 落位失败：把备份挪回原位保住旧数据，再上抛原始错误
          try {
            await _op(
                'rename', (_) => _client.rename(backupPath, fullPath, false));
          } catch (restoreError) {
            // LOG-01：备份还原失败 = 旧数据可能不在原位（数据半落地），
            // error 级上报（此前 dev.log release 无痕迹）
            _warn(
                '降级交换的备份还原失败（旧数据可能未回原位）: '
                '$backupPath -> $fullPath: $restoreError',
                critical: true);
          }
          rethrow;
        }
        // 落位成功，清理备份。失败仅遗留孤儿备份文件（list 已过滤 .old.
        // 标记，不会被下游当有效数据消费），不影响上传结果。
        try {
          await _op('remove', (t) => _client.remove(backupPath, t));
        } catch (cleanupError) {
          _warn('backup cleanup failed for $backupPath: $cleanupError');
        }
      }
    } catch (e) {
      // 清理临时文件，避免远端残留半成品
      try {
        await _op('remove', (t) => _client.remove(tempPath, t));
      } catch (cleanupError) {
        // 临时文件清理失败记录日志，便于排查远端残留半成品
        _warn('temp file cleanup failed for $tempPath: $cleanupError');
      }
      // 401/403 认证失败：抛专属异常供上层引导用户修正凭据
      if (_isUnauthorized(e)) {
        throw _authExceptionOf(e);
      }
      throw CloudStorageException('Upload failed: $e', e);
    }
  }

  /// 审计 W-A 探测：目标文件已出现且临时文件已消失 → MOVE 实际成功。
  ///
  /// 同一父目录一次列举同时核实两个名字（目标出现 + 临时消失），
  /// 任一探测出错都保守返回 false，走原有错误处理路径。
  Future<bool> _moveLandedAnyway(String tempPath, String fullPath) async {
    try {
      final parentDir = PathHelper.dirname(fullPath);
      final targetName = PathHelper.basename(fullPath);
      final tempName = PathHelper.basename(tempPath);
      final files =
          await _opRetryable('readDir', (t) => _client.readDir(parentDir, t));
      // M1：isDir 缺省统一 `?? true`（见 _findEntry 注释）。
      final targetLanded =
          files.any((f) => !(f.isDir ?? true) && f.name == targetName);
      final tempGone =
          !files.any((f) => !(f.isDir ?? true) && f.name == tempName);
      return targetLanded && tempGone;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> download({required String path}) async {
    try {
      final bytes = await downloadBinary(path: path);
      if (bytes == null) return null;
      // 方案C：信封解包（旧裸文件原样返回，无需迁移）
      final envelope = _tryUnwrapEnvelope(bytes);
      return envelope?.data ?? utf8.decode(bytes);
    } on CloudConfigurationException {
      // WD-Y2：配置类错误（空 path / 尾斜杠拒绝等）是调用方 bug，
      // 原样上抛 —— 与 downloadBinary 的口径一致，不伪装成存储故障
      rethrow;
    } on CloudAuthException {
      // downloadBinary 已识别的认证失败原样透传（不依赖字符串兜底）
      rethrow;
    } catch (e) {
      // 统一用 _isNotFound 判断 404，优先结构化状态码、字符串匹配仅兜底
      if (_isNotFound(e)) {
        return null;
      }
      // 401/403 认证失败需与网络错误区分：上层（如 enableFromCloud 探测）
      // 依赖异常类型引导用户重新配置凭据，误报为网络错误会误导排查方向
      if (_isUnauthorized(e)) {
        throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
      }
      throw CloudStorageException('Download failed: $e', e);
    }
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    _assertFilePath(path);
    // 路径构造（含遍历防护）置于 try 之外：配置类错误必须原样上抛，
    // 不落入下方通用包装变成「存储故障」
    final fullPath = _buildPath(path);
    try {
      // Download file
      final bytes = await _opRetryable(
          'read', (t) => _client.read(fullPath, cancelToken: t));

      final raw = Uint8List.fromList(bytes);
      // 方案C：信封解包 —— 返回调用方写入的原始字节，保证
      // uploadBinary ⇄ downloadBinary 往返一致（信封只是传输载体）
      final envelope = _tryUnwrapEnvelope(raw);
      if (envelope == null) return raw;
      return envelope.b64
          ? base64Decode(envelope.data)
          : utf8.encode(envelope.data);
    } catch (e) {
      if (_isNotFound(e)) {
        return null;
      }
      if (_isUnauthorized(e)) {
        throw _authExceptionOf(e);
      }
      throw CloudStorageException('Download failed: $e', e);
    }
  }

  @override
  Future<void> delete({required String path}) async {
    _assertFilePath(path);
    final fullPath = _buildPath(path);

    // C-02 修复：删除操作应幂等，404（文件不存在）视为成功
    // 审计 WebDAV-T3：DELETE 是幂等操作，此前走 [_op]（无重试）—— 与
    // [_retryIdempotent] 注释「覆盖 remove」及「幂等操作自动重试」的
    // 设计承诺不符，瞬时网络抖动即删除失败。改用 [_opRetryable]。
    try {
      await _opRetryable('remove', (t) => _client.remove(fullPath, t));
    } catch (e) {
      if (_isNotFound(e)) {
        // 文件已不存在，删除幂等成功
      } else if (_isUnauthorized(e)) {
        // 审计 WD-M1：凭据失效必须抛认证异常（与 upload/download/list/
        // exists/getMetadata 及 S3 实现对齐），让上层引导用户改密码，
        // 而不是报成笼统的存储故障。
        throw _authExceptionOf(e);
      } else {
        throw CloudStorageException('Delete failed: $e', e);
      }
    }

    // 删除元数据文件（失败静默忽略，元数据是辅助数据）
    await _deleteMetadata(fullPath);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    try {
      // Build full path
      final fullPath = _buildPath(path);

      // List files（幂等读，自动重试瞬时网络故障）
      final files =
          await _opRetryable('readDir', (t) => _client.readDir(fullPath, t));

      // Convert to CloudFile objects, excluding directories and internal
      // artifacts（sidecar/临时/备份，审计 W-G 统一口径）
      return files
          .where((file) =>
              !(file.isDir ?? true) &&
              !(file.name != null && _isInternalArtifact(file.name!)))
          .map((file) {
        final name = file.name ?? '';
        // 构造相对于 remotePath 的路径，供下游 _buildPath 重新拼接。
        // file.path 为 null 时回退到基于 name 的拼接，而非回退到目录路径，
        // 避免下游把目录路径当成文件路径处理。
        // 审计 WD-L2/B7：入参带尾斜杠时归一化（含根目录 '/' 本身 ——
        // 旧实现的 `length > 1` 守卫让根目录泄漏出带前导斜杠的脏路径
        // `/x.json`，与其余方法的口径不一致）。
        final normalizedDir =
            path.endsWith('/') ? path.substring(0, path.length - 1) : path;
        final relativePath =
            normalizedDir.isEmpty ? name : '$normalizedDir/$name';
        return CloudFile(
          name: name,
          path: relativePath,
          size: file.size,
          lastModified: file.mTime,
          metadata: const {},
          // 方案C：PROPFIND 携带的 getetag 透出，供条件写/写后校验使用
          eTag: _normalizeETag(file.eTag),
        );
      }).toList();
    } catch (e) {
      // H1（审计修复）：目录不存在（404）收敛为空列表，与 S3 的
      // ListObjects 语义对齐（不存在 prefix 返回 200+空集）。此前 404 被
      // 包装成 CloudStorageException 上抛，云端账本发现（discoverRemote
      // Ledgers）静默降级、恢复/全量恢复入口直接报「恢复失败」—— 用户
      // 中途在服务器删目录 / remotePath 指向未建子路径时整条链路中断。
      // 其余错误（网络/认证/权限）照旧上抛，不得误报「空目录」。
      if (_isNotFound(e)) {
        return const <CloudFile>[];
      }
      // 401/403 认证失败：抛专属异常供上层引导用户修正凭据
      if (_isUnauthorized(e)) {
        throw _authExceptionOf(e);
      }
      throw CloudStorageException('List failed: $e', e);
    }
  }

  @override
  Future<bool> exists({required String path}) async {
    _assertFilePath(path);
    final fullPath = _buildPath(path);
    final parentDir = PathHelper.dirname(fullPath);
    final fileName = PathHelper.basename(fullPath);

    try {
      final files =
          await _opRetryable('readDir', (t) => _client.readDir(parentDir, t));
      // 审计 B7：排除目录 —— 同名目录会让 exists()=true 但 download 必败。
      // 审计 W-G：内部产物与 list() 口径一致过滤，消除三态分裂。
      // M1：isDir 缺省统一 `?? true`（见 _findEntry 注释）。
      return files.any((f) =>
          !(f.isDir ?? true) &&
          f.name == fileName &&
          !_isInternalArtifact(fileName));
    } catch (e) {
      // 仅在目录不存在（404）时返回 false；其他错误（网络中断、
      // 403 权限不足等）必须抛出，避免调用方误判文件不存在而触发
      // 覆盖上传等危险操作。
      if (_isNotFound(e)) {
        return false;
      }
      // 401/403 认证失败必须抛出：误判为「不存在」会触发覆盖上传等危险操作
      if (_isUnauthorized(e)) {
        throw _authExceptionOf(e);
      }
      throw CloudStorageException('Failed to check file existence: $e', e);
    }
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    _assertFilePath(path);
    try {
      final fullPath = _buildPath(path);

      // 父目录 Depth-1 扫描定位条目（readProps 对普通文件不可靠，
      // 见 _findEntry 注释）。404 由统一异常分类器收敛为 null。
      final file = await _findEntry(fullPath);
      if (file == null) return null;

      // 元数据来源优先级：
      // 1) 信封内嵌 meta（新格式，随主文件原子写入）
      // 2) sidecar JSON（旧格式裸文件的兼容回退）
      //
      // 注意必须读**原始字节**（信封形态）——downloadBinary 会把信封
      // 解包成业务数据，二次解包永远得到 null。
      //
      // 审计 M10：解析结果按 (path, eTag) 缓存（见 _metaCache 注释），
      // eTag 未变的重复调用零下载。
      final eTag = _normalizeETag(file.eTag);
      final cacheKey =
          (eTag == null || eTag.isEmpty) ? null : '$fullPath\u0000$eTag';
      Map<String, dynamic> customMetadata;
      final cached = cacheKey == null ? null : _metaCache[cacheKey];
      if (cached != null) {
        customMetadata = cached;
      } else {
        final resolved = await _resolveCustomMetadata(fullPath);
        if (resolved == null) {
          // 瞬时故障：维持既有「元数据缺失」降级语义，但不落缓存——
          // 否则一次网络抖动会把这个 eTag 的元数据钉死为空，后续
          // getStatus 永远拿不到 fingerprint 而反复全量回退
          customMetadata = const {};
        } else {
          customMetadata = resolved;
          if (cacheKey != null) {
            _cacheMeta(cacheKey, resolved);
          }
        }
      }

      return CloudFile(
        name: PathHelper.basename(fullPath),
        // 口径对齐其余方法（upload/download/delete/list）：返回**逻辑相对
        // 路径**（即调用方传入的 path），保证 getMetadata 的返回值可直接
        // 回传给 _buildPath 重新拼接而不产生双前缀。file.path 是 webdav_client
        // 返回的服务端绝对路径，混出去会让下游把目录前缀拼两遍。
        path: path,
        size: file.size,
        lastModified: file.mTime,
        metadata: customMetadata,
        eTag: _normalizeETag(file.eTag),
      );
    } catch (e) {
      // 401/403 认证失败需原样抛出：下方其余异常上抛为通用存储故障，
      // 认证错误必须可区分以引导用户改凭据
      if (_isUnauthorized(e)) {
        throw _authExceptionOf(e);
      }
      // 仅「确认不存在」收敛为 null（接口契约：getMetadata 缺失返回 null）；
      // 超时/网络等其余故障一律上抛，绝不静默变成「云端无元数据」
      throw CloudStorageException('Get metadata failed: $e', e);
    }
  }

  /// M10：解析元数据（信封内嵌 meta → sidecar 回退）。
  ///
  /// 返回 null 表示解析过程遭遇瞬时故障（调用方不缓存）；
  /// 非 null（含空 Map）为稳定解析结果（sidecar 缺失的 404 亦属稳定，
  /// 旧格式裸文件本就无 sidecar），调用方可按 eTag 缓存。
  Future<Map<String, dynamic>?> _resolveCustomMetadata(String fullPath) async {
    try {
      final rawBytes = await _opRetryable(
          'read', (t) => _client.read(fullPath, cancelToken: t));
      final envelope = _tryUnwrapEnvelope(Uint8List.fromList(rawBytes));
      if (envelope?.meta != null) {
        return envelope!.meta!;
      }
      return await _getMetadata(fullPath);
    } catch (e) {
      _warn('metadata source read failed for $fullPath: $e');
      return null;
    }
  }

  /// Builds the full path with remote path prefix.
  ///
  /// 审计 W-D：拒绝 `..` 段 —— `PathHelper.normalize` 只折叠斜杠不解析
  /// 相对段，`../` 会逐级消解后**完全逃逸 remotePath 沙箱**（对齐 S3 侧
  /// `_assertNoTraversal` 的防护）。
  String _buildPath(String path) {
    _assertNoTraversal(path);
    return PathHelper.join([_remotePath, path]);
  }

  /// 按分段校验拒绝父目录引用（不误伤 `ledger..backup.json`）。
  ///
  /// 审计 N-1（2026-09-12）：分段校验按未解码的 `/` 切分存在编码盲区 ——
  /// `%2e%2e`（URL 编码的 `..`）与 `\..`（反斜杠形态）在部分服务器解码/
  /// 归一化后同样构成父目录引用。校验前做防御性归一化：反斜杠统一转斜杠
  /// + 尝试一层 URI 解码（失败保持原判定），对原始与归一化两种形态分别
  /// 分段校验。归一化仅用于校验，不改变实际传输的路径值。
  static void _assertNoTraversal(String value) {
    final normalized = value.replaceAll('\\', '/');
    for (final candidate in <String>[normalized, _decodeLoosely(normalized)]) {
      for (final seg in candidate.split('/')) {
        if (seg == '..') {
          throw CloudConfigurationException(
              'Invalid path containing ".." segment: $value');
        }
      }
    }
  }

  /// N-1：防御性 URI 解码（与 WebDAVProvider._decodeLoosely 同口径）。
  static String _decodeLoosely(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  /// 审计 W-X：401 与 403 分开表述 —— 401 才是凭据错误（改密码），
  /// 403 多为权限不足（目录 ACL / 配额），一律让用户改密码会误导排查。
  /// 两者同为 [CloudAuthException]（RetryHelper 对认证类均不重试，
  /// 类型语义不变，仅文案更准确）。
  CloudAuthException _authExceptionOf(Object e) {
    final code = _statusCodeOf(e);
    if (code == 403) {
      return CloudAuthException('WebDAV 访问被拒绝（权限不足）：请检查账号对该目录的读写权限或服务器配额', e);
    }
    return CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
  }

  /// 提取异常携带的结构化 HTTP 状态码（dio 系异常），无则返回 null。
  ///
  /// webdav_client 内部抛出的是 dio 的 DioException（带 response.statusCode），
  /// 这里用 dynamic 访问 response 字段以避免引入 dio 直接依赖。
  int? _statusCodeOf(Object e) {
    try {
      final dynamic dyn = e;
      final dynamic response = dyn.response;
      if (response != null) {
        final dynamic code = response.statusCode;
        if (code is int) return code;
      }
    } catch (_) {
      // 非 dio 异常类型，无 response 字段
    }
    return null;
  }

  /// 统一判断 WebDAV 404 错误，优先使用结构化状态码，字符串匹配仅作兜底。
  ///
  /// M5：只要异常携带了结构化 response，就**只**按状态码判定 —— 字符串
  /// 兜底仅在完全无结构化信息时使用。之前「有 response 但非 404」也会
  /// 落到字符串匹配，而 DioException.toString() 内嵌完整 URL：文件名含
  /// "404"/"not found" 子串时（如 backup404.json），任何网络层错误都会
  /// 被误判为文件不存在 → exists()=false → 触发覆盖上传等危险操作。
  ///
  /// 审计 WD-M3：无结构化信息的异常（SocketException 等）消息常内嵌
  /// host:port（如 `10.0.40.35:8404`），**纯数字子串匹配必然误判**
  /// （8404 含 "404"、端口含 "401"/"403" 同理）。故兜底只做明确的措辞
  /// 匹配，彻底移除数字子串 —— 连接层失败本就不该被归类为任何 HTTP 状态。
  bool _isNotFound(Object e) {
    final code = _statusCodeOf(e);
    if (code != null) {
      return code == 404;
    }
    // 兜底：仅当确实无结构化信息时使用措辞匹配（不做数字子串匹配）
    final msg = e.toString().toLowerCase();
    return msg.contains('not found') ||
        msg.contains('does not exist') ||
        msg.contains('no such file') ||
        msg.contains('no such resource');
  }

  /// 统一判断 WebDAV 401/403 认证失败，策略与 [_isNotFound] 一致：
  /// 有结构化状态码只看状态码；字符串兜底仅限无结构化信息时的措辞匹配，
  /// 不做纯数字子串匹配（WD-M3 同款理由）。
  ///
  /// 认证失败与网络故障对用户的处置动作完全不同（改凭据 vs 查网络），
  /// 必须区分抛出 [CloudAuthException]，避免上层统一报「请检查网络」。
  bool _isUnauthorized(Object e) {
    final code = _statusCodeOf(e);
    if (code != null) {
      return code == 401 || code == 403;
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('unauthorized') || msg.contains('forbidden');
  }

  /// 判断 rename(MOVE overwrite=true) 失败是否源于「服务器不支持覆盖式 MOVE」。
  ///
  /// 仅这类错误允许进入 uploadBinary 的交换式降级流程；网络中断、超时等
  /// 瞬时故障绝不能触发降级（审计 WD-1）。有结构化状态码只认 405/409/412；
  /// 字符串兜底只匹配方法/前置条件类明确措辞，不匹配纯数字（避免撞上
  /// 异常消息内嵌的 URL 端口等子串）。
  bool _isOverwriteUnsupported(Object e) {
    final code = _statusCodeOf(e);
    if (code != null) {
      // 405 Method Not Allowed / 409 Conflict / 412 Precondition Failed /
      // 501 Not Implemented（RFC 4918 明确定义为「服务器不支持该方法」——
      // 部分服务器仅对 Overwrite: T 的覆盖式 MOVE 返回 501，而交换降级
      // 使用的 Overwrite: F MOVE 仍可用）。
      //
      // 423 Locked 有意不纳入：被锁资源同样会挡住交换降级自身的 MOVE
      //（先 `full → backup` 即 423），降级无法成功，纳入只会多一次无效尝试。
      return code == 405 || code == 409 || code == 412 || code == 501;
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('method not allowed') ||
        msg.contains('precondition failed') ||
        msg.contains('not implemented') ||
        msg.contains('conflict');
  }

  /// Ensures a directory exists, creating it if necessary.
  ///
  /// M-04 修复：仅在 404（目录不存在）时触发创建流程；
  /// 网络中断、403 权限不足、500 服务器错误等异常直接向上传播，
  /// 避免掩盖真实问题导致误导性的 mkdir 调用。
  Future<void> _ensureDirectory(String dirPath) async {
    try {
      await _op('readDir', (t) => _client.readDir(dirPath, t));
      // readDir 成功，目录已存在
      return;
    } catch (e) {
      if (_isNotFound(e)) {
        // 目录不存在，创建它
        await _createDirectoryRecursively(dirPath);
      } else {
        // 网络错误、权限不足等不应触发目录创建
        rethrow;
      }
    }
  }

  /// Creates a directory recursively.
  ///
  /// 采用「先 mkdir 再验证」策略：readDir 探测失败后直接 mkdir，
  /// 若 mkdir 抛 405/409（目录已存在，常见于并发创建），再 readDir
  /// 验证一次确认目录确实存在，避免把并发竞态误判为创建失败。
  Future<void> _createDirectoryRecursively(String dirPath) async {
    final parts = dirPath.split('/').where((p) => p.isNotEmpty).toList();
    var currentPath = '';

    for (final part in parts) {
      currentPath = currentPath.isEmpty ? part : '$currentPath/$part';
      try {
        await _op('readDir', (t) => _client.readDir(currentPath, t));
        // 目录已存在，继续下一级
      } catch (e) {
        // 目录可能不存在，尝试创建
        try {
          await _op('mkdir', (t) => _client.mkdir(currentPath, t));
        } catch (createError) {
          // mkdir 失败可能是并发创建（405/409），再验证一次。
          // 审计 B6：判定口径与包内 M5/WD-M3 对齐 —— 有结构化状态码只认
          // 状态码，措辞兜底仅限无结构化信息时；**不做纯数字子串匹配**
          // （异常消息内嵌的 URL 端口如 :8405/:8409 必然误判「已存在」）。
          final code = _statusCodeOf(createError);
          final maybeAlreadyExists = code != null
              ? (code == 405 || code == 409)
              : (() {
                  final msg = createError.toString().toLowerCase();
                  return msg.contains('already exists') ||
                      msg.contains('conflict');
                })();
          if (maybeAlreadyExists) {
            try {
              await _op('readDir', (t) => _client.readDir(currentPath, t));
              // 验证成功，目录确实存在（由其他进程创建）
            } catch (_) {
              // 验证也失败，说明是真实错误。审计 B6：抛**原始 mkdir 错误**
              // 而非 rethrow（Dart 的 rethrow 重抛的是最近一层 catch 的
              // readDir 异常，会掩盖根因）
              throw createError;
            }
          } else {
            // 非「已存在」类错误，向上抛出
            rethrow;
          }
        }
      }
    }
  }

  /// Retrieves custom metadata from JSON sidecar（旧格式裸文件的兼容回退）。
  ///
  /// 方案C 后新上传均为信封自包含，本方法仅服务旧版裸文件：信封无 meta
  /// 时回退读 sidecar。不再有写入方 —— 新上传的元数据内嵌于信封。
  Future<Map<String, dynamic>> _getMetadata(String filePath) async {
    try {
      final metadataPath = '$filePath.metadata.json';
      final bytes = await _opRetryable(
          'read', (t) => _client.read(metadataPath, cancelToken: t));
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return json['metadata'] as Map<String, dynamic>? ?? {};
    } catch (e) {
      // 审计修复：sidecar 不存在（从未写过/已被清理）是常态，静默返回空；
      // 超时/网络抖动等真实故障也返回空 map（指纹缺失 → 上层走全量下载
      // 兜底，安全设计不变），但必须留下告警 —— 否则弱网下反复全量下载
      // 无从排查。
      if (!_isNotFound(e)) {
        _warn('metadata sidecar read failed for $filePath: $e');
      }
      return {};
    }
  }

  /// Deletes custom metadata file.
  Future<void> _deleteMetadata(String filePath) async {
    try {
      final metadataPath = '$filePath.metadata.json';
      await _op('remove', (t) => _client.remove(metadataPath, t));
    } catch (e) {
      // 元数据是辅助数据，删除失败（如文件本就不存在）不阻塞主流程，
      // 但记录 warning 便于排查，与 _storeMetadata 的日志策略保持一致
      _warn('metadata delete failed for $filePath: $e');
    }
  }
}
