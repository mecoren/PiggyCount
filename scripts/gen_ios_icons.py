#!/usr/bin/env python3
"""从 launcher_legacy.png 生成 iOS 各尺寸 App Icon。

iOS 图标必须是不透明方形(无 alpha),用 adaptive_legacy.png(白底) 缩放即可。
"""

from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "icon" / "launcher_legacy.png"
IOS_DIR = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"

# iOS 图标尺寸表(文件名, 像素尺寸)
SIZES = [
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


def main():
    if not SRC.exists():
        raise SystemExit(f"Source not found: {SRC}")

    src = Image.open(SRC).convert("RGBA")
    # iOS 不支持 alpha,合成到白底
    bg = Image.new("RGBA", src.size, (255, 255, 255, 255))
    src = Image.alpha_composite(bg, src).convert("RGB")

    for name, size in SIZES:
        out = src.resize((size, size), Image.LANCZOS)
        out.save(IOS_DIR / name, "PNG")
        print(f"  {name} ({size}x{size})")

    print(f"✓ Generated {len(SIZES)} iOS icons → {IOS_DIR}")


if __name__ == "__main__":
    main()
