#!/usr/bin/env python3
"""从源 PNG 抠图生成全平台图标素材（透明背景）。

输入：用户提供的 PNG（近白底，主体居中）。
输出（全部 1024×1024 除非另注）：
  assets/icon/icon_master.png         - 透明背景主图（抠图后居中缩放）
  assets/icon/adaptive_foreground.png - Android adaptive 前景层（透明，内容缩至 60% 留 safe zone）
  assets/icon/adaptive_monochrome.png - Android 13+ themed icon 单色层（黑色 + alpha 蒙版）
  assets/icon/launcher_legacy.png     - Android legacy 启动图标（透明）
  assets/logo2.png                    - 海报/splash 用 logo（透明，1024×1024）
  assets/logo_216.png                 - 216×216
  assets/logo_512.png                 - 512×512
  ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png - iOS AppIcon（白底合成，iOS 不支持 alpha）

用法：
  python scripts/gen_icons_from_image.py <源图.png>

之后运行：
  dart run flutter_launcher_icons   # 用 adaptive_* / launcher_legacy 生成 Android 各密度图标
  # iOS 图标已由本脚本直接生成（gen_ios_icons.py 的逻辑已内嵌）
"""

import sys
from collections import deque
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ICON_DIR = ROOT / "assets" / "icon"
ASSETS_DIR = ROOT / "assets"
IOS_DIR = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"

# 背景抠除参数
BG_TOLERANCE = 32  # 颜色距离容差（曼哈顿距离 / 3）
EDGE_FEATHER = 1   # 边缘羽化半径（像素）

# 画布尺寸
MASTER_SIZE = 1024
ADAPTIVE_CONTENT_RATIO = 0.60  # adaptive 前景内容占比（留 safe zone）


def _average_corner_color(pixels, w, h):
    """取 4 个角像素的平均色作为背景色估计。"""
    r = (pixels[0, 0][0] + pixels[w - 1, 0][0] + pixels[0, h - 1][0] + pixels[w - 1, h - 1][0]) // 4
    g = (pixels[0, 0][1] + pixels[w - 1, 0][1] + pixels[0, h - 1][1] + pixels[w - 1, h - 1][1]) // 4
    b = (pixels[0, 0][2] + pixels[w - 1, 0][2] + pixels[0, h - 1][2] + pixels[w - 1, h - 1][2]) // 4
    return (r, g, b)


def _color_match(pixel, bg, tol):
    """曼哈顿距离 / 3 <= tol 视为背景色。"""
    return (abs(pixel[0] - bg[0]) + abs(pixel[1] - bg[1]) + abs(pixel[2] - bg[2])) / 3.0 <= tol


def remove_background(img, tol=BG_TOLERANCE):
    """从图像中移除近白背景：BFS flood-fill 从所有边界像素出发。

    仅移除与背景连通的像素，主体内部浅色区域不会被误删。
    返回 RGBA 图像，背景区 alpha=0。
    """
    img = img.convert("RGBA")
    w, h = img.size
    pixels = img.load()

    bg = _average_corner_color(pixels, w, h)

    visited = bytearray(w * h)  # 0=未访问，1=背景
    queue = deque()

    # 从四条边的所有像素播种（确保覆盖整圈背景）
    def seed(x, y):
        idx = y * w + x
        if not visited[idx] and _color_match(pixels[x, y], bg, tol):
            visited[idx] = 1
            queue.append((x, y))

    for x in range(w):
        seed(x, 0)
        seed(x, h - 1)
    for y in range(h):
        seed(0, y)
        seed(w - 1, y)

    # BFS 扩散
    while queue:
        x, y = queue.popleft()
        for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                idx = ny * w + nx
                if not visited[idx] and _color_match(pixels[nx, ny], bg, tol):
                    visited[idx] = 1
                    queue.append((nx, ny))

    # 生成 alpha 通道
    alpha = Image.new("L", (w, h), 255)
    alpha_px = alpha.load()
    for y in range(h):
        row = y * w
        for x in range(w):
            if visited[row + x]:
                alpha_px[x, y] = 0

    # 边缘羽化（避免主体边缘出现锯齿状硬切）
    if EDGE_FEATHER > 0:
        alpha = alpha.filter(ImageFilter.GaussianBlur(radius=EDGE_FEATHER))

    out = img.copy()
    out.putalpha(alpha)
    return out


def crop_to_content(img):
    """裁剪到非透明内容的边界框。"""
    bbox = img.getbbox()
    return img.crop(bbox) if bbox else img


