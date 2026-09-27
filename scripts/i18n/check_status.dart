#!/usr/bin/env dart
// ignore_for_file: avoid_print
// 命令行工具：print 即本程序的输出方式（终端报表），非库代码。

/// PiggyCount 国际化翻译状态检查工具
///
/// 功能：
/// 1. 检查各语言翻译文件的完整性和状态
/// 2. 检查各语言文件中多余的 key
/// 3. 检测未使用的翻译 key
/// 3.1 检测「疑似死键」—— 只有同名 Dart 标识符命中、拿不出 l10n 访问器
///     证据的 key（旧口径把它们算成已使用，死键因此长期隐身）
/// 4. 提供清理选项
///
/// 使用方法：
/// dart scripts/i18n/check_status.dart
library;

import 'dart:io';
import 'dart:convert';

/// 刻意留空的翻译键（**不是**漏翻译）。
///
/// 全是「单位后缀」：中文需要（「9月」「3 笔」「1,234 元」），英/韩语境的表达
/// 里不需要 —— 拼接后空串正是想要的效果（`3.2 per day` 这类成对单位另有
/// `userProfilePosterDailyUnit` 承担）。
///
/// 登记在此，检查工具就不会把它们当漏翻译反复告警；真有漏翻时才不会被这几条
/// 固定噪音淹没。**新增刻意空值必须在此登记**，否则工具会（正确地）继续告警。
const intentionalEmptyKeys = <String>{
  'widgetMonthSuffix',
  'sharePosterUnitCount',
  'userProfilePosterCountUnit',
  'userProfilePosterLedgerUnit',
};

/// 语言显示名。未登记的语言回落到语言码本身 —— 新增语言包时本工具仍能正常
/// 报告（只是名字显示为码），不会因漏配名字而打印 `null`。
const _languageDisplayNames = <String, String>{
  'zh': '简体中文',
  'en': 'English',
  'zh_TW': '繁體中文',
  'ko': '한국어',
};

String _displayName(String lang) => _languageDisplayNames[lang] ?? lang;

/// 从 `lib/l10n` 动态发现语言包（`app_<lang>.arb`）。
///
/// 此前语言列表在几处写死为 `['zh','en','zh_TW']`，加语言必然漏配 —— `ko`
/// 就长期没被本工具检查过。改为文件名驱动后，新增 `app_xx.arb` 即刻纳入；
/// `zh` 固定排首位作为基准，其余按字母序（输出稳定，便于逐次比对）。
List<String> discoverLanguages(Directory l10nDir) {
  final langs = <String>[];
  if (l10nDir.existsSync()) {
    for (final entity in l10nDir.listSync()) {
      final m = RegExp(r'^app_(.+)\.arb$').firstMatch(entity.uri.pathSegments.last);
      if (m != null) langs.add(m.group(1)!);
    }
  }
  langs.sort();
  if (langs.remove('zh')) langs.insert(0, 'zh');
  return langs;
}

void main() async {
  print('');
  print('=' * 70);
  print('  PiggyCount 国际化翻译状态检查');
  print('=' * 70);
  print('');

  // ========== 第一部分：检查翻译完整性 ==========
  await checkTranslationCompleteness();

  print('');
  print('─' * 70);
  print('');

  // ========== 第二部分：检查各语言多余的 keys ==========
  final extraKeysMap = await checkExtraKeys();

  if (extraKeysMap.isNotEmpty) {
    print('');
    print('─' * 70);
    print('');

    // 询问是否清理多余的 keys
    print('⚠️  是否要清理这些多余的 keys？(y/N): ');
    final confirm = stdin.readLineSync()?.toLowerCase();

    if (confirm == 'y' || confirm == 'yes') {
      await cleanExtraKeys(extraKeysMap);
      print('');
      print('─' * 70);
      print('');
    } else {
      print('❌ 已取消清理多余 keys 的操作');
      print('');
      print('─' * 70);
      print('');
    }
  }

  // ========== 第三部分：检查未使用的 keys ==========
  final unusedKeys = await checkUnusedKeys();

  if (unusedKeys.isNotEmpty) {
    print('');
    print('─' * 70);
    print('');

    // 询问是否清理未使用的 keys
    print('⚠️  是否要清理这些未使用的 keys？(y/N): ');
    final confirm = stdin.readLineSync()?.toLowerCase();

    if (confirm == 'y' || confirm == 'yes') {
      await cleanUnusedKeys(unusedKeys);
    } else {
      print('❌ 已取消清理未使用 keys 的操作');
    }
  }

  print('');
  print('=' * 70);
  print('');
}

