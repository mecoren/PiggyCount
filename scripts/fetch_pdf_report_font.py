#!/usr/bin/env python3
"""取「PDF 报表」用的中文字体（Noto Sans SC）并**子集化**到 `assets/fonts/`。

# 为什么需要这个脚本

`pdf` 包自己不会画字：中文必须**内嵌字体文件**（它只支持 glyf 轮廓的
TTF/OTF，不支持 TTC 字体集合、也不支持 woff2 —— 所以不能直接读
Android 的 `/system/fonts/NotoSansCJK-Regular.ttc`，iOS 侧更没有可读的系统
字体路径）。而「Noto Sans SC」完整静态字重单个约 **10.5MB**（30,796 字形），
两个字重 21MB 全塞进 APK 与项目"用系统字体省体积"的既有取舍冲突。

所以本脚本只入库存**子集**：常用字（GB2312 全集）+ 项目自己的文案用字 +
标点/货币/数学符号。子集后单字重 ~1.5MB，两个字重 ~3MB；`pdf` 包在
生成时还会**再按实际用到的字**二次子集，导出的 PDF 因此只有几百 KB。

# 字体来源与许可

- 字体：Noto Sans SC（SIL Open Font License 1.1，见同目录 `OFL.txt`）。
- 下载：Google Fonts CSS2 接口。**故意带老 UA**（`Mozilla/4.0`）——新 UA
  只会拿到 woff2（多段 unicode-range 分片），pdf 包读不了；老 UA 返回
  单个 `format('truetype')` 的完整 TTF。
- [WARN] gstatic 的 URL 带版本号（`/v41/...`），**会随上游发版失效**：脚本每次
  都重新查 CSS2 拿当下 URL，不硬编码哈希路径。

# 用法

    python scripts/fetch_pdf_report_font.py            # 下载 + 子集化 + 落 assets/fonts/
    python scripts/fetch_pdf_report_font.py --check    # 只校验已有产物（覆盖 + 体积）
    python scripts/fetch_pdf_report_font.py --keep-full  # 不子集（临时排查生僻字缺字用）

依赖：`python -m pip install fonttools`（仅**生成期**需要；产物已入库，
构建 App / CI 都不需要跑本脚本）。

# 改了文案之后

子集覆盖「所有 arb 文案里的字」。**若新文案用了 GB2312 之外的字**（例如
生僻人名、emoji），`--check` 会报缺字，请重跑本脚本（脚本会重新扫 arb 并
扩子集）。同时 `test/services/export/pdf_report_font_test.dart` 会在单元测试
里再守一道：逐字断言字体资产覆盖全部 arb 文案。

[WARN] 用户**自行输入**的分类名 / 备注不受子集保护：落在子集外的字在 PDF 里会被
pdf 包渲染成缺字占位框（不抛异常，见 `pdf` 的 `text.dart` `_addPlaceholder`）。
需要根治时按 `--keep-full` 换完整字重（APK +21MB），或改用更激进的做法
（中文报表走图片），不要偷偷放宽子集就了事。

[WARN] **朝鲜语（ko）不在覆盖范围内**：Noto Sans SC 本身不含谚文（U+AC00-D7A3，
0/11172），`app_ko.arb` 里的 655 个韩文字因此渲染成占位框。原因：韩文必须换
`Noto Sans KR` 取子集（多一份资产 ~0.3MB/字重），而项目当前没有 ko 用户；
真要支持时，在这里加一条 `Noto Sans KR` 的子集通道并把产物挂到 PDF 主题的
`fontFallback` 上即可（脚本结构已按「多字体」写）。`--check` 会把这类
「源字体本身就没有」的码位归为 [WARN] 而不是 [FAIL]。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "assets" / "fonts"
LICENSE_FILE = OUT_DIR / "OFL.txt"

# 原始字体只做缓存，不入库（.tmp/ 已在 .gitignore 里）
CACHE_DIR = ROOT / ".tmp" / "pdf-report-font"

CSS_URL = "https://fonts.googleapis.com/css2?family=Noto+Sans+SC:wght@{weight}"
# 老 UA：拿单文件 TTF 而不是 woff2 分片
UA = "Mozilla/4.0 (compatible; PiggyCount font fetch)"
OFL_URL = "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/OFL.txt"

# weight → 产物文件名里的字重名（pdf 侧按这两个文件建 theme 的 normal/bold）
WEIGHTS: dict[int, str] = {400: "Regular", 700: "Bold"}


def asset_name(weight: int, *, subset: bool = True) -> str:
    suffix = "-subset" if subset else ""
    return f"NotoSansSC-{WEIGHTS[weight]}{suffix}.ttf"


# 除 CJK 汉字外的必留码位区间（拉丁 / 标点 / 货币 / 数学 / 全角 / 假名…）。
# CJK 汉字本身由 GB2312 枚举补上（见 gb2312_codepoints），不整体保留
# U+4E00-U+9FFF —— 那样等于没子集。
KEEP_RANGES: tuple[tuple[int, int], ...] = (
    (0x0020, 0x007E),  # Basic Latin
    (0x00A0, 0x00FF),  # Latin-1 Supplement
    (0x0100, 0x017F),  # Latin Extended-A
    (0x0180, 0x024F),  # Latin Extended-B
    (0x2E80, 0x2EFF),  # CJK Radicals（部首，罕用但便宜）
    (0x2000, 0x206F),  # General Punctuation（— – ‘ ’ “ ” …）
    (0x2070, 0x209F),  # 上标 / 下标
    (0x20A0, 0x20BF),  # 货币符号（₩ ₽ …）
    (0x2100, 0x214F),  # Letterlike（℃ №）
    (0x2150, 0x218F),  # 数字形式（⅓ ⅔）
    (0x2190, 0x21FF),  # 箭头
    (0x2200, 0x22FF),  # 数学运算符（≠ ≤ ≥ ≈ ± × ÷ ∑）
    (0x2460, 0x24FF),  # 带圈数字 ①②③
    (0x25A0, 0x25FF),  # 几何图形（● ■ ▲）
    (0x2600, 0x26FF),  # 杂项符号（★ ☆ ♡）
    (0x2700, 0x27BF),  # Dingbats（✓ ✗）
    (0x3000, 0x303F),  # CJK 标点（。、「」〈〉）
    (0x3040, 0x30FF),  # 假名（日文商户名偶见）
    (0xFF01, 0xFF60),  # 全角形式（ＡＢ １２３ ￥）
    (0xFFE0, 0xFFE6),  # 全角符号（￠ ￡ ￥ ￦）
)


def gb2312_codepoints() -> set[int]:
    """GB2312 全部可编码字符（6763 汉字 + 682 符号）。

    不引第三方字表：直接枚举双字节区位码再解码，等价于「常用汉字表」。
    """
    out: set[int] = set()
    for hi in range(0xA1, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                ch = bytes((hi, lo)).decode("gb2312")
            except UnicodeDecodeError:
                continue
            out.add(ord(ch))
    return out


def source_text_codepoints() -> set[int]:
    """项目自身文案 / 资源里的全部字符（arb + Dart 源码）。

    这样「文案里出现过的字」一定在子集里，不必等 `--check` 才发现缺字。
    """
    out: set[int] = set()
    patterns = [
        (ROOT / "lib" / "l10n", "*.arb"),
        (ROOT / "lib", "*.dart"),
    ]
    for base, glob in patterns:
        if not base.is_dir():
            continue
        for path in sorted(base.rglob(glob)):
            text = path.read_text(encoding="utf-8", errors="replace")
            out.update(ord(ch) for ch in text)
    return out


def requested_codepoints() -> set[int]:
    """希望进子集的全部码位（不含「源字体有没有」这一步）。"""
    out: set[int] = set()
    for lo, hi in KEEP_RANGES:
        out.update(range(lo, hi + 1))
    out |= gb2312_codepoints()
    out |= source_text_codepoints()
    # 控制字符 / 代理区不参与子集（写进 cmap 没意义）
    return {c for c in out if c >= 0x20 and c != 0x7F and not (0xD800 <= c <= 0xDFFF)}


def font_codepoints(path: Path) -> set[int]:
    from fontTools.ttLib import TTFont  # noqa: PLC0415

    font = TTFont(str(path))
    try:
        return set(font.getBestCmap())
    finally:
        font.close()


def fetch(url: str, *, timeout: int = 120) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (固定白名单域名)
        return resp.read()


def resolve_ttf_url(weight: int) -> str:
    """查 CSS2 取当下有效的 TTF 直链（gstatic 路径带版本号，不能硬编码）。"""
    css = fetch(CSS_URL.format(weight=weight)).decode("utf-8")
    urls = re.findall(r"url\((https://[^)]+\.ttf)\)", css)
    ttf = [u for u in urls if "format('truetype')" in css or True]
    if not ttf:
        raise RuntimeError(f"CSS2 未返回 TTF 直链（weight={weight}）：{css[:200]}")
    # 同一响应里若有多个，取第一个（老 UA 下只有一个）
    return ttf[0]


def cached_original(weight: int) -> Path:
    path = CACHE_DIR / f"NotoSansSC-{WEIGHTS[weight]}-full.ttf"
    if not path.exists():
        url = resolve_ttf_url(weight)
        print(f"  ↓ {url}")
        data = fetch(url, timeout=600)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(f"    原始字体 {len(data) / 1e6:.2f} MB → {path.relative_to(ROOT)}")
    return path


def subset_font(src: Path, dst: Path, codepoints: set[int]) -> None:
    try:
        from fontTools import subset  # noqa: PLC0415 (仅生成期依赖)
    except ImportError as exc:  # pragma: no cover
        raise SystemExit(
            "缺少 fonttools：python -m pip install fonttools"
        ) from exc

    opts = subset.Options()
    opts.hinting = False  # 去掉 hinting 指令（CJK 字体里占地不小）
    opts.glyph_names = False  # post 表降到 3.0
    opts.legacy_kern = False
    opts.notdef_outline = True
    opts.recalc_bounds = False  # 保留原轮廓包围盒，pdf 的 glyf 解析直接用
    opts.name_IDs = ["*"]
    opts.name_legacy = True
    opts.name_languages = ["*"]
    # pdf 包只按 cmap 做码位→字形映射，OpenType 排版表（GSUB/GPOS…）没有用武之地
    opts.drop_tables += [
        "GSUB",
        "GPOS",
        "GDEF",
        "BASE",
        "STAT",
        "vhea",
        "vmtx",
        "gasp",
        "DSIG",
        "meta",
    ]

    font = subset.load_font(str(src), opts)
    try:
        subsetter = subset.Subsetter(options=opts)
        subsetter.populate(unicodes=codepoints)
        subsetter.subset(font)
        dst.parent.mkdir(parents=True, exist_ok=True)
        subset.save_font(font, str(dst), opts)
    finally:
        font.close()


def coverage_gap(path: Path, codepoints: Iterable[int]) -> list[int]:
    """返回字体 cmap 未覆盖的码位（空列表 = 全覆盖）。"""
    from fontTools.ttLib import TTFont  # noqa: PLC0415

    font = TTFont(str(path))
    try:
        cmap = font.getBestCmap()
        return [c for c in sorted(codepoints) if c not in cmap]
    finally:
        font.close()


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_license() -> None:
    """OFL 1.1 要求随字体分发许可原文。"""
    if LICENSE_FILE.exists():
        return
    try:
        LICENSE_FILE.parent.mkdir(parents=True, exist_ok=True)
        LICENSE_FILE.write_bytes(fetch(OFL_URL))
        print(f"  ↓ 许可原文 → {LICENSE_FILE.relative_to(ROOT)}")
    except (urllib.error.URLError, TimeoutError) as exc:  # pragma: no cover
        print(f"[WARN] 许可原文下载失败（{exc}）：请手工放置 {LICENSE_FILE}", file=sys.stderr)


def _format_gap(codepoints: Iterable[int]) -> str:
    """缺字样本一律写成 `U+xxxx`：Windows 控制台默认 GBK，直接 print 生僻字会
    抛 UnicodeEncodeError（脚本因此在中途崩掉过）。"""
    sample = list(codepoints)[:40]
    text = " ".join(f"U+{c:04X}" for c in sample)
    return f"{text} 等" if len(sample) == 40 else text


def _reconfigure_stdout() -> None:
    """控制台编码兜底：任何无法编码的字符降级成 '?'，不要让脚本崩在 print 上。"""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:  # pragma: no cover - 老 Python / 非文本流
            continue
        try:
            reconfigure(errors="replace")
        except (ValueError, OSError):  # pragma: no cover
            pass


def _load_sources_meta() -> dict[str, object]:
    path = OUT_DIR / "SOURCES.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text("utf-8"))


def run_check(weights: Iterable[int]) -> int:
    """离线校验：不重新下载源字体，用 SOURCES.json 里记的「源字体缺口数量」当基线。"""
    requested = requested_codepoints()
    meta = _load_sources_meta()
    files = meta.get("files") or {}
    print(f"请求码位（GB2312 + 标点符号 + 项目文案）：{len(requested)}")
    bad = 0
    for weight in weights:
        path = OUT_DIR / asset_name(weight)
        if not path.exists():
            print(f"[FAIL] 缺文件：{path.relative_to(ROOT)}")
            bad += 1
            continue
        entry = files.get(path.name) if isinstance(files, dict) else None
        if not isinstance(entry, dict):
            print(f"[WARN] {path.name}：SOURCES.json 里没有它的记录，无法判定基线")
            bad += 1
            continue
        cmap = font_codepoints(path)
        missing = sorted(c for c in requested if c not in cmap)
        expected_gap = int(entry.get("source_gap_count") or 0)
        size_mb = path.stat().st_size / 1e6
        if len(missing) > expected_gap:
            print(
                f"[FAIL] {path.name}：缺 {len(missing)} 个码位（源字体本身只缺 {expected_gap}），"
                f"例如 {_format_gap(missing)}"
            )
            bad += 1
            continue
        print(f"[OK] {path.name}：{size_mb:.2f} MB，覆盖 {len(requested) - len(missing)}/{len(requested)}")
        if missing:
            print(f"   [WARN] 子集外（源字体不含）：{_format_gap(missing)}")
    if not LICENSE_FILE.exists():
        print("[FAIL] 缺 OFL.txt（许可原文）")
        bad += 1
    return 1 if bad else 0


def main() -> int:
    _reconfigure_stdout()
    parser = argparse.ArgumentParser(description="取 PDF 报表中文字体并子集化")
    parser.add_argument("--check", action="store_true", help="只校验已有产物")
    parser.add_argument(
        "--keep-full", action="store_true", help="不子集化（完整字重，临时排查用）"
    )
    parser.add_argument(
        "--weights",
        default=",".join(str(w) for w in WEIGHTS),
        help="要处理的字重，逗号分隔（当前支持 400,700）",
    )
    args = parser.parse_args()

    try:
        weights = [int(w) for w in args.weights.split(",") if w.strip()]
    except ValueError:
        print("[FAIL] --weights 只接受逗号分隔的数字，如 400,700", file=sys.stderr)
        return 2
    unknown = [w for w in weights if w not in WEIGHTS]
    if unknown:
        print(f"[FAIL] 未收录的字重：{unknown}（可选 {sorted(WEIGHTS)}）", file=sys.stderr)
        return 2

    if args.check:
        return run_check(weights)

    if args.keep_full:
        print("[WARN] --keep-full：产物为完整字重（单字重 ~10.5MB），不要提交到仓库！")

    requested = requested_codepoints()
    print(f"请求子集：{len(requested)} 个码位")

    # --check 的基线：源字体能力（数量 + 样本）——保留上一次的记录，避免
    # 只跑 --weights 400 时把 700 的记录抹掉。
    previous = _load_sources_meta()
    sources: dict[str, dict[str, object]] = dict(previous.get("files") or {})

    for weight in weights:
        print(f"[{weight}] {WEIGHTS[weight]}")
        src = cached_original(weight)
        source_cmap = font_codepoints(src)
        must = requested & source_cmap
        source_gap = sorted(requested - source_cmap)
        print(f"  源字体覆盖 {len(must)}/{len(requested)}；缺 {len(source_gap)}（源字体本身没有）")
        dst = OUT_DIR / asset_name(weight, subset=not args.keep_full)
        if args.keep_full:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(src.read_bytes())
        else:
            subset_font(src, dst, must)
        size_mb = dst.stat().st_size / 1e6
        print(f"  → {dst.relative_to(ROOT)}  {size_mb:.2f} MB")
        lost = [c for c in sorted(must) if c not in font_codepoints(dst)]
        if lost:
            print(f"[FAIL] 子集缺 {len(lost)} 个本应保留的码位：{_format_gap(lost)}", file=sys.stderr)
            return 1
        sources[dst.name] = {
            "upstream": "Google Fonts / Noto Sans SC",
            "weight": weight,
            "license": "SIL Open Font License 1.1（见 OFL.txt）",
            "subset": not args.keep_full,
            "codepoints": len(must),
            "bytes": dst.stat().st_size,
            "sha256": sha256_of(dst),
            "source_gap_count": len(source_gap),
            "source_gap_sample": [chr(c) for c in source_gap[:64]],
        }

    ensure_license()
    (OUT_DIR / "SOURCES.json").write_text(
        json.dumps(
            {
                "generator": "scripts/fetch_pdf_report_font.py",
                "css": CSS_URL,
                "ranges": [[lo, hi] for lo, hi in KEEP_RANGES],
                "files": sources,
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print("[OK] 完成。改文案后重跑本脚本；`--check` 可离线校验覆盖。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
