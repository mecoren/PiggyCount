#!/usr/bin/env python3
"""生成 Android adaptive icon 素材(前景 / monochrome 线框版)。

产出(1024×1024,内容缩进 adaptive 安全区 ~62%):
  assets/icon/adaptive_foreground.png  — 全彩小猪存钱罐(透明底),adaptive 前景层
  assets/icon/adaptive_monochrome.png  — 线框小猪(黑色+透明镂空),Android 13 themed icon 用
  assets/icon/preview_themed.png       — 模拟 Pixel 动态图标亮/暗效果(仅预览,不打包)
  assets/icon/launcher_legacy.png      — 不透明白底 legacy 启动图标

几何取自 assets/logo.svg(256 viewBox,小猪存钱罐造型),用 PIL 按 4× 超采样重绘后缩回抗锯齿。

用法:python3 scripts/gen_adaptive_icons.py
之后:dart run flutter_launcher_icons
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "icon"

CANVAS = 1024  # adaptive 图层画布
SS = 4  # 超采样倍数

# 内容 bbox: x[60, 218], y[60, 222],宽 158,高 162,中心约 (139, 141)
# 居中放到画布上,前景 60% 占比,monochrome 75% 占比
CONTENT_W = 158
CONTENT_H = 162
CONTENT_CX = 139
CONTENT_CY = 141

SCALE = 3.3
OFF_X = CANVAS / 2 - CONTENT_CX * SCALE
OFF_Y = CANVAS / 2 - CONTENT_CY * SCALE


def set_content_ratio(ratio):
    """设置内容(宽 158 单位)占画布的比例,居中。"""
    global SCALE, OFF_X, OFF_Y
    SCALE = CANVAS * ratio / CONTENT_W
    OFF_X = CANVAS / 2 - CONTENT_CX * SCALE
    OFF_Y = CANVAS / 2 - CONTENT_CY * SCALE


# 小猪 logo.svg 的配色
YELLOW = (255, 193, 7, 255)      # #FFC107 主体
ORANGE = (255, 179, 0, 255)      # #FFB300 耳朵/鼻子/腿
BLACK = (0, 0, 0, 255)
WHITE = (255, 255, 255, 255)


def pt(x, y):
    """256 坐标 → 超采样画布坐标"""
    return ((x * SCALE + OFF_X) * SS, (y * SCALE + OFF_Y) * SS)


def d(v):
    """256 尺度的长度 → 超采样画布长度"""
    return v * SCALE * SS


def ellipse_box(cx, cy, rx, ry):
    x0, y0 = pt(cx - rx, cy - ry)
    x1, y1 = pt(cx + rx, cy + ry)
    return [x0, y0, x1, y1]


def thick_line(draw, p0, p1, width, fill):
    """带圆头端点的粗线(PIL line 无 cap,用端点圆补)"""
    draw.line([p0, p1], fill=fill, width=int(width))
    for p in (p0, p1):
        r = width / 2
        draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] - r + width], fill=fill)


def triangle(draw, p0, p1, p2, fill, outline, width):
    """画填充三角形(带描边)"""
    pts = [pt(*p0), pt(*p1), pt(*p2)]
    draw.polygon(pts, fill=fill, outline=outline)
    # 描边:沿三条边画粗线
    for a, b in [(pts[0], pts[1]), (pts[1], pts[2]), (pts[2], pts[0])]:
        draw.line([a, b], fill=outline, width=int(width))


def gen_foreground():
    """全彩前景:与 logo.svg 同构(小猪存钱罐)"""
    set_content_ratio(0.60)
    im = Image.new("RGBA", (CANVAS * SS, CANVAS * SS), (0, 0, 0, 0))
    dr = ImageDraw.Draw(im)

    # 耳朵(三角形,先画在身体后面)
    triangle(dr, (70, 96), (60, 60), (100, 84), ORANGE, BLACK, d(6))
    triangle(dr, (186, 96), (196, 60), (156, 84), ORANGE, BLACK, d(6))

    # 主体(椭圆,黄填充 + 黑描边)
    dr.ellipse(ellipse_box(128, 148, 80, 62), fill=YELLOW,
               outline=BLACK, width=int(d(8)))

    # 投币口(顶部黑色矩形)
    slot_x0, slot_y0 = pt(108, 84)
    slot_x1, slot_y1 = pt(148, 90)
    dr.rounded_rectangle([slot_x0, slot_y0, slot_x1, slot_y1],
                          radius=int(d(3)), fill=BLACK)

    # 鼻子(椭圆 + 描边)
    dr.ellipse(ellipse_box(128, 158, 28, 20), fill=ORANGE,
               outline=BLACK, width=int(d(6)))
    # 鼻孔
    dr.ellipse(ellipse_box(120, 158, 4, 6), fill=BLACK)
    dr.ellipse(ellipse_box(136, 158, 4, 6), fill=BLACK)

    # 眼睛
    dr.ellipse(ellipse_box(108, 128, 5, 5), fill=BLACK)
    dr.ellipse(ellipse_box(148, 128, 5, 5), fill=BLACK)

    # 腿(圆角矩形)
    leg1_x0, leg1_y0 = pt(78, 200)
    leg1_x1, leg1_y1 = pt(96, 222)
    dr.rounded_rectangle([leg1_x0, leg1_y0, leg1_x1, leg1_y1],
                          radius=int(d(6)), fill=ORANGE, outline=BLACK, width=int(d(6)))
    leg2_x0, leg2_y0 = pt(160, 200)
    leg2_x1, leg2_y1 = pt(178, 222)
    dr.rounded_rectangle([leg2_x0, leg2_y0, leg2_x1, leg2_y1],
                          radius=int(d(6)), fill=ORANGE, outline=BLACK, width=int(d(6)))

    # 尾巴(卷曲路径,用多段线近似贝塞尔)
    # M208 148 Q220 140 214 128 Q208 120 218 116
    tail_pts = []
    # 第一段二次贝塞尔: (208,148) -> control (220,140) -> (214,128)
    p0, p1, p2 = (208, 148), (220, 140), (214, 128)
    for i in range(21):
        t = i / 20
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        tail_pts.append(pt(x, y))
    # 第二段二次贝塞尔: (214,128) -> control (208,120) -> (218,116)
    p0, p1, p2 = (214, 128), (208, 120), (218, 116)
    for i in range(1, 21):
        t = i / 20
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        tail_pts.append(pt(x, y))
    for a, b in zip(tail_pts, tail_pts[1:]):
        thick_line(dr, a, b, d(6), BLACK)

    return im.resize((CANVAS, CANVAS), Image.LANCZOS)


def gen_monochrome():
    """单色版:themed icon 只取 alpha 通道,特征全部用实心形 + 透明镂空表达。
    - 主体:实心椭圆
    - 耳朵:实心三角形
    - 鼻子:实心椭圆 + 镂空鼻孔
    - 眼睛:镂空
    - 投币口:镂空缝
    - 腿:实心圆角矩形
    - 尾巴:粗线
    画布占比 0.75。
    """
    set_content_ratio(0.75)
    mask = Image.new("L", (CANVAS * SS, CANVAS * SS), 0)
    dr = ImageDraw.Draw(mask)

    # 耳朵(实心三角形)
    ear1 = [pt(70, 96), pt(60, 60), pt(100, 84)]
    ear2 = [pt(186, 96), pt(196, 60), pt(156, 84)]
    dr.polygon(ear1, fill=255)
    dr.polygon(ear2, fill=255)

    # 主体(实心椭圆)
    dr.ellipse(ellipse_box(128, 148, 80, 62), fill=255)

    # 腿(实心圆角矩形)
    leg1_x0, leg1_y0 = pt(78, 200)
    leg1_x1, leg1_y1 = pt(96, 222)
    dr.rounded_rectangle([leg1_x0, leg1_y0, leg1_x1, leg1_y1],
                          radius=int(d(6)), fill=255)
    leg2_x0, leg2_y0 = pt(160, 200)
    leg2_x1, leg2_y1 = pt(178, 222)
    dr.rounded_rectangle([leg2_x0, leg2_y0, leg2_x1, leg2_y1],
                          radius=int(d(6)), fill=255)

    # 尾巴(粗线)
    tail_pts = []
    p0, p1, p2 = (208, 148), (220, 140), (214, 128)
    for i in range(21):
        t = i / 20
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        tail_pts.append(pt(x, y))
    p0, p1, p2 = (214, 128), (208, 120), (218, 116)
    for i in range(1, 21):
        t = i / 20
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        tail_pts.append(pt(x, y))
    for a, b in zip(tail_pts, tail_pts[1:]):
        thick_line(dr, a, b, d(8), 255)

    # 鼻子(实心椭圆)
    dr.ellipse(ellipse_box(128, 158, 28, 20), fill=255)

    # 投币口:镂空缝(横穿主体顶部)
    slot_x0, slot_y0 = pt(108, 84)
    slot_x1, slot_y1 = pt(148, 92)
    dr.rounded_rectangle([slot_x0, slot_y0, slot_x1, slot_y1],
                          radius=int(d(3)), fill=0)

    # 鼻孔:镂空
    dr.ellipse(ellipse_box(120, 158, 5, 7), fill=0)
    dr.ellipse(ellipse_box(136, 158, 5, 7), fill=0)

    # 眼睛:镂空
    dr.ellipse(ellipse_box(108, 128, 7, 7), fill=0)
    dr.ellipse(ellipse_box(148, 128, 7, 7), fill=0)

    mask = mask.resize((CANVAS, CANVAS), Image.LANCZOS)
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 255))
    out.putalpha(mask)
    return out


def gen_preview(mono):
    """模拟 Pixel themed icon 亮/暗效果,纯预览用"""
    size = 512
    pad = 40
    glyph = mono.resize((size, size), Image.LANCZOS)
    canvas = Image.new("RGBA", (size * 2 + pad * 3, size + pad * 2),
                       (255, 255, 255, 255))
    for i, (bg, fg) in enumerate([
        ((233, 226, 208, 255), (74, 68, 89, 255)),   # 亮:浅底深 glyph
        ((74, 68, 89, 255), (233, 226, 208, 255)),   # 暗:深底浅 glyph
    ]):
        cell = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        dr = ImageDraw.Draw(cell)
        dr.ellipse([0, 0, size, size], fill=bg)
        tinted = Image.new("RGBA", (size, size), fg)
        tinted.putalpha(glyph.getchannel("A"))
        cell = Image.alpha_composite(cell, tinted)
        canvas.paste(cell, (pad + i * (size + pad), pad), cell)
    return canvas


def gen_legacy(fg):
    """legacy 启动图标(Android 8 以下 / 不支持 adaptive 的 launcher):
    必须**不透明**——透明底在部分设备上表现很差。底色与 adaptive 背景一致。
    """
    bg = Image.new("RGBA", (CANVAS, CANVAS), (255, 255, 255, 255))  # 白底
    # 前景占比 0.60 留白偏多,legacy 无系统蒙版裁切,放大一些(0.60×1.3=0.78)
    big = int(CANVAS * 1.3)
    scaled = fg.resize((big, big), Image.LANCZOS)
    crop = (big - CANVAS) // 2
    bg.alpha_composite(scaled.crop((crop, crop, crop + CANVAS, crop + CANVAS)))
    return bg


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    fg = gen_foreground()
    fg.save(OUT_DIR / "adaptive_foreground.png")
    gen_legacy(fg).save(OUT_DIR / "launcher_legacy.png")
    mono = gen_monochrome()
    mono.save(OUT_DIR / "adaptive_monochrome.png")
    gen_preview(mono).save(OUT_DIR / "preview_themed.png")
    print("✓ adaptive_foreground / launcher_legacy / adaptive_monochrome / preview_themed →", OUT_DIR)


if __name__ == '__main__':
    main()
