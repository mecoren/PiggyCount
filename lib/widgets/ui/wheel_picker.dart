import 'package:flutter/cupertino.dart';
import '../../styles/tokens.dart';
import 'haptics.dart';
import 'picker_sheet.dart';

/// 通用滚轮选择器（外壳走 [PiggyPickerSheet]）
class WheelPicker<T> extends StatefulWidget {
  final T initial;
  final List<T> items;
  final String Function(T) labelBuilder;
  final String title;

  const WheelPicker({
    super.key,
    required this.initial,
    required this.items,
    required this.labelBuilder,
    required this.title,
  });

  @override
  State<WheelPicker<T>> createState() => _WheelPickerState<T>();
}

class _WheelPickerState<T> extends State<WheelPicker<T>> {
  Color _textPrimary(BuildContext context) => PiggyTokens.textPrimary(context);

  late T selected;
  late FixedExtentScrollController _controller;

  @override
  void initState() {
    super.initState();
    selected = widget.initial;
    final index = widget.items.indexOf(selected);
    _controller =
        FixedExtentScrollController(initialItem: index >= 0 ? index : 0);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;

    return PiggyPickerSheet(
      title: widget.title,
      onConfirm: () => Navigator.pop(context, selected),
      child: SizedBox(
        height: 156,
        child: CupertinoPicker(
          itemExtent: 52,
          scrollController: _controller,
          onSelectedItemChanged: (i) {
            PiggyHaptics.selection();
            setState(() {
              selected = items[i];
            });
          },
          children: [
            for (final item in items)
              Center(
                child: Text(
                  widget.labelBuilder(item),
                  style: TextStyle(fontSize: PiggyTextTokens.fs18, color: _textPrimary(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 显示滚轮选择器
Future<T?> showWheelPicker<T>(
  BuildContext context, {
  required T initial,
  required List<T> items,
  required String Function(T) labelBuilder,
  required String title,
}) {
  return showPiggyPickerSheet<T>(
    context,
    builder: (_) => WheelPicker<T>(
      initial: initial,
      items: items,
      labelBuilder: labelBuilder,
      title: title,
    ),
  );
}
