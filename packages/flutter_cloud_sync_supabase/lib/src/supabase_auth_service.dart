import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as s;

/// Supabase implementation of CloudAuthService
class SupabaseAuthService implements CloudAuthService {
  final s.SupabaseClient client;

  SupabaseAuthService(this.client);

  @override
  Stream<CloudUser?> get authStateChanges {
    return client.auth.onAuthStateChange.map((event) {
      final u = event.session?.user;
      return u != null ? CloudUser(id: u.id, email: u.email) : null;
    });
  }

  @override
  Future<CloudUser?> get currentUser async {
    final u = client.auth.currentUser;
    if (u == null) return null;
    return CloudUser(id: u.id, email: u.email);
  }

  @override
  Future<void> signOut() async {
    try {
      await client.auth.signOut();
    } on s.AuthException catch (e) {
      throw CloudAuthException('Sign out failed: ${e.message}', e);
    }
  }

  @override
  Future<CloudUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final res = await client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      // res.user 可能为 null（如触发 MFA 流程时未直接返回会话），
      // 强制解包会抛出空指针异常，故显式抛出业务异常（C9）
      final u = res.user;
      if (u == null) {
        throw CloudAuthException(
          'Sign in succeeded but no user returned (possibly MFA required)',
        );
      }
      return CloudUser(id: u.id, email: u.email);
    } on s.AuthException catch (e) {
      throw CloudAuthException('Sign in failed: ${e.message}', e);
    }
  }

  @override
  Future<CloudUser> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final res = await client.auth.signUp(email: email, password: password);
      // res.user 可能为 null（如服务端要求邮箱验证后才创建用户），
      // 强制解包会抛出空指针异常，故显式抛出业务异常（C9）
      final u = res.user;
      if (u == null) {
        throw CloudAuthException(
          'Sign up succeeded but no user returned (email verification may be required)',
        );
      }
      return CloudUser(id: u.id, email: u.email);
    } on s.AuthException catch (e) {
      throw CloudAuthException('Sign up failed: ${e.message}', e);
    }
  }

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {
    try {
      await client.auth.resetPasswordForEmail(email);
    } on s.AuthException catch (e) {
      throw CloudAuthException('Password reset failed: ${e.message}', e);
    }
  }

  @override
  Future<void> resendEmailVerification({required String email}) async {
    try {
      await client.auth.resend(
        type: s.OtpType.signup,
        email: email,
      );
    } on s.AuthException catch (e) {
      throw CloudAuthException('Resend verification failed: ${e.message}', e);
    }
  }
}
