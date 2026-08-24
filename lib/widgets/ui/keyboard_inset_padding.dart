import 'package:flutter/material.dart';

/// 键盘底部避让内边距（叶子组件）。
///
/// 独立读取 [MediaQuery.viewInsetsOf] 以隔离 rebuild 范围。
/// 键盘弹出/收起动画期间 viewInsets 每帧变化，若在父级 build 中读取
/// （如 `bottom: 16 + MediaQuery.of(context).viewInsets.bottom`）会导致
/// 整棵子树每帧重建。提取为叶子组件后，仅此 Padding 逐帧重建，
/// [child]（sheet 表单内容等）不受影响。
///
/// 用法：把其它方向的固定边距放在外层普通 Padding 中，
/// 本组件只负责叠加键盘高度：
///
/// ```dart
/// Padding(
///   padding: const EdgeInsets.only(left: 16, right: 16, top: 12),
///   child: KeyboardBottomInsetPadding(
///     extra: 16,
///     child: ...,
///   ),
/// )
/// ```
class KeyboardBottomInsetPadding extends StatelessWidget {
  const KeyboardBottomInsetPadding({
    super.key,
    this.extra = 0,
    required this.child,
  });

  /// 键盘高度之外额外追加的底部间距
  final double extra;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: extra + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: child,
    );
  }
}
