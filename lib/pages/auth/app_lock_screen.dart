import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../providers/security_providers.dart';
import '../../services/security/app_lock_service.dart';
import '../../widgets/biz/pin_entry_pad.dart';
import '../../widgets/biz/piggy_icon.dart';
import '../../widgets/ui/ui.dart';
import '../../l10n/app_localizations.dart';

class AppLockScreen extends ConsumerStatefulWidget {
  const AppLockScreen({super.key});

  @override
  ConsumerState<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends ConsumerState<AppLockScreen> {
  String _pin = '';
  bool _isError = false;
  bool _biometricAvailable = false;
  bool _biometricEnabled = false;
  String? _lockoutMessage;
  // wipe 执行后禁用键盘：数据已清，停留锁屏待用户重启
  bool _wiped = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    final canUse = await AppLockService.canUseBiometrics();
    final enabled = await AppLockService.isBiometricEnabled();
    if (mounted) {
      setState(() {
        _biometricAvailable = canUse;
        _biometricEnabled = enabled;
      });
      if (canUse && enabled) {
        _authenticateWithBiometrics();
      }
    }
  }

  Future<void> _authenticateWithBiometrics() async {
    final l10n = AppLocalizations.of(context);
    final success = await AppLockService.authenticateWithBiometrics(
      reason: l10n.appLockBiometricReason,
    );
    if (success && mounted) {
      _unlock();
    }
  }

  void _onNumberTap(String number) {
    if (_wiped || _pin.length >= 4) return;
    setState(() {
      _isError = false;
      _lockoutMessage = null;
      _pin += number;
    });
    if (_pin.length == 4) {
      _verifyPin();
    }
  }

  void _onDelete() {
    if (_pin.isEmpty) return;
    setState(() {
      _isError = false;
      _pin = _pin.substring(0, _pin.length - 1);
    });
  }

  Future<void> _verifyPin() async {
    final locked = await AppLockService.isLockedOut();
    if (!mounted) return;
    if (locked) {
      final remaining = await AppLockService.getLockoutRemaining();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        _isError = true;
        _lockoutMessage =
            l10n.appLockLockedOut(remaining.inSeconds.clamp(1, 3600));
        _pin = '';
      });
      return;
    }
    final enteredPin = _pin;
    final success = await AppLockService.verifyPin(enteredPin);
    if (!mounted) return;
    if (success) {
      _unlock();
    } else {
      // wipe 条件达成（开关开 + 连续失败达阈值）：提供清除数据选项。
      // 取消则停留锁屏（退避锁定仍在，不会被绕过）。
      if (await AppLockService.shouldWipe()) {
        if (!mounted) return;
        final confirmed = await AppDialog.confirm<bool>(
          context,
          title: AppLocalizations.of(context).appLockWipeConfirmTitle,
          message: AppLocalizations.of(context).appLockWipeConfirmMessage,
          destructive: true,
        );
        if (!mounted) return;
        if (confirmed == true) {
          await _runWipe();
          return;
        }
      }
      final remaining = await AppLockService.getLockoutRemaining();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      if (mounted) {
        setState(() {
          _isError = true;
          _lockoutMessage = remaining > Duration.zero
              ? l10n.appLockLockedOut(remaining.inSeconds.clamp(1, 3600))
              : null;
        });
      }
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        setState(() {
          _pin = '';
          _isError = false;
        });
      }
    }
  }

  void _unlock() {
    AppLockService.recordUnlock();
    ref.read(isAppLockedProvider.notifier).state = false;
  }

  /// 执行清除数据：成功后禁用键盘并提示重启（内存态重启前保持锁屏）。
  /// 部分失败的细节记日志，重启后用户可核对（尽力而为口径）。
  Future<void> _runWipe() async {
    await AppLockService.wipeAllData();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _wiped = true;
      _pin = '';
      _isError = false;
      _lockoutMessage = l10n.appLockWipedMessage;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final showBiometric = _biometricAvailable && _biometricEnabled;

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            // Logo
            PiggyIcon(
              size: 64.0.scaled(context, ref),
            ),
            SizedBox(height: 24.0.scaled(context, ref)),
            // 标题
            Text(
              l10n.appLockEnterPin,
              style: TextStyle(
                fontSize: 18.0.scaled(context, ref),
                fontWeight: FontWeight.w600,
                color: PiggyTokens.textPrimary(context),
              ),
            ),
            SizedBox(height: 32.0.scaled(context, ref)),
            // PIN 圆点
            PinDotIndicator(
              filledCount: _pin.length,
              isError: _isError,
            ),
            if (_lockoutMessage != null) ...[
              SizedBox(height: 12.0.scaled(context, ref)),
              Text(
                _lockoutMessage!,
                style: TextStyle(
                  fontSize: 13.0.scaled(context, ref),
                  color: PiggyTokens.error(context),
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const Spacer(flex: 1),
            // 数字键盘
            Padding(
              padding:
                  EdgeInsets.symmetric(horizontal: 40.0.scaled(context, ref)),
              child: NumberPad(
                onNumberTap: _onNumberTap,
                onDelete: _onDelete,
                showBiometric: showBiometric,
                onBiometric: showBiometric ? _authenticateWithBiometrics : null,
              ),
            ),
            SizedBox(height: 32.0.scaled(context, ref)),
          ],
        ),
      ),
    );
  }
}
