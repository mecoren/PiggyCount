import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clearRecoveryCredentials 清空凭证与冷却标记（审计 S8）', () {
    final auth = PiggyCountCloudAuthService(
        baseUrl: 'https://unit.test', apiPrefix: '/api/v1');
    auth.setRecoveryCredentials(
        email: 'user@example.com', password: 'secret-pass-1');
    expect(auth.debugRecoveryEmail, 'user@example.com');
    expect(auth.debugSilentRecoveryArmed, isTrue);

    auth.clearRecoveryCredentials();
    expect(auth.debugRecoveryEmail, isNull);
    expect(auth.debugSilentRecoveryArmed, isFalse,
        reason: '登出后不得残留可用于静默重登的凭证');
  });

  test('setRecoveryCredentials 空串视为清除', () {
    final auth = PiggyCountCloudAuthService(
        baseUrl: 'https://unit.test', apiPrefix: '/api/v1');
    auth.setRecoveryCredentials(email: 'a@b.c', password: 'pw123456');
    auth.setRecoveryCredentials(email: '', password: '');
    expect(auth.debugRecoveryEmail, isNull);
    expect(auth.debugSilentRecoveryArmed, isFalse);
  });

  test('signOut 后恢复凭证被清空（无会话路径同样清理，审计 S8）', () async {
    final auth = PiggyCountCloudAuthService(
        baseUrl: 'https://unit.test', apiPrefix: '/api/v1');
    auth.setRecoveryCredentials(email: 'a@b.c', password: 'pw123456');
    await auth.signOut();
    expect(auth.debugSilentRecoveryArmed, isFalse,
        reason: '显式登出不得残留静默重登凭证');
  });
}
