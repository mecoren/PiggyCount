# -*- coding: utf-8 -*-
"""WCAG 对比度门禁：只读亮/暗两套文字色（纯算式，不需要设备）。

用法::

  python scripts/contrast_check.py            # 打印全部组合并给出判定
  python scripts/contrast_check.py --quiet    # 只在不合格时输出（CI 友好）

退出码：有任何 **正文级** 组合 FAIL（<4.5:1）返回 1，否则 0 —— 因此可直接
挂在 CI 上。`textDisabled`（inactive）按 WCAG 1.4.3 明确豁免，不计入。

判定口径：
  正文（normal text）≥ 4.5:1 ；大字（large text，≥18pt/14pt bold）≥ 3.0:1 ；
  非文本 UI（图标/控件边界，1.4.11）≥ 3.0:1。

自检（不依赖设备，也不依赖终端）::

  python scripts/contrast_check.py --self-check
"""
import sys


def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lum(rgb):
    r, g, b = (lin(v) for v in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def hexrgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def over(fg_rgb, alpha, bg_rgb):
    """fg 带 alpha 叠在 bg 上（Flutter 的 withValues(alpha:) 就是这个语义）。"""
    return tuple(f * alpha + b * (1 - alpha) for f, b in zip(fg_rgb, bg_rgb))


def ratio(fg, bg):
    a, b = lum(fg), lum(bg)
    hi, lo = (a, b) if a > b else (b, a)
    return (hi + 0.05) / (lo + 0.05)


PAGE_L, CARD_L = hexrgb('E5EEFE'), hexrgb('F9F9F9')
PAGE_D, CARD_D = hexrgb('151A24'), hexrgb('1C2330')
WHITE = (255, 255, 255)
BLACK = (0, 0, 0)

# (标签, 前景, alpha(None=不透明), 背景集合, 最低要求)
# 最低要求：4.5 = 正文；3.0 = 大字 / 非文本 UI；None = 豁免不计。
CASES = [
    ('textPrimary 亮',    hexrgb('111827'), None, [('页', PAGE_L), ('卡', CARD_L)], 4.5),
    ('textSecondary 亮',  hexrgb('4B5563'), None, [('页', PAGE_L), ('卡', CARD_L)], 4.5),
    ('textTertiary 亮',   hexrgb('5F6B7A'), None, [('页', PAGE_L), ('卡', CARD_L)], 4.5),
    ('iconTertiary 亮',   BLACK, 0.45, [('页', PAGE_L), ('卡', CARD_L)], 3.0),
    ('textPrimary 暗',    WHITE, None, [('页', PAGE_D), ('卡', CARD_D)], 4.5),
    ('textSecondary 暗',  WHITE, 0.7,  [('页', PAGE_D), ('卡', CARD_D)], 4.5),
    ('textTertiary 暗',   WHITE, 0.54, [('页', PAGE_D), ('卡', CARD_D)], 4.5),
    ('iconTertiary 暗',   WHITE, 0.54, [('页', PAGE_D), ('卡', CARD_D)], 3.0),
    # 豁免：inactive / disabled（WCAG 1.4.3 明确排除）
    ('textDisabled 亮',   BLACK, 0.26, [('页', PAGE_L)], None),
]


def evaluate():
    rows = []
    for name, fg, alpha, bgs, need in CASES:
        for bname, bg in bgs:
            eff = fg if alpha is None else over(fg, alpha, bg)
            r = ratio(eff, bg)
            if need is None:
                verdict = '豁免'
            elif r >= 4.5:
                verdict = 'PASS'
            elif r >= need:
                verdict = 'PASS(大字/非文本)'
            else:
                verdict = 'FAIL'
            rows.append((name, bname, r, need, verdict))
    return rows


def self_check():
    """不连设备也能验的那部分：WCAG 公式与判定。"""
    # 黑/白极限：1:1 与 21:1
    assert abs(ratio(BLACK, WHITE) - 21.0) < 1e-9, ratio(BLACK, WHITE)
    assert abs(ratio(WHITE, WHITE) - 1.0) < 1e-9
    # 已知点：#9CA3AF 叠亮色页面底是 2.18（历史实测值，改色前）
    assert abs(ratio(hexrgb('9CA3AF'), PAGE_L) - 2.18) < 0.01, \
        ratio(hexrgb('9CA3AF'), PAGE_L)
    # alpha 叠加：全透明 = 背景本身
    assert over(WHITE, 0.0, PAGE_D) == PAGE_D
    rows = evaluate()
    assert all(v != 'FAIL' for *_x, v in rows), \
        [r for r in rows if r[-1] == 'FAIL']
    # 豁免项必须真的被标成豁免（防止把 disabled 误当门禁）
    assert any(v == '豁免' for *_x, v in rows)
    print('self-check ok')


def main():
    quiet = '--quiet' in sys.argv
    if '--self-check' in sys.argv:
        self_check()
        return 0

    rows = evaluate()
    failures = [r for r in rows if r[4] == 'FAIL']
    if not quiet:
        print(f"{'令牌组合':<26}{'底':<4}{'对比度':>8}  判定"
              '(4.5 正文 / 3.0 大字·非文本)')
        for name, bname, r, need, verdict in rows:
            print(f'{name:<26}{bname:<4}{r:>8.2f}  {verdict}')
    if failures:
        print('\n不合格组合（正文需 ≥4.5:1 / 大字·非文本 ≥3.0:1）：')
        for name, bname, r, need, _v in failures:
            print(f'  - {name} 叠{bname}底：{r:.2f} < {need}')
        return 1
    print('OK: 全部组合达标' if quiet else '\nOK: 全部组合达标')
    return 0


if __name__ == '__main__':
    sys.exit(main())
