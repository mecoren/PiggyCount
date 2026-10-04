import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../styles/tokens.dart';
import '../../providers.dart';
import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/account_type_utils.dart';
import '../ui/picker_sheet.dart';
import '../ui/piggy_spinner.dart';

/// 账户选择器数据模型
class AccountOption {
  final int? id;
  final String name;
  final String type;
  final IconData icon;

  AccountOption({
    this.id,
    required this.name,
    required this.type,
    required this.icon,
  });
}

/// 账户选择器组件（使用滚轮样式）
class AccountPicker extends ConsumerStatefulWidget {
  final int? selectedAccountId;
  final bool allowNull;

  const AccountPicker({
    super.key,
    this.selectedAccountId,
    this.allowNull = true,
  });

  @override
  ConsumerState<AccountPicker> createState() => _AccountPickerState();

  /// 显示账户选择器底部弹窗
  static Future<int?> show(
    BuildContext context, {
    int? selectedAccountId,
    bool allowNull = true,
  }) async {
    return showPiggyPickerSheet<int?>(
      context,
      builder: (_) => AccountPicker(
        selectedAccountId: selectedAccountId,
        allowNull: allowNull,
      ),
    );
  }
}

class _AccountPickerState extends ConsumerState<AccountPicker> {
  FixedExtentScrollController? _controller;
  int _selectedIndex = 0;
  List<AccountOption> _options = [];
  bool _initialized = false;

  void _buildOptions(List<Account> accounts) {
    if (_initialized) return;

    _options = [];

    // 添加"不选择账户"选项
    if (widget.allowNull) {
      _options.add(AccountOption(
        id: null,
        name: AppLocalizations.of(context).accountNone,
        type: 'none',
        icon: Icons.remove,
      ));
    }

    // 添加账户列表
    for (final account in accounts) {
      _options.add(AccountOption(
        id: account.id,
        name: account.name,
        type: account.type,
        icon: getIconForAccountType(account.type),
      ));
    }

    // 查找选中项的索引
    _selectedIndex = _options.indexWhere(
      (option) => option.id == widget.selectedAccountId,
    );
    if (_selectedIndex < 0) _selectedIndex = 0;

    // 初始化滚动控制器
    _controller = FixedExtentScrollController(initialItem: _selectedIndex);
    _initialized = true;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // v1.15.0: 获取当前账本币种
    final currentLedgerAsync = ref.watch(currentLedgerProvider);
    final currentCurrency = currentLedgerAsync.asData?.value?.currency ?? 'CNY';

    // v1.15.0: 获取所有账户并按币种筛选
    final allAccountsAsync = ref.watch(allAccountsStreamProvider);
    final primaryColor = Theme.of(context).colorScheme.primary;

    return allAccountsAsync.when(
      data: (allAccounts) {
        // 只显示与当前账本同币种的可交易账户
        final accounts = allAccounts
            .where((account) =>
                account.currency == currentCurrency &&
                isTradableType(account.type))
            .toList();

        _buildOptions(accounts);

        return PiggyPickerSheet(
          title: l10n.accountSelectTitle,
          confirmEnabled: _options.isNotEmpty,
          onConfirm: () {
            if (_options.isEmpty) return;
            Navigator.pop(context, _options[_selectedIndex].id);
          },
          // 滚轮选择器
          child: _controller == null
              ? const SizedBox.shrink()
              : SizedBox(
                  height: 216,
                  child: CupertinoPicker(
                    itemExtent: 72,
                    scrollController: _controller!,
                    selectionOverlay: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: primaryColor.withValues(alpha: 0.3),
                            width: 1,
                          ),
                          bottom: BorderSide(
                            color: primaryColor.withValues(alpha: 0.3),
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                    onSelectedItemChanged: (index) {
                      setState(() {
                        _selectedIndex = index;
                      });
                    },
                    children: _options.map((option) {
                      return _buildAccountItem(option, primaryColor);
                    }).toList(),
                  ),
                ),
        );
      },
      loading: () => SizedBox(
        height: 200,
        child: Center(
          child: PiggySpinner(size: 36, color: PiggyTokens.primary(context)),
        ),
      ),
      error: (err, stack) => SizedBox(
        height: 200,
        child: Center(
          child: Text('${l10n.commonError}: $err'),
        ),
      ),
    );
  }

  Widget _buildAccountItem(AccountOption option, Color primaryColor) {
    final isNone = option.id == null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          // 图标
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              // token 化：写死 Colors.grey 在暗黑模式下不可见
              color: isNone
                  ? PiggyTokens.surfaceDisabled(context)
                  : primaryColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: isNone
                ? Icon(option.icon,
                    color: PiggyTokens.iconSecondary(context), size: 24)
                : AccountTypeIcon(
                    type: option.type,
                    size: 24,
                  ),
          ),
          const SizedBox(width: 16),

          // 账户名称和类型
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  option.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!isNone) ...[
                  const SizedBox(height: 4),
                  Text(
                    getAccountTypeLabel(context, option.type),
                    style: TextStyle(
                      fontSize: 14,
                      color: PiggyTokens.textSecondary(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
