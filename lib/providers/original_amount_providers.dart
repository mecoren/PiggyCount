import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/transaction_original_amount.dart';

/// v45 金额偏差计算的「金额口径」（原币 / 本位币折算）。
///
/// 分析页与账本明细列表角标共用同一来源 —— 页面上切了口径，列表标记
/// 立刻跟着变，避免"页面一套口径、列表另一套"的认知分裂。
///
/// ponytail: 会话内生效（StateProvider，未持久化）。需要跨启动记忆时，
/// 再接项目既有的 SharedPreferences 偏好范式即可，默认值保持不变。
final originalAmountMetricProvider =
    StateProvider<OriginalAmountMetric>((ref) => OriginalAmountMetric.currency);

/// v45 金额偏差计算的「差异基准」（以记账金额 / 以原始金额）。
final originalAmountBasisProvider =
    StateProvider<OriginalAmountBasis>((ref) => OriginalAmountBasis.recorded);
