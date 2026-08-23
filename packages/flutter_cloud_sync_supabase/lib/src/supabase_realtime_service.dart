library;

import 'dart:async';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// Supabase implementation of [RealtimeChannel].
class SupabaseRealtimeChannel implements RealtimeChannel {
  final supabase.RealtimeChannel _channel;
  // 使用传入的 client 而非全局单例执行 removeChannel，
  // 避免多实例场景下误操作非本实例管理的连接（P-M5）
  final supabase.SupabaseClient _client;
  // 缓存 channel name，避免访问 _channel.topic（supabase 包内部成员）
  final String _name;
  // 通过 subscribe 回调追踪最新订阅状态，避免访问 SDK 内部成员，
  // 也避免在 subscribe() 中立即标记为已订阅（SDK 实际是异步建联）（C5）
  // 注：当前 SDK (realtime_client 2.13.0) 未提供 status getter / onStatus 方法，
  // 故通过 subscribe 回调捕获状态。
  supabase.RealtimeSubscribeStatus? _status;
  // 服务级状态回调，由 SupabaseRealtimeService 注入，
  // 用于将单个 channel 的状态变化反向更新服务级连接状态（C3）
  void Function(supabase.RealtimeSubscribeStatus status, Object? error)?
      onStatusChange;

  SupabaseRealtimeChannel(
    this._channel,
    this._client, {
    required String name,
  }) : _name = name;

  @override
  RealtimeChannel onPostgresChanges({
    required String event,
    required String schema,
    required String table,
    String? filter,
    required void Function(Map<String, dynamic> payload) callback,
  }) {
    _channel.onPostgresChanges(
      event: _parsePostgresEvent(event),
      schema: schema,
      table: table,
      filter: filter != null ? _parseEqFilter(filter) : null,
      callback: (payload) {
        // Convert Supabase payload to our format
        final data = <String, dynamic>{
          'eventType': payload.eventType.name.toUpperCase(),
          'new': payload.newRecord,
          'old': payload.oldRecord,
          'table': payload.table,
          'schema': payload.schema,
          'commitTimestamp': payload.commitTimestamp,
        };
        callback(data);
      },
    );

    return this;
  }

  @override
  RealtimeChannel on(
    String event,
    void Function(Map<String, dynamic> payload) callback,
  ) {
    _channel.onBroadcast(
      event: event,
      callback: (payload) {
        callback(payload);
      },
    );

    return this;
  }

