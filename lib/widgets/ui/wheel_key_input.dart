import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/platform/hardware_key_bridge.dart';
import '../../styles/tokens.dart';

/// 段的值口径。
///
/// 定宽数字串的中间态两段不同，必须显式标注而不是「靠 min 大小猜」：
/// - [leadingZeros]：**高位前缀**语义 —— 键入位是整体高位，如年段 `202` → 2020
///   （2600 这种「少敲了两位的年份」由 clamp 收口）；
/// - [direct]：**直接数值**语义 —— 键入位就是数值本身，如月段 `1` → 1（而不是 10）。
enum WheelKeyPrefixMode { leadingZeros, direct }

/// 一个滚轮列在键盘通路里的规格：宽度 / 值域 / 落地动作。
///
/// [minOf] / [maxOf] / [currentOf] 都是**回调**而不是取值快照：日期段的可用范围
/// 随年、月变化（`minDate` / `maxDate` 裁剪 + 当月实际天数），必须每次按键现取。
class WheelKeyColumn {
  const WheelKeyColumn({
    required this.width,
    required this.minOf,
    required this.maxOf,
    required this.currentOf,
    required this.onApply,
    this.prefixMode = WheelKeyPrefixMode.direct,
  });

  /// 定宽位数：年 4、其余 2（敲满即定案并落到下一段）。
  final int width;

  /// 本段当前可选的最小值（含 `minDate` 裁剪与本段下限）。
  final int Function() minOf;

  /// 本段当前可选的最大值（日期段随年月变化）。
  final int Function() maxOf;

  /// 本段当前生效值（供 ±1 微调取基准）。
  final int Function() currentOf;

  /// 落地动作：由宿主把值写进自身状态 + 同步对应滚轮位置。
  final ValueChanged<int> onApply;

  final WheelKeyPrefixMode prefixMode;
}

/// 定宽数字串的键盘驱动：段缓冲、当前段、越界前推、退格与切段。
///
/// 三条规则合起来给出「完全不需要切列键」的手感（小键盘上没有方向键）：
/// 1. **命中**：`当前段缓冲 + 新数字` 仍在段值域内 → 直接生效；
/// 2. **越界前推**：超出段上限（如时段已有 `7`，再敲 `0` = 70 > 23）→ 当前段定案，
///    这一位推给下一段（`7` `0` `5` → 07:05）；
/// 3. **敲满定案**：缓冲达到段宽度 → 自动落到下一段（`20261015` 八位走完三段）。
///
/// 末段越界没有下一段可推，改为**重开一位**（秒段 `9` 再敲 `9` → 09）。
/// 年段（[WheelKeyPrefixMode.leadingZeros]）越界**不前推**：它是 4 位整体，
/// 敲 `3` 的意思是「想输 3xxx 年」而不是「跳到月段」，只做 clamp。
///
/// 无定时器：所有输入都是确定的，不做「等待若干毫秒自动定案」那类超时语义。
class WheelKeyInputController {
  WheelKeyInputController({
    required this.columns,
    required this.onConfirm,
    required this.onCancel,
  }) : _typed = List<String>.filled(columns.length, '');

  final List<WheelKeyColumn> columns;

  /// 回车：等价于顶栏钩子。
  final VoidCallback onConfirm;

  /// Esc：等价于顶栏 X。
  final VoidCallback onCancel;

  /// 每段本次键入的数字串。**定案（敲满 / 越界 / 回车）不清空**，只在用户显式
  /// 切段时重置 —— 这是退格能跨段回退的前提（见 [_backspace]）。
  final List<String> _typed;

  int _active = 0;
  bool _hasInput = false;

  /// 当前段下标（键盘键入落在哪一段）。
  int get activeIndex => _active;

  /// 本抽屉生命周期内是否发生过键盘键入（描边只在 true 时绘制，触摸路径零影响）。
  bool get hasKeyboardInput => _hasInput;

