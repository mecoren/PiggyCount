import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/reminder_providers.dart';
import '../../utils/notification_factory.dart';
import '../../utils/notification_android.dart';
import '../../styles/tokens.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';

class ReminderSettingsPage extends ConsumerWidget {
  const ReminderSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminderSettings = ref.watch(reminderSettingsProvider);

    final isDark = PiggyTokens.isDark(context);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: AppLocalizations.of(context)!.reminderTitle,
        showBack: true,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          PiggyTokens.topScrollablePadding(context, extra: 16),
          16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          // 提醒开关 + 提醒时间设置
          SettingsCard(
            children: [
              // 提醒开关
              SettingsToggleItem(
                icon: Icons.notifications_active_outlined,
                title: AppLocalizations.of(context)!.reminderDailyTitle,
                subtitle: AppLocalizations.of(context)!.reminderDailySubtitle,
                value: reminderSettings.isEnabled,
                onChanged: (value) {
                  ref
                      .read(reminderSettingsProvider.notifier)
                      .updateEnabled(value);
                },
              ),
              // 提醒时间设置
              SettingsNavItem(
                icon: Icons.access_time_rounded,
                title: AppLocalizations.of(context)!.reminderTimeTitle,
                subtitle: reminderSettings.timeString,
                onTap: () async {
                  final selectedTime = await showWheelTimePicker(
                    context,
                    initial: TimeOfDay(
                      hour: reminderSettings.hour,
                      minute: reminderSettings.minute,
                    ),
                  );

                  if (selectedTime != null) {
                    ref.read(reminderSettingsProvider.notifier).updateTime(
                          selectedTime.hour,
                          selectedTime.minute,
                        );
                  }
                },
              ),
            ],
          ),

          const SizedBox(height: 16),