  @override
  Future<void> send({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    await _channel.sendBroadcastMessage(
      event: event,
      payload: payload,
    );
  }

  @override
  Future<void> subscribe() async {
    // supabase 的 RealtimeChannel.subscribe() 返回 RealtimeChannel（非 Future），
    // 用于链式调用，此处不需要 await。
    // 通过 SDK 提供的状态回调追踪真实订阅状态（C5）：不再在调用后立即标记为已订阅，
    // 而是等待 SDK 在建联成功/失败/超时/关闭时回调。
    // 同时将状态变化转发给服务级回调以更新连接状态（C3）。
    _channel.subscribe((status, error) {
      _status = status;
      onStatusChange?.call(status, error);
    });
  }

  @override
  Future<void> unsubscribe() async {
    // 使用构造时注入的 client 而非全局单例，确保操作的是本实例的连接（P-M5）
    await _client.removeChannel(_channel);
  }

  @override
  String get name => _name;

  @override
  String get state {
    // 映射 SDK 真实订阅状态，避免在 subscribe() 后立即返回 'subscribed'（C5）。
    // 当前 SDK 枚举仅含 4 个值（无 waiting），未订阅时 _status 为 null。
    final status = _status;
    if (status == null) return 'closed';
    switch (status) {
      case supabase.RealtimeSubscribeStatus.subscribed:
        return 'subscribed';
      case supabase.RealtimeSubscribeStatus.closed:
        return 'closed';
      case supabase.RealtimeSubscribeStatus.timedOut:
        return 'timed_out';
      case supabase.RealtimeSubscribeStatus.channelError:
        return 'error';
    }
  }

  /// Parse event string to Supabase event type
  supabase.PostgresChangeEvent _parsePostgresEvent(String event) {
    switch (event.toUpperCase()) {
      case 'INSERT':
        return supabase.PostgresChangeEvent.insert;
      case 'UPDATE':
        return supabase.PostgresChangeEvent.update;
      case 'DELETE':
        return supabase.PostgresChangeEvent.delete;
      case '*':
      case 'ALL':
        return supabase.PostgresChangeEvent.all;
      default:
        return supabase.PostgresChangeEvent.all;
    }
  }

  /// 解析 "column=value" / "column=op.value" 格式的过滤器。
  ///
  /// 审计 S20：manager（database_sync_manager.dart）生成的是 PostgREST
  /// 线格式（如 `ledger_id=eq.123`、`status=in.(a,b)`），旧实现把首个 `=`
  /// 之后整体当值——`eq.` 前缀被并入值导致过滤器永不命中，realtime
  /// 订阅静默失效。此处正确解析操作符并映射到 SDK 枚举：
  /// - 无操作符前缀 → 按 eq 处理（向后兼容旧调用方）
  /// - 支持 eq/neq/lt/lte/gt/gte/like/ilike
  /// - 多条件（逗号拼接）与 in/is 等复合值显式拒绝——本包装的
  ///   onPostgresChanges 每次注册只接受单个过滤器对象，
  ///   静默丢弃条件比快速失败更危险
  supabase.PostgresChangeFilter _parseEqFilter(String filter) {
    final eqIdx = filter.indexOf('=');
    if (eqIdx <= 0 || eqIdx == filter.length - 1) {
      throw ArgumentError(
        'Invalid realtime filter "$filter", '
        'expected "column=value" or "column=op.value"',
      );
    }
    final column = filter.substring(0, eqIdx).trim();
    var rest = filter.substring(eqIdx + 1).trim();

    if (rest.contains(',')) {
      throw ArgumentError(
        'Multi-condition realtime filter "$filter" is not supported by this '
        'wrapper; register one filter per condition instead',
      );
    }

    const operators = <String, supabase.PostgresChangeFilterType>{
      'eq': supabase.PostgresChangeFilterType.eq,
      'neq': supabase.PostgresChangeFilterType.neq,
      'lt': supabase.PostgresChangeFilterType.lt,
      'lte': supabase.PostgresChangeFilterType.lte,
      'gt': supabase.PostgresChangeFilterType.gt,
      'gte': supabase.PostgresChangeFilterType.gte,
      'like': supabase.PostgresChangeFilterType.like,
      'ilike': supabase.PostgresChangeFilterType.ilike,
    };

    var type = supabase.PostgresChangeFilterType.eq;
    final dot = rest.indexOf('.');
    if (dot > 0) {
      final head = rest.substring(0, dot);
      final mapped = operators[head];
      if (mapped != null) {
        type = mapped;
        rest = rest.substring(dot + 1);
      }
    }

    // 剥掉外层引号（manager 对保留字符值会生成 col=eq."abc"）；
    // SDK 序列化时按需自行加引号，这里不剥会双重引用导致不匹配。
    if (rest.length >= 2 && rest.startsWith('"') && rest.endsWith('"')) {
      rest = rest.substring(1, rest.length - 1);
    }

    return supabase.PostgresChangeFilter(
      type: type,
      column: column,
      value: rest,
    );
  }
}

/// Supabase implementation of [CloudRealtimeService].
///
/// Provides WebSocket-based realtime communication for Supabase.
///
/// Example:
/// ```dart
/// final client = supabase.Supabase.instance.client;
/// final realtimeService = SupabaseRealtimeService(client);
///
/// // Monitor connection state
/// realtimeService.connectionState.listen((state) {
///   print('Connection: $state');
/// });
///
/// // Create a channel
/// final channel = realtimeService.channel('transactions:123');
///
/// // Listen to database changes
/// channel.onPostgresChanges(
///   event: '*',
///   schema: 'public',
///   table: 'transactions',
///   filter: 'ledger_id=eq.123',
///   callback: (payload) {
///     print('Change: ${payload['eventType']}');
///   },
/// );
///
/// await channel.subscribe();
/// ```
class SupabaseRealtimeService implements CloudRealtimeService {
  final supabase.SupabaseClient _client;
  final Map<String, RealtimeChannel> _channels = {};
  final StreamController<RealtimeConnectionState> _connectionStateController =
      StreamController<RealtimeConnectionState>.broadcast();

  RealtimeConnectionState _currentState = RealtimeConnectionState.disconnected;

  SupabaseRealtimeService(this._client) {
    _initializeConnectionMonitoring();
  }