  /// 测试观察口：某段当前的键入缓冲。
  String typedDigitsOf(int index) => _typed[index];

  /// 处理一个逻辑键；返回 true = 本次按键已被消费。
  bool handleLogicalKey(LogicalKeyboardKey key) {
    final handled = _dispatch(key);
    if (handled) _hasInput = true;
    return handled;
  }

  bool _dispatch(LogicalKeyboardKey key) {
    final digit = kHardwareDigits[key];
    if (digit != null) {
      _typeInto(_active, digit);
      return true;
    }
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      _backspace();
      return true;
    }
    // 分段键：定案当前段并前进（不改当前段的值）。日期里 `.` / `/` 本就是分隔符，
    // 这里也承担「只想改某一列」的入口 —— 小键盘没有方向键，只靠它。
    if (key == LogicalKeyboardKey.period ||
        key == LogicalKeyboardKey.numpadDecimal ||
        key == LogicalKeyboardKey.comma ||
        key == LogicalKeyboardKey.slash ||
        key == LogicalKeyboardKey.numpadDivide) {
      moveTo(_active + 1);
      return true;
    }
    if (key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd ||
        key == LogicalKeyboardKey.arrowUp) {
      _step(1);
      return true;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract ||
        key == LogicalKeyboardKey.arrowDown) {
      _step(-1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      moveTo(_active - 1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.tab) {
      moveTo(_active + 1);
      return true;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      onConfirm();
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      onCancel();
      return true;
    }
    // 其余（`*`、字母等）不消费，原样放行。
    return false;
  }

  /// 显式切段：目标段缓冲重置，免得旧前缀与新增键位粘成怪值。
  void moveTo(int index) {
    final target = index.clamp(0, columns.length - 1);
    if (target == _active) return;
    _active = target;
    _typed[target] = '';
  }

  /// 指针选中某列作为键盘输入目标（R7）：**无条件**清掉该列键入缓冲 —— 用户刚把
  /// 这列的滚动位置改了，旧前缀再粘新键位会得到怪值。
  ///
  /// 与 [moveTo] 的区别：[moveTo] 在目标段相同时直接返回 —— 键盘的「敲满自动前进 /
  /// `.` 切段」不能把下一段已开始的缓冲清掉，而这里的清空是刻意的。
  void selectColumn(int index) {
    _active = index.clamp(0, columns.length - 1);
    _typed[_active] = '';
  }

  /// 当前段 ±1（`+` / `-` / `↑` / `↓`），并把该段缓冲清掉：微调与键入前缀互斥。
  void _step(int delta) {
    final column = columns[_active];
    _typed[_active] = '';
    final value =
        (column.currentOf() + delta).clamp(column.minOf(), column.maxOf());
    column.onApply(value.toInt());
  }

  void _typeInto(int index, String digit) {
    final column = columns[index];
    final candidate = _typed[index] + digit;
    final raw = _rawValue(column, candidate);

    if (raw > column.maxOf() &&
        column.prefixMode == WheelKeyPrefixMode.direct) {
      if (index == columns.length - 1) {
        // 末段没有下一段可推 → 重开一位（"99" → 09）。
        _typed[index] = digit;
        column.onApply(
          _rawValue(column, digit)
              .clamp(column.minOf(), column.maxOf())
              .toInt(),
        );
        return;
      }
      moveTo(index + 1);
      _typeInto(index + 1, digit);
      return;
    }

    _typed[index] = candidate;
    column.onApply(raw.clamp(column.minOf(), column.maxOf()).toInt());
    if (_typed[index].length >= column.width && index < columns.length - 1) {
      moveTo(index + 1);
    }
  }

  /// 退格：删当前段缓冲末位并按剩余串重算；缓冲已空则往前找最近有键入的段继续。
  ///
  /// 这是**单调回退**，不做「退回打开抽屉那一刻的初值」（要那样得存整条键入历史
  /// 的快照栈，收益仅是连退回初值，不值当）。删空后值保持当前生效值。
  void _backspace() {
    var index = _active;
    if (_typed[index].isEmpty) {
      var prev = index - 1;
      while (prev >= 0 && _typed[prev].isEmpty) {
        prev--;
      }
      if (prev < 0) return;
      _active = prev;
      index = prev;
    }
    final column = columns[index];
    final remaining = _typed[index].substring(0, _typed[index].length - 1);
    _typed[index] = remaining;
    if (remaining.isEmpty) return;
    column.onApply(
      _rawValue(column, remaining)
          .clamp(column.minOf(), column.maxOf())
          .toInt(),
    );
  }

  /// 键入串 → 未 clamp 的原始值（用于越界判定）。
  int _rawValue(WheelKeyColumn column, String digits) {
    var s = digits;
    if (s.length > column.width) s = s.substring(s.length - column.width);
    if (s.isEmpty) return column.currentOf();
    var value = int.parse(s);
    if (column.prefixMode == WheelKeyPrefixMode.leadingZeros &&
        s.length < column.width) {
      var scale = 1;
      for (var i = s.length; i < column.width; i++) {
        scale *= 10;
      }
      value *= scale;
    }
    return value;
  }
}

/// 把键盘通路接进滚轮抽屉的 `State`。
///
/// `initState` 申请原生捕获、`dispose` 成对撤销 —— 两条互为镜像的硬约束：
/// 只 `addListener` 不 `setCaptureOwner`，MuMu / 投屏注入下**完全无效**（原生不
/// 转发）；只申请不撤销，抽屉关闭后会**持续吞掉数字键**（原生对捕获集合里的键
/// 一律 `return true`）。两步流里的日期步 / 时间步是两个独立路由，各自注册、各自
/// 撤销，不能只在外层做一次。
///
/// 闸门：[keyInputEnabled] + 路由 `isCurrent` + 焦点不在输入框内。抽屉里没有输入
/// 框，第三条是给将来加文本字段留的口径，与金额抽屉同一套判据。
mixin WheelKeyInputMixin<T extends StatefulWidget> on State<T> {
  WheelKeyInputController? _controller;

  /// 本抽屉的段规格（按当前模式给出真正存在的段，如 `y` 模式只有年份段）。
  List<WheelKeyColumn> buildKeyColumns();

  /// 回车动作：与顶栏钩子同一件事（定案并 `Navigator.pop(结果)`）。
  void confirmFromKeyboard();

  /// Esc 动作：默认与顶栏 X 同一件事。
  void cancelFromKeyboard() => Navigator.of(context).maybePop();

  /// 本形态当前是否可以接键（子类可覆盖）。
  bool get keyInputEnabled => true;

  /// 惰性建：段规格要读子类 `initState` 里就绪的滚动控制器，建早了会拿到空对象。
  WheelKeyInputController get keyInput =>
      _controller ??= WheelKeyInputController(
        columns: buildKeyColumns(),
        onConfirm: confirmFromKeyboard,
        onCancel: cancelFromKeyboard,
      );

  /// 一列的包装：当前段描边 + **指针选段**（R7：点按 / 鼠标滚轮选中的列即键盘输入
  /// 目标）。
  ///
  /// 刻意用指针级 [Listener] 而不是 `onSelectedItemChanged`：后者也会被键盘通路的
  /// `jumpToItem` 与邻列联动（`_syncMonthWheel` / `_syncDayWheel`）触发，会把活动段
  /// 在键入中途偷走（敲年导致月被 clamp 跳动时焦点被抢到月）。[Listener] 不参与
  /// 手势竞技场，对滚轮的拖动 / 抛掷零干扰。
  Widget keyColumn(int index, Widget picker) => Listener(
        onPointerDown: (_) => _selectColumn(index),
        onPointerSignal: (event) {
          // 鼠标滚轮滚列也算「选中该列」（模拟器 / 桌面利器）。
          if (event is PointerScrollEvent) _selectColumn(index);
        },
        child: WheelKeyActiveOverlay(
          active: keyInput.hasKeyboardInput && keyInput.activeIndex == index,
          child: picker,
        ),
      );

  void _selectColumn(int index) => setState(() => keyInput.selectColumn(index));

  bool get _keyGateOpen {
    if (!keyInputEnabled) return false;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext == null ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onFrameworkKey);
    HardwareKeyBridge.addListener(_onNativeKey);
    HardwareKeyBridge.setCaptureOwner(this, true);
  }

