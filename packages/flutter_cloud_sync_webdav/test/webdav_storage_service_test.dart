import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

import 'package:flutter_cloud_sync_webdav/src/webdav_storage_service.dart';

/// 方案C / 审计批次2：WebDAVStorageService 回归
///
/// 用自定义 dio HttpClientAdapter 模拟一台小型 WebDAV 服务器：
/// PUT/GET/DELETE/MOVE/PROPFIND/MKCOL/OPTIONS 全部本地内存实现。
class _FakeServer implements HttpClientAdapter {
  /// fullPath -> 内容
  final Map<String, List<int>> files = {};

  /// fullPath -> etag（裸值，响应时加引号）
  final Map<String, String> etags = {};

  /// MOVE 响应状态码（200 = W-A「成功但返回非 2xx 规范码」场景）
  int moveStatus = 201;

  /// MOVE 是否真的执行移动（false = 模拟不支持覆盖 MOVE 的服务器）
  bool performMove = true;

  int putCalls = 0;
  final List<(String, String)> moveCalls = [];

  @override
  void close({bool force = false}) {}

  Future<Uint8List> _collect(Stream<Uint8List>? stream) async {
    final builder = BytesBuilder();
    await for (final chunk in stream ?? const Stream<Uint8List>.empty()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  String _quoteETag(String? raw) => raw == null ? '' : '"$raw"';

  String _responseXml({
    required String href,
    required bool isDir,
    String? eTag,
    int? size,
  }) {
    return '<d:response>'
        '<d:href>$href</d:href>'
        '<d:propstat><d:prop>'
        '<d:resourcetype>${isDir ? '<d:collection/>' : ''}</d:resourcetype>'
        '${!isDir && size != null ? '<d:getcontentlength>$size</d:getcontentlength>' : ''}'
        '${!isDir && eTag != null ? '<d:getetag>${_quoteETag(eTag)}</d:getetag>' : ''}'
        '<d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified>'
        '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
        '</d:response>';
  }

  List<String> _children(String dirPath) {
    final prefix =
        dirPath.endsWith('/') ? dirPath : '$dirPath/';
    return files.keys.where((k) => k.startsWith(prefix)).toList();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final method = options.method.toUpperCase();
    final path = options.uri.path;

    switch (method) {
      case 'OPTIONS':
        return ResponseBody.fromString('', 200);

      case 'PUT':
        putCalls++;
        final bytes = await _collect(requestStream);
        files[path] = bytes;
        etags[path] = 'put-$putCalls';
        return ResponseBody.fromString('', 201);

      case 'GET':
        final content = files[path];
        if (content == null) {
          return ResponseBody.fromString('not found', 404);
        }
        return ResponseBody.fromBytes(content, 200);

      case 'DELETE':
        if (files.remove(path) != null || etags.remove(path) != null) {
          return ResponseBody.fromString('', 204);
        }
        return ResponseBody.fromString('', 404);

      case 'MOVE':
        final dest =
            Uri.parse(options.headers['destination'] as String).path;
        moveCalls.add((path, dest));
        if (performMove && files.containsKey(path)) {
          files[dest] = files.remove(path)!;
          final e = etags.remove(path);
          if (e != null) etags[dest] = '$e-moved';
        }
        return ResponseBody.fromString('', moveStatus);

      case 'MKCOL':
        return ResponseBody.fromString('', 201);

      case 'PROPFIND':
        final depthOne = options.headers['depth'] == '1';
        final buf = StringBuffer(
            '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">');
        if (depthOne) {
          // 自身（目录）+ 直接子项（Depth 1 语义）
          buf.write(_responseXml(
              href: path.endsWith('/') ? path : '$path/', isDir: true));
          for (final child in _children(path)) {
            buf.write(_responseXml(
              href: child,
              isDir: false,
              eTag: etags[child],
              size: files[child]?.length,
            ));
          }
        } else {
          final content = files[path];
          if (content == null && !etags.containsKey(path)) {
            return ResponseBody.fromString('not found', 404);
          }
          buf.write(_responseXml(
            href: path,
            isDir: false,
            eTag: etags[path],
            size: content?.length,
          ));
        }
        buf.write('</d:multistatus>');
        return ResponseBody.fromString(buf.toString(), 207);

      default:
        return ResponseBody.fromString('unsupported', 405);
    }
  }
}

void main() {
  late _FakeServer server;
  late WebDAVStorageService service;

  setUp(() {
    server = _FakeServer();
    final client = webdav.newClient(
      'https://webdav.example.com',
      user: 'u',
      password: 'p',
      debug: false,
    );
    // WdDio 实现 Dio：直接替换底层适配器为内存假服务器
    client.c.httpClientAdapter = server;
    service = WebDAVStorageService(client, '/');
  });

  group('信封格式（方案C / 审计 W-I）', () {
    test('upload 带元数据 → 云端为单信封文件，download 还原原文', () async {
      const data = '{"ledger":"demo","count":3}';
      await service.upload(
        path: 'ledger_x.json',
        data: data,
        metadata: {'fingerprint': 'fp-1', 'uploadedAt': '2026-01-01T00:00:00Z'},
      );

      // 云端产物是信封 JSON（fmt 标记 + meta 内嵌）
      final stored = utf8.decode(server.files['/ledger_x.json']!);
      expect(stored.startsWith('{'), isTrue);
      expect(stored, contains('pc-wdav-env-v1'));
      expect(stored, contains('fp-1'));

      // download 还原为调用方写入的原始内容
      expect(await service.download(path: 'ledger_x.json'), data);

      // getMetadata 读到内嵌 meta + eTag
      final meta = await service.getMetadata(path: 'ledger_x.json');
      expect(meta, isNotNull);
      expect(meta!.metadata!['fingerprint'], 'fp-1');
      expect(meta.eTag, isNotNull);
    });

    test('旧版裸文件 + sidecar → download 原样返回，getMetadata 回退读 sidecar',
        () async {
      const raw = '{"legacy":true}';
      server.files['/legacy.json'] = utf8.encode(raw);
      server.etags['/legacy.json'] = 'legacy-1';
      server.files['/legacy.json.metadata.json'] = utf8.encode(jsonEncode({
        'metadata': {'fingerprint': 'old-fp'},
        'updatedAt': '2025-01-01T00:00:00Z',
      }));

      expect(await service.download(path: 'legacy.json'), raw);

      final meta = await service.getMetadata(path: 'legacy.json');
      expect(meta!.metadata!['fingerprint'], 'old-fp');
      expect(meta.eTag, 'legacy-1');
    });

    test('无元数据的二进制保持裸字节（零开销路径）', () async {
      final bytes = [1, 2, 3, 255];
      await service.uploadBinary(path: 'attachments/a.bin', bytes: bytes);

      expect(server.files['/attachments/a.bin'], bytes);
      expect(await service.downloadBinary(path: 'attachments/a.bin'), bytes);
    });

    test('带元数据的二进制走 base64 信封，往返一致', () async {
      final bytes = [9, 8, 7];
      await service.uploadBinary(
        path: 'attachments/b.bin',
        bytes: bytes,
        metadata: {'sha256': 'xyz'},
      );

      final stored = utf8.decode(server.files['/attachments/b.bin']!);
      expect(stored, contains('pc-wdav-env-v1'));
      expect(await service.downloadBinary(path: 'attachments/b.bin'), bytes);
    });
  });

  group('条件写（eTag 预检）', () {
    test('eTag 匹配 → 正常写入', () async {
      server.files['/k.json'] = utf8.encode('old');
      server.etags['/k.json'] = 'v1';

      await service.uploadBinaryConditional(
        path: 'k.json',
        bytes: utf8.encode('new'),
        metadata: {'fingerprint': 'fp'},
        ifMatchEtag: 'v1',
      );

      expect(utf8.decode(server.files['/k.json']!), contains('pc-wdav-env-v1'));
    });

    test('eTag 不匹配 → CloudPreconditionFailedException 且未写入', () async {
      server.files['/k.json'] = utf8.encode('old');
      server.etags['/k.json'] = 'v2';
      final putsBefore = server.putCalls;

      await expectLater(
        service.uploadBinaryConditional(
          path: 'k.json',
          bytes: utf8.encode('new'),
          ifMatchEtag: 'stale',
        ),
        throwsA(isA<CloudPreconditionFailedException>()),
      );
      expect(server.putCalls, putsBefore);
    });

    test('ifMatch 但远端不存在 → 条件失败', () async {
      await expectLater(
        service.uploadBinaryConditional(
          path: 'absent.json',
          bytes: utf8.encode('x'),
          ifMatchEtag: 'whatever',
        ),
        throwsA(isA<CloudPreconditionFailedException>()),
      );
    });

    test('ifNoneMatch 且远端已存在 → 条件失败', () async {
      server.files['/exists.json'] = utf8.encode('x');
      await expectLater(
        service.uploadBinaryConditional(
          path: 'exists.json',
          bytes: utf8.encode('y'),
          ifNoneMatch: true,
        ),
        throwsA(isA<CloudPreconditionFailedException>()),
      );
    });

    test('ifNoneMatch 且远端不存在 → 创建成功', () async {
      await service.uploadBinaryConditional(
        path: 'fresh.json',
        bytes: utf8.encode('y'),
        ifNoneMatch: true,
      );
      expect(server.files.containsKey('/fresh.json'), isTrue);
    });
  });

  group('审计 W-D/W-Y：路径防护', () {
    test('含 .. 段的路径被拒绝（不逃逸 remotePath 沙箱）', () async {
      await expectLater(
        service.upload(path: '../evil.json', data: 'x'),
        throwsA(isA<CloudConfigurationException>()),
      );
      await expectLater(
        service.downloadBinary(path: 'a/../evil.json'),
        throwsA(isA<CloudConfigurationException>()),
      );
      // 服务端从未收到过任何逃逸请求
      expect(server.files.keys.any((k) => k.contains('..')), isFalse);
    });

    test('空 path 写操作显式拒绝', () async {
      await expectLater(
        service.upload(path: '', data: 'x'),
        throwsA(isA<CloudConfigurationException>()),
      );
      await expectLater(
        service.delete(path: '  '),
        throwsA(isA<CloudConfigurationException>()),
      );
    });
  });

  group('审计 W-A：MOVE 返回 200 的假失败恢复', () {
    test('数据已落盘时按成功处理（不再误报 Upload failed）', () async {
      server.moveStatus = 200; // 真实移动了，但状态码不规范
      server.performMove = true;

      await service.uploadBinary(
        path: 'ledger_m.json',
        bytes: utf8.encode('content'),
      );

      expect(server.moveCalls, isNotEmpty);
      expect(utf8.decode(server.files['/ledger_m.json']!), 'content');
    });

    test('MOVE 失败且非降级错误 → 抛存储异常、旧文件完好', () async {
      server.performMove = false; // 不执行移动
      server.moveStatus = 500; // 非覆盖类错误 → 不允许降级
      server.files['/keep.json'] = utf8.encode('original');

      await expectLater(
        service.uploadBinary(
          path: 'keep.json',
          bytes: utf8.encode('replacement'),
        ),
        throwsA(isA<CloudStorageException>()),
      );
      expect(utf8.decode(server.files['/keep.json']!), 'original');
    });
  });

  group('审计 W-G/W-X：过滤口径与认证文案', () {
    test('list 过滤内部产物；普通文件正常列出并携带 eTag', () async {
      server.files['/ledger_a.json'] = utf8.encode('{}');
      server.etags['/ledger_a.json'] = 'ea';
      server.files['/ledger_a.json.tmp.123_0'] = utf8.encode('half');
      server.files['/ledger_a.json.old.456'] = utf8.encode('backup');
      server.files['/x.metadata.json'] = utf8.encode('{}');

      final listed = await service.list(path: '/');
      final names = listed.map((f) => f.name).toList();

      expect(names, contains('ledger_a.json'));
      expect(names, isNot(contains('ledger_a.json.tmp.123_0')));
      expect(names, isNot(contains('ledger_a.json.old.456')));
      expect(names, isNot(contains('x.metadata.json')));

      final a = listed.firstWhere((f) => f.name == 'ledger_a.json');
      expect(a.eTag, 'ea');
    });

    test('PUT 403 → 权限不足文案（而非「账号或密码错误」）', () async {
      // 用一个始终对 PUT 返回 403 的包装适配器模拟权限拒绝
      final deny = _DenyAdapter(server, status: 403);
      final client = webdav.newClient(
        'https://webdav.example.com',
        user: 'u',
        password: 'p',
      );
      client.c.httpClientAdapter = deny;
      final svc = WebDAVStorageService(client, '/');

      await expectLater(
        svc.upload(path: 'denied.json', data: 'x'),
        throwsA(isA<CloudAuthException>()
            .having((e) => e.message, 'message', contains('权限不足'))),
      );
    });

    test('PUT 401 → 账号或密码错误文案', () async {
      final deny = _DenyAdapter(server, status: 401);
      final client = webdav.newClient(
        'https://webdav.example.com',
        user: 'u',
        password: 'p',
      );
      client.c.httpClientAdapter = deny;
      final svc = WebDAVStorageService(client, '/');

      // 上游 auth 协商：首请求无凭据收到 401 且 WWW-Authenticate 缺失时
      // 直接抛错；这里凭据已随请求发送，仍 401 → 结构化状态码命中文案分支
      await expectLater(
        svc.upload(path: 'denied.json', data: 'x'),
        throwsA(isA<CloudAuthException>()
            .having((e) => e.message, 'message', anyOf(
                contains('账号或密码错误'), contains('认证失败')))),
      );
    });
  });
}

/// 对指定方法一律返回给定状态码的适配器（其余透传给 inner）
class _DenyAdapter implements HttpClientAdapter {
  _DenyAdapter(this._inner, {required this.status});

  final _FakeServer _inner;
  final int status;

  @override
  void close({bool force = false}) => _inner.close(force: force);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method.toUpperCase() == 'PUT') {
      // 消费掉请求流，避免悬挂
      await for (final _ in requestStream ?? const Stream<Uint8List>.empty()) {}
      return ResponseBody.fromString('', status);
    }
    return _inner.fetch(options, requestStream, cancelFuture);
  }
}
