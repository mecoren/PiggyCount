// 审计 ICL-1（2026-09-12 P1）回归：iCloud eTag 最小接线。
//
// 根因：iCloud 原生无 ETag 概念，CloudFile.eTag 恒 null →
// transactions_sync_manager 的冲突探测（_detectUploadConflict →
// UploadProbe.cloudETag）拿不到锚点，If-Match 语义失效，两机并发
// 上传退化为「盲上传 + 写后校验」的静默 last-writer-wins。
//
// 最小接线（审计方案 6）：getMetadata/list 把原生 lastModified 归一化
// 为 ISO 字符串填入 eTag。验收标准：冲突探测 cloudETag 非 null；
// 同一 lastModified 往返稳定（同文件两次读必须同 eTag）。
// 诚实边界：秒级精度，同秒并发窗口仍不可分辨——但这从「任何并发都
// 不可分辨」收窄为「同秒才不可分辨」。
library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_icloud/flutter_cloud_sync_icloud.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ICL-1: getMetadata/list 的 eTag 从 lastModified 接线', () {
    test('getMetadata：lastModified → eTag 非 null 且为 UTC ISO 形态',
        () async {
      final channel = FakeICloudMethodChannel(
        getMetadataResult: {
          'name': 'ledger_1.json',
          'path': 'ledger_1.json',
          'size': 123,
          'lastModified': '2026-09-14T10:30:00Z',
        },
      );
      final service = ICloudStorageService(channel);

      final meta = await service.getMetadata(path: 'ledger_1.json');

      expect(meta, isNotNull);
      expect(meta!.eTag, isNotNull,
          reason: 'ICL-1 根因：eTag 恒 null 使冲突探测的 If-Match 锚点'
              '失效，两机并发静默 last-writer-wins');
      expect(meta.eTag, '2026-09-14T10:30:00.000Z');
    });

    test('list：每个条目的 eTag 同样接线', () async {
      final channel = FakeICloudMethodChannel(
        listFilesResult: [
          {
            'name': 'ledger_1.json',
            'path': 'ledger_1.json',
            'size': 10,
            'lastModified': '2026-09-14T08:00:00Z',
          },
          {
            'name': 'ledger_2.json',
            'path': 'ledger_2.json',
            'size': 20,
            // 无 lastModified 的条目：eTag 维持 null（弱锚点语义允许缺席）
            'lastModified': null,
          },
        ],
      );
      final service = ICloudStorageService(channel);

      final files = await service.list(path: '');

      expect(files.length, 2);
      expect(files[0].eTag, '2026-09-14T08:00:00.000Z');
      expect(files[1].eTag, isNull,
          reason: '无 lastModified 的对象无锚点可透出，'
              '调用方容忍 null（CloudFile.eTag 契约）');
    });

    test('往返稳定：同一 lastModified 两次读取 → eTag 相同', () async {
      final channel = FakeICloudMethodChannel(
        getMetadataResult: {
          'name': 'x.json',
          'path': 'x.json',
          'lastModified': '2026-09-14T12:00:00Z',
        },
      );
      final service = ICloudStorageService(channel);

      final first = await service.getMetadata(path: 'x.json');
      final second = await service.getMetadata(path: 'x.json');

      expect(first!.eTag, second!.eTag,
          reason: 'eTag 作 If-Match 锚点的前提是往返稳定——'
              '同文件同 lastModified 必须产生同 eTag');
    });

    test('uploadBinaryConditional：锚点一致 → 放行写入（create-only=false）',
        () async {
      var uploadedPath = '';
      final channel = FakeICloudMethodChannel(
        getMetadataResult: {
          'name': 'ledger_1.json',
          'path': 'ledger_1.json',
          'lastModified': '2026-09-14T10:30:00Z',
        },
      );
      // 拦截上传调用记录
      channel.setUploadRecorder((p) => uploadedPath = p);
      final service = ICloudStorageService(channel);

      await service.uploadBinaryConditional(
        path: 'ledger_1.json',
        bytes: [1, 2],
        ifMatchEtag: '2026-09-14T10:30:00.000Z',
      );

      expect(uploadedPath, 'ledger_1.json', reason: '锚点一致应放行写入');
    });

    test('uploadBinaryConditional：锚点漂移（他机并发写入）→ 条件失败',
        () async {
      final channel = FakeICloudMethodChannel(
        getMetadataResult: {
          'name': 'ledger_1.json',
          'path': 'ledger_1.json',
          // 他机 1 分钟前刚写入 → lastModified 已变
          'lastModified': '2026-09-14T10:31:00Z',
        },
      );
      final service = ICloudStorageService(channel);

      expect(
        () => service.uploadBinaryConditional(
          path: 'ledger_1.json',
          bytes: [1, 2],
          // 探测时的锚点是 10:30:00
          ifMatchEtag: '2026-09-14T10:30:00.000Z',
        ),
        throwsA(isA<CloudPreconditionFailedException>()),
        reason: 'ICL-1 根因：无锚点比对时两机并发静默 last-writer-wins');
    });

    test('uploadBinaryConditional：ifNoneMatch + 对象已存在 → 条件失败',
        () async {
      final channel = FakeICloudMethodChannel(
        getMetadataResult: {
          'name': 'ledger_1.json',
          'path': 'ledger_1.json',
          'lastModified': '2026-09-14T10:30:00Z',
        },
      );
      final service = ICloudStorageService(channel);

      expect(
        () => service.uploadBinaryConditional(
          path: 'ledger_1.json',
          bytes: [1, 2],
          ifNoneMatch: true,
        ),
        throwsA(isA<CloudPreconditionFailedException>()),
      );
    });

    test('uploadBinaryConditional：远端不存在 + ifMatch → 锚点失效',
        () async {
      final channel = FakeICloudMethodChannel(getMetadataResult: null);
      final service = ICloudStorageService(channel);

      expect(
        () => service.uploadBinaryConditional(
          path: 'ledger_1.json',
          bytes: [1, 2],
          ifMatchEtag: 'any-anchor',
        ),
        throwsA(isA<CloudPreconditionFailedException>()),
        reason: '探测时存在、写入时消失 = 中途被并发删除，按冲突处理',
      );
    });

    test('无法解析的 lastModified → eTag null（不产生伪锚点）', () async {
      final channel = FakeICloudMethodChannel(
        getMetadataResult: {
          'name': 'x.json',
          'path': 'x.json',
          'lastModified': 'not-a-date',
        },
      );
      final service = ICloudStorageService(channel);

      final meta = await service.getMetadata(path: 'x.json');

      expect(meta!.eTag, isNull,
          reason: '脏数据不透出伪 eTag——错误的锚点比没有锚点更危险');
    });
  });
}
