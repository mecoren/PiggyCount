import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/encryption/encryption_service.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';

/// 加密密码对话框模式
enum PasswordDialogMode {
  /// 首次设置：密码 + 确认密码
  setup,

  /// 修改密码：旧密码 + 新密码 + 确认新密码
  change,

  /// 验证密码：仅密码（用于解锁/重置前的身份验证）
  verify,
}

/// 加密密码输入对话框
///
/// 三种模式：
/// - [PasswordDialogMode.setup]：首次开启加密，收集 (password, confirmPassword)
/// - [PasswordDialogMode.change]：修改密码，收集 (oldPassword, newPassword, confirmPassword)
/// - [PasswordDialogMode.verify]：验证身份，收集 (password)
///
/// 返回值：
/// - setup/change → `PasswordDialogResult`（含所有字段）；用户取消 → null
/// - verify → `String`（密码）；用户取消 → null
///
/// 校验逻辑：
/// - 密码长度 < 6 → 显示错误，不允许提交
/// - 确认密码不匹配 → 显示错误，不允许提交
/// - 修改模式下旧密码留空 → 显示错误
class PasswordSetupDialog extends ConsumerStatefulWidget {
  final PasswordDialogMode mode;

  const PasswordSetupDialog({super.key, required this.mode});

  /// setup / change 模式：返回 PasswordDialogResult 或 null（取消）
  static Future<PasswordDialogResult?> showForResult(
    BuildContext context, {
    required PasswordDialogMode mode,
  }) {
    return showDialog<PasswordDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PasswordSetupDialog(mode: mode),
    );
  }

  /// verify 模式：返回密码字符串或 null（取消）
  static Future<String?> showForVerify(BuildContext context) async {
    final result = await showDialog<PasswordDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          const PasswordSetupDialog(mode: PasswordDialogMode.verify),
    );
    return result?.password;
  }

  @override
  ConsumerState<PasswordSetupDialog> createState() =>
      _PasswordSetupDialogState();
}

/// 对话框返回结果
class PasswordDialogResult {
  /// 主密码（setup 模式下为新密码，change 模式下为新密码，verify 模式下为输入的密码）
  final String password;

  /// 旧密码（仅 change 模式有值）
  final String? oldPassword;

  const PasswordDialogResult({required this.password, this.oldPassword});
}

class _PasswordSetupDialogState extends ConsumerState<PasswordSetupDialog> {
  late final TextEditingController _oldPwdController;
  late final TextEditingController _pwdController;
  late final TextEditingController _confirmPwdController;

