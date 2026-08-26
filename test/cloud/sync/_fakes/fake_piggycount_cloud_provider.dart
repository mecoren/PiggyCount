// FakePiggyCountCloudProvider — SyncEngine e2e 测试的 in-memory 替身。
//
// 设计:
//   - extends PiggyCountCloudProvider 真类(默认构造无副作用,_auth/_storage
//     在 initialize() 调用后才被设)
//   - 覆盖 baseUrl / apiPrefix / auth / storage getter 返 fake 实例
//   - 覆盖 SyncEngine 实际用到的 ~20 个方法,内存模拟 server 状态
//   - 未实现的方法抛 UnimplementedError,测试碰到说明该补
//
// 用法:见 `sync_engine_e2e_test.dart`。
//
// Day 1 范围:pull / push / readLedgers / storage.list + basic auth getter,
// 足够覆盖核心 pull/apply 测试场景。其它方法(附件 / WS / profile / shared
// resources)留待 Day 2 按需补。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

// =====================================================================
// FakePiggyCountCloudAuthService — extends 真类,覆盖 currentUserId/currentDeviceId
// =====================================================================

class FakePiggyCountCloudAuthService extends PiggyCountCloudAuthService {
  FakePiggyCountCloudAuthService({
    String? userId = 'test-user-id',
    String? deviceId = 'test-device-id',
  })  : _userId = userId,
        _deviceId = deviceId,
        super(baseUrl: 'https://fake.test', apiPrefix: '/api/v1');

  String? _userId;
  String? _deviceId;

  // 覆盖 PiggyCountCloudAuthService 自身的 getter(不在 CloudAuthService 接口
  // 内但 AppCursorStore 强 cast 后用到)
  @override
  String? get currentUserId => _userId;

  @override
  String? get currentDeviceId => _deviceId;

  // CloudAuthService 抽象接口实现 — fake 不真做认证
  @override
  Future<CloudUser?> get currentUser async =>
      _userId == null ? null : CloudUser(id: _userId!);

  /// 测试入口:模拟用户登录 / 登出
  void setLoggedIn({String? userId = 'test-user-id', String? deviceId = 'test-device-id'}) {
    _userId = userId;
    _deviceId = deviceId;
  }
}

// =====================================================================
// FakePiggyCountCloudStorageService — 内存模拟 storage(用于 fullPush JSON 等)
// =====================================================================

class FakePiggyCountCloudStorageService implements CloudStorageService {
  final Map<String, String> _files = {};
  final Map<String, Map<String, String>?> _metadata = {};

  /// 测试 helper:模拟 server 端账本列表(`storage.list(path: '')` 返回)
  final List<CloudFile> ledgerSnapshots = [];

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    _files[path] = data;
    _metadata[path] = metadata;
  }

  @override
  Future<String?> download({required String path}) async {
    return _files[path];
  }

  @override
  Future<void> delete({required String path}) async {
    _files.remove(path);
    _metadata.remove(path);
    ledgerSnapshots.removeWhere((f) => f.path == path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    // 测试关注的是"远端账本列表",由 [ledgerSnapshots] 控制
    return List.unmodifiable(ledgerSnapshots);
  }

  @override
  Future<bool> exists({required String path}) async {
    return _files.containsKey(path) ||
        ledgerSnapshots.any((f) => f.path == path);
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    if (!_files.containsKey(path) &&
        !ledgerSnapshots.any((f) => f.path == path)) {
      return null;
    }
    return CloudFile(name: path, path: path);
  }

  /// 测试 helper：直接塞入可下载文件内容（fullPull 守卫等场景，
  /// 需要保证「若无守卫则恢复必然执行」的对照前提）
  void seedFile({required String path, required String content}) {
    _files[path] = content;
  }
}

// =====================================================================
// FakePiggyCountCloudProvider — 主入口
// =====================================================================

class FakePiggyCountCloudProvider extends PiggyCountCloudProvider {
  FakePiggyCountCloudProvider({
    String? userId = 'test-user-id',
    String? deviceId = 'test-device-id',
  }) {
    _fakeAuth = FakePiggyCountCloudAuthService(
      userId: userId,
      deviceId: deviceId,
    );
    _fakeStorage = FakePiggyCountCloudStorageService();
  }

  late final FakePiggyCountCloudAuthService _fakeAuth;
  late final FakePiggyCountCloudStorageService _fakeStorage;

  /// In-memory server 状态:全部 sync_changes 流。
  /// 测试通过 [pushFakeChange] 往里塞;[pullChanges] 按 since 切片返回。
  final List<PiggyCountCloudSyncChange> _serverChanges = [];

  /// 在线 ledger list(server 端 `/sync/ledgers` 返回)。
  /// 测试通过 [pushFakeLedger] 注入。
  final List<PiggyCountCloudReadLedger> _serverLedgers = [];

  /// 历次 push 操作记录(用于断言"几次 push" / "推了哪些 change")
  final List<List<Map<String, dynamic>>> pushedBatches = [];

