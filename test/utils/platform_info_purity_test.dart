/// 平台抽象纯度守门：`lib/` 与 `packages/` 中除 `lib/utils/platform_info.dart`
/// （抽象自身）外，**零裸 `Platform.isIOS / isAndroid / ...`**。
///
/// 为什么值得一个测试：`dart:io` 的 `Platform` 有引力——判平台时顺手写一个
/// `Platform.isAndroid` 比走 `PlatformInfo` 近得多，而裸判在桌面 / web / 测试
/// 环境全部失真（web 下 `Platform.isIOS` 直接抛异常，`PlatformInfo` 为此把
/// `kIsWeb` 短路前置，见 `lib/utils/platform_info.dart:38-45`）。
/// 本测试是 `contrast_token_test.dart` / `font_size_token_ratchet_test.dart`
/// 确立的「源码扫描 + CI 常驻」范式在平台抽象上的复制。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 平台抽象的实现文件自身 —— 全库唯一允许出现裸 `Platform.is*` 的地方。
const _allowedImplementation = 'lib/utils/platform_info.dart';

/// 只匹配 `Platform.is*` 判定（`Platform.version` / `operatingSystem` 等
/// 非判定用法不在契约内：`update_permissions.dart` 的 Android API 级判定
/// 走 `Platform.version`，正则抓不到，也不该抓）。
final _barePlatformIs =
    RegExp(r'\bPlatform\.(isIOS|isAndroid|isWindows|isLinux|isMacOS|isFuchsia)\b');

/// 生成物 / 构建产物不做平台判定，跳过以省扫描时间：
/// `.g.dart` / `.freezed.dart` 是 codegen；`.dart_tool/` 下是 Flutter 工具
/// 自动生成的插件注册表（`dart_plugin_registrant.dart` 天生逐平台 if-else，
/// 不属本契约管辖——它由 `flutter pub get` 重建，不进版本库）。
bool _isSkippable(String path) {
  final normalized = path.replaceAll(r'\', '/');
  return normalized.endsWith('.g.dart') ||
      normalized.endsWith('.freezed.dart') ||
      normalized.contains('/.dart_tool/') ||
      normalized.contains('/build/');
}

List<File> _dartFilesUnder(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !_isSkippable(f.path))
      .toList();
}

/// 返回违规清单（`相对路径:行号` 形式），空 = 通过。
List<String> _violationsIn(String dirPath) {
  final out = <String>[];
  for (final file in _dartFilesUnder(dirPath)) {
    final rel = file.path.replaceAll(r'\', '/');
    if (rel == _allowedImplementation) continue;
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (_barePlatformIs.hasMatch(lines[i])) {
        out.add('$rel:${i + 1}  ${lines[i].trim()}');
      }
    }
  }
  return out;
}

void main() {
  test('lib/ 无裸 Platform.is（platform_info.dart 自身除外）', () {
    final violations = _violationsIn('lib');
    expect(violations, isEmpty,
        reason: '判平台一律走 PlatformInfo（lib/utils/platform_info.dart），'
            '裸 Platform.is* 在桌面 / web / 测试环境全部失真。违规：\n${violations.join('\n')}');
  });

  test('packages/ 无裸 Platform.is', () {
    final violations = _violationsIn('packages');
    expect(violations, isEmpty,
        reason: '子包不得反向依赖 lib/，同样不该裸判平台。违规：\n${violations.join('\n')}');
  });

  test('platform_info.dart 自身仍然持有全部平台判定（防判定被搬空后测试假绿）', () {
    final source = File(_allowedImplementation).readAsStringSync();
    expect(_barePlatformIs.allMatches(source).length, greaterThanOrEqualTo(2),
        reason: '抽象自身至少应保留 iOS / Android 两个判定；'
            '若平台判定被搬去别处，先把允许清单改成本文件新址再跑');
  });
}
