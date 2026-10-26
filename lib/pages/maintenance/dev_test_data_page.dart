import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../providers/budget_providers.dart';
import '../../providers/database_providers.dart';
import '../../providers/sync_providers.dart';
import '../../services/data/dev_test_data_seeder.dart';
import '../../styles/tokens.dart';
import '../../utils/dev_tool_gate.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';

/// 测试数据生成页 —— **只在 dev flavor 的 debug / profile 包可达**
/// （[DevToolGate.enabled]）。release / prod flavor 下入口不渲染，页内还会
/// 再判一次，兜住「被别处 push 进来」的情况。
///
/// 面向「本地功能联调 / 列表与统计性能自测」：一键写入几千条覆盖各实体的
/// 数据，并可在同页清空。所有数据都带 [DevTestDataSeeder.marker] 前缀，
/// 生成前会先清掉上一批，重复点击不会叠数据。
class DevTestDataPage extends ConsumerStatefulWidget {
  const DevTestDataPage({super.key});

  @override
  ConsumerState<DevTestDataPage> createState() => _DevTestDataPageState();
}

class _DevTestDataPageState extends ConsumerState<DevTestDataPage> {
  static const _plan = DevSeedPlan();

  bool _busy = false;
  String? _stage;
  int _done = 0;
  int _total = 0;
  DevSeedResult? _result;
  String? _cleanupSummary;

  /// 真实包名 / 版本（dev flavor 的 applicationId 带 `.dev` 后缀），
  /// 只用于在二次确认里标明当前环境。
  String? _envPackage;
  String? _envVersion;

