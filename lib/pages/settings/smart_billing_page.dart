import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../../providers/smart_billing_providers.dart';
import '../../providers/theme_providers.dart';
import '../../providers/voice_billing_providers.dart';
import '../ai/ai_settings_page.dart';
import '../automation/auto_billing_settings_page.dart';
import 'shortcuts_guide_page.dart';
import '../../l10n/app_localizations.dart';

/// Google Play 版本(CI 注入)。截屏自动记账依赖 READ_MEDIA_IMAGES,在 Google
/// Play 渠道被砍掉,这里用来隐藏入口。详见 release.yml 的临时 manifest 配置。
const _isGooglePlayBuild = bool.fromEnvironment('GOOGLE_PLAY', defaultValue: false);

/// 智能记账二级页面
class SmartBillingPage extends ConsumerWidget {
  const SmartBillingPage({super.key});

  /// 显示功能引导弹窗
  void _showFeatureGuideDialog(
    BuildContext context,
    String title,
    String description,
    String aiRequirement,
    bool requiresAI, {
    String? actionHint,
  }) {
    final l10n = AppLocalizations.of(context);
    final hint = actionHint ?? l10n.smartBillingGuideHint;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.info_outline, color: PiggyTokens.primary(context)),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              description,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: requiresAI
                    ? PiggyTokens.warning(context).withValues(alpha: 0.1)
                    : PiggyTokens.info(context).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                border: Border.all(
                  color: requiresAI ? PiggyTokens.warning(context) : PiggyTokens.info(context),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    requiresAI ? Icons.warning_amber : Icons.psychology,
                    color: requiresAI ? PiggyTokens.warning(context) : PiggyTokens.info(context),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      aiRequirement,
                      style: TextStyle(
                        fontSize: 13,
                        color: requiresAI ? PiggyTokens.warning(context) : PiggyTokens.info(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: PiggyTokens.primary(context).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.touch_app,
                    color: PiggyTokens.primary(context),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      hint,
                      style: TextStyle(
                        fontSize: 13,
                        color: PiggyTokens.primary(context),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.commonKnow),
          ),
        ],
      ),
    );
  }

  /// 语音记账设置区：触发方式 + 自动检测下的静音时长滑块
  Widget _buildVoiceBillingSection(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(voiceBillingSettingsProvider);
    final isAuto = settings.triggerMode == VoiceTriggerMode.auto;

    return SettingsCard(
      children: [
        SettingsNavItem(
          icon: Icons.mic_none_outlined,
          title: l10n.smartBillingVoiceTrigger,
          subtitle: isAuto
              ? l10n.voiceTriggerModeAuto
              : l10n.voiceTriggerModeHold,
          onTap: () => _showVoiceTriggerDialog(context, ref, settings.triggerMode),
        ),
        if (isAuto) ...[
          const _VoiceSilenceTimeoutSlider(),
        ],
      ],
    );
  }

  /// 触发方式选择弹窗
  void _showVoiceTriggerDialog(
    BuildContext context,
    WidgetRef ref,
    VoiceTriggerMode current,
  ) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.read(primaryColorProvider);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.smartBillingVoiceTrigger),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in VoiceTriggerMode.values)
              RadioListTile<VoiceTriggerMode>(
                value: mode,
                groupValue: current,
                activeColor: primaryColor,
                title: Text(
                  mode == VoiceTriggerMode.auto
                      ? l10n.voiceTriggerModeAuto
                      : l10n.voiceTriggerModeHold,
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  mode == VoiceTriggerMode.auto
                      ? l10n.voiceTriggerModeAutoDesc
                      : l10n.voiceTriggerModeHoldDesc,
                  style: const TextStyle(fontSize: 12),
                ),
                onChanged: (value) async {
                  if (value == null) return;
                  Navigator.pop(dialogContext);
                  await ref
                      .read(voiceBillingSettingsProvider.notifier)
                      .setTriggerMode(value);
                },
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonCancel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.smartBillingPageTitle,
        showBack: true,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.of(context).padding.top + 56 + 16,
          16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          // AI设置卡片
          SettingsCard(
            children: [
              // AI智能识别设置
              SettingsNavItem(
                icon: Icons.psychology_outlined,
                title: l10n.aiSettingsTitle,
                subtitle: l10n.aiSettingsSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AISettingsPage()),
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 16),

          // 快速记账功能引导
          SettingsCard(
            children: [
              // 图片记账
              SettingsNavItem(
                icon: Icons.photo_library_outlined,
                title: l10n.smartBillingImageBilling,
                subtitle: l10n.smartBillingImageBillingDesc,
                onTap: () {
                  _showFeatureGuideDialog(
                    context,
                    l10n.smartBillingImageBilling,
                    l10n.smartBillingImageBillingGuide,
                    l10n.smartBillingVisionAIRequired,
                    true,
                  );
                },
              ),

              // 拍照记账
              SettingsNavItem(
                icon: Icons.camera_alt_outlined,
                title: l10n.smartBillingCameraBilling,
                subtitle: l10n.smartBillingCameraBillingDesc,
                onTap: () {
                  _showFeatureGuideDialog(
                    context,
                    l10n.smartBillingCameraBilling,
                    l10n.smartBillingCameraBillingGuide,
                    l10n.smartBillingVisionAIRequired,
                    true,
                  );
                },
              ),

              // 语音记账
              SettingsNavItem(
                icon: Icons.mic_outlined,
                title: l10n.smartBillingVoiceBilling,
                subtitle: l10n.smartBillingVoiceBillingDesc,
                onTap: () {
                  _showFeatureGuideDialog(
                    context,
                    l10n.smartBillingVoiceBilling,
                    l10n.smartBillingVoiceBillingGuide,
                    l10n.smartBillingAIRequired,
                    true,
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 16),

          // 截图自动记账
          SettingsCard(
            children: [
              // 分享记账（Android：门槛低、GP 版唯一截图类入口，置顶）
              if (Platform.isAndroid)
                SettingsNavItem(
                  icon: Icons.share_outlined,
                  title: l10n.shareBilling,
                  subtitle: l10n.shareBillingDesc,
                  onTap: () {
                    _showFeatureGuideDialog(
                      context,
                      l10n.shareBilling,
                      l10n.shareBillingGuide,
                      l10n.smartBillingVisionAIRequired,
                      true,
                      actionHint: l10n.shareBillingActionHint,
                    );
                  },
                ),
              // 截图自动记账
              if (!(Platform.isAndroid && _isGooglePlayBuild))
                SettingsNavItem(
                  icon: Icons.auto_fix_high,
                  title: Platform.isAndroid
                      ? l10n.autoScreenshotBilling
                      : l10n.autoScreenshotBillingIosTitle,
                  subtitle: Platform.isAndroid
                      ? l10n.autoScreenshotBillingDesc
                      : l10n.autoScreenshotBillingIosDesc,
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AutoBillingSettingsPage()),
                    );
                  },
                ),
              // 快捷指令
              SettingsNavItem(
                icon: Icons.app_shortcut,
                title: l10n.shortcutsGuide,
                subtitle: l10n.shortcutsGuideDesc,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ShortcutsGuidePage()),
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 16),

          // 智能记账通用设置
          SettingsCard(
            children: [
              // 自动关联标签
              SettingsToggleItem(
                icon: Icons.label_outline,
                title: l10n.smartBillingAutoTags,
                subtitle: l10n.smartBillingAutoTagsDesc,
                value: ref.watch(smartBillingAutoTagsProvider),
                onChanged: (value) {
                  ref.read(smartBillingAutoTagsProvider.notifier).state = value;
                },
              ),
              // 自动添加附件
              SettingsToggleItem(
                icon: Icons.attachment_outlined,
                title: l10n.smartBillingAutoAttachment,
                subtitle: l10n.smartBillingAutoAttachmentDesc,
                value: ref.watch(smartBillingAutoAttachmentProvider),
                onChanged: (value) {
                  ref.read(smartBillingAutoAttachmentProvider.notifier).state = value;
                },
              ),
            ],
          ),

          const SizedBox(height: 16),

          // 语音记账设置（触发方式 + 静音灵敏度）
          _buildVoiceBillingSection(context, ref),
        ],
      ),
    );
  }
}

