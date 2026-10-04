// #461 标签详情页按 月/年/全部 时间维度筛选:
// 默认「全部」保持旧行为;切「月」只看当前周期;切「年」只看当前年周期。
// 统计卡片与交易列表共用同一范围。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/tag/tag_detail_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/biz/biz.dart' show TransactionListItem;
import 'package:piggycount/widgets/ui/piggy_spinner.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  Widget host(int ledgerId, int tagId) {
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        currentLedgerIdProvider.overrideWith((ref) => ledgerId),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: TagDetailPage(tagId: tagId, tagName: '旅行'),
      ),
    );
  }

  testWidgets('默认全部;切月/年后统计与列表只显示对应周期', (tester) async {
    final ledgerId = await db.into(db.ledgers).insert(LedgersCompanion.insert(
          name: '测试账本',
        ));
    final tagId = await repo.createTag(name: '旅行');

    Future<void> seed(DateTime happenedAt, double amount) async {
      final txId = await repo.addTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: amount,
        happenedAt: happenedAt,
      );
      await repo.addTagToTransaction(transactionId: txId, tagId: tagId);
    }

    final now = DateTime.now();
    // 本月一笔(月/年/全部都可见)
    await seed(DateTime(now.year, now.month, 15), 100);
    // 今年另一个月一笔(年/全部可见;now 在 1 月时取 2 月,年范围含未来周期)
    final otherMonth = now.month == 1 ? 2 : 1;
    await seed(DateTime(now.year, otherMonth, 15), 20);
    // 久远一笔(仅全部可见)
    await seed(DateTime(2006, 1, 15), 7);

    await tester.pumpWidget(host(ledgerId, tagId));
    await tester.pumpAndSettle();

    // 默认「全部」:3 笔全显示(保持旧行为)
    expect(find.byType(TransactionListItem), findsNWidgets(3));
    expect(find.text('3笔'), findsOneWidget);

    // 切「月」:只剩本月 1 笔
    await tester.tap(find.text('月'));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionListItem), findsNWidgets(1));
    expect(find.text('1笔'), findsOneWidget);
    // 显示当前周期标签,可再点开选择器换周期
    final monthLabel = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    expect(find.text(monthLabel), findsOneWidget);

    // 切「年」:本年 2 笔
    await tester.tap(find.text('年'));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionListItem), findsNWidgets(2));
    expect(find.text('2笔'), findsOneWidget);
    expect(find.text('${now.year}'), findsOneWidget);

    // 切回「全部」:恢复 3 笔
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionListItem), findsNWidgets(3));
    expect(find.text('3笔'), findsOneWidget);

    // 切维度不得闪 loading：月→年→全部 三连切，每一步在下一帧（数据已同步
    // 就绪）就必须看到明细行，不能出现 PiggySpinner。
    // 回归背景：切维度时若换 provider 实例，整块列表会回 loading 转圈。
    for (final label in ['年', '月', '全部']) {
      await tester.tap(find.text(label));
      await tester.pump(); // 只推进一帧，不 pumpAndSettle
      expect(
        find.byType(PiggySpinner),
        findsNothing,
        reason: '切「$label」后不应出现 loading 指示器',
      );
      expect(find.byType(TransactionListItem), findsWidgets);
      await tester.pumpAndSettle();
    }

    // 切维度时 chip 行不得横向位移。ChoiceChip 选中时才画 ✓，若不统一宽度，
    // 选中瞬间 chip 变宽会把后面的 chip 挤一下 —— 逐帧比对三个 chip 的横坐标。
    Map<String, double> chipOffsets() => {
          for (final label in ['月', '年', '全部'])
            label: tester.getTopLeft(find.text(label)).dx,
        };

    final before = chipOffsets();
    for (final label in ['月', '年', '全部']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(chipOffsets(), before, reason: '切「$label」后 chip 行不应位移');
    }

    // 手动拆树:drift QueryStream 取消订阅时会排一个 zero-duration Timer,
    // 留给框架自动拆树会触发 "A Timer is still pending" 断言。
    // pump 必须带时长——不带时不推进 FakeAsync 时钟,timer 不会执行。
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