  /// 历次 pullChanges 调用记录(用于断言"几次 pull" / "since 序列")
  final List<({int? since, int limit, bool persistCursor})> pullCalls = [];

  /// 控制 pullChanges 是否抛错(测试错误恢复路径)
  Exception Function(int? since)? pullErrorInjector;

  /// 控制 storage.list 是否抛错
  Exception? storageListError;

  final StreamController<PiggyCountCloudRealtimeEvent> _realtimeController =
      StreamController<PiggyCountCloudRealtimeEvent>.broadcast();

  // ====== 覆盖 PiggyCountCloudProvider getter ======

  @override
  String? get baseUrl => 'https://fake.test';

  @override
  String? get apiPrefix => '/api/v1';

  @override
  CloudAuthService get auth => _fakeAuth;

  @override
  CloudStorageService get storage {
    if (storageListError != null) {
      // 注入错误时,let 调用方拿到 storage 后再抛
      // (实际上 list() 内部检查 storageListError 抛)
    }
    return _StorageProxy(_fakeStorage, () => storageListError);
  }

  // ====== 覆盖 SyncEngine 用到的方法 ======

  @override
  Future<PiggyCountCloudPullResult> pullChanges({
    int? since,
    int limit = 1000,
    bool persistCursor = true,
  }) async {
    pullCalls.add((since: since, limit: limit, persistCursor: persistCursor));
    final injector = pullErrorInjector;
    if (injector != null) {
      final err = injector(since);
      // ignore: only_throw_errors
      throw err;
    }
    final from = since ?? 0;
    final unread = _serverChanges.where((c) => c.changeId > from).toList();
    final slice = unread.take(limit).toList();
    // 真实 server 语义：server_cursor 是服务端当前全局头部，与 since 回显无关。
    // （审计 S2 测试需要：自愈 probe since=超大值时也必须拿到真实头部，
    //   否则游标被推到 since 本身，后续新增量会被永久跳过。）
    // 空流分支同样必须返真实头部（0）而非回显 since —— 否则 SYNC-11 的
    // 轻量探针 pullChanges(since: 1<<40) 会拿到 1<<40 > 本地游标，
    // getStatus 永远误判 cloudNewer。
    final head = _serverChanges.isEmpty
        ? 0
        : _serverChanges.map((c) => c.changeId).reduce((a, b) => a > b ? a : b);
    return PiggyCountCloudPullResult(
      changes: slice,
      serverCursor: slice.isEmpty ? head : slice.last.changeId,
      hasMore: unread.length > slice.length,
    );
  }

  @override
  Future<void> pushChanges({
    required List<Map<String, dynamic>> changes,
  }) async {
    pushedBatches.add(changes);
  }

  @override
  Future<List<PiggyCountCloudReadLedger>> readLedgers() async {
    return List.unmodifiable(_serverLedgers);
  }

  @override
  Stream<PiggyCountCloudRealtimeEvent> get realtimeEvents =>
      _realtimeController.stream;

  @override
  Future<void> startRealtime() async {
    // no-op:测试不真起 WS
  }

  // ====== Testing helpers ======

  /// 模拟 server 推一条 sync_change(`change_id` 自增)。
  /// caller 通过 [WS 触发](调 [emitRealtimeEvent])或者让 client 主动 pull 拉到。
  PiggyCountCloudSyncChange pushFakeChange({
    String entityType = 'transaction',
    required String entitySyncId,
    String ledgerId = '',
    String action = 'upsert',
    Map<String, dynamic>? payload,
    String updatedByDeviceId = 'remote-device',
    int? changeId, // 审计 S3：测试注入显式 id（默认仍自增）
  }) {
    final change = PiggyCountCloudSyncChange(
      changeId: changeId ?? _serverChanges.length + 1,
      ledgerId: ledgerId,
      entityType: entityType,
      entitySyncId: entitySyncId,
      action: action,
      updatedByDeviceId: updatedByDeviceId,
      updatedAt: '2026-05-24T10:00:00Z',
      payload: payload,
    );
    _serverChanges.add(change);
    return change;
  }

  /// 模拟 server 端的账本列表(`/sync/ledgers` 返)。
  /// [monthStartDay] 不传模拟老 server 未返该字段(null 哨兵)。
  void pushFakeLedger({
    required String ledgerId,
    String ledgerName = 'Fake Ledger',
    String currency = 'CNY',
    String role = 'owner',
    bool isShared = false,
    int memberCount = 1,
    int? monthStartDay,
    DateTime? updatedAt,
  }) {
    _serverLedgers.add(PiggyCountCloudReadLedger(
      ledgerId: ledgerId,
      ledgerName: ledgerName,
      currency: currency,
      role: role,
      isShared: isShared,
      memberCount: memberCount,
      monthStartDay: monthStartDay,
      updatedAt: updatedAt ?? DateTime.now(),
      transactionCount: 0,
      incomeTotal: 0,
      expenseTotal: 0,
      balance: 0,
    ));
  }

