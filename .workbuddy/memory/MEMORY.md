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
