import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/utils/secure_url.dart';

void main() {
  test('显式 http:// 判定为明文，其余不是', () {
    expect(isExplicitHttpUrl('http://dav.example.com/'), isTrue);
    expect(isExplicitHttpUrl('HTTP://dav.example.com/'), isTrue);
    expect(isExplicitHttpUrl('https://xxx.supabase.co'), isFalse);
    expect(isExplicitHttpUrl('xxx.supabase.co'), isFalse);
    expect(isExplicitHttpUrl(''), isFalse);
    expect(isExplicitHttpUrl('  http://a  '), isTrue);
  });

  test('缺协议自动补 https://，其余原样', () {
    expect(normalizeCloudUrl('xxx.supabase.co'), 'https://xxx.supabase.co');
    expect(normalizeCloudUrl('https://xxx.supabase.co'),
        'https://xxx.supabase.co');
    // 显式 http 原样返回，由调用方内联报错拦截
    expect(normalizeCloudUrl('http://dav.example.com/'),
        'http://dav.example.com/');
    expect(normalizeCloudUrl(''), '');
  });

  test('S5：自配端点强制 HTTPS，仅回环允许明文', () {
    // 明文远端：拦截
    expect(isInsecureRemoteUrl('http://api.example.com'), isTrue);
    expect(isInsecureRemoteUrl('HTTP://192.168.1.10:11434'), isTrue);
    // HTTPS / 缺协议：放行（缺协议按 https 补全）
    expect(isInsecureRemoteUrl('https://api.example.com/v1'), isFalse);
    expect(isInsecureRemoteUrl('api.example.com/v1'), isFalse);
    expect(isInsecureRemoteUrl(''), isFalse);
    // 本机回环：允许明文（Ollama / LM Studio）
    expect(isInsecureRemoteUrl('http://localhost:11434'), isFalse);
    expect(isInsecureRemoteUrl('http://127.0.0.1:8080/v1'), isFalse);
    expect(isInsecureRemoteUrl('http://[::1]:8080'), isFalse);
    // 非 http(s) 协议：拒绝
    expect(isInsecureRemoteUrl('file:///etc/passwd'), isTrue);
    expect(isInsecureRemoteUrl('ftp://example.com'), isTrue);
  });
}
