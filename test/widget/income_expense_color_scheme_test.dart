/// 2026-08 v2 方案回归:三套「收入/支出」配色(`redIncome` / `greenIncome`
/// / `blueIncome`)在 widget view 入参被 setState 切换时,对应映射的颜色
/// 字面量(incomeColor/expenseColor → widgetIncomeColor/widgetExpenseColor)
/// 应该保持文档里给定的色值:
/// - redIncome   → income=#E5533C / expense=#2FA36B
/// - greenIncome → income=#2FA36B / expense=#E5533C
/// - blueIncome  → income=#477AF8 / expense=#EE6839
///
/// 历史版本(`redForIncome: bool`)只在前两种之间切换;此测试覆盖第三
/// 种 + 三种互不相等两个不变量,在主屏、外发的桌面小组件、widget
/// 预览生成器三处共用同一组色值。
library;

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/providers/theme_providers.dart' show IncomeExpenseColorScheme;
import 'package:piggycount/widget/views/widget_view_style.dart';

void main() {
  group('IncomeExpenseColorScheme (v2)', () {
    test('每个枚举值都有不同的 persistenceKey,且默认是 blueIncome',
        () {
      final keys = IncomeExpenseColorScheme.values
          .map((v) => v.persistenceKey)
          .toSet();
      expect(keys.length, IncomeExpenseColorScheme.values.length,
          reason: 'persistenceKey 必须唯一,否则 prefs/cloud sync 会撞键');
      for (final v in IncomeExpenseColorScheme.values) {
        expect(v.persistenceKey, isNotEmpty);
      }
    });

    test('fromKey 兼容老 bool + 字符串未知值回退到 blueIncome(默认)', () {
      // 老 prefs/cloud sync 一段时间里仍以 bool 形态保存;不能拒绝。
      expect(IncomeExpenseColorScheme.fromKey(true),
          IncomeExpenseColorScheme.redIncome);
      expect(IncomeExpenseColorScheme.fromKey(false),
          IncomeExpenseColorScheme.greenIncome);
      // 合法字符串
      expect(IncomeExpenseColorScheme.fromKey('redIncome'),
          IncomeExpenseColorScheme.redIncome);
      expect(IncomeExpenseColorScheme.fromKey('greenIncome'),
          IncomeExpenseColorScheme.greenIncome);
      expect(IncomeExpenseColorScheme.fromKey('blueIncome'),
          IncomeExpenseColorScheme.blueIncome);
      // 未知字符串/类型 → 默认值(blueIncome),绝不抛
      expect(IncomeExpenseColorScheme.fromKey(null),
          IncomeExpenseColorScheme.blueIncome);
      expect(IncomeExpenseColorScheme.fromKey('garbage'),
          IncomeExpenseColorScheme.blueIncome);
      expect(IncomeExpenseColorScheme.fromKey(42),
          IncomeExpenseColorScheme.blueIncome);
    });

    test('widgetIncomeColor / widgetExpenseColor 三方案色值固定', () {
      // redIncome(经典红入/绿支)
      expect(widgetExpenseColor(IncomeExpenseColorScheme.redIncome),
          const Color(0xFF2FA36B));
      expect(widgetIncomeColor(IncomeExpenseColorScheme.redIncome),
          const Color(0xFFE5533C));
      // greenIncome(红支/绿入)
      expect(widgetExpenseColor(IncomeExpenseColorScheme.greenIncome),
          const Color(0xFFE5533C));
      expect(widgetIncomeColor(IncomeExpenseColorScheme.greenIncome),
          const Color(0xFF2FA36B));
      // blueIncome(2026-08 新增,默认)— 收入 #477AF8 / 支出 #EE6839。
      expect(widgetExpenseColor(IncomeExpenseColorScheme.blueIncome),
          const Color(0xFFEE6839));
      expect(widgetIncomeColor(IncomeExpenseColorScheme.blueIncome),
          const Color(0xFF477AF8));
    });

    test('三方案互不相等 — 切换 provider 应该换来肉眼可见的差异', () {
      final reds = <Color>{
        widgetIncomeColor(IncomeExpenseColorScheme.redIncome),
        widgetIncomeColor(IncomeExpenseColorScheme.greenIncome),
        widgetIncomeColor(IncomeExpenseColorScheme.blueIncome),
      };
      expect(reds.length, 3,
          reason: '三方案的 income 色必须互不相同');
      final greens = <Color>{
        widgetExpenseColor(IncomeExpenseColorScheme.redIncome),
        widgetExpenseColor(IncomeExpenseColorScheme.greenIncome),
        widgetExpenseColor(IncomeExpenseColorScheme.blueIncome),
      };
      expect(greens.length, 3,
          reason: '三方案的 expense 色必须互不相同');
    });
  });
}
