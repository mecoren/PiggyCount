import 'package:flutter/material.dart';

import '../../styles/tokens.dart';

/// 全应用统一的 filled 圆角输入框装饰（与账户编辑页同款）：
/// 底色 `surfaceInput` + 圆角 `radiusLg` + 待机无边框 +
/// 聚焦主题色 1.5 + 错误 error 色。
///
/// 各页禁止手写 `InputDecoration(border: UnderlineInputBorder…)` 裸下划线
/// 或各自拼 filled 样式，统一调这个（单源，换肤只改一处）。
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
