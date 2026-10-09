// 表单抽屉外壳（PiggyFormSheet）的结构与手势契约 —— 三条硬要求：
//
//  1) 底部「取消｜保存」**固定在卡片底部**：长表单不滚动也能直接点；
//  2) 抽屉能**下拉关闭**，且整卡一条通路、手感一致：抓取条 / 标题 / 按钮行（非
//     滚动区，外层手势）与字段区（顶部 overscroll）都折算成同一个位移进度；
//  3) 下拉**跟手且可停住**：拖动中卡片停在手指位置，松手按「位移过半 / 快速下滑」
//     判定关闭，否则回弹归位（旧实现是「字段区攒够 72 像素直接 pop」，不跟手、
//     停不住，与抓取条上的手感两回事）。
//
// 第 2 条的字段区一路曾经不成立：整张卡片是一个 SingleChildScrollView 时，滚动区
// 在手势竞技场里吃掉了所有下拉（探针实测：长内容在标题上拖动也不会关闭），所以
// 字段区改为从 OverscrollNotification 取位移；非滚动区由外壳外层的 GestureDetector
// 取位移。两条通路都只是「输入源」，位移 / 判定 / 收尾共用。

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
  /// 打开一个表单抽屉。
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

  /// 卡片高度 = 外壳高度（等于抽屉内容高度，也是下拉判定的折算基准）。
  double sheetHeight(WidgetTester tester) =>
      tester.getSize(find.byType(PiggySheetCard)).height;

  double sheetTop(WidgetTester tester) =>
      tester.getRect(find.byType(PiggySheetCard)).top;

  /// 按住并往下拖 [distance] 逻辑像素，**不松手**（便于断言「拖动中就停在手指位置」）。
  ///
  /// 第一下越过的 slop（`kTouchSlop` = 18）两路处理不同：非滚动区的手势在
  /// pointer-down 就赢下竞技场（唯一成员），从第一像素起 1:1；字段区的手势被内部
  /// 滚动区赢走，滚动区按 `DragStartBehavior.start` 吃掉激活那一段。所以这里只把
  /// 它当「起点」，断言用区间而不是精确值。
  Future<TestGesture> startPullDown(
    WidgetTester tester,
    Finder finder,
    double distance,
  ) async {
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(finder));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveBy(Offset(0, distance));
    await tester.pump();
    return gesture;
  }

  /// 按住后分 [steps] 步各下拖 [step] 像素，返回 (手势, 每步之后卡片的位移增量) ——
  /// 用来断言「每步都与手指 1:1」（不跟手时这一串会明显偏小）。
  Future<(TestGesture, List<double>)> pullDownInSteps(
    WidgetTester tester,
    Finder finder, {
    required double step,
    int steps = 3,
  }) async {
    final TestGesture gesture =
        await tester.startGesture(tester.getCenter(finder));
    // 先激活（见 startPullDown 的说明），不计入增量。
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();

    final List<double> deltas = <double>[];
    double previous = sheetTop(tester);
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(0, step));
      await tester.pump();
      final double current = sheetTop(tester);
      deltas.add(current - previous);
      previous = current;
    }
    return (gesture, deltas);
  }

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
    expect(sheetTop(tester), greaterThanOrEqualTo(0), reason: '向上滚不该移动卡片');
  });

  testWidgets('短表单：卡片按内容收缩，按钮行仍在底部', (tester) async {
    await openSheet(tester, 2);

    expect(
      sheetHeight(tester),
      lessThan(viewportHeight(tester) * 0.8),
      reason: '字段少时卡片应贴着内容收缩，而不是撑满整屏',
    );
    expect(find.byType(PiggySheetActions), findsOneWidget);
  });

  testWidgets('长表单：在抓取条上向下拖 → 可以关闭抽屉', (tester) async {
    await openSheet(tester, 12);
    final card = tester.getRect(find.byType(PiggySheetCard));

    // 抓取条在卡片顶部居中；从它的位置上按住往下拖（含 32×4 条幅外的留白）
    await tester.dragFrom(
      Offset(card.center.dx, card.top + 10),
      Offset(0, sheetHeight(tester) * 0.7),
    );
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse, reason: '抓取条是最稳的拖拽落点');
  });

  testWidgets('长表单：在标题上向下拖 → 可以关闭抽屉', (tester) async {
    await openSheet(tester, 12);
    expect(sheetOpen(), isTrue);

    await tester.drag(find.text('标题'), Offset(0, sheetHeight(tester) * 0.7));
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse, reason: '标题属非滚动区，下拉必须能关抽屉');
  });

  testWidgets('长表单：在按钮行空白处向下拖 → 可以关闭抽屉', (tester) async {
    await openSheet(tester, 12);

    // 两个按钮中间的空隙：非交互、非滚动区
    final actions = tester.getRect(find.byType(PiggySheetActions));
    await tester.dragFrom(
      Offset(actions.center.dx, actions.center.dy),
      Offset(0, sheetHeight(tester) * 0.7),
    );
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse);
  });

  testWidgets('长表单：字段区滚到顶后继续下拉 → 可以关闭抽屉', (tester) async {
    await openSheet(tester, 12);

    // 12 个字段必然溢出：此时字段区在顶部，继续下拉应触发关闭
    await tester.drag(
      find.byType(TextField).first,
      Offset(0, sheetHeight(tester) * 0.7),
    );
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse, reason: '字段区下拉与抓取条同口径，过阈值即关闭');
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

    expect(sheetOpen(), isTrue, reason: '阈值（卡片高度一半）内的抖动不能关抽屉');
    expect(sheetTop(tester), greaterThanOrEqualTo(0));
  });

  testWidgets('下拉跟手：字段区与标题每步位移都与手指 1:1，松手未过阈值即归位', (tester) async {
    await openSheet(tester, 12);

    // 标题（非滚动区）
    final (TestGesture titleGesture, List<double> titleDeltas) =
        await pullDownInSteps(tester, find.text('标题'), step: 60);
    for (final double delta in titleDeltas) {
      expect(delta, closeTo(60, 1));
    }
    await titleGesture.up();
    await tester.pumpAndSettle();
    expect(sheetOpen(), isTrue, reason: '没过阈值要回弹归位而不是关掉');

    // 字段区：同一段位移必须有同样的跟手表现（旧实现是攒够阈值才一次性跳走）
    final (TestGesture fieldGesture, List<double> fieldDeltas) =
        await pullDownInSteps(tester, find.byType(TextField).first, step: 60);
    for (final double delta in fieldDeltas) {
      expect(delta, closeTo(60, 1), reason: '字段区下拉必须与在标题上拖一致');
    }
    await fieldGesture.up();
    await tester.pumpAndSettle();
    expect(sheetOpen(), isTrue);
  });

  testWidgets('下拉后上滑：抽屉跟手收回，字段内容一动不动（不再两个动画打架）', (tester) async {
    await openSheet(tester, 12);
    final double cardTopBefore = sheetTop(tester);
    final double fieldOffsetInCard =
        tester.getRect(find.text('字段 0')).top - cardTopBefore;

    final TestGesture gesture = await tester
        .startGesture(tester.getCenter(find.byType(TextField).first));
    await gesture.moveBy(const Offset(0, 30)); // 激活（slop）
    await tester.pump();
    await gesture.moveBy(const Offset(0, 150)); // 往下拉
    await tester.pump();

    expect(sheetTop(tester) - cardTopBefore, closeTo(150, 1));
    expect(
      tester.getRect(find.text('字段 0')).top - sheetTop(tester),
      closeTo(fieldOffsetInCard, 0.5),
      reason: '下拉过程中字段内容停在顶部不动',
    );

    // 手指折返上滑 = 抽屉等量收回（不是内容先滚走、抽屉再自己弹回去）
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(sheetTop(tester) - cardTopBefore, closeTo(50, 1));
    expect(
      tester.getRect(find.text('字段 0')).top - sheetTop(tester),
      closeTo(fieldOffsetInCard, 0.5),
      reason: '折返上滑只收抽屉，字段内容仍不动',
    );

    // 收到底后继续上滑才轮到内容滚动
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(sheetTop(tester), closeTo(cardTopBefore, 0.5));

    final double relativeBefore =
        tester.getRect(find.text('字段 0')).top - sheetTop(tester);
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    expect(
      tester.getRect(find.text('字段 0')).top - sheetTop(tester),
      lessThan(relativeBefore - 40),
      reason: '抽屉收回到顶之后，上滑才交回给字段内容滚动',
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(sheetOpen(), isTrue);
  });

  testWidgets('拖到阈值以内松手：先停住，再回弹归位（不关闭）', (tester) async {
    await openSheet(tester, 12);
    final topBefore = sheetTop(tester);
    final double distance = sheetHeight(tester) * 0.4;

    final TestGesture gesture =
        await startPullDown(tester, find.text('标题'), distance);
    final double moved = sheetTop(tester) - topBefore;
    expect(moved, greaterThanOrEqualTo(distance), reason: '跟手至少 1:1');
    expect(moved, lessThanOrEqualTo(distance + 30), reason: '至多多算激活那一下');
    expect(moved, lessThan(sheetHeight(tester) * 0.5), reason: '仍在关闭阈值内');

    // 停住：手指不动（只是等时间过去）卡片也不许动，更不能到点就跳走
    await tester.pump(const Duration(milliseconds: 120));
    expect(sheetTop(tester) - topBefore, closeTo(moved, 0.5));

    await gesture.up();
    await tester.pumpAndSettle();

    expect(sheetTop(tester), closeTo(topBefore, 0.5));
    expect(sheetOpen(), isTrue);
  });

  testWidgets('快速下滑：位移没过阈值也关闭（同抓取条口径）', (tester) async {
    await openSheet(tester, 12);
    // 位移远不到卡片高度的一半，只能靠速度判定
    await tester.fling(find.text('标题'), const Offset(0, 90), 3000);
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse);
  });

  testWidgets('快速下滑（字段区）：位移没过阈值也关闭', (tester) async {
    await openSheet(tester, 12);
    await tester.fling(find.byType(TextField).first, const Offset(0, 90), 3000);
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse);
  });
}
