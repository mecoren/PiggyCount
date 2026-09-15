// 后端身份摘要回归（2026-09-15 双模拟器回归后补的改进点）。
//
// 实测背景：B 端后端轮换后残留旧后端状态，两次误连旧后端下载串台，
// 而「发现云端账本」弹窗只有「发现 N 个账本」，看不出数据来自哪个后端。
// 本文件锁定三件事：
// 1. 摘要口径 `类型 · host · 桶/远端路径`，本地/未配置不展示哨兵地址；
// 2. **不泄露凭据**：ak/sk、WebDAV 密码、Supabase anonKey 绝不出现在
//    摘要串里（它是给用户看的提示，不是诊断导出）；
// 3. 超长远端路径截断，避免撑爆弹窗。

import 'package:flutter/material.dart' show Locale;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/cloud/backend_identity.dart';
import 'package:piggycount/l10n/app_localizations.dart';

const _s3 = CloudServiceConfig(
  type: CloudBackendType.s3,
  name: 'S3',
  s3Endpoint: 'oss-cn-shenzhen.aliyuncs.com',
  s3Region: 'cn-shenzhen',
  s3AccessKey: 'AKIASECRET123',
  s3SecretKey: 'SUPERSECRET456',
  s3Bucket: 'piggycount',
);

const _webdav = CloudServiceConfig(
  type: CloudBackendType.webdav,
  name: 'WebDAV',
  webdavUrl: 'https://dav.example.com/dav/piggy/',
  webdavUsername: 'pctest',
  webdavPassword: 'piggy123',
  webdavRemotePath: '/piggycount/',
);

const _supabase = CloudServiceConfig(
  type: CloudBackendType.supabase,
  name: 'Supabase',
  supabaseUrl: 'https://abcdefg.supabase.co',
  supabaseAnonKey: 'ANONKEY_SHOULD_NOT_APPEAR',
  supabaseBucket: 'ledger-backup',
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('backendIdentitySummary 口径', () {
    test('S3：类型 · host（无 scheme）· 桶名', () {
      expect(backendIdentitySummary(l10n, _s3),
          'S3 · oss-cn-shenzhen.aliyuncs.com · piggycount');
    });

    test('WebDAV：类型 · host · 远端路径（与「我的」卡片同口径类型名）', () {
      expect(backendIdentitySummary(l10n, _webdav),
          '${l10n.mineCloudServiceWebDAV} · dav.example.com · /piggycount/');
    });

    test('Supabase：类型 · host · 桶名', () {
      expect(backendIdentitySummary(l10n, _supabase),
          '${l10n.mineCloudServiceCustom} · abcdefg.supabase.co · ledger-backup');
    });

    test('本地模式：只展示类型名，不含哨兵地址', () {
      final summary = backendIdentitySummary(
          l10n, CloudServiceConfig.localStorage());
      expect(summary, l10n.mineCloudServiceOffline);
      expect(summary.contains('__LOCAL_DEVICE__'), isFalse);
    });

    test('iCloud：无 host / 无桶 → 只展示类型名', () {
      final summary = backendIdentitySummary(
          l10n, const CloudServiceConfig(type: CloudBackendType.icloud, name: 'iCloud'));
      expect(summary, 'iCloud');
    });

    test('未配置的 S3（endpoint 缺失）：不展示 __NOT_CONFIGURED__', () {
      final summary = backendIdentitySummary(
          l10n,
          const CloudServiceConfig(
            type: CloudBackendType.s3,
            name: 'S3',
            s3Bucket: '',
          ));
      expect(summary, 'S3');
      expect(summary.contains('__NOT_CONFIGURED__'), isFalse);
    });

    test('超长远端路径：截断以 … 结尾，长度不超上限', () {
      final long = '/${'a' * 80}/';
      final summary = backendIdentitySummary(
          l10n,
          CloudServiceConfig(
            type: CloudBackendType.webdav,
            name: 'WebDAV',
            webdavUrl: 'https://dav.example.com',
            webdavRemotePath: long,
          ));
      expect(summary.endsWith('…'), isTrue);
      final target = summary.split(' · ').last;
      expect(target.length, 48);
    });
  });

  group('backendIdentitySummary 不泄露凭据', () {
    test('S3 ak/sk 不出现在摘要里', () {
      final summary = backendIdentitySummary(l10n, _s3);
      expect(summary.contains('AKIASECRET123'), isFalse);
      expect(summary.contains('SUPERSECRET456'), isFalse);
    });

    test('WebDAV 密码 / 用户名不出现在摘要里', () {
      final summary = backendIdentitySummary(l10n, _webdav);
      expect(summary.contains('piggy123'), isFalse);
      expect(summary.contains('pctest'), isFalse);
    });

    test('Supabase anonKey 不出现在摘要里', () {
      final summary = backendIdentitySummary(l10n, _supabase);
      expect(summary.contains('ANONKEY_SHOULD_NOT_APPEAR'), isFalse);
    });
  });
}
