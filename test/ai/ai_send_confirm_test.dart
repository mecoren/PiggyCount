/// AI 外发会话级二次确认门（安全加固）行为契约：
/// - 未注入确认通道 → fail-closed（拒绝外发）；
/// - 用户取消 → 不发送；确认后同会话不再重复打扰；
/// - 工厂二道关先查「持久同意」再查「会话确认」；
/// - 后台自动化用 runBypassed 显式旁路，作用域外自动恢复。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/ai/privacy/ai_privacy_consent.dart';
import 'package:piggycount/ai/privacy/ai_send_confirm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  void consent(bool agreed) {
    AiPrivacyConsentStore.testSecureStore = agreed
        ? {AiPrivacyConsentStore.prefsKey: '$kAiPrivacyConsentVersion'}
        : <String, String>{};
  }

  setUp(() {
    AiSendConfirmGate.resetForTest();
    consent(true);
  });

  group('ensureConfirmed', () {
    test('未注入确认通道 → fail-closed', () async {
      AiSendConfirmGate.setUiConfirmForTest(null);
      expect(await AiSendConfirmGate.ensureConfirmed(), isFalse);
    });

    test('用户确认 → true，且同会话不再二次调用回调', () async {
      var calls = 0;
      AiSendConfirmGate.setUiConfirmForTest(() async {
        calls++;
        return true;
      });

      expect(await AiSendConfirmGate.ensureConfirmed(), isTrue);
      expect(await AiSendConfirmGate.ensureConfirmed(), isTrue);
      expect(calls, 1, reason: '会话内确认过一次后不再打扰');
    });

    test('用户取消 → false，且下次仍会再问', () async {
      var calls = 0;
      AiSendConfirmGate.setUiConfirmForTest(() async {
        calls++;
        return false;
      });

      expect(await AiSendConfirmGate.ensureConfirmed(), isFalse);
      expect(await AiSendConfirmGate.ensureConfirmed(), isFalse);
      expect(calls, 2, reason: '取消不写会话态，下次重新确认');
    });
  });

  group('runBypassed', () {
    test('作用域内视为已确认，作用域外恢复', () async {
      AiSendConfirmGate.setUiConfirmForTest(null);

      final inside = await AiSendConfirmGate.runBypassed(
          () async => AiSendConfirmGate.ensureConfirmed());
      expect(inside, isTrue, reason: '后台非交互路径显式旁路');

      expect(await AiSendConfirmGate.ensureConfirmed(), isFalse,
          reason: '旁路仅限作用域内，退出后恢复 fail-closed');
    });
  });

  group('guardOutboundSend（工厂二道关）', () {
    test('未同意 → 抛 AiConsentRequiredException（即使已会话确认）', () async {
      consent(false);
      AiSendConfirmGate.setUiConfirmForTest(() async => true);
      await AiSendConfirmGate.ensureConfirmed();

      await expectLater(AiSendConfirmGate.guardOutboundSend(),
          throwsA(isA<AiConsentRequiredException>()));
    });

    test('已同意但未确认会话 → 抛 AiSendNotConfirmedException', () async {
      AiSendConfirmGate.setUiConfirmForTest(null);
      await expectLater(AiSendConfirmGate.guardOutboundSend(),
          throwsA(isA<AiSendNotConfirmedException>()));
    });

    test('已同意且已确认 → 放行', () async {
      AiSendConfirmGate.setUiConfirmForTest(() async => true);
      await AiSendConfirmGate.ensureConfirmed();
      await expectLater(AiSendConfirmGate.guardOutboundSend(), completes);
    });
  });
}
