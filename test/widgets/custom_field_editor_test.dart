/// v46 交易编辑器内自定义字段分区的 widget 契约。
///
/// 保护三件事：
/// 1. **按账本定义渲染**：该账本有定义才出现录入位，没有定义时整块隐藏
///    （既有调用方的布局与改动前一致），且不引入水平溢出；
/// 2. **编辑回显**：已有值填进输入位；
/// 3. **提交三态**：未涉及 → null（不改动）、填了/改了 → 全量覆盖、
///    原有值被清空 → 空 map（显式清空）。第三态最容易写错 —— 见
///    amount_editor_sheet 提交处那段 `_customValues.isEmpty` 判断。
///
/// ⚠️ 点「完成」后**不要**用 `pumpAndSettle()`：提交回调里会把按钮切到
/// loading 转圈（无限动画），settle 永远等不到静止 → 超时失败。这里统一
/// 只 `pump()` 一帧 —— 断言只依赖 `onSubmit` 已被同步调用。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/biz/amount_editor_sheet.dart';

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

  /// 真机级视口 + 渲染错误收集。
  ///
  /// - 视口取 400×900：默认测试视口 800×600 对「金额行 + 备注 + 标签 +
  ///   自定义字段 + 数字键盘」的固定纵向布局本来就不够（既有状态）。
  /// - 收集而非直接失败：400dp 宽 + FlutterTest 字体（每字宽 1em，比真机字体
  ///   宽近一倍）下，数字键盘的日期键会换行并溢出 —— 这是**既有**问题
  ///   （`quick_entry_mode_test` 的对照组同样溢出），与本需求无关。
  ///   收集后即可只对「水平溢出」与「自定义字段分区」设防。
  List<String> prepareTest(WidgetTester tester) {
    tester.view.physicalSize = const Size(400 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) => errors.add(details.exceptionAsString());
    addTearDown(() => FlutterError.onError = previous);
    return errors;
  }

  List<String> horizontalOverflows(List<String> errors) =>
      errors.where((e) => e.contains('on the right')).toList();

  Ledger ledger() => Ledger(
        id: 1,
        name: 'L',
        currency: 'CNY',
        type: 'personal',
        createdAt: DateTime(2026, 1, 1),
        myRole: 'owner',
        memberCount: 1,
        isShared: false,
        monthStartDay: 1,
      );

  Future<void> seedField({
    required String syncId,
    required String name,
    required String type,
    int sortOrder = 0,
  }) async {
    await db.into(db.customFieldDefinitions).insert(
          CustomFieldDefinitionsCompanion.insert(
            ledgerId: 1,
            name: name,
            fieldType: type,
            syncId: Value(syncId),
            sortOrder: Value(sortOrder),
          ),
        );
  }

  Widget host({
    Map<String, dynamic> initialCustomValues = const {},
    required void Function(AmountEditorResult) onSubmit,
  }) =>
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          currentLedgerProvider
              .overrideWith((ref) => Stream<Ledger?>.value(ledger())),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: AmountEditorSheet(
              categoryName: '餐饮',
              initialDate: DateTime(2026, 9, 18),
              initialAmount: 100,
              initialCustomValues: initialCustomValues,
              ledgerId: 1,
              onSubmit: onSubmit,
            ),
          ),
        ),
      );

  Finder inputFor(String syncId) =>
      find.byKey(ValueKey('custom_field_input_$syncId'));

  /// 点「完成」并只推一帧（见文件头注释：loading 转圈会让 settle 超时）。
  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.text('完成'));
    await tester.pump();
  }

  testWidgets('无定义 → 整块隐藏（既有调用方布局不变）', (tester) async {
    final errors = prepareTest(tester);
    await tester.pumpWidget(host(onSubmit: (_) {}));
    await tester.pumpAndSettle();

    expect(find.text('自定义字段'), findsNothing);
    expect(horizontalOverflows(errors), isEmpty);
  });

  testWidgets('有定义 → 渲染分区标题与各字段录入位（按 sortOrder），无水平溢出',
      (tester) async {
    final errors = prepareTest(tester);
    await seedField(syncId: 'cf-b', name: '运费', type: 'amount', sortOrder: 1);
    await seedField(syncId: 'cf-a', name: '税费', type: 'text', sortOrder: 0);

    await tester.pumpWidget(host(onSubmit: (_) {}));
    await tester.pumpAndSettle();

    expect(find.text('自定义字段'), findsOneWidget);
    expect(find.text('税费'), findsOneWidget);
    expect(find.text('运费'), findsOneWidget);
    expect(inputFor('cf-a'), findsOneWidget);
    expect(inputFor('cf-b'), findsOneWidget);
    expect(horizontalOverflows(errors), isEmpty,
        reason: '录入位（名称 84dp + 输入框）不得把表单顶出水平溢出');
  });

  testWidgets('超长字段名不引入水平溢出（名称单行省略）', (tester) async {
    final errors = prepareTest(tester);
    await seedField(
      syncId: 'cf-long',
      name: '装修款分十二期手续费与平台服务费合计',
      type: 'amount',
    );

    await tester.pumpWidget(host(onSubmit: (_) {}));
    await tester.pumpAndSettle();

    expect(horizontalOverflows(errors), isEmpty);
    expect(inputFor('cf-long'), findsOneWidget);
  });

  testWidgets('编辑回显：已有值填进对应输入位（金额去尾零 / 文本原样）', (tester) async {
    prepareTest(tester);
    await seedField(syncId: 'cf-a', name: '税费', type: 'amount');
    await seedField(syncId: 'cf-b', name: '备注值', type: 'text', sortOrder: 1);

    await tester.pumpWidget(host(
      initialCustomValues: const {'cf-a': 12.5, 'cf-b': '发票 001'},
      onSubmit: (_) {},
    ));
    await tester.pumpAndSettle();

    final amountField = tester.widget<TextField>(inputFor('cf-a'));
    final textField = tester.widget<TextField>(inputFor('cf-b'));
    expect(amountField.controller!.text, '12.5');
    expect(textField.controller!.text, '发票 001');
  });

  testWidgets('日期字段：无值时显示占位文案', (tester) async {
    prepareTest(tester);
    await seedField(syncId: 'cf-d', name: '开票日', type: 'date');

    await tester.pumpWidget(host(onSubmit: (_) {}));
    await tester.pumpAndSettle();

    expect(find.text('选择日期'), findsOneWidget);
    expect(find.byKey(const ValueKey('custom_field_date_cf-d')), findsOneWidget);
  });

  testWidgets('提交三态①：原值与现值都为空 → customValues 为 null（不改动）',
      (tester) async {
    prepareTest(tester);
    await seedField(syncId: 'cf-a', name: '税费', type: 'amount');
    AmountEditorResult? captured;

    await tester.pumpWidget(host(onSubmit: (r) => captured = r));
    await tester.pumpAndSettle();

    await submit(tester);

    expect(captured, isNotNull);
    expect(captured!.customValues, isNull,
        reason: '没碰过自定义字段就不该提交值，否则会把别的设备已填的值抹掉');
  });

  testWidgets('提交三态②：填写后 → 提交全量快照', (tester) async {
    prepareTest(tester);
    await seedField(syncId: 'cf-a', name: '税费', type: 'amount');
    AmountEditorResult? captured;

    await tester.pumpWidget(host(onSubmit: (r) => captured = r));
    await tester.pumpAndSettle();

    await tester.enterText(inputFor('cf-a'), '12.5');
    await tester.pump();

    await submit(tester);

    expect(captured!.customValues, {'cf-a': 12.5});
  });

  testWidgets('提交三态③：原有值被清空 → 提交空 map（显式清空）', (tester) async {
    prepareTest(tester);
    await seedField(syncId: 'cf-a', name: '税费', type: 'amount');
    AmountEditorResult? captured;

    await tester.pumpWidget(host(
      initialCustomValues: const {'cf-a': 12.5},
      onSubmit: (r) => captured = r,
    ));
    await tester.pumpAndSettle();

    await tester.enterText(inputFor('cf-a'), '');
    await tester.pump();

    await submit(tester);

    expect(captured!.customValues, isNotNull);
    expect(captured!.customValues, isEmpty,
        reason: '原值非空 + 现值空 = 用户主动清空，必须提交空 map 而不是 null');
  });

  testWidgets('提交三态④：原值非空但未改动 → 提交原值（不丢也不变）',
      (tester) async {
    prepareTest(tester);
    await seedField(syncId: 'cf-a', name: '税费', type: 'amount');
    await seedField(syncId: 'cf-b', name: '备注值', type: 'text', sortOrder: 1);
    AmountEditorResult? captured;

    await tester.pumpWidget(host(
      initialCustomValues: const {'cf-a': 12.5},
      onSubmit: (r) => captured = r,
    ));
    await tester.pumpAndSettle();

    await tester.enterText(inputFor('cf-b'), 'hello');
    await tester.pump();

    await submit(tester);

    expect(captured!.customValues!['cf-a'], 12.5,
        reason: '未改动的已有值必须原样带回');
    expect(captured!.customValues!['cf-b'], 'hello');
  });
}