/// 检查翻译完整性
Future<void> checkTranslationCompleteness() async {
  final l10nDir = Directory('lib/l10n');
  // 动态发现（写死列表会让新增语言漏检，ko 就曾被漏掉）
  final languages = discoverLanguages(l10nDir);

  print('📊 第一步：检查翻译文件完整性');
  print('');

  // 存储每个语言的键信息
  final Map<String, int> keyCount = {};
  final Map<String, Set<String>> allKeys = {};

  // 读取所有语言文件
  for (final lang in languages) {
    final file = File('${l10nDir.path}/app_$lang.arb');

    if (!file.existsSync()) {
      print('⚠️  文件不存在: app_$lang.arb');
      keyCount[lang] = 0;
      allKeys[lang] = {};
      continue;
    }

    try {
      final content = await file.readAsString();
      final Map<String, dynamic> data = json.decode(content);
      final keys = data.keys.where((key) => !key.startsWith('@')).toSet();

      keyCount[lang] = keys.length;
      allKeys[lang] = keys;
    } catch (e) {
      print('❌ 解析失败: app_$lang.arb - $e');
      keyCount[lang] = 0;
      allKeys[lang] = {};
    }
  }

  // 以中文为基准
  final zhKeys = allKeys['zh'] ?? {};
  final zhCount = zhKeys.length;

  // 打印统计表格
  print('语言代码 | 文件名称        | 键数量   | 完成度   | 状态');
  print('-' * 70);

  for (final lang in languages) {
    final count = keyCount[lang] ?? 0;
    final percentage =
        zhCount > 0 ? (count / zhCount * 100).toStringAsFixed(1) : '0.0';

    String status;
    if (count == 0) {
      status = '❌ 缺失';
    } else if (count >= zhCount) {
      status = '✅ 完整';
    } else if (count >= zhCount * 0.9) {
      status = '⚠️  接近完成';
    } else {
      status = '🔴 不完整';
    }

    final langCode = lang.padRight(8);
    final fileName = 'app_$lang.arb'.padRight(15);
    final countStr = count.toString().padLeft(7);
    final percentStr = '$percentage%'.padLeft(8);

    print('$langCode | $fileName | $countStr | $percentStr | $status');
  }

  print('-' * 70);
  print('');

  // 详细差异分析
  print('📋 详细分析:');
  print('');

  bool hasIssues = false;

  for (final lang in languages) {
    if (lang == 'zh') continue; // 跳过基准语言

    final langKeys = allKeys[lang] ?? {};
    final missing = zhKeys.difference(langKeys);

    if (missing.isEmpty) {
      print('✅ $lang (${_displayName(lang)}): 完全匹配中文版本');
    } else {
      hasIssues = true;
      print('🔴 $lang (${_displayName(lang)}): 缺少 ${missing.length} 个键');
      if (missing.length <= 10) {
        for (final key in missing.take(10)) {
          print('   - $key');
        }
      }
    }
    print('');
  }

  // 检查空值
  print('🔍 检查空值翻译:');
  print('');

  bool hasEmptyValues = false;
  for (final lang in languages) {
    final file = File('${l10nDir.path}/app_$lang.arb');
    if (!file.existsSync()) continue;

    final content = await file.readAsString();
    final data = json.decode(content) as Map<String, dynamic>;
    final empty = <String>[];

    for (final entry in data.entries) {
      if (!entry.key.startsWith('@')) {
        final value = entry.value?.toString() ?? '';
        if (value.trim().isEmpty) {
          empty.add(entry.key);
        }
      }
    }

    // 刻意留空的单位后缀与"疑似漏翻译"分开：只有后者值得告警。
    final intentional =
        empty.where(intentionalEmptyKeys.contains).toList()..sort();
    final unexpected =
        empty.where((k) => !intentionalEmptyKeys.contains(k)).toList();

    if (unexpected.isNotEmpty) {
      hasEmptyValues = true;
      print('⚠️  ${_displayName(lang)} 有 ${unexpected.length} 个空值翻译');
      for (final key in unexpected.take(5)) {
        print('   - $key');
      }
      if (unexpected.length > 5) {
        print('   ... 还有 ${unexpected.length - 5} 个');
      }
      print('');
    }

    if (intentional.isNotEmpty) {
      print('ℹ️  ${_displayName(lang)} 有 ${intentional.length} 个刻意留空的单位后缀'
          '（见 intentionalEmptyKeys，正常）：${intentional.join('、')}');
      print('');
    }
  }

  if (!hasEmptyValues) {
    print('✅ 所有翻译都有值');
    print('');
  }

  // 总结
  print('📈 总结:');
  print('  基准语言: 简体中文 (zh) - $zhCount 个键');

  final complete =
      languages.where((l) => (keyCount[l] ?? 0) >= zhCount).length;
  final incomplete = languages.length - complete;

  print('  完整翻译: $complete/${languages.length} 个语言');
  print('  待完善: $incomplete 个语言');

  if (!hasIssues && !hasEmptyValues) {
    print('');
    print('🎉 所有翻译文件状态良好！');
  }
}