/// 静音判定时长滑块：拖动时仅更新本地预览，松手后持久化并触发云同步
class _VoiceSilenceTimeoutSlider extends ConsumerStatefulWidget {
  const _VoiceSilenceTimeoutSlider();

  @override
  ConsumerState<_VoiceSilenceTimeoutSlider> createState() =>
      _VoiceSilenceTimeoutSliderState();
}

class _VoiceSilenceTimeoutSliderState
    extends ConsumerState<_VoiceSilenceTimeoutSlider> {
  int? _dragValueMs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(voiceBillingSettingsProvider);
    final displayMs = _dragValueMs ?? settings.silenceTimeoutMs;
    final seconds = (displayMs / 1000).toStringAsFixed(1);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Icon(Icons.timer_outlined,
                  size: 20, color: ref.watch(primaryColorProvider)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.smartBillingVoiceSilenceTimeout,
                        style: const TextStyle(fontSize: 15)),
                    Text(
                      l10n.smartBillingVoiceSilenceTimeoutValue(seconds),
                      style: TextStyle(
                        fontSize: 12,
                        color: PiggyTokens.textTertiary(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Slider.adaptive(
          value: displayMs.toDouble(),
          min: VoiceBillingSettings.minSilenceTimeoutMs.toDouble(),
          max: VoiceBillingSettings.maxSilenceTimeoutMs.toDouble(),
          divisions: (VoiceBillingSettings.maxSilenceTimeoutMs -
                  VoiceBillingSettings.minSilenceTimeoutMs) ~/
              100,
          activeColor: ref.watch(primaryColorProvider),
          label: '${seconds}s',
          onChanged: (value) {
            setState(() => _dragValueMs = value.round());
          },
          onChangeEnd: (value) async {
            setState(() => _dragValueMs = null);
            await ref
                .read(voiceBillingSettingsProvider.notifier)
                .setSilenceTimeoutMs(value.round());
          },
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}
