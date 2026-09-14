// 审计 ICL-2（2026-09-12 P1）回归：iCloud exists() 环境故障透传。
//
// 根因：原生 ICloudManager.fileExists 用 `try? safeURL(...)` 把容器
// 未初始化（NSError 1001）与路径校验失败（1002）静默压成 false，
// Dart 侧原样返回 → 调用方（exists 探测锚点/上传冲突仲裁）把环境
// 故障误判为「文件不存在」，诱发覆盖上传（静默盖掉云端他机数据）。
//
// 修复链路：Swift fileExists 改 throws → 插件转 FlutterError
// （code ICLOUD_1001/1002）→ Dart PlatformException 上抛 →
// ICloudStorageService.exists 的 _isNotFoundError 不命中（非 404 族）
// → CloudStorageException 上抛，与「文件真实不存在」区分。
//
// 本测试在 Dart 侧锁死错误分类语义（Swift 侧为原生代码，桥接层
// 形态由 plugin 侧 ICLOUD_<code> 约定承载，Flutter 单测不可达）。
library;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_icloud/flutter_cloud_sync_icloud.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ICL-2: exists() 环境故障不压成 false', () {
    test('容器未初始化（ICLOUD_1001）→ CloudStorageException 而非 false',
        () async {
      final channel = FakeICloudMethodChannel(
        existsError: PlatformException(
          code: 'ICLOUD_1001',
          message: 'Container not initialized',
        ),
      );
      final service = ICloudStorageService(channel);

      // 期望抛出：环境故障必须与「文件不存在」区分，否则调用方
      // （上传冲突仲裁的探测锚点）会误判后触发覆盖上传
      expect(
        () => service.exists(path: 'ledger_abc.json'),
        throwsA(isA<CloudStorageException>()),
      );
    });

    test('路径校验失败（ICLOUD_1002，遍历/逃逸）→ CloudStorageException',
        () async {
      final channel = FakeICloudMethodChannel(
        existsError: PlatformException(
          code: 'ICLOUD_1002',
          message: 'Path traversal detected: ../../etc/passwd',
        ),
      );
      final service = ICloudStorageService(channel);

      expect(
        () => service.exists(path: '../escape'),
        throwsA(isA<CloudStorageException>()),
      );
    });

    test('未知 iCloud 原生错误（ICLOUD_UNKNOWN）→ 同样上抛', () async {
      final channel = FakeICloudMethodChannel(
        existsError: PlatformException(
          code: 'ICLOUD_UNKNOWN',
          message: 'undocumented native failure',
        ),
      );
      final service = ICloudStorageService(channel);

      expect(
        () => service.exists(path: 'any'),
        throwsA(isA<CloudStorageException>()),
      );
    });

    test('文件真实不存在（NotFound 族）→ 仍返回 false（语义不受影响）',
        () async {
      final channel = FakeICloudMethodChannel(
        existsError: PlatformException(
          code: 'NSFileNoSuchFileError',
          message: 'no such file',
        ),
      );
      final service = ICloudStorageService(channel);

      expect(await service.exists(path: 'ledger_gone.json'), isFalse,
          reason: '真实不存在必须维持 false 语义（幂等读/删除等 '
              '调用方依赖）');
    });
  });
}
