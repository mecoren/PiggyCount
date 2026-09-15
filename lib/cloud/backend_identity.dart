// 当前云后端身份摘要（「发现云端账本」弹窗、启动检查等确认场景共用）。
//
// 背景（2026-09-15 双模拟器云同步回归实测）：B 端在后端轮换后残留了上一轮
// 的激活后端状态，连续两次「误连旧后端」——发现弹窗照常出现在 S3 轮数据
// 头上，而当时激活的其实是 WebDAV（两轮 syncId 完全不同，下载后才察觉）。
// 弹窗原文案只有「发现 N 个本机没有的账本：…」，用户无从判断这是哪个后端
// 的数据。补上一行「后端类型 + 脱敏地址 + 桶/远端路径」后，连错后端可以
// 在点「下载」之前就被看出来。
//
// 安全边界：只展示 host（复用 CloudServiceConfig.obfuscatedUrl 的脱敏口径，
// 丢弃 scheme / 查询串）与桶名 / 远端路径，**绝不拼接 apikey、accessKey、
// secretKey、密码**——这是一个面向用户的提示串，不是诊断导出。

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import '../l10n/app_localizations.dart';

/// 远端路径等长标识的展示上限：超出截断，避免撑爆弹窗。
const int _maxTargetLength = 48;

/// 后端类型的中文展示名（与「我的 → 云服务」卡片同口径）。
///
/// S3 / iCloud 沿用该卡片里的字面量（此前两处都直接写字面量），
/// 需要本地化的类型走 l10n，避免再引入一套重复称谓。
String backendTypeLabel(AppLocalizations l10n, CloudBackendType type) {
  switch (type) {
    case CloudBackendType.local:
      return l10n.mineCloudServiceOffline;
    case CloudBackendType.webdav:
      return l10n.mineCloudServiceWebDAV;
    case CloudBackendType.supabase:
      return l10n.mineCloudServiceCustom;
    case CloudBackendType.icloud:
      return 'iCloud';
    case CloudBackendType.s3:
      return 'S3';
  }
}

/// 当前激活配置的一行身份摘要：`类型 · host · 桶或远端路径`。
///
/// - 地址取 `obfuscatedUrl()`（仅 host）；本地模式 / 未配置的哨兵值
///   （`__LOCAL_DEVICE__` / `__NOT_CONFIGURED__`）不展示；
/// - 目标位按后端取桶名（S3 / Supabase）或远端路径（WebDAV），
///   过长截断；iCloud / 本地无目标位时省略。
String backendIdentitySummary(AppLocalizations l10n, CloudServiceConfig cfg) {
  final parts = <String>[backendTypeLabel(l10n, cfg.type)];
  final host = _displayHost(cfg);
  if (host != null) parts.add(host);
  final target = _displayTarget(cfg);
  if (target != null) parts.add(target);
  return parts.join(' · ');
}

String? _displayHost(CloudServiceConfig cfg) {
  // iCloud 没有「地址」概念：obfuscatedUrl() 对它返回固定的 'iCloud Drive'，
  // 拼进去会变成「iCloud · iCloud Drive」这种同义重复，故直接略去。
  if (cfg.type == CloudBackendType.icloud) return null;
  final host = cfg.obfuscatedUrl();
  if (host == '__LOCAL_DEVICE__' || host == '__NOT_CONFIGURED__') return null;
  final trimmed = host.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _displayTarget(CloudServiceConfig cfg) {
  final String? raw;
  switch (cfg.type) {
    case CloudBackendType.s3:
      raw = cfg.s3Bucket;
    case CloudBackendType.supabase:
      raw = cfg.supabaseBucket;
    case CloudBackendType.webdav:
      raw = cfg.webdavRemotePath;
    case CloudBackendType.local:
    case CloudBackendType.icloud:
      raw = null; // 本地 / iCloud 无桶或远端路径概念
  }
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length <= _maxTargetLength
      ? trimmed
      : '${trimmed.substring(0, _maxTargetLength - 1)}…';
}
