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
/// 因此原生 `MainActivity.dispatchKeyEvent` 在「金额抽屉请求捕获」时截获数字 /
/// 运算 / 退格 / 回车键，经本通道回传 Dart，由金额抽屉消费；**吞掉这些键**（返回
/// true）避免与框架路径重复处理。capture 关闭时原生原样放行，备注框打字、系统
/// 按键（含 BACK）都不受影响。
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
