# PiggyCount 项目长期记忆

## 版本号机制（重要）
- `pubspec.yaml` 的 `version: 0.0.1` 仅是本地/开发构建占位默认值，**不是线上版本来源**。
- 线上版本（versionName / CFBundleShortVersionString）来自 **git release tag**（如 `v4.2.0`），在 CI（`.github/workflows/release.yml`）构建前由 `sed` 覆盖 `pubspec.yaml`：`version: ${CLEAN_VERSION}+${BUILD_NUMBER}`。
- `versionCode` = GitHub `run_number`（构建号），与版本数字无关。
- 发布后 pubspec 不会被写回仓库，故本地长期停留在 0.0.1，属预期行为。
- 本地共 141 个 tag，最新本地 tag 为 `3.6.0`；线上若显示 4.x 说明远程有更新 tag 且本地未 `git fetch --tags`。
