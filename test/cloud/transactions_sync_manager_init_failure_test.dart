// TSM 延迟初始化失败时**不得**产生「无人监听的异步错误」（2026-10-12 收口）。
//
// 背景（真机复现）：`_ensureInitialized` 的创建者分支自己
// `await _initialize(gen)`，从不 await 它创建的那个 Completer —— 该 Completer
// 是给**并发等待者**用的。于是初始化失败时 `completer.completeError(...)` 若
// 此刻没有任何等待者，这个 Future 的错误就无人监听 → Dart 直接上报到
// `PlatformDispatcher.onError`：日志里同时出现
//
//   StartupSyncChecker: 云端账本发现失败（降级跳过）: CloudSyncException ...
//   [Zone] Uncaught platform error: CloudSyncException ...
//
// 异常本身已被调用方（启动检查降级分支）正常捕获并记日志，所以第二次上报是
// 纯噪音；接入崩溃上报后会被记成崩溃。
//
// 复现用 **HTTP（非 HTTPS）** WebDAV 地址：`WebDAVProvider.initialize` 在
// **任何网络调用之前**就以「必须使用 HTTPS」拒绝（见
// packages/flutter_cloud_sync_webdav/lib/src/webdav_provider.dart 的 scheme
// 校验），确定性、零网络依赖。
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/base_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
  });

  TransactionsSyncManager buildManager() => TransactionsSyncManager(
        config: const fcs.CloudServiceConfig(
          type: fcs.CloudBackendType.webdav,
          name: 'test',
          // 非 https → initialize 在任何网络调用前即拒绝（确定性失败）
          webdavUrl: 'http://example.invalid/dav',
          webdavUsername: 'pctest',
          webdavPassword: 'piggy123',
        ),
        db: db,
        repo: _DummyRepo(),
      );

  test('初始化失败：异常仍照常上抛给调用方，且不留未处理的异步错误', () async {
    final unhandled = <Object>[];

    await runZonedGuarded(
      () async {
        await expectLater(
          buildManager().discoverRemoteLedgers(),
          throwsA(anything),
          reason: '调用方（启动检查降级分支 / 任意 await 方）必须仍能捕获该异常 —— '
              '修复只消除重复上报，不能吞掉错误',
        );
        // 给「未处理异步错误」的上报留出微任务 + 事件循环窗口
        await Future<void>.delayed(const Duration(milliseconds: 100));
      },
      (e, st) => unhandled.add(e),
    );

    expect(
      unhandled,
      isEmpty,
      reason: '初始化失败只应上抛一次给调用方；重复上报会污染错误日志，'
          '接入崩溃上报后会被记成崩溃',
    );
  });
}

class _DummyRepo implements BaseRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
