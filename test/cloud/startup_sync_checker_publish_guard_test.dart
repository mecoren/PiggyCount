import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/cloud/startup_sync_checker.dart';
import 'package:piggycount/cloud/sync_diff_service.dart';

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

  // 「删除」现在是两类：交易行 + 实体（账户/分类/标签/预算/周期规则/
  // 汇率覆盖）。unselectedDeletedCount 必须两类都数进去 —— 只数交易行的话，
  // 用户拒绝了实体删除后手动入口仍会 force 回传，把"删掉的账户"复活回去。
  group('unselectedDeletedCount（实体删除也必须计入 S1 判据）', () {
    SyncPreview previewOf(List<SyncChange> changes) =>
        SyncPreview(changes: changes);

    SyncChange txDelete({required bool selected}) => SyncChange(
          type: SyncChangeType.deleted,
          localTransaction: null,
          selected: selected,
        );
    SyncChange entityDelete({required bool selected}) => SyncChange(
          type: SyncChangeType.deleted,
          entityDelete: const SyncEntityDelete(
            kind: SyncEntityKind.account,
            localId: 1,
            syncId: 'acc-1',
            name: '现金',
          ),
          selected: selected,
        );

    test('仅实体删除未勾选 → 计数为 1 且守卫生效', () {
      final preview = previewOf([entityDelete(selected: false)]);
      final n = StartupSyncChecker.unselectedDeletedCount(preview);
      expect(n, 1);
      expect(
        StartupSyncChecker.shouldSkipMergePublish(
            previewExists: true, unselectedDeletedCount: n),
        isTrue,
        reason: '实体删除未被接受时不得回传，否则残留被推回云端、删除复活',
      );
    });

    test('实体删除已勾选 + 交易删除未勾选 → 计数为 1（只数未勾选的那类）', () {
      final preview = previewOf([
        entityDelete(selected: true),
        txDelete(selected: false),
      ]);
      expect(StartupSyncChecker.unselectedDeletedCount(preview), 1);
    });

    test('全部已勾选 → 计数 0，正常回传', () {
      final preview = previewOf([
        entityDelete(selected: true),
        txDelete(selected: true),
      ]);
      final n = StartupSyncChecker.unselectedDeletedCount(preview);
      expect(n, 0);
      expect(
        StartupSyncChecker.shouldSkipMergePublish(
            previewExists: true, unselectedDeletedCount: n),
        isFalse,
      );
    });

    test('只含新增/修改时不计入（无删除就不该拦回传）', () {
      final preview = previewOf([
        SyncChange(type: SyncChangeType.added),
        SyncChange(type: SyncChangeType.modified),
      ]);
      expect(StartupSyncChecker.unselectedDeletedCount(preview), 0);
    });
  });
}
