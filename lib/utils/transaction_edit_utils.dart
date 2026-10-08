import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/db.dart';
import '../pages/transaction/transaction_editor_page.dart';
import '../providers/database_providers.dart';

class TransactionEditUtils {
  static Future<void> editTransaction(
    BuildContext context,
    WidgetRef ref,
    Transaction transaction,
    Category? category,
  ) async {
    // 获取交易关联的标签
    final repo = ref.read(repositoryProvider);
    final tags = await repo.getTagsForTransaction(transaction.id);
    final tagIds = <int>[for (final t in tags) t.id];

    // v46 自定义字段:编辑前读一次该笔已存值用于表单回显。
    // 读的是交易行上的值本身(不依赖定义表),所以即使字段定义尚未从其他设备
    // 同步下来,这里拿到的已有值也不会因为「定义看不见」而被清掉。
    final customValues = await repo.getValuesForTransaction(transaction.id);

    if (!context.mounted) return;

    // 所有类型（收入/支出/转账）都以底部抽屉形式弹出交易编辑器，
    // 与新建记账保持一致的交互体验。
    // quickMode: true 恒定（不受「快捷记账模式」设置开关控制）：编辑的第一屏
    // 就该是这笔交易的金额表单，分类是要点击分类位才弹出的子界面 —— 与
    // FAB「记一笔」的新形态完全一致；开关只决定「记一笔」的进入方式。
    await showTransactionFormBottomSheet(
      context,
      initialKind: transaction.type, // 'expense', 'income', 或 'transfer'
      quickAdd: true,
      quickMode: true,
      initialCategoryId: transaction.categoryId,
      initialAmount: transaction.amount,
      initialDate: transaction.happenedAt,
      initialNote: transaction.note,
      editingTransactionId: transaction.id,
      initialAccountId: transaction.accountId,
      // 转账特有的参数
      initialToAccountId: transaction.toAccountId,
      // 标签
      initialTagIds: tagIds,
      // 账单标记（不计入收支/预算）回显
      initialExcludeFromStats: transaction.excludeFromStats,
      initialExcludeFromBudget: transaction.excludeFromBudget,
      // v30 多币种:编辑外币交易时汇率行按隐含汇率回显
      initialCurrencyCode: transaction.currencyCode,
      initialNativeAmount: transaction.nativeAmount,
      // v45 原始金额回显(未填写 → null,输入框留空)
      initialOriginalAmount: transaction.originalAmount,
      // v46 自定义字段回显(fieldSyncId → value)
      initialCustomValues: customValues,
    );
  }
}
