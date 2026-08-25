import 'dart:async';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

/// WebDAV authentication service
///
/// WebDAV uses HTTP Basic Authentication. Once configured with username/password,
/// the user is considered "logged in". This service creates a virtual user
/// based on the username.
class WebDAVAuthService implements CloudAuthService {
  final String username;
  late final StreamController<CloudUser?> _authStateController;
  CloudUser? _currentUser;

  WebDAVAuthService(this.username) {
    // Create virtual user from username
    _currentUser = CloudUser(
      id: username,
      email: '$username@webdav',
    );

    // Create broadcast stream that sends current state on listen.
    // 审计 WD-L9：无条件重放当前状态 —— 此前 signOut 后（_currentUser ==
    // null）新订阅者收不到任何事件，UI 永远等不到初始登录态。
    _authStateController = StreamController<CloudUser?>.broadcast(
      onListen: () {
        _authStateController.add(_currentUser);
      },
    );
  }

  @override
  Stream<CloudUser?> get authStateChanges {
    return _authStateController.stream;
  }

  @override
  Future<CloudUser?> get currentUser async {
    return _currentUser;
  }

  @override
  Future<void> signOut() async {
    // 审计 WD-L9：dispose 后调用不再抛 StateError（controller 已关闭，
    // add 会崩），静默幂等即可。
    _currentUser = null;
    if (!_authStateController.isClosed) {
      _authStateController.add(null);
    }
  }

  @override
  Future<CloudUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    throw UnsupportedError('WebDAV does not support email sign in');
  }

  @override
  Future<CloudUser> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    throw UnsupportedError('WebDAV does not support sign up');
  }

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {
    throw UnsupportedError('WebDAV does not support password reset');
  }

  @override
  Future<void> resendEmailVerification({required String email}) async {
    throw UnsupportedError('WebDAV does not support email verification');
  }

  void dispose() {
    _authStateController.close();
  }
}
