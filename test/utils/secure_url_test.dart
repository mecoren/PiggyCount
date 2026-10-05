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
}
