/// 账本卡片组件
///
/// 展示账本基本信息，同步状态通过 syncStatusProvider 单独获取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/ledger_display_item.dart';
import '../../cloud/sync_service.dart';
import '../../providers/theme_providers.dart';
import '../../providers/sync_providers.dart';
import '../../utils/format_utils.dart';
import '../../utils/currencies.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import '../ui/piggy_popup_menu.dart';

/// 账本卡片
class LedgerCard extends ConsumerStatefulWidget {
  final LedgerDisplayItem ledger;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 角标「⋯」的操作菜单条目（项目锚点浮层菜单）。
  ///
  /// 长按是不可发现的手势,预算管理等入口藏在里面没人找得到,
  /// 必须有一个可见的等价入口 —— 两者弹**同一份**菜单,所以条目由本卡片持有、
  /// 选中后经 [onMoreSelected] 上抛。
  final List<PiggyMenuItem>? moreItems;

  /// [moreItems] 选中回调（value 即 `PiggyMenuItem.action` 的 `value`）。
  final ValueChanged<String>? onMoreSelected;
  final bool selected;

  const LedgerCard({
    super.key,
    required this.ledger,
    this.onTap,
    this.onLongPress,
    this.moreItems,
    this.onMoreSelected,
    this.selected = false,
  });

  @override
  ConsumerState<LedgerCard> createState() => _LedgerCardState();
}

class _LedgerCardState extends ConsumerState<LedgerCard> {
  /// 角标「⋯」内层 [PopupMenuButton] 的 key：长按卡片时用
  /// `showButtonMenu()` 打开同一份菜单（该方法是公开的），省得两套锚点逻辑。
  final PiggyMenuKey _menuKey = PiggyMenuKey();

  void _openMore() => _menuKey.currentState?.showButtonMenu();

  @override
  Widget build(BuildContext context) {
    final ledger = widget.ledger;
    final onTap = widget.onTap;
    final selected = widget.selected;
    final moreItems = widget.moreItems;
    final onMoreSelected = widget.onMoreSelected;
    final primaryColor = ref.watch(primaryColorProvider);
    final l10n = AppLocalizations.of(context);

    // 获取同步状态
    final syncStatusAsync = ref.watch(syncStatusProvider(ledger.id));
    final syncStatus = syncStatusAsync.valueOrNull;

    // 检查是否正在上传
    final uploadingIds = ref.watch(uploadingLedgerIdsProvider);
    final isUploading =
        !ledger.isRemoteOnly && uploadingIds.contains(ledger.id);

    // 判断同步状态
    final isRemote = ledger.isRemoteOnly;
    final isSynced = syncStatus?.diff == SyncDiff.inSync;

    // 非同步状态：除了inSync和noRemote之外的所有状态
    final isNotSynced = syncStatus != null &&
        syncStatus.diff != SyncDiff.inSync &&
        syncStatus.diff != SyncDiff.noRemote &&
        syncStatus.diff != SyncDiff.notConfigured;

    return GestureDetector(
      onTap: onTap,
      // 有菜单条目时长按打开角标那份（同一份），否则沿用调用方的长按回调。
      onLongPress: moreItems != null ? _openMore : widget.onLongPress,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: PiggyTokens.surface(context),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          // 主题色边框：选中加粗，未选中细边框（与全站卡片统一），用边框替代阴影
          border: Border.all(
            color: primaryColor,
            width: selected ? 2.5 : 1.5,
          ),
          boxShadow: null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          child: Stack(
            children: [
              // 左侧色条：仅选中时显示
              if (selected)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 4,
                    decoration: BoxDecoration(
                      color: primaryColor,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(PiggyDimens.radiusLg),
                        bottomLeft: Radius.circular(PiggyDimens.radiusLg),
                      ),
                    ),
                  ),
                ),

              // 底层：账本信息（始终显示）
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 顶部：名称 + 状态图标
                    Row(
                      children: [
                        // 账本名称。ID 部分按本地/远程分口径：
                        // - 本地账本：数据库 id，日常辨识足够；
                        // - 远程账本：槽位短 ID（slotKey 前 6 位，与同名
                        //   多槽位警示弹窗同一口径 formatSlotShortId）。
                        //   此前展示 remoteSyncId.hashCode（Dart 整型哈希），
                        //   与弹窗承诺的短 ID 对不上号，甄别无法兑现。
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              children: [
                                TextSpan(
                                  text:
                                      translateLedgerName(context, ledger.name),
                                  style: PiggyTextTokens.boldTitle(context)
                                      .copyWith(fontWeight: FontWeight.w600),
                                ),
                                TextSpan(
                                  text: isRemote
                                      ? ' (ID:${ledger.remoteSyncId == null ? '?' : formatSlotShortId(ledger.remoteSyncId!)})'
                                      : ' (ID:${ledger.id})',
                                  // UI-07：字号走 PiggyTextTokens（body=14）
                                  style: PiggyTextTokens.body(context).copyWith(
                                      fontWeight: FontWeight.w500,
                                      color: isRemote
                                          ? primaryColor.withValues(alpha: 0.8)
                                          : PiggyTokens.textSecondary(context)),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // v24: 共享账本 🤝 角标 + 成员数
                        if (ledger.isShared) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.handshake,
                            size: 14,
                            color: primaryColor,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            '${ledger.memberCount}',
                            style: PiggyTextTokens.label(context)
                                .copyWith(color: primaryColor),
                          ),
                        ],

                        const SizedBox(width: 8),

                        // 状态图标
                        _buildStatusIcon(
                          context,
                          ref,
                          primaryColor,
                          isSynced,
                          isNotSynced,
                          isRemote,
                          isUploading,
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // 统计数据（本地和远程都显示）
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 币种
                        Text(
                          '${l10n.ledgersCurrency}：${getCurrencyName(ledger.currency, context)}（${ledger.currency}）',
                          style: PiggyTextTokens.body(context).copyWith(
                              color: PiggyTokens.textSecondary(context)),
                        ),
                        const SizedBox(height: 4),
                        // 记账笔数
                        Text(
                          l10n.ledgersRecords('${ledger.transactionCount}'),
                          style: PiggyTextTokens.body(context).copyWith(
                              color: PiggyTokens.textSecondary(context)),
                        ),
                        const SizedBox(height: 4),
                        // 余额（根据设置使用简洁或完整格式）
                        Text(
                          l10n.ledgersBalance(
                            ref.watch(compactAmountProvider)
                                ? formatBalance(
                                    ledger.balance,
                                    ledger.currency,
                                    isChineseLocale:
                                        Localizations.localeOf(context)
                                                .languageCode ==
                                            'zh',
                                  )
                                : formatBalanceFull(
                                    ledger.balance, ledger.currency),
                          ),
                          style: PiggyTextTokens.body(context).copyWith(
                            fontWeight: FontWeight.w500,
                            color: ledger.balance >= 0
                                ? PiggyTokens.success(context)
                                : PiggyTokens.error(context),
                          ),
                        ),
                        // 云端上传时间：仅远程账本显示（供同名多槽位甄别：
                        // 与短 ID 一起构成「哪个是最新槽位」的判断依据；
                        // 蒙层半透明会压暗底层，故蒙层内也同步展示短 ID）
                        if (isRemote) ...[
                          const SizedBox(height: 4),
                          Text(
                            '${l10n.ledgerCardCloudUploaded}：${formatCloudUploadDate(ledger.lastUpdated)}',
                            style: PiggyTextTokens.body(context).copyWith(
                                color: PiggyTokens.textSecondary(context)),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              // 蒙层：仅远程账本显示
              if (isRemote)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color:
                          PiggyTokens.surface(context).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.cloud_download,
                          size: 48,
                          color: primaryColor,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.ledgerCardDownloadCloud,
                          // UI-07：title(16) 基础上仅覆写字重与颜色
                          style: PiggyTextTokens.title(context).copyWith(
                            fontWeight: FontWeight.w600,
                            color: primaryColor,
                          ),
                        ),
                        // 同名多槽位甄别信息（与警示弹窗同口径）：短 ID +
                        // 上传时间。蒙层压暗底层，这两行才是用户实际可读的
                        const SizedBox(height: 4),
                        Text(
                          'ID:${ledger.remoteSyncId == null ? '?' : formatSlotShortId(ledger.remoteSyncId!)}',
                          style: PiggyTextTokens.body(context).copyWith(
                              fontWeight: FontWeight.w500,
                              color: primaryColor.withValues(alpha: 0.8)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${l10n.ledgerCardCloudUploaded}：${formatCloudUploadDate(ledger.lastUpdated)}',
                          style: PiggyTextTokens.body(context).copyWith(
                              color: PiggyTokens.textSecondary(context)),
                        ),
                      ],
                    ),
                  ),
                ),

              // 右下角操作按钮（长按菜单的可见等价入口;放蒙层之后保证远程账本也可点）
              // 用项目「锚点浮层菜单」：贴在本按钮下方、靠右自动右沿对齐、
              // 不铺遮罩色、点别处即关（参考 orbit 移动端页头 ⋮ 面板）。
              if (moreItems != null)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: PiggyPopupMenu(
                    menuKey: _menuKey,
                    items: moreItems,
                    onSelected: onMoreSelected,
                    primaryColor: primaryColor,
                    tooltip: l10n.ledgersActions,
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(
                        Icons.more_horiz,
                        size: 20,
                        color: PiggyTokens.iconSecondary(context),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 状态图标
  Widget _buildStatusIcon(
    BuildContext context,
    WidgetRef ref,
    Color primaryColor,
    bool isSynced,
    bool isNotSynced,
    bool isRemote,
    bool isUploading,
  ) {
    // 优先显示上传中状态
    if (isUploading) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2.0,
        ),
      );
    }

    if (isRemote) {
      // 远程账本：云下载图标
      return Icon(
        Icons.cloud_download,
        color: primaryColor,
        size: 20,
      );
    } else if (isSynced) {
      // 已同步：绿色云勾选图标（UI-02：走 token，暗色下对比度一致）
      return Icon(
        Icons.cloud_done,
        color: PiggyTokens.success(context),
        size: 20,
      );
    } else if (isNotSynced) {
      // 未同步（包括：localNewer、cloudNewer、different、error、notLoggedIn）：红色云图标
      return Icon(
        Icons.cloud_off,
        color: PiggyTokens.error(context),
        size: 20,
      );
    } else {
      // 纯本地账本（离线模式/未配置）：灰色云关闭图标
      return Icon(
        Icons.cloud_off,
        color: PiggyTokens.iconTertiary(context),
        size: 20,
      );
    }
  }
}
