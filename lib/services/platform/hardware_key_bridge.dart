import 'package:flutter/services.dart';

/// Android Activity 层硬件按键转发桥（MuMu 模拟器 / 投屏注入专用兜底）。
///
/// 背景：物理按键在 Android 上有两条到达 App 的路径——
/// ① `FlutterView.dispatchKeyEvent → KeyboardManager → 框架 HardwareKeyboard`；
/// ② `Activity.dispatchKeyEvent`（窗口最外层，先于视图树）。
/// 实测在 **MuMu 模拟器与投屏注入**下，注入按键进不了 ①（框架 [HardwareKeyboard]
/// 收不到任何事件，连聚焦的 Flutter 输入框也打不进字），但 Activity 级路径是活的
/// （BACK 能经 Activity 导航通道弹栈、原生 EditText 能收到注入的字符）。
///
/// 因此原生 `MainActivity.dispatchKeyEvent` 在「金额抽屉 / 日期时间滚轮抽屉请求
/// 捕获」时截获数字 / 运算 / 退格 / 回车 / 方向键，经本通道回传 Dart，由请求方
/// 消费；**吞掉这些键**（返回 true）避免与框架路径重复处理。capture 关闭时原生
/// 原样放行，备注框打字、系统按键（含 BACK）都不受影响。
///
/// 金额位是纯展示组件、无输入连接，本通路**不会弹输入法**。
///
/// 多实例：快捷抽屉的支出 / 收入两份表单在 IndexedStack 里同时保活，两者都注册
/// 监听并各自按闸门判定；capture 用 owner 集合做**引用计数**（任一 owner 想要即
/// 开启），避免两份表单在切换分段时因 didUpdateWidget 调用次序而互相抢 / 放。
class HardwareKeyBridge {
  HardwareKeyBridge._();

  static const MethodChannel _channel =
      MethodChannel('com.wait.piggycount/hardware_keys');

  static final Set<void Function(int keyCode)> _listeners = {};
  static final Set<Object> _captureOwners = {};
  static bool _handlerInstalled = false;

  /// 注册原生按键回调（keyCode = Android `KeyEvent.keyCode`）。回调内部自行判定
  /// 是否消费；同一按键会广播给所有监听者。
  static void addListener(void Function(int keyCode) listener) {
    _listeners.add(listener);
    if (!_handlerInstalled) {
      _handlerInstalled = true;
      _channel.setMethodCallHandler(_handle);
    }
  }

  static void removeListener(void Function(int keyCode) listener) {
    _listeners.remove(listener);
  }

  /// 声明 / 撤销本 [owner] 对按键捕获的诉求。任一 owner 想要即向原生开启捕获。
  static void setCaptureOwner(Object owner, bool wants) {
    final changed =
        wants ? _captureOwners.add(owner) : _captureOwners.remove(owner);
    if (!changed) return;
    _applyCapture(_captureOwners.isNotEmpty);
  }

  static void _applyCapture(bool enabled) {
    // 忽略返回值与异常：非 Android 平台 / 通道未就绪时静默降级（框架路径仍在）。
    _channel
        .invokeMethod<void>('setCapture', {'enabled': enabled})
        .catchError((Object _) {});
  }

  static Future<dynamic> _handle(MethodCall call) async {
    if (call.method != 'onKeyDown') return;
    final args = call.arguments;
    final keyCode = args is Map ? (args['keyCode'] as int?) : null;
    if (keyCode == null) return;
    // 拷贝一份：回调可能在遍历中注销自身（抽屉关闭）。
    for (final listener in _listeners.toList(growable: false)) {
      listener(keyCode);
    }
  }
}

/// 硬件键盘数字键 → 字符（主键盘排与小键盘同映射）。
///
/// 非 const：`LogicalKeyboardKey` 无常量相等性，做不了 const map 的键。
/// 原先私有在 `AmountEditorSheet` 内，本版起与日期 / 时间滚轮抽屉共用（两处都要
/// 「敲数字」这件事，抄两份必然漂移）。
final Map<LogicalKeyboardKey, String> kHardwareDigits = {
  LogicalKeyboardKey.digit0: '0',
  LogicalKeyboardKey.digit1: '1',
  LogicalKeyboardKey.digit2: '2',
  LogicalKeyboardKey.digit3: '3',
  LogicalKeyboardKey.digit4: '4',
  LogicalKeyboardKey.digit5: '5',
  LogicalKeyboardKey.digit6: '6',
  LogicalKeyboardKey.digit7: '7',
  LogicalKeyboardKey.digit8: '8',
  LogicalKeyboardKey.digit9: '9',
  LogicalKeyboardKey.numpad0: '0',
  LogicalKeyboardKey.numpad1: '1',
  LogicalKeyboardKey.numpad2: '2',
  LogicalKeyboardKey.numpad3: '3',
  LogicalKeyboardKey.numpad4: '4',
  LogicalKeyboardKey.numpad5: '5',
  LogicalKeyboardKey.numpad6: '6',
  LogicalKeyboardKey.numpad7: '7',
  LogicalKeyboardKey.numpad8: '8',
  LogicalKeyboardKey.numpad9: '9',
};