  bool _showOldPwd = false;
  bool _showPwd = false;
  bool _showConfirmPwd = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _oldPwdController = TextEditingController();
    _pwdController = TextEditingController();
    _confirmPwdController = TextEditingController();
  }

  @override
  void dispose() {
    _oldPwdController.dispose();
    _pwdController.dispose();
    _confirmPwdController.dispose();
    super.dispose();
  }

  bool get _isChangeMode => widget.mode == PasswordDialogMode.change;
  bool get _isVerifyMode => widget.mode == PasswordDialogMode.verify;
  bool get _needsConfirm => widget.mode != PasswordDialogMode.verify;

  String? get _validationError {
    final l10n = AppLocalizations.of(context);
    if (_isChangeMode && _oldPwdController.text.isEmpty) {
      return l10n.cloudSyncEncryptOldPasswordLabel;
    }
    if (_pwdController.text.length < EncryptionService.minPasswordLength) {
      return l10n.cloudSyncEncryptPasswordTooShort;
    }
    if (_needsConfirm && _pwdController.text != _confirmPwdController.text) {
      return l10n.cloudSyncEncryptPasswordMismatch;
    }
    return null;
  }

  bool get _canSubmit => _validationError == null;

  void _onSubmit() {
    final error = _validationError;
    if (error != null) {
      setState(() => _errorMessage = error);
      return;
    }
    Navigator.of(context).pop(
      PasswordDialogResult(
        password: _pwdController.text,
        oldPassword:
            _isChangeMode ? _oldPwdController.text : null,
      ),
    );
  }

  void _onCancel() {
    Navigator.of(context).pop();
  }

  /// 简单的密码强度评估
  /// 返回 0-3：0=空，1=弱，2=中，3=强
  int _passwordStrength(String pwd) {
    if (pwd.isEmpty) return 0;
    int score = 0;
    if (pwd.length >= 8) score++;
    if (RegExp(r'[A-Z]').hasMatch(pwd) ||
        RegExp(r'[a-z]').hasMatch(pwd)) {
      score++;
    }
    if (RegExp(r'[0-9]').hasMatch(pwd)) score++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(pwd)) score++;
    return score > 3 ? 3 : score;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final strength = _passwordStrength(_pwdController.text);

    return AlertDialog(
      scrollable: true, // 审计 U3：小屏+键盘弹起时内容可滚动
      title: Text(_title(l10n)),
      content: SizedBox(
        width: (MediaQuery.sizeOf(context).width - 32).clamp(0.0, 320.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isChangeMode) ...[
              _buildPasswordField(
                controller: _oldPwdController,
                label: l10n.cloudSyncEncryptOldPasswordLabel,
                show: _showOldPwd,
                onToggle: () => setState(() => _showOldPwd = !_showOldPwd),
                onChanged: () => setState(() => _errorMessage = null),
              ),
              const SizedBox(height: 12),
            ],
            _buildPasswordField(
              controller: _pwdController,
              label: _isVerifyMode
                  ? l10n.cloudSyncEncryptPasswordLabel
                  : (_isChangeMode
                      ? l10n.cloudSyncEncryptNewPasswordLabel
                      : l10n.cloudSyncEncryptPasswordLabel),
              show: _showPwd,
              onToggle: () => setState(() => _showPwd = !_showPwd),
              onChanged: () => setState(() => _errorMessage = null),
              autofocus: !_isChangeMode,
            ),
            if (_needsConfirm) ...[
              if (_pwdController.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildStrengthIndicator(strength),
              ],
              const SizedBox(height: 12),
              _buildPasswordField(
                controller: _confirmPwdController,
                label: l10n.cloudSyncEncryptConfirmPasswordLabel,
                show: _showConfirmPwd,
                onToggle: () =>
                    setState(() => _showConfirmPwd = !_showConfirmPwd),
                onChanged: () => setState(() => _errorMessage = null),
              ),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.error.withValues(
                        alpha: 0.08,
                      ),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline,
                        size: 16, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (!_isVerifyMode) ...[
              const SizedBox(height: 8),
              Text(
                l10n.cloudSyncEncryptMultiDeviceHint,
                style: TextStyle(
                  color: PiggyTokens.textTertiary(context),
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _onCancel,
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _canSubmit ? _onSubmit : null,
          child: Text(_submitLabel(l10n)),
        ),
      ],
    );
  }

  String _title(AppLocalizations l10n) {
    switch (widget.mode) {
      case PasswordDialogMode.setup:
        return l10n.cloudSyncEncryptSetPassword;
      case PasswordDialogMode.change:
        return l10n.cloudSyncEncryptChangePassword;
      case PasswordDialogMode.verify:
        return l10n.cloudSyncEncryptPasswordLabel;
    }
  }

  String _submitLabel(AppLocalizations l10n) {
    switch (widget.mode) {
      case PasswordDialogMode.setup:
        return l10n.commonConfirm;
      case PasswordDialogMode.change:
        return l10n.commonConfirm;
      case PasswordDialogMode.verify:
        return l10n.commonConfirm;
    }
  }

  Widget _buildPasswordField({
    required TextEditingController controller,
    required String label,
    required bool show,
    required VoidCallback onToggle,
    required VoidCallback onChanged,
    bool autofocus = false,
  }) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: !show,
      onChanged: (_) => onChanged(),
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          icon: Icon(show
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined),
          onPressed: onToggle,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
    );
  }

  Widget _buildStrengthIndicator(int strength) {
    if (strength == 0) return const SizedBox.shrink();

    final colors = [
      Colors.grey,
      Colors.red,
      Colors.orange,
      Colors.green,
    ];

    return Row(
      children: [
        ...List.generate(3, (i) {
          final active = i < strength;
          return Expanded(
            child: Container(
              height: 3,
              margin: EdgeInsets.only(right: i < 2 ? 4 : 0),
              decoration: BoxDecoration(
                color: active ? colors[strength] : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
              ),
            ),
          );
        }),
      ],
    );
  }
}
