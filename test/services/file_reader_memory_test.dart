/// M15（B9）：`_readFileWithProgress` 从「分块 `List<int>` + addAll 拼接」改成
/// 「预分配 `Uint8List` + `readInto` 直写」。
///
/// CI 里测不了 RSS，所以断的是**改写后仍然正确**的三件事：
/// 1. 多 MB / 多次系统调用（readInto 允许短读）之后字节不错位、不截断；
/// 2. 进度单调且不越界，终点 1.0；
/// 3. 传给 xlsxConverter 的是 `Uint8List` —— 若哪天又退回 `List<int>`，
///    调用点会重新 `Uint8List.fromList` 整份复制，10MB 文件多白吃 10MB。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/services/import/file_reader.dart';

/// file_picker 12+ 把 PlatformFile 改成了 abstract base class（没有公开构造、
/// 也没有 bytes/size 属性），所以测试里按接口自建最小实现，同时覆盖
/// 「有本地路径」与「只有内存字节」两条支路。
final class _FakePlatformFile extends PlatformFile {
  _FakePlatformFile({required this.name, this.filePath, this.bytes});

  @override
  final String name;
  final String? filePath;
  final Uint8List? bytes;

  @override
  Uri get uri =>
      filePath != null ? Uri.file(filePath!) : Uri.parse('memory://$name');

  @override
  XFile get xFile => XFile(filePath ?? name);

  @override
  int? lengthSync() =>
      bytes?.length ?? (filePath == null ? 0 : File(filePath!).lengthSync());

  @override
  Future<int?> length() async => lengthSync();

  @override
  Future<Uint8List> readAsBytes() async =>
      bytes ??
      (filePath == null
          ? Uint8List(0)
          : File(filePath!).readAsBytesSync());

  @override
  Stream<Uint8List> readAsByteStream() async* {
    yield await readAsBytes();
  }
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('file_reader_m15'));
  tearDown(() => tmp.deleteSync(recursive: true));

  PlatformFile picked(String name, String path) =>
      _FakePlatformFile(name: name, filePath: path);

  test('1.5MB 非 ASCII CSV 逐字符还原，进度单调到 1.0', () async {
    final lines = <String>['日期,金额,备注'];
    for (var i = 0; i < 30000; i++) {
      lines.add('2025-0${i % 9 + 1}-0${i % 8 + 1},$i.99,消费记录$i 号 éü中文');
    }
    final text = lines.join('\n');
    final file = File('${tmp.path}/big.csv')..writeAsStringSync(text);
    expect(file.lengthSync(), greaterThan(1024 * 1024));

    final progress = <double>[];
    final decoded = await FileReaderService.readFile(
      picked('big.csv', file.path),
      onProgress: progress.add,
    );

    expect(decoded, text, reason: 'readInto 短读/偏移处理有误');
    expect(progress, isNotEmpty);
    expect(progress.first, greaterThan(0));
    expect(progress.last, 1.0);
    for (var i = 1; i < progress.length; i++) {
      expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
    }
  });

  test('xlsx 分支拿到的是 Uint8List（不是退回的 List<int>）', () async {
    final bytes = Uint8List.fromList(List.generate(400000, (i) => i % 251));
    final file = File('${tmp.path}/book.xlsx')..writeAsBytesSync(bytes);

    Object? seen;
    await FileReaderService.readFile(
      picked('book.xlsx', file.path),
      xlsxConverter: (b) {
        seen = b;
        return 'ok';
      },
    );

    expect(seen, isA<Uint8List>());
    expect(seen, equals(bytes));

    // 类型系统管不住的一种回退：读文件处又攒成 List<int> 再 fromList 复制一份
    // （10MB 账单 = 80MB Smi + 10MB 副本）。这条是源码契约，和仓库里其它
    // contract test 同一手法。
    final src = File('lib/services/import/file_reader.dart').readAsStringSync();
    expect(src, contains('readInto'));
    expect(src, isNot(contains('.addAll(')));
  });

  test('UTF-16LE(BOM) / 空文件 / 无路径走 bytes 三条支路都不歪', () async {
    final text = '支付宝账单，包含中文与 emoji 🎉 的 UTF-16LE 文件';
    final u16 = File('${tmp.path}/u16.csv')
      ..writeAsBytesSync([0xFF, 0xFE] +
          [
            for (final c in text.codeUnits) ...[c & 0xFF, c >> 8]
          ]);
    expect(await FileReaderService.readFile(picked('u16.csv', u16.path)), text);

    final empty = File('${tmp.path}/empty.csv')..createSync();
    expect(
        await FileReaderService.readFile(picked('empty.csv', empty.path)), '');

    final inMem = _FakePlatformFile(
        name: 'mem.csv', bytes: Uint8List.fromList('abc'.codeUnits));
    expect(await FileReaderService.readFile(inMem), 'abc');

    final noBytes = _FakePlatformFile(name: 'none.csv');
    expect(await FileReaderService.readFile(noBytes), '');
  });
}
