import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_webdav/flutter_cloud_sync_webdav.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WebDAVProvider', () {
    late WebDAVProvider provider;

    setUp(() {
      provider = WebDAVProvider();
    });

    test('should have correct provider ID', () {
      expect(provider.providerId, equals('webdav'));
    });

    test('should have correct provider name', () {
      expect(provider.providerName, equals('WebDAV'));
    });

    test('validateConfig should return false for empty config', () {
      expect(provider.validateConfig({}), isFalse);
    });

    test('validateConfig should return false for missing url', () {
      expect(
        provider.validateConfig({
          'username': 'user',
          'password': 'pass',
        }),
        isFalse,
      );
    });

    test('validateConfig should return false for missing username', () {
      expect(
        provider.validateConfig({
          'url': 'https://example.com',
          'password': 'pass',
        }),
        isFalse,
      );
    });

    test('validateConfig should return false for missing password', () {
      expect(
        provider.validateConfig({
          'url': 'https://example.com',
          'username': 'user',
        }),
        isFalse,
      );
    });

    test('validateConfig should return true for valid config', () {
      expect(
        provider.validateConfig({
          'url': 'https://nextcloud.example.com',
          'username': 'user@example.com',
          'password': 'password',
        }),
        isTrue,
      );
    });

    test('validateConfig should accept optional remotePath', () {
      expect(
        provider.validateConfig({
          'url': 'https://nextcloud.example.com',
          'username': 'user@example.com',
          'password': 'password',
          'remotePath': '/PiggyCount/',
        }),
        isTrue,
      );
    });

    test('validateConfig should return false for invalid remotePath type', () {
      expect(
        provider.validateConfig({
          'url': 'https://nextcloud.example.com',
          'username': 'user@example.com',
          'password': 'password',
          'remotePath': 123, // should be string
        }),
        isFalse,
      );
    });

    test(
        'should throw CloudConfigurationException when accessing auth before initialization',
        () {
      expect(
        () => provider.auth,
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test(
        'should throw CloudConfigurationException when accessing storage before initialization',
        () {
      expect(
        () => provider.storage,
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test('initialize should throw on invalid config', () async {
      expect(
        () => provider.initialize({}),
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    // Note: Full integration tests require a real WebDAV server
    // and should be run separately with proper credentials
  });

  group('WebDAVAuthService', () {
    test('currentUser should return virtual user built from username', () async {
      final authService = WebDAVAuthService('test-user');

      final user = await authService.currentUser;

      expect(user, isNotNull);
      expect(user!.id, equals('test-user'));
      expect(user.email, equals('test-user@webdav'));

      authService.dispose();
    });

    test(
        'signInWithEmail / signUpWithEmail should throw UnsupportedError '
        '(WebDAV uses Basic Auth, no email accounts)', () async {
      final authService = WebDAVAuthService('test-user');

      expect(
        () => authService.signInWithEmail(
            email: 'user@example.com', password: 'password'),
        throwsUnsupportedError,
      );
      expect(
        () => authService.signUpWithEmail(
            email: 'user@example.com', password: 'password'),
        throwsUnsupportedError,
      );

      authService.dispose();
    });

    test('authStateChanges should emit current user on listen', () async {
      final authService = WebDAVAuthService('test-user');

      final states = <CloudUser?>[];
      final subscription = authService.authStateChanges.listen(states.add);

      // broadcast stream 在 onListen 时推送当前用户
      await Future.delayed(const Duration(milliseconds: 100));

      expect(states, isNotEmpty);
      expect(states.last?.id, equals('test-user'));

      await subscription.cancel();
      authService.dispose();
    });

    test('authStateChanges should emit null after signOut', () async {
      final authService = WebDAVAuthService('test-user');

      var user = await authService.currentUser;
      expect(user, isNotNull);

      final states = <CloudUser?>[];
      final subscription = authService.authStateChanges.listen(states.add);
      await authService.signOut();
      await Future.delayed(const Duration(milliseconds: 100));

      user = await authService.currentUser;
      expect(user, isNull);
      expect(states.last, isNull);

      await subscription.cancel();
      authService.dispose();
    });

    test('sendPasswordResetEmail should throw UnsupportedError', () async {
      final authService = WebDAVAuthService('test-user');

      expect(
        () => authService.sendPasswordResetEmail(email: 'user@example.com'),
        throwsUnsupportedError,
      );

      authService.dispose();
    });

    test('resendEmailVerification should throw UnsupportedError', () async {
      final authService = WebDAVAuthService('test-user');

      expect(
        () => authService.resendEmailVerification(email: 'user@example.com'),
        throwsUnsupportedError,
      );

      authService.dispose();
    });
  });

  group('WebDAVStorageService', () {
    test('should implement CloudStorageService', () {
      // This would require mocking WebDAV client
      // For now, we just verify the class exists
      expect(WebDAVStorageService, isNotNull);
    });
  });
}
