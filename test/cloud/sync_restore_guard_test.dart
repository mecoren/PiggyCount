import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/cloud/sync_restore_guard.dart';

void main() {
  setUp(() {
    // 保证用例间状态干净（守卫为进程级静态）
    while (SyncRestoreGuard.isBusy) {
      SyncRestoreGuard.end();
    }
  });

  test('初始不忙碌；begin/end 计数翻转', () {
    expect(SyncRestoreGuard.isBusy, isFalse);
    SyncRestoreGuard.begin();
    expect(SyncRestoreGuard.isBusy, isTrue);
    SyncRestoreGuard.end();
    expect(SyncRestoreGuard.isBusy, isFalse);
  });

  test('可重入嵌套：内层结束后外层仍忙碌', () async {
    await SyncRestoreGuard.run(() async {
      await SyncRestoreGuard.run(() async {});
      expect(SyncRestoreGuard.isBusy, isTrue, reason: '外层尚未退出');
    });
    expect(SyncRestoreGuard.isBusy, isFalse);
  });

  test('body 抛异常也必须释放', () async {
    await expectLater(
      SyncRestoreGuard.run(() async => throw StateError('boom')),
      throwsStateError,
    );
    expect(SyncRestoreGuard.isBusy, isFalse);
  });

  test('end 幂等安全（多余 end 不产生负计数副作用）', () {
    SyncRestoreGuard.end();
    expect(SyncRestoreGuard.isBusy, isFalse);
  });
}
