// 审计 SUP-D1/D2（2026-09-12 P1）回归：Supabase 数据库服务契约收口。
//
// SUP-D1：subscribe() 原裸抛 UnimplementedError（Error 类），会穿透
// 调用方 `catch (Exception)` 异常边界直达 zone 顶层。改抛
// CloudConfigurationException 后，任何未来调用方都能以包契约异常
// 捕获并归类（配置类错误，而非进程级 Error）。
//
// SUP-D2：query() 原对响应做 `as List` 强转，服务端返回非 List 形态
// （RLS 策略改写/视图/标量）时抛 TypeError（同样穿透 Exception 边界）。
// 改防御式检查后走可捕获的 CloudStorageException。
library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_supabase/flutter_cloud_sync_supabase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

void main() {
  SupabaseDatabaseService buildService() {
    final client = supabase.SupabaseClient(
      'https://test-project.supabase.co',
      'test-anon-key',
    );
    return SupabaseDatabaseService(client);
  }

  group('SUP-D1: subscribe 契约收口', () {
    test('抛 CloudConfigurationException 而非 UnimplementedError', () {
      final svc = buildService();
      expect(
        () => svc.subscribe(table: 'any_table'),
        throwsA(isA<CloudConfigurationException>()),
        reason: 'UnimplementedError 是 Error 类，穿透 catch (Exception) '
            '异常边界直达 zone 顶层',
      );
    });

    test('CloudConfigurationException 可被 catch (Exception) 捕获', () {
      final svc = buildService();
      Object? caught;
      try {
        svc.subscribe(table: 'any_table');
      } on Exception catch (e) {
        caught = e;
      }
      expect(caught, isA<CloudConfigurationException>(),
          reason: '契约异常必须是 Exception 子类，才能被常规异常边界拦住');
    });
  });

  group('SUP-D2: query 防御式响应转换', () {
    test('未登录 → CloudNotAuthenticatedException（认证先于网络）', () async {
      final svc = buildService();
      await expectLater(
        svc.query(table: 'any_table'),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );
    });

    test('update 未登录 → CloudNotAuthenticatedException（非 TypeError）',
        () async {
      final svc = buildService();
      // 未登录路径若实现错误（如 NPE/TypeError）会以 Error 形态逃逸，
      // 这里锁死它必须是包契约的认证异常
      await expectLater(
        svc.update(table: 't', id: '1', data: {'a': 1}),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );
    });
  });
}