/// 检查各语言多余的 keys
Future<Map<String, Set<String>>> checkExtraKeys() async {
  print('🔍 第二步：检查各语言多余的 keys');
  print('');

  final l10nDir = Directory('lib/l10n');

  // 读取中文文件作为基准
  final zhFile = File('${l10nDir.path}/app_zh.arb');
  if (!zhFile.existsSync()) {
    print('❌ 找不到 app_zh.arb 文件');
    return {};
  }

  final zhContent = await zhFile.readAsString();
  final zhData = json.decode(zhContent) as Map<String, dynamic>;
  final zhKeys = zhData.keys.where((key) => !key.startsWith('@')).toSet();

  print('📊 基准文件 (app_zh.arb): ${zhKeys.length} 个键');
  print('');

  // 支持的语言列表 (排除中文，动态发现)
  final languages = discoverLanguages(l10nDir).where((l) => l != 'zh').toList();

  // 收集每个语言的多余键
  final Map<String, Set<String>> extraKeysMap = {};

  for (final lang in languages) {
    final file = File('${l10nDir.path}/app_$lang.arb');
    if (!file.existsSync()) {
      print('⚠️  跳过不存在的文件: app_$lang.arb');
      continue;
    }

    final content = await file.readAsString();
    final data = json.decode(content) as Map<String, dynamic>;
    final keys = data.keys.where((key) => !key.startsWith('@')).toSet();

    // 找出多余的键
    final extraKeys = keys.difference(zhKeys);

    if (extraKeys.isNotEmpty) {
      extraKeysMap[lang] = extraKeys;
    }
  }

  if (extraKeysMap.isEmpty) {
    print('✅ 没有发现多余的键！');
    return {};
  }

  // 显示所有多余的键
  print('═══════════════════════════════════════════════════════════════');
  print('📋 发现以下语言有多余的键：');
  print('');

  for (final entry in extraKeysMap.entries) {
    final lang = entry.key;
    final keys = entry.value;

    print('🔴 $lang (${_displayName(lang)}): ${keys.length} 个多余的键');
    print('─'.padRight(60, '─'));

    // 按字母排序显示
    final sortedKeys = keys.toList()..sort();
    for (var i = 0; i < sortedKeys.length && i < 10; i++) {
      print('  ${(i + 1).toString().padLeft(3)}. ${sortedKeys[i]}');
    }
    if (sortedKeys.length > 10) {
      print('  ... 还有 ${sortedKeys.length - 10} 个');
    }
    print('');
  }

  print('═══════════════════════════════════════════════════════════════');

  return extraKeysMap;
}

