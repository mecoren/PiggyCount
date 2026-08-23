import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 永不完成的假客户端：模拟半开连接。
class HungClient implements http.Client {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Completer<http.StreamedResponse>().future; // never
  }

  @override
  void close() {}

  @override
  Future<http.Response> delete(Uri url,
          {Map<String, String>? headers, Object? body, dynamic encoding}) =>
      _never();

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) =>
      _never();

  @override
  Future<http.Response> head(Uri url, {Map<String, String>? headers}) =>
      _never();

  @override
  Future<http.Response> patch(Uri url,
          {Map<String, String>? headers, Object? body, dynamic encoding}) =>
      _never();

  @override
  Future<http.Response> post(Uri url,
          {Map<String, String>? headers,
          Object? body,
          dynamic encoding}) =>
      _never();

  @override
  Future<http.Response> put(Uri url,
          {Map<String, String>? headers, Object? body, dynamic encoding}) =>
      _never();

  @override
  Future<String> read(Uri url, {Map<String, String>? headers}) => Completer<String>().future;

  @override
  Future<Uint8List> readBytes(Uri url, {Map<String, String>? headers}) => Completer<Uint8List>().future;

  Future<http.Response> _never() =>
      Completer<http.Response>().future; // hang forever
}

void main() {
  test('挂起请求被超时中断并转为 CloudStorageException（审计 S15）', () async {
    final storage = PiggyCountCloudStorageService(
      baseUrl: 'https://unit.test',
      apiPrefix: '/api/v1',
      auth: PiggyCountCloudAuthService(
          baseUrl: 'https://unit.test', apiPrefix: '/api/v1'),
      httpClient: HungClient(),
      requestTimeout: const Duration(milliseconds: 120),
    );
    final sw = Stopwatch()..start();
    await expectLater(
        storage.fetchServerVersion(), throwsA(isA<CloudStorageException>()));
    sw.stop();
    expect(sw.elapsed.inSeconds, lessThan(5),
        reason: '必须按注入的超时(120ms)快速失败，而非无限等待');
  });

  test('debugSendWithTimeout 将 TimeoutException 转译为 CloudStorageException',
      () async {
    final client = HungClient();
    final req = http.Request('GET', Uri.parse('https://unit.test/ping'));
    final sw = Stopwatch()..start();
    await expectLater(
      debugSendWithTimeout(
          const Duration(milliseconds: 80), () => client.send(req)),
      throwsA(isA<CloudStorageException>()),
    );
    sw.stop();
    expect(sw.elapsed.inMilliseconds, lessThan(5000));
  });
}


