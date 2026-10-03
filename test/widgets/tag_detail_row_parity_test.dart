// 标签详情页明细行口径对齐账本明细（首页）：
// - 明细区是「整张大卡片」外壳（主题色细边框 + 首末圆角 + 日间细线）
// - 转账行标题走备注/「转账」，副行显示「转出账户 → 转入账户」，金额不挂正负号
// - 当前标签不在行内重复出现，其它标签照常展示
// - 「不计收支」pill 展示，且统计卡片金额跳过不计收支的记录（笔数照常）
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
import 'package:piggycount/widgets/biz/day_group_card.dart';

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
        home: TagDetailPage(tagId: tagId, tagName: '测-标签4'),
      ),
    );
  }

  testWidgets('转账行 / 其它标签 / 不计收支 与账本明细同口径', (tester) async {
    final ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: '测试账本'),
        );
    // 账户直接插表：createAccount 会打日志，留一个 2s 落盘 timer 让拆树断言挂掉
    final fromId = await db.into(db.accounts).insert(AccountsCompanion.insert(
          ledgerId: ledgerId,
          name: '储蓄卡',
        ));
    final toId = await db.into(db.accounts).insert(AccountsCompanion.insert(
          ledgerId: ledgerId,
          name: '信用卡',
        ));

    final tagId = await repo.createTag(name: '测-标签4');
    final otherTagId = await repo.createTag(name: '出差');

    final now = DateTime.now();
    final day = DateTime(now.year, now.month, 15);
    Future<void> seed({
      required String type,
      required double amount,
      int? toAccountId,
      String? note,
      bool excludeFromStats = false,
      List<int> tagIds = const [],
    }) async {
      final txId = await repo.addTransaction(
        ledgerId: ledgerId,
        type: type,
        amount: amount,
        accountId: fromId,
        toAccountId: toAccountId,
        happenedAt: day,
        note: note,
        excludeFromStats: excludeFromStats,
      );
      for (final id in tagIds) {
        await repo.addTagToTransaction(transactionId: txId, tagId: id);
      }
    }

    // 同一天三笔 → 明细区只有一张大卡片
    await seed(
      type: 'transfer',
      amount: 8849.4,
      toAccountId: toId, // 无备注 → 标题走 l10n「转账」
      tagIds: [tagId],
    );
    await seed(
      type: 'expense',
      amount: 20.04,
      note: '打车',
      tagIds: [tagId],
    );
    await seed(
      type: 'expense',
      amount: 87.18,
      note: '午餐',
      excludeFromStats: true,
      tagIds: [tagId, otherTagId],
    );

    await tester.pumpWidget(host(ledgerId, tagId));
    await tester.pumpAndSettle();

    expect(find.byType(DayGroupCard), findsOneWidget);

    // 转账行：标题走 l10n，副行显示账户流向；金额不带正负号
    expect(find.text('转账'), findsOneWidget);
    expect(find.textContaining('储蓄卡 → 信用卡'), findsOneWidget);
    expect(find.text('8,849.4'), findsOneWidget);
    expect(find.text('+8,849.4'), findsNothing);

    // 普通支出行（备注接在次要信息行里，与账本明细一致）
    expect(find.textContaining('打车'), findsOneWidget);
    expect(find.text('-20.04'), findsOneWidget);

    // 「不计收支」pill + 另一标签 chip；当前标签只在汇总卡片出现一次
    expect(find.textContaining('午餐'), findsOneWidget);
    expect(find.text('-87.18'), findsOneWidget);
    expect(find.text('不计收支'), findsOneWidget);
    expect(find.text('出差'), findsOneWidget);
    expect(find.text('测-标签4'), findsOneWidget);

    // 统计：3 笔全计；支出合计只剩 20.04（不计收支那笔被跳过），收入为 0
    expect(find.text('3笔'), findsOneWidget);
    expect(find.text('20.04'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
