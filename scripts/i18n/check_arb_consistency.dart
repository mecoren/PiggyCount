#!/usr/bin/env dart
// ignore_for_file: avoid_print
// 命令行门禁：print 即输出方式（终端 / CI 注解），非库代码。

/// ARB key 一致性门禁（E4）。
///
/// 以 `l10n.yaml` 的模板 `app_en.arb` 为基准，逐语言检查：
/// 1. **键集合一致**：模板有、语言缺 → 错误；语言有、模板无 → 错误；
/// 2. **无意外空值**：空串会直接显示成空白，除 `intentionalEmptyKeys` 外一律报错；
/// 3. **占位符齐全**：模板 `@key.placeholders` 声明的参数必须在译文里出现
///    （`{count}` / `{count, plural, ...}` 都算），否则 `flutter gen-l10n`
///    会把它渲染成字面量或直接失败；
/// 4. **无孤立元数据**：`@foo` 对应的 `foo` 已不存在（删 key 漏删元数据）。
///
/// 用法：
/// ```
/// dart run scripts/i18n/check_arb_consistency.dart             # 本地
/// dart run scripts/i18n/check_arb_consistency.dart --github    # CI 注解
/// dart run scripts/i18n/check_arb_consistency.dart --self-check
/// ```
/// 有任一错误时退出码为 1（可直接作为 CI 步骤）。
library;

import 'dart:io';

import 'arb_rules.dart';

const String _l10nDirPath = 'lib/l10n';

class _Issue {
  const _Issue(this.file, this.message);

  final String file;
  final String message;
}

