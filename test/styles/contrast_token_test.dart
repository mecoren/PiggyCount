/// 无障碍对比度令牌契约（WCAG 1.4.3 正文 ≥4.5:1 / 1.4.11 非文本 ≥3:1）。
///
/// 直接读 `lib/styles/tokens.dart` 里的**亮色字面量**算对比度 —— 令牌改回
/// 不合格的值（例如把 `textTertiary` 退回 `#9CA3AF`）本测试必须变红。
/// 算式与 `scripts/contrast_check.py` 同源（sRGB 相对亮度 + (L1+.05)/(L2+.05)）。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

/// 亮色页面底 / 卡片底（与 `scripts/contrast_check.py` 一致）。
const int _pageBg = 0xFFE5EEFE;
const int _cardBg = 0xFFF9F9F9;

double _lin(int c) {
  final v = c / 255.0;
  return v <= 0.04045
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(int argb) {
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  return 0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b);
}

double _ratio(int fg, int bg) {
  final a = _luminance(fg);
  final b = _luminance(bg);
  final hi = a > b ? a : b;
  final lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}

int _hexFrom(String source, RegExp pattern, String what) {
  final m = pattern.firstMatch(source);
  expect(m, isNotNull,
      reason: '在 tokens.dart 里找不到 $what（正则失配即失败，'
          '防止令牌被改成别的表达而绕过本契约）');
  return 0xFF000000 | int.parse(m!.group(1)!, radix: 16);
}

void main() {
  late String source;

  setUpAll(() {
    source = File('lib/styles/tokens.dart').readAsStringSync();
  });

  test('亮色 textSecondary 达正文线（≥4.5:1）', () {
    final c = _hexFrom(
        source,
        RegExp(r'_textSecondaryLight\s*=\s*Color\(0xFF([0-9A-Fa-f]{6})\)'),
        '_textSecondaryLight');
    expect(_ratio(c, _pageBg), greaterThanOrEqualTo(4.5),
        reason: '页面底对比度需 ≥4.5');
    expect(_ratio(c, _cardBg), greaterThanOrEqualTo(4.5),
        reason: '卡片底对比度需 ≥4.5');
  });

  test('亮色 textTertiary 达正文线（≥4.5:1），且不再用 #9CA3AF', () {
    final c = _hexFrom(
        source,
        RegExp(r'textTertiary\(BuildContext context\)[\s\S]*?'
            r'const Color\(0xFF([0-9A-Fa-f]{6})\)'),
        'textTertiary 亮色字面量');
    expect(_ratio(c, _pageBg), greaterThanOrEqualTo(4.5));
    expect(_ratio(c, _cardBg), greaterThanOrEqualTo(4.5));
    // 只锁 textTertiary 自己：`#9CA3AF` 仍是 `statusOffline` 的合法取值
    expect(c, isNot(0xFF9CA3AF),
        reason: '历史不合格值不得回流（亮色 2.18 / 2.41 < 4.5）');
  });

  test('亮色 iconTertiary 达非文本线（≥3:1）', () {
    final m = RegExp(r'iconTertiary\(BuildContext context\)[\s\S]*?'
            r'Colors\.black\.withValues\(alpha:\s*([0-9.]+)\)')
        .firstMatch(source);
    expect(m, isNotNull, reason: '找不到 iconTertiary 亮色 alpha');
    final alpha = double.parse(m!.group(1)!);
    expect(alpha, greaterThanOrEqualTo(0.45),
        reason: '原 0.38 只有 2.63 / 2.66，未达 3:1');
  });
}
