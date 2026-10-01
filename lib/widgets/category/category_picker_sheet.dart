import 'package:flutter/material.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import '../ui/piggy_header.dart';
import 'category_selector.dart';

/// 以底部抽屉弹出「分类选择子界面」，返回用户选中的分类（`null` = 取消）。
///
/// 定位：记账表单的**子界面** —— 独立于记账表单弹出，既不共享后者的
/// [ScrollController]（所以弹出、滚动、关闭都不会把记账界面顶高或收起来），
/// 关闭时也不影响记账表单的任何状态（金额、备注、标签、账户原地保留）。
///
/// 与 `showCategorySelector`（`widgets/biz/category_selector_dialog.dart`，
/// Dialog 形态、带搜索）刻意分开：那条路径服务搜索页 / 预算 / 周期交易，要的是
/// 「可搜索的大列表」；本条要的是「和分类网格同一套手感、随点随回」。
Future<Category?> showCategoryPickerSheet(
  BuildContext context, {
  required String kind,
  int? currentCategoryId,
}) {
  final l10n = AppLocalizations.of(context);
  final sheetBg = PiggyTokens.scaffoldBackground(context);
  return showModalBottomSheet<Category>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Material(
      // 必须用 Material 自身的 clipBehavior 裁剪，而不是 Container 的
      // decoration：decoration 只把背景画成圆角，**不裁剪子内容** ——
      // 标题栏自带的矩形背景会盖住顶部两角，看起来就是直角（实测踩过）。
      // 与记账抽屉本体（transaction_editor_page 的 quickEntrySheet）同口径。
      color: sheetBg,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(PiggyDimens.radiusXl),
      ),
      child: SizedBox(
        // 半屏：既装得下整屏网格，又始终露出下层记账界面（用户能看见自己
        // 并没有被"踢出"记账流程）。
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: Column(
          children: [
            PiggyTitleBar(
              title:
                  kind == 'income' ? l10n.categoryIncome : l10n.categoryExpense,
              showBack: true,
              backIcon: const Icon(Icons.close),
              onBack: () => Navigator.of(ctx).pop(),
              backgroundColor: sheetBg,
              compact: true,
            ),
            Expanded(
              child: CategorySelector(
                kind: kind,
                initialCategoryId: currentCategoryId,
                onCategorySelected: (c) => Navigator.of(ctx).pop(c),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
