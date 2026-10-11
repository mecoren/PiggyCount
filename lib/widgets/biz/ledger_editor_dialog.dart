/// 账本编辑弹窗（名称 / 本位币 / 每月起始日）与「编辑并保存」完整流程。
///
/// 从 `ledgers_page_new.dart` 的私有方法提取为公共函数，供两处共用：
/// - 账本页长按「编辑」（任意账本）；
/// - 我的页「账本设置」分区「账本信息」（当前账本）。
/// [editLedgerInfo] 承载保存全流程（本位币变更确认 + nativeAmount 重算 +
/// 刷新信号 + 同步 + 小组件刷新），两个入口行为完全一致，避免币种变更
/// 从新入口保存时绕过重算造成存量交易折算口径错乱。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../services/billing/post_processor.dart';
import '../../services/system/logger_service.dart';
import '../../styles/tokens.dart';
import '../../utils/currencies.dart';
import '../../widget/widget_manager.dart';
import '../currency/currency_picker_sheet.dart';
import '../ui/ui.dart';
import 'day_of_month_picker.dart';

/// 弹出账本编辑对话框；用户取消返回 null。
///
/// [title] 缺省为「编辑账本」文案（创建入口需显式传「新建账本」）。
/// [primaryColor] 由调用方传入（币种选择器高亮用），widget 层不读 provider。
Future<({String name, String currency, int monthStartDay})?>
    showLedgerEditorDialog(
  BuildContext context, {
  required Color primaryColor,
  String? title,
  String? initialName,
  String? initialCurrency,
  int? initialMonthStartDay,
}) async {
  String currency = initialCurrency ?? 'CNY';
  int monthStartDay = initialMonthStartDay ?? 1;
  final nameCtrl = TextEditingController(text: initialName ?? '');

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setState) {
        // 外壳走项目弹窗语言（[AppDialogShell]）：居中标题 + 表单内容 +
        // 底部分栏动作区；不再自绘 Dialog(surfaceElevated + radiusXl) + Padding。
        return AppDialogShell(
          title: Text(title ?? AppLocalizations.of(ctx).ledgersEdit),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: piggyOutlinedDecoration(
                  ctx,
                  label: AppLocalizations.of(ctx).ledgersName,
                ),
              ),
              const SizedBox(height: PiggyDimens.p12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                // v30 语义升级:账本 currency = 「账本本位币」(统计折算目标),
                // 与资产页的用户级「主币种」是两个概念,label 用本位币避免混淆。
                title: Text(AppLocalizations.of(ctx).ledgerBaseCurrencyLabel),
                subtitle: Text(displayCurrency(currency, context)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  // 币种选择器（统一走共用币种抽屉：国旗 + 选中高亮 + 搜索）
                  final picked = await showCurrencyPickerSheet(
                    ctx,
                    selected: currency,
                    primaryColor: primaryColor,
                    title: AppLocalizations.of(ctx).ledgersSelectCurrency,
                  );
                  if (picked != null) {
                    setState(() => currency = picked);
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(AppLocalizations.of(ctx).ledgersMonthStartDay),
                subtitle: Text(monthStartDay <= 1
                    ? AppLocalizations.of(ctx).ledgersMonthStartDayNatural
                    : AppLocalizations.of(ctx)
                        .ledgersMonthStartDayValue(monthStartDay)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  // 28 宫格月起始日选择器（复用共用 1~N 日网格抽屉）
                  final picked = await showDayOfMonthPickerSheet(
                    ctx,
                    title: AppLocalizations.of(ctx).ledgersMonthStartDay,
                    hint: AppLocalizations.of(ctx).ledgersMonthStartDayHint,
                    selected: monthStartDay,
                  );
                  if (picked != null) {
                    setState(() => monthStartDay = picked);
                  }
                },
              ),
            ],
          ),
          // 底部按钮与确认框同一语言：取消｜保存分栏（保存=主题色）。
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppLocalizations.of(ctx).commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                title == AppLocalizations.of(ctx).ledgersNew
                    ? AppLocalizations.of(ctx).ledgersCreate
                    : AppLocalizations.of(ctx).commonSave,
              ),
            ),
          ],
        );
      });
    },
  );

  if (ok == true && nameCtrl.text.trim().isNotEmpty) {
    return (
      name: nameCtrl.text.trim(),
      currency: currency,
      monthStartDay: monthStartDay
    );
  }

  return null;
}

