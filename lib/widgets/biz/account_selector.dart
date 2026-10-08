import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:collection/collection.dart';
import '../../data/db.dart';
import '../../styles/tokens.dart';
import '../../utils/lru_cache.dart';
import '../../utils/account_type_utils.dart';
import '../../providers.dart';
import '../../services/system/logger_service.dart';
import '../../l10n/app_localizations.dart';
import '../ui/piggy_spinner.dart';

/// 账户选择器组件
/// 横滑标签形式，支持 LRU 排序
class AccountSelector extends ConsumerStatefulWidget {
  final int? selectedAccountId;
  final ValueChanged<int?> onAccountSelected;
  final int ledgerId;
  /// v30 多币种:按币种过滤可选账户(记账币种优先联动,选 JPY → 只显示 JPY
  /// 账户)。null = 账本本位币(旧行为)。变更时列表自动重载。
  final String? filterCurrency;
  /// 账户隐藏(#240)E1 钉住:编辑历史交易时传入该交易当前挂的账户 id。若该
  /// 账户已被隐藏(因而被下方过滤排除),补回候选并打「已隐藏」灰标,让用户
  /// 能原样保存;其余隐藏账户仍不出现。null = 不钉住(新建交易场景)。
  final int? pinnedAccountId;

  const AccountSelector({
    super.key,
    required this.selectedAccountId,
    required this.onAccountSelected,
    required this.ledgerId,
    this.filterCurrency,
    this.pinnedAccountId,
  });

  @override
  ConsumerState<AccountSelector> createState() => _AccountSelectorState();
}

class _AccountSelectorState extends ConsumerState<AccountSelector> {
  List<Account> _accounts = [];
  List<int> _lruOrder = [];
  late LRUCache _lruCache;
  bool _isLoading = true;

  // 记录初始选中的账户ID，用于排序（不随点击变化）
  int? _initialSelectedAccountId;

  @override
  void initState() {
    super.initState();
    _initialSelectedAccountId = widget.selectedAccountId;
    _lruCache = LRUCache(key: 'account_lru_${widget.ledgerId}', maxSize: 20);
    _loadAccounts();
  }

  @override
  void didUpdateWidget(covariant AccountSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    // v30:记账切换币种 → 账户列表按新币种重载
    if (oldWidget.filterCurrency != widget.filterCurrency) {
      _loadAccounts();
    }
  }

  Future<void> _loadAccounts() async {
    try {
      final repo = ref.read(repositoryProvider);

      // 使用 provider 查询账本信息
      final ledger = await ref.read(ledgerByIdProvider(widget.ledgerId).future);
      if (ledger == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
        return;
      }

      // 获取所有账户,然后按当前账本币种 + 可交易类型筛选
      var allAccounts = await repo.getAllAccounts();

      // 账户隐藏(#240):选择器不展示已隐藏账户(账户管理页「已隐藏」分区与
      // 编辑历史交易时的 E1 钉住除外,见下方 pinnedAccountId 补回)。
      allAccounts = allAccounts.where((a) => !a.hidden).toList();

      // v30:过滤币种 = 显式传入(记账所选币种)?? 账本本位币(旧行为)
      final wanted =
          (widget.filterCurrency ?? ledger.currency).toUpperCase();
      var accounts = allAccounts
          .where((a) =>
              a.currency.toUpperCase() == wanted && isTradableType(a.type))
          .toList();

      // 账户隐藏(#240)E1 钉住:above 已排除隐藏账户;若调用方传了
      // pinnedAccountId 且它因隐藏被排除,补回候选(带 hidden=true,chip
      // 渲染时打灰标)。账户不存在或本就未隐藏则不处理。
      final pinnedId = widget.pinnedAccountId;
      if (pinnedId != null && !accounts.any((a) => a.id == pinnedId)) {
        final pinned = await repo.getAccount(pinnedId);
        if (pinned != null && pinned.hidden) {
          accounts = [...accounts, pinned];
        }
      }

      // 获取 LRU 排序
      final lruOrder = await _lruCache.getOrderedIds();

      logger.debug('AccountSelector', '加载账户完成，初始选中: $_initialSelectedAccountId, LRU顺序: $lruOrder');

      if (mounted) {
        setState(() {
          _accounts = accounts;
          _lruOrder = lruOrder;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// 根据 LRU 排序账户
  /// 使用初始选中的账户ID进行排序，避免点击时立即重排
  List<Account> _getSortedAccounts() {
    if (_accounts.isEmpty) return [];

    final List<Account> sorted = [];

    // 将初始选中的账户放在第一个（如果存在）
    if (_initialSelectedAccountId != null) {
      final selected = _accounts.where((a) => a.id == _initialSelectedAccountId).firstOrNull;
      if (selected != null) {
        sorted.add(selected);
      }
    }

    // 按 LRU 顺序添加其他账户
    for (final id in _lruOrder) {
      final account = _accounts.where((a) => a.id == id && a.id != _initialSelectedAccountId).firstOrNull;
      if (account != null && !sorted.contains(account)) {
        sorted.add(account);
      }
    }

    // 添加未在 LRU 中的账户（按创建顺序）
    for (final account in _accounts) {
      if (!sorted.contains(account)) {
        sorted.add(account);
      }
    }

    return sorted;
  }

  void _onAccountTap(int? accountId) {
    logger.debug('AccountSelector', '点击账户: $accountId, 当前LRU顺序: $_lruOrder');
    widget.onAccountSelected(accountId);

    // 只记录使用，不立即更新排序（下次加载时才生效）
    if (accountId != null) {
      _lruCache.recordUsage(accountId);
      logger.debug('AccountSelector', '已记录使用，但不更新当前排序');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return SizedBox(
        height: 32,
        child: Center(
          child: PiggySpinner(size: 16, color: PiggyTokens.primary(context)),
        ),
      );
    }

    final sortedAccounts = _getSortedAccounts();

    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: sortedAccounts.length + 1, // +1 for "no account" option
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          // "无账户"永远在第一位
          if (index == 0) {
            final isSelected = widget.selectedAccountId == null;
            return _buildAccountChip(
              label: AppLocalizations.of(context).accountNone,
              isSelected: isSelected,
              onTap: () => _onAccountTap(null),
            );
          }

          // 其他账户从索引 1 开始
          final accountIndex = index - 1;
          final account = sortedAccounts[accountIndex];
          final isSelected = widget.selectedAccountId == account.id;

          return _buildAccountChip(
            label: account.name,
            isSelected: isSelected,
            // account.hidden 只可能在 E1 钉住场景为 true(其余隐藏账户已被
            // 过滤,不会出现在 sortedAccounts 里),借该字段直接打灰标。
            isHidden: account.hidden,
            onTap: () => _onAccountTap(account.id),
          );
        },
      ),
    );
  }

  Widget _buildAccountChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    bool isHidden = false,
  }) {
    final primaryColor = ref.watch(primaryColorProvider);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? primaryColor : PiggyTokens.surfaceChip(context),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isHidden) ...[
                Icon(
                  Icons.visibility_off,
                  size: 12,
                  color: isSelected
                      ? Colors.white70
                      : PiggyTokens.textTertiary(context),
                ),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: PiggyTextTokens.fs13,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected ? Colors.white : PiggyTokens.textSecondary(context),
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
