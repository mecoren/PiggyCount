import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cloud_sync_s3/src/s3_client.dart';

/// P5：S3 _retry 的重试延迟必须带 jitter（指数退避 + 50%~100% 抖动），
/// 防止多设备在瞬时故障后同一时刻集中重试形成 thundering herd。
void main() {
  group('P5: S3 retry jitter', () {
    test('重试延迟 = 指数退避 + 50%~100% jitter', () {
      // 用 dummy 参数构造（retryDelayForTest 不触网，构造器仅存参 + 建 client）
      final client = S3Client(
        endpoint: 'https://s3.test',
        region: 'us-east-1',
        accessKey: 'a',
        secretKey: 'b',
      );
      // 固定种子可复现：同一 attempt 50 次取样全部落在 [base/2, base] 区间
      final rng = Random(42);
      for (var attempt = 1; attempt <= 4; attempt++) {
        final baseMs = (1 << (attempt - 1)) * 1000;
        for (var i = 0; i < 50; i++) {
          final d = client.retryDelayForTest(attempt, rng);
          expect(d.inMilliseconds, greaterThanOrEqualTo(baseMs ~/ 2),
              reason: 'attempt=$attempt 下界 base/2=${baseMs ~/ 2}ms');
          expect(d.inMilliseconds, lessThanOrEqualTo(baseMs),
              reason: 'attempt=$attempt 上界 base=${baseMs}ms');
        }
      }
    });
  });
}
