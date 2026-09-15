// 同名多槽位甄别的共享拼装回归（两次实测 §4.2 改进点补齐批次）。
//
// 此前警示只在启动检查一个入口落地，且远程卡片 ID 显示 hashCode 与
// 弹窗短 ID 对不上号。本批把拼装提为共享方法后锁定三件事：
// 1. StartupSyncChecker.newLedgersDialogMessage：基础文案 + 同名多槽位
//    警示行的完整拼装（启动检查与云同步页「同步云端」两入口共用，
//    防止再次漂移成「一个警示另一个静默放行」）；
// 2. 警示明细格式：`短ID·上传时间(条数)`，新者在前，null 时间显示 '?'；
// 3. batchRestoreDuplicateDetail：「全部恢复」的覆盖语义
//    明细（同名槽位相互覆盖只留其一，与导入路径的「产生重复」不同）。
//
// 用生成的 AppLocalizationsEn 实例直接拼装（纯 Dart，无需 widget 环境）。

import 'package:flutter/material.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/cloud/startup_sync_checker.dart';
import 'package:piggycount/cloud/transactions_sync_manager.dart'
    show RemoteLedgerMeta;
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/models/ledger_display_item.dart';
import 'package:piggycount/pages/main/ledgers_page_new.dart'
    show batchRestoreDuplicateDetail;
import 'package:piggycount/utils/format_utils.dart';

RemoteLedgerMeta _m(String slotKey, String name,
        {int txCount = 10, DateTime? uploadedAt}) =>
    RemoteLedgerMeta(
      slotKey: slotKey,
      name: name,
      currency: 'CNY',
      monthStartDay: 1,
      txCount: txCount,
      uploadedAt: uploadedAt,
    );