  /// 进度回调按行触发（几千次），限流到 ~100ms 一次，避免把自己刷成掉帧源。
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _loadEnv();
  }

  Future<void> _loadEnv() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _envPackage = info.packageName;
        _envVersion =
            info.version.isEmpty ? null : '${info.version}+${info.buildNumber}';
      });
    } catch (_) {
      // 取不到包信息不影响功能，环境描述退化为 flavor / mode / 平台。
    }
  }

  DevToolEnv get _env =>
      DevToolGate.env(packageName: _envPackage, version: _envVersion);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ledger = ref.watch(currentLedgerProvider).value;

    // 兜底门禁：即使有人绕过入口（深链 / 调试路由）进来，也拿不到操作按钮。
    if (!DevToolGate.enabled) {
      return Scaffold(
        backgroundColor: PiggyTokens.scaffoldBackground(context),
        extendBodyBehindAppBar: true,
        appBar: PiggyTitleBar(title: l10n.devSeedTitle, showBack: true),
        body: Center(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              PiggyDimens.p24,
              MediaQuery.of(context).padding.top + 80,
              PiggyDimens.p24,
              PiggyDimens.p24,
            ),
            child: Text(
              l10n.devSeedUnavailable,
              textAlign: TextAlign.center,
              style: PiggyTextTokens.body(context)
                  .copyWith(color: PiggyTokens.textSecondary(context)),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(title: l10n.devSeedTitle, showBack: true),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          PiggyDimens.p16,
          PiggyTokens.topScrollablePadding(context, extra: PiggyDimens.p16),
          PiggyDimens.p16,
          PiggyDimens.p16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          Text(
            l10n.devSeedHint,
            style: PiggyTextTokens.label(context)
                .copyWith(color: PiggyTokens.textTertiary(context)),
          ),
          const SizedBox(height: PiggyDimens.p16),
          SettingsCard(
            children: [
              _InfoRow(
                icon: Icons.account_balance_wallet_outlined,
                label: l10n.devSeedCurrentLedgerName(ledger?.name ?? '-'),
              ),
              _EnvBlock(env: _env),
              _InfoRow(
                icon: Icons.storage_outlined,
                label: l10n.devSeedPlanSummary(_plan.totalRecords),
              ),
              _CountRow(
                label: l10n.devSeedEntityAccounts,
                count: _plan.accounts,
              ),
              _CountRow(
                label: l10n.devSeedEntityCategories,
                count: _plan.categories,
              ),
              _CountRow(label: l10n.devSeedEntityTags, count: _plan.tags),
              _CountRow(
                label: l10n.devSeedEntityCustomFields,
                count: _plan.customFields,
              ),
              _CountRow(
                label: l10n.devSeedEntityBudgets,
                count: _plan.budgets,
              ),
              _CountRow(
                label: l10n.devSeedEntityRecurring,
                count: _plan.recurring,
              ),
              _CountRow(
                label: l10n.devSeedEntitySavingsGoals,
                count: _plan.savingsGoals,
              ),
              _CountRow(
                label: l10n.devSeedEntityHoldings,
                count: _plan.holdings,
              ),
              _CountRow(
                label: l10n.devSeedEntityTransactions,
                count: _plan.transactions +
                    _plan.extraLedgers * _plan.extraLedgerTransactions,
              ),
              _CountRow(
                label: l10n.devSeedEntityLedgers,
                count: _plan.extraLedgers,
              ),
            ],
          ),
          const SizedBox(height: PiggyDimens.p16),
          FilledButton.icon(
            onPressed: _busy ? null : _runSeed,
            icon: const Icon(Icons.auto_awesome),
            label: Text(l10n.devSeedGenerate),
          ),
          const SizedBox(height: PiggyDimens.p8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _runCleanup,
            icon: Icon(Icons.delete_sweep_outlined,
                color: PiggyTokens.error(context)),
            label: Text(
              l10n.devSeedCleanup,
              style: TextStyle(color: PiggyTokens.error(context)),
            ),
          ),
          if (_busy) ...[
            const SizedBox(height: PiggyDimens.p20),
            LinearProgressIndicator(
              value: _total > 0 ? (_done / _total).clamp(0.0, 1.0) : null,
              color: PiggyTokens.primary(context),
              backgroundColor: PiggyTokens.divider(context),
            ),
            const SizedBox(height: PiggyDimens.p8),
            Text(
              '${l10n.devSeedStageLabel(_stageLabel(l10n, _stage))} '
              '$_done / $_total',
              style: PiggyTextTokens.label(context)
                  .copyWith(color: PiggyTokens.textSecondary(context)),
            ),
          ],
          if (_result != null && !_busy) ...[
            const SizedBox(height: PiggyDimens.p20),
            SectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.devSeedDone,
                    style: PiggyTextTokens.body(context)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: PiggyDimens.p8),
                  Text(
                    l10n.devSeedDoneDetail(
                      _result!.cleanedTotal,
                      _result!.createdTotal,
                    ),
                    style: PiggyTextTokens.label(context),
                  ),
                  if (_result!.failed > 0) ...[
                    const SizedBox(height: PiggyDimens.p4),
                    Text(
                      l10n.devSeedFailedCount(_result!.failed),
                      style: PiggyTextTokens.label(context)
                          .copyWith(color: PiggyTokens.error(context)),
                    ),
                  ],
                  const SizedBox(height: PiggyDimens.p4),
                  Text(
                    l10n.devSeedElapsed(_result!.elapsed.inMilliseconds),
                    style: PiggyTextTokens.label(context)
                        .copyWith(color: PiggyTokens.textTertiary(context)),
                  ),
                  const SizedBox(height: PiggyDimens.p8),
                  Text(
                    l10n.devSeedRefreshHint,
                    style: PiggyTextTokens.label(context)
                        .copyWith(color: PiggyTokens.textTertiary(context)),
                  ),
                ],
              ),
            ),
          ],
          if (_cleanupSummary != null && !_busy) ...[
            const SizedBox(height: PiggyDimens.p20),
            Text(
              _cleanupSummary!,
              style: PiggyTextTokens.label(context)
                  .copyWith(color: PiggyTokens.textSecondary(context)),
            ),
          ],
        ],
      ),
    );
  }

  // ==========================================================================
  // 操作
  // ==========================================================================

  Future<void> _runSeed() async {
    if (!DevToolGate.enabled) return;
    final l10n = AppLocalizations.of(context);
    // 写库是彻底覆盖（先删上一批测试数据）且量大，按「批量 / 覆盖」走
    // 双重危险确认（两次、各 3 秒倒计时），并在这两屏里都写明当前环境。
    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: l10n.devSeedGenerateConfirmTitle,
      firstMessage: l10n.devSeedGenerateConfirmMessage(_plan.totalRecords),
      secondMessage: l10n.devSeedGenerateSecondMessage(_plan.totalRecords),
      firstMessageWidget: _EnvBlock(env: _env, padding: EdgeInsets.zero),
      secondMessageWidget: _EnvBlock(env: _env, padding: EdgeInsets.zero),
      countdownSeconds: 3,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _busy = true;
      _stage = DevSeedStage.cleanup;
      _done = 0;
      _total = 0;
      _result = null;
      _cleanupSummary = null;
    });

    try {
      final repo = ref.read(repositoryProvider);
      final ledger = ref.read(currentLedgerProvider).value;
      var ledgerId = ref.read(currentLedgerIdProvider);
      final currency = ledger?.currency ?? 'CNY';
      if (ledger == null) {
        // 全新安装且跳过了默认账本时，先补一个账本，否则交易会挂在不存在的
        // ledgerId 上（列表看不到）。
        ledgerId = await repo.createLedger(
          name: l10n.ledgerDefaultName,
          currency: currency,
        );
        ref.read(currentLedgerIdProvider.notifier).state = ledgerId;
      }
      final result = await DevTestDataSeeder.seed(
        repo: repo,
        ledgerId: ledgerId,
        currency: currency,
        plan: _plan,
        onProgress: _onProgress,
      );
      _afterDataChanged();
      if (!mounted) return;
      setState(() => _result = result);
      showToast(context, l10n.devSeedDone);
    } catch (e) {
      if (!mounted) return;
      showToast(context, '${l10n.commonError}: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stage = null;
        });
      }
    }
  }

  Future<void> _runCleanup() async {
    if (!DevToolGate.enabled) return;
    final l10n = AppLocalizations.of(context);
    // 批量删除，走双重危险确认；两屏都标明环境。
    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: l10n.devSeedCleanupConfirmTitle,
      firstMessage: l10n.devSeedCleanupConfirmMessage,
      secondMessage: l10n.devSeedCleanupSecondMessage,
      firstMessageWidget: _EnvBlock(env: _env, padding: EdgeInsets.zero),
      secondMessageWidget: _EnvBlock(env: _env, padding: EdgeInsets.zero),
      countdownSeconds: 3,
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _busy = true;
      _stage = DevSeedStage.cleanup;
      _done = 0;
      _total = 0;
      _cleanupSummary = null;
    });

    try {
      final cleaned = await DevTestDataSeeder.cleanup(
        repo: ref.read(repositoryProvider),
        ledgerId: ref.read(currentLedgerIdProvider),
        onProgress: _onProgress,
      );
      _afterDataChanged();
      if (!mounted) return;
      final total = cleaned.values.fold<int>(0, (a, b) => a + b);
      setState(() {
        _result = null;
        _cleanupSummary = l10n.devSeedCleanupDone(total);
      });
      showToast(context, l10n.devSeedCleanupDone(total));
    } catch (e) {
      if (!mounted) return;
      showToast(context, '${l10n.commonError}: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _stage = null;
        });
      }
    }
  }

  void _onProgress(String stage, int done, int total) {
    if (!mounted) return;
    final now = DateTime.now();
    final stageChanged = stage != _stage;
    if (!stageChanged &&
        now.difference(_lastTick) < const Duration(milliseconds: 100) &&
        done != total) {
      return;
    }
    _lastTick = now;
    setState(() {
      _stage = stage;
      _done = done;
      _total = total;
    });
  }

  /// 批量写库后让页面侧的读缓存跟上（Drift 的 watch 流会自动刷新，
  /// 这里补的是 FutureProvider 那几条）。
  void _afterDataChanged() {
    ref.invalidate(categoriesProvider);
    ref.invalidate(transferCategoryProvider);
    ref.invalidate(allBudgetsProvider);
    ref.invalidate(budgetOverviewProvider);
    ref.invalidate(categoryBudgetsProvider);
    ref.read(syncGenerationProvider.notifier).state++;
  }

  String _stageLabel(AppLocalizations l10n, String? stage) {
    switch (stage) {
      case DevSeedStage.cleanup:
        return l10n.devSeedStageCleanup;
      case DevSeedStage.accounts:
        return l10n.devSeedEntityAccounts;
      case DevSeedStage.categories:
        return l10n.devSeedEntityCategories;
      case DevSeedStage.tags:
        return l10n.devSeedEntityTags;
      case DevSeedStage.customFields:
        return l10n.devSeedEntityCustomFields;
      case DevSeedStage.budgets:
        return l10n.devSeedEntityBudgets;
      case DevSeedStage.recurring:
        return l10n.devSeedEntityRecurring;
      case DevSeedStage.savingsGoals:
        return l10n.devSeedEntitySavingsGoals;
      case DevSeedStage.holdings:
        return l10n.devSeedEntityHoldings;
      case DevSeedStage.transactions:
        return l10n.devSeedEntityTransactions;
      case DevSeedStage.ledgers:
        return l10n.devSeedEntityLedgers;
      default:
        return l10n.devSeedRunning;
    }
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PiggyDimens.p16,
        vertical: PiggyDimens.p12,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: PiggyTokens.iconSecondary(context)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: PiggyTextTokens.body(context),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 运行环境清单：**一行一项**、左标签右值、全部加粗。
///
/// 刻意不用一段拼接文本：`com.watt.piggycount.dev.debug` 这类长包名在窄卡片里
/// 会被挤成居中折行的「一坨」，看不出哪段是哪个字段。页面与两次确认弹窗共用
/// 同一个组件，保证同一份环境信息在两处长得一致。
class _EnvBlock extends StatelessWidget {
  const _EnvBlock({
    required this.env,
    this.padding = const EdgeInsets.symmetric(
      horizontal: PiggyDimens.p16,
      vertical: PiggyDimens.p8,
    ),
  });

  final DevToolEnv env;

  /// 页面里的卡片行自己带 16 的横向内边距；弹窗正文外层已有 20，
  /// 传 [EdgeInsets.zero] 即可与上方说明文字左缘对齐。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final rows = <({String label, String value})>[
      (label: l10n.devSeedEnvFlavor, value: env.flavor),
      (label: l10n.devSeedEnvMode, value: env.mode),
      (label: l10n.devSeedEnvPlatform, value: env.platform),
      if (env.packageName != null)
        (label: l10n.devSeedEnvPackage, value: env.packageName!),
      if (env.version != null)
        (label: l10n.devSeedEnvVersion, value: env.version!),
    ];

    const labelWidth = 64.0;
    final titleStyle = PiggyTextTokens.body(context).copyWith(
      fontWeight: FontWeight.w700,
      color: PiggyTokens.textPrimary(context),
    );
    final labelStyle = PiggyTextTokens.label(context).copyWith(
      fontWeight: FontWeight.w600,
      color: PiggyTokens.textSecondary(context),
    );
    final valueStyle = PiggyTextTokens.label(context).copyWith(
      fontWeight: FontWeight.w700,
      color: PiggyTokens.textPrimary(context),
    );

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.devSeedEnvironment, style: titleStyle),
          const SizedBox(height: PiggyDimens.p4),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(top: PiggyDimens.p4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: Text(row.label, style: labelStyle),
                  ),
                  Expanded(child: Text(row.value, style: valueStyle)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PiggyDimens.p16,
        vertical: PiggyDimens.p8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: PiggyTextTokens.body(context)
                  .copyWith(color: PiggyTokens.textSecondary(context)),
            ),
          ),
          Text(
            '$count',
            style: PiggyTextTokens.body(context)
                .copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
