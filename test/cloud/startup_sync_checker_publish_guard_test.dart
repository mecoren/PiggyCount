import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/cloud/startup_sync_checker.dart';

void main() {
  group('shouldSkipMergePublish（致命 S1 删除复活防线）', () {
    test('存在未勾选的云端删除 → 跳过回传', () {
      expect(
        StartupSyncChecker.shouldSkipMergePublish(
            previewExists: true, unselectedDeletedCount: 1),
        isTrue,
      );
    });
    test('全部删除已被勾选应用 → 正常回传', () {
      expect(
        StartupSyncChecker.shouldSkipMergePublish(
            previewExists: true, unselectedDeletedCount: 0),
        isFalse,
      );
    });
    test('旧格式全量替换路径(preview 为空)不受守卫影响', () {
      expect(
        StartupSyncChecker.shouldSkipMergePublish(
            previewExists: false, unselectedDeletedCount: 0),
        isFalse,
      );
    });
  });
}
