/// M13 归档流式（磁盘到磁盘）回归：
/// - 导出产物必须是**合法 tar.gz**：`TarDecoder` 与**系统 `tar tzf`** 都能读
///   （只自证兼容等于没测——外部工具读不出就是把格式改坏了）；
/// - 条目顺序与旧实现逐字一致（无头像/图标时：metadata.json → images/*）；
/// - 导出 → 导入逐附件 sha256 还原。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/services/attachment_export_import_service.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.documents);

  final String documents;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getTemporaryPath() async => documents;
}

/// 取一个带容器 `Ref` 的服务实例（服务构造需要 Ref）。
final _exportServiceProvider = Provider<AttachmentExportImportService>(
    (ref) => AttachmentExportImportService(ref));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;
  late Directory root;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    root = await Directory.systemTemp.createTemp('pc_m13_archive');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    container = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(repo),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await root.delete(recursive: true);
  });

  test('导出磁盘到磁盘：TarDecoder 可读 + 系统 tar 可读 + 导入逐字节还原', () async {
    final attDir = Directory('${root.path}/attachments');
    await attDir.create(recursive: true);
    // 用非平凡二进制内容（200KB）证明确实按字节搬运
    final payload = List<int>.generate(200000, (i) => (i * 31) % 256);
    await File('${attDir.path}/photo.jpg').writeAsBytes(payload);
    final sha = crypto.sha256.convert(payload).toString();

    await db.into(db.transactionAttachments).insert(
        TransactionAttachmentsCompanion.insert(
            transactionId: 1,
            fileName: 'photo.jpg',
            fileSize: drift.Value(payload.length),
            localSha256: drift.Value(sha)));

    final svc = container.read(_exportServiceProvider);
    final exportPath = await svc.exportAttachments();

    expect(exportPath, isNotNull, reason: '有附件时应导出');
    expect(await File(exportPath!).exists(), isTrue);

    // 1) TarDecoder：条目名 / 顺序 / 内容
    final bytes = await File(exportPath).readAsBytes();
    final tarData = GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(tarData);
    final names = archive.map((f) => f.name).toList();
    expect(names, ['metadata.json', 'images/photo.jpg'],
        reason: '无头像/自定义图标时条目顺序须与旧实现一致');
    final img =
        archive.files.firstWhere((f) => f.name == 'images/photo.jpg');
    expect(img.content as List<int>, payload);
    final meta =
        jsonDecode(utf8.decode(archive.files
            .firstWhere((f) => f.name == 'metadata.json')
            .content as List<int>)) as Map<String, dynamic>;
    expect(meta['count'], 1);

    // 2) 系统 tar：外部工具必须能读（跨端兼容的硬证据）
    final tarOk = await _systemTarList(exportPath);
    if (tarOk == null) {
      markTestSkipped('系统无 tar 命令，跳过外部兼容校验');
    } else {
      expect(tarOk, contains('metadata.json'));
      expect(tarOk, contains('images/photo.jpg'));
    }

    // 3) 往返：删掉本地原图后导入应逐字节还原
    await File('${attDir.path}/photo.jpg').delete();
    final res = await svc.importAttachments(
        archivePath: exportPath, conflictStrategy: 'overwrite');
    expect(res.success, isTrue);
    expect(res.imported, 1);

    final restored = await File('${attDir.path}/photo.jpg').readAsBytes();
    expect(crypto.sha256.convert(restored).toString(), sha,
        reason: '导入还原必须与原内容逐字节一致');
  });
}

/// 用系统 `tar -tzf` 列目录；命令不可用时返回 null（交由调用方 skip）。
Future<String?> _systemTarList(String archivePath) async {
  try {
    final res = await Process.run('tar', ['-tzf', archivePath]);
    if (res.exitCode != 0) {
      fail('系统 tar 读取失败（exit=${res.exitCode}）：${res.stderr}');
    }
    return res.stdout as String;
  } on ProcessException {
    return null;
  }
}