/// Android `KeyEvent.keyCode` → [LogicalKeyboardKey]（原生 Activity 层转发用）。
///
/// MuMu 模拟器 / 投屏注入的物理按键进不了 Flutter 框架层，只能由原生
/// `MainActivity.dispatchKeyEvent` 截获后经 [HardwareKeyBridge] 回传原始 keyCode，
/// 在这里映射回逻辑键，复用与框架通路完全相同的处理。常量值取自
/// `android.view.KeyEvent`（KEYCODE_0=7…KEYCODE_9=16、KEYCODE_NUMPAD_0=144…）。
///
/// ⚠️ 与原生 `MainActivity.isCapturedKey` 的集合**对齐维护**：本表多出的
/// `TAB` / `FORWARD_DEL` / `ESCAPE` 原生侧刻意不捕获（捕获集合里命中的键一律被
/// 吞，吞 TAB 会破坏系统键盘导航与无障碍），它们只在框架层通路出现。
final Map<int, LogicalKeyboardKey> kAndroidKeyMap = {
  7: LogicalKeyboardKey.digit0,
  8: LogicalKeyboardKey.digit1,
  9: LogicalKeyboardKey.digit2,
  10: LogicalKeyboardKey.digit3,
  11: LogicalKeyboardKey.digit4,
  12: LogicalKeyboardKey.digit5,
  13: LogicalKeyboardKey.digit6,
  14: LogicalKeyboardKey.digit7,
  15: LogicalKeyboardKey.digit8,
  16: LogicalKeyboardKey.digit9,
  144: LogicalKeyboardKey.numpad0,
  145: LogicalKeyboardKey.numpad1,
  146: LogicalKeyboardKey.numpad2,
  147: LogicalKeyboardKey.numpad3,
  148: LogicalKeyboardKey.numpad4,
  149: LogicalKeyboardKey.numpad5,
  150: LogicalKeyboardKey.numpad6,
  151: LogicalKeyboardKey.numpad7,
  152: LogicalKeyboardKey.numpad8,
  153: LogicalKeyboardKey.numpad9,
  56: LogicalKeyboardKey.period, // KEYCODE_PERIOD
  55: LogicalKeyboardKey.comma, // KEYCODE_COMMA
  158: LogicalKeyboardKey.numpadDecimal, // KEYCODE_NUMPAD_DOT
  67: LogicalKeyboardKey.backspace, // KEYCODE_DEL
  112: LogicalKeyboardKey.delete, // KEYCODE_FORWARD_DEL
  81: LogicalKeyboardKey.add, // KEYCODE_PLUS
  157: LogicalKeyboardKey.numpadAdd, // KEYCODE_NUMPAD_ADD
  69: LogicalKeyboardKey.minus, // KEYCODE_MINUS
  156: LogicalKeyboardKey.numpadSubtract, // KEYCODE_NUMPAD_SUBTRACT
  17: LogicalKeyboardKey.asterisk, // KEYCODE_STAR
  155: LogicalKeyboardKey.numpadMultiply, // KEYCODE_NUMPAD_MULTIPLY
  76: LogicalKeyboardKey.slash, // KEYCODE_SLASH
  154: LogicalKeyboardKey.numpadDivide, // KEYCODE_NUMPAD_DIVIDE
  19: LogicalKeyboardKey.arrowUp, // KEYCODE_DPAD_UP
  20: LogicalKeyboardKey.arrowDown, // KEYCODE_DPAD_DOWN
  21: LogicalKeyboardKey.arrowLeft, // KEYCODE_DPAD_LEFT
  22: LogicalKeyboardKey.arrowRight, // KEYCODE_DPAD_RIGHT
  61: LogicalKeyboardKey.tab, // KEYCODE_TAB
  66: LogicalKeyboardKey.enter, // KEYCODE_ENTER
  160: LogicalKeyboardKey.numpadEnter, // KEYCODE_NUMPAD_ENTER
  111: LogicalKeyboardKey.escape, // KEYCODE_ESCAPE
};

/// 原生 keyCode 查表；未纳入映射的返回 null（调用方据此放行）。
LogicalKeyboardKey? logicalKeyFromAndroidKeyCode(int keyCode) =>
    kAndroidKeyMap[keyCode];
