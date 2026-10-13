/// PDF 报表的内嵌字体契约：资产必须覆盖**报表实际会用到的文案**里的每个字。
///
/// 为什么值得单独守一道：中文 PDF 最经典的坑是「跑到某个字才画成一个空占位
/// 框」——`pdf` 包遇到缺字既不抛异常也不返回错误（只在 debug 断言里 print 一
/// 行），跑一百个用例也发现不了。所以把「字体 ↔ 文案」做成静态门禁：
/// 改文案后漏字 → 本测试直接红，提示重跑
/// `python scripts/fetch_pdf_report_font.py`（它会重新扫 arb 并扩子集）。
///
/// 必需字符集的来源是**排版源码本身**：从 `lib/services/export/*.dart` 里抠出
/// 所有 `l10n.<key>` 引用，再到 ash 里取这些 key 在 zh / en / zh_TW 三种官方
/// 语言下的值。这样门禁自动跟着代码走，也不会被别处的 emoji 文案（Noto Sans SC
/// 根本没有彩色 emoji，PDF 文案里也不该出现）误报。
///
/// 覆盖范围不含 `ko`：Noto Sans SC 本身没有谚文（0/11172），要支持得另引
/// Noto Sans KR 子集，见 `scripts/fetch_pdf_report_font.py` 头部说明。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fontAssets = {
    'Regular': 'assets/fonts/NotoSansSC-Regular-subset.ttf',
    'Bold': 'assets/fonts/NotoSansSC-Bold-subset.ttf',
  };
  const exportDir = 'lib/services/export';

  /// 从导出层的 Dart 源码里抠出用到的 l10n key。
  ///
  /// 同时兼顾两种写法：`l10n.xxx` 与 `l10n!.xxx`；参数化 key（如
  /// `pdfReportPageOf(1, 2)`）只取方法名，占位符本身不是文案字符。
  Set<String> usedL10nKeys() {
    final keys = <String>{};
    final pattern = RegExp(r'l10n!?\.([A-Za-z][A-Za-z0-9_]*)');
    for (final entity in Directory(exportDir).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final m in pattern.allMatches(entity.readAsStringSync())) {
        keys.add(m.group(1)!);
      }
    }
    return keys;
  }

  test('字体资产在位、体积像样、能被 pdf 包解析', () async {
    for (final entry in fontAssets.entries) {
      final data = await rootBundle.load(entry.value);
      final size = data.lengthInBytes;
      expect(size, greaterThan(500 * 1024),
          reason: '${entry.value} 太小：像是没跑 scripts/fetch_pdf_report_font.py');
      expect(size, lessThan(12 * 1024 * 1024),
          reason: '${entry.value} 是完整字重（10MB 级）：不该入库，重跑子集脚本');
      // 真解析一遍：资产被截断 / 不是 glyf 轮廓（OTF-CFF、TTC）时这里就会抛。
      final ttf = TtfParser(data);
      expect(ttf.numGlyphs, greaterThan(6000),
          reason: '字形数太少，子集选错了');
    }
  });

  test('两种字重覆盖报表文案的每个字符', () async {
    final keys = usedL10nKeys();
    expect(keys.length, greaterThan(20),
        reason: '只从 $exportDir 里抠到 ${keys.length} 个 l10n key，守卫本身失效了');

    final arb = <String, Map<String, dynamic>>{
      for (final locale in ['zh', 'en', 'zh_TW'])
        locale: jsonDecode(
            File('lib/l10n/app_$locale.arb').readAsStringSync()) as Map<String, dynamic>,
    };

    final required = <int>{};
    final unknown = <String>[];
    for (final key in keys) {
      var hit = false;
      for (final values in arb.values) {
        final value = values[key];
        if (value is String) {
          hit = true;
          required.addAll(value.runes);
        }
      }
      if (!hit) unknown.add(key);
    }
    expect(unknown, isEmpty, reason: '这些 key 在官方 arb 里找不到，可能是拼错了：$unknown');
    // 换行/空格不是字形，不参与覆盖判定
    required.removeAll(const {0x0A, 0x0D, 0x09, 0x20});

    for (final entry in fontAssets.entries) {
      final ttf = TtfParser(await rootBundle.load(entry.value));
      final missing = <int>[
        for (final rune in required)
          if (!ttf.charToGlyphIndexMap.containsKey(rune)) rune,
      ]..sort();
      expect(missing, isEmpty,
          reason: '${entry.key} 缺 ${missing.length} 个字：'
              '${missing.map(String.fromCharCode).join()}'
              '\n重跑 `python scripts/fetch_pdf_report_font.py` 重生成子集。');
    }
  });
}
