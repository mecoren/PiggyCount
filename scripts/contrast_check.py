"""WCAG 对比度算式：只读 tokens.dart 里的颜色常量，不涉及设备。

用途：方案 §五 U2 验收项「对比度 ≥4.5:1」。这里出的是**算式不是真机截图**，
所以只作为「哪些令牌本身不合格」的证据，不做成门禁（不合格项要改就是改视觉，
与 U1 同一前置：先有截图回归）。
"""


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

CASES = [
    # (标签, 前景, alpha(None=不透明), 背景集合)
    ('textPrimary 亮', hexrgb('111827'), None, [('页', PAGE_L), ('卡', CARD_L)]),
    ('textSecondary 亮(black54)', (0, 0, 0), 0x8A / 255, [('页', PAGE_L), ('卡', CARD_L)]),
    ('textTertiary 亮', hexrgb('9CA3AF'), None, [('页', PAGE_L), ('卡', CARD_L)]),
    ('textPrimary 暗', WHITE, None, [('页', PAGE_D), ('卡', CARD_D)]),
    ('textSecondary 暗(white70)', WHITE, 0.7, [('页', PAGE_D), ('卡', CARD_D)]),
    ('textTertiary 暗(white54)', WHITE, 0.54, [('页', PAGE_D), ('卡', CARD_D)]),
    ('textDisabled 亮(black26)', (0, 0, 0), 0.26, [('页', PAGE_L)]),
]

print(f"{'令牌组合':<26}{'底':<4}{'对比度':>8}  判定(4.5 正文 / 3.0 大字)")
for name, fg, alpha, bgs in CASES:
    for bname, bg in bgs:
        eff = fg if alpha is None else over(fg, alpha, bg)
        r = ratio(eff, bg)
        verdict = 'PASS' if r >= 4.5 else ('大字PASS' if r >= 3.0 else 'FAIL')
        print(f'{name:<26}{bname:<4}{r:>8.2f}  {verdict}')
