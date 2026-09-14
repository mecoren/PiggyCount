// 审计 SUP-1（2026-09-12 P1）回归：Supabase 存储层路径遍历防护。
//
// 根因：`users/{uid}/` 前缀是 Supabase 模式下的唯一租户隔离手段，
// `_buildUserPath` 此前直接 join，`../` 段可构造 `users/uidA/../uidB/x`
// 形态的跨用户对象键（服务端语义解析后越权读写）。
//
// 锁死语义：路径含恰为 `..` 的分段（含 URL 编码 `%2e%2e` 与反斜杠
// `\..` 形态）→ CloudConfigurationException，且在任何网络请求之前
// 拒绝（未登录环境即可验证——认证异常若先于遍历校验抛出说明校验
// 顺序错误）。合法文件名（`ledger..backup.json` 连续点、`.hidden`
// 前导点）不受影响。
library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_supabase/flutter_cloud_sync_supabase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

void main() {
  SupabaseStorageService buildService() {
    final client = supabase.SupabaseClient(
      'https://test-project.supabase.co',
      'test-anon-key',
    );
    return SupabaseStorageService(client, 'test-bucket');
  }

  group('SUP-1: 路径遍历防护（分段 .. 校验 + 双形态归一化）', () {
    test('裸 ../ 段 → 拒绝（且先于认证检查——未登录也不出现 '
        'CloudNotAuthenticatedException）', () async {
      final svc = buildService();
      // 校验顺序断言：若 _buildUserPath 不含遍历校验，第一个抛出的
      // 将是 CloudNotAuthenticatedException（currentUser == null）
      await expectLater(
        svc.download(path: '../other-user/secret.json'),
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test('中段 .. 跨用户形态 users/a/../b → 拒绝', () async {
      final svc = buildService();
      await expectLater(
        svc.upload(path: 'users/a/../b/x.json', data: '{}'),
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test('URL 编码 %2e%2e 形态 → 归一化后拒绝（编码盲区）', () async {
      final svc = buildService();
      await expectLater(
        svc.delete(path: '%2e%2e/victim.json'),
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test('反斜杠 \\.. 形态 → 归一化后拒绝', () async {
      final svc = buildService();
      await expectLater(
        svc.exists(path: '..\\..\\victim.json'),
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test('合法文件名不受误伤：连续点 / 前导点 / 普通路径', () async {
      final svc = buildService();
      // 这些不应抛 CloudConfigurationException——未登录环境下抛的
      // 是 CloudNotAuthenticatedException（认证先于网络，路径本身合法）
      await expectLater(
        svc.download(path: 'ledger..backup.json'),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );
      await expectLater(
        svc.download(path: '.hidden/ledger_1.json'),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );
      await expectLater(
        svc.download(path: 'attachments/abc123.bin'),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );
    });
  });
}
