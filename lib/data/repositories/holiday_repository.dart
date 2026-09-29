import '../db.dart';

/// 中国法定节假日本地缓存的数据访问（prd/calendar_holiday）。
///
/// 两张表都是「随时可整表重建」的本地缓存，与自动汇率（[ExchangeRates]）
/// 同定位，因此本接口的写方法**刻意不记 ChangeTracker**：纳管会回流幻影
/// 变更，并让 `test/cloud/sync_contract_coverage_test.dart` 变红
/// （见 prd/calendar_holiday/design.md 决策 2，这是本设计最需要 review 的边界）。
///
/// 网络拉取 / 预置兜底 / 每月更新判定都在 `HolidayService`；本层只做 DB，
/// 事务边界不外泄（整年替换的原子性是本层职责）。
abstract class HolidayRepository {
  /// 记账表固定主键（单行设计）。
  static const int metaRowId = 1;

  /// 全部缓存行（date 升序）。
  Future<List<HolidayEntry>> getAll();

  /// 某年缓存行（date 升序）。
  Future<List<HolidayEntry>> getByYear(int year);

  /// 某公历日（'YYYY-MM-DD'）单行；无则 null（调用方回落到预置表）。
  Future<HolidayEntry?> getByDate(String date);

  /// 整年替换：**事务内**先删该年旧行再插入 [rows]，任一步失败整体回滚，
  /// 不留「删了旧行、没插上新行」的空年份。
  ///
  /// [year] 是「本次拉取的年份」（删旧行用）；[rows] 每行自带 year
  /// （跨年条目如元旦放假以 date 所属年份为准）。
  Future<void> replaceYear(int year, List<HolidayEntry> rows);

  /// 更新记账。无记录时返回默认值（从未成功 / 自动更新开），
  /// **不落库**——首次真正写是在 saveMeta。
  Future<HolidayUpdateMetaData> getMeta();

  /// upsert 更新记账（id 归一为 [metaRowId]）。
  Future<void> saveMeta(HolidayUpdateMetaData meta);
}
