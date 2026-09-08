import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_icloud/flutter_cloud_sync_icloud.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_method_channel.dart';

/// P0-2 回归（对齐 WebDAV WD-M3 审计口径）：iCloud「不存在」判定
/// 不得使用纯数字子串匹配 —— 异常消息内嵌 host:port（如 `:8404`）
/// 时，任何网络/权限错误被误判为「不存在」→ exists()=false →
/// 调用方触发覆盖上传，静默盖掉云端数据。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P0-2: iCloud _isNotFoundError 不受数字子串干扰', () {
    test('异常消息内嵌 :8404 端口 → 不误判为不存在（download 抛错）',
        () async {
      final channel = FakeICloudMethodChannel(
        downloadError: PlatformException(
          code: 'network_error',
          message: 'Failed to connect to 10.0.40.35:8404: connection refused',
        ),
      );
      final service = ICloudStorageService(channel);

      // 网络错误必须抛出（不得收敛为 null 的「不存在」语义）
      expect(
        () => service.download(path: 'ledger_abc.json'),
        throwsA(isA<CloudStorageException>()),
      );
    });

    test('异常消息内嵌 :8404 端口 → exists() 抛错而非 false', () async {
      final channel = FakeICloudMethodChannel(
        existsError: PlatformException(
          code: 'network_error',
          message: 'Failed to connect to 10.0.40.35:8404: connection refused',
        ),
      );
      final service = ICloudStorageService(channel);

      // 误判 false 会让上层走覆盖上传——必须抛异常
      expect(
        () => service.exists(path: 'ledger_abc.json'),
        throwsA(isA<CloudStorageException>()),
      );
    });

    test('对象名含 404 字样的网络错误 → 不误判', () async {
      final channel = FakeICloudMethodChannel(
        existsError: PlatformException(
          code: 'timeout',
          message: 'Request for backup404.json timed out after 30s',
        ),
      );
      final service = ICloudStorageService(channel);
      expect(
        () => service.exists(path: 'backup404.json'),
        throwsA(isA<CloudStorageException>()),
      );
    });

    test('结构化 notfound 错误码 → 正常按不存在处理（幂等语义保留）',
        () async {
      final channel = FakeICloudMethodChannel(
        existsError: PlatformException(
          code: 'notFound',
          message: 'file does not exist',
        ),
      );
      final service = ICloudStorageService(channel);
      expect(await service.exists(path: 'ledger_abc.json'), isFalse);
    });

    test('精确 404 错误码 → 按不存在处理', () async {
      final channel = FakeICloudMethodChannel(
        downloadError: PlatformException(code: '404', message: ''),
      );
      final service = ICloudStorageService(channel);
      expect(await service.download(path: 'ledger_abc.json'), isNull);
    });

    test('措辞 not found 兜底仍然有效（无结构化码的裸异常）', () async {
      final channel = FakeICloudMethodChannel(
        existsError: Exception('NSFileNoSuchFileError: file not found'),
      );
      final service = ICloudStorageService(channel);
      expect(await service.exists(path: 'ledger_abc.json'), isFalse);
    });
  });
}
