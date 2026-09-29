import 'package:dio/dio.dart';

import '../../data/db.dart';
import '../../data/repositories/holiday_repository.dart';
import '../system/logger_service.dart';

/// 节假日拉取 / 解析 / 判定失败。
class HolidayFetchException implements Exception {
  HolidayFetchException(this.message);
  final String message;
  @override
  String toString() => 'HolidayFetchException: $message';
}

/// 中国法定节假日数据服务（prd/calendar_holiday）。
///
/// 数据源：timor.tech 免费公益接口 `https://timor.tech/api/holiday/year/{y}`，
/// 响应 `{"code":0,"holiday":{"MM-DD":{"holiday":true,"name":"春节","date":"..."}}}`；
/// `holiday:true` = 放假、`false` = 调休补班、不在 map 中 = 普通日（按星期判定）。
/// 国务院未发布次年安排时该年 map 为 `{}`，属正常状态（见 [builtinHolidays]）。
/// 请求需带浏览器 UA（服务端 Cloudflare 会拦无 UA 的默认客户端）。
///
/// 存储边界：只经 [HolidayRepository] 写本地缓存表，**不**记 ChangeTracker
/// （缓存可随时重建，不进同步 / 备份）。网络 / 判定在本层，事务在 Repository。
class HolidayService {
  HolidayService(this._repo, {Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = _timeout;
    _dio.options.receiveTimeout = _timeout;
  }

  /// 数据源基础地址（公益接口，无鉴权；UA 见 [_ua]）
  static const String apiBase = 'https://timor.tech/api/holiday/year';

  /// 预置数据覆盖的最早年份（更早年份线上也无数据）
  static const int builtinYearMin = 2026;

  /// 可按年补写的年份下界：timor.tech 实测有数据的最早年份（2026-09-30 实测：
  /// 2000 / 2007 / 2008 / 2010 / 2012 均返回 `{"code":0,"holiday":{}}`，
  /// 2013 起有完整数据）。下界之前的年份请求必空，不让用户选到。
  static const int yearMin = 2013;

  /// 可按年补写的年份上界：明年（与 [yearsToFetch] 的 12 月跨年口径一致）。
  static int yearMax(DateTime now) => now.year + 1;

  /// 浏览器 UA：timor.tech 的 Cloudflare 拦截无 UA 的默认客户端
  static const String _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';

  static const Duration _timeout = Duration(seconds: 20);

  /// 范围补写并发度：分片 `Future.wait` 逐片并发（18 年范围约 5 片）。
  /// 保守取 4，避免公益接口限流；落库仍串行（见 [fetchYearRange]）。
  static const int _rangeConcurrency = 4;

  /// 范围补写单次请求的收发超时。批量场景单年卡 20s 会拖住整片，
  /// 10s 足够返回这份 KB 级 JSON（连接建立仍受 [_timeout] 约束，
  /// Dio 5 不支持按请求覆盖 connectTimeout）。
  static const Duration _rangePerYearTimeout = Duration(seconds: 10);

  /// 连续失败这么多次后熔断剩余年份：网络已断的典型信号，再等下去
  /// 只是把剩余年份逐个等到超时（18 年 × 20s ≈ 6 分钟白等）。
  static const int _rangeAbortAfter = 3;

  /// 预置行的 fetchedAt 哨兵值（非网络获取，显式区分于真实拉取时间）
  static final DateTime _builtinFetchedAt =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  final HolidayRepository _repo;
  final Dio _dio;

  // ==========================================================================
  // 纯函数（单测直接覆盖，无 IO）
  // ==========================================================================

  /// 把异常压缩为一句可展示的原因（范围全失败时 toast 用，
  /// 见 `holidayFetchYearFailed`；只报个数用户无从排查）。
  static String shortError(Object e) {
    if (e is HolidayFetchException) return e.message;
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
          return '连接超时';
        case DioExceptionType.sendTimeout:
          return '发送超时';
        case DioExceptionType.receiveTimeout:
          return '接收超时';
        case DioExceptionType.connectionError:
          return '网络连接失败';
        case DioExceptionType.badResponse:
          return '服务端异常（${e.response?.statusCode ?? '未知'}）';
        case DioExceptionType.cancel:
          return '已取消';
        case DioExceptionType.transformTimeout:
          return '数据解析超时';
        case DioExceptionType.badCertificate:
        case DioExceptionType.unknown:
          return '网络异常';
      }
    }
    return '网络异常';
  }

  /// 是否应执行自动更新（**每月一次**口径，定时 + 补更判定的唯一口径，纯函数）。
  ///
  /// - [lastUpdateMs] `<= 0`（从未成功）→ 应更新（首装冷启动）；
  /// - 上次成功的日历月 ≠ 当前日历月（跨入新月后的首次启动 / tick）→ 应更新；
  /// - 其余（本月已成功过）→ 不更新。
  ///
  /// 失败不写成功时间，本轮月内后续 tick / 启动仍按缺额重试（与旧每日口径
  /// 的补更语义一致）。不校验时刻 / 日期——每月首次满足条件即更新。
  static bool shouldUpdateNow({
    required int lastUpdateMs,
    required DateTime now,
  }) {
    if (lastUpdateMs <= 0) return true;
    final last = DateTime.fromMillisecondsSinceEpoch(lastUpdateMs);
    return last.year != now.year || last.month != now.month;
  }

  /// 应拉取的年份集合：今年 +（本地 12 月时）明年（元旦跨年即有节假日可显示）。
  static List<int> yearsToFetch(DateTime now) =>
      now.month == 12 ? [now.year, now.year + 1] : [now.year];

  /// 解析 timor.tech 年接口响应（纯函数，单测覆盖形状）。
  ///
  /// `date` 字段更权威（YYYY-MM-DD）；异常缺失时由 `MM-DD + year` 拼合，
  /// 拼接后仍不是 10 位（脏数据）则跳过该条。
  static List<HolidayEntry> parseYearResponse(
      int year, Map<String, dynamic> data) {
    final code = data['code'];
    if (code != 0) {
      throw HolidayFetchException('接口返回 code=$code（非 0）');
    }
    final holiday = data['holiday'];
    if (holiday is! Map) {
      throw HolidayFetchException('响应结构异常：holiday 非对象');
    }
    final fetchedAt = DateTime.now();
    final rows = <HolidayEntry>[];
    for (final entry in holiday.entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      final rawDate = (raw['date'] ?? '').toString();
      final date = rawDate.length == 10 ? rawDate : '$year-${entry.key}';
      if (date.length != 10) continue;
      rows.add(HolidayEntry(
        date: date,
        year: int.tryParse(date.substring(0, 4)) ?? year,
        isHoliday: raw['holiday'] == true,
        name: (raw['name'] ?? '').toString(),
        fetchedAt: fetchedAt,
      ));
    }
    rows.sort((a, b) => a.date.compareTo(b.date));
    return rows;
  }

  /// 预置节假日（无网络 / 首装冷启动时日历仍可正确标注的兜底表）。
  ///
  /// 来源：timor.tech `/api/holiday/year/{y}` 实测数据（2026-09 快照，与国务院
  /// 办公厅发布的安排一致，国办发明电〔2025〕10 号）。放假日与调休补班日都
  /// 收录（补班日影响周末展示）。线上数据更新后由拉取整年替换；本表在
  /// [loadAll] 中只对「DB 未覆盖的年份」按年兜底。
  static List<HolidayEntry> builtinHolidays() => [
        for (final (date, isHoliday, name) in _builtinRows)
          HolidayEntry(
            date: date,
            year: int.parse(date.substring(0, 4)),
            isHoliday: isHoliday,
            name: name,
            fetchedAt: _builtinFetchedAt,
          ),
      ];

  /// 预置节假日按 date 索引（查询兜底）。
  static Map<String, HolidayEntry> builtinHolidayByDate() => {
        for (final h in builtinHolidays()) h.date: h,
      };

  static const List<(String, bool, String)> _builtinRows = [
    // 2026 年（国办发明电〔2025〕10 号）
    ('2026-01-01', true, '元旦'),
    ('2026-01-02', true, '元旦'),
    ('2026-01-03', true, '元旦'),
    ('2026-01-04', false, '元旦后补班'),
    ('2026-02-14', false, '春节前补班'),
    ('2026-02-15', true, '春节'),
    ('2026-02-16', true, '除夕'),
    ('2026-02-17', true, '初一'),
    ('2026-02-18', true, '初二'),
    ('2026-02-19', true, '初三'),
    ('2026-02-20', true, '初四'),
    ('2026-02-21', true, '初五'),
    ('2026-02-22', true, '初六'),
    ('2026-02-23', true, '初七'),
    ('2026-02-28', false, '春节后补班'),
    ('2026-04-04', true, '清明节'),
    ('2026-04-05', true, '清明节'),
    ('2026-04-06', true, '清明节'),
    ('2026-05-01', true, '劳动节'),
    ('2026-05-02', true, '劳动节'),
    ('2026-05-03', true, '劳动节'),
    ('2026-05-04', true, '劳动节'),
    ('2026-05-05', true, '劳动节'),
    ('2026-05-09', false, '劳动节后补班'),
    ('2026-06-19', true, '端午节'),
    ('2026-06-20', true, '端午节'),
    ('2026-06-21', true, '端午节'),
    ('2026-09-20', false, '中秋节前补班'),
    ('2026-09-25', true, '中秋节'),
    ('2026-09-26', true, '中秋节'),
    ('2026-09-27', true, '中秋节'),
    ('2026-10-01', true, '国庆节'),
    ('2026-10-02', true, '国庆节'),
    ('2026-10-03', true, '国庆节'),
    ('2026-10-04', true, '中秋节'),
    ('2026-10-05', true, '国庆节'),
    ('2026-10-06', true, '国庆节'),
    ('2026-10-07', true, '国庆节'),
    ('2026-10-08', true, '国庆节'),
    ('2026-10-10', false, '国庆节后补班'),
  ];

  // ==========================================================================
  // 读
  // ==========================================================================

  /// 全部缓存行（date 升序）。**按年合并**（AC-E5）：DB 已缓存的年份完全
  /// 以 DB 为准；预置表只兜底「DB 未覆盖的年份」。
  ///
  /// 不按「整表非空」判定——否则补写任一历史年份（如 2022）就会让 2026
  /// 预置徽标整体消失。合并结果只是**读时视图，不回写 DB**，DB 始终保持
  /// 用户实际拉取的内容（避免预置表灌库造成概览条数虚高）。
  Future<List<HolidayEntry>> loadAll() async {
    final rows = await _repo.getAll();
    if (rows.isEmpty) return builtinHolidays();
    final cachedYears = rows.map((r) => r.year).toSet();
    final fallback =
        builtinHolidays().where((r) => !cachedYears.contains(r.year));
    final merged = [...rows, ...fallback]
      ..sort((a, b) => a.date.compareTo(b.date));
    return merged;
  }

  Future<HolidayUpdateMetaData> getMeta() => _repo.getMeta();

  /// 切换「每月自动更新」开关。
  Future<void> setAutoEnabled(bool enabled) async {
    final meta = await _repo.getMeta();
    await _repo.saveMeta(meta.copyWith(autoEnabled: enabled));
  }

  // ==========================================================================
  // 写（网络拉取 + 整年替换）
  // ==========================================================================

  /// 手动更新：强制拉取（无视每月记账）。失败抛 [HolidayFetchException]，
  /// 旧缓存保留、失败计数 +1。
  Future<HolidayUpdateMetaData> updateNow({bool force = true}) =>
      _update(force: force, now: DateTime.now());

  /// 按年联网补写（设置页「按年份获取」/「更新该年」入口，AC-E1）。
  ///
  /// 与 [updateNow] 同源的整年替换语义，差异只在**记账口径**（AC-E6）：
  /// 只有所补年份属于 [yearsToFetch]（今年，或 12 月的明年）时才写
  /// [HolidayUpdateMetaData.lastUpdateMs]；补历史年份只写 `lastAttemptMs`，
  /// 否则会把本月本该发生的每月自动更新误判为「本月已成功」而跳过。
  ///
  /// 空响应（该年 `holiday == {}`）按成功处理：该年替换为空集（清掉旧数据），
  /// 不抛错也不记失败（AC-E7）。失败抛 [HolidayFetchException]，旧缓存保留。
  ///
  /// 返回「更新记账 + 该年实际返回行数」记录：`rowCount == 0` 即该年线上
  /// 无数据，供 UI 提示「该年无数据」（AC-E7）。
  Future<({HolidayUpdateMetaData meta, int rowCount})> fetchYear(
    int year,
  ) async {
    final now = DateTime.now();
    var meta = await _repo.getMeta();
    final attemptMs = now.millisecondsSinceEpoch;
    await _repo.saveMeta(meta.copyWith(lastAttemptMs: attemptMs));
    try {
      final rows = await _fetchYearRows(year);
      await _repo.replaceYear(year, rows);
      final successMs = DateTime.now().millisecondsSinceEpoch;
      // 历史年份不在自动更新范围内 → 保持 lastUpdateMs 不变（不抑制本月自动更新）
      final inAutoScope = yearsToFetch(now).contains(year);
      meta = meta.copyWith(
        lastUpdateMs: inAutoScope ? successMs : meta.lastUpdateMs,
        lastAttemptMs: successMs,
        failureCount: 0,
      );
      await _repo.saveMeta(meta);
      logger.info('Holiday',
          '按年获取成功 year=$year rows=${rows.length} autoScope=$inAutoScope');
      return (meta: meta, rowCount: rows.length);
    } catch (e) {
      await _repo.saveMeta(meta.copyWith(
        lastAttemptMs: attemptMs,
        failureCount: meta.failureCount + 1,
      ));
      logger.warning('Holiday', '按年获取失败 year=$year（旧缓存保留）: $e');
      rethrow;
    }
  }

  /// 按年份范围联网补写（设置页「按年份范围获取」入口）。
  ///
  /// 两阶段流水线（2026-09-30 修订——修「选 2000-2017 全部失败」又慢又
  /// 看不出原因：此前逐年串行，一次断网要把每年都等到 20s 超时）：
  /// 1. **分片并发拉取**：按 [concurrency] 分片 `Future.wait`，只做网络 +
  ///    解析，不写库（drift 同连接并发事务不安全，落库统一放阶段 2 串行）；
  /// 2. **串行落库**：按年份升序逐个整年替换（语义与 [fetchYear] 一致）。
  ///
  /// **单年失败不中止**：跳过该年继续拉后续年份（2026-09-29 修订）。
  /// 但**连续失败达 [_rangeAbortAfter] 次即熔断**：网络已断时不再把剩余
  /// 年份逐个等到超时，未尝试的年份同样计入 `failedYears`（[aborted] 置
  /// true，`firstError` 留首个异常供 UI 报原因）。
  ///
  /// 记账一次写完：整次范围操作只对 `failureCount` +1（此前逐年各自 +1，
  /// 一次 18 年全失败会刷出「连续失败 18 次」），全成功则清零；
  /// `lastUpdateMs` 口径与 [fetchYear] 一致（范围内有自动更新年份成功才写）。
  /// 取消（[shouldCancel]）且颗粒无收时记账原样恢复，不污染失败计数；
  /// 未尝试的年份不计入 `failedYears`，已完成的保留。
  ///
  /// 返回：`updated` = 有数据的年份数；`noData` = 线上无数据的年份数；
  /// `failedYears` = 获取失败的年份（升序）；`firstError` = 首个异常原文；
  /// `aborted` = 是否触发熔断；`cancelled` = 是否被中途取消。
  Future<
      ({
        int updated,
        int noData,
        List<int> failedYears,
        Object? firstError,
        bool aborted,
        bool cancelled,
      })> fetchYearRange(
    int startYear,
    int endYear, {
    int concurrency = _rangeConcurrency,
    void Function(int done, int total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final years = [for (var y = startYear; y <= endYear; y++) y];
    final total = years.length;
    final now = DateTime.now();
    final before = await _repo.getMeta();
    final attemptMs = now.millisecondsSinceEpoch;
    await _repo.saveMeta(before.copyWith(lastAttemptMs: attemptMs));

    var doneCount = 0;
    void emitProgress() => onProgress?.call(doneCount, total);

    // 阶段 1：分片并发拉取（只网络 + 解析，不写库）。
    final fetched = <int, List<HolidayEntry>>{};
    final failedYears = <int>[];
    Object? firstError;
    var aborted = false;
    var cancelled = false;
    var streak = 0;

    outer:
    for (var i = 0; i < years.length; i += concurrency) {
      if (shouldCancel?.call() == true) {
        cancelled = true;
        break;
      }
      final chunkEnd =
          (i + concurrency < years.length) ? i + concurrency : years.length;
      final chunk = years.sublist(i, chunkEnd);
      final results = await Future.wait(
        chunk
            .map<Future<({int year, List<HolidayEntry>? rows, Object? error})>>(
                (year) async {
          try {
            final rows = await _fetchYearRows(year,
                perYearTimeout: _rangePerYearTimeout);
            return (year: year, rows: rows, error: null);
          } catch (e) {
            return (year: year, rows: null, error: e);
          }
        }),
      );
      // 按年份升序结算：计数确定、熔断判定稳定。
      for (final r in results) {
        doneCount++;
        if (r.error == null) {
          streak = 0;
          fetched[r.year] = r.rows!;
        } else {
          firstError ??= r.error;
          streak++;
          failedYears.add(r.year);
          if (streak >= _rangeAbortAfter) {
            aborted = true;
            // 剩余未尝试的年份同样记失败（没拿到数据是事实），保持升序。
            failedYears.addAll(years.sublist(years.indexOf(r.year) + 1));
            doneCount = total;
            break outer;
          }
        }
      }
      emitProgress();
    }
    if (aborted) emitProgress();

    // 取消且颗粒无收：记账原样恢复，不污染失败计数。
    if (doneCount == 0) {
      await _repo.saveMeta(before);
      return (
        updated: 0,
        noData: 0,
        failedYears: <int>[],
        firstError: null,
        aborted: false,
        cancelled: cancelled,
      );
    }

    // 阶段 2：串行落库（整年替换语义与 fetchYear 一致）。
    var updated = 0;
    var noData = 0;
    var inScopeSuccess = false;
    final ordered = fetched.keys.toList()..sort();
    for (final year in ordered) {
      final rows = fetched[year]!;
      await _repo.replaceYear(year, rows);
      if (rows.isEmpty) {
        noData++;
      } else {
        updated++;
      }
      if (yearsToFetch(now).contains(year)) inScopeSuccess = true;
    }

    failedYears.sort();
    final successMs = DateTime.now().millisecondsSinceEpoch;
    await _repo.saveMeta(before.copyWith(
      lastUpdateMs: inScopeSuccess ? successMs : before.lastUpdateMs,
      lastAttemptMs: successMs,
      failureCount: failedYears.isEmpty ? 0 : before.failureCount + 1,
    ));
    logger.info('Holiday',
        '按范围获取完成 years=$startYear-$endYear updated=$updated noData=$noData failed=$failedYears aborted=$aborted cancelled=$cancelled');
    return (
      updated: updated,
      noData: noData,
      failedYears: failedYears,
      firstError: firstError,
      aborted: aborted,
      cancelled: cancelled,
    );
  }

  /// 调度入口：按 [shouldUpdateNow] 判定是否需要更新。
  ///
  /// 返回 true = 本次执行了更新；false = 未到条件（本月已成功 / 自动更新已关）。
  /// 网络失败不抛（调度层静默，记账已落库）。
  Future<bool> autoUpdateIfDue({DateTime? now, bool enabled = true}) async {
    final current = await _repo.getMeta();
    if (!enabled || !current.autoEnabled) return false;
    if (!shouldUpdateNow(
      lastUpdateMs: current.lastUpdateMs,
      now: now ?? DateTime.now(),
    )) {
      return false;
    }
    try {
      await _update(force: true, now: now ?? DateTime.now());
      return true;
    } catch (e) {
      logger.warning('Holiday', '自动更新失败（旧缓存保留）: $e');
      return false;
    }
  }

  Future<HolidayUpdateMetaData> _update({
    required bool force,
    required DateTime now,
  }) async {
    var meta = await _repo.getMeta();
    if (!force &&
        !shouldUpdateNow(
          lastUpdateMs: meta.lastUpdateMs,
          now: now,
        )) {
      return meta;
    }

    // 「已尝试」（成败都写）：失败后下一轮 tick / 下次启动仍按缺额重试
    final attemptMs = now.millisecondsSinceEpoch;
    await _repo.saveMeta(meta.copyWith(lastAttemptMs: attemptMs));

    try {
      final years = yearsToFetch(now);
      final fetched = <HolidayEntry>[];
      // 逐年拉取：单年失败即中止（保证「整年完整替换」而非半截数据）
      for (final y in years) {
        fetched.addAll(await _fetchYearRows(y));
      }
      // 按年替换：传整份 fetched（而非按年过滤）—— 12 月拉 [本年, 次年] 时，
      // 次年 1 月 1 日这类跨年条目会被两个年份的响应先后给出，整份传入 +
      // upsert 语义才能保证最终两个年份的行都在（与参考实现一致）。
      for (final y in years) {
        await _repo.replaceYear(y, fetched);
      }

      final successMs = DateTime.now().millisecondsSinceEpoch;
      meta = meta.copyWith(
        lastUpdateMs: successMs,
        lastAttemptMs: successMs,
        failureCount: 0,
      );
      await _repo.saveMeta(meta);
      logger.info('Holiday', '节假日更新成功 years=$years rows=${fetched.length}');
      return meta;
    } catch (e) {
      // 保留旧缓存，只累加失败计数（旧数据仍可显示）
      await _repo.saveMeta(meta.copyWith(
        lastAttemptMs: attemptMs,
        failureCount: meta.failureCount + 1,
      ));
      logger.warning('Holiday', '节假日更新失败（旧缓存保留）: $e');
      rethrow;
    }
  }

  /// 单年网络拉取 + 解析（不写库不记账；记账由调用方一次完成）。
  /// [perYearTimeout] 覆盖收发超时（范围批量场景用短超时，见
  /// [_rangePerYearTimeout]；空 = 用 [_timeout]）。
  Future<List<HolidayEntry>> _fetchYearRows(
    int year, {
    Duration? perYearTimeout,
  }) async {
    final url = '$apiBase/$year';
    final resp = await _dio.get<Map<String, dynamic>>(
      url,
      options: Options(
        headers: {
          'User-Agent': _ua,
          'Accept': 'application/json',
        },
        sendTimeout: perYearTimeout,
        receiveTimeout: perYearTimeout,
      ),
    );
    final data = resp.data;
    if (data == null) {
      throw HolidayFetchException('[$url] 空响应');
    }
    return parseYearResponse(year, data);
  }
}
