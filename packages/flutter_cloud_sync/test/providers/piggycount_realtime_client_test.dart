/// 审计 M18：PiggyCountCloudRealtimeClient 订阅幂等。
///
/// start/stop 任意交错不得产生「僵尸连接」：stop() 发生在
/// `requireAccessToken()` await 期间时，恢复执行后必须放弃建连，
/// 而不是在 `_running=false` 下照常建连 + 启动心跳 + 广播 connected。
library;

import 'dart:async';

import 'package:flutter_cloud_sync/src/providers/piggycount_cloud_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 假认证服务：requireAccessToken 返回测试可控的 Completer，
/// 复现 token 获取期间的 async gap。
class _FakeRealtimeAuth extends PiggyCountCloudAuthService {
  _FakeRealtimeAuth()
      : super(baseUrl: 'https://realtime.unit.test', apiPrefix: '/api/v1');

  /// 每次 requireAccessToken 发放一个新的 token 闸门，由测试逐个放行。
  final issuedTokenGates = <Completer<String>>[];
  int requireCalls = 0;

  @override
  Future<String> requireAccessToken() async {
    requireCalls++;
    final gate = Completer<String>();
    issuedTokenGates.add(gate);
    return gate.future;
  }

  @override
  Future<bool> tryRefreshSession() async => false;
}

/// 假 WS 通道：记录 sink 发送/关闭状态，不触网。
class _FakeWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  // 保持打开的广播流：模拟「连接存续」。若用已关闭的空流，
  // listen 会立刻触发 onDone → _scheduleReconnect，偏离被测场景。
  final _incoming = StreamController<dynamic>.broadcast();
  final sent = <dynamic>[];
  bool sinkClosed = false;

  @override
  Future<void> get ready => Future.value();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeWebSocketSink(this);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;
}

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._channel);

  final _FakeWebSocketChannel _channel;

  @override
  void add(dynamic data) {
    _channel.sent.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final _ in stream) {
      // 丢弃
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _channel.sinkClosed = true;
  }

  @override
  Future<void> get done => Future.value();
}

void main() {
  /// 冲刷事件循环：broadcast stream 投递与 connect 后续微任务均需数轮
  Future<void> flush() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('M18: stop() 发生在 token 获取期间 → 放弃建连，无僵尸连接', () async {
    final auth = _FakeRealtimeAuth();
    final channels = <_FakeWebSocketChannel>[];
    final client = PiggyCountCloudRealtimeClient(
      baseUrl: 'https://realtime.unit.test',
      auth: auth,
      channelFactory: (uri, headers) {
        final channel = _FakeWebSocketChannel();
        channels.add(channel);
        return channel;
      },
    );

    final events = <String>[];
    final sub = client.events.listen((e) => events.add(e.type));

    // start 停在 requireAccessToken 的闸门上
    final startFuture = client.start();
    await flush();
    expect(auth.requireCalls, 1);

    // token 完成前 stop —— 修复前这里之后会照常建出僵尸连接
    await client.stop();
    auth.issuedTokenGates.first.complete('token');
    await startFuture;
    await flush();

    expect(channels, isEmpty, reason: 'M18: stop 后不得再建立 WS 连接');
    expect(events, isEmpty,
        reason: 'M18: 僵尸连接不应向业务层广播 connected 事件');

    await sub.cancel();
    client.dispose();
  });

  test('M18: 并发 start() 幂等 —— 仅一次 token 获取、一条连接、一个 connected',
      () async {
    final auth = _FakeRealtimeAuth();
    final channels = <_FakeWebSocketChannel>[];
    final client = PiggyCountCloudRealtimeClient(
      baseUrl: 'https://realtime.unit.test',
      auth: auth,
      channelFactory: (uri, headers) {
        final channel = _FakeWebSocketChannel();
        channels.add(channel);
        return channel;
      },
    );

    var connectedCount = 0;
    final sub = client.events.listen((e) {
      if (e.type == 'connected') connectedCount++;
    });

    final f1 = client.start();
    final f2 = client.start(); // 第二次应被 _running 守卫直接跳过
    await flush();
    expect(auth.requireCalls, 1, reason: 'M18: 并发 start 只允许一次 token 获取');

    auth.issuedTokenGates.first.complete('token');
    await f1;
    await f2;
    await flush();

    expect(channels.length, 1, reason: 'M18: 并发 start 只允许建一条连接');
    expect(connectedCount, 1);

    await client.stop();
    expect(channels.single.sinkClosed, isTrue);

    await sub.cancel();
    client.dispose();
  });

  test('M18: stop→start 循环 —— 每轮新连接，旧连接被关闭', () async {
    final auth = _FakeRealtimeAuth();
    final channels = <_FakeWebSocketChannel>[];
    final client = PiggyCountCloudRealtimeClient(
      baseUrl: 'https://realtime.unit.test',
      auth: auth,
      channelFactory: (uri, headers) {
        final channel = _FakeWebSocketChannel();
        channels.add(channel);
        return channel;
      },
    );

    var connectedCount = 0;
    final sub = client.events.listen((e) {
      if (e.type == 'connected') connectedCount++;
    });

    // 第一轮
    final f1 = client.start();
    await flush();
    auth.issuedTokenGates[0].complete('token-1');
    await f1;
    await flush();
    expect(channels.length, 1);
    expect(connectedCount, 1);

    await client.stop();
    expect(channels[0].sinkClosed, isTrue);

    // 第二轮：重新订阅可用（此前 stop 清空了状态）
    final f2 = client.start();
    await flush();
    auth.issuedTokenGates[1].complete('token-2');
    await f2;
    await flush();
    expect(channels.length, 2, reason: 'M18: 重启应建立新连接');
    expect(connectedCount, 2);

    await client.stop();
    expect(channels[1].sinkClosed, isTrue);

    await sub.cancel();
    client.dispose();
  });
}
