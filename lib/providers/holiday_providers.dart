import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db.dart';
import '../services/calendar/holiday_service.dart';
import 'database_providers.dart';

/// 节假日服务（本地缓存 Repository + 网络拉取 / 预置兜底 / 每日判定）。
final holidayServiceProvider = Provider<HolidayService>((ref) {
  return HolidayService(ref.watch(repositoryProvider));
});

/// 全部缓存行（DB 为空时由 Service 回落预置表，保证冷启动 / 离线可用）。
///
/// 手动更新成功后 `ref.invalidate` 本 provider 即可让日历与设置页同步刷新。
final holidayListProvider = FutureProvider<List<HolidayEntry>>((ref) {
  return ref.watch(holidayServiceProvider).loadAll();
});

/// 按 'YYYY-MM-DD' 索引的缓存（日历日格逐格查询用，避免线性查找）。
///
/// 从 [holidayListProvider] 派生而非各自查库：只需失效列表即可同时刷新两者。
final holidayMapProvider =
    Provider<AsyncValue<Map<String, HolidayEntry>>>((ref) {
  return ref.watch(holidayListProvider).whenData(
        (rows) => {for (final r in rows) r.date: r},
      );
});

/// 更新记账（上次成功 / 连续失败 / 自动更新开关 / 每日时刻）。
final holidayMetaProvider = FutureProvider<HolidayUpdateMetaData>((ref) {
  return ref.watch(holidayServiceProvider).getMeta();
});