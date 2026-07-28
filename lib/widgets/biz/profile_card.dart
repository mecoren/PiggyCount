import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/sync_providers.dart' as sp;
import '../../services/system/logger_service.dart';
import '../../services/ui/avatar_service.dart';
import '../../providers/avatar_providers.dart';
import '../../styles/header_skins.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import 'amount_text.dart';
import 'bee_icon.dart';
import '../ui/toast.dart';

/// MinePage 顶部用户信息卡片
///
/// 从原 `mine_page.dart` 的 `_MinePageHeader` 抽取，包装为 16px 圆角卡片，
/// 背景保留 `headerSkinProvider`（用户选择的头部皮肤），与 wait-home 风格的
/// 灰底白卡视觉兼容。
///
/// 功能完整保留：
/// - 头像点击弹窗（编辑昵称 / 相册 / 拍照 / 删除）
/// - 昵称点击直接编辑
/// - 小眼睛切换金额隐藏
/// - 3 列统计（天数 / 记录数 / 余额）
/// - BeeCount Cloud 模式下头像自动云同步
class ProfileCard extends ConsumerStatefulWidget {
  const ProfileCard({super.key});

  @override
  ConsumerState<ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends ConsumerState<ProfileCard> {
  // 本地 optimistic 状态：用户自己刚选完图片时立刻更新到这里，配合 setState
  // 让 UI 零延迟响应。后台同步（BeeCountCloud 拉下来的头像）落盘后通过
  // ref.watch(avatarPathProvider) 自动传播到这里；_avatarPath 只是初始化 /
  // optimistic override，渲染时 avatarPathProvider 的值优先。
  String? _avatarPath;
  bool _isLoadingAvatar = true;

  @override
  void initState() {
    super.initState();
    _loadAvatar();
  }

  Future<void> _loadAvatar() async {
    final path = await AvatarService.getAvatarPath();
    if (mounted) {
      setState(() {
        _avatarPath = path;
        _isLoadingAvatar = false;
      });
    }
  }

  Future<void> _showProfileOptions() async {
    final l10n = AppLocalizations.of(context);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.mineProfileEditTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text(l10n.mineDisplayNameEditTitle),
              onTap: () => Navigator.pop(context, 'nickname'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(l10n.mineAvatarFromGallery),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(l10n.mineAvatarFromCamera),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            if (_avatarPath != null)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: Text(l10n.mineAvatarDelete,
                    style: const TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
        ],
      ),
    );

    if (result == null || !mounted) return;

    if (result == 'nickname') {
      await _showEditDisplayName();
      return;
    }

    try {
      if (result == 'gallery') {
        final path = await AvatarService.pickAndSaveAvatar();
        if (mounted && path != null) {
          setState(() => _avatarPath = path);
          ref.invalidate(avatarPathProvider);
          await _syncAvatarToCloud(path);
        }
      } else if (result == 'camera') {
        final path = await AvatarService.takePhotoAndSaveAvatar();
        if (mounted && path != null) {
          setState(() => _avatarPath = path);
          ref.invalidate(avatarPathProvider);
          await _syncAvatarToCloud(path);
        }
      } else if (result == 'delete') {
        await AvatarService.deleteAvatar();
        if (mounted) {
          setState(() => _avatarPath = null);
          ref.invalidate(avatarPathProvider);
        }
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, '${AppLocalizations.of(context).commonError}: $e');
    }
  }

  /// 头像同步到 BeeCount Cloud（走 /api/v1/profile/avatar）。
  /// 失败仅记日志，不阻塞用户使用本地头像；iCloud/WebDAV/Supabase 场景跳过。
  Future<void> _syncAvatarToCloud(String absolutePath) async {
    try {
      final providerInstance =
          await ref.read(sp.beecountCloudProviderInstance.future);
      if (providerInstance == null) {
        logger.debug('avatar_sync', '非 BeeCount Cloud 模式，跳过头像云同步');
        return;
      }
      final file = File(absolutePath);
      if (!file.existsSync()) {
        logger.warning(
            'avatar_sync', 'upload skipped: file missing $absolutePath');
        return;
      }
      final bytes = await file.readAsBytes();
      final name = absolutePath.split('/').last;
      logger.info('avatar_sync',
          'upload start path=$absolutePath size=${bytes.length}B');
      final result = await providerInstance.uploadMyAvatar(
        bytes: bytes,
        fileName: name,
        mimeType: name.toLowerCase().endsWith('.png')
            ? 'image/png'
            : 'image/jpeg',
      );
      // 上传成功后把本地 remoteVersion 立刻推到 server 的新版本，避免下一次
      // bootstrap 再触发一次重新下载自己刚传的头像。
      await AvatarService.setStoredRemoteVersion(result.avatarVersion);
      logger.info('avatar_sync',
          'upload done server_version=${result.avatarVersion} url=${result.avatarUrl}');
    } catch (e, st) {
      logger.warning('avatar_sync', 'upload failed (non-blocking): $e', st);
    }
  }

  /// 按本地时段返回问候语 + 配图(太阳/月亮)+ 图标色:5-11 早 / 11-13 午 /
  /// 13-18 下午 / 18-23 晚 / 23-5 夜。白天用太阳(暖色 amber→orange),晚上 / 夜里
  /// 用月亮(violet / indigo);图标色不随主题变。
  ({String text, IconData icon, Color color}) _greeting(AppLocalizations l10n) {
    final h = DateTime.now().hour;
    if (h >= 5 && h < 11) {
      return (
        text: l10n.mineGreetingMorning,
        icon: Icons.wb_twilight,
        color: const Color(0xFFF59E0B),
      );
    }
    if (h >= 11 && h < 13) {
      return (
        text: l10n.mineGreetingNoon,
        icon: Icons.wb_sunny,
        color: const Color(0xFFF59E0B),
      );
    }
    if (h >= 13 && h < 18) {
      return (
        text: l10n.mineGreetingAfternoon,
        icon: Icons.wb_sunny,
        color: const Color(0xFFF97316),
      );
    }
    if (h >= 18 && h < 23) {
      return (
        text: l10n.mineGreetingEvening,
        icon: Icons.nights_stay,
        color: const Color(0xFF8B5CF6),
      );
    }
    return (
      text: l10n.mineGreetingNight,
      icon: Icons.nightlight_round,
      color: const Color(0xFF818CF8),
    );
  }

