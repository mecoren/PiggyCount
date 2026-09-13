// 远程账本卡片与弹窗 ID 口径一致性契约（源码级，非渲染断言）。
//
// 背景（两次实测 §4.2 复盘发现的自相矛盾缺口）：启动检查弹窗承诺
// 「可稍后在 账本管理-云端账本 按 ID 甄别下载」，展示 slotKey 前 6 位
// 短 ID；但远程卡片此前显示 remoteSyncId.hashCode（Dart 整型哈希），
// 两者对不上号，用户拿弹窗里的短 ID 到卡片页找不到对应项，甄别承诺
// 无法兑现。本契约锁定三条：
// 1. 远程卡片（底层 + 蒙层）ID 一律走 formatSlotShortId（slotKey 前 6 位）；
// 2. 卡片不再用 remoteSyncId.hashCode 充当展示 ID（hashCode 仍是
//    LedgerDisplayItem.fromRemote 里 UI 唯一化的 id 字段，允许存在）；
// 3. 「全部恢复」双危险确认的第一段拼入 ledgersRestoreAllDuplicateSlots
//    警示行（同名槽位依次覆盖语义）。
//
// 读源码做正则匹配（对齐 home_header_layout_test.dart 的契约测试模式），
// 任何调整这些结构的改动都会在此失败提醒同步更新契约。

import 'dart:io';

void main() {
  final card =
      File('lib/widgets/biz/ledger_card.dart').readAsStringSync();
  final ledgers = File('lib/pages/main/ledgers_page_new.dart').readAsStringSync();
  final display =
      File('lib/models/ledger_display_item.dart').readAsStringSync();

  // 1. 卡片底层 ID 行：远程分支走 formatSlotShortId
  _expect(
    RegExp(r'isRemote\s*\?.*formatSlotShortId\(ledger\.remoteSyncId!\)')
        .hasMatch(card),
    'ledger_card: remote branch renders formatSlotShortId(remoteSyncId)',
  );

  // 2. 卡片蒙层也展示同一口径短 ID（蒙层压暗底层，是用户实际可读层）
  _expect(
    RegExp(r"'ID:\$\{ledger\.remoteSyncId == null \? '\?' : "
            r"formatSlotShortId\(ledger\.remoteSyncId!\)\}'")
        .hasMatch(card),
    'ledger_card: overlay shows same slot short id',
  );

  // 3. 卡片展示 hashCode 的旧写法已移除（fromRemote 构造器内的 hashCode
  //    id 占位不在此列——那是 UI 唯一化字段，非展示文本）
  _expect(
    !RegExp(r"ID:\$\{ledger\.id\}\}'\s*,\s*//\s*UI").hasMatch(card),
    'ledger_card: no raw id shown for remote overlay',
  );
  _expect(
    RegExp(r"id: remoteSyncId\.hashCode").hasMatch(display),
    'ledger_display_item: id placeholder hashCode still in fromRemote '
    '(UI uniqueness only)',
  );

  // 4. 「全部恢复」第一段确认拼入同名多槽位覆盖警示
  _expect(
    RegExp(r'ledgersRestoreAllDuplicateSlots\(dupDetail\)').hasMatch(ledgers),
    'ledgers_page_new: restore-all confirm appends duplicate-slots warning',
  );

  stdout.writeln('Remote card / dialog ID consistency contract passed.');
}

void _expect(bool condition, String description) {
  if (!condition) {
    throw StateError('Expected $description.');
  }
}
