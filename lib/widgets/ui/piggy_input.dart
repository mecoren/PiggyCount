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
  Widget? prefixIcon,
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
    prefixIcon: prefixIcon,
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

/// 表单输入框的统一圆角档位：介于 `radiusLg`(12) / `radiusXl`(16) 之间，
/// 与底部按钮行（`PiggySheetActions`）同档，两者同屏时圆角语言一致。
const double _kFormFieldRadius = 14;

/// 项目统一输入框装饰：**浅灰填充 + 细描边 + 浮动标签**（2026-10-15 起全项目口径）。
///
/// 基准实现：云同步配置三表单（`cloud_service_page.dart` 的 `_CloudConfigSheet`）
/// 与加密「设置密码」弹窗（`password_setup_dialog.dart`）。
///
/// 表单类输入框一律用它：待机浅灰底（`surfaceSecondary`，与取消键同源）+
/// 1px 中性描边（`borderStrong`），聚焦主题色 1.6px、错误 `error` 色 1 / 1.6，
/// `labelText` 浮到边框上。填充底让输入区在卡片底色上有明确的「可输入」边界，
/// 聚焦 / 错误只换描边色与线宽；水平内边距 `p16`，与字段区的 `p20` 留距
/// 形成内外层次；圆角与底部按钮行同为 14。
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
  OutlineInputBorder b(Color c, double w) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(_kFormFieldRadius),
        borderSide: w == 0 ? BorderSide.none : BorderSide(color: c, width: w),
      );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    hintStyle: TextStyle(color: PiggyTokens.textTertiary(context)),
    helperText: helper,
    errorText: errorText,
    prefixText: prefix,
    suffixIcon: suffixIcon,
    prefixIcon: prefixIcon,
    filled: true,
    fillColor: PiggyTokens.surfaceSecondary(context),
    contentPadding: const EdgeInsets.symmetric(
      horizontal: PiggyDimens.p16,
      vertical: 14,
    ),
    border: b(Colors.transparent, 0),
    enabledBorder: b(PiggyTokens.borderStrong(context), 1),
    focusedBorder: b(PiggyTokens.primary(context), 1.6),
    errorBorder: b(PiggyTokens.error(context), 1),
    focusedErrorBorder: b(PiggyTokens.error(context), 1.6),
  );
}