/// 编辑指定账本并落库的完整流程（弹窗 → 本位币变更确认 → 保存 → 重算 →
/// 刷新 → 同步 → 小组件刷新）。
///
/// [context] 必须传**调用页面的稳定 context**（如 ConsumerState 的
/// `this.context`）：菜单/弹层携带的 context 可能随入口弹层销毁而被吞掉
/// 后续流程（原账本页注释同口径）。
Future<void> editLedgerInfo(
  BuildContext context,
  WidgetRef ref, {
  required int ledgerId,
}) async {
  final repo = ref.read(repositoryProvider);
  final ledgerData = await repo.getLedgerById(ledgerId);

  if (ledgerData == null || !context.mounted) return;

  final result = await showLedgerEditorDialog(
    context,
    primaryColor: ref.read(primaryColorProvider),
    title: AppLocalizations.of(context).ledgersEdit,
    initialName: ledgerData.name,
    initialCurrency: ledgerData.currency,
    initialMonthStartDay: ledgerData.monthStartDay,
  );

  if (result == null || !context.mounted) return;

  // v30 本位币变更:存量交易的 nativeAmount 快照是按旧本位币算的,需按新
  // 本位币全量重算(边界 5,.docs/multi-currency-ledger 02 §八)。先确认再改。
  final currencyChanged =
      result.currency.toUpperCase() != ledgerData.currency.toUpperCase();
  if (currencyChanged) {
    final stats = await repo.getLedgerStats(ledgerId: ledgerId);
    final txCount = stats.transactionCount;
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AppDialogShell(
        title: Text(l10n.ledgerBaseCurrencyLabel),
        content: Text(
          '${l10n.ledgerCurrencyChangeRecalcHint}\n'
          '${l10n.recalcSyncCountHint(txCount)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(AppLocalizations.of(dctx).commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(AppLocalizations.of(dctx).commonConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }

  await repo.updateLedger(
    id: ledgerId,
    name: result.name.trim(),
    currency: result.currency,
    monthStartDay: result.monthStartDay,
  );

  if (currencyChanged) {
    // 先强制拉一次「以新主币种为 base」的汇率:改币种瞬间本地通常还没有
    // 这一组(汇率按本位币基准存),不拉的话重算会因缺汇率整体跳过
    // (反馈17:CNY→JPY 后旧交易折算不动)。extraQuotes 带上账本实际涉及
    // 的全部外币(无账户币种不在 usedCurrencies 里)。拉取失败也继续——
    // 缺汇率的笔退化 =amount,由 L11 横幅兜底,绝不保留旧口径错值。
    final foreign = await repo.getLedgerForeignCurrencies(ledgerId);
    await refreshExchangeRatesFromUi(ref,
        force: true,
        extraQuotes: {...foreign, ledgerData.currency.toUpperCase()});
    // 全量重算(逐笔记 change,L13);缺汇率的笔留待 L11 横幅
    final n =
        await repo.recalcNativeAmountsForLedger(ledgerId, result.currency);
    if (context.mounted && n > 0) {
      showToast(
          context, AppLocalizations.of(context).recalcForeignTxDone(n));
    }
  }

  // 刷新信号必须在 sync 之前发(反馈19):改主币种重算产生几百条 change,
  // push 可能耗时数十秒甚至失败,原先信号排在 await sync 之后导致首页/
  // 账本页统计长时间(或永远)显示旧数据。本地数据此刻已就绪,立即刷新。
  ref.read(ledgerListRefreshProvider.notifier).state++;
  // currentLedgerProvider 已是 StreamProvider(Drift watch 自动推送),
  // 此 invalidate 仅作防御性重订阅(如流曾进入 error 态),正常路径冗余无害。
  ref.invalidate(currentLedgerProvider);
  ref.read(statsRefreshProvider.notifier).state++;
  ref.read(budgetRefreshProvider.notifier).state++;

  // 修改账本元数据后,触发同步以更新云端(本地非 tx 写入不会自动 push)。
  // 放刷新信号之后:UI 不等 push 完成;失败也不影响本地展示(下次同步兜底)。
  try {
    await PostProcessor.sync(ref, ledgerId: ledgerId);
  } catch (e) {
    logger.warning(
        'LedgerEditor', '改账本元数据后同步失败(本地已生效,下次同步重试): $e');
  }

  // 起始日影响小部件「本月」口径,立即刷新
  try {
    final repository = ref.read(repositoryProvider);
    final colorScheme = ref.read(incomeExpenseColorSchemeProvider);
    // 没有 BuildContext,靠 languageProvider 还原当前 App 语言(见
    // widget_manager.dart resolveWidgetLocalizations 文档)。
    await WidgetManager().updateAllWidgetsLocalized(
      repository,
      ledgerId,
      ref.read(primaryColorProvider),
      explicitLocale: ref.read(languageProvider),
      colorScheme: colorScheme,
      baseCurrency: ref.read(baseCurrencyProvider),
    );
  } catch (e) {
    logger.warning('LedgerEditor', '改账本起始日后刷新小组件失败', e);
  }
}
