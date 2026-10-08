import '../models/transaction_original_amount.dart';

/// 统计Repository接口
/// 定义统计相关的所有数据操作
abstract class StatisticsRepository {
  /// 按分类统计（指定时间范围和类型）
  Future<List<({int? id, String name, String? icon, double total})>> totalsByCategory({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  });

  /// 按分类统计（支持二级分类展开），count 为该分类下的记账笔数
  Future<List<({int? id, String name, String? icon, int? parentId, int level, double total, int count})>>
      totalsByCategoryWithHierarchy({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  });

  /// 按天统计（指定时间范围和类型）
  Future<List<({DateTime day, double total})>> totalsByDay({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  });

  /// 按月统计（指定年份和类型）
  ///
  /// [month] 为周期标签,约定传 DateTime(year, month, 1);实际范围由账本
  /// monthStartDay 决定:[y-m-起始日, y-(m+1)-起始日)。
  /// 返回的 12 桶为周期标签月,范围 = 账本起始日定义的
  /// [当年1月周期起点, 次年1月周期起点)。
  Future<List<({DateTime month, double total})>> totalsByMonth({
    required int ledgerId,
    required String type,
    required int year,
  });

  /// 按年统计（所有年份，指定类型）
  Future<List<({int year, double total})>> totalsByYearSeries({
    required int ledgerId,
    required String type,
  });

  /// 按标签统计（指定时间范围和类型），total 按金额降序由调用方排。
  ///
  /// 口径与分类维度一致：`COALESCE(native_amount, amount)` + `exclude_from_stats
  /// = 0`，区间为半开 `[start, end)`，与 [totalsByCategory] 可直接对账。
  Future<List<({int id, String name, String? color, double total, int count})>>
      totalsByTag({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  });

  /// 获取指定时间范围的收支总额
  Future<(double income, double expense)> totalsInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  });

  /// 获取指定月份的收支总额
  ///
  /// [month] 为周期标签,约定传 DateTime(year, month, 1);实际范围由账本
  /// monthStartDay 决定:[y-m-起始日, y-(m+1)-起始日)。
  Future<(double income, double expense)> monthlyTotals({
    required int ledgerId,
    required DateTime month,
  });

  /// 获取指定年份的收支总额
  Future<(double income, double expense)> yearlyTotals({
    required int ledgerId,
    required int year,
  });

  // --- v45 原始金额偏差 ---------------------------------------------------
  //
  // 差异 = 原始侧 − 记账侧（[OriginalAmountBasis.recorded]）或反向
  // （[OriginalAmountBasis.original]）；未填写（物理 NULL）→ 回落同口径记账
  // 金额 → 差异 0，与「默认金额」语义一致，因此下列聚合天然把「未填写」
  // 当零偏差处理，无需另加兜底。
  //
  // [metric] 决定用原币还是本位币折算（后者原始侧按该笔隐含汇率缩放）；
  // 全部沿用 `exclude_from_stats = 0` 与半开区间 `[start, end)`，
  // 与 [totalsByDay] / [totalsByCategory] 可直接对账。

  /// 偏差汇总。
  ///
  /// [deviated] = 「原始金额 ≠ 记账金额」的明细数。未填写的明细在保存/
  /// 迁移时已兜底为记账金额（差异恒 0），所以它是"有偏差的明细数"，
  /// 而不是"用户手填过的明细数"。
  Future<({
    int total,
    int deviated,
    double diffSum,
    double absDiffSum,
    double maxAbsDiff,
  })> originalAmountDiffSummary({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
    required OriginalAmountMetric metric,
    required OriginalAmountBasis basis,
  });

  /// 偏差趋势。[granularity] 取 `'day' | 'month' | 'year'`，桶连续补零。
  /// [deviated] 同 [originalAmountDiffSummary] 的口径。
  Future<
      List<
          ({
            DateTime bucket,
            int deviated,
            double diffSum,
            double absDiffSum,
          })>> originalAmountDiffTrend({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
    required String granularity,
    required OriginalAmountMetric metric,
    required OriginalAmountBasis basis,
  });

  /// 偏差分类排行。名称/图标随 SQL 一并 LEFT JOIN 出来，调用方不必二次解析；
  /// 共享账本 Editor 行（category_id 为空）落到 [categoryId] == null。
  Future<
      List<
          ({
            int? categoryId,
            String? categoryName,
            String? categoryIcon,
            int deviated,
            double diffSum,
            double absDiffSum,
          })>> originalAmountDiffByCategory({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
    required OriginalAmountMetric metric,
    required OriginalAmountBasis basis,
  });

  /// 偏差账本排行（跨账本视角；[absDiffSum] 降序由调用方排）。
  Future<
      List<
          ({
            int ledgerId,
            int deviated,
            double diffSum,
            double absDiffSum,
          })>> originalAmountDiffByLedger({
    required String type,
    required DateTime start,
    required DateTime end,
    required OriginalAmountMetric metric,
    required OriginalAmountBasis basis,
  });

  /// B2(v47)：区间内带自定义字段值的交易原始行（按字段值的分组聚合在
  /// Dart 侧做 —— 值以 JSON 散落在行上，SQL 无 JSON1 依赖；行数受
  /// custom_values_json IS NOT NULL 过滤约束，绝大多数账本为 0 行）。
  /// 口径与既有统计一致：排除「不计收支」，金额取
  /// `COALESCE(native_amount, amount)`（本位币折算）。
  Future<List<({String type, double nativeAmount, String? customValuesJson})>>
      customFieldStatsRows({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  });
}