  /// Initialize connection state monitoring
  void _initializeConnectionMonitoring() {
    // Monitor Supabase realtime connection status
    // Note: Supabase doesn't expose a direct connection state stream
    // We infer state from channel subscriptions and socket events
    _updateConnectionState(
      _client.realtime.isConnected
          ? RealtimeConnectionState.connected
          : RealtimeConnectionState.disconnected,
    );
  }

  @override
  Stream<RealtimeConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  RealtimeConnectionState get currentState => _currentState;

  @override
  RealtimeChannel channel(String channelName) {
    // Return existing channel if already created
    if (_channels.containsKey(channelName)) {
      return _channels[channelName]!;
    }

    // Create new Supabase channel
    final supabaseChannel = _client.channel(channelName);

    // Wrap in our interface，传入 _client 用于 unsubscribe（P-M5）
    final channel =
        SupabaseRealtimeChannel(supabaseChannel, _client, name: channelName);

    // 注入状态回调：将单个 channel 的订阅状态变化反向更新服务级连接状态，
    // 避免仅依赖初始化时的一次快照（C3）。
    // 当前 SDK 未提供 onStatus 方法，故通过 subscribe 回调转发（见 channel.subscribe）。
    channel.onStatusChange = (status, _) {
      switch (status) {
        case supabase.RealtimeSubscribeStatus.subscribed:
          _updateConnectionState(RealtimeConnectionState.connected);
          break;
        case supabase.RealtimeSubscribeStatus.closed:
        case supabase.RealtimeSubscribeStatus.timedOut:
        case supabase.RealtimeSubscribeStatus.channelError:
          _updateConnectionState(RealtimeConnectionState.disconnected);
          break;
      }
    };

    // Cache channel
    _channels[channelName] = channel;

    return channel;
  }

  @override
  Future<void> removeChannel(String channelName) async {
    final channel = _channels[channelName];
    if (channel == null) return;
    // 先 unsubscribe 成功后再从缓存移除，避免 unsubscribe 失败时
    // 缓存已被清空导致调用方无法重试（P-M3）
    try {
      await channel.unsubscribe();
    } finally {
      _channels.remove(channelName);
    }
  }

  @override
  Future<void> removeAllChannels() async {
    // 先快照再清理，避免遍历过程中并发修改（P-M4）
    final snapshot = _channels.values.toList();
    final errors = <Object>[];
    for (final channel in snapshot) {
      // 每个 channel 单独捕获异常，避免一个失败导致其余未清理
      try {
        await channel.unsubscribe();
      } catch (e) {
        errors.add(e);
      }
    }
    _channels.clear();
    // 统一上报：单个异常原样抛出，多个异常聚合后抛出
    if (errors.length == 1) throw errors.first;
    if (errors.length > 1) {
      throw CloudSyncException(
        'Multiple channel unsubscribe failures: $errors',
      );
    }
  }

  @override
  List<RealtimeChannel> get channels => _channels.values.toList();

  @override
  bool hasChannel(String channelName) => _channels.containsKey(channelName);

  @override
  Future<void> connect() async {
    _updateConnectionState(RealtimeConnectionState.connecting);

    try {
      // 仅当底层 realtime 已连接时才升级为 connected，
      // 否则保持 connecting，由 channel 的 subscribe 回调升级为 connected（C4）
      if (_client.realtime.isConnected) {
        _updateConnectionState(RealtimeConnectionState.connected);
      }
    } catch (e) {
      _updateConnectionState(RealtimeConnectionState.error);
      throw CloudSyncException('Failed to connect to realtime server: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      // Remove all channels
      await removeAllChannels();

      // Disconnect realtime
      // Note: Supabase doesn't provide explicit disconnect
      // Channels are automatically cleaned up

      _updateConnectionState(RealtimeConnectionState.disconnected);
    } catch (e) {
      _updateConnectionState(RealtimeConnectionState.error);
      throw CloudSyncException('Failed to disconnect from realtime server: $e');
    }
  }

  /// Update connection state and notify listeners
  void _updateConnectionState(RealtimeConnectionState newState) {
    if (_currentState != newState) {
      _currentState = newState;
      _connectionStateController.add(_currentState);
    }
  }

  /// Dispose resources
  ///
  /// 先取消所有 channel 订阅再关闭 StreamController，
  /// 避免遗留订阅导致资源泄漏（P-M10）。
  /// 接口 [CloudRealtimeService] 未声明 dispose，故此处非 @override。
  Future<void> dispose() async {
    await removeAllChannels();
    await _connectionStateController.close();
  }
}
