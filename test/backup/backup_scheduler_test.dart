/// Task 4（/prd/cloud_backup/execution_plan.md）：
/// BackupScheduler 触发条件矩阵与时间/日期工具函数契约。
///
/// shouldTriggerNow 是定时备份的唯一判定入口（纯函数，可穷举矩阵）：
/// 开关关闭 / 未到时间 / 到达且当日未备 / 当日已备 / 跨窗口启动补触发。
///
/// P2-4/SEC-08（2026-09-09）：失败补试语义（auto_last_date 仅成功写入）
/// 与 attemptAllowed（失败退避 30 分钟 + 时钟回拨 5 分钟容差）矩阵。
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

    test('P2-4：失败不占用当日名额（auto_last_date 仅成功写入）', () {
      // 22:30 失败一次后，23:00 的 tick 仍应触发（补试）——
      // 语义由「失败不写 auto_last_date」保证，这里验证不带 lastDate
      // 的判定放行（app.dart 失败路径不写 key）
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: true,
              scheduledMinutes: 22 * 60,
              lastDate: null,
              now: DateTime(2026, 8, 16, 23, 0)),
          isTrue);
    });
  });

  group('P2-4/SEC-08: attemptAllowed 失败补试退避与回拨防护', () {
    final now = DateTime(2026, 8, 16, 23, 0);

    test('无上次尝试记录 → 放行（首次触发）', () {
      expect(
          BackupScheduler.attemptAllowed(lastAttemptMillis: null, now: now),
          isTrue);
    });

    test('距上次尝试 ≥30 分钟 → 放行（失败补试）', () {
      expect(
          BackupScheduler.attemptAllowed(
              lastAttemptMillis: now
                  .subtract(const Duration(minutes: 30))
                  .millisecondsSinceEpoch,
              now: now),
          isTrue);
    });

    test('距上次尝试 <30 分钟 → 拦截（分钟级 tick 不连打云端）', () {
      expect(
          BackupScheduler.attemptAllowed(
              lastAttemptMillis: now
                  .subtract(const Duration(minutes: 29))
                  .millisecondsSinceEpoch,
              now: now),
          isFalse);
    });

    test('SEC-08：时钟回拨（now 早于上次尝试）→ 拦截', () {
      // 上次尝试 23:00，时钟回拨到 22:30 → 回拨期不重复触发
      expect(
          BackupScheduler.attemptAllowed(
              lastAttemptMillis: now.millisecondsSinceEpoch,
              now: now.subtract(const Duration(minutes: 30))),
          isFalse);
    });

    test('SEC-08：小幅 NTP 修正（≤5 分钟容差内回拨）→ 拦截但爬回后放行', () {
      // 回拨 3 分钟（在容差内）→ 拦截
      expect(
          BackupScheduler.attemptAllowed(
              lastAttemptMillis: now.millisecondsSinceEpoch,
              now: now.subtract(const Duration(minutes: 3))),
          isFalse);
      // 时钟爬回越过上次尝试点 + 退避间隔（30 分钟）→ 放行。
      // 仅越过容差还不够——30 分钟退避对回拨场景同样生效。
      expect(
          BackupScheduler.attemptAllowed(
              lastAttemptMillis: now.millisecondsSinceEpoch,
              now: now.add(BackupScheduler.minAttemptInterval +
                  const Duration(minutes: 1))),
          isTrue);
    });

    test('跨日残留的上次尝试 → 间隔必然满足，放行', () {
      expect(
          BackupScheduler.attemptAllowed(
              lastAttemptMillis:
                  DateTime(2026, 8, 15, 22, 0).millisecondsSinceEpoch,
              now: now),
          isTrue);
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
