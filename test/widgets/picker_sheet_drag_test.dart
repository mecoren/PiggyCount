// 选择器抽屉（PiggyPickerSheet）的下拉契约 —— 两条硬要求：
//
//  1) **只有「内容是可滚动列表 / 网格」的选择器**才开 `dragToDismiss: true`：
//     内容区手势在手势竞技场里归内部滚动区，模态抽屉自身的拖拽够不到它（列表滚到
//     顶后继续下拉什么也不会发生）；开了之后走与表单抽屉同一套（`PiggySheetDragScope`）
//     —— 跟手、可停住、按「卡片高度一半 / 700px/s」判定，折返上滑 1:1 收回且内容不动。
//  2) **滚轮型必须保持 false**（`CupertinoPicker`：日期 / 时间 / 通用 / 年份范围 / 账户）：
//     竖直拖拽本身就是滚轮的操作，钉顶物理会把滚轮手势抢走。没开时行为必须与原生
//     一字不差：拖内容不收抽屉、卡片不动，顶栏仍能拖（那是模态抽屉自身的拖拽）。
//
// 白名单由「守门」用例从源码派生，防止有人顺手给滚轮型开上。

import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoPicker;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/widgets/ui/picker_sheet.dart';
import 'package:piggycount/widgets/ui/sheet_card.dart';

/// 允许开 `dragToDismiss: true` 的文件（内容是可滚动列表 / 网格）。
const Set<String> _dragToDismissAllowed = <String>{
  'lib/widgets/currency/currency_picker_sheet.dart', // 币种列表
  'lib/widgets/category/category_picker_sheet.dart', // 分类列表 / 网格
  'lib/widgets/biz/category_selector_dialog.dart', // 分类筛选列表
  'lib/widgets/biz/day_of_month_picker.dart', // 1~28 日网格（大字号下滚动兜底）
  'lib/widgets/biz/search_filter_sheet.dart', // 筛选 - 账户列表
  'lib/widgets/ui/option_sheet.dart', // 动作菜单列表（大字号下滚动兜底）
  'lib/pages/tag/widgets/tag_selector.dart', // 标签列表
};

/// 内容是可滚动列表的假选择器内容。
Widget _list(int itemCount) => ListView.builder(
      itemCount: itemCount,
      itemBuilder: (context, i) => SizedBox(
        height: 56,
        child: Center(child: Text('条目 $i')),
      ),
    );

/// 滚轮内容（`CupertinoPicker` 内部就是竖直滚动的 `ListWheelScrollView`）。
Widget _wheel() => SizedBox(
      height: 156,
      child: CupertinoPicker(
        itemExtent: 52,
        onSelectedItemChanged: (_) {},
        children: <Widget>[
          for (var i = 0; i < 10; i++) Center(child: Text('轮 $i')),
        ],
      ),
    );

