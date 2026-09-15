# PiggyCount 项目长期备忘

## 测试环境（Windows 本地）

- **sqlite3.dll**：`flutter test` 跑依赖 `NativeDatabase.memory()`（drift FFI）的测试时，
  需要 sqlite3.dll 在 PATH 上。CI 跑 ubuntu-latest（系统自带 libsqlite3），
  本地 Windows 无系统 sqlite3.dll。
  - 解决：`export PATH="/d/DevTools/sqlite3-bin:$PATH"` 后再 `flutter test`。
  - DLL 位置：`D:\DevTools\sqlite3-bin\sqlite3.dll`
  - 纯 mock 测试（如 flutter_cloud_sync 包内 cloud_sync_manager_test）不需要 sqlite3。
- Flutter：`D:\DevTools\env\flutter\bin\flutter`（3.44.3 stable）
- Pub cache：`D:\DevTools\tools\pub-cache\hosted\pub.flutter-io.cn\`

## 生产缺口修复计划（2026-08-16-production-gap-closure）

13 项缺口，计划文件：`docs/superpowers/plans/2026-08-16-production-gap-closure.md`
- 用户规则：不提交 git；中文注释解释"为什么"；恢复语义=真覆盖（镜像云端）。
- 完成：H1/H2/H3/M1/M2/M3（应用+diff 层）、P1（凭据硬失败）、P3（超时）、P4（完整性校验）、M4（UTC）。
- 待办：P5（S3 jitter）、P2（离线队列）、Task 12（全量回归 + analyze）。
  - 2026-08-17 更新：P5/P2 已完成，dart analyze 零告警。102 包测试 + 10 sync 测试全绿。

## 工具链注意事项

- **不要给 flutter_cloud_sync_s3 包 pubspec 加 `meta` 依赖**——会引发解析冲突，
  导致 `flutter pub get` 静默失败（空输出+退出1），进而 flutter_tools 快照损坏，
  所有 flutter 命令失效。改用方法名 `ForTest` 后缀约定代替 `@visibleForTesting` 注解。
- **flutter wrapper 损坏恢复**：若 flutter 命令全部静默失败但 `dart.exe --version` 正常
  （SDK 在 `D:\DevTools\env\flutter\bin\cache\dart-sdk\bin\dart.exe`），说明 flutter_tools
  快照损坏。可用 `dart.exe analyze`/`dart.exe test`（纯 Dart 包）绕过；或 `flutter clean` 重建。
- `dart test` 不兼容 `flutter_test` 包（需 Flutter 测试框架），仅 `flutter test` 能跑含
  TestWidgetsFlutterBinding 的测试。纯 mock 包测试理论可 dart test，但 flutter_test 导入仍需 flutter 框架。

## 模拟器双端同步实测工具链（2026-09-13 固化）

包名 `com.wait.piggycount.dev.debug`；本地库 `app_flutter/piggycount.sqlite`；附件 `app_flutter/attachments/`。

- **拉/推二进制必须用 `adb exec-out` / 原生路径**：
  - `adb shell cat <file>` 会把 `\n` 转成 `\r\n`，拉 sqlite 必得 `database disk image is malformed`。
    改用 `adb -s 127.0.0.1:$P exec-out run-as <pkg> cat <path> > local.sqlite`（字节数完全一致）。
  - `adb push` 的路径必须是 Windows 原生形式（`D:/...`）。传 MSYS 的 `/d/...` 时 adb 报
    `cannot stat`，这正是历史报告里"adb push 大文件静默失败"的真实根因——**不是大小限制**。
- **`adb shell` 输出行尾带 `\r`**：`for f in $(adb shell ls dir)` 会把 `\r` 拼进路径，
  导致 `cp: bad 'xxx\r'`。循环前必须 `| tr -d '\r'`。
- **`run-as ... sh -c "rm -rf path/*"` 的 glob 不展开**（报 `rm: Needs 1 argument`）；
  直接 `rm -rf <目录本身>`，应用会自动重建。
- **取一致快照**：设备端自带 `/system/bin/sqlite3`。`am force-stop` → 
  `run-as <pkg> sqlite3 <db> "VACUUM INTO '<dir>/snap.sqlite'"` → `exec-out` 拉取。
- **清库保云配置**：云配置 = `shared_prefs/FlutterSharedPreferences.xml` 的 `cloud_active_type`
  + `shared_prefs/FlutterSecureStorage.xml` 的 `cloud_s3_cfg`/`cloud_webdav_cfg`（加密，
  实现在 `packages/flutter_cloud_sync/lib/src/config/cloud_service_store.dart`）。
  清库只删 `piggycount.sqlite*` + `attachments/`，**绝不碰 `shared_prefs/`**（含库加密主密钥
  `FlutterSecureKeyStorage.xml`）。
- **切换云后端**走应用 UI（我的 → 云服务 → 卡片 → 确定），不要手工改 prefs；
  切换不动加密存储里的凭据（S3 与 WebDAV 两套并存）。
- **`slotKey = 账本 syncId`**（远端路径 `ledger_<slotKey>.json`，
  `lib/cloud/transactions_sync_manager.dart:703-718`）。「全量上传」**不清理云端独有账本**，
  故桶内历史残留槽位会与新数据同名并存。治理：把新账本的 `sync_id`
  （连同 `local_changes.entity_sync_id`、`ledger_members.ledger_sync_id`）对齐到旧槽位 syncId
  → 上传即就地覆盖，B 端云端发现数即等于本地账本数。
- **测试后收尾**：恢复 `cloud_active_type` 后，务必把两端本地库还原为与目标云端一致的快照，
  否则 `auto_sync=true` 会在下次启动把另一轮的数据推成新增槽位（污染云端）。
- **注入脚本**：`scripts/inject_16384_sync_test.py`（附件段依赖 **Pillow**，装在隔离 venv
  `~/.workbuddy/binaries/python/envs/default`）。前置：库必须为空（`tx=0 且 ledgers<=1`）。
- **WebDAV 测试服务器**：`scripts/webdav_test/webdav_server.py` 默认绑定 `127.0.0.1`
  （2026-09-13 改，原先硬编码 `0.0.0.0`）且**不强制鉴权**（规避 webdav_client 的
  401+keep-alive 竞态）。需局域网访问时手动改 HOST。`start_webdav_local.py` 启动器
  保留兼容：脚本已是 `127.0.0.1` 则直接 exec，被改回 `0.0.0.0` 则内存改写。
  凭据 `pctest/piggy123`，remotePath `/piggycount/`。
- **E2EE 为可选**：未配置时 WebDAV 落盘为明文信封
  `{"fmt":"pc-wdav-env-v1","b64":false,"data":"<快照JSON>"}`；开启后才是密文
  （见 `docs/encryption-security-boundary.md`）。做"一致性"结论时须声明加密配置。

## E2EE 双后端回归（2026-09-15 固化）

- **S3 + E2EE 的元数据信封键必须是连字符 `pc-encmeta`**。原 `_encmeta` 会变成请求头
  `x-amz-meta-_encmeta`，OSS 网关默认丢弃下划线头名（`underscores_in_headers off`），
  而 S3 签名器已把该头计入 SignedHeaders → `HTTP 403 Not all the signed headers are found
  in the request`（伴随账本 1–3 `PutObject timed out after ~100s` 的网络抖动）。
  修复点 `lib/data/encryption/encrypted_cloud_storage.dart`，读取端保留
  `legacyEncMetaKey` 兼容旧密文（**不设清理期限**：快照同步没有"全体升级完成"信号）。
- **上传超时不是配置问题**：`transferTimeoutFor()` = 30s 基线 + 30s/MB，上限 5min；
  E2EE 信封约 2.3MB → 99~100s 是公式结果。重试有 P5 指数退避 + jitter（1s/2s/4s 的 50%~100%）。
- **发现弹窗已带后端标识**：`lib/cloud/backend_identity.dart` 生成
  `类型 · host · 桶/远端路径`（复用 `obfuscatedUrl()`，不含凭据），
  `StartupSyncChecker.newLedgersDialogMessage(..., backend:)` 前置一行；
  两个入口：启动检查 `WidgetRefDeps.showNewLedgersConfirmDialog`、云同步页「同步云端」。
  触发验证的低成本办法：往 `scripts/webdav_test/data/piggycount/` 复制一份
  `ledger_<已存在syncId>.json` 成新文件名（合法 E2EE 信封可被识别），验证完删除。
- **对比脚本口径**：`scripts/live_db/compare_sync_final.py` 把 ledgers 拆「同步字段（严格）」
  与「设备本地字段 `is_shared`/`member_count`（`[OK*]` 预期差异，不计入 issues）」；
  **退出码 0 = 无非预期差异、2 = 存在不一致**。该脚本位于被 gitignore 的
  `scripts/live_db/`，改动需 `git add -f` 才能纳管。
- **WebDAV 测试服务器落盘目录是 `scripts/webdav_test/data/piggycount/`**（remotePath 决定），
  且该目录**被 git 跟踪**；`rm -rf data` 清环境会在 git 里留下删除记录。
- 模拟器被关闭时 `adb devices` 为空、`adb connect` 报 10061；先查
  MuMuPlayer/dnplayer/qemu 进程是否存在，进程没了就只能等重开（本机 Bash 工具不可用，
  全流程用 PowerShell：截图必须 `shell screencap` + `adb pull`，Python 中文输出先设
  `[Console]::OutputEncoding = UTF8`）。
