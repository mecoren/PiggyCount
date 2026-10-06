# 第三方组件声明 / Third-Party Notices

本仓库源码**原则上不包含（vendor）第三方库的源代码**：第三方依赖由 `pubspec.yaml` / `pubspec.lock` 声明，在构建时经 pub 从官方源获取，各自按其原始开源协议授权，与本项目的 [LICENSE](LICENSE)（双许可）相互独立。使用、分发或基于本项目二次开发时，请一并遵守下列组件各自的协议。

**唯一的例外**是 Android 侧的 SQLCipher native 库（见下方「随仓库分发的二进制」一节）：为规避构建期访问 GitHub 的网络失败，其预编译二进制已入库。

`packages/` 目录下的 `flutter_ai_kit*` 与 `flutter_cloud_sync*` 系列为本项目自研组件，属许可软件本体、受项目 LICENSE 约束，**不属于第三方组件**。

> 以下清单基于各包发布物中的 LICENSE 文本核验（2026-07 整理、2026-10 更新，共 48 个第三方直接依赖，**无 GPL / LGPL / AGPL 项**）。传递依赖可用 `flutter pub deps` 查看；如与上游申明不符，以上游为准。
>
> **English**: This repository does **not vendor** any third-party source code, with one exception: the prebuilt SQLCipher native library for Android (see "Vendored binaries" below), committed to avoid build-time failures when fetching from GitHub. All other dependencies are declared in `pubspec.yaml` / `pubspec.lock` and fetched by pub at build time under their own licenses, independent of this project's dual [LICENSE](LICENSE_EN). Packages under `packages/` (`flutter_ai_kit*`, `flutter_cloud_sync*`) are first-party components covered by the project LICENSE. The list below was verified against each package's published LICENSE text (as of 2026-10, 48 direct third-party dependencies, **no GPL / LGPL / AGPL**); upstream prevails in case of discrepancy.

## 直接依赖 / Direct dependencies

**Flutter SDK / flutter_localizations** — BSD-3-Clause

**MIT（19）**
archive · country_flags · csv · dio · drift · excel · file_picker · fl_chart · flutter_image_compress · flutter_list_view · flutter_riverpod · flutter_svg · gbk_codec · in_app_review · permission_handler · reorderable_grid_view · supabase_flutter · uuid · yaml

**BSD-3-Clause（24）**
collection · connectivity_plus · crypto · flutter_local_notifications · gal · home_widget · http · image_cropper · intl · jovial_svg · local_auth · open_filex · package_info_plus · path · path_provider · qr_flutter · quick_actions · record · share_plus · shared_preferences · url_launcher · visibility_detector · webview_flutter · webview_flutter_wkwebview

**Apache-2.0（4）**
app_links · decimal · image_picker · table_calendar

**BSD-2-Clause（1）**
timezone

## 随仓库分发的二进制 / Vendored binaries

### SQLCipher（Community Edition）— BSD-style（Zetetic LLC）

- **位置**：`android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libsqlcipher.so`（合计约 16.45 MB）
- **用途**：Android 侧数据库整库加密（`hooks.user_defines.sqlite3.name_android: sqlcipher` 让运行时 `dlopen` 该库）
- **来源**：`simolus3/sqlite3.dart` 的 release `sqlite3-3.7.0` 中预编译的 `libsqlcipher.*.android.so`
- **许可**：SQLCipher Community Edition 采用 BSD-style 许可（非 GPL/LGPL/AGPL；Community 版不含商业版的额外条款）。上游许可原文见 <https://www.zetetic.net/sqlcipher/license/>
- **取回方式与校验**：`python scripts/fetch_sqlcipher_android_libs.py --mirror <加速前缀>`，按 `sqlite3` 包内 `asset_hashes.dart` 的 sha256 逐字节校验（脚本内已固化 3.7.0 的校验值）
- **为什么入库而非构建期拉取**：实测 `github.com/.../releases/download/...` 会 302 到 `objects.githubusercontent.com`，国内直连超时（`WinError 10060`），构建期拉取必然失败；入库换来「clone 即可构建」。详见 `prd/sqlcipher_db_encryption/design.md` §7

> **English**: The three `libsqlcipher.so` files under `android/app/src/main/jniLibs/<abi>/` are prebuilt SQLCipher Community Edition binaries (BSD-style license, © Zetetic LLC), vendored from the `sqlite3-3.7.0` release of `simolus3/sqlite3.dart` and verified by SHA-256. They are distributed together with this project; see <https://www.zetetic.net/sqlcipher/license/> for the upstream license text.

---

如发现本清单与上游实际协议不符，欢迎提 Issue 指正。