          // 测试通知按钮
          SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      final notificationUtil =
                          NotificationFactory.getInstance();
                      await notificationUtil.showNotification(
                        id: 9999,
                        title: AppLocalizations.of(context)!.reminderTestTitle,
                        body: AppLocalizations.of(context)!.reminderTestBody,
                      );
                      if (context.mounted) {
                        showToast(context,
                            AppLocalizations.of(context)!.reminderTestSent);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: PiggyTokens.primary(context),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(PiggyDimens.radiusSm),
                      ),
                    ),
                    child: Text(
                      AppLocalizations.of(context)!.reminderTestNotification,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),

          // Android专用电池和渠道检查按钮
          if (Platform.isAndroid) ...[
            const SizedBox(height: 16),
            SettingsCard(
              children: [
                // 电池优化状态检查
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        final androidUtil = NotificationFactory.getInstance()
                            as AndroidNotificationUtil;
                        final batteryInfo =
                            await androidUtil.getBatteryOptimizationInfo();
                        if (context.mounted) {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(AppLocalizations.of(context)!
                                  .reminderBatteryStatus),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(AppLocalizations.of(context)!
                                      .reminderManufacturer(
                                          batteryInfo['manufacturer'] ??
                                              'Unknown')),
                                  Text(AppLocalizations.of(context)!
                                      .reminderModel(
                                          batteryInfo['model'] ?? 'Unknown')),
                                  Text(AppLocalizations.of(context)!
                                      .reminderAndroidVersion(
                                          batteryInfo['androidVersion'] ??
                                              'Unknown')),
                                  const SizedBox(height: 8),
                                  Text(
                                    (batteryInfo['isIgnoring'] == true)
                                        ? AppLocalizations.of(context)!
                                            .reminderBatteryIgnored
                                        : AppLocalizations.of(context)!
                                            .reminderBatteryNotIgnored,
                                    style: TextStyle(
                                      color: (batteryInfo['isIgnoring'] == true)
                                          ? PiggyTokens.success(context)
                                          : PiggyTokens.warning(context),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (batteryInfo['isIgnoring'] != true) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      AppLocalizations.of(context)!
                                          .reminderBatteryAdvice,
                                      style: const TextStyle(
                                          fontSize: 12, color: Colors.red),
                                    ),
                                  ],
                                ],
                              ),
                              actions: [
                                if (batteryInfo['isIgnoring'] != true &&
                                    batteryInfo['canRequest'] == true)
                                  TextButton(
                                    onPressed: () async {
                                      Navigator.of(context).pop();
                                      final androidUtil =
                                          NotificationFactory.getInstance()
                                              as AndroidNotificationUtil;
                                      await androidUtil
                                          .requestIgnoreBatteryOptimizations();
                                    },
                                    child: Text(AppLocalizations.of(context)!
                                        .commonSettings),
                                  ),
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: Text(AppLocalizations.of(context)!
                                      .commonConfirm),
                                ),
                              ],
                            ),
                          );
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(PiggyDimens.radiusSm),
                        ),
                      ),
                      child: Text(
                        AppLocalizations.of(context)!.reminderCheckBattery,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),

                // 通知渠道设置检查
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        final androidUtil = NotificationFactory.getInstance()
                            as AndroidNotificationUtil;
                        final channelInfo =
                            await androidUtil.getNotificationChannelInfo();
                        if (context.mounted) {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(AppLocalizations.of(context)!
                                  .reminderChannelStatus),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text((channelInfo['isEnabled'] == true)
                                      ? AppLocalizations.of(context)!
                                          .reminderChannelEnabled
                                      : AppLocalizations.of(context)!
                                          .reminderChannelDisabled),
                                  Text(AppLocalizations.of(context)!
                                      .reminderChannelImportance(
                                          channelInfo['importance'] ??
                                              'unknown')),
                                  Text((channelInfo['sound'] == true)
                                      ? AppLocalizations.of(context)!
                                          .reminderChannelSoundOn
                                      : AppLocalizations.of(context)!
                                          .reminderChannelSoundOff),
                                  Text((channelInfo['vibration'] == true)
                                      ? AppLocalizations.of(context)!
                                          .reminderChannelVibrationOn
                                      : AppLocalizations.of(context)!
                                          .reminderChannelVibrationOff),
                                  if (channelInfo['bypassDnd'] != null)
                                    Text((channelInfo['bypassDnd'] == true)
                                        ? AppLocalizations.of(context)!
                                            .reminderChannelDndBypass
                                        : AppLocalizations.of(context)!
                                            .reminderChannelDndNoBypass),
                                  const SizedBox(height: 8),
                                  if (channelInfo['isEnabled'] != true ||
                                      channelInfo['importance'] == 'none' ||
                                      channelInfo['importance'] == 'min' ||
                                      channelInfo['importance'] == 'low') ...[
                                    Text(
                                      AppLocalizations.of(context)!
                                          .reminderChannelAdvice,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.orange),
                                    ),
                                    Text(AppLocalizations.of(context)!
                                        .reminderChannelAdviceImportance),
                                    Text(AppLocalizations.of(context)!
                                        .reminderChannelAdviceSound),
                                    Text(AppLocalizations.of(context)!
                                        .reminderChannelAdviceBanner),
                                    Text(AppLocalizations.of(context)!
                                        .reminderChannelAdviceXiaomi),
                                  ] else ...[
                                    Text(
                                      AppLocalizations.of(context)!
                                          .reminderChannelGood,
                                      style: const TextStyle(
                                          color: Colors.green,
                                          fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ],
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () async {
                                    Navigator.of(context).pop();
                                    final androidUtil =
                                        NotificationFactory.getInstance()
                                            as AndroidNotificationUtil;
                                    await androidUtil
                                        .openNotificationChannelSettings();
                                  },
                                  child: Text(AppLocalizations.of(context)!
                                      .commonSettings),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: Text(AppLocalizations.of(context)!
                                      .commonConfirm),
                                ),
                              ],
                            ),
                          );
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(PiggyDimens.radiusSm),
                        ),
                      ),
                      child: Text(
                        AppLocalizations.of(context)!.reminderCheckChannel,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),

                // 打开应用设置
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        final androidUtil = NotificationFactory.getInstance()
                            as AndroidNotificationUtil;
                        await androidUtil.openAppSettings();
                        if (context.mounted) {
                          showToast(
                              context,
                              AppLocalizations.of(context)!
                                  .reminderAppSettingsMessage);
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(PiggyDimens.radiusSm),
                        ),
                      ),
                      child: Text(
                        AppLocalizations.of(context)!.reminderOpenAppSettings,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],

          // 说明文字
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: PiggyTokens.surfaceSecondary(context),
              borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
              border: isDark
                  ? null
                  : Border.all(
                      color: PiggyTokens.borderStrong(context),
                      width: 0.5,
                    ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context)!.reminderDescription,
                  style: TextStyle(
                    fontSize: 13,
                    color: PiggyTokens.textSecondary(context),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  Platform.isIOS
                      ? AppLocalizations.of(context)!.reminderIOSInstructions
                      : AppLocalizations.of(context)!
                          .reminderAndroidInstructions,
                  style: PiggyTextTokens.label(context).copyWith(
                      color: PiggyTokens.textTertiary(context), height: 1.4),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
