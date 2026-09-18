import 'package:flutter/foundation.dart';

/// 包内调试日志。
///
/// 用 `assert` 做 release 短路：release 构建下整段被摇树移除，且
/// [buildMessage] 是闭包 —— 未执行时连字符串插值都不发生（这点的
/// 意义在热路径上：形参式 `debugLog('x=$x')` 在 release 仍会拼串）。
///
/// 之所以不用裸 `print`：① 触发 `avoid_print` 静态告警；② release
/// 包会输出到 stdout，等于把内部状态泄漏给用户可见的日志流。
void debugLog(String Function() buildMessage) {
  assert(() {
    debugPrint(buildMessage());
    return true;
  }());
}
