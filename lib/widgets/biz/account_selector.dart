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
import '../ui/segmented_control.dart';

/// 账户选择器组件
///
/// **横滑**芯片形式（账户数不定，分段控件那种等宽 2~3 段放不下），支持 LRU
/// 排序，首个恒为「不选择账户」。
///
/// 芯片的选中 / 未选视觉与「进度来源」的 [PiggySegmentedControl] **共用**
/// [piggySelectableDecoration]（主色描边 + 12% 主色底），高度也同为 40：
/// 原先这里自画的是「实心主色底 + 白字」，与同一个记账抽屉里的分段控件像两个
/// 体系，且实心蓝的视觉重量盖过了金额位。
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

  /// 是否**按内容取宽**（默认 false = 占满调用方给的宽度）。
  ///
  /// 记账抽屉把账户 / 标签 / 附件 / 旗标合并成一条属性行时传 true：那里账户区
  /// 是「非 flex 子项 + 内容宽」，账户少时才不会被 `Expanded` 份额撑到半行、
  /// 在右边留一段空洞（见 `amount_editor_sheet.dart` 的 `_buildAccountAndTagRow`）。
  /// 供其它调用方（转账表单等）保持原样。
  final bool shrinkWrapToContent;

  const AccountSelector({
    super.key,
    required this.selectedAccountId,
    required this.onAccountSelected,
    required this.ledgerId,
    this.filterCurrency,
    this.pinnedAccountId,
    this.shrinkWrapToContent = false,
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
      // 高度与 [rowHeight] 一致：加载完从 32 跳到 40 会让整张表单抖一下。
      return SizedBox(
        height: rowHeight,
        width: widget.shrinkWrapToContent ? 0 : null,
        child: Center(
          child: PiggySpinner(size: 16, color: PiggyTokens.primary(context)),
        ),
      );
    }

    final sortedAccounts = _getSortedAccounts();

    // 按内容取宽（记账抽屉的合并属性行专用）：用 [SingleChildScrollView] + [Row]
    // 而不是 [ListView] —— scroll view 的视口尺寸会收缩到内容宽
    // （`constrain(child.size)`），内容真的超出调用方给的上界时才横滑。
    //
    // 刻意**不自己量文本宽度**：量出来的值与实际渲染差几个像素，最后一个芯片
    // 就会被裁掉一截或右侧多留一道缝（两处口径必须逐像素一致，不值得）。
    if (widget.shrinkWrapToContent) {
      return SizedBox(
        height: rowHeight,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i <= sortedAccounts.length; i++) ...[
                if (i > 0) const SizedBox(width: PiggyDimens.p8),
                _chipFor(i, sortedAccounts),
              ],
            ],
          ),
        ),
      );
    }

    return SizedBox(
      height: rowHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: sortedAccounts.length + 1, // +1 for "no account" option
        separatorBuilder: (_, __) => const SizedBox(width: PiggyDimens.p8),
        itemBuilder: (_, index) => _chipFor(index, sortedAccounts),
      ),
    );
  }

  /// 第 [index] 个芯片（0 = 「不选择账户」，其余按 [sortedAccounts] 顺序）。
  Widget _chipFor(int index, List<Account> sortedAccounts) {
    if (index == 0) {
      return _buildAccountChip(
        label: AppLocalizations.of(context).accountNone,
        isSelected: widget.selectedAccountId == null,
        onTap: () => _onAccountTap(null),
      );
    }

    final account = sortedAccounts[index - 1];
    return _buildAccountChip(
      label: account.name,
      isSelected: widget.selectedAccountId == account.id,
      // account.hidden 只可能在 E1 钉住场景为 true(其余隐藏账户已被过滤,
      // 不会出现在 sortedAccounts 里),借该字段直接打灰标。
      isHidden: account.hidden,
      onTap: () => _onAccountTap(account.id),
    );
  }

  /// 芯片行高：与「进度来源」分段控件同高（40），触控目标更大，也让同一个记
  /// 账抽屉里的可选格子看起来是一套东西。
  static const double rowHeight = 40;

  Widget _buildAccountChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    bool isHidden = false,
  }) {
    // 主色取 `PiggyTokens.primary`（= 主题 colorScheme.primary，其值就是用户的
    // 个性化主色）而**不是**再 read 一遍 primaryColorProvider：两处取值在真实
    // 主题里等价，但混用两个来源意味着将来主题主色一旦改成别的公式（例如按
    // 明暗微调）两处就会漂移 —— 这里与 PiggySegmentedControl 共用同一个入口。
    final textColor =
        piggySelectableTextColor(context, selected: isSelected);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        // 供 widget 测试取装饰（与 PiggySegmentedControl 逐字段比对，防再退回
        // 「实心主色底」那一版）。
        key: ValueKey('accountChip_$label'),
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        // 与 PiggySegmentedControl 共用同一套装饰（主色描边 + 12% 主色底），
        // 让账户行与「进度来源」那种分段控件是同一套视觉语言。
        decoration: piggySelectableDecoration(
          context,
          selected: isSelected,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isHidden) ...[
              Icon(
                Icons.visibility_off,
                size: 12,
                color: isSelected
                    ? textColor.withValues(alpha: 0.7)
                    : PiggyTokens.textTertiary(context),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: PiggyTextTokens.fs13,
                // 与分段控件一致：选中 / 未选都是 w600，靠颜色与描边分主次
                fontWeight: FontWeight.w600,
                color: textColor,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
