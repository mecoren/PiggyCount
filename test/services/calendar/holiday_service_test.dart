// HolidayService / HolidayScheduler 契约（prd/calendar_holiday design.md §7，
// 2026-09-29 修订为每月一次口径 + 年份范围补写）：
//  - shouldUpdateNow 全分支（从未成功 / 本月已成功 / 上月成功 / 跨年 / 时钟回拨）
//  - yearsToFetch 12 月含明年
//  - parseYearResponse 响应形状（date 优先 / MM-DD 拼接 / code≠0 / 脏数据跳过）
//  - 预置表覆盖关键日（放假 / 补班）
//  - loadAll 按年合并（DB 空回落预置；补写历史年份不冲掉 2026 兜底）
//  - 拉取失败保留旧缓存 + 失败计数 +1
//  - fetchYear 按年补写（成功 / 空响应 / 失败三分支 + AC-E6 记账差异）
//  - fetchYearRange 范围补写（计数 / 单年失败跳过 / 熔断 / 记账一次 / 取消）
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/holiday_repository.dart';
import 'package:piggycount/services/calendar/holiday_scheduler.dart';
import 'package:piggycount/services/calendar/holiday_service.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);
  final ResponseBody Function(RequestOptions) handler;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body) => ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType]
      },
    );

/// 假的 Repository：内存态，只验证 Service 的编排语义（真库语义由
/// local_holiday_repository_test.dart 覆盖）。
class _FakeHolidayRepo implements HolidayRepository {
  final List<HolidayEntry> rows = [];
  final List<int> replacedYears = [];
  int saveMetaCount = 0;

