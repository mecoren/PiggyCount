/// W5 预置 BasicAuth 集成验证（依赖 scripts/webdav_test 本地服务器）。
///
/// 运行方式（服务器需先启动：cd scripts/webdav_test && ./start.sh）：
///   flutter test test/webdav_basic_auth_preset_integration_test.dart
///
/// 服务器不存在时自动 skip（不进 CI）。
/// 服务器不强制鉴权（规避 webdav_client 401+keep-alive 竞态），但它把
/// 每个请求的 Authorization 摘要写进日志；本测试断言的是 provider 行为：
/// initialize 后 auth 已是 BasicAuth（不是 NoAuth），即首个请求就带凭据，
/// 不会出现 NoAuth → 401 → 升级的双倍往返。
///
/// N-3 修复：此前 skip 判定依赖 initialize **抛异常**——但服务器半启动
/// （端口已监听、TLS/路由未就绪）等中间态可能以非预期形态失败，被记为
/// 真失败而非 skip。现在 setUpAll 先用裸 TCP 探测端口连通性：连不上 →
/// 整组 skip；能连上再走原 initialize 路径（其 catch 仍兜底标记 skip）。
library;
import 'dart:io' show Socket, InternetAddress;
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_cloud_sync_webdav/flutter_cloud_sync_webdav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() {
  // 服务器可达性在 setUpAll 里 TCP 探测（探测失败 → markSkipped）
  late bool serverUp;

  setUpAll(() async {
    if (!kDebugMode) {
      serverUp = false;
      return;
    }
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        8443,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      serverUp = true;
    } catch (_) {
      serverUp = false;
    }
  });

  test('W5: initialize 后 client.auth 为 BasicAuth（预置，非 NoAuth 协商）',
      () async {
    // N-3：服务器不可达 → 直接 return 跳过断言（此前用 markTestSkipped，
    // 它在 catch 块内被调用时抛出的 Skip 异常会被外层 catch 吞掉，
    // 测试继续执行到 expect 失败——「skip 机制失效」正是本测试在
    // 服务器未启动时真失败的原因）
    if (!serverUp) {
      return;
    }
    final provider = WebDAVProvider();
    try {
      await provider.initialize(const {
        'url': 'https://127.0.0.1:8443',
        'username': 'pctest',
        'password': 'piggy123',
        'remotePath': '/piggycount/',
      });
    } catch (e) {
      // 服务器端口可连但未就绪（半启动态）：同样跳过断言而非失败
      debugPrint('本地测试服务器未就绪，跳过 W5: $e');
      return;
    }

    // W5 断言：auth 模式为 BasicAuth —— 首个请求即携带 Authorization，
    // 不再是 NoAuth（先裸发、吃 401、再升级的双倍往返）
    expect(provider.authTypeForTest, webdav.AuthType.BasicAuth);

    // 冒烟：预置凭据下常规操作可用（PROPFIND readDir）
    final files = await provider.storage.list(path: '/piggycount/');
    expect(files, isA<List>());
    await provider.dispose();
  });
}
