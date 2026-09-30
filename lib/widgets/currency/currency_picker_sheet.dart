import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/currencies.dart';
import 'currency_flag.dart';
import '../ui/ui.dart';

/// 币种选择 bottom sheet(搜索 + 国旗 + 汇率 + 选中勾)。返回选中的 code,取消返回 null。
///
/// 从 exchange_rate_page._pickBaseCurrency 抽出,汇率页 / 个性化页 / 记账弹窗共用。
/// [rateBase] 传入(大写 ISO)时,每行右侧展示「1 该币种 ≈ x rateBase」的汇率
/// (弹窗内拉一次全量,缺失显示占位)。
Future<String?> showCurrencyPickerSheet(
  BuildContext context, {
  required String selected,
  required Color primaryColor,
  String? title,
  String? rateBase,
}) {
  final current = selected.toUpperCase();
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    // 卡片由 builder 内的 Material 自绘（四角圆角 + 四周留间距），
    // 弹层底本身透明。
    backgroundColor: Colors.transparent,
    builder: (bctx) {
      String query = '';
      final sheetTitle = title ?? AppLocalizations.of(bctx).baseCurrencyLabel;
      // 常用币种置顶(kCommonCurrencyCodes 顺序),其余按地区原顺序。
      // 有序列表只构建一次,不随每次按键重建(输入法卡顿根因:每个字符
      // 都 getCurrencies + 多次 where 全量扫描 + 重新 toList)。
      final List<CurrencyInfo> ordered = () {
        final allCur = getCurrencies(bctx);
        final list = <CurrencyInfo>[];
        for (final code in kCommonCurrencyCodes) {
          for (final c in allCur) {
            if (c.code == code) {
              list.add(c);
              break;
            }
          }
        }
        list.addAll(
            allCur.where((c) => !kCommonCurrencyCodes.contains(c.code)));
        return list;
      }();
      return StatefulBuilder(builder: (sctx, setSheetState) {
        // 仅重算过滤结果(轻量),排序已缓存。
        final filtered = ordered.where((c) {
          final q = query.trim();
          if (q.isEmpty) return true;
          final uq = q.toUpperCase();
          return c.code.contains(uq) || c.name.contains(q);
        }).toList();

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              PiggyDimens.p16,
              0,
              PiggyDimens.p16,
              PiggyDimens.p16,
            ),
            // 透明路由底不提供 Material 祖先，TextField / ListTile
            // 必须显式包 Material。
            child: Material(
              color: PiggyTokens.surfaceElevated(bctx),
              borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
              clipBehavior: Clip.antiAlias,
              child: KeyboardBottomInsetPadding(
                extra: 16,
                child: SizedBox(
                  height: 440,
                  child: Column(
                    children: [
                      // 标题区：小号居中、次级色，与选项抽屉同口径。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          PiggyDimens.p16,
                          PiggyDimens.p16,
                          PiggyDimens.p16,
                          PiggyDimens.p12,
                        ),
                        child: Text(
                          sheetTitle,
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(bctx).textTheme.labelLarge?.copyWith(
                                    color: PiggyTokens.textSecondary(bctx),
                                  ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: PiggyDimens.p16),
                        child: TextField(
                          decoration: piggyFilledDecoration(
                            bctx,
                            hint:
                                AppLocalizations.of(bctx).ledgersSearchCurrency,
                          ),
                          onChanged: (v) => setSheetState(() => query = v),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Expanded(
                        // 汇率展示:rateBase 传入时用 Consumer 拿全量汇率;否则空 map。
                        child: Consumer(builder: (cctx, ref, _) {
                          final rates = rateBase == null
                              ? const <String, double>{}
                              : (ref
                                      .watch(currencyPickerRatesProvider(
                                          rateBase.toUpperCase()))
                                      .valueOrNull ??
                                  const <String, double>{});
                          return ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final c = filtered[i];
                              final sel = c.code == current;
                              // 汇率行:1 该币种 ≈ x rateBase(base 自身/缺失不显示)
                              String? rateText;
                              if (rateBase != null &&
                                  c.code != rateBase.toUpperCase()) {
                                final r = rates[c.code];
                                if (r != null) {
                                  rateText =
                                      '1 ${c.code} ≈ ${r.toStringAsPrecision(4)} ${rateBase.toUpperCase()}';
                                }
                              }
                              return ListTile(
                                leading: currencyFlag(cctx, c.code),
                                title: Text(
                                  '${c.name} (${c.code})',
                                  style: TextStyle(
                                    color: sel
                                        ? primaryColor
                                        : PiggyTokens.textPrimary(bctx),
                                    fontWeight: sel
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                                subtitle: rateText == null
                                    ? null
                                    : Text(
                                        rateText,
                                        style: PiggyTextTokens.caption(cctx),
                                      ),
                                trailing: sel
                                    ? Icon(Icons.check, color: primaryColor)
                                    : null,
                                onTap: () => Navigator.pop(bctx, c.code),
                              );
                            },
                          );
                        }),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      });
    },
  );
}

/// 应用主币种选择:同值跳过 / set provider / 已有手动汇率提示 / force 重拉自动汇率。
///
/// 汇率页与个性化页共用 —— 选完后统一走这条收尾逻辑。mounted 守卫照旧。
/// 审计 U15/U4：force 重拉汇率可达数秒，进行中忽略重复触发，
/// 防止用户连选多个币种造成并发刷新互相覆盖。
bool _applyBaseCurrencyBusy = false;
Future<void> applyBaseCurrencySelection(
  BuildContext context,
  WidgetRef ref,
  String code,
) async {
  final l10n = AppLocalizations.of(context);
  final current = ref.read(baseCurrencyProvider).toUpperCase();
  final next = code.toUpperCase();
  if (next == current) return;
  if (_applyBaseCurrencyBusy) {
    // 复用「刷新中」文案提示进行中（审计 U15）
    showToast(context, l10n.mineUploadRefreshing);
    return;
  }

  ref.read(baseCurrencyProvider.notifier).state = next;
  // 新主币种若已有手动汇率,提示并立即生效;随后 force 重拉自动汇率。
  final repo = ref.read(repositoryProvider);
  _applyBaseCurrencyBusy = true;
  try {
    final overrides = await repo.getOverrides(next);
    if (!context.mounted) return;
    if (overrides.isNotEmpty) {
      showToast(context, l10n.rateManualApplied(overrides.length));
    }
    await refreshExchangeRatesFromUi(ref, force: true);
  } finally {
    _applyBaseCurrencyBusy = false;
  }
}
