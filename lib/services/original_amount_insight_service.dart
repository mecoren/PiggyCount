import 'dart:math' as math;

import '../data/db.dart';
import '../data/models/transaction_original_amount.dart';

/// v45 原始金额偏差的严重程度。
enum OriginalAmountSeverity {
  /// 轻微：偏差率落在 [ratioFloor, 2 * ratioFloor)。
  slight,

  /// 明显：偏差率落在 [2 * ratioFloor, 1.0)。
  notable,

  /// 严重：偏差率 >= 1.0（偏差达到基准金额的一倍及以上）。
  severe,
}

/// v45 偏差原因码。
///
/// 刻意只给**码**不给文案：文案由 UI 层按 l10n 渲染，既保证多语言，
/// 也避免纯函数服务反向依赖 BuildContext。同一原因码在全应用文案一致。
enum OriginalAmountReasonCode {
  /// 偏差为正（记账基准下 = 原始高于记账）：疑似未记录优惠 / 折扣 / 抹零。
  aboveRecorded,

  /// 偏差为负（记账基准下 = 原始低于记账）：疑似追加费用（运费 / 服务费）
  /// 或事后补录。
  belowRecorded,

  /// 偏差率恰为整数倍：疑似单位或币种换算误差（分↔元、×100）。
  multipleOfRecorded,

  /// 同分类内高频出现偏差：疑似该分类的录入口径存在系统性偏差。
  categoryHabit,
}

/// 单笔偏差洞察结果（纯数据，无 UI / 存储依赖）。
///
/// 金额字段均为**所选口径下**的值（原币或本位币折算），见 [OriginalAmountMetric]。
class OriginalAmountInsight {
  final int transactionId;
  final OriginalAmountSeverity severity;
  final OriginalAmountReasonCode reasonCode;

  /// 记账金额（即"默认金额"），所选口径下。
  final double recordedAmount;

  /// 原始金额有效值，所选口径下（未填写时等于 [recordedAmount]）。
  final double originalAmount;

  /// 所选口径与基准下的差异（正负含义随基准翻转）。
  final double diff;

  /// [diff] 占基准金额的比率；基准金额为 0 时记 0。
  final double diffRate;

  const OriginalAmountInsight({
    required this.transactionId,
    required this.severity,
    required this.reasonCode,
    required this.recordedAmount,
    required this.originalAmount,
    required this.diff,
    required this.diffRate,
  });

  OriginalAmountInsight copyWith({OriginalAmountReasonCode? reasonCode}) {
    return OriginalAmountInsight(
      transactionId: transactionId,
      severity: severity,
      reasonCode: reasonCode ?? this.reasonCode,
      recordedAmount: recordedAmount,
      originalAmount: originalAmount,
      diff: diff,
      diffRate: diffRate,
    );
  }
}

/// v45 洞察规则引擎：纯函数、离线可解释、零外部依赖（不引入 AI / 网络）。
///
/// 触发条件：`|diff| >= max(absoluteFloor, ratioFloor * |基准金额|)`。
/// [defaultAbsoluteFloor] 用于滤掉小额噪声 —— 3 元与 3.6 元的 20% 偏差
/// 没有洞察价值，而不设下限会让小额明细淹没列表。
class OriginalAmountInsightService {
  const OriginalAmountInsightService._();

  /// 默认偏差率门槛（20%）。
  static const double defaultRatioFloor = 0.20;

  /// 默认绝对差值下限（滤除小额噪声）。
  static const double defaultAbsoluteFloor = 1.0;

  /// 同分类触发次数达到此值即归因为「该分类口径系统性偏差」。
  static const int categoryHabitMinHits = 3;

  /// 对一批明细产出偏差洞察，按 `|diff|` 倒序（最该看的排最前）。
  ///
  /// [metric] / [basis] 与统计层同源，保证「汇总看到的偏差」与
  /// 「洞察列出的明细」是同一套口径。
  ///
  /// 未填写原始金额的明细在保存/迁移时已兜底为记账金额，天然 `diff == 0`，
  /// 会被阈值过滤 —— 它们不是"偏差"，只是使用默认金额，属于正常状态。
  static List<OriginalAmountInsight> analyze(
    List<Transaction> transactions, {
    OriginalAmountMetric metric = OriginalAmountMetric.currency,
    OriginalAmountBasis basis = OriginalAmountBasis.recorded,
    double ratioFloor = defaultRatioFloor,
    double absoluteFloor = defaultAbsoluteFloor,
  }) {
    final drafts = <({OriginalAmountInsight insight, int? categoryId})>[];
    // 分类级命中计数：用于第二遍的系统性偏差归因。
    final hitsByCategory = <int, int>{};

    for (final t in transactions) {
      // 转账没有"票面金额 vs 实付金额"的语义，不参与偏差洞察。
      if (t.type == 'transfer') continue;

      final diff = t.diffOf(metric, basis);
      final absDiff = diff.abs();
      final base = t.diffBaseOf(metric, basis);
      final threshold = math.max(absoluteFloor, ratioFloor * base.abs());
      if (absDiff < threshold) continue;

      final rate = base == 0 ? 0.0 : diff / base;
      drafts.add((
        insight: OriginalAmountInsight(
          transactionId: t.id,
          severity: classify(rate, ratioFloor: ratioFloor),
          reasonCode: reasonFor(diff, rate),
          recordedAmount: t.recordedAmountOf(metric),
          originalAmount: t.originalAmountOf(metric),
          diff: diff,
          diffRate: rate,
        ),
        categoryId: t.categoryId,
      ));
      final cid = t.categoryId;
      if (cid != null) {
        hitsByCategory.update(cid, (v) => v + 1, ifAbsent: () => 1);
      }
    }

    return drafts
        .map((d) {
          final cid = d.categoryId;
          // 「未分类」(categoryId == null) 不参与归因：它不是一个真实的
          // 分类口径，归因成"该分类系统性偏差"没有可操作性。
          if (cid != null &&
              (hitsByCategory[cid] ?? 0) >= categoryHabitMinHits) {
            return d.insight.copyWith(
              reasonCode: OriginalAmountReasonCode.categoryHabit,
            );
          }
          return d.insight;
        })
        .toList()
      ..sort((a, b) => b.diff.abs().compareTo(a.diff.abs()));
  }

  /// 按偏差率分级。[ratioFloor] 为轻微档下界（默认 20%）。
  static OriginalAmountSeverity classify(
    double diffRate, {
    double ratioFloor = defaultRatioFloor,
  }) {
    final r = diffRate.abs();
    if (r >= 1.0) return OriginalAmountSeverity.severe;
    if (r >= 2 * ratioFloor) return OriginalAmountSeverity.notable;
    return OriginalAmountSeverity.slight;
  }

  /// 按规则映射原因码（按优先级从具体到笼统）。
  static OriginalAmountReasonCode reasonFor(double diff, double diffRate) {
    // 偏差率恰为整数倍（1×、2×…）→ 换算误差特征最明显，优先于方向性
    // 归因；±5% 容差吸收小数与四舍五入。
    final a = diffRate.abs();
    if (a >= 1 && (a - a.roundToDouble()).abs() <= 0.05) {
      return OriginalAmountReasonCode.multipleOfRecorded;
    }
    return diff > 0
        ? OriginalAmountReasonCode.aboveRecorded
        : OriginalAmountReasonCode.belowRecorded;
  }
}
