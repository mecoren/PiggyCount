import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/budget_repository.dart';
import '../../../services/data/category_service.dart';
import '../../../styles/tokens.dart';
import '../../../utils/ui_scale_extensions.dart';
import '../../../widgets/category_icon.dart';
import 'budget_progress_bar.dart';

/// 分类预算条目组件
class CategoryBudgetTile extends ConsumerWidget {
  final CategoryBudgetUsage usage;
  final String currencySymbol;
  final VoidCallback? onTap;

  const CategoryBudgetTile({
    required this.usage,
    this.currencySymbol = '¥',
    this.onTap,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budget = usage.usage;
    final statusColor = _getStatusColor(context, budget.status);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: 12.0.scaled(context, ref),
          horizontal: 4.0.scaled(context, ref),
        ),
        child: Row(
          children: [
            // 分类图标 —— 优先用 CategoryIconWidget(支持 iconType='custom' 的
            // 上传图片);Category 缺失(老数据 / 云端模式)才回退到 switch 拿
            // Material icon。
            Container(
              width: 36.0.scaled(context, ref),
              height: 36.0.scaled(context, ref),
              decoration: BoxDecoration(
                color: PiggyTokens.primary(context).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(PiggyDimens.radiusSm.scaled(context, ref)),
              ),
              alignment: Alignment.center,
              child: usage.category != null
                  ? CategoryIconWidget(
                      category: usage.category,
                      size: 20.0.scaled(context, ref),
                      color: PiggyTokens.primary(context),
                    )
                  : Icon(
                      CategoryService.getCategoryIcon(usage.categoryIcon),
                      size: 20.0.scaled(context, ref),
                      color: PiggyTokens.primary(context),
                    ),
            ),
            SizedBox(width: 12.0.scaled(context, ref)),
            // 分类信息和进度
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        usage.categoryName,
                        style: TextStyle(
                          fontSize: PiggyTextTokens.fs14,
                          fontWeight: FontWeight.w500,
                          color: PiggyTokens.textPrimary(context),
                        ),
                      ),
                      Text(
                        '${(budget.rate * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: PiggyTextTokens.fs14,
                          fontWeight: FontWeight.w600,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8.0.scaled(context, ref)),
                  BudgetProgressBar(
                    used: budget.used,
                    budget: budget.budget,
                    showLabel: true,
                    height: 6,
                    currencySymbol: currencySymbol,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(BuildContext context, String status) {
    switch (status) {
      case 'exceeded':
        return PiggyTokens.error(context);
      case 'danger':
        return PiggyTokens.error(context);
      case 'warning':
        return PiggyTokens.warning(context);
      default:
        return PiggyTokens.success(context);
    }
  }
}
