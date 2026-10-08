// 「表单抽屉全部统一」契约（2026-10 收口批次）：
// 存量整屏表单页（标签 / 分类 / AI 服务商 / AI 提示词 / 周期账单）一律改为
// `PiggyFormSheet` 悬浮卡片抽屉，壳里固定「居中标题 + 取消｜保存」。
//
// 标签与周期账单的契约分别在 `tag_edit_page_result_test.dart`、
// `recurring_form_drawer_test.dart`（含各自入口链路）；本文件覆盖剩下三页，
// 防止它们悄悄退回整屏路由。

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/ai/ai_prompt_edit_page.dart';
import 'package:piggycount/pages/ai/ai_provider_manage_page.dart';
import 'package:piggycount/pages/category/category_edit_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/ui/form_sheet.dart';
import 'package:piggycount/widgets/ui/sheet_actions.dart';

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

  /// 宿主：一个按钮触发对应抽屉，便于断言壳与标题。
  Future<void> pumpHost(
      WidgetTester tester, Future<void> Function(BuildContext) open) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => open(context),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('分类编辑器 → 悬浮卡片抽屉（新建态）', (tester) async {
    await pumpHost(
      tester,
      (context) => showCategoryFormBottomSheet(context, kind: 'expense'),
    );

    expect(find.byType(PiggyFormSheet), findsOneWidget);
    expect(find.text('新建分类'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('AI 服务商编辑器 → 悬浮卡片抽屉（新建态）', (tester) async {
    await pumpHost(
      tester,
      (context) => showAIProviderFormBottomSheet(context),
    );

    expect(find.byType(PiggyFormSheet), findsOneWidget);
    expect(find.text('添加服务商'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('AI 提示词编辑器 → 悬浮卡片抽屉（加载完成后）', (tester) async {
    await pumpHost(
      tester,
      (context) => showAIPromptFormBottomSheet(context),
    );

    expect(find.byType(PiggyFormSheet), findsOneWidget);
    expect(find.text('提示词编辑'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    // 无改动时保存键禁用（沿用 `_hasChanges` 门控）
    expect(
      tester.widget<PiggySheetActions>(find.byType(PiggySheetActions)).onConfirm,
      isNull,
    );
  });
}
