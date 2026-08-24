import 'dart:io';

/// 首页头部布局契约测试。
///
/// 锁定 2026-08 改版后的版式契约：
/// 1. PiggyHeader 内：56 高工具栏行（左账本胶囊 / 中 logo+标题 / 右操作）
///    → 12 间距 → HomeBudgetSummary 预算总结卡固定在头部；
/// 2. 月总结卡（HomeMonthSummaryCard）移出头部，置于 body 顶部、
///    水平 12 内边距，不随明细滚动。
///
/// 本测试读源码做正则匹配（非渲染断言），任何调整头部结构的改动都会
/// 在此失败提醒同步更新契约。
void main() {
  final source = File('lib/pages/main/home_page.dart').readAsStringSync();

  _expect(
    RegExp(
      r'return PiggyHeader\(\s*'
      r'child: Column\([\s\S]*?'
      r'SizedBox\(\s*height: 56,\s*child: Row\([\s\S]*?'
      r'const SizedBox\(height: 12\),\s*'
      r'// 预算总结卡片（固定在顶部）\s*'
      r'const HomeBudgetSummary\(\),',
    ).hasMatch(source),
    'approved toolbar row + fixed HomeBudgetSummary inside PiggyHeader',
  );

  _expect(
    RegExp(
      r'// 月总结卡片固定在顶部，不随明细滚动\s*'
      r'Padding\(\s*'
      r'padding: const EdgeInsets\.symmetric\(horizontal: 12\),\s*'
      r'child: HomeMonthSummaryCard\(',
    ).hasMatch(source),
    'approved HomeMonthSummaryCard pinned above the list (outside header)',
  );

  stdout.writeln('Home header spacing contract passed.');
}

void _expect(bool condition, String description) {
  if (!condition) {
    throw StateError('Expected $description.');
  }
}
