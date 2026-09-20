/// M16（B9）：Riverpod `family` 的 key 必须有值相等语义。
///
/// `List<int>` / `Map` / `Set` 的 `==` 是身份相等 —— 每次传进来的都是新实例，
/// family 缓存每次都命中不了，于是**每帧新建一个 provider 元素且永不回收**
/// （交易列表滚动时按 id 批量取标签/附件数量正是这个形状）。
/// 类型系统中不了这条，所以扫源码：出现即红。
///
/// 修法是换个有 `==` 的 key（`ids.join(',')` 字符串最省事），或者干脆删掉
/// —— 本次扫出的两个都是无人调用的死 provider，直接删了。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/ 下没有以 List/Map/Set 为 key 的 family provider', () {
    // 锚在"值类型的收尾 >"上：`>` 后紧跟逗号、逗号后是 List/Map/Set 才算 key。
    // 只看 `.family<` 之后的第一个逗号会误伤 `family<List<({a, List<Tag> tags})>, int>`
    // 这种值类型里带 record 字段的写法（calendar_providers 就有一处）。
    // `[^;]` 把窗口锁在单条语句内（provider 声明以 `;` 收尾）。
    final pattern = RegExp(r'\.family<[^;]{0,200}>,\s*(List|Map|Set)\s*<');
    final bad = <String>[];
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
        .toList();

    for (final file in dartFiles) {
      final src = file.readAsStringSync();
      for (final m in pattern.allMatches(src)) {
        final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
        bad.add('${file.path}:$line  ${m.group(0)!.trim()}');
      }
    }

    expect(dartFiles.length, greaterThan(200), reason: '扫描范围本身出问题');
    expect(bad, isEmpty,
        reason: 'family key 用引用类型 = 每次新建一个永不回收的缓存元素:\n${bad.join('\n')}');
  });
}
