import 'package:flutter/material.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../ui/picker_sheet.dart';
import 'category_selector.dart';

/// 以底部抽屉弹出「分类选择子界面」，返回用户选中的分类（`null` = 取消）。
///
/// 定位：记账表单的**子界面** —— 独立于记账表单弹出，既不共享后者的
/// [ScrollController]（所以弹出、滚动、关闭都不会把记账界面顶高或收起来），
/// 关闭时也不影响记账表单的任何状态（金额、备注、标签、账户原地保留）。
///
/// 外壳走项目选择器抽屉口径（[showPiggyPickerSheet] + [PiggyPickerSheet]）：
/// 悬浮卡片 + 顶栏「X / 标题」，不再自绘 Material + PiggyTitleBar 的平底弹层。
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
  return showPiggyPickerSheet<Category>(
    context,
    // 内容是可滚动分类列表 / 网格：滚到顶后继续下拉也能收抽屉。
    dragToDismiss: true,
    builder: (ctx) => PiggyPickerSheet(
      title: kind == 'income' ? l10n.categoryIncome : l10n.categoryExpense,
      // 半屏：既装得下整屏网格，又始终露出下层记账界面（用户能看见自己
      // 并没有被"踢出"记账流程）。
      maxHeight: MediaQuery.of(ctx).size.height * 0.7,
      child: CategorySelector(
        kind: kind,
        initialCategoryId: currentCategoryId,
        onCategorySelected: (c) => Navigator.of(ctx).pop(c),
      ),
    ),
  );
}
