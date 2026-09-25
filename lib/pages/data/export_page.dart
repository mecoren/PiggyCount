import 'dart:io';
import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import 'package:intl/intl.dart';
import '../../providers.dart';
import '../../data/repositories/base_repository.dart';
import '../../data/db.dart';
import '../../widgets/ui/ui.dart';
import '../../services/export/ledger_csv.dart';
import '../../styles/tokens.dart';

import '../../utils/platform_info.dart';

class ExportPage extends ConsumerStatefulWidget {
  const ExportPage({super.key});
  @override
  ConsumerState<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends ConsumerState<ExportPage> {
  bool exporting = false;
  double progress = 0;
  String? savedPath;

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: AppLocalizations.of(context).exportTitle,
        showBack: true,
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AppLocalizations.of(context).exportDescription),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed:
                          exporting ? null : () => _export(repo, ledgerId),
                      icon: const Icon(Icons.save_alt_outlined),
                      label: Text(PlatformInfo.isIOS
                          ? AppLocalizations.of(context).exportButtonIOS
                          : AppLocalizations.of(context).exportButtonAndroid),
                    ),
                    const SizedBox(height: 16),
                    if (exporting)
                      Row(
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: LinearProgressIndicator(
                                value: progress == 0 ? null : progress),
                          ),
                        ],
                      ),
                    if (savedPath != null) ...[
                      const SizedBox(height: 12),
                      Text(AppLocalizations.of(context)
                          .exportSavedTo(savedPath!)),
                    ],
                  ],
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  Future<void> _export(BaseRepository repo, int ledgerId) async {
    // 在首个 await 前获取本地化实例,避免 async gap 后使用 BuildContext
    final l10n = AppLocalizations.of(context);
    try {
      setState(() {
        exporting = true;
        progress = 0;
        savedPath = null;
      });
      String directory;
      bool shareAfter = false;
      if (PlatformInfo.isIOS) {
        // iOS: 写入应用文档目录，然后使用系统分享
        final docDir = await getApplicationDocumentsDirectory();
        directory = docDir.path;
        shareAfter = true;
      } else {
        // Android: 直接保存到公共 Download/PiggyCount 目录
        const downloadPath = '/storage/emulated/0/Download/PiggyCount';
        final dir = Directory(downloadPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        directory = downloadPath;
      }

      // 获取交易和分类数据
      final transactionsWithCategory =
          await repo.transactionsWithCategoryAll(ledgerId: ledgerId).first;
      final total = transactionsWithCategory.length;
      // 表头与数据行都由 services/export/ledger_csv 唯一构造（列序对齐可单测）
      final rows = <List<dynamic>>[ledgerCsvHeaders(l10n)];

      // 批量获取所有交易的标签
      final transactionIds =
          transactionsWithCategory.map((tx) => tx.t.id).toList();
      final tagsMap = await repo.getTagsForTransactions(transactionIds);

      // 批量获取所有交易的附件
      final attachmentsMap =
          await repo.getAttachmentsForTransactions(transactionIds);

      // v46 自定义字段：定义（按 sortOrder）用于把交易上的值翻译成用户看得懂
      // 的字段名；值批量取一次，避免逐条查询（N+1）。
      final customFieldDefs = await repo.getDefinitionsForLedger(ledgerId);
      final customValuesMap = customFieldDefs.isEmpty
          ? const <int, Map<String, dynamic>>{}
          : await repo.getValuesForTransactions(transactionIds);

      // 缓存所有账户信息，避免重复查询
      final allAccounts = await repo.getAllAccounts();
      final accountMap = {for (var acc in allAccounts) acc.id: acc};

      // v30 多币种:账本本位币(currencyCode 为 NULL 的历史行按账户/本位币兜底,
      // 与统计读取端同语义 —— 导出自包含,回导不丢币种)
      final ledgerData = await repo.getLedgerById(ledgerId);
      final ledgerBase = ((ledgerData?.currency.isNotEmpty ?? false)
              ? ledgerData!.currency
              : 'CNY')
          .toUpperCase();

      // 缓存所有分类信息（包括父分类）
      final incomeCategories = await repo.getTopLevelCategories('income');
      final expenseCategories = await repo.getTopLevelCategories('expense');
      final allCategories = <int, Category>{};
      for (final cat in [...incomeCategories, ...expenseCategories]) {
        allCategories[cat.id] = cat;
        // 获取子分类
        final subCategories = await repo.getSubCategories(cat.id);
        for (final subCat in subCategories) {
          allCategories[subCat.id] = subCat;
        }
      }

      // await 后校验 mounted,后续循环中会将 context 传给工具方法
      if (!mounted) return;

      for (int i = 0; i < transactionsWithCategory.length; i++) {
        final txWithCat = transactionsWithCategory[i];
        final t = txWithCat.t;
        rows.add(buildLedgerCsvRow(
          l10n: l10n,
          tx: t,
          category: txWithCat.category,
          // 转账时 account 即转出账户（账户名与币种兜底都用它）
          account: t.accountId != null ? accountMap[t.accountId] : null,
          toAccount: accountMap[t.toAccountId],
          allCategories: allCategories,
          tagNames:
              (tagsMap[t.id] ?? const []).map((tag) => tag.name).toList(),
          attachmentFileNames: (attachmentsMap[t.id] ?? const [])
              .map((att) => att.fileName)
              .toList(),
          customFieldDefinitions: customFieldDefs,
          customValues: customValuesMap[t.id],
          ledgerBaseCurrency: ledgerBase,
        ));
        if (i % 50 == 0) {
          setState(() => progress = (i + 1) / (total == 0 ? 1 : total));
        }
      }

      final csvStr = const ListToCsvConverter(eol: '\n').convert(rows);
      final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final path = p.join(directory, 'piggycount_$ts.csv');

      // 添加UTF-8 BOM标记，确保Excel正确识别中文编码
      const utf8Bom = '\uFEFF';
      await File(path).writeAsString(utf8Bom + csvStr,
          encoding: Encoding.getByName('utf-8')!);
      setState(() {
        savedPath = path;
        exporting = false;
        progress = 1;
      });
      if (!mounted) return;
      final l10nDialog = AppLocalizations.of(context);
      if (shareAfter) {
        // 触发分享面板
        await SharePlus.instance.share(ShareParams(
            files: [XFile(path)], text: l10nDialog.exportShareText));
        // 分享面板关闭后再校验,页面已销毁则不再弹成功提示
        if (!mounted) return;
        await AppDialog.info(context,
            title: l10nDialog.exportSuccessTitle,
            message: l10nDialog.exportSuccessMessageIOS(path));
      } else {
        await AppDialog.info(context,
            title: l10nDialog.exportSuccessTitle,
            message: l10nDialog.exportSuccessMessageAndroid(path));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => exporting = false);
      final l10nError = AppLocalizations.of(context);
      await AppDialog.error(context,
          title: l10nError.exportFailedTitle, message: e.toString());
    }
  }
}
