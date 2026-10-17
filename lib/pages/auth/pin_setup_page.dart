import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../providers/security_providers.dart';
import '../../services/security/app_lock_service.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/pin_entry_pad.dart';
import '../../l10n/app_localizations.dart';

enum PinSetupMode { create, change }

class PinSetupPage extends ConsumerStatefulWidget {
  final PinSetupMode mode;

  const PinSetupPage({super.key, this.mode = PinSetupMode.create});

  @override
  ConsumerState<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends ConsumerState<PinSetupPage> {
  // 步骤：0=验证旧PIN（仅change模式）, 1=输入新PIN, 2=确认新PIN
  int _step = 0;
  String _pin = '';
  String _firstPin = '';
  bool _isError = false;
  // S2：PIN 长度可选 4 / 6 位。改密时先按已保存长度自动校验旧 PIN。
  int _pinLength = AppLockService.kDefaultPinLength;

  @override
  void initState() {
    super.initState();
    _step = widget.mode == PinSetupMode.change ? 0 : 1;
    _loadStoredLength();
  }

  Future<void> _loadStoredLength() async {
    final stored = await AppLockService.getPinLength();
    if (!mounted || stored == _pinLength) return;
    setState(() => _pinLength = stored);
  }

  String get _title {
    final l10n = AppLocalizations.of(context);
    if (_step == 0) return l10n.appLockVerifyCurrentPin;
    if (_step == 1) return l10n.appLockSetNewPin;
    return l10n.appLockConfirmPin;
  }

  void _onNumberTap(String number) {
    if (_pin.length >= _pinLength) return;
    setState(() {
      _isError = false;
      _pin += number;
    });
    if (_pin.length == _pinLength) {
      _handlePinComplete();
    }
  }

  void _onDelete() {
    if (_pin.isEmpty) return;
    setState(() {
      _isError = false;
      _pin = _pin.substring(0, _pin.length - 1);
    });
  }

  Future<void> _handlePinComplete() async {
    if (_step == 0) {
      // 验证旧 PIN
      final valid = await AppLockService.verifyPin(_pin);
      if (valid) {
        setState(() {
          _step = 1;
          _pin = '';
        });
      } else {
        _showError();
      }
    } else if (_step == 1) {
      // 记录第一次输入
      setState(() {
        _firstPin = _pin;
        _pin = '';
        _step = 2;
      });
    } else {
      // 确认 PIN
      if (_pin == _firstPin) {
        await AppLockService.setPin(_pin, length: _pinLength);
        ref.read(appLockEnabledProvider.notifier).state = true;
        if (mounted) {
          showToast(context, AppLocalizations.of(context).appLockPinSetSuccess);
          Navigator.pop(context, true);
        }
      } else {
        _showError();
        // 重置到输入新 PIN 步骤
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) {
          setState(() {
            _step = 1;
            _firstPin = '';
          });
        }
      }
    }
  }

  void _showError() {
    setState(() => _isError = true);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _pin = '';
          _isError = false;
        });
      }
    });
  }

  /// 4 位 / 6 位 PIN 选择器（S2，仅新建 PIN 步骤可见）。
  Widget _buildLengthSelector() {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        Text(
          l10n.appLockPinLengthTitle,
          style: TextStyle(
            fontSize: PiggyTextTokens.fs13.scaled(context, ref),
            color: PiggyTokens.textSecondary(context),
          ),
        ),
        SizedBox(height: 8.0.scaled(context, ref)),
        // 用项目统一分段控件（Material SegmentedButton 的圆角/配色与
        // PiggyDimens/PiggyTokens 不一致，见 custom_field_manage_page 的说明）。
        PiggySegmentedControl<int>(
          options: [
            for (final len in AppLockService.kSupportedPinLengths)
              PiggySegmentOption<int>(
                value: len,
                label: l10n.appLockPinLengthOption(len),
              ),
          ],
          selected: _pinLength,
          onChanged: (next) {
            if (next == _pinLength) return;
            setState(() {
              _pinLength = next;
              _pin = '';
              _firstPin = '';
              _isError = false;
            });
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: widget.mode == PinSetupMode.create
            ? AppLocalizations.of(context).appLockSetPin
            : AppLocalizations.of(context).appLockChangePin,
        showBack: true,
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: Column(
          children: [
            Expanded(
              child: SafeArea(
                top: false,
                child: Column(
                  children: [
                    const Spacer(flex: 2),
                    // 步骤提示
                    Text(
                      _title,
                      style: TextStyle(
                        fontSize: PiggyTextTokens.fs18.scaled(context, ref),
                        fontWeight: FontWeight.w600,
                        color: PiggyTokens.textPrimary(context),
                      ),
                    ),
                    SizedBox(height: 32.0.scaled(context, ref)),
                    // PIN 圆点
                    PinDotIndicator(
                      length: _pinLength,
                      filledCount: _pin.length,
                      isError: _isError,
                    ),
                    // 长度选择（S2）：只在「输入新 PIN」步骤展示，改长度会清空
                    // 已输入内容（圆点数量随之变化，避免半截 PIN 直接提交）。
                    if (_step == 1) ...[
                      SizedBox(height: 24.0.scaled(context, ref)),
                      _buildLengthSelector(),
                    ],
                    const Spacer(flex: 1),
                    // 数字键盘
                    Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: 40.0.scaled(context, ref)),
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
          ],
        ),
      ),
    );
  }
}
