// 切换云服务确认弹窗的「凭据保留」文案契约（2026-09-13 WebDAV 轮 §5.4-2 落地）。
//
// 背景：该轮实测证实切换后端时 S3 凭据原样保留在加密存储（切回即用），
// 但弹窗只说「将登出当前账号」，用户无法预知配置是否丢失，凭据保留的
// 事实是实测出来的而不是产品承诺出来的。本批把实测事实固化为产品文案：
// 「已保存的云服务凭据不会被删除，可随时切回」。
//
// 前置语义验证（cloud_service_store.activate）：activate 只写
// cloud_active_type 并读取目标后端自己的配置键，从不删除其他后端凭据
// （含切到 local/iCloud 的路径）——文案承诺在所有后端组合上都成立。
//
// 读源码/生成物做正则匹配（对齐 remote_card_slot_id_contract_test 的
// 契约测试模式），锁两条：
// 1. 4 个 arb 与 4 个生成 localization 的该消息都含「凭据不删除/可切回」
//    语义（防止后续 l10n 修改把承诺改丢，或 gen-l10n 漏跑）；
// 2. 切换确认弹窗消费的是 cloudSwitchConfirmMessage（文案改动必然
//    经由该 key 到达用户，杜绝旁路硬编码）。

import 'dart:io';

/// locale → 生成文件名 + 「凭据保留」承诺必须出现的关键词。
/// zh_TW 与 zh 共享 app_localizations_zh.dart（两个类）。
const _targets = <String, (String, String)>{
  'zh': ('app_zh.arb|app_localizations_zh.dart', '凭据不会被删除'),
  'zh_TW': ('app_zh_TW.arb|app_localizations_zh.dart', '憑證不會被刪除'),
  'en': ('app_en.arb|app_localizations_en.dart', 'will not be deleted'),
  'ko': ('app_ko.arb|app_localizations_ko.dart', '삭제되지 않으며'),
};

final _getterRe = RegExp(
    r"cloudSwitchConfirmMessage\s*=>\s*'([^']*)'",
    dotAll: true);
final _arbRe = RegExp(
    r'"cloudSwitchConfirmMessage":\s*"([^"]*)"',
    dotAll: true);

void main() {
  for (final e in _targets.entries) {
    final (files, keyword) = e.value;

    // 1a. arb 源：消息体含承诺关键词
    final arb = File('lib/l10n/${files.split('|').first}').readAsStringSync();
    final arbMsg = _arbRe.firstMatch(arb)?.group(1);
    _expect(arbMsg != null, 'app_${e.key}.arb defines cloudSwitchConfirmMessage');
    _expect(
      arbMsg!.contains(keyword),
      'app_${e.key}.arb: cloudSwitchConfirmMessage mentions "$keyword" '
      '(credential-retention promise)',
    );

    // 1b. 生成物：该 locale 的 getter 字符串里同样含承诺关键词。
    // zh 文件里有两个类（zh / zh_TW），按「任一匹配含关键词」判定
    // ——zh 判 zh 关键词、zh_TW 判 zh_TW 关键词，互不越界。
    final gen = File('lib/l10n/${files.split('|').last}').readAsStringSync();
    final bodies = _getterRe
        .allMatches(gen)
        .map((m) => m.group(1) ?? '')
        .toList();
    _expect(bodies.isNotEmpty, 'generated ${e.key} localization has getter');
    _expect(
      bodies.any((b) => b.contains(keyword)),
      'generated ${e.key} localization carries the credential-retention '
      'promise (run: flutter gen-l10n)',
    );
  }

  // 2. 弹窗接线：切换确认消费 cloudSwitchConfirmMessage
  final page =
      File('lib/pages/cloud/cloud_service_page.dart').readAsStringSync();
  _expect(
    page.contains('cloudSwitchConfirmMessage'),
    'cloud_service_page: switch confirm dialog consumes '
    'cloudSwitchConfirmMessage',
  );

  stdout.writeln('Cloud switch credential-retention copy contract passed.');
}

void _expect(bool condition, String description) {
  if (!condition) {
    throw StateError('Expected $description.');
  }
}
