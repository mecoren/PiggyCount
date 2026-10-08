// 表单抽屉外壳（PiggyFormSheet）的结构与手势契约 —— 两条硬要求：
//
//  1) 底部「取消｜保存」**固定在卡片底部**：长表单不滚动也能直接点；
//  2) 抽屉能**下拉关闭**（与云同步配置表单同口径）：抓取条 / 标题 / 按钮行
//     这些非滚动区靠抽屉自身手势关闭，字段区由 _DragToDismiss 兜住。
//
// 第二条曾经不成立：整张卡片是一个 SingleChildScrollView，长表单时滚动区
// 在手势竞技场里吃掉了所有下拉（探针实测：长内容在标题上拖动也不会关闭）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/widgets/ui/form_sheet.dart';
import 'package:piggycount/widgets/ui/sheet_actions.dart';
import 'package:piggycount/widgets/ui/sheet_card.dart';

/// 造一个表单内容：[fieldCount] 越大越可能超出屏幕（触发内部滚动）。
Widget _fields(int fieldCount) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < fieldCount; i++) ...[
          TextField(decoration: InputDecoration(labelText: '字段 $i')),
          const SizedBox(height: 16),
        ],
      ],
    );

void main() {
  /// 打开一个表单抽屉；返回「抽屉是否还开着」的判定函数。
  Future<void> openSheet(WidgetTester tester, int fieldCount) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showPiggyFormSheet<void>(
                context,
                builder: (_) => PiggyFormSheet(
                  title: '标题',
                  cancelLabel: '取消',
                  confirmLabel: '保存',
                  onCancel: () => Navigator.of(context).pop(),
                  onConfirm: () {},
                  child: _fields(fieldCount),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  bool sheetOpen() => find.byType(PiggySheetCard).evaluate().isNotEmpty;

  double viewportHeight(WidgetTester tester) =>
      tester.view.physicalSize.height / tester.view.devicePixelRatio;

  testWidgets('长表单：底部「取消｜保存」首屏可见，且不随字段区滚动', (tester) async {
    await openSheet(tester, 12);

    // 按钮行在视口内（不用滚到底就能点）
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(
      tester.getRect(find.text('保存')).bottom,
      lessThanOrEqualTo(viewportHeight(tester)),
      reason: '保存键必须在首屏可见（固定底部）',
    );

    final footerBefore = tester.getRect(find.byType(PiggySheetActions));
    final lastFieldBefore = tester.getRect(find.text('字段 11'));

    // 在字段区向下滚（内容往下走 = 手指向上拖）
    await tester.drag(find.byType(TextField).first, const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byType(PiggySheetActions)),
      footerBefore,
      reason: '字段区滚动时底部按钮行必须纹丝不动',
    );
    expect(
      tester.getRect(find.text('字段 11')).top,
      lessThan(lastFieldBefore.top),
      reason: '字段区本身要能滚动（否则限高没生效）',
    );
  });

  testWidgets('短表单：卡片按内容收缩，按钮行仍在底部', (tester) async {
    await openSheet(tester, 2);

    expect(
      tester.getSize(find.byType(PiggySheetCard)).height,
      lessThan(viewportHeight(tester) * 0.8),
      reason: '字段少时卡片应贴着内容收缩，而不是撑满整屏',
    );
    expect(find.byType(PiggySheetActions), findsOneWidget);
  });

  testWidgets('长表单：在标题上向下拖 → 可以关闭抽屉', (tester) async {
    await openSheet(tester, 12);
    expect(sheetOpen(), isTrue);

    await tester.drag(find.text('标题'), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse, reason: '标题属非滚动区，下拉必须能关抽屉');
  });

  testWidgets('长表单：在按钮行空白处向下拖 → 可以关闭抽屉', (tester) async {
    await openSheet(tester, 12);

    // 两个按钮中间的空隙：非交互、非滚动区
    final actions = tester.getRect(find.byType(PiggySheetActions));
    await tester.dragFrom(
      Offset(actions.center.dx, actions.center.dy),
      const Offset(0, 400),
    );
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse);
  });

  testWidgets('长表单：字段区滚到顶后继续下拉 → 可以关闭抽屉', (tester) async {
    await openSheet(tester, 12);

    // 12 个字段必然溢出：此时字段区在顶部，继续下拉应触发关闭
    await tester.drag(find.byType(TextField).first, const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse, reason: '字段区下拉关闭由 _DragToDismiss 兜住');
  });

  testWidgets('短表单：在字段上向下拖也能关闭（滚动范围为零时同样兜住）', (tester) async {
    await openSheet(tester, 2);

    await tester.drag(find.byType(TextField).first, const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse);
  });

  testWidgets('字段区小幅下拉（未过阈值）不应误关', (tester) async {
    await openSheet(tester, 12);

    await tester.drag(find.byType(TextField).first, const Offset(0, 30));
    await tester.pumpAndSettle();

    expect(sheetOpen(), isTrue, reason: '阈值（72）内的抖动不能关抽屉');
  });
}