  @override
  void dispose() {
    HardwareKeyBridge.setCaptureOwner(this, false);
    HardwareKeyBridge.removeListener(_onNativeKey);
    HardwareKeyboard.instance.removeHandler(_onFrameworkKey);
    super.dispose();
  }

  bool _onFrameworkKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    if (!_keyGateOpen) return false;
    return _handleKey(event.logicalKey);
  }

  void _onNativeKey(int keyCode) {
    if (!_keyGateOpen) return;
    final key = logicalKeyFromAndroidKeyCode(keyCode);
    if (key != null) _handleKey(key);
  }

  bool _handleKey(LogicalKeyboardKey key) {
    final handled = keyInput.handleLogicalKey(key);
    // 值可能没变（`.` / `←` `→` 只切段、退格把缓冲删空），但「当前段」描边要跟着
    // 动，所以这里无条件重建一次；与段 `onApply` 里的 setState 同帧合并，不额外多跑。
    if (handled) setState(() {});
    return handled;
  }
}

/// 当前段「输入焦点」描边（仅在发生过键盘键入后出现）。
///
/// 只画描边不画填充：`CupertinoPicker` 自带的 selectionOverlay 已是圆角浅底，再叠
/// 一层底会糊成一坨；描边既准确表达「数字落在这里」，又不占布局 —— `Stack` +
/// `IgnorePointer`，不改变卡片高度、不吃滚轮手势，触摸路径逐像素不变。
class WheelKeyActiveOverlay extends StatelessWidget {
  const WheelKeyActiveOverlay({
    super.key,
    required this.active,
    required this.child,
    this.itemExtent = 52,
    this.viewportHeight = 156,
  });

