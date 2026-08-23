import 'dart:async';
import 'dart:io';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldClearSessionOnRefreshError（审计 S16）', () {
    test('网络类异常 → 保留会话', () {
      expect(PiggyCountCloudProvider.shouldClearSessionOnRefreshError(
          SocketException('offline')), isFalse);
      expect(PiggyCountCloudProvider.shouldClearSessionOnRefreshError(
          TimeoutException('slow')), isFalse);
      expect(PiggyCountCloudProvider.shouldClearSessionOnRefreshError(
          Exception('HTTP 500 server error')), isFalse);
    });
    test('确定性认证失效 → 清空会话', () {
      expect(PiggyCountCloudProvider.shouldClearSessionOnRefreshError(
          CloudAuthException('refresh token rejected')), isTrue);
      expect(PiggyCountCloudProvider.shouldClearSessionOnRefreshError(
          Exception('HTTP 401 unauthorized')), isTrue);
      expect(PiggyCountCloudProvider.shouldClearSessionOnRefreshError(
          Exception('HTTP 403 forbidden')), isTrue);
    });
  });
}
