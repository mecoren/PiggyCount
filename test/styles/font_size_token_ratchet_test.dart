import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 硬编码字号门禁：`lib/pages` / `lib/widgets` 里**不得**再出现裸数字 `fontSize`。
///
/// 历史与转折：
/// - 2026-09-19 U1 实测 549 处字面量，当时只交了 ratchet 门禁 —— 原因是
///   `PiggyTextTokens` 的成员返回整只 `TextStyle`（自带 color / fontWeight /
///   行高），逐处替换等于**改视觉**，且 16 / 13 两档根本没有对应令牌。
/// - 2026-10-05 补了 `PiggyTextTokens.fs*` **纯字号刻度**（只有 double，不带
///   颜色字重行高），`fontSize: 16` → `fontSize: PiggyTextTokens.fs16` 成为
///   **零视觉变更**的机械收敛 —— 506 处已全部迁移，基线压到 **0**。
///
/// 现在的门禁含义：新增一处裸数字字号即红。请用 `PiggyTextTokens.fs16`
/// （或语义化的 `title/body/label/...`，若确实要连带颜色字重）。
void main() {
  const baseline = {'lib/pages': 0, 'lib/widgets': 0};
  final literalFontSize = RegExp(r'fontSize:\s*\d');

  test('硬编码字号未超过基线（只减不增）', () {
    final counts = <String, int>{};
    final perFile = <String, int>{};
    final histogram = <String, int>{};
    var scannedFiles = 0;

    for (final dir in baseline.keys) {
      var total = 0;
      for (final file in Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        scannedFiles++;
        var inFile = 0;
        for (final line in file.readAsLinesSync()) {
          final t = line.trimLeft();
          if (t.startsWith('//') || t.startsWith('*')) continue; // 注释不算
          for (final m in literalFontSize.allMatches(line)) {
            inFile++;
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

    // 守卫自检：走的文件太少说明目录写错或扫描失效（收敛到 0 之后，
    // 不能用"字面量 ≥500"当自检了）。
    expect(scannedFiles, greaterThanOrEqualTo(40),
        reason: '只扫到 $scannedFiles 个 dart 文件，守卫本身失效了');

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
      '请改用 PiggyTextTokens.fs*（纯字号，零视觉变更）；',
      '若确实要连带颜色/字重，用 title / body / label 那些语义令牌。',
    ].join('\n'));
  });
}