  HolidayUpdateMetaData meta = HolidayUpdateMetaData(
    id: HolidayRepository.metaRowId,
    lastUpdateMs: 0,
    lastAttemptMs: 0,
    failureCount: 0,
    autoEnabled: true,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  @override
  Future<List<HolidayEntry>> getAll() async =>
      [...rows]..sort((a, b) => a.date.compareTo(b.date));

  @override
  Future<List<HolidayEntry>> getByYear(int year) async =>
      (rows.where((r) => r.year == year).toList()
        ..sort((a, b) => a.date.compareTo(b.date)));

  @override
  Future<HolidayEntry?> getByDate(String date) async {
    for (final r in rows) {
      if (r.date == date) return r;
    }
    return null;
  }

  @override
  Future<void> replaceYear(int year, List<HolidayEntry> newRows) async {
    replacedYears.add(year);
    rows.removeWhere((r) => r.year == year);
    for (final r in newRows) {
      rows.removeWhere((e) => e.date == r.date);
      rows.add(r);
    }
  }

  @override
  Future<HolidayUpdateMetaData> getMeta() async => meta;

  @override
  Future<void> saveMeta(HolidayUpdateMetaData m) async {
    saveMetaCount++;
    meta = m;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shouldUpdateNow 判定（每月一次口径）', () {
    final now = DateTime(2026, 9, 28, 9, 0);

    test('从未成功（首装冷启动）→ 更新', () {
      expect(
        HolidayService.shouldUpdateNow(lastUpdateMs: 0, now: now),
        isTrue,
      );
    });

    test('本月已成功 → 不更新（月初成功月末也不重复）', () {
      expect(
        HolidayService.shouldUpdateNow(
          lastUpdateMs: DateTime(2026, 9, 1, 8, 5).millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });

    test('昨天成功（同为 9 月）→ 不更新', () {
      expect(
        HolidayService.shouldUpdateNow(
          lastUpdateMs: DateTime(2026, 9, 27, 8, 30).millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });

    test('上月成功 → 跨入新月即更新（8-31 → 9-1）', () {
      expect(
        HolidayService.shouldUpdateNow(
          lastUpdateMs: DateTime(2026, 8, 31, 23, 0).millisecondsSinceEpoch,
          now: DateTime(2026, 9, 1, 0, 1),
        ),
        isTrue,
      );
    });

    test('跨年（去年 12 月成功 → 1 月）→ 更新', () {
      expect(
        HolidayService.shouldUpdateNow(
          lastUpdateMs: DateTime(2025, 12, 20, 10, 0).millisecondsSinceEpoch,
          now: DateTime(2026, 1, 1, 9, 0),
        ),
        isTrue,
      );
    });

    test('lastUpdateMs 在本月的未来时刻（时钟回拨）→ 视为本月已成功，不更新', () {
      expect(
        HolidayService.shouldUpdateNow(
          lastUpdateMs: DateTime(2026, 9, 30).millisecondsSinceEpoch,
          now: now,
        ),
        isFalse,
      );
    });

    test('HolidayScheduler.shouldTriggerNow 只补开关项', () {
      expect(
        HolidayScheduler.shouldTriggerNow(
            enabled: false, lastUpdateMs: 0, now: now),
        isFalse,
      );
      expect(
        HolidayScheduler.shouldTriggerNow(
            enabled: true, lastUpdateMs: 0, now: now),
        isTrue,
      );
    });
  });

  group('yearsToFetch', () {
    test('非 12 月只拉今年；12 月含明年（元旦跨年）', () {
      expect(HolidayService.yearsToFetch(DateTime(2026, 11, 30)), [2026]);
      expect(HolidayService.yearsToFetch(DateTime(2026, 12, 1)), [2026, 2027]);
    });
  });

  group('parseYearResponse', () {
    test('date 字段优先、MM-DD 拼接兜底、按日期升序', () {
      final rows = HolidayService.parseYearResponse(2026, {
        'code': 0,
        'holiday': {
          '02-15': {'holiday': true, 'name': '春节', 'date': '2026-02-15'},
          '01-04': {'holiday': false, 'name': '元旦后补班'},
        },
      });
      expect(rows.map((r) => r.date).toList(),
          ['2026-01-04', '2026-02-15']); // 08 拼出完整日期并升序
      expect(rows.first.isHoliday, isFalse); // 补班
      expect(rows.first.name, '元旦后补班');
      expect(rows.last.isHoliday, isTrue);
      expect(rows.last.year, 2026);
    });

    test('code≠0 / holiday 非对象 → 抛 HolidayFetchException', () {
      expect(
        () => HolidayService.parseYearResponse(2026, {'code': 1}),
        throwsA(isA<HolidayFetchException>()),
      );
      expect(
        () => HolidayService.parseYearResponse(
            2026, {'code': 0, 'holiday': <dynamic>[]}),
        throwsA(isA<HolidayFetchException>()),
      );
    });

    test('脏数据跳过：键拼不出 10 位日期 / 值不是对象', () {
      final rows = HolidayService.parseYearResponse(2026, {
        'code': 0,
        'holiday': {
          '1-1': {'holiday': true, 'name': '脏'},
          '03-01': 'not-a-map',
          '05-01': {'holiday': true, 'name': '劳动节', 'date': '2026-05-01'},
        },
      });
      expect(rows.length, 1);
      expect(rows.single.date, '2026-05-01');
    });
  });

  group('预置兜底表', () {
    test('覆盖 2026 关键日：国庆放假 / 节后补班 / 春节初一', () {
      final byDate = HolidayService.builtinHolidayByDate();
      expect(byDate['2026-10-01']!.isHoliday, isTrue);
      expect(byDate['2026-10-01']!.name, '国庆节');
      expect(byDate['2026-10-10']!.isHoliday, isFalse);
      expect(byDate['2026-10-10']!.name, contains('补班'));
      expect(byDate['2026-02-17']!.isHoliday, isTrue);
      expect(HolidayService.builtinHolidays().every((h) => h.year == 2026),
          isTrue);
    });

    test('loadAll：DB 空 → 回落预置表（离线 / 首装可用）', () async {
      final repo = _FakeHolidayRepo();
      final svc = HolidayService(repo);
      final rows = await svc.loadAll();
      expect(rows.length, HolidayService.builtinHolidays().length);
      expect(rows.any((r) => r.date == '2026-10-01'), isTrue);
    });

    test('loadAll：DB 已覆盖的年份以 DB 为准', () async {
      final repo = _FakeHolidayRepo();
      repo.rows.add(HolidayEntry(
        date: '2026-03-08',
        year: 2026,
        isHoliday: true,
        name: '测试日',
        fetchedAt: DateTime.now(),
      ));
      final rows = await HolidayService(repo).loadAll();
      expect(rows.length, 1);
      expect(rows.single.name, '测试日');
    });

    test('loadAll：补写历史年份后 2026 预置兜底仍在（按年合并，AC-E5）', () async {
      final repo = _FakeHolidayRepo();
      repo.rows.add(HolidayEntry(
        date: '2022-01-01',
        year: 2022,
        isHoliday: true,
        name: '元旦',
        fetchedAt: DateTime.now(),
      ));
      final rows = await HolidayService(repo).loadAll();
      expect(rows.any((r) => r.year == 2022), isTrue, reason: 'DB 年份保留');
      expect(rows.any((r) => r.date == '2026-10-01'), isTrue,
          reason: '2026 未被 DB 覆盖 → 预置兜底继续生效');
      expect(rows.length, 1 + HolidayService.builtinHolidays().length);
      expect(rows.map((r) => r.date).toSet().length, rows.length,
          reason: '合并结果不得出现重复日期');
    });
  });

  group('更新流程', () {
    test('updateNow 成功：整年替换 + 记账清零 + 不含失败计数', () async {
      final repo = _FakeHolidayRepo();
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((o) => _json({
            'code': 0,
            'holiday': {
              '10-01': {'holiday': true, 'name': '国庆节', 'date': '2026-10-01'},
              '10-10': {'holiday': false, 'name': '国庆节后补班'},
            },
          }));
      final svc = HolidayService(repo, dio: dio);

      final meta = await svc.updateNow();

      expect(repo.replacedYears, isNotEmpty);
      expect(repo.rows.any((r) => r.date == '2026-10-01'), isTrue);
      expect(repo.rows.any((r) => r.date == '2026-10-10'), isTrue);
      expect(meta.lastUpdateMs, greaterThan(0));
      expect(meta.failureCount, 0);
    });

    test('updateNow 失败：抛错、保留旧缓存、失败计数 +1', () async {
      final repo = _FakeHolidayRepo();
      repo.rows.add(HolidayEntry(
        date: '2026-10-01',
        year: 2026,
        isHoliday: true,
        name: '国庆节',
        fetchedAt: DateTime.now(),
      ));
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((o) =>
          throw DioException.connectionError(
              requestOptions: o, reason: 'down'));
      final svc = HolidayService(repo, dio: dio);

      await expectLater(svc.updateNow(), throwsA(isA<DioException>()));

      expect(repo.rows.length, 1, reason: '失败不得清空旧缓存');
      expect(repo.rows.single.date, '2026-10-01');
      expect(repo.meta.failureCount, 1);
      expect(repo.meta.lastAttemptMs, greaterThan(0));
      expect(repo.meta.lastUpdateMs, 0, reason: '失败不更新成功时间');
      expect(repo.replacedYears, isEmpty, reason: '拉取失败不得进入替换阶段');
    });

    test('autoUpdateIfDue 分支：关开关 / 本月已成功不拉，跨月才拉', () async {
      var fetchCount = 0;
      final repo = _FakeHolidayRepo();
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((o) {
        fetchCount++;
        return _json({'code': 0, 'holiday': <String, dynamic>{}});
      });
      final svc = HolidayService(repo, dio: dio);

      // 1) 调用方显式禁用
      expect(await svc.autoUpdateIfDue(enabled: false), isFalse);
      // 2) 本地开关关闭
      repo.meta = repo.meta.copyWith(autoEnabled: false);
      expect(await svc.autoUpdateIfDue(), isFalse);
      // 3) 开启但本月已成功
      repo.meta = repo.meta.copyWith(
        autoEnabled: true,
        lastUpdateMs: DateTime.now().millisecondsSinceEpoch,
      );
      expect(await svc.autoUpdateIfDue(), isFalse);
      expect(fetchCount, 0, reason: '前三种情形都不得出网');

      // 4) 上月成功 → 拉取（每月一次口径）
      repo.meta = repo.meta.copyWith(
        lastUpdateMs: DateTime.now()
            .subtract(const Duration(days: 40))
            .millisecondsSinceEpoch,
      );
      expect(await svc.autoUpdateIfDue(), isTrue);
      expect(fetchCount, greaterThan(0));
    });

    test('setAutoEnabled：开关状态落库', () async {
      final repo = _FakeHolidayRepo();
      final svc = HolidayService(repo);

      await svc.setAutoEnabled(false);
      expect(repo.meta.autoEnabled, isFalse);

      await svc.setAutoEnabled(true);
      expect(repo.meta.autoEnabled, isTrue);
    });
  });

  group('按年补写 fetchYear（第二轮 AC-E1 / E6 / E7）', () {
    test('年份边界：下界 2013（数据源实测下界）、上界为明年', () {
      expect(HolidayService.yearMin, 2013);
      expect(HolidayService.yearMax(DateTime(2026, 9, 28)), 2027);
      expect(HolidayService.yearMax(DateTime(2026, 12, 31)), 2027);
    });

    test('成功：整年替换该年 + rowCount + 失败计数清零', () async {
      final repo = _FakeHolidayRepo();
      repo.meta = repo.meta.copyWith(failureCount: 3);
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((o) => _json({
            'code': 0,
            'holiday': {
              '01-01': {'holiday': true, 'name': '元旦', 'date': '2022-01-01'},
              '01-02': {'holiday': true, 'name': '元旦', 'date': '2022-01-02'},
            },
          }));
      final svc = HolidayService(repo, dio: dio);

      final result = await svc.fetchYear(2022);

      expect(result.rowCount, 2);
      expect(repo.replacedYears, [2022], reason: '只替换所补年份');
      expect(repo.rows.where((r) => r.year == 2022).length, 2);
      expect(repo.meta.failureCount, 0);
      expect(repo.meta.lastAttemptMs, greaterThan(0));
    });

    test('历史年份不写 lastUpdateMs（AC-E6：不抑制当天自动更新）', () async {
      final repo = _FakeHolidayRepo();
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter(
          (o) => _json({'code': 0, 'holiday': <String, dynamic>{}}));
      final svc = HolidayService(repo, dio: dio);

      final result = await svc.fetchYear(2022);

      expect(result.rowCount, 0, reason: '空响应 = 该年无数据');
      expect(result.meta.lastUpdateMs, 0, reason: '历史年份不得写成功时间');
      expect(repo.meta.lastUpdateMs, 0);
      expect(repo.meta.failureCount, 0, reason: '空响应按成功处理');
      expect(repo.replacedYears, [2022], reason: '空响应也执行整年替换（清空该年）');
    });

    test('补今年时写 lastUpdateMs（属自动更新范围）', () async {
      final thisYear = DateTime.now().year;
      final repo = _FakeHolidayRepo();
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((o) => _json({
            'code': 0,
            'holiday': {
              '10-01': {
                'holiday': true,
                'name': '国庆节',
                'date': '$thisYear-10-01'
              },
            },
          }));
      final svc = HolidayService(repo, dio: dio);

      final result = await svc.fetchYear(thisYear);

      expect(result.rowCount, 1);
      expect(result.meta.lastUpdateMs, greaterThan(0));
    });

    test('失败：抛错、保留旧缓存、失败计数 +1、不进替换阶段', () async {
      final repo = _FakeHolidayRepo();
      repo.rows.add(HolidayEntry(
        date: '2022-01-01',
        year: 2022,
        isHoliday: true,
        name: '元旦',
        fetchedAt: DateTime.now(),
      ));
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((o) =>
          throw DioException.connectionError(
              requestOptions: o, reason: 'down'));
      final svc = HolidayService(repo, dio: dio);

      await expectLater(svc.fetchYear(2022), throwsA(isA<DioException>()));

      expect(repo.rows.length, 1, reason: '失败不得清空旧缓存');
      expect(repo.rows.single.date, '2022-01-01');
      expect(repo.meta.failureCount, 1);
      expect(repo.meta.lastUpdateMs, 0);
      expect(repo.replacedYears, isEmpty);
    });
  });

  group('按年份范围补写 fetchYearRange（2026-09-29 修订：失败跳过不中止）', () {
    /// 按请求 URL 里的年份分支响应；[failYears] 内的年份直接断网。
    HolidayService svcFor(_FakeHolidayRepo repo,
        {Set<int> failYears = const {},
        required Set<int> emptyYears,
        List<int>? requests}) {
      final dio = Dio();
      dio.httpClientAdapter = _StubAdapter((o) {
        final year = int.parse(o.uri.pathSegments.last);
        requests?.add(year);
        if (failYears.contains(year)) {
          throw DioException.connectionError(requestOptions: o, reason: 'down');
        }
        if (emptyYears.contains(year)) {
          return _json({'code': 0, 'holiday': <String, dynamic>{}});
        }
        return _json({
          'code': 0,
          'holiday': {
            '01-01': {'holiday': true, 'name': '元旦', 'date': '$year-01-01'},
          },
        });
      });
      return HolidayService(repo, dio: dio);
    }

    test('区间逐年补写：成功 / 无数据分别计数，全部完成无失败', () async {
      final repo = _FakeHolidayRepo();
      final requests = <int>[];
      final svc = svcFor(repo, emptyYears: {2023}, requests: requests);

      final result = await svc.fetchYearRange(2022, 2024);

      expect(result.updated, 2);
      expect(result.noData, 1);
      expect(result.failedYears, isEmpty);
      expect(result.firstError, isNull);
      expect(result.aborted, isFalse);
      expect(result.cancelled, isFalse);
      expect(requests..sort(), [2022, 2023, 2024],
          reason: '分片并发后落库仍按年份升序，请求集合一致');
      expect(repo.replacedYears.toSet(), {2022, 2023, 2024});
      expect(repo.rows.where((r) => r.year == 2022).length, 1);
    });

    test('区间内某年失败 → 跳过该年继续拉后续年份', () async {
      final repo = _FakeHolidayRepo();
      final requests = <int>[];
      final svc =
          svcFor(repo, failYears: {2023}, emptyYears: {}, requests: requests);

      final result = await svc.fetchYearRange(2022, 2025);

      expect(result.updated, 3, reason: '2022 / 2024 / 2025 成功计入');
      expect(result.noData, 0);
      expect(result.failedYears, [2023]);
      expect(result.firstError, isNotNull);
      expect(result.aborted, isFalse, reason: '单年失败不触发熔断');
      expect(requests..sort(), [2022, 2023, 2024, 2025],
          reason: '2023 失败后 2024/2025 仍要请求');
      expect(repo.replacedYears.toSet(), {2022, 2024, 2025},
          reason: '失败年份旧缓存保留，成功年份正常替换');
    });

    test('区间内全部失败 → updated=0，failedYears 收齐全部年份', () async {
      final repo = _FakeHolidayRepo();
      final svc = svcFor(repo, failYears: {2022, 2023, 2024}, emptyYears: {});

      final result = await svc.fetchYearRange(2022, 2024);

      expect(result.updated, 0);
      expect(result.noData, 0);
      expect(result.failedYears, [2022, 2023, 2024]);
      expect(result.firstError, isNotNull);
      expect(repo.replacedYears, isEmpty);
      expect(repo.meta.failureCount, 1,
          reason: '整次范围操作只记一次失败（此前逐年各 +1 会刷出连续失败 3 次）');
    });

    test('连续传输失败熔断：不断网试剩余年份，未尝试的同样记失败', () async {
      final repo = _FakeHolidayRepo();
      final requests = <int>[];
      final svc = svcFor(
        repo,
        failYears: {2022, 2023, 2024, 2025, 2026, 2027, 2028, 2029},
        emptyYears: {},
        requests: requests,
      );

      final result = await svc.fetchYearRange(2022, 2029);

      expect(result.aborted, isTrue);
      expect(result.updated, 0);
      expect(
          result.failedYears, [2022, 2023, 2024, 2025, 2026, 2027, 2028, 2029]);
      expect(requests.length, lessThan(8), reason: '熔断后剩余年份不再请求（此前逐个等到超时）');
      expect(repo.meta.failureCount, 1, reason: '熔断整次也只记一次');
      expect(result.firstError, isNotNull);
    });

    test('部分失败记账一次：此前失败 5 次 → 6 次而非逐年累加', () async {
      final repo = _FakeHolidayRepo();
      repo.meta = repo.meta.copyWith(failureCount: 5);
      final svc = svcFor(repo, failYears: {2023}, emptyYears: {});

      final result = await svc.fetchYearRange(2022, 2024);

      expect(result.failedYears, [2023]);
      expect(repo.meta.failureCount, 6);
    });

    test('全成功清零失败计数', () async {
      final repo = _FakeHolidayRepo();
      repo.meta = repo.meta.copyWith(failureCount: 5);
      final svc = svcFor(repo, emptyYears: {2023});

      final result = await svc.fetchYearRange(2022, 2024);

      expect(result.failedYears, isEmpty);
      expect(repo.meta.failureCount, 0);
    });

    test('取消且颗粒无收：不请求、记账原样恢复', () async {
      final repo = _FakeHolidayRepo();
      final requests = <int>[];
      final svc = svcFor(repo, emptyYears: {}, requests: requests);
      final before = repo.meta;

      final result =
          await svc.fetchYearRange(2022, 2024, shouldCancel: () => true);

      expect(result.cancelled, isTrue);
      expect(result.updated, 0);
      expect(result.noData, 0);
      expect(result.failedYears, isEmpty);
      expect(requests, isEmpty);
      expect(repo.meta.failureCount, before.failureCount);
      expect(repo.meta.lastAttemptMs, before.lastAttemptMs);
    });

    test('范围内含自动更新年份且成功 → 写 lastUpdateMs', () async {
      final repo = _FakeHolidayRepo();
      final nowYear = DateTime.now().year;
      final svc = svcFor(repo, emptyYears: {});

      final result = await svc.fetchYearRange(nowYear, nowYear);

      expect(result.updated, 1);
      expect(repo.meta.lastUpdateMs, greaterThan(0));
    });

    test('单年区间 = 退化 range，语义与 fetchYear 一致', () async {
      final repo = _FakeHolidayRepo();
      final svc = svcFor(repo, emptyYears: {2022});

      final result = await svc.fetchYearRange(2022, 2022);

      expect(result.updated, 0);
      expect(result.noData, 1);
      expect(result.failedYears, isEmpty);
      expect(repo.replacedYears, [2022], reason: '空响应也执行整年替换');
    });
  });
}
