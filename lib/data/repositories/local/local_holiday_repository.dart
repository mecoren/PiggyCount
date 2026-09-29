import 'package:drift/drift.dart' as d;

import '../../db.dart';
import '../holiday_repository.dart';

/// [HolidayRepository] 的 Drift 实现。
///
/// 刻意不注入 ChangeTracker：两张表都是可重建的本地缓存（见接口注释）。
class LocalHolidayRepository implements HolidayRepository {
  LocalHolidayRepository(this.db);

  final PiggyDatabase db;

  @override
  Future<List<HolidayEntry>> getAll() => (db.select(db.holidayEntries)
        ..orderBy([(t) => d.OrderingTerm.asc(t.date)]))
      .get();

  @override
  Future<List<HolidayEntry>> getByYear(int year) =>
      (db.select(db.holidayEntries)
            ..where((t) => t.year.equals(year))
            ..orderBy([(t) => d.OrderingTerm.asc(t.date)]))
          .get();

  @override
  Future<HolidayEntry?> getByDate(String date) =>
      (db.select(db.holidayEntries)..where((t) => t.date.equals(date)))
          .getSingleOrNull();

  @override
  Future<void> replaceYear(int year, List<HolidayEntry> rows) {
    // 整年替换的原子性收在本层：单事务内先删该年旧行再插新行。
    // 逐条 insert 用 upsert 语义兜底：12 月拉 [本年, 次年] 两轮时，
    // 次年 1 月 1 日这类跨年条目可能被两个年份的响应同时给出。
    return db.transaction(() async {
      await (db.delete(db.holidayEntries)..where((t) => t.year.equals(year)))
          .go();
      if (rows.isEmpty) return;
      await db.batch((b) {
        b.insertAllOnConflictUpdate(
          db.holidayEntries,
          rows.map((r) => r.toCompanion(false)).toList(),
        );
      });
    });
  }

  @override
  Future<HolidayUpdateMetaData> getMeta() async {
    final row = await (db.select(db.holidayUpdateMeta)
          ..where((t) => t.id.equals(HolidayRepository.metaRowId)))
        .getSingleOrNull();
    return row ?? _defaults();
  }

  @override
  Future<void> saveMeta(HolidayUpdateMetaData meta) {
    return db.into(db.holidayUpdateMeta).insertOnConflictUpdate(
          HolidayUpdateMetaData(
            // 单行表：外部传入的 id 一律归一到固定行，避免写出第二行。
            id: HolidayRepository.metaRowId,
            lastUpdateMs: meta.lastUpdateMs,
            lastAttemptMs: meta.lastAttemptMs,
            failureCount: meta.failureCount,
            autoEnabled: meta.autoEnabled,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }

  HolidayUpdateMetaData _defaults() => HolidayUpdateMetaData(
        id: HolidayRepository.metaRowId,
        lastUpdateMs: 0,
        lastAttemptMs: 0,
        failureCount: 0,
        autoEnabled: true,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
}