/// 清理各语言多余的 keys
Future<void> cleanExtraKeys(Map<String, Set<String>> extraKeysMap) async {
  print('');
  print('🔄 开始清理多余的 keys...');
  print('');

  final l10nDir = Directory('lib/l10n');
  int totalDeleted = 0;

  for (final entry in extraKeysMap.entries) {
    final lang = entry.key;
    final extraKeys = entry.value;
    final file = File('${l10nDir.path}/app_$lang.arb');

    final content = await file.readAsString();
    final data = json.decode(content) as Map<String, dynamic>;

    // 删除多余的键及其元数据
    for (final key in extraKeys) {
      data.remove(key);
      data.remove('@$key');
      totalDeleted++;
    }

    // 写回文件
    final encoder = JsonEncoder.withIndent('  ');
    final formatted = encoder.convert(data);
    await file.writeAsString('$formatted\n');

    print('  ✅ app_$lang.arb: 删除 ${extraKeys.length} 个键');
  }

  print('');
  print('✅ 清理多余 keys 完成！共删除 $totalDeleted 个键');
}

/// 检查未使用的 keys
Future<List<String>> checkUnusedKeys() async {
  print('🔍 第三步：检查未使用的翻译 key');
  print('');

  // 读取中文 arb 文件获取所有 keys
  final arbFile = File('lib/l10n/app_zh.arb');
  if (!arbFile.existsSync()) {
    print('❌ 找不到 lib/l10n/app_zh.arb 文件');
    return [];
  }

  final arbContent = await arbFile.readAsString();
  final arbData = json.decode(arbContent) as Map<String, dynamic>;

  // 获取所有非元数据的 keys
  final allKeys =
      arbData.keys.where((key) => !key.startsWith('@')).toList();

  print('📊 总共有 ${allKeys.length} 个翻译 keys');

  // 搜索 Dart 文件中的使用情况
  final libDir = Directory('lib');
  final dartFiles = <File>[];

  await for (final entity in libDir.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      // 过滤掉 lib/l10n/ 目录下的生成文件。
      // 分隔符必须先归一化成 '/'：Windows 的 entity.path 是 'lib\l10n\…'，
      // 旧写法 contains('lib/l10n/') 恒为假 —— 生成代码被当源码扫，每个 key
      // 的 `String get <key>;` 都算「使用中」，未使用 keys 于是恒等于 0
      // （同一份仓库在 macOS/Linux 上却会报出真实列表）。
      final normalized = entity.path.replaceAll(r'\', '/');
      if (!normalized.contains('lib/l10n/')) {
        dartFiles.add(entity);
      }
    }
  }

  print('📁 扫描 ${dartFiles.length} 个 Dart 文件...');
  print('');

  final unusedKeys = <String>[];
  final usedKeys = <String>{};
  // 「只有同名 Dart 标识符命中、拿不出 l10n 访问器证据」的键。
  // 典型来源：参数/字段/局部变量与 key 撞名（如 `String monthSuffix = '月'`、
  // `required this.monthSuffix`）—— 旧实现把这算成「已使用」，死键就这样
  // 长期隐身（`l10n.monthSuffix` 无人调用却永远查不出来）。
  // 单列一份供人工确认，**不并进未使用**：判死会误删真在用的 key。
  final weakOnlyKeys = <String>[];

  // 统计口径反转成「先扫一遍代码，再逐 key 查集合」：
  // 旧实现是「逐 key 建正则 × 逐个文件 hasMatch」= O(keys × files)，2500+ key
  // 的仓库上要跑几十秒，且强证据正则里叠了多段 `\s*` 量词，候选接收者变多后
  // 回溯会进一步恶化（实测卡死）。集合版只扫 3 遍文件。
  //
  // - [strongKeys]：被当作**成员**访问过的名字（`<本地化实例>.<key>`）；
  // - [identifiers]：真实代码里出现过的所有标识符（宽松兜底）。
  final strongKeys = await _collectStronglyUsedKeys(dartFiles);
  final identifiers = await _collectIdentifiers(dartFiles);

  for (final key in allKeys) {
    if (strongKeys.contains(key)) {
      usedKeys.add(key);
    } else if (identifiers.contains(key)) {
      usedKeys.add(key);
      weakOnlyKeys.add(key);
    } else {
      unusedKeys.add(key);
    }
  }

  // 输出结果
  print('✅ 使用中的 keys: ${usedKeys.length}');
  print('❌ 未使用的 keys: ${unusedKeys.length}');
  print('');

  if (unusedKeys.isNotEmpty) {
    print('📝 未使用的 keys 列表：');
    print('=' * 60);
    // 列全：这一份是要照着删的清单，截断到 20 条反而看不到全貌。
    for (final key in unusedKeys) {
      print('  • $key: "${arbData[key]}"');
    }
    print('=' * 60);
  } else {
    print('🎉 太好了！没有发现未使用的 keys！');
  }

  // 疑似死键：只有同名标识符命中。**不要**直接删 —— 先确认仓库里没有
  // `AppLocalizations` 实例用别的名字承载（本工具只认显式赋值与类型标注）。
  if (weakOnlyKeys.isNotEmpty) {
    print('');
    print('🟡 疑似死键（${weakOnlyKeys.length} 个）：只有同名 Dart 标识符命中，');
    print('   没有任何 `<本地化实例>.<key>` 访问器证据 —— 多半是参数/字段撞名');
    print('   把死键伪装成了「使用中」。人工确认真无调用后再删：');
    print('=' * 60);
    // 这份清单按设计应当很短，逐条列全（不像未使用列表可能上百条）。
    for (final key in weakOnlyKeys) {
      print('  • $key: "${arbData[key]}"');
    }
    print('=' * 60);
  }

  return unusedKeys;
}