void main() {
  Future<void> openPicker(
    WidgetTester tester, {
    required Widget child,
    required bool dragToDismiss,
  }) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showPiggyPickerSheet<void>(
                context,
                dragToDismiss: dragToDismiss,
                builder: (_) =>
                    PiggyPickerSheet(title: '选择器', child: child),
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

  double sheetTop(WidgetTester tester) =>
      tester.getRect(find.byType(PiggySheetCard)).top;

  double sheetHeight(WidgetTester tester) =>
      tester.getSize(find.byType(PiggySheetCard)).height;

  /// 按住并往下拖 [distance]（第一下越过手势识别 slop 只作激活），不松手。
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

  testWidgets('列表型：顶栏（非滚动区）下拉 → 关闭抽屉', (tester) async {
    await openPicker(tester, child: _list(30), dragToDismiss: true);
    expect(sheetOpen(), isTrue);

    await tester.drag(find.text('选择器'), Offset(0, sheetHeight(tester) * 0.7));
    await tester.pumpAndSettle();

    expect(sheetOpen(), isFalse);
  });

  testWidgets('列表型：列表滚到顶后继续下拉 → 跟手，过阈值关闭', (tester) async {
    await openPicker(tester, child: _list(30), dragToDismiss: true);
    final double topBefore = sheetTop(tester);
    final double itemOffsetInCard =
        tester.getRect(find.text('条目 0')).top - topBefore;

    final TestGesture gesture =
        await startPullDown(tester, find.text('条目 0'), 120);
    expect(
      sheetTop(tester) - topBefore,
      closeTo(120, 1),
      reason: '内容到顶后继续下拉要跟手',
    );
    expect(
      tester.getRect(find.text('条目 0')).top - sheetTop(tester),
      closeTo(itemOffsetInCard, 0.5),
      reason: '下拉期间列表内容钉在顶部不动',
    );

    // 收回到顶再上滑：交回给列表滚动（不误收抽屉）
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(sheetTop(tester), greaterThan(topBefore));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(sheetOpen(), isTrue, reason: '没过阈值只是回弹归位');

    // 真正拖过半屏 → 关闭
    await tester.drag(find.text('条目 0'), Offset(0, sheetHeight(tester) * 0.7));
    await tester.pumpAndSettle();
    expect(sheetOpen(), isFalse);
  });

  testWidgets('列表型：列表中间下拉 → 只滚列表，卡片纹丝不动', (tester) async {
    await openPicker(tester, child: _list(30), dragToDismiss: true);

    // 先把列表滚下去（手指上拖）
    await tester.drag(find.text('条目 0'), const Offset(0, -160));
    await tester.pumpAndSettle();
    final double topAfterScroll = sheetTop(tester);

    // 再从列表中间往下拖：只应把列表滚回去，卡片不能动
    await tester.drag(find.text('条目 4'), const Offset(0, 100));
    await tester.pumpAndSettle();

    expect(sheetTop(tester), closeTo(topAfterScroll, 0.5), reason: '卡片不许跟着走');
    expect(sheetOpen(), isTrue);
  });

  testWidgets('列表型：拖到阈值以内松手 → 先停住再回弹归位（不关闭）', (tester) async {
    await openPicker(tester, child: _list(30), dragToDismiss: true);
    final double topBefore = sheetTop(tester);

    final TestGesture gesture = await startPullDown(
      tester,
      find.text('条目 0'),
      sheetHeight(tester) * 0.3,
    );
    final double moved = sheetTop(tester) - topBefore;
    expect(moved, greaterThan(sheetHeight(tester) * 0.25), reason: '跟手 1:1');
    expect(moved, lessThan(sheetHeight(tester) * 0.5), reason: '仍在阈值内');

    await tester.pump(const Duration(milliseconds: 120));
    expect(sheetTop(tester) - topBefore, closeTo(moved, 0.5), reason: '可停住');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(sheetTop(tester), closeTo(topBefore, 0.5));
    expect(sheetOpen(), isTrue);
  });

  testWidgets('滚轮型（未开 dragToDismiss）：拖滚轮不收抽屉、卡片不动，顶栏仍可拖', (tester) async {
    await openPicker(tester, child: _wheel(), dragToDismiss: false);
    final topBefore = sheetTop(tester);

    // 拖滚轮：滚轮自己滚（手指下拖 = 滚轮内容下移），卡片一动不动
    await tester.drag(find.byType(CupertinoPicker), const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(sheetTop(tester), closeTo(topBefore, 0.5), reason: '拖滚轮不许动抽屉');
    expect(sheetOpen(), isTrue);

    // 顶栏（非滚动区）仍走模态抽屉自身的拖拽 → 可关闭
    await tester.drag(find.text('选择器'), Offset(0, sheetHeight(tester) * 0.7));
    await tester.pumpAndSettle();
    expect(sheetOpen(), isFalse, reason: '滚轮型的顶栏拖拽是原生行为，必须保留');
  });

  test('守门：只有内容可滚动的列表 / 网格型选择器才开 dragToDismiss（滚轮型禁开）', () {
    final Set<String> enabled = <String>{};
    for (final FileSystemEntity entity
        in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String path = entity.path.replaceAll(r'\', '/');
      for (final String line in entity.readAsLinesSync()) {
        final String trimmed = line.trim();
        // 只看代码行：注释里提到 `dragToDismiss: true` 不算启用
        if (trimmed.startsWith('//')) continue;
        if (trimmed.contains('dragToDismiss: true')) enabled.add(path);
      }
    }

    expect(
      enabled,
      _dragToDismissAllowed,
      reason: '新增 / 移除开启点必须同时改白名单：'
          '内容是可滚动列表 / 网格才允许（滚轮型、非滚动动作菜单禁止）',
    );
  });
}
