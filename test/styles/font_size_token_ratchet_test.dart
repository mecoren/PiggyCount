import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// U1 门禁：`lib/pages` / `lib/widgets` 里的硬编码字号**只减不增**。
///
/// 为什么是 ratchet 而不是一次性收敛（本轮实测，不是推测）：
/// - 字面量共 549 处（pages 340 / widgets 209），最高频是 **16（125 次）和 13（64 次）**；
/// - [PiggyTextTokens] 的成员不是字号常量，而是返回整只 `TextStyle` 的方法
///   （`lib/styles/tokens.dart:800-856`，`title/strongTitle/boldTitle/body/label`，
///   兜底分支里的值只有 11/12/14/15/18）—— 一次 `fontSize: 16` → 令牌的替换会连带
///   把 color / fontWeight / fontFamily 一起换掉，是改视觉而不是改名字；
/// - 另一条路 `PiggyTypography.buildBase`（`:871`）是 TextTheme 级替换，同样带
///   height/family 副作用，且 16/13 在那里也没有对位档位；
/// - 本轮无 Android 真机/模拟器，拿不到收敛前后的截图对比。
///
/// 所以这里只钉死一条：**新增一处硬编码字号就红**。逐文件收敛留到有视觉回归条件时做，
/// 失败信息里的直方图就是那份迁移顺序表（先做令牌里已有的 14/12/15，再决定 16/13 是
/// 补令牌还是并档）。
void main() {
  // 基线：2026-09-19 实测。只允许往下走。
  const baseline = {'lib/pages': 340, 'lib/widgets': 209};
  final literalFontSize = RegExp(r'fontSize:\s*\d');

  test('硬编码字号未超过基线（只减不增）', () {
    final counts = <String, int>{};
    final perFile = <String, int>{};
    final histogram = <String, int>{};

    for (final dir in baseline.keys) {
      var total = 0;
      for (final file in Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        var inFile = 0;
        for (final line in file.readAsLinesSync()) {
          final t = line.trimLeft();
          if (t.startsWith('//') || t.startsWith('*')) continue; // 注释不算
          for (final m in literalFontSize.allMatches(line)) {
            inFile++;
            // 直方图键：把 `fontSize: 16` / `16.0` / `16.sp` 归到 16
            // （m.end 在数字之后，回退 1 才拿到首位）
            final rest = line.substring(m.end - 1);
            final v = RegExp(r'^[0-9]+').firstMatch(rest)?.group(0) ?? '?';
            histogram[v] = (histogram[v] ?? 0) + 1;
          }
        }
        total += inFile;
        if (inFile > 0) perFile[file.path] = inFile;
      }
      counts[dir] = total;
    }

    final measured = counts.values.fold<int>(0, (a, b) => a + b);
    expect(measured, greaterThanOrEqualTo(500),
        reason: '整个扫描只找到 $measured 处，正则或目录写错了，守卫本身失效了');

    final offenders = <String>[];
    for (final entry in counts.entries) {
      final allowed = baseline[entry.key]!;
      if (entry.value > allowed) {
        offenders.add('${entry.key}: ${entry.value} > 基线 $allowed '
            '（多出 ${entry.value - allowed} 处）');
      }
    }
    final top = perFile.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final hist = (histogram.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .map((e) => '${e.key}×${e.value}')
        .join(' ');

    expect(offenders, isEmpty, reason: [
      ...offenders,
      '',
      '新增处在哪（当前最多 8 个文件）：',
      ...top.take(8).map((e) => '  ${e.value}  ${e.key}'),
      '',
      '字面量直方图（出现次数从多到少，就是收敛顺序）：$hist',
      '用 [PiggyTextTokens] 已有字号（14/12/15/11/18）替换即可减数；',
      '16 与 13 无对应令牌 —— 要动它们得先决定是补令牌还是并档，别顺手改。',
    ].join('\n'));
  });
}