LedgerDisplayItem _remote(String slotKey, String name,
        {int txCount = 10, required DateTime uploadedAt}) =>
    LedgerDisplayItem.fromRemote(
      remoteSyncId: slotKey,
      name: name,
      currency: 'CNY',
      updatedAt: uploadedAt,
      transactionCount: txCount,
      balance: 0,
    );

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('newLedgersDialogMessage（两入口共享拼装）', () {
    test('无同名 → 只有基础文案，不含警示行', () {
      final msg = StartupSyncChecker.newLedgersDialogMessage(l10n, [
        _m('slot-aaa111', 'A'),
        _m('slot-bbb222', 'B'),
      ]);
      expect(msg, l10n.startupSyncNewLedgersMessage(2, 'A(10)、B(10)'));
      expect(msg.contains('multiple cloud slots'), isFalse);
    });

    test('同名 → 基础文案换行后追加警示行，明细短ID·时间(条数)且新者在前',
        () {
      final msg = StartupSyncChecker.newLedgersDialogMessage(l10n, [
        _m('slot-old111', '回忆', txCount: 800,
            uploadedAt: DateTime(2026, 9, 1, 10, 0)),
        _m('slot-new222', '回忆', txCount: 1001,
            uploadedAt: DateTime(2026, 9, 10, 23, 0)),
      ]);
      final base = l10n.startupSyncNewLedgersMessage(2, '回忆(800)、回忆(1001)');
      expect(msg.startsWith(base), isTrue);
      // 警示行：换行分隔，短 ID 与卡片同口径（前 6 位）
      final warning = msg.substring(base.length + 1);
      expect(
          warning,
          l10n.startupSyncDuplicateSlots(
              '回忆: slot-n·2026-09-10 23:00(1001)、slot-o·2026-09-01 10:00(800)'));
    });

    test('uploadedAt 为 null 的槽位显示 ?', () {
      final msg = StartupSyncChecker.newLedgersDialogMessage(l10n, [
        _m('slot-a1111', 'D', uploadedAt: DateTime(2026, 9, 5)),
        _m('slot-b2222', 'D', txCount: 3),
      ]);
      expect(msg, contains('slot-b·?(3)'));
    });

    // 后端标识行：多后端轮换（S3 ↔ WebDAV）时避免误连旧后端下载串台
    //（2026-09-15 双模拟器回归实测两次踩坑）。
    test('backend 非空 → 前置「当前后端」行，基础文案整体保留在后', () {
      final base = l10n.startupSyncNewLedgersMessage(2, 'A(10)、B(10)');
      final msg = StartupSyncChecker.newLedgersDialogMessage(l10n, [
        _m('slot-aaa111', 'A'),
        _m('slot-bbb222', 'B'),
      ], backend: 'S3 · oss-cn-shenzhen.aliyuncs.com · piggycount');
      expect(msg,
          '${l10n.startupSyncNewLedgersBackend('S3 · oss-cn-shenzhen.aliyuncs.com · piggycount')}\n$base');
    });

    test('backend 为 null / 空串 / 纯空白 → 不加后端行（保持原文案）', () {
      final base = l10n.startupSyncNewLedgersMessage(1, 'A(10)');
      for (final backend in <String?>[null, '', '   ']) {
        expect(
            StartupSyncChecker.newLedgersDialogMessage(l10n, [_m('s1', 'A')],
                backend: backend),
            base);
      }
    });

    test('后端行 + 同名多槽位警示行：三行顺序为 后端 / 基础 / 警示', () {
      final msg = StartupSyncChecker.newLedgersDialogMessage(l10n, [
        _m('slot-a1111', 'D', uploadedAt: DateTime(2026, 9, 5)),
        _m('slot-b2222', 'D', txCount: 3),
      ], backend: 'WebDAV · dav.example.com');
      final lines = msg.split('\n');
      expect(lines.length, 3);
      expect(
          lines[0], l10n.startupSyncNewLedgersBackend('WebDAV · dav.example.com'));
      expect(lines[1], l10n.startupSyncNewLedgersMessage(2, 'D(10)、D(3)'));
      expect(
          lines[2],
          l10n.startupSyncDuplicateSlots(
              'D: slot-a·2026-09-05 00:00(10)、slot-b·?(3)'));
    });
  });

  group('batchRestoreDuplicateDetail（全部恢复 · 覆盖语义）', () {
    test('无同名 → null（确认文案保持原样）', () {
      final detail = batchRestoreDuplicateDetail([
        _remote('slot-a1111', 'A', uploadedAt: DateTime(2026, 9, 1)),
        _remote('slot-b2222', 'B', uploadedAt: DateTime(2026, 9, 2)),
      ]);
      expect(detail, isNull);
    });

    test('同名 → `名称: 短ID·时间(条数)、…`，新者在前', () {
      // fromRemote 的 lastUpdated=updatedAt（provider 传 uploadedAt ?? now）
      final detail = batchRestoreDuplicateDetail([
        _remote('slot-old111', '回忆',
            txCount: 800, uploadedAt: DateTime(2026, 9, 1, 10, 0)),
        _remote('slot-new222', '回忆',
            txCount: 1001, uploadedAt: DateTime(2026, 9, 10, 23, 0)),
      ]);
      expect(
          detail,
          '回忆: slot-n·2026-09-10 23:00(1001)、'
          'slot-o·2026-09-01 10:00(800)');
    });

    test('多名称各自分组、互不混并；单槽位名称不出现在明细', () {
      final detail = batchRestoreDuplicateDetail([
        _remote('x1', 'X', uploadedAt: DateTime(2026, 9, 5)),
        _remote('x2', 'X', uploadedAt: DateTime(2026, 9, 6)),
        _remote('y1', 'Y', uploadedAt: DateTime(2026, 9, 1)),
        _remote('y2', 'Y', uploadedAt: DateTime(2026, 9, 2)),
        _remote('c1', 'Z', uploadedAt: DateTime(2026, 9, 3)),
      ]);
      expect(detail, contains('X: x2·2026-09-06'));
      expect(detail, contains('Y: y2·2026-09-02'));
      expect(detail, isNot(contains('Z')));
      // X 组在前（首现顺序）
      expect(detail!.indexOf('X:'), lessThan(detail.indexOf('Y:')));
    });
  });

  group('口径一致性（卡片 ↔ 弹窗 ↔ 全部恢复）', () {
    test('formatSlotShortId：6 位截断 / 短 key 原样（legacy 数字名）', () {
      expect(formatSlotShortId('abcdef123456'), 'abcdef');
      expect(formatSlotShortId('12'), '12');
      expect(formatSlotShortId('123456'), '123456');
    });

    test('formatCloudUploadDate：null → ?，非 null → 本地 yyyy-MM-dd HH:mm',
        () {
      expect(formatCloudUploadDate(null), '?');
      final at = DateTime(2026, 9, 10, 23, 5);
      expect(formatCloudUploadDate(at.toUtc()), isNotEmpty);
    });
  });
}
