#!/usr/bin/env python3
"""把 SQLCipher 的 **Android** native 库取到 `android/app/src/main/jniLibs/<abi>/`。

# 为什么需要这个脚本

`sqlite3` 3.x 的 hook 在 `source: sqlcipher` 下会把 `libsqlcipher.so` 作为
**absolute 类 native 资产**交给构建系统，但实测（2026-10-05）该资产**没有**被复制进
Android 产物：APK 的 `lib/<abi>/` 里只有 `sqlite3_flutter_libs` 打的上游
`libsqlite3.so`（二进制内无 `sqlcipher` 字样），设备上也不存在任何 cipher 库。
于是 Android 上跑的是普通 SQLite，`PRAGMA key` 被静默忽略 —— "看起来加密、其实
明文"的最坏状态。

官方替代品 `sqlcipher_flutter_libs` 已 EOL（`0.7.0+eol`，作者让改用 sqlite3 3.x），
因此 Android 只能自己把库放进 `jniLibs`，再用
`hooks.user_defines.sqlite3: {source: system, name_android: sqlcipher}`
让运行时按 `libsqlcipher.so` 去找（`source: system` 支持 `name_$targetOS`，
见 `sqlite3/lib/src/hook/compile/description.dart`）。

# 校验和从哪来

取自 `sqlite3` 包自带的 `lib/src/hook/asset_hashes.dart`（release tag
`sqlite3-3.7.0`），**不手抄**：升级 sqlite3 时请同步更新这两处并重跑本脚本。

⚠️ 2026-10-06：随 sqlite3 3.5.2 → 3.7.0 升级，三个 Android 资产的 sha256 已全部
变化（旧值取自 3.5.2，留着会一直校验失败），已按 3.7.0 的 asset_hashes.dart 更新。

# 用法

    python scripts/fetch_sqlcipher_android_libs.py            # 下载 + 校验 + 落位
    python scripts/fetch_sqlcipher_android_libs.py --check    # 只校验已有文件

⚠️ 落位的 `.so` 是**第三方二进制**（SQLCipher 社区版）。是否入库/随包分发涉及许可
结论（见 `prd/sqlcipher_db_encryption/design.md` §7），本脚本只负责"取到并验真"。
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import urllib.request
from pathlib import Path

RELEASE_TAG = "sqlite3-3.7.0"
_GITHUB_URL = (
    "https://github.com/simolus3/sqlite3.dart/releases/download/"
    f"{RELEASE_TAG}/{{filename}}"
)

# (release 文件名, APK ABI 目录, sha256) —— 取自 sqlite3 包的 asset_hashes.dart
ASSETS = [
    (
        "libsqlcipher.arm64.android.so",
        "arm64-v8a",
        "cd99b7a3c78270f2925ddc936802df94eaf2d764122bd1ae1504edc18a7de24a",
    ),
    (
        "libsqlcipher.arm.android.so",
        "armeabi-v7a",
        "d576bf3c24c1c31a386c64ee3897fd8fea4c0b707834e613e4750354d06dc946",
    ),
    (
        "libsqlcipher.x64.android.so",
        "x86_64",
        "dd55e20fc8fbfaba3d141e6df5e470f476b56cb332939e37c317609f26f9aa5b",
    ),
]

JNI_LIBS = Path("android/app/src/main/jniLibs")
LIB_NAME = "libsqlcipher.so"


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(filename: str, mirror: str | None = None) -> bytes:
    """下载单个资产。

    `mirror` 是 GitHub 加速前缀（如 `https://ghfast.top/`）：实测（2026-10-06）
    `github.com/.../releases/download/...` 会 302 到 objects.githubusercontent.com，
    国内直连会超时（WinError 10060），必须借加速镜像。走镜像同样安全 —— 下文
    仍会按 sqlite3 包内的 sha256 逐字节校验。
    """
    url = (
        f"{mirror.rstrip('/')}/{_GITHUB_URL.format(filename=filename)}"
        if mirror
        else _GITHUB_URL.format(filename=filename)
    )
    print(f"  下载 {url}")
    with urllib.request.urlopen(url, timeout=300) as resp:
        return resp.read()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check", action="store_true", help="只校验已落位的文件，不下载"
    )
    parser.add_argument(
        "--mirror",
        default=None,
        help="GitHub 加速前缀（如 https://ghfast.top/）。国内直连 github.com 的 "
        "release 下载会超时，用镜像即可；内容仍按 sha256 强校验。",
    )
    args = parser.parse_args()

    failures: list[str] = []
    for filename, abi, expected in ASSETS:
        target = JNI_LIBS / abi / LIB_NAME
        if args.check:
            if not target.exists():
                failures.append(f"{target} 不存在")
                continue
            actual = sha256_of(target)
            ok = actual == expected
            print(f"  {'OK  ' if ok else 'FAIL'} {abi:12s} {actual[:16]}")
            if not ok:
                failures.append(f"{target} 校验和不匹配")
            continue

        try:
            data = fetch(filename, mirror=args.mirror)
        except Exception as e:  # noqa: BLE001 - 脚本入口，直接报清楚即可
            failures.append(f"{filename} 下载失败: {e}")
            continue

        digest = hashlib.sha256(data).hexdigest()
        if digest != expected:
            failures.append(
                f"{filename} 校验和不匹配: 期望 {expected[:16]}… 实得 {digest[:16]}…"
            )
            continue

        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        print(f"  OK   {abi:12s} {len(data) / 1048576:.2f} MB -> {target}")

    if failures:
        print("\n失败：")
        for f in failures:
            print("  -", f)
        return 1

    print("\n全部就位。接着把 pubspec.yaml 的 hooks 改成 "
          "{source: system, name_android: sqlcipher} 后重建 APK。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
