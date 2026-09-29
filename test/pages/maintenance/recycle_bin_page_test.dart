import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/base_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/maintenance/recycle_bin_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';

class _FakeRepo extends Mock implements BaseRepository {}

class _FakeSync extends Mock implements SyncService {}

/// 回收站恢复实时消失回归测试。
///
/// 背景：点恢复后库内归档行已删、实际已还原，但列表仍显示该行，
/// 重进页面才会消失。本测试用假仓（恢复返回 true）点恢复，
/// 断言该行同步消失、不依赖重进或后台重载。
void main() {
  late _FakeRepo repo;
  late _FakeSync sync;

  final tx = Transaction(
    id: 5,
    ledgerId: 1,
    type: 'expense',
    amount: 105,
    happenedAt: DateTime(2026, 9, 28, 10, 19),
    excludeFromStats: false,
    excludeFromBudget: false,
    currencyCode: 'CNY',
  );
  DeletedTransaction row() => DeletedTransaction(
        txId: 5,
        ledgerId: 1,
        happenedAt: DateTime(2026, 9, 28, 10, 19),
        deletedAt: DateTime(2026, 9, 28, 11, 10),
        payload: jsonEncode(tx.toJson()),
      );
  Ledger ledger() => Ledger(
        id: 1,
        name: '默认账本',
        currency: 'CNY',
        type: 'personal',
        createdAt: DateTime(2026, 1, 1),
        syncId: 'ledger-1',
        myRole: 'owner',
        memberCount: 1,
        isShared: false,
        monthStartDay: 1,
      );

  Widget host() {
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        syncServiceProvider.overrideWithValue(sync),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: RecycleBinPage(),
      ),
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repo = _FakeRepo();
    sync = _FakeSync();
    when(() => sync.markLocalChanged(ledgerId: any(named: 'ledgerId')))
        .thenReturn(null);
    when(() => repo.getDeletedTransactions()).thenAnswer((_) async => [row()]);
    when(() => repo.getAllLedgers()).thenAnswer((_) async => [ledger()]);
    when(() => repo.restoreDeletedTransaction(any()))
        .thenAnswer((_) async => true);
  });

  testWidgets('点恢复后该行实时消失，不等重进', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.restore), findsOneWidget);

    await tester.tap(find.byIcon(Icons.restore));
    await tester.pumpAndSettle();

    verify(() => repo.restoreDeletedTransaction(5)).called(1);
    expect(find.byIcon(Icons.restore), findsNothing);
    expect(find.text('回收站是空的'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // showToast 用 2 秒定时器自动收Overlay：走完它再结束，否则报 pending timer。
    await tester.pump(const Duration(seconds: 3));
  });
}
