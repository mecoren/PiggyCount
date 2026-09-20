import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../services/billing/post_processor.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';

/// v44 回收站（F1）：软删除的交易列在这里，可恢复或就地彻底删除。
///
/// 为什么做成页面、而不是"删除时给一条撤销"：本 app 的通知原语是覆盖层
/// Toast（`lib/widgets/ui/toast.dart`，不占布局、无 action 位，且
/// `IgnorePointer` 会吞掉点击），加 action 要动全局组件；而删除入口有 4 个
/// （首页滑动、分类详情、标签详情、搜索批量），只给其中一个配撤销反而更不
/// 一致。回收站对 4 个入口一律兜底。
///
/// 回收站**只在本机**：归档行不进快照（`transactions_json` 只导
/// transactions 表），所以它既不上云也不进备份。对端要感知这笔删除，走的
/// 仍是原本那条路——本地有/云端无的 diff 项，且按 SYNC-05 默认不勾选。
class RecycleBinPage extends ConsumerStatefulWidget {
  const RecycleBinPage({super.key});

  @override
  ConsumerState<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends ConsumerState<RecycleBinPage> {
  static final _ts = DateFormat('yyyy-MM-dd HH:mm');
  late Future<_BinData> _data = _load();

  Future<_BinData> _load() async {
    final repo = ref.read(repositoryProvider);
    final rows = await repo.getDeletedTransactions();
    final ledgers = await repo.getAllLedgers();
    // payload 解码一次就好：滚动列表每帧重建时再 jsonDecode 是纯浪费。
    final txs = <int, Transaction>{
      for (final r in rows)
        r.txId:
            Transaction.fromJson(jsonDecode(r.payload) as Map<String, dynamic>),
    };
    return _BinData(
      rows,
      txs,
      {for (final l in ledgers) l.id: l.name},
    );
  }

  /// 与首页删除走同一套刷新口径：计数 / 统计 / 预算 / 同步标记。
  void _refreshLedger(int ledgerId) {
    ref.invalidate(countsForLedgerProvider(ledgerId));
    ref.read(statsRefreshProvider.notifier).state++;
    ref.read(budgetRefreshProvider.notifier).state++;
    PostProcessor.sync(ref, ledgerId: ledgerId);
  }

  Future<void> _restore(DeletedTransaction row) async {
    final repo = ref.read(repositoryProvider);
    final l10n = AppLocalizations.of(context);
    final ok = await repo.restoreDeletedTransaction(row.txId);
    if (!mounted) return;
    if (!ok) {
      // 原 id 已被占用：标签/附件是按那个 id 挂着的，换个 id 落回去等于
      // 把它们丢在原地，所以底层直接拒绝，这里如实告知。
      showToast(context, l10n.recycleBinRestoreConflict);
      return;
    }
    _refreshLedger(row.ledgerId);
    showToast(context, l10n.recycleBinRestored);
    setState(() => _data = _load());
  }

  Future<void> _purge(DeletedTransaction row) async {
    final l10n = AppLocalizations.of(context);
    final ok = await AppDialog.confirm<bool>(
          context,
          title: l10n.recycleBinPurge,
          message: l10n.recycleBinPurgeConfirm,
        ) ??
        false;
    if (!ok || !mounted) return;
    await ref.read(repositoryProvider).purgeDeletedTransaction(row.txId);
    if (!mounted) return;
    _refreshLedger(row.ledgerId);
    setState(() => _data = _load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.recycleBin,
        subtitle: l10n.recycleBinSubtitle,
        showBack: true,
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 80,
        ),
        child: FutureBuilder<_BinData>(
          future: _data,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('${l10n.commonError}: ${snap.error}',
                      textAlign: TextAlign.center),
                ),
              );
            }
            final data = snap.data!;
            final rows = data.rows;
            if (rows.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline,
                          size: 64.0.scaled(context, ref),
                          color: PiggyTokens.textTertiary(context)),
                      SizedBox(height: 16.0.scaled(context, ref)),
                      Text(l10n.recycleBinEmpty,
                          style: TextStyle(
                              color: PiggyTokens.textSecondary(context))),
                    ],
                  ),
                ),
              );
            }
            return ListView.builder(
              padding: EdgeInsets.symmetric(
                horizontal: 12.0.scaled(context, ref),
                vertical: 8.0.scaled(context, ref),
              ),
              itemCount: rows.length,
              itemBuilder: (context, i) => _tile(context, l10n, rows[i], data),
            );
          },
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, AppLocalizations l10n,
      DeletedTransaction row, _BinData data) {
    final tx = data.txs[row.txId]!;
    final isExpense = tx.type == 'expense';
    final isTransfer = tx.type == 'transfer';
    final ledgerName = data.ledgerNames[row.ledgerId] ?? '#${row.ledgerId}';
    return SectionCard(
      margin: EdgeInsets.only(bottom: 8.0.scaled(context, ref)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AmountText(
                  value: tx.type == 'adjustment'
                      ? tx.amount
                      : isExpense
                          ? -tx.amount
                          : tx.amount,
                  signed: !isTransfer,
                  showCurrency: true,
                  currencyCode: tx.currencyCode,
                ),
                SizedBox(height: 4.0.scaled(context, ref)),
                if (tx.note?.isNotEmpty == true) ...[
                  Text(
                    tx.note!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PiggyTextTokens.caption(context),
                  ),
                  SizedBox(height: 2.0.scaled(context, ref)),
                ],
                Text(
                  '$ledgerName · ${_ts.format(tx.happenedAt)} → ${_ts.format(row.deletedAt)}',
                  style: PiggyTextTokens.caption(context),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.recycleBinRestore,
            onPressed: () => _restore(row),
            icon: const Icon(Icons.restore),
          ),
          IconButton(
            tooltip: l10n.recycleBinPurge,
            onPressed: () => _purge(row),
            icon: const Icon(Icons.delete_forever_outlined),
          ),
        ],
      ),
    );
  }
}

class _BinData {
  final List<DeletedTransaction> rows;
  final Map<int, Transaction> txs;
  final Map<int, String> ledgerNames;
  const _BinData(this.rows, this.txs, this.ledgerNames);
}
