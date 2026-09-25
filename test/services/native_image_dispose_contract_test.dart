import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// M10 / M11 源码契约守卫：凡产生 native 位图的调用点必须显式释放。
///
/// 为什么是源码契约而不是内存差分：`ui.Image` / `ui.Codec` 的位图在 native 堆，
/// `flutter test` 的 `getAllocationProfile` 只统计 Dart 堆，真机 RSS 由
/// `scripts/profile_memory.py` 负责。这里守的是「新增位图产生点忘了 dispose」。
void main() {
  const bitmapApi = '.toImage(pixelRatio';
  const codecApi = 'instantiateImageCodec';
  // 产生点之后多少行内必须看到 dispose()
  const disposeWindow = 10;

  test('lib/ 下每个 native 位图产生点都在窗口内释放', () {
    final offenders = <String>[];
    var checkedSites = 0;

    for (final file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue; // 注释里提到 API 名不算产生点
        if (!line.contains(bitmapApi) && !line.contains(codecApi)) continue;
        checkedSites++;
        final window = lines.skip(i).take(disposeWindow).join('\n');
        if (!window.contains('dispose()')) {
          offenders.add('${file.path}:${i + 1}  ${line.trim()}');
        }
      }
    }

    // 下限锚点（2026-09-25 U1 整合后）：海报截屏 5 份拷贝收敛为
    // lib/utils/widget_capture.dart 单点（finally 内 dispose），加上
    // attachment_service 的 codec 点共 2 个。低于 2 说明扫描失效；
    // 新增产生点时本测试会自动纳入 dispose 窗口检查。
    expect(checkedSites, greaterThanOrEqualTo(2),
        reason: '只找到 $checkedSites 个位图产生点，守卫本身失效了');
    expect(offenders, isEmpty,
        reason:
            '以下调用点泄漏 native 位图（pixelRatio 3.0 单张 8~15MB）：\n${offenders.join('\n')}');
  });

  test('attachment_service._getImageInfo 同时释放 codec 与 image', () {
    final body =
        File('lib/services/attachment_service.dart').readAsStringSync();
    final method = RegExp(
      r'_getImageInfo\(String imagePath\)\s*async\s*\{([\s\S]*?)\n  \}',
    ).firstMatch(body);
    expect(method, isNotNull, reason: '未找到 _getImageInfo 方法体，可能已重构');
    expect(method!.group(1), contains('codec?.dispose()'));
    expect(method.group(1), contains('image?.dispose()'));
    expect(method.group(1), contains('finally'));
  });
}
