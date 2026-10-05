/// Android 打包契约：**配了 `name_android: sqlcipher` 就必须带上自备库**。
///
/// 这条闸门防的是一个非常具体、后果很重的错法：只把 pubspec 的
/// `name_android: sqlcipher` 打开（或提交），却忘了 `jniLibs` 里那三个
/// `libsqlcipher.so`。此时运行时按 `libsqlcipher.so` 去找库，而包里根本没有 ——
/// 结果是**连 SQLite 都加载不了**，应用直接起不来（2026-10-05 实测过这个状态：
/// 把 `sqlite3_flutter_libs` 移除后 APK 的 `lib/<abi>/` 一个 SQLite 库都不剩）。
///
/// 反过来说：本测试在未启用该配置时**什么也不要求**（恒真），所以不会给当前
/// 构建添负担；一旦有人打开开关，它立刻变成硬门禁。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 与 `name_$targetOS` 对应（`source: system` 时的库名，见 sqlite3 包的
/// `lib/src/hook/compile/description.dart`）。
const String _nameKey = 'name_android';

/// APK 实际会打包的 ABI 目录（与 `flutter build apk` 的产物一致）。
const List<String> _abis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('启用 name_android: sqlcipher 时，三个 ABI 的自备库必须齐备且像样', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp('^\\s*$_nameKey:\\s*(\\S+)', multiLine: true).firstMatch(pubspec);

    if (match == null) {
      // 当前未启用自备库配方（Android 仍用 sqlite3_flutter_libs 打的库）。
      // 这不是"缺东西"，不该在这里报警。
      return;
    }

    expect(match.group(1), 'sqlcipher',
        reason: '$_nameKey 只会被用来指向 SQLCipher 构建；改成别的名字前请先想清楚');

    for (final abi in _abis) {
      final lib = File('android/app/src/main/jniLibs/$abi/libsqlcipher.so');
      expect(lib.existsSync(), isTrue,
          reason: '缺少 $abi 的 libsqlcipher.so：运行时要求打开 libsqlcipher.so，'
              '而包里没有的话**连 SQLite 都加载不了**（应用起不来）。'
              '跑 `python scripts/fetch_sqlcipher_android_libs.py` 补齐。');
      expect(lib.lengthSync(), greaterThan(1024 * 1024),
          reason: '$abi 的库只有 ${lib.lengthSync()} 字节，疑似占位文件或下载损坏');
    }
  });
}
