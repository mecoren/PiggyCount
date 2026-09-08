import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cloud_sync_s3/src/s3_client.dart';

/// P1-2（上轮审计 N12 收口）：S3 对象传输超时按体积自适应。
///
/// 旧固定 30s 在弱网（上行 117KB/s）下 350KB 快照必超时且 putObject
/// 不重试（非幂等纪律）→ 慢网上传确定性失败。新策略：30s 基线 +
/// 30s/MB，上限 5min（对齐 StartupSyncChecker._publishTimeout 实测结论）。
/// 元数据类操作（HEAD/LIST/DELETE）保持 [S3Client.timeout] 不变。
void main() {
  group('P1-2: S3 transferTimeoutFor 体积自适应', () {
    final client = S3Client(
      endpoint: 'https://s3.test',
      region: 'us-east-1',
      accessKey: 'a',
      secretKey: 'b',
    );

    test('空对象 → 基线 30s（与旧行为一致）', () {
      expect(client.transferTimeoutFor(0), const Duration(seconds: 30));
    });

    test('350KB 快照（弱网 117KB/s 实测场景）→ ~40.5s，不再必超时', () {
      final d = client.transferTimeoutFor(350 * 1024);
      expect(d.inMilliseconds, greaterThan(30 * 1000));
      expect(d.inMilliseconds, lessThanOrEqualTo(45 * 1000));
    });

    test('5MB 大附件 → ~180s（旧值 30s 必超）', () {
      final d = client.transferTimeoutFor(5 * 1024 * 1024);
      expect(d.inSeconds, greaterThanOrEqualTo(150));
      expect(d.inSeconds, lessThanOrEqualTo(210));
    });

    test('超大对象 → 封顶 5min（保留挂起保护）', () {
      final d = client.transferTimeoutFor(500 * 1024 * 1024);
      expect(d, const Duration(minutes: 5));
    });

    test('自定义基线 timeout 时下限随基线抬升', () {
      final tuned = S3Client(
        endpoint: 'https://s3.test',
        region: 'us-east-1',
        accessKey: 'a',
        secretKey: 'b',
        timeout: const Duration(seconds: 60),
      );
      // 空对象至少给到自定义基线
      expect(tuned.transferTimeoutFor(0), const Duration(seconds: 60));
      // 60s + 30s/MB 的体积项叠加
      final d = tuned.transferTimeoutFor(1024 * 1024);
      expect(d.inSeconds, greaterThanOrEqualTo(90));
    });
  });
}
