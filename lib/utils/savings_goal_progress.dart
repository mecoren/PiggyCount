// 储蓄目标的进度解算（纯函数，便于单测）。
// 见 prd/savings_goal/requirements.md §4.2 / design.md §2。
//
// 刻意吃「已解算的 saved + target」而不是直接吃 SavingsGoal 行对象：账户模式
// 要把账户余额喂进来、手动模式喂 saved_amount，解算在调用方完成，这里只做
// 算术 —— 于是所有边界（目标 ≤ 0、账户透支、速度估算）都能穷举测到。

/// 单个目标的进度画像。
class SavingsGoalProgress {
  const SavingsGoalProgress({
    required this.saved,
    required this.target,
    required this.remaining,
    required this.rate,
    required this.achieved,
    this.dailyRate,
    this.estimatedDays,
    this.estimatedDate,
  });

  /// 已存金额（账户模式 = 账户余额；手动模式 = `saved_amount`）
  final double saved;

  /// 目标金额
  final double target;

  /// 剩余金额（已达成时为 0）
  final double remaining;

  /// 进度比，**已 clamp 到 [0, 1]**（仅供进度条宽度使用）；
  /// 已存文本不要用 `rate * target` 反推，会丢掉超额部分。
  final double rate;

  final bool achieved;

  /// 日均储蓄速度；无法估算（未起步 / 目标已达成 / 日期基准异常）时为 null。
  final double? dailyRate;
  final int? estimatedDays;
  final DateTime? estimatedDate;
}

/// 解算单个目标的进度。
///
/// [startDate] 是速度估算的基准日（目标起算日），[now] 可注入以便单测。
SavingsGoalProgress computeSavingsGoalProgress({
  required double saved,
  required double targetAmount,
  required DateTime startDate,
  DateTime? now,
}) {
  // 脏数据兜底：目标金额 ≤ 0 时进度恒 0 且**不判达成**，不产生 NaN / 除零。
  if (targetAmount <= 0) {
    return SavingsGoalProgress(
      saved: saved,
      target: targetAmount,
      remaining: 0,
      rate: 0,
      achieved: false,
    );
  }

  final nowValue = now ?? DateTime.now();
  final rate = (saved / targetAmount).clamp(0.0, 1.0);
  final achieved = saved >= targetAmount;
  // 账户透支（saved < 0）时「剩余」按目标全额展示：进度条已 clamp 到 0，若这里
  // 给出 `target - saved`（> target），UI 会出现「还差 1300 / 目标 1000」这种
  // 看起来像 bug 的展示（见 requirements §4.2 的边界口径）。
  final remaining = saved < 0
      ? targetAmount
      : (targetAmount - saved).clamp(0.0, double.infinity).toDouble();

  // 速度估算：账户透支（saved < 0）或尚未起步时无法估算。
  // 起算日落在未来（脏数据 / 时区回拨）时按 1 天兜底，避免负天数放大速度。
  final elapsedDays = nowValue.difference(startDate).inDays;
  final days = elapsedDays < 1 ? 1 : elapsedDays;
  final daily = saved > 0 ? saved / days : 0.0;

  double? dailyRate;
  int? estimatedDays;
  DateTime? estimatedDate;
  if (remaining > 0 && daily > 0) {
    dailyRate = daily;
    estimatedDays = (remaining / daily).ceil();
    estimatedDate = DateTime(nowValue.year, nowValue.month, nowValue.day)
        .add(Duration(days: estimatedDays));
  }

  return SavingsGoalProgress(
    saved: saved,
    target: targetAmount,
    remaining: remaining,
    rate: rate,
    achieved: achieved,
    dailyRate: dailyRate,
    estimatedDays: estimatedDays,
    estimatedDate: estimatedDate,
  );
}

/// 目标清单的汇总（仅账本本位币口径，见 requirements §4.3）。
class SavingsGoalSummary {
  const SavingsGoalSummary({
    required this.totalCount,
    required this.foreignCount,
    required this.totalTarget,
    required this.totalSaved,
  });

  /// 目标总数（含外币）
  final int totalCount;

  /// 未计入合计的外币目标数（UI 需给一行提示）
  final int foreignCount;

  final double totalTarget;
  final double totalSaved;
}

/// 汇总目标清单。
///
/// [items] 每项是「(目标金额, 已存金额, 币种, 进度来源账户)」——同样刻意不吃行
/// 对象，账户模式的已存由调用方先解算好。币种 ≠ 账本本位币的目标**只计数不计
/// 金额**：视图期没有可靠汇率，硬折会给出错误数字（沿用订阅视图同款口径）。
///
/// **总已存按账户去重**：账户模式下 `saved` 就是该账户的余额，多个目标盯同一个
/// 账户（「换手机」和「旅游」都挂在储蓄卡上）时那笔钱只有一份 —— 逐项相加会让
/// 合计虚高成余额的 N 倍。故 `accountId != null` 的项按账户**只计一次**（该账户
/// 首次出现时计入），[SavingsGoalSummary.totalSaved] 因此是「这些目标实际可用
/// 的攒钱总额」。手动模式（`accountId == null`，含账户被删后的悬空引用回退）逐项
/// 累加 —— 那是各目标独立记录的手动累计额，不存在重复。
///
/// [SavingsGoalSummary.totalTarget] 恒逐项累加：每个目标是独立诉求（存 1000 换
/// 手机 + 存 2000 去旅游 = 要攒 3000），目标金额不因共用一个账户而去重。
SavingsGoalSummary summarizeSavingsGoals(
  List<({double target, double saved, String currency, int? accountId})> items, {
  required String ledgerCurrency,
}) {
  final base = ledgerCurrency.trim().toUpperCase();
  var totalTarget = 0.0;
  var totalSaved = 0.0;
  var foreignCount = 0;
  // 已计入总已存的「进度来源账户」（账户模式去重）。
  final countedAccountIds = <int>{};

  for (final item in items) {
    if (item.currency.trim().toUpperCase() != base) {
      foreignCount++;
      continue;
    }
    totalTarget += item.target;

    final accountId = item.accountId;
    if (accountId != null && !countedAccountIds.add(accountId)) {
      // 同一账户的余额已在前面计过，跳过本次累加（目标额不受影响）。
      continue;
    }
    totalSaved += item.saved;
  }

  return SavingsGoalSummary(
    totalCount: items.length,
    foreignCount: foreignCount,
    totalTarget: totalTarget,
    totalSaved: totalSaved,
  );
}
