import 'package:flutter/material.dart';

import '../../styles/tokens.dart';

/// 无边框 filled 圆角输入框装饰——**仅限贴合卡片 / 列表的内嵌输入**：
/// 标题栏搜索框、币种 / 分类选择器与下拉组件内的搜索行等。
/// 底色 `surfaceInput` + 圆角 `radiusLg` + 待机无边框 + 聚焦主题色 1.5 + 错误 error 色。
///
/// 表单类输入框请用 [piggyOutlinedDecoration]（项目统一口径），不要用这个。
InputDecoration piggyFilledDecoration(
  BuildContext context, {
  String? label,
  String? hint,
  String? helper,
  String? errorText,
  Widget? suffixIcon,
}) {
  OutlineInputBorder b(Color c, double w) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        borderSide: w == 0 ? BorderSide.none : BorderSide(color: c, width: w),
      );
  final primary = PiggyTokens.primary(context);
  return InputDecoration(
    labelText: label,
    hintText: hint,
    hintStyle: TextStyle(color: PiggyTokens.textTertiary(context)),
    helperText: helper,
    errorText: errorText,
    suffixIcon: suffixIcon,
    filled: true,
    fillColor: PiggyTokens.surfaceInput(context),
    isDense: true,
    floatingLabelBehavior: FloatingLabelBehavior.auto,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: b(Colors.transparent, 0),
    enabledBorder: b(Colors.transparent, 0),
    focusedBorder: b(primary, 1.5),
    errorBorder: b(PiggyTokens.error(context), 1),
    focusedErrorBorder: b(PiggyTokens.error(context), 1.5),
  );
}

/// 项目统一输入框装饰：**描边式 + 浮动标签**（2026-09-30 起全项目口径）。
///
/// 基准实现：云同步配置三表单（`cloud_service_page.dart` 的 `_CloudConfigSheet`）
/// 与加密「设置密码」弹窗（`password_setup_dialog.dart`）。
///
/// 表单类输入框一律用它：待机 1px 中性描边、聚焦主题色 2px、`labelText` 浮到
/// 边框上，内容直接浮在卡片 / 弹窗底色上时也能看清边界（filled 底色与卡片同色
/// 会让边界消失）。颜色 / 线宽沿用 `OutlineInputBorder` 的 M3 默认推导。
///
/// 无边框内嵌输入（标题栏搜索框、选择器内搜索行、金额显示位）用
/// [piggyFilledDecoration]，不要套描边——见 `AGENTS.md` 输入框规范。
InputDecoration piggyOutlinedDecoration(
  BuildContext context, {
  String? label,
  String? hint,
  String? helper,
  String? errorText,
  String? prefix,
  Widget? suffixIcon,
  Widget? prefixIcon,
}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    hintStyle: TextStyle(color: PiggyTokens.textTertiary(context)),
    helperText: helper,
    errorText: errorText,
    prefixText: prefix,
    suffixIcon: suffixIcon,
    prefixIcon: prefixIcon,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
    ),
  );
}
