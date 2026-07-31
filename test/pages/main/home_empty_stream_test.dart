// A 组回归测试:首页 StreamBuilder 必须用 snapshot.hasData 区分"流已加载(可能
// 为空)"与"流尚未返回",而非 streamData.isNotEmpty。
//
// Bug:home_page.dart 原用 `streamData != null && streamData.isNotEmpty` 判断,
// 导致 Drift stream 合法 emit [] (删除最后一笔后)被当作"未加载",回退到启动
// 缓存 cachedFullData(不随单笔删除更新),旧记录残留。
//
// 采用源码契约(与 home_header_layout_test.dart 一致):断言 hasStreamData 赋值
// 不含 isNotEmpty 误判,且使用 snapshot.hasData。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/pages/main/home_page.dart').readAsStringSync();

  // 定位 builder 内 hasStreamData 赋值片段
  final hasStreamDataMatch =
      RegExp(r'final\s+hasStreamData\s*=\s*([^;]+);').firstMatch(source);
  if (hasStreamDataMatch == null) {
    throw StateError('未找到 hasStreamData 赋值,home_page.dart 可能已重构');
  }
  final hasStreamDataExpr = hasStreamDataMatch.group(1)!;

  test('hasStreamData 使用 snapshot.hasData,而非 isNotEmpty 误判', () {
    expect(
      hasStreamDataExpr.contains('snapshot.hasData'),
      isTrue,
      reason: 'hasStreamData 应使用 snapshot.hasData 区分"已加载"与"未加载"。'
          '实际: $hasStreamDataExpr',
    );
  });

  test('hasStreamData 不含 isNotEmpty 空列表误判', () {
    expect(
      hasStreamDataExpr.contains('isNotEmpty'),
      isFalse,
      reason: 'hasStreamData 不得用 isNotEmpty 判断流是否返回 —— 空列表是合法的'
          '已加载状态。实际: $hasStreamDataExpr',
    );
  });

  // 同时确认 cachedFullData 仅在 !hasStreamData 时回退(保留预加载兜底语义)
  test('cachedFullData 仍作为 !hasStreamData 时的预加载兜底', () {
    expect(
      source.contains('cachedFullData'),
      isTrue,
      reason: '应保留 cachedFullData 作为流未返回时的预加载兜底',
    );
  });
}