def fit_to_canvas(content, canvas_size, content_ratio):
    """把内容等比缩放到占画布 content_ratio 比例，居中放置到透明画布。"""
    cw, ch = content.size
    scale = (canvas_size * content_ratio) / float(max(cw, ch))
    new_w = max(1, int(round(cw * scale)))
    new_h = max(1, int(round(ch * scale)))
    content = content.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    offset = ((canvas_size - new_w) // 2, (canvas_size - new_h) // 2)
    canvas.alpha_composite(content, offset)
    return canvas


def make_adaptive_foreground(master):
    """Android adaptive 前景层：内容缩至 60%（留 safe zone），居中，透明背景。"""
    content = crop_to_content(master)
    return fit_to_canvas(content, MASTER_SIZE, ADAPTIVE_CONTENT_RATIO)


def make_monochrome(foreground):
    """Android 13+ themed icon 单色层：黑色像素 + alpha 蒙版。

    系统会自动着色，所以颜色不重要，只看 alpha 通道的形状。
    """
    alpha = foreground.getchannel("A")
    out = Image.new("RGBA", foreground.size, (0, 0, 0, 255))
    out.putalpha(alpha)
    return out


def make_ios_icons(master):
    """生成 iOS AppIcon 全套尺寸。

    iOS App Store 强制要求图标无 alpha 通道（不透明），
    故把透明主体合成到白底上，视觉上与透明版在白色背景上一致。
    """
    bg = Image.new("RGBA", master.size, (255, 255, 255, 255))
    composited = Image.alpha_composite(bg, master).convert("RGB")

    sizes = [
        ("Icon-App-1024x1024@1x.png", 1024),
        ("Icon-App-20x20@1x.png", 20),
        ("Icon-App-20x20@2x.png", 40),
        ("Icon-App-20x20@3x.png", 60),
        ("Icon-App-29x29@1x.png", 29),
        ("Icon-App-29x29@2x.png", 58),
        ("Icon-App-29x29@3x.png", 87),
        ("Icon-App-40x40@1x.png", 40),
        ("Icon-App-40x40@2x.png", 80),
        ("Icon-App-40x40@3x.png", 120),
        ("Icon-App-50x50@1x.png", 50),
        ("Icon-App-50x50@2x.png", 100),
        ("Icon-App-57x57@1x.png", 57),
        ("Icon-App-57x57@2x.png", 114),
        ("Icon-App-60x60@2x.png", 120),
        ("Icon-App-60x60@3x.png", 180),
        ("Icon-App-72x72@1x.png", 72),
        ("Icon-App-72x72@2x.png", 144),
        ("Icon-App-76x76@1x.png", 76),
        ("Icon-App-76x76@2x.png", 152),
        ("Icon-App-83.5x83.5@2x.png", 167),
    ]
    for name, size in sizes:
        out = composited.resize((size, size), Image.LANCZOS)
        out.save(IOS_DIR / name, "PNG")
        print(f"  iOS: {name} ({size}x{size})")


def main():
    if len(sys.argv) < 2:
        print("Usage: python scripts/gen_icons_from_image.py <source.png>")
        sys.exit(1)

    src_path = Path(sys.argv[1]).expanduser().resolve()
    if not src_path.exists():
        print(f"Source not found: {src_path}")
        sys.exit(1)

    ICON_DIR.mkdir(parents=True, exist_ok=True)
    IOS_DIR.mkdir(parents=True, exist_ok=True)

    print(f"[1/4] Loading source: {src_path}")
    src = Image.open(src_path).convert("RGBA")

    print("[2/4] Removing background (BFS flood-fill from borders)...")
    transparent = remove_background(src)

    # 把主体裁剪到边界框，再等比缩放到 1024×1024 透明画布（主体居中、不裁切）
    content = crop_to_content(transparent)
    master = Image.new("RGBA", (MASTER_SIZE, MASTER_SIZE), (0, 0, 0, 0))
    cw, ch = content.size
    # 主体充满画布的 88%（留少量边距，避免顶到边缘）
    scale = (MASTER_SIZE * 0.88) / float(max(cw, ch))
    new_w = max(1, int(round(cw * scale)))
    new_h = max(1, int(round(ch * scale)))
    content = content.resize((new_w, new_h), Image.LANCZOS)
    master.alpha_composite(content, ((MASTER_SIZE - new_w) // 2, (MASTER_SIZE - new_h) // 2))

    print("[3/4] Generating derived assets...")
    master.save(ICON_DIR / "icon_master.png")
    print(f"  ✓ icon_master.png ({MASTER_SIZE}x{MASTER_SIZE})")

    fg = make_adaptive_foreground(master)
    fg.save(ICON_DIR / "adaptive_foreground.png")
    print("  ✓ adaptive_foreground.png (transparent, content 60%)")

    # launcher_legacy 用透明背景（按用户要求）
    # 注意：flutter_launcher_icons 0.14.x 会用此图直接生成 mipmap-*/ic_launcher.png
    master.save(ICON_DIR / "launcher_legacy.png")
    print("  ✓ launcher_legacy.png (transparent)")

    mono = make_monochrome(fg)
    mono.save(ICON_DIR / "adaptive_monochrome.png")
    print("  ✓ adaptive_monochrome.png (alpha mask)")

    # logo2 / logo_216 / logo_512：透明背景
    master.save(ASSETS_DIR / "logo2.png")
    print("  ✓ assets/logo2.png (1024x1024)")

    master.resize((216, 216), Image.LANCZOS).save(ASSETS_DIR / "logo_216.png")
    print("  ✓ assets/logo_216.png (216x216)")

    master.resize((512, 512), Image.LANCZOS).save(ASSETS_DIR / "logo_512.png")
    print("  ✓ assets/logo_512.png (512x512)")

    print("[4/4] Generating iOS AppIcon set (composited on white)...")
    make_ios_icons(master)

    print("\n✓ Done. Next step:")
    print("  dart run flutter_launcher_icons   # regenerate Android mipmap/drawable icons")


if __name__ == "__main__":
    main()