void main(List<String> args) {
  if (args.contains('--self-check')) {
    _runSelfCheck();
    return;
  }
  final github = args.contains('--github');

  final dir = Directory(_l10nDirPath);
  final languages = discoverLanguages(dir);
  if (languages.isEmpty) {
    _emit(
      const _Issue('lib/l10n', '未发现任何 app_*.arb 语言包'),
      github: github,
    );
    exitCode = 1;
    return;
  }

  final templateFile = File('$_l10nDirPath/app_$templateLanguage.arb');
  if (!templateFile.existsSync()) {
    _emit(
      _Issue(templateFile.path, '模板文件不存在（l10n.yaml 指向 app_$templateLanguage.arb）'),
      github: github,
    );
    exitCode = 1;
    return;
  }

  final Map<String, dynamic> template;
  try {
    template = loadArb(templateFile);
  } on FormatException catch (e) {
    _emit(_Issue(templateFile.path, '模板 JSON 解析失败: ${e.message}'),
        github: github);
    exitCode = 1;
    return;
  }

  final templateKeys = messageKeys(template);
  final issues = <_Issue>[];

  print('');
  print('ARB 一致性检查（模板：app_$templateLanguage.arb）');
  print('语言包：${languages.join(', ')}');
  print('模板键数：${templateKeys.length}');
  print('-' * 70);

  for (final lang in languages) {
    if (lang == templateLanguage) continue;
    final file = File('$_l10nDirPath/app_$lang.arb');
    if (!file.existsSync()) {
      issues.add(_Issue(file.path, '语言包文件不存在'));
      continue;
    }

    final Map<String, dynamic> arb;
    try {
      arb = loadArb(file);
    } on FormatException catch (e) {
      issues.add(_Issue(file.path, 'JSON 解析失败: ${e.message}'));
      continue;
    }

    final keys = messageKeys(arb);

    // 1) 键集合
    final missing = templateKeys.difference(keys).toList()..sort();
    final extra = keys.difference(templateKeys).toList()..sort();
    if (missing.isNotEmpty) {
      issues.add(_Issue(
        file.path,
        '缺少 ${missing.length} 个键: ${_preview(missing)}',
      ));
    }
    if (extra.isNotEmpty) {
      issues.add(_Issue(
        file.path,
        '多出 ${extra.length} 个键（模板里没有）: ${_preview(extra)}',
      ));
    }

    // 2) 空值
    final empty = <String>[];
    for (final key in templateKeys.intersection(keys)) {
      final value = arb[key];
      if (value is String &&
          value.trim().isEmpty &&
          !intentionalEmptyKeys.contains(key)) {
        empty.add(key);
      }
    }
    if (empty.isNotEmpty) {
      issues.add(_Issue(
        file.path,
        '${empty.length} 个键是空值（非故意留空）: ${_preview(empty)}',
      ));
    }

    // 3) 占位符
    final placeholderErrors = <String>[];
    for (final key in templateKeys.intersection(keys)) {
      final declared = declaredPlaceholders(template, key);
      if (declared.isEmpty) continue;
      final value = arb[key];
      if (value is! String) continue;
      final absent = declared.where((p) => !hasPlaceholder(value, p)).toList()
        ..sort();
      if (absent.isNotEmpty) {
        placeholderErrors.add('$key（缺 ${absent.join('、')}）');
      }
    }
    if (placeholderErrors.isNotEmpty) {
      issues.add(_Issue(
        file.path,
        '${placeholderErrors.length} 个键缺少占位符: ${_preview(placeholderErrors)}',
      ));
    }

    // 4) 孤立元数据
    final orphanMeta = <String>[];
    for (final k in arb.keys) {
      if (!k.startsWith('@') || k.startsWith('@@') || k.startsWith('@_')) {
        continue;
      }
      final base = k.substring(1);
      if (!keys.contains(base)) orphanMeta.add(k);
    }
    if (orphanMeta.isNotEmpty) {
      issues.add(_Issue(
        file.path,
        '${orphanMeta.length} 个孤立元数据（对应的消息键不存在）: '
        '${_preview(orphanMeta)}',
      ));
    }

    // 5) @@locale 自洽（允许缺失，存在则必须与文件名一致）
    final locale = arb['@@locale'];
    if (locale is String && locale != lang) {
      issues.add(_Issue(
        file.path,
        '@@locale="$locale" 与文件名语言 "$lang" 不一致',
      ));
    }
  }

  if (issues.isEmpty) {
    print('✅ 通过：${languages.length} 个语言包键集合、空值、占位符全部一致');
    print('');
    return;
  }

  for (final issue in issues) {
    _emit(issue, github: github);
  }
  print('');
  print('❌ 发现 ${issues.length} 项问题');
  print('');
  exitCode = 1;
}

String _preview(List<String> items, {int limit = 20}) {
  if (items.length <= limit) return items.join(', ');
  return '${items.take(limit).join(', ')} … 还有 ${items.length - limit} 个';
}

void _emit(_Issue issue, {required bool github}) {
  print('ERROR [${issue.file}] ${issue.message}');
  if (github) {
    print('::error file=${issue.file}::${issue.message}');
  }
}

/// 门禁自身的纯逻辑自检（不读仓库文件，CI 不跑，手动回归时用）。
void _runSelfCheck() {
  final failures = <String>[];
  void check(String what, bool ok) {
    if (!ok) failures.add(what);
  }

  check('{name} 命中', hasPlaceholder('Hello {name}', 'name'));
  check('{count, plural, ...} 命中', hasPlaceholder('{count, plural, one {# 笔} other {# 笔}}', 'count'));
  check('ICU 分支里的 {He} 不误判', !hasPlaceholder('{gender, select, male {He} other {They}}', 'He'));

  final template = <String, dynamic>{
    'greeting': 'Hello {name}',
    '@greeting': {
      'placeholders': {
        'name': {'type': 'String'},
      },
    },
  };
  final missing = messageKeys(template).difference({'other'});
  check('键集合差集', missing.contains('greeting'));
  check('占位符声明解析', declaredPlaceholders(template, 'greeting').contains('name'));

  if (failures.isEmpty) {
    print('✅ self-check 通过');
  } else {
    print('❌ self-check 失败: ${failures.join('; ')}');
    exitCode = 1;
  }
}
