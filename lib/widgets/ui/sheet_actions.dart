import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import 'piggy_spinner.dart';

/// 底部抽屉双等宽操作按钮：左侧取消（中性灰填充 + 1px 浅描边）+
/// 右侧确认（主题色填充）。
///
/// 尺寸口径（2026-10-15 统一）：
/// - **按钮高度固定 37**：纵向内边距 8×2 + fs14 文本行高 21（`height: 1.5`，
///   全平台恒定，不随设备字体度量浮动）；
/// - 圆角 [_kRadius]（14）、按钮间距 12；
/// - 按钮行的左右内边距 20（与字段区对齐）、上下 12，与上方 1px 分隔线
///   由 [PiggyFormSheet] 施加。
///
/// 按压反馈（2026-10-15 统一）：按住时整钮**居中缩至 95%**，松开回弹，
/// 50ms 快速过渡；Material 的水波纹与按压高亮在本组件关闭 —— 按压只留
/// 缩放这一处反馈，不叠两套效果（实现见 [_PressScaleButton]）。
///
/// 口径：所有底部抽屉底部的取消/确认操作统一用本组件，不要在各抽屉里
/// 手写右对齐小按钮或单个全宽保存键。
class PiggySheetActions extends StatelessWidget {
  /// 按钮圆角 14（介于 [PiggyDimens.radiusLg] 12 与 [PiggyDimens.radiusXl] 16
  /// 之间的组件私有档位：与 ≈37 的按钮高比约 0.38，描边式等宽按钮在
  /// 该比例下最接近 iOS 警示框的观感）。
  static const double _kRadius = 14;

  /// 按钮内边距：横向 16、纵向 8（纵向是撑高的唯一来源）。
  static const EdgeInsets _kPadding = EdgeInsets.symmetric(
    horizontal: PiggyDimens.p16,
    vertical: PiggyDimens.p8,
  );

  final String cancelLabel;
  final String confirmLabel;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;

  /// 确认进行中：确认键切转圈并与取消键一并禁用（防连点）。
  final bool confirmBusy;

  const PiggySheetActions({
    super.key,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.onCancel,
    required this.onConfirm,
    this.confirmBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    final shape = WidgetStateProperty.all(
      const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(_kRadius)),
      ),
    );
    final textStyle = WidgetStateProperty.all(
      const TextStyle(
        fontSize: PiggyTextTokens.fs14,
        fontWeight: FontWeight.w500,
        // 固定行高 21：按钮高 = 8×2 + 21 = 37，不让中文行高随设备
        // 字体度量漂移（33~39 的浮动会让同一抽屉在不同机型上差一档）。
        height: 1.5,
      ),
    );
    final confirmStyle = ButtonStyle(
      // Size.zero：不吃 Material 默认的 Size(64, 40) 最小高度，
      // 高度完全由 [_kPadding] 纵向 + 固定行高决定。
      minimumSize: WidgetStateProperty.all(Size.zero),
      padding: WidgetStateProperty.all(_kPadding),
      // shrinkWrap：关掉 Material 默认在按钮外垫的 48 虚拟命中区 ——
      // 它不是视觉的一部分，但会把按钮行与分隔线 / 卡片底的视觉留白
      // 由 12 顶到 21（命中区 48 - 按钮 37 = 11，两侧各摊 5.5）。
      // 命中区 = 按钮本体（37 高 × 半个卡宽），宽度充足、不欠可点性。
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      // 关掉 Material 默认的按压墨水（水波纹 + 高亮底）：按压反馈统一由
      // [_PressScaleButton] 的缩放入场，叠上墨水会变成两套反馈同时出现。
      splashFactory: NoSplash.splashFactory,
      overlayColor: WidgetStateProperty.all(Colors.transparent),
      shape: shape,
      textStyle: textStyle,
    );
    final cancelStyle = confirmStyle.merge(ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? null
            : PiggyTokens.surfaceSecondary(context),
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? null
            : PiggyTokens.textPrimary(context),
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? null
            : BorderSide(color: PiggyTokens.borderStrong(context)),
      ),
      elevation: WidgetStateProperty.all(0),
    ));
    return Row(
      children: [
        Expanded(
          child: _PressScaleButton(
            onPressed: confirmBusy ? null : onCancel,
            style: cancelStyle,
            child: Text(cancelLabel),
          ),
        ),
        const SizedBox(width: PiggyDimens.p12),
        Expanded(
          child: _PressScaleButton(
            onPressed: confirmBusy ? null : onConfirm,
            style: confirmStyle,
            child: confirmBusy
                ? PiggySpinner(
                    size: 18,
                    color: PiggyTokens.textOnPrimary(context),
                  )
                : Text(confirmLabel),
          ),
        ),
      ],
    );
  }
}

/// 按压缩放按钮：按住时整钮居中缩至 95%、松开回弹（过渡 50ms）。
///
/// 缩放挂在 [WidgetStatesController] 的真实按压态上（与按钮自身的
/// pressed 手势状态同源）：手势被外层的下拉关闭抢走时会走 cancel、
/// 缩放随之收回，不会停在按下态。
class _PressScaleButton extends StatefulWidget {
  const _PressScaleButton({
    required this.onPressed,
    required this.style,
    required this.child,
  });

  final VoidCallback? onPressed;
  final ButtonStyle style;
  final Widget child;

  @override
  State<_PressScaleButton> createState() => _PressScaleButtonState();
}

class _PressScaleButtonState extends State<_PressScaleButton> {
  /// 按住时缩至 95%、过渡 50ms（按下与回弹同一时长）。
  static const double _pressedScale = 0.95;
  static const Duration _pressDuration = Duration(milliseconds: 50);

  final WidgetStatesController _states = WidgetStatesController();
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_syncPressed);
  }

  @override
  void dispose() {
    _states.removeListener(_syncPressed);
    _states.dispose();
    super.dispose();
  }

  void _syncPressed() {
    final pressed = _states.value.contains(WidgetState.pressed);
    if (pressed != _pressed) setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? _pressedScale : 1,
      duration: _pressDuration,
      child: FilledButton(
        onPressed: widget.onPressed,
        style: widget.style,
        statesController: _states,
        child: widget.child,
      ),
    );
  }
}
