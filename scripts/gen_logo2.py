#!/usr/bin/env python3
"""从 launcher_legacy.png 生成 logo2.png(用于海报/splash 的小猪 logo)。

logo2.png 历史上是 1024x1024 不透明 logo,与 launcher legacy 同源。
"""

from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "icon" / "launcher_legacy.png"
DST = ROOT / "assets" / "logo2.png"


def main():
    if not SRC.exists():
        raise SystemExit(f"Source not found: {SRC}")
    src = Image.open(SRC).convert("RGBA")
    # 合成到不透明白底(海报上的 logo 不需要透明)
    bg = Image.new("RGBA", src.size, (255, 255, 255, 255))
    out = Image.alpha_composite(bg, src).convert("RGB")
    # 输出 1024x1024
    if out.size != (1024, 1024):
        out = out.resize((1024, 1024), Image.LANCZOS)
    out.save(DST, "PNG")
    print(f"✓ logo2.png → {DST} ({out.size[0]}x{out.size[1]})")


if __name__ == "__main__":
    main()
