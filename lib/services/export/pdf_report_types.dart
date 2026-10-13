/// PDF 报表的数据模型：**不含** `pdf` 包依赖，便于单测直接构造夹具。
///
/// 为什么单独一层：报表的取数（SQL）与排版（pdf 包）是两件容易各自出错的事。
/// 取数用 `test/services/pdf_report_service_test.dart` 钉在 Drift 内存库上，
/// 排版用 `test/services/pdf_report_document_test.dart` 拿手写夹具跑通；
/// 两边都只依赖这一层纯数据，不必为了测排版去搭数据库。
///
/// 统计口径全部沿用既有 SQL 聚合（`COALESCE(native_amount, amount)` +
/// `exclude_from_stats = 0` + 半开区间 `[start, end)`），与洞察页 / 区间报表页
/// **同源** —— 报表导出的数必须能跟界面上看到的对得上（报销 / 对账场景）。
library;

/// 一份报表的全部数据。
class PdfReportData {
  const PdfReportData({
    required this.ledgerName,
    required this.currencyCode,
    required this.start,
    required this.end,
    required this.income,
    required this.expense,
    required this.txCount,
    required this.expenseCategories,
    required this.incomeCategories,
    required this.buckets,
    required this.byMonth,
    required this.entries,
  });

  /// 账本名（报表头展示）。
  final String ledgerName;

  /// 账本本位币（ISO 大写）。金额按它展示，不逐笔区分原币。
  final String currencyCode;

  /// 半开区间 `[start, end)`，与统计 SQL 完全一致。
  final DateTime start;
  final DateTime end;

  /// 区间内收入 / 支出合计（转账两侧都不计入，与首页/洞察页一致）。
  final double income;
  final double expense;

  /// 收支笔数（income + expense，不含转账）。
  final int txCount;

  /// 支出 / 收入一级分类排行（已按金额降序、已并「其他」）。
  final List<PdfReportCategory> expenseCategories;
  final List<PdfReportCategory> incomeCategories;

  /// 趋势桶。区间 ≤ [PdfReportService.dayBucketLimit] 天是日桶，否则月桶。
  final List<PdfReportBucket> buckets;

  /// [buckets] 是否为月桶（决定 x 轴标签格式与标题用词）。
  final bool byMonth;

  /// 明细（按时间**升序**，与账单核对顺序一致）。含转账。
  final List<PdfReportEntry> entries;

  /// 结余 = 收入 − 支出。
  double get balance => income - expense;

  /// 区间天数（半开区间本身就是天数）。至少 1，避免除零。
  int get days {
    final d = end.difference(start).inDays;
    return d <= 0 ? 1 : d;
  }

  /// 日均支出。区间为 0 天也不会除零。
  double get dailyAvgExpense => expense / days;
}

/// 分类排行的一行（一级分类口径，二级金额已并进父分类）。
class PdfReportCategory {
  const PdfReportCategory({
    required this.name,
    required this.total,
    required this.count,
  });

  final String name;
  final double total;
  final int count;
}

/// 趋势桶（日或月），收入与支出各一列。
class PdfReportBucket {
  const PdfReportBucket({
    required this.bucket,
    required this.income,
    required this.expense,
  });

  final DateTime bucket;
  final double income;
  final double expense;
}

/// 明细表的一行。
class PdfReportEntry {
  const PdfReportEntry({
    required this.at,
    required this.type,
    required this.amount,
    this.categoryName,
    this.accountName,
    this.note,
  });

  final DateTime at;

  /// `'expense' | 'income' | 'transfer'`，展示名走
  /// `ledgerCsvTypeLabel`（与 CSV 导出的类型列同一处文案）。
  final String type;

  /// 本位币金额（`native_amount ?? amount`），与合计口径一致。
  final double amount;

  final String? categoryName;
  final String? accountName;
  final String? note;
}
