import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/database_providers.dart';
import '../../providers/encryption_providers.dart';
import '../../providers/sync_providers.dart'
    show
        activeCloudConfigProvider,
        syncServiceProvider,
        syncMetricsServiceProvider;
import '../transactions_sync_manager.dart';
import 'backup_scheduler.dart';
import 'cloud_backup_service.dart';

/// 云端备份服务（仅路径 A 快照后端可用；PiggyCount Cloud / LocalOnly 为 null）
final cloudBackupServiceProvider = Provider<CloudBackupService?>((ref) {
  final sync = ref.watch(syncServiceProvider);
  if (sync is! TransactionsSyncManager) return null;
  // P0-1：备份场景指标注入；backend 分组键取当前激活配置的后端名
  final activeAsync = ref.watch(activeCloudConfigProvider);
  return CloudBackupService(
    db: ref.watch(databaseProvider),
    repo: ref.watch(repositoryProvider),
    // 复用同步管理器的 E2EE 装饰 storage：备份与同步同一加密口径
    storageResolver: () => sync.decoratedStorage(),
    encryptionService: ref.watch(encryptionServiceProvider),
    metrics: ref.watch(syncMetricsServiceProvider),
    metricsBackend:
        activeAsync.hasValue ? activeAsync.value!.type.name : 'unknown',
  );
});

/// 备份相关 UI 状态刷新 tick（手动/定时备份完成后 +1）
final backupRefreshProvider = StateProvider<int>((ref) => 0);

/// 定时备份开关（持久化 backup_auto_enabled，默认关）
final backupAutoEnabledProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  ref.watch(backupRefreshProvider);
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getBool('backup_auto_enabled') ?? false;
});

class BackupAutoSetter {
  BackupAutoSetter(this._ref);
  final Ref _ref;
  Future<void> set(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('backup_auto_enabled', v);
    _ref.invalidate(backupAutoEnabledProvider);
  }
}

final backupAutoSetterProvider =
    Provider<BackupAutoSetter>((ref) => BackupAutoSetter(ref));

/// 每日触发时间（持久化 backup_time，默认 22:00）
final backupTimeProvider = FutureProvider.autoDispose<String>((ref) async {
  ref.watch(backupRefreshProvider);
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getString('backup_time') ?? BackupScheduler.defaultBackupTime;
});

class BackupTimeSetter {
  BackupTimeSetter(this._ref);
  final Ref _ref;
  Future<void> set(String hhMm) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backup_time', hhMm);
    _ref.invalidate(backupTimeProvider);
  }
}

final backupTimeSetterProvider =
    Provider<BackupTimeSetter>((ref) => BackupTimeSetter(ref));

/// 最近一次备份状态（date + ok），从未备份为 null
final lastBackupInfoProvider =
    FutureProvider.autoDispose<({String date, bool ok})?>((ref) async {
  ref.watch(backupRefreshProvider);
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  final date = prefs.getString('backup_last_date');
  if (date == null || date.isEmpty) return null;
  return (date: date, ok: prefs.getString('backup_last_result') != 'fail');
});