/// 收集「被当作本地化 getter 访问过」的 key 名（强证据）。
///
/// 三种访问形态：
/// - 具名接收者：`l10n.foo`、`l10nError.foo`、`l.foo`（接收者名见
///   [_collectLocalizationReceivers]）；
/// - 接收者后的本地封装函数：`l10nInsight(context).foo`（见
///   `lib/pages/report/annual_report_page.dart` 的同名 helper）；
/// - 内联调用：`AppLocalizations.of(context).foo`、
///   `lookupAppLocalizations(locale).foo`。
///
/// 接收者与 `.` 之间允许空白与 `!`/`?`：仓库里大量写法是
/// `AppLocalizations.of(context)\n      .importChooseFile,` —— 旧实现的
/// `).$key` 相邻判断漏掉这类换行写法，正是「真在用的 key 被误报」的主因。
Future<Set<String>> _collectStronglyUsedKeys(List<File> dartFiles) async {
  final receivers = await _collectLocalizationReceivers(dartFiles);
  final member = r'([A-Za-z_$][A-Za-z0-9_$]*)';
  final namedRe = RegExp(r'\b(?:' +
      receivers.map(RegExp.escape).join('|') +
      r')(?:\s*\([^()]*\))?\s*[!?]?\s*\.\s*' +
      member);
  // 拼出的正则与原先 `'…' + member` 逐字节相同（相邻原始字面量先合并），
  // 只是改用插值以满足 prefer_interpolation_to_compose_strings。
  const callHeadPattern =
      r'\b(?:AppLocalizations\.of|lookupAppLocalizations)\s*\([^()]*\)'
      r'\s*[!?]?\s*\.\s*';
  final callRe = RegExp('$callHeadPattern$member');
  final keys = <String>{};
  for (final file in dartFiles) {
    final content = await file.readAsString();
    for (final re in [namedRe, callRe]) {
      for (final m in re.allMatches(content)) {
        keys.add(m.group(1)!);
      }
    }
  }
  return keys;
}

