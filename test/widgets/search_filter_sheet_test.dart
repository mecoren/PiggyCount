// 搜索页筛选抽屉契约：
// - 外壳必须是悬浮卡片表单抽屉（`PiggyFormSheet`），不再退回居中 Dialog；
// - 八个筛选维度各有独立行 / 输入块，「附件」是三段分段控件；
// - 分类维度走底部抽屉（`PiggyPickerSheet`），与账户 / 标签 / 币种同一手感；
// - 确认整包回传筛选条件，「清空筛选」只清草稿（点确定前不影响页面）。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/styles/tokens.dart';
import 'package:piggycount/widgets/biz/search_filter_sheet.dart';
import 'package:piggycount/widgets/ui/form_sheet.dart';
import 'package:piggycount/widgets/ui/picker_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  /// 宿主：按钮弹出筛选抽屉，把返回值交给 [onResult] 以便断言。
  Future<void> pumpHost(
    WidgetTester tester,
    void Function(SearchFilterValues? result) onResult, {
    SearchFilterValues initial = const SearchFilterValues(),
  }) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  final result = await showSearchFilterSheet(
                    context,
                    initial: initial,
                  );
                  onResult(result);
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('筛选抽屉：悬浮卡片外壳 + 各维度行 + 底部「取消｜确定」', (tester) async {
    await pumpHost(tester, (_) {});

    expect(find.byType(PiggyFormSheet), findsOneWidget);
    expect(find.text('筛选'), findsOneWidget);

    // 行式维度（图标 + 名称 + 当前值）
    expect(find.text('分类筛选'), findsOneWidget);
    expect(find.text('账户筛选'), findsOneWidget);
    expect(find.text('标签筛选'), findsOneWidget);
    expect(find.text('币种筛选'), findsOneWidget);
    expect(find.text('开始日期'), findsOneWidget);
    expect(find.text('结束日期'), findsOneWidget);
    // 未设置时统一显示占位文案（八个维度里有 6 个可空行）
    expect(find.text('未设置'), findsNWidgets(6));

    // 金额块 + 附件分段控件
    expect(find.text('金额筛选'), findsOneWidget);
    expect(find.text('最小金额'), findsOneWidget);
    expect(find.text('最大金额'), findsOneWidget);
    expect(find.text('附件筛选'), findsOneWidget);
    expect(find.text('不限'), findsOneWidget);
    expect(find.text('有附件'), findsOneWidget);
    expect(find.text('无附件'), findsOneWidget);

    // 底部双等宽按钮行
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
  });

  testWidgets('附件分段：选「有附件」→ 确定回传 hasAttachment = true', (tester) async {
    SearchFilterValues? result;
    await pumpHost(tester, (r) => result = r);

    // 附件块在字段区底部：先滚到可见位置再点（默认测试视口装不下整张卡片）。
    final segment = find.text('有附件');
    await tester.ensureVisible(segment);
    await tester.pumpAndSettle();
    await tester.tap(segment);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.hasAttachment, isTrue);
  });

  testWidgets('清空筛选：清掉各维度草稿后再确认 → 全维度为空', (tester) async {
    SearchFilterValues? result;
    await pumpHost(
      tester,
      (r) => result = r,
      initial: const SearchFilterValues(
        minAmount: 10,
        maxAmount: 100,
        hasAttachment: true,
      ),
    );

    // 初值到位（金额回填输入框、附件段为「有附件」）
    expect(find.text('10.0'), findsOneWidget);
    expect(find.text('100.0'), findsOneWidget);

    await tester.tap(find.text('清空筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    final values = result!;
    expect(values.minAmount, isNull);
    expect(values.maxAmount, isNull);
    expect(values.hasAttachment, isNull);
    expect(values.tagIds, isEmpty);
  });

  testWidgets('尾部槽位贴行右缘：无值是箭头，有值是清除键（取代箭头）', (tester) async {
    // 币种维度有值 → 该行尾部换成清除键；其余行「未设置」仍是箭头。
    await pumpHost(
      tester,
      (_) {},
      initial: const SearchFilterValues(currency: 'CNY'),
    );

    const labels = ['分类筛选', '账户筛选', '标签筛选', '币种筛选', '开始日期', '结束日期'];
    expect(find.byIcon(Icons.chevron_right), findsNWidgets(labels.length - 1));
    final closeIcon = find.byIcon(Icons.close);
    expect(closeIcon, findsOneWidget);
    // 清除键是「移除」动作：用警示色，与值的选中主色区分
    expect(
      tester.widget<Icon>(closeIcon).color,
      PiggyTokens.error(tester.element(closeIcon)),
    );

    for (final label in labels) {
      final row = find
          .ancestor(of: find.text(label), matching: find.byType(Material))
          .first;
      final rowRect = tester.getRect(row);
      // 每行尾部只有一个图标（前置图标之后的那个）：箭头或清除键
      final tail = find.descendant(of: row, matching: find.byType(Icon)).last;
      // 尾部图标右缘到行右缘只隔行内 padding（p12）：标签若参与 flex 均分，
      // 它用不完的份额会被丢到 Row 末尾，把尾部图标推到行中间。
      expect(
        rowRect.right - tester.getRect(tail).right,
        moreOrLessEquals(PiggyDimens.p12, epsilon: 0.5),
        reason: '$label 行的尾部图标没有贴到行右缘',
      );
    }
  });

  testWidgets('分类筛选 → 底部抽屉（不再走居中弹窗）', (tester) async {
    await pumpHost(tester, (_) {});

    await tester.tap(find.text('分类筛选'));
    await tester.pumpAndSettle();

    expect(find.byType(PiggyPickerSheet), findsOneWidget);
    // 抽屉标题与维度行同名，选中后行内应带清除键
    expect(find.text('分类筛选'), findsNWidgets(2));
  });
}
