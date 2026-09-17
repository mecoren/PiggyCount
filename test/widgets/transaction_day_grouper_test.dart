import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:piggycount/data/db.dart' as db;
import 'package:piggycount/widgets/biz/transaction_day_grouper.dart';

typedef TxItem = ({db.Transaction t, db.Category? category, db.Account? account, db.Account? toAccount});

TxItem makeItem({
  required int id,
  required DateTime happenedAt,
  double amount = 10,
  String type = 'expense',
  String? note,
}) =>
    (
      t: db.Transaction(
        id: id,
        ledgerId: 1,
        type: type,
        amount: amount,
        happenedAt: happenedAt,
        note: note,
        excludeFromStats: false,
        excludeFromBudget: false,
      ),
      category: null,
      account: null,
      toAccount: null,
    );

void main() {
  final d20240101 = DateTime(2024, 1, 1);
  final d20240102 = DateTime(2024, 1, 2);
  final d20240103 = DateTime(2024, 1, 3);
  final d20240215 = DateTime(2024, 2, 15);
  final d20231231 = DateTime(2023, 12, 31);

  group('dayKeyOf', () {
    test('与 DateFormat yyyy-MM-dd 输出严格一致（含个位月/日）', () {
      final dates = [
        DateTime(2024, 1, 5),
        DateTime(2023, 12, 31),
        DateTime(1999, 7, 1),
        DateTime(2024, 2, 29),
      ];
      for (final d in dates) {
        final item = makeItem(id: 1, happenedAt: d);
        final expected = DateFormat('yyyy-MM-dd')
            .format(DateTime(d.year, d.month, d.day));
        expect(TransactionDayGrouper.dayKeyOf(item), expected);
      }
    });
  });

  group('fullRebuild', () {
    test('按天分组 + 日 key 降序 + 日内保持输入顺序（乱序输入）', () {
      final g = TransactionDayGrouper()
        ..fullRebuild([
          makeItem(id: 1, happenedAt: d20240102, amount: 1),
          makeItem(id: 2, happenedAt: d20240101, amount: 2),
          makeItem(id: 3, happenedAt: d20240102, amount: 3),
          makeItem(id: 4, happenedAt: d20231231, amount: 4),
          makeItem(id: 5, happenedAt: d20240215, amount: 5),
        ]);

      expect(
          g.sortedDayKeys, ['2024-02-15', '2024-01-02', '2024-01-01', '2023-12-31']);
      expect(g.dayGroups['2024-01-02']!.map((e) => e.t.id), [1, 3]);
      expect(g.dayGroups['2023-12-31']!.map((e) => e.t.id), [4]);
    });
  });

  group('applyDiff', () {
    test('AC2/AC8：新列表引用但值相等（Drift 重复 emit / 预载 fallback）→ 无变化',
        () {
      final g = TransactionDayGrouper()
        ..fullRebuild([
          makeItem(id: 1, happenedAt: d20240101),
          makeItem(id: 2, happenedAt: d20240102),
        ]);

      // 全新实例、全新列表，字段值完全一致
      final dirty = g.applyDiff([
        makeItem(id: 2, happenedAt: d20240102),
        makeItem(id: 1, happenedAt: d20240101),
      ]);

      expect(dirty, isNull);
    });

    test('AC3：向已有日新增 → 该日重建、其余日的列表引用保持', () {
      final g = TransactionDayGrouper()
        ..fullRebuild([
          makeItem(id: 1, happenedAt: d20240101),
          makeItem(id: 2, happenedAt: d20240102),
        ]);
      final day1List = g.dayGroups['2024-01-01'];
      final day2List = g.dayGroups['2024-01-02'];

      final dirty = g.applyDiff([
        makeItem(id: 3, happenedAt: d20240101),
        makeItem(id: 1, happenedAt: d20240101),
        makeItem(id: 2, happenedAt: d20240102),
      ]);

      expect(dirty, {'2024-01-01'});
      expect(g.dayGroups['2024-01-01']!.map((e) => e.t.id), [3, 1]);
      // 脏日换新列表，未脏日保留原实例（零重建）
      expect(identical(g.dayGroups['2024-01-01'], day1List), isFalse);
      expect(identical(g.dayGroups['2024-01-02'], day2List), isTrue);
      expect(g.sortedDayKeys, ['2024-01-02', '2024-01-01']);
    });

    test('AC4：新日期新增 → 插入正确排序位置', () {
      final g = TransactionDayGrouper()
        ..fullRebuild([
          makeItem(id: 1, happenedAt: d20240103),
          makeItem(id: 2, happenedAt: d20240101),
        ]);

      final dirty = g.applyDiff([
        makeItem(id: 3, happenedAt: d20240102),
        makeItem(id: 1, happenedAt: d20240103),
        makeItem(id: 2, happenedAt: d20240101),
      ]);

      expect(dirty, {'2024-01-02'});
      expect(g.sortedDayKeys, ['2024-01-03', '2024-01-02', '2024-01-01']);
    });

    test('AC5：跨日移动 → 新旧两日都重建', () {
      final g = TransactionDayGrouper()
        ..fullRebuild([
          makeItem(id: 1, happenedAt: d20240101),
          makeItem(id: 2, happenedAt: d20240102),
          makeItem(id: 3, happenedAt: d20240103),
        ]);

      final dirty = g.applyDiff([
        makeItem(id: 1, happenedAt: d20240102), // 1 日 → 2 日
        makeItem(id: 2, happenedAt: d20240102),
        makeItem(id: 3, happenedAt: d20240103),
      ]);

      expect(dirty, {'2024-01-01', '2024-01-02'});
      expect(g.dayGroups['2024-01-02']!.map((e) => e.t.id), [1, 2]);
      expect(g.dayGroups.containsKey('2024-01-01'), isFalse);
      expect(g.sortedDayKeys, ['2024-01-03', '2024-01-02']);
    });

    test('AC6：同日改金额 → 该日重建且内容为新值', () {
      final g = TransactionDayGrouper()
        ..fullRebuild([
          makeItem(id: 1, happenedAt: d20240101, amount: 5),
          makeItem(id: 2, happenedAt: d20240102, amount: 6),
        ]);

      final dirty = g.applyDiff([
        makeItem(id: 1, happenedAt: d20240101, amount: 50),
        makeItem(id: 2, happenedAt: d20240102, amount: 6),
      ]);

      expect(dirty, {'2024-01-01'});
      expect(g.dayGroups['2024-01-01']!.first.t.amount, 50);
    });

    test('AC7：删除某日全部交易 → 该日移除', () {
      final g = TransactionDayGrouper()
        ..fullRebuild([
          makeItem(id: 1, happenedAt: d20240101),
          makeItem(id: 2, happenedAt: d20240101),
          makeItem(id: 3, happenedAt: d20240102),
        ]);

      final dirty = g.applyDiff([
        makeItem(id: 3, happenedAt: d20240102),
      ]);

      expect(dirty, {'2024-01-01'});
      expect(g.dayGroups.containsKey('2024-01-01'), isFalse);
      expect(g.sortedDayKeys, ['2024-01-02']);
    });

    test('清空列表 → 全部日移除', () {
      final g = TransactionDayGrouper()
        ..fullRebuild([
          makeItem(id: 1, happenedAt: d20240101),
        ]);

      final dirty = g.applyDiff([]);

      expect(dirty, {'2024-01-01'});
      expect(g.sortedDayKeys, isEmpty);
      expect(g.dayGroups, isEmpty);
    });

    test('空 → 空 → 无变化', () {
      final g = TransactionDayGrouper()..fullRebuild([]);
      expect(g.applyDiff([]), isNull);
    });

    test('差分对拍：操作序列后的增量结果与全量重算深度相等', () {
      final items = <TxItem>[
        makeItem(id: 1, happenedAt: d20240101, amount: 1),
        makeItem(id: 2, happenedAt: d20240101, amount: 2),
        makeItem(id: 3, happenedAt: d20240102, amount: 3),
        makeItem(id: 4, happenedAt: d20240215, amount: 4),
        makeItem(id: 5, happenedAt: d20231231, amount: 5),
      ];
      final inc = TransactionDayGrouper()..fullRebuild(items);

      // 操作序列：改金额、跨日移动、删除、新增已有日、新增新日、无变化 emit
      inc.applyDiff([
        makeItem(id: 1, happenedAt: d20240101, amount: 100),
        makeItem(id: 2, happenedAt: d20240101, amount: 2),
        makeItem(id: 3, happenedAt: d20240102, amount: 3),
        makeItem(id: 4, happenedAt: d20240215, amount: 4),
        makeItem(id: 5, happenedAt: d20231231, amount: 5),
      ]);
      inc.applyDiff([
        makeItem(id: 1, happenedAt: d20240103, amount: 100), // 移到 3 日
        makeItem(id: 2, happenedAt: d20240101, amount: 2),
        makeItem(id: 3, happenedAt: d20240102, amount: 3),
        makeItem(id: 4, happenedAt: d20240215, amount: 4),
      ]); // 删除 id=5
      inc.applyDiff([
        makeItem(id: 6, happenedAt: d20240102, amount: 6), // 已有日新增
        makeItem(id: 7, happenedAt: d20240101, amount: 7), // 新日? 1 日已存在
        makeItem(id: 1, happenedAt: d20240103, amount: 100),
        makeItem(id: 2, happenedAt: d20240101, amount: 2),
        makeItem(id: 3, happenedAt: d20240102, amount: 3),
        makeItem(id: 4, happenedAt: d20240215, amount: 4),
      ]);
      final finalList = <TxItem>[
        makeItem(id: 6, happenedAt: d20240102, amount: 6),
        makeItem(id: 7, happenedAt: d20240101, amount: 7),
        makeItem(id: 1, happenedAt: d20240103, amount: 100),
        makeItem(id: 2, happenedAt: d20240101, amount: 2),
        makeItem(id: 3, happenedAt: d20240102, amount: 3),
        makeItem(id: 4, happenedAt: d20240215, amount: 4),
      ];
      final full = TransactionDayGrouper()..fullRebuild(finalList);

      expect(inc.sortedDayKeys, full.sortedDayKeys);
      expect(inc.dayGroups, equals(full.dayGroups));
    });
  });
}
