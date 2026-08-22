import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../providers/security_providers.dart';
import '../../providers/theme_providers.dart';
import '../../services/security/app_lock_service.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/biz/pin_entry_pad.dart';
import '../../l10n/app_localizations.dart';
import '../auth/pin_setup_page.dart';

class AppLockSettingsPage extends ConsumerStatefulWidget {
  const AppLockSettingsPage({super.key});

  @override
  ConsumerState<AppLockSettingsPage> createState() =>
      _AppLockSettingsPageState();
}

class _AppLockSettingsPageState extends ConsumerState<AppLockSettingsPage> {
  bool _canUseBiometrics = false;

  @override
  void initState() {
    super.initState();
    _checkBiometricSupport();
  }

  Future<void> _checkBiometricSupport() async {
    final canUse = await AppLockService.canUseBiometrics();
    if (mounted) {
      setState(() => _canUseBiometrics = canUse);
    }
  }

  Future<void> _toggleAppLock(bool enable) async {
    final l10n = AppLocalizations.of(context);

    if (enable) {
      // 开启：跳转设置 PIN
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => const PinSetupPage(mode: PinSetupMode.create),
        ),
      );
      // 如果用户取消设置，开关回弹
      if (result != true) return;
    } else {
      // 关闭：需要验证当前 PIN
      final verified = await _verifyCurrentPin();
      if (!verified) return;

      await AppLockService.clearPin();
      ref.read(appLockEnabledProvider.notifier).state = false;
      ref.read(appLockBiometricEnabledProvider.notifier).state = false;
      if (mounted) {
        showToast(context, l10n.appLockDisabled);
      }
    }
  }

  Future<bool> _verifyCurrentPin() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const _PinVerifyPage(),
      ),
    );
    return result == true;
  }

  Future<void> _changePin() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const PinSetupPage(mode: PinSetupMode.change),
      ),
    );
  }

  Future<void> _toggleBiometric(bool enable) async {
    if (enable) {
      // 先验证生物识别可用
      final success = await AppLockService.authenticateWithBiometrics(
        reason: AppLocalizations.of(context).appLockBiometricReason,
      );
      if (!success) return;
    }
    ref.read(appLockBiometricEnabledProvider.notifier).state = enable;
    await AppLockService.setBiometricEnabled(enable);
  }

  void _showTimeoutPicker() {
    final l10n = AppLocalizations.of(context);
    final currentTimeout = ref.read(appLockTimeoutProvider);
    final primaryColor = ref.read(primaryColorProvider);

    final options = [
      (0, l10n.appLockTimeoutImmediate),
      (60, l10n.appLockTimeout1Min),
      (300, l10n.appLockTimeout5Min),
      (900, l10n.appLockTimeout15Min),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: PiggyTokens.surfaceElevated(context),
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(PiggyDimens.radiusXl)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  l10n.appLockTimeout,
                  style:
                      PiggyTextTokens.strongTitle(ctx).copyWith(fontSize: 16),
                ),
              ),
              ...options.map((opt) {
                final isSelected = opt.$1 == currentTimeout;
                return ListTile(
                  title: Text(opt.$2),
                  trailing: isSelected
                      ? Icon(Icons.check, color: primaryColor)
                      : null,
                  onTap: () {
                    ref.read(appLockTimeoutProvider.notifier).state = opt.$1;
                    AppLockService.setTimeoutSeconds(opt.$1);
                    Navigator.pop(ctx);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  String _timeoutLabel(int seconds) {
    final l10n = AppLocalizations.of(context);
    switch (seconds) {
      case 0:
        return l10n.appLockTimeoutImmediate;
      case 60:
        return l10n.appLockTimeout1Min;
      case 300:
        return l10n.appLockTimeout5Min;
      case 900:
        return l10n.appLockTimeout15Min;
      default:
        return '${seconds}s';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabled = ref.watch(appLockEnabledProvider);
    final biometricEnabled = ref.watch(appLockBiometricEnabledProvider);
    final timeout = ref.watch(appLockTimeoutProvider);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.appLockTitle,
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
          // 应用锁开关
          SettingsCard(
            children: [
              SettingsToggleItem(
                icon: Icons.lock_outline,
                title: l10n.appLockEnable,
                subtitle: l10n.appLockEnableDesc,
                value: enabled,
                onChanged: _toggleAppLock,
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: 16),
            // PIN 管理
            SettingsCard(
              children: [
                SettingsNavItem(
                  icon: Icons.dialpad,
                  title: l10n.appLockChangePin,
                  onTap: _changePin,
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 生物识别 + 超时
            SettingsCard(
              children: [
                if (_canUseBiometrics)
                  SettingsToggleItem(
                    icon: Icons.fingerprint,
                    title: l10n.appLockBiometric,
                    subtitle: l10n.appLockBiometricDesc,
                    value: biometricEnabled,
                    onChanged: _toggleBiometric,
                  ),
                SettingsNavItem(
                  icon: Icons.timer_outlined,
                  title: l10n.appLockTimeout,
                  subtitle: _timeoutLabel(timeout),
                  onTap: _showTimeoutPicker,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 验证当前 PIN 页面（用于关闭应用锁时验证）
class _PinVerifyPage extends ConsumerStatefulWidget {
  const _PinVerifyPage();

  @override
  ConsumerState<_PinVerifyPage> createState() => _PinVerifyPageState();
}

class _PinVerifyPageState extends ConsumerState<_PinVerifyPage> {
  String _pin = '';
  bool _isError = false;

  void _onNumberTap(String number) {
    if (_pin.length >= 4) return;
    setState(() {
      _isError = false;
      _pin += number;
    });
    if (_pin.length == 4) {
      _verify();
    }
  }

  void _onDelete() {
    if (_pin.isEmpty) return;
    setState(() {
      _isError = false;
      _pin = _pin.substring(0, _pin.length - 1);
    });
  }

  Future<void> _verify() async {
    final success = await AppLockService.verifyPin(_pin);
    if (success) {
      if (mounted) Navigator.pop(context, true);
    } else {
      setState(() => _isError = true);
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        setState(() {
          _pin = '';
          _isError = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.appLockVerifyPin,
        showBack: true,
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(
            top: PiggyTokens.topScrollablePadding(context),
          ),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Text(
                l10n.appLockVerifyCurrentPin,
                style: TextStyle(
                  fontSize: 18.0.scaled(context, ref),
                  fontWeight: FontWeight.w600,
                  color: PiggyTokens.textPrimary(context),
                ),
              ),
              SizedBox(height: 32.0.scaled(context, ref)),
              PinDotIndicator(
                filledCount: _pin.length,
                isError: _isError,
              ),
              const Spacer(flex: 1),
              Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: 40.0.scaled(context, ref)),
                child: NumberPad(
                  onNumberTap: _onNumberTap,
                  onDelete: _onDelete,
                ),
              ),
              SizedBox(height: 32.0.scaled(context, ref)),
            ],
          ),
        ),
      ),
    );
  }
}
