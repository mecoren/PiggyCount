import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';

/// 选择器底部抽屉的统一外壳（滚轮 / 列表 / 网格 / 单选 / 动作菜单共用）。
///
/// 与「同步设置 → 定时备份时间」的时间选择抽屉同口径：弹层底透明，悬浮卡片
/// （四周留距 + 四角圆角）承载内容，操作图标化到顶栏两端——取消 X 在左
/// （中性色）+ 标题居中（`strongTitle` 17）+ 确定钩子在右（主色），底部不放
/// 按钮行。
///
/// 没有确认动作的选择器（点选即应用 / 点选即收起）把 [onConfirm] 留空，
/// 顶栏只留 X + 标题（右侧补等宽占位，保证标题真正居中）。
///
/// 抽成共用组件的原因：`WheelTimePicker` / `WheelDatePicker` / `WheelPicker` /
/// `HolidayYearRangePicker` / 币种 / 账户 / 分类 / 网格 / 单选 / 附件来源等
/// 抽屉曾各自维护外壳与头部，改样式时极易漂移（旧的全宽平底弹层 +
/// 纯文本「取消｜标题｜确定」头部 `WheelPickerHeader` 已随统一删除）。
class PiggyPickerSheet extends StatelessWidget {
  const PiggyPickerSheet({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onConfirm,
    this.confirmLabel,
    this.confirmEnabled = true,
    this.onCancel,
    this.maxHeight,
  });

  /// 顶栏居中标题。
  final String title;

  /// 标题下的副说明（如标签选择器的「可多选」提示），可空。
  final String? subtitle;

  /// 滚轮 / 列表 / 网格等内容区，由各选择器自备（含自身内边距）。
  final Widget child;

  /// 顶栏右侧钩子回调，调用方通常在其中 `Navigator.pop(context, 结果)`。
  /// 为空 = 无确认动作：顶栏只留 X + 标题。
  final VoidCallback? onConfirm;

  /// 钩子的语义文案，仅用于 tooltip / 无障碍朗读，为空回落「确定」。
  final String? confirmLabel;

  /// 钩子是否可用；置 false 时钩子以禁用态呈现（如标签选择器数据未就绪）。
  final bool confirmEnabled;

  /// 取消 / 关闭回调，为空回落 `Navigator.pop`。
  final VoidCallback? onCancel;

  /// 卡片内容高度上限（内容自适应，超出则内部滚动；用 `ConstrainedBox`
  /// 而非固定高度，键盘弹出挤压可用高度时能自动收缩，不会顶出屏幕）。
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.commonCancel,
            onPressed: onCancel ?? () => Navigator.pop(context),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: PiggyTextTokens.strongTitle(context)
                      .copyWith(fontSize: 17),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    textAlign: TextAlign.center,
                    style: PiggyTextTokens.label(context).copyWith(
                      color: PiggyTokens.textTertiary(context),
                    ),
                  ),
              ],
            ),
          ),
          // 无确认动作时补等宽占位，保证标题在视觉上真正居中
          if (onConfirm != null)
            IconButton(
              icon: Icon(
                Icons.check,
                color: PiggyTokens.primary(context),
              ),
              tooltip: confirmLabel ?? l10n.commonOk,
              onPressed: confirmEnabled ? onConfirm : null,
            )
          else
            const SizedBox(width: 48),
        ],
      ),
    );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        // Flexible(loose)：本版 Flutter 给 Column 的非 flex 子项主轴约束是
        // 无界的，内部自带 `Expanded` / 滚动区的选择器会直接踩
        //「non-zero flex but incoming height constraints are unbounded」；
        // 包一层 loose flex 后拿到的剩余高度有界，同时不会拉伸滚轮这类
        // 自然高度的子项（tight 才会撑满）。
        Flexible(child: child),
        const SizedBox(height: 12),
      ],
    );

    final Widget sized = maxHeight == null
        ? content
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight!),
            child: content,
          );

    return Padding(
      // 键盘避让：选择器抽屉一般无输入框，保留以防插入输入型内容
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      // SafeArea 在外统一吃掉底部安全区，内部不再叠 paddingOf.bottom，避免双重留白
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            PiggyDimens.p16,
            0,
            PiggyDimens.p16,
            PiggyDimens.p16,
          ),
          // IconButton / CupertinoPicker / TextField / ListTile 均为 Material 系
          // 组件，transparent 路由底不提供 Material 祖先，必须显式包一层，
          // 否则直接红屏
          child: Material(
            color: PiggyTokens.surfaceElevated(context),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
            clipBehavior: Clip.antiAlias,
            child: sized,
          ),
        ),
      ),
    );
  }
}

/// 以统一外壳弹出选择器抽屉：[T] 是抽屉返回值类型。
Future<T?> showPiggyPickerSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  // 弹层底透明，卡片本身由 [PiggyPickerSheet] 内的 Material 绘制四角圆角
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    builder: builder,
  );
}