  /// 编辑用户昵称。保存写入 displayNameProvider —— 本地持久化与(仅 BeeCount
  /// Cloud 模式)云推送由 provider 的 listener 自动完成。v1 不支持清空已设昵称:
  /// trim 为空则不改动。
  ///
  /// controller 由弹窗 [_EditDisplayNameDialog] 自己持有/释放,不在本异步方法里
  /// `finally { controller.dispose() }` —— 否则取消时弹窗退场动画未结束、TextField
  /// 仍挂载就释放 controller,会触发 "used after disposed" 红屏。
  Future<void> _showEditDisplayName() async {
    final current = ref.read(displayNameProvider);
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _EditDisplayNameDialog(initial: current),
    );
    if (result == null || !mounted) return;
    final name = result.trim();
    if (name.isEmpty || name == current) return; // v1 不清空;无变化不写
    ref.read(displayNameProvider.notifier).state = name;
    showToast(context, AppLocalizations.of(context).mineDisplayNameSaved);
  }

  @override
  Widget build(BuildContext context) {
    // 监听云同步写下来的头像路径：当 SyncEngine.syncMyProfile 从服务端拉到
    // 新头像并 bump avatarRefreshProvider 时，这里自动拿到新值，无需手动刷新。
    // 优先级：云同步路径 > 本地 optimistic (_avatarPath)。
    final avatarAsync = ref.watch(avatarPathProvider);
    final effectiveAvatarPath = avatarAsync.asData?.value ?? _avatarPath;

    // 获取当前账本信息
    final currentLedgerId = ref.watch(currentLedgerIdProvider);
    final countsAsync = ref.watch(countsForLedgerProvider(currentLedgerId));
    final balanceAsync = ref.watch(currentBalanceProvider(currentLedgerId));
    final currentLedgerAsync = ref.watch(currentLedgerProvider);
    final hide = ref.watch(hideAmountsProvider);
    final displayName = ref.watch(displayNameProvider);
    final l10n = AppLocalizations.of(context);
    final greeting = _greeting(l10n);
    final nameStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          color: BeeTokens.textPrimary(context),
          fontWeight: FontWeight.w600,
        );
    // 已设置=「问候,昵称」(与 web 一致),未设置=Slogan。
    final headerText = displayName.isNotEmpty
        ? l10n.mineGreetingNamed(greeting.text, displayName)
        : l10n.mineSlogan;

    final day = countsAsync.asData?.value.dayCount ?? 0;
    final tx = countsAsync.asData?.value.txCount ?? 0;
    final balance = balanceAsync.asData?.value ?? 0.0;
    final currencyCode = currentLedgerAsync.asData?.value?.currency ?? 'CNY';

    // 统计信息文字颜色
    final labelStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
          color: BeeTokens.textSecondary(context),
        );
    final numStyle = BeeTextTokens.strongTitle(context)
        .copyWith(fontSize: 20, color: BeeTokens.textPrimary(context));

    // 头部皮肤：亮暗通用同一款(暗色由皮肤内部渲染成纯黑底 + 偏淡主题色图形)。
    // 'none' → null = 纯主题色 / 纯黑。
    final skin = headerSkinById(ref.watch(headerSkinProvider));
    final isDark = BeeTokens.isDark(context);
    final primary = Theme.of(context).colorScheme.primary;
    // ProfileCard 背景色：亮色模式用主题色，暗黑模式用纯黑（与原 PrimaryHeader 一致）
    final cardBg = isDark ? Colors.black : primary;

    return ClipRRect(
      borderRadius: BorderRadius.circular(BeeDimens.radiusXl),
      child: Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(BeeDimens.radiusXl),
        ),
        child: Stack(
          children: [
            // 头部皮肤装饰层（主题色底之上的图形层）；未选皮肤时为纯主题色 / 纯黑
            if (skin != null)
              Positioned.fill(child: skin.builder(primary, isDark)),
            // 主内容
            Padding(
              padding: EdgeInsets.fromLTRB(
                16.0.scaled(context, ref),
                20.0.scaled(context, ref),
                16.0.scaled(context, ref),
                16.0.scaled(context, ref),
              ),
              child: Column(
                children: [
                  // 头像/Logo
                  GestureDetector(
                    onTap: _showProfileOptions,
                    child: Stack(
                      children: [
                        Container(
                          width: 80.0.scaled(context, ref),
                          height: 80.0.scaled(context, ref),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.1),
                            border: Border.all(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.3),
                              width: 2,
                            ),
                          ),
                          child: ClipOval(
                            child: _isLoadingAvatar
                                ? Center(
                                    child: SizedBox(
                                      width: 20.0.scaled(context, ref),
                                      height: 20.0.scaled(context, ref),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color:
                                            Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                  )
                                : (effectiveAvatarPath != null
                                    ? Image.file(
                                        // key 加入 path：Flutter 以 (File, key) 区
                                        // 分不同图片，否则从 A.jpg 换到 B.jpg（路径
                                        // 不同但 widget 复用）有时仍显示缓存的 A。
                                        key: ValueKey(effectiveAvatarPath),
                                        File(effectiveAvatarPath),
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) {
                                          return BeeIcon(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                            size: 40.0.scaled(context, ref),
                                          );
                                        },
                                      )
                                    : BeeIcon(
                                        color:
                                            Theme.of(context).colorScheme.primary,
                                        size: 40.0.scaled(context, ref),
                                      )),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 24.0.scaled(context, ref),
                            height: 24.0.scaled(context, ref),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: Icon(
                              Icons.edit,
                              size: 12.0.scaled(context, ref),
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 12.0.scaled(context, ref)),
                  // 昵称行:已设置 = 「时段图标 + 问候,昵称」(与 web 一致),未设置 =
                  // Slogan;名字可点直接编辑(发现性主入口在头像:点头像→编辑资料,可改
                  // 昵称/头像)。小眼睛(隐藏金额)紧跟其后,整体居中。
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (displayName.isNotEmpty) ...[
                        Icon(greeting.icon,
                            size: 18.0.scaled(context, ref),
                            color: greeting.color),
                        SizedBox(width: 6.0.scaled(context, ref)),
                      ],
                      Flexible(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _showEditDisplayName,
                          child: Text(
                            headerText,
                            style: nameStyle,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      SizedBox(width: 8.0.scaled(context, ref)),
                      GestureDetector(
                        onTap: () {
                          final cur = ref.read(hideAmountsProvider);
                          ref.read(hideAmountsProvider.notifier).state = !cur;
                        },
                        child: Icon(
                          hide
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 18,
                          color: BeeTokens.textPrimary(context),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 16.0.scaled(context, ref)),
                  // 统计数据
                  Row(
                    children: [
                      Expanded(
                        child: _StatCell(
                          label: AppLocalizations.of(context).mineDaysCount,
                          value: day.toString(),
                          labelStyle: labelStyle,
                          numStyle: numStyle,
                          centered: true,
                        ),
                      ),
                      Expanded(
                        child: _StatCell(
                          label: AppLocalizations.of(context).mineTotalRecords,
                          value: tx.toString(),
                          labelStyle: labelStyle,
                          numStyle: numStyle,
                          centered: true,
                        ),
                      ),
                      Expanded(
                        child: _StatCell(
                          label: AppLocalizations.of(context).mineCurrentBalance,
                          value: balance,
                          isAmount: true,
                          currencyCode: currencyCode,
                          labelStyle: labelStyle,
                          numStyle: numStyle.copyWith(
                            color: balance >= 0
                                ? BeeTokens.textPrimary(context)
                                : BeeTokens.error(context),
                          ),
                          centered: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCell extends ConsumerWidget {
  final String label;
  final dynamic value; // 可以是 String 或 double
  final TextStyle? labelStyle;
  final TextStyle? numStyle;
  final bool isAmount; // 是否为金额类型
  final String? currencyCode; // 币种代码
  final bool centered; // 是否居中对齐

  const _StatCell({
    required this.label,
    required this.value,
    this.labelStyle,
    this.numStyle,
    this.isAmount = false,
    this.currencyCode,
    this.centered = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget valueWidget;
    if (isAmount && value is double) {
      // 金额类型,使用 AmountText
      valueWidget = AmountText(
        value: value as double,
        signed: false,
        showCurrency: true,
        useCompactFormat: ref.watch(compactAmountProvider),
        currencyCode: currencyCode,
        style: numStyle,
      );
    } else {
      // 其他类型,直接显示字符串
      valueWidget = Text(value.toString(), style: numStyle);
    }

    return Column(
      crossAxisAlignment:
          centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        valueWidget,
        SizedBox(height: 4.0.scaled(context, ref)), // 数字与标签间距增大
        Text(label,
            style: labelStyle,
            textAlign: centered ? TextAlign.center : TextAlign.start),
      ],
    );
  }
}

/// 昵称编辑弹窗。独立 StatefulWidget 自己持有 controller、在 dispose() 释放,
/// 把 controller 的生命周期绑到弹窗本身 —— 弹窗(含 TextField)整棵子树卸载后
/// 才释放,彻底规避调用方在退场动画期间提前 dispose 造成的 "used after disposed"。
class _EditDisplayNameDialog extends StatefulWidget {
  const _EditDisplayNameDialog({required this.initial});

  final String initial;

  @override
  State<_EditDisplayNameDialog> createState() => _EditDisplayNameDialogState();
}

class _EditDisplayNameDialogState extends State<_EditDisplayNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.mineDisplayNameEditTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 20,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(hintText: l10n.mineDisplayNameHint),
        onSubmitted: (v) {
          if (v.trim().isNotEmpty) Navigator.pop(context, v);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) {
            final canSave = value.text.trim().isNotEmpty;
            return TextButton(
              onPressed: canSave
                  ? () => Navigator.pop(context, _controller.text)
                  : null,
              child: Text(l10n.commonSave),
            );
          },
        ),
      ],
    );
  }
}
