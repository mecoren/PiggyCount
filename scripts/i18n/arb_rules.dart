// ignore_for_file: avoid_print
/// ARB 一致性检查的共享规则（`check_status.dart` 与
/// `check_arb_consistency.dart` 共用，避免两套「刻意留空」清单漂移）。
library;

import 'dart:convert';
import 'dart:io';

/// 模板语言（与 `l10n.yaml` 的 `template-arb-file: app_en.arb` 对齐）。
const String templateLanguage = 'en';

/// 刻意留空的翻译键（**不是**漏翻译）。
///
/// 全是「单位后缀」：中文需要（「9月」「3 笔」「1,234 元」），英/韩语境的表达
/// 里不需要 —— 拼接后空串正是想要的效果。新增刻意空值必须在此登记。
const Set<String> intentionalEmptyKeys = <String>{
  'widgetMonthSuffix',
  'sharePosterUnitCount',
  'userProfilePosterCountUnit',
  'userProfilePosterLedgerUnit',
};

/// 语言显示名。未登记的语言回落到语言码本身。
const Map<String, String> languageDisplayNames = <String, String>{
  'zh': '简体中文',
  'en': 'English',
  'zh_TW': '繁體中文',
  'ko': '한국어',
};

String languageDisplayName(String lang) => languageDisplayNames[lang] ?? lang;

/// 从 `lib/l10n` 动态发现语言包（`app_<lang>.arb`）。
///
/// `zh` 固定排首位作为中文基准，其余按字母序（输出稳定，便于逐次比对）。
List<String> discoverLanguages(Directory l10nDir) {
  final langs = <String>[];
  if (l10nDir.existsSync()) {
    for (final entity in l10nDir.listSync()) {
      final m = RegExp(r'^app_(.+)\.arb$')
          .firstMatch(entity.uri.pathSegments.last);
      if (m != null) langs.add(m.group(1)!);
    }
  }
  langs.sort();
  if (langs.remove('zh')) langs.insert(0, 'zh');
  return langs;
}

/// 读取并解析 ARB；解析失败抛 [FormatException]（调用方决定是否计入错误）。
Map<String, dynamic> loadArb(File file) {
  final content = file.readAsStringSync();
  final decoded = json.decode(content);
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('${file.path} 顶层不是 JSON 对象');
  }
  return decoded;
}

/// 非元数据键（忽略 `@key` 元数据）。
Set<String> messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

/// 模板 key 声明的占位符（来自 `@key.placeholders`）。
Set<String> declaredPlaceholders(Map<String, dynamic> arb, String key) {
  final meta = arb['@$key'];
  if (meta is! Map<String, dynamic>) return const <String>{};
  final placeholders = meta['placeholders'];
  if (placeholders is! Map<String, dynamic>) return const <String>{};
  return placeholders.keys.toSet();
}

/// 字符串里是否真的引用了占位符 [name]（`{name}` / `{name, plural, ...}`）。
///
/// 只认小写开头的名字，避免把 ICU 分支文本里的 `{He}` / `{They}` 误当成
/// 占位符（Flutter 占位符惯例是 lowerCamelCase）。
bool hasPlaceholder(String value, String name) {
  // 大写开头的名字视为 ICU 分支文本（`{He}` / `{They}`），不是占位符。
  if (name.isEmpty || !RegExp(r'^[a-z]').hasMatch(name)) return false;
  final re = RegExp(r'\{' + RegExp.escape(name) + r'(?=[\s,}])');
  return re.hasMatch(value);
}
