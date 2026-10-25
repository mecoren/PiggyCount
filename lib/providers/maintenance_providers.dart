/// 孤儿数据维护工具的 Riverpod 集成。
///
/// 分两个 Provider:
/// - [orphanScannerProvider] / [orphanCleanerProvider]:单例服务,注入 db。
/// - [orphanScanReportProvider]:FutureProvider,UI 用 `ref.watch` 拿扫描结果;
///   `ref.invalidate(orphanScanReportProvider)` 重扫。
///
/// UI 在 cleaner 跑完后 invalidate 一次,重扫给新视图。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/maintenance/orphan_cleaner.dart';
import '../services/maintenance/orphan_record.dart';
import '../services/maintenance/orphan_scanner.dart';
import '../services/system/prefs_repair_service.dart';
import 'database_providers.dart';

/// 本机偏好存储自救（清空损坏的 `flutter.*` 偏好项）。
///
/// 只在「`SharedPreferences.getInstance()` 整体失败」时使用：云服务页错误态
/// 提供入口，走双重危险确认后清空再重试。
final prefsRepairServiceProvider =
    Provider<PrefsRepairService>((_) => const PrefsRepairService());

final orphanScannerProvider = Provider<OrphanScanner>((ref) {
  final db = ref.watch(databaseProvider);
  return OrphanScanner(db: db);
});

final orphanCleanerProvider = Provider<OrphanCleaner>((ref) {
  final db = ref.watch(databaseProvider);
  return OrphanCleaner(db: db);
});

/// 一次扫描的全部结果。autoDispose:用户离开页面后下次进来重扫。
final orphanScanReportProvider =
    FutureProvider.autoDispose<OrphanScanReport>((ref) async {
  final scanner = ref.watch(orphanScannerProvider);
  return scanner.scanAll();
});
