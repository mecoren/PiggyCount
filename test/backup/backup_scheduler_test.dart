/// Task 4（/prd/cloud_backup/execution_plan.md）：
/// BackupScheduler 触发条件矩阵与时间/日期工具函数契约。
///
/// shouldTriggerNow 是定时备份的唯一判定入口（纯函数，可穷举矩阵）：
/// 开关关闭 / 未到时间 / 到达且当日未备 / 当日已备 / 跨窗口启动补触发。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/cloud/backup/backup_scheduler.dart';

void main() {
  group('shouldTriggerNow 触发条件矩阵', () {
    final now = DateTime(2026, 8, 16, 22, 30);

    test('开关关闭 → 不触发', () {
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: false,
              scheduledMinutes: 22 * 60,
              lastDate: '2026-08-15',
              now: now),
          isFalse);
    });

    test('未到设定时间 → 不触发', () {
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: true,
              scheduledMinutes: 23 * 60,
              lastDate: '2026-08-15',
              now: now),
          isFalse);
    });

    test('到达设定时间且当日未备 → 触发', () {
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: true,
              scheduledMinutes: 22 * 60,
              lastDate: '2026-08-15',
              now: now),
          isTrue);
    });

    test('当日已备（无论成败）→ 不再触发', () {
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: true,
              scheduledMinutes: 22 * 60,
              lastDate: '2026-08-16',
              now: now),
          isFalse);
    });

    test('当日已过设定时间后启动（补触发语义）', () {
      // 23:30 才启动（错过今晚 22:00 的 tick）且今日未备 → 立即触发
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: true,
              scheduledMinutes: 22 * 60,
              lastDate: '2026-08-15',
              now: DateTime(2026, 8, 16, 23, 30)),
          isTrue);
    });

    test('当日未到设定时间（等待今晚窗口）', () {
      // 早上 8 点启动，今日 22:00 窗口未到 → 不触发，等到点再备
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: true,
              scheduledMinutes: 22 * 60,
              lastDate: '2026-08-15',
              now: DateTime(2026, 8, 16, 8, 0)),
          isFalse);
    });
  });

  group('时间与日期工具', () {
    test('parseHhMm', () {
      expect(BackupScheduler.parseHhMm('22:00'), 22 * 60);
      expect(BackupScheduler.parseHhMm('00:05'), 5);
      expect(BackupScheduler.parseHhMm('bad'), 0);
    });

    test('formatHhMm / formatDate 往返', () {
      expect(BackupScheduler.formatHhMm(22 * 60), '22:00');
      expect(BackupScheduler.formatHhMm(5), '00:05');
      expect(BackupScheduler.formatDate(DateTime(2026, 8, 6)), '2026-08-06');
    });
  });

  test('start/dispose 幂等安全', () {
    final s = BackupScheduler(onCheck: () async {})..start();
    s.start(); // 重复 start 不重建 Timer
    s.dispose();
    s.dispose(); // 重复 dispose 安全
  });
}
