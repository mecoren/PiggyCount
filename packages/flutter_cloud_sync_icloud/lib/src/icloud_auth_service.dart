import 'dart:async';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import 'icloud_method_channel.dart';

/// iCloud account status
enum ICloudAccountStatus {
  available,
  restricted,
  noAccount,
  temporarilyUnavailable,
  unknown,
}

/// iCloud auth service implementation
///
/// iCloud uses system Apple ID, so this service creates a virtual user
/// when iCloud is available, similar to WebDAV's approach.
class ICloudAuthService implements CloudAuthService {
  final ICloudMethodChannel _methodChannel;
  late final StreamController<CloudUser?> _authStateController;
  CloudUser? _currentUser;
  // 用 Future 缓存替代 bool 标志：所有并发调用方共享同一个初始化任务，
  // 避免标志位在 await 完成前被提前置位导致重复初始化或竞态。
  Future<void>? _initFuture;

  ICloudAuthService(this._methodChannel) {
    // Create broadcast stream that sends current state on listen
    _authStateController = StreamController<CloudUser?>.broadcast(
      onListen: () {
        _ensureInitialized().then((_) {
          _authStateController.add(_currentUser);
        });
      },
    );
  }

  Future<void> _ensureInitialized() {
    // 所有调用方共享同一个 Future，避免标志位在 await 前提前置位导致竞态
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    try {
      // Check if iCloud is available
      final isAvailable = await _methodChannel.isICloudAvailable();
      if (isAvailable) {
        // Create virtual iCloud user
        _currentUser = CloudUser(
          id: 'icloud-user',
          email: 'iCloud',
          metadata: {
            'provider': 'icloud',
            'accountStatus': 'available',
          },
        );
      } else {
        _currentUser = null;
      }
    } catch (e) {
      // 初始化失败：置空用户并清除 Future 缓存，允许后续重试
      _currentUser = null;
      _initFuture = null;
    }
  }

  @override
  Stream<CloudUser?> get authStateChanges {
    return _authStateController.stream;
  }

  @override
  Future<CloudUser?> get currentUser async {
    await _ensureInitialized();
    return _currentUser;
  }

  /// Refresh iCloud availability status
  Future<void> refreshStatus() async {
    final isAvailable = await _methodChannel.isICloudAvailable();
    if (isAvailable) {
      _currentUser = CloudUser(
        id: 'icloud-user',
        email: 'iCloud',
        metadata: {
          'provider': 'icloud',
          'accountStatus': 'available',
        },
      );
    } else {
      _currentUser = null;
    }
    _authStateController.add(_currentUser);
  }

  // iCloud uses system account, following operations are not supported

  @override
  Future<CloudUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    throw UnsupportedError(
      'iCloud uses system Apple ID. Please sign in to iCloud in Settings.',
    );
  }

  @override
  Future<CloudUser> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    throw UnsupportedError(
      'iCloud uses system Apple ID. Please create an Apple ID in Settings.',
    );
  }

  @override
  Future<void> signOut() async {
    // For iCloud, we just clear the cached user but don't actually sign out
    // User needs to sign out from iOS Settings
    _currentUser = null;
    _authStateController.add(null);
  }

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {
    throw UnsupportedError(
      'Please reset Apple ID password at appleid.apple.com',
    );
  }

  @override
  Future<void> resendEmailVerification({required String email}) async {
    throw UnsupportedError('iCloud does not require email verification');
  }

  void dispose() {
    _authStateController.close();
  }
}