  /// 描边只在 true 时绘制（测试与实现共用的锚点）。
  static const Key borderKey = ValueKey<String>('wheelKeyActiveOverlay');

  final bool active;
  final Widget child;
  final double itemExtent;
  final double viewportHeight;

  @override
  Widget build(BuildContext context) {
    // 结构必须恒定：`child` 永远待在 Stack 的首个插槽里（`Positioned.fill`），只有
    // 描边这个兄弟节点随 active 增删。
    //
    // 反例（曾踩过）：按 active 在「直接返回 child」与「包一层 Stack」之间切换。这样
    // 这一列的 CupertinoPicker 元素会在切换时被销毁重建，而重建后的
    // FixedExtentScrollController 会重新 attach 出一个以 `initialItem`（抽屉打开那
    // 一刻的值）为起点的 position —— 表现为敲完数字去点别的列时，本列滚轮连同取值
    // 悄悄退回初值（2026-10-15「月选 2 后点日，月变成 10」）。
    //
    // 「无 active 描边」时的尺寸口径不变：Stack 只有定位子节点，取
    // `constraints.biggest`，与滚轮自身撑满的结果一致（回归用例断言高度 156）。
    return Stack(
      children: [
        Positioned.fill(child: child),
        if (active)
          Positioned(
            left: 0,
            right: 0,
            top: (viewportHeight - itemExtent) / 2,
            height: itemExtent,
            child: IgnorePointer(
              child: DecoratedBox(
                key: borderKey,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: PiggyTokens.primary(context), width: 2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