  /// 模拟 server 推 WS 事件
  void emitRealtimeEvent(PiggyCountCloudRealtimeEvent event) {
    _realtimeController.add(event);
  }

  /// 添加 ledger snapshot(`storage.list(path: '')` 返回)— fullPush 决策用
  void pushFakeLedgerSnapshot({
    required String ledgerId,
  }) {
    _fakeStorage.ledgerSnapshots.add(CloudFile(
      name: ledgerId,
      path: ledgerId,
    ));
  }

  /// 测试 helper：塞入可下载文件（透传 [_fakeStorage.seedFile]）
  void seedStorageFile({required String path, required String content}) {
    _fakeStorage.seedFile(path: path, content: content);
  }

  /// 清空所有 in-memory 状态
  void reset() {
    _serverChanges.clear();
    _serverLedgers.clear();
    pushedBatches.clear();
    pullCalls.clear();
    pullErrorInjector = null;
    storageListError = null;
    _fakeStorage.ledgerSnapshots.clear();
  }

  // ====== 附件 / 图标 ======

  /// in-memory 附件 store:fileId → bytes
  final Map<String, Uint8List> uploadedAttachments = {};
  /// 测试可塞预定义内容供 download
  final Map<String, Uint8List> downloadableAttachments = {};
  /// 记录每次 uploadAttachment 调用(并发场景断言用)
  final List<String> uploadAttachmentCalls = [];

  @override
  Future<PiggyCountCloudAttachmentUploadResult> uploadAttachment({
    required String ledgerId,
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  }) async {
    uploadAttachmentCalls.add(fileName);
    final fileId =
        'fake-attachment-${uploadedAttachments.length + 1}-$fileName';
    uploadedAttachments[fileId] = bytes;
    return PiggyCountCloudAttachmentUploadResult(
      fileId: fileId,
      ledgerId: ledgerId,
      sha256: 'fakesha256-$fileId',
      size: bytes.length,
      mimeType: mimeType,
      fileName: fileName,
    );
  }

  @override
  Future<Uint8List> downloadAttachment({required String fileId}) async {
    final bytes = downloadableAttachments[fileId] ?? uploadedAttachments[fileId];
    if (bytes == null) {
      throw CloudStorageException(
          'Fake: attachment not found: $fileId');
    }
    return bytes;
  }

  @override
  Future<PiggyCountCloudAttachmentUploadResult> uploadCategoryIcon({
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  }) async {
    final fileId = 'fake-icon-${uploadedAttachments.length + 1}-$fileName';
    uploadedAttachments[fileId] = bytes;
    return PiggyCountCloudAttachmentUploadResult(
      fileId: fileId,
      ledgerId: '',
      sha256: 'fakesha256-$fileId',
      size: bytes.length,
      mimeType: mimeType,
      fileName: fileName,
    );
  }

  // ====== fullPush 路径用 ======

  final List<PiggyCountCloudWriteCommitMeta> writeCreateLedgerCalls = [];

  @override
  Future<PiggyCountCloudWriteCommitMeta> writeCreateLedger({
    String? ledgerId,
    required String ledgerName,
    String currency = 'CNY',
    String? idempotencyKey,
  }) async {
    final meta = PiggyCountCloudWriteCommitMeta(
      ledgerId: ledgerId ?? 'auto-$ledgerName',
      baseChangeId: 0,
      newChangeId: _serverChanges.length + 1,
      serverTimestamp: DateTime.now().toUtc(),
      idempotencyReplayed: false,
    );
    writeCreateLedgerCalls.add(meta);
    return meta;
  }

  @override
  Future<PiggyCountCloudProfile> getMyProfile() async {
    throw UnimplementedError('FakeProvider.getMyProfile');
  }

  @override
  Future<PiggyCountCloudLedgerStats> readLedgerStats({
    required String ledgerId,
  }) async {
    throw UnimplementedError('FakeProvider.readLedgerStats');
  }

  @override
  Future<PiggyCountCloudSharedResources> fetchSharedResources({
    required String ledgerId,
  }) async {
    throw UnimplementedError('FakeProvider.fetchSharedResources');
  }
}

/// 让 storage.list 也能注入错误(因为 storage getter 本身返 fake,内部 list
/// 调用时检查注入错误)。
class _StorageProxy implements CloudStorageService {
  _StorageProxy(this._real, this._errorGetter);
  final FakePiggyCountCloudStorageService _real;
  final Exception? Function() _errorGetter;

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) =>
      _real.upload(path: path, data: data, metadata: metadata);

  @override
  Future<String?> download({required String path}) =>
      _real.download(path: path);

  @override
  Future<void> delete({required String path}) => _real.delete(path: path);

  @override
  Future<List<CloudFile>> list({required String path}) async {
    final err = _errorGetter();
    if (err != null) {
      // ignore: only_throw_errors
      throw err;
    }
    return _real.list(path: path);
  }

  @override
  Future<bool> exists({required String path}) => _real.exists(path: path);

  @override
  Future<CloudFile?> getMetadata({required String path}) =>
      _real.getMetadata(path: path);
}
