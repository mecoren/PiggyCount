// P2-15（治理批次）：单账本上传冲突守卫（uploadLedgerWithConflictGuard）
// 的 widget 级回归 —— 此前该数据安全交互全靠人工验证。
//
// 覆盖场景（对照 helper 契约注释）：
// - 首传成功（无冲突）→ true，不弹任何对话框
// - 三选一：取消 → false，云端/本地均不动
// - 三选一：强制上传 → 以 force:true 重试 → true
// - 三选一：对比合并 → 走 compareMerge 回调 → false
// - 未提供 compareMerge（二选一）：取消 → false；确认 → force 重试 → true
// - 非冲突异常 → 原样上抛（由调用方失败提示处理）
// - 二选一对话框按方向（cloudNewer/unknown）显示对应文案

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/cloud/upload_conflict_helper.dart';

Widget _wrap() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: const Scaffold(body: SizedBox.shrink()),
    );

/// 冲突对话框动作按钮文案（zh arb 实际值）
const _cancelLabel = '取消';
const _mergeLabel = '对比合并';
const _forceLabel = '覆盖上传';

void main() {
  late int forceCallCount;
  late bool mergeCalled;
  late List<bool> forceArgs;

  Future<void> Function({required bool force}) makeRun({
    Object? conflictDirection,
    Object? throwOnForce,
  }) {
    forceCallCount = 0;
    forceArgs = [];
    mergeCalled = false;
    return ({required bool force}) async {
      if (!force && conflictDirection != null) {
        throw CloudConflictException(direction: conflictDirection as String);
      }
      if (force && throwOnForce != null) {
        throw throwOnForce;
      }
      forceCallCount++;
      forceArgs.add(force);
    };
  }

  testWidgets('首传成功（无冲突）→ true，无对话框', (tester) async {
    await tester.pumpWidget(_wrap());
    final ctx = tester.element(find.byType(Scaffold));

    final result = await uploadLedgerWithConflictGuard(
      ctx,
      run: makeRun(),
      compareMerge: () async => mergeCalled = true,
    );
    await tester.pump();

    expect(result, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(mergeCalled, isFalse);
  });

  testWidgets('三选一：取消 → false，不再重试、云端本地均不动', (tester) async {
    await tester.pumpWidget(_wrap());
    final ctx = tester.element(find.byType(Scaffold));

    final future = uploadLedgerWithConflictGuard(
      ctx,
      run: makeRun(conflictDirection: 'cloudNewer'),
      compareMerge: () async => mergeCalled = true,
    );
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text(_cancelLabel));
    await tester.pump();

    expect(await future, isFalse);
    expect(forceCallCount, 0, reason: '取消后不得以 force 重试');
    expect(mergeCalled, isFalse);
  });

  testWidgets('三选一：强制上传 → force:true 重试成功 → true', (tester) async {
    await tester.pumpWidget(_wrap());
    final ctx = tester.element(find.byType(Scaffold));

    final future = uploadLedgerWithConflictGuard(
      ctx,
      run: makeRun(conflictDirection: 'unknown'),
      compareMerge: () async => mergeCalled = true,
    );
    await tester.pump();

    await tester.tap(find.text(_forceLabel));
    await tester.pump();

    expect(await future, isTrue);
    expect(forceArgs, [true], reason: '用户确认后必须以 force 重试');
    expect(mergeCalled, isFalse);
  });

  testWidgets('三选一：对比合并 → 走 compareMerge 回调 → false', (tester) async {
    await tester.pumpWidget(_wrap());
    final ctx = tester.element(find.byType(Scaffold));

    final future = uploadLedgerWithConflictGuard(
      ctx,
      run: makeRun(conflictDirection: 'unknown'),
      compareMerge: () async => mergeCalled = true,
    );
    await tester.pump();

    await tester.tap(find.text(_mergeLabel));
    await tester.pump();

    expect(await future, isFalse);
    expect(mergeCalled, isTrue);
    expect(forceCallCount, 0, reason: '合并路径不得触发 force 覆盖');
  });

  testWidgets('三选一：cloudNewer 方向显示「云端较新」文案', (tester) async {
    await tester.pumpWidget(_wrap());
    final ctx = tester.element(find.byType(Scaffold));

    final future = uploadLedgerWithConflictGuard(
      ctx,
      run: makeRun(conflictDirection: 'cloudNewer'),
      compareMerge: () async {},
    );
    await tester.pump();

    // cloudNewer 专属文案（zh arb：conflictUploadCloudNewerMessage）
    expect(
        find.textContaining('云端快照比本地更新'), findsOneWidget);
    await tester.tap(find.text(_cancelLabel));
    await tester.pump();
    expect(await future, isFalse);
  });

  testWidgets('未提供 compareMerge（二选一）：取消 → false 不重试', (tester) async {
    await tester.pumpWidget(_wrap());
    final ctx = tester.element(find.byType(Scaffold));

    final future = uploadLedgerWithConflictGuard(
      ctx,
      run: makeRun(conflictDirection: 'cloudNewer'),
    );
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text(_cancelLabel));
    await tester.pump();

    expect(await future, isFalse);
    expect(forceCallCount, 0);
  });

  testWidgets('未提供 compareMerge（二选一）：确认 → force 重试 → true',
      (tester) async {
    await tester.pumpWidget(_wrap());
    final ctx = tester.element(find.byType(Scaffold));

    final future = uploadLedgerWithConflictGuard(
      ctx,
      run: makeRun(conflictDirection: 'cloudNewer'),
    );
    await tester.pump();

    await tester.tap(find.text(_forceLabel));
    await tester.pump();

    expect(await future, isTrue);
    expect(forceArgs, [true]);
  });

  testWidgets('非冲突异常 → 原样上抛（调用方失败提示处理）', (tester) async {
    await tester.pumpWidget(_wrap());
    final ctx = tester.element(find.byType(Scaffold));

    Future<Never> run({required bool force}) async {
      throw Exception('network down');
    }
    await expectLater(
      uploadLedgerWithConflictGuard(ctx, run: run),
      throwsA(isA<Exception>().having((e) => e.toString(), 'text',
          contains('network down'))),
    );
    await tester.pump();
    // 未弹任何对话框（错误走调用方提示路径）
    expect(find.byType(AlertDialog), findsNothing);
  });
}