/// 收集 lib 真实代码里出现过的所有标识符（宽松兜底的「弱证据」）。
///
/// 与旧实现的正则 `[.\s]\??!?<key>\b` 等价但更快：那次是按 key 逐文件匹配，
/// 这里扫一遍即可。含注释/字符串里的出现（与旧实现一致，方向偏保守：
/// 多算「已使用」，不会误导删除）。
Future<Set<String>> _collectIdentifiers(List<File> dartFiles) async {
  final idRe = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*');
  final ids = <String>{};
  for (final file in dartFiles) {
    final content = await file.readAsString();
    for (final m in idRe.allMatches(content)) {
      ids.add(m.group(0)!);
    }
  }
  return ids;
}

/// 从 lib 的 Dart 文件里收集「承载 AppLocalizations 实例」的接收者名。
///
/// 三种形态都要收：
/// - `final l10n = AppLocalizations.of(context)`（赋值目标，无类型标注）；
/// - `AppLocalizations l10n`（参数/字段的类型标注）；
/// - `(l) => l.headerSkinAurora`（单参 lambda，参数类型靠推断 —— 见
///   `lib/styles/header_skins.dart` 的 `nameOf` 回调）。
///
/// 写死 `l10n` 不够：仓库里还有 l10nDialog / l10nError / l10nToast / sample
/// / subtitle / l 等命名，漏收会把它们的正常用法误报成「疑似死键」。
///
/// 放宽接收者集合只会让**误报变少**（多算成已使用），不会掩盖死键 ——
/// 死键的标识符在真实代码里根本不出现，凑不出 `.<key>` 这种文本。
Future<Set<String>> _collectLocalizationReceivers(List<File> dartFiles) async {
  final assignRe = RegExp(r'(\w+)\s*=\s*AppLocalizations\.of');
  final typedRe = RegExp(r'AppLocalizations\??\s+(\w+)');
  // 单参 lambda：`(l) => l.headerSkinAurora`。参数被 `)` 隔在 `=>` 之前，
  // 所以必须显式匹配括号，不能写成 `(\w+)\s*=>`。
  final lambdaRe = RegExp(r'\(\s*(\w+)\s*\)\s*=>\s*\1\s*\.');
  final names = <String>{};
  for (final file in dartFiles) {
    final content = await file.readAsString();
    for (final re in [assignRe, typedRe, lambdaRe]) {
      for (final m in re.allMatches(content)) {
        names.add(m.group(1)!);
      }
    }
  }
  // 兜底：一个都没扫到就退化回惯用名。空 alternation 会让 `(?:)` 匹配空串，
  // 强证据正则退化成「任意 `.<key>` 都算强命中」，守卫自身失效。
  if (names.isEmpty) names.add('l10n');
  return names;
}

/// 清理未使用的 keys
Future<void> cleanUnusedKeys(List<String> unusedKeys) async {
  print('');
  print('🔄 开始清理未使用的 keys...');
  print('');

  // 获取所有语言的 arb 文件
  final l10nDir = Directory('lib/l10n');
  final arbFiles = await l10nDir
      .list()
      .where((entity) => entity is File && entity.path.endsWith('.arb'))
      .cast<File>()
      .toList();

  for (final file in arbFiles) {
    final fileName = file.path.split('/').last;
    final content = await file.readAsString();
    final data = json.decode(content) as Map<String, dynamic>;

    // 删除未使用的 keys 及其元数据
    for (final key in unusedKeys) {
      data.remove(key);
      data.remove('@$key'); // 删除元数据
    }

    // 写回文件（格式化 JSON）
    final encoder = JsonEncoder.withIndent('  ');
    final formatted = encoder.convert(data);
    await file.writeAsString('$formatted\n');

    print('  ✓ $fileName');
  }

  print('');
  print('✅ 清理未使用 keys 完成！共删除 ${unusedKeys.length} 个键');
  print('💡 请运行 flutter gen-l10n 重新生成本地化代码');
}
