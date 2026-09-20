import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// M12 源码契约守卫：lib/ 下每个 `Image.asset(...)` 必须带 cacheWidth。
///
/// 为什么按调用点而不是按资产体积：`assets/icon/icon_master.png` 与
/// `assets/logo2.png` 都是 1024²（解码 4MB），`assets/images/piggyassets_*.png`
/// 是 1179×2556（11.5MB），而引用它们的 widget 常把路径装在数据类里传来
/// （`ProductPromo.logoAsset`），按文件名扫会漏掉间接引用。调用点只有一处真值：
/// 渲染时到底解多大。
void main() {
  // 产生点之后多少行内必须看到 cacheWidth
  const widthWindow = 7;

  test('lib/ 下每个 Image.asset 都钉了 cacheWidth', () {
    final offenders = <String>[];
    var checkedSites = 0;

    for (final file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue; // 注释里提到的不算调用点
        if (!line.contains('Image.asset(')) continue;
        checkedSites++;
        final window = lines.skip(i).take(widthWindow).join('\n');
        if (!window.contains('cacheWidth')) {
          offenders.add('${file.path}:${i + 1}  ${line.trim()}');
        }
      }
    }

    expect(checkedSites, greaterThan(0), reason: '一个调用点都没扫到，守卫本身失效了');
    expect(offenders, isEmpty,
        reason:
            '以下 Image.asset 按原图尺寸解码（PNG 解码后 = 宽×高×4B）：\n${offenders.join('\n')}');
  });
}
