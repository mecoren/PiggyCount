import 'package:flutter/foundation.dart';

import 'ai_privacy_consent.dart';

/// AI 外发**会话级二次确认**门（安全加固）。
///
/// 与一次性「告知+同意」（[AiPrivacyConsentStore]）不同：用户可能早已
/// 授过权，但此刻未必想把这笔内容发出去。本门在**每次会话的首次外发**前
/// 再确认一次，同一会话确认后不再重复打扰（用户主动取消 → 本次不发）。
///
/// 工厂（`AIProviderFactory`）是无 `BuildContext` 的纯 Dart，故确认动作由
/// UI 通过 [uiConfirm] 注入（App 启动时用全局 Navigator 接线）。**未注入
/// 确认通道时 [ensureConfirmed] 返回 false（fail-closed）**——非交互后台
/// 自动化必须显式走 [runBypassed] 声明「用户已在自动化设置中显式开启」，
/// 不能靠「没有 UI」蒙混放行。
class AiSendConfirmGate {
  AiSendConfirmGate._();

  /// 本会话是否已二次确认。
  static bool _confirmedInSession = false;

  /// 旁路深度（非交互后台路径）>0 时视为已确认。
  static int _bypassDepth = 0;

  /// UI 注入的确认回调（弹确认框，返回 true=允许发送）。null = 无确认通道。
  ///
  /// 生产环境由 `main.dart` 用全局 Navigator 接线；未接线时按 fail-closed
  /// 处理（[ensureConfirmed] 返回 false）。
  static Future<bool> Function()? uiConfirm;

  static bool get isConfirmedInSession =>
      _confirmedInSession || _bypassDepth > 0;

  /// 确保本次会话已确认；返回 true 表示允许外发。
  static Future<bool> ensureConfirmed() async {
    if (isConfirmedInSession) return true;
    final cb = uiConfirm;
    if (cb == null) return false;
    final ok = await cb();
    if (ok) _confirmedInSession = true;
    return ok;
  }

  /// 外发前统一守卫（工厂二道关）：先查持久同意的二道关，再查会话二次确认。
  ///
  /// 任一不满足即抛强类型异常，由调用方（UI 渠道）转换为用户可读提示；
  /// 交互渠道应在发起前先调 [ensureConfirmed] 并静默取消，避免把「用户
  /// 主动取消」误报成「发送失败」。
  static Future<void> guardOutboundSend() async {
    if (!await AiPrivacyConsentStore.isConsented()) {
      throw const AiConsentRequiredException();
    }
    if (!await ensureConfirmed()) {
      throw const AiSendNotConfirmedException();
    }
  }

  /// 非交互后台路径的显式旁路作用域（如定时/自动记账）。
  ///
  /// 使用点必须写清「为什么无需交互确认」；不得用于用户主动发起的渠道。
  static Future<T> runBypassed<T>(Future<T> Function() action) async {
    _bypassDepth++;
    try {
      return await action();
    } finally {
      _bypassDepth--;
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _confirmedInSession = false;
    _bypassDepth = 0;
    uiConfirm = null;
  }

  @visibleForTesting
  static void setUiConfirmForTest(Future<bool> Function()? cb) {
    uiConfirm = cb;
  }
}

/// 尚未同意 AI 数据共享条款（工厂二道关）。
///
/// 与「一次性同意」的区别：本异常出现在**未同意却已发起外发**时，说明有
/// 渠道绕过了设置页的同意流程，属防御性拦截。
class AiConsentRequiredException implements Exception {
  final String message;

  const AiConsentRequiredException([
    this.message = '尚未同意 AI 数据共享条款',
  ]);

  @override
  String toString() => 'AiConsentRequiredException: $message';
}

/// 本次会话尚未通过 AI 外发二次确认（用户取消或无确认通道）。
///
/// UI 渠道在发起前已确认过，正常不会看到本异常；出现即代表有路径跳过了
/// 交互确认，属防御性拦截。
class AiSendNotConfirmedException implements Exception {
  final String message;

  const AiSendNotConfirmedException([
    this.message = '本次会话尚未确认发送',
  ]);

  @override
  String toString() => 'AiSendNotConfirmedException: $message';
}
