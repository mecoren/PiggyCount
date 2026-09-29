// HolidayRepository 契约（prd/calendar_holiday 决策 2/3）：
//  - replaceYear 事务整年替换：旧行删除、跨年不误删、空列表 = 只删不插
//  - getMeta 无记录返回默认值且不落库；saveMeta upsert + 单行归一
//  - 两张缓存表的写入【绝不】记 ChangeTracker（否则云端回流幻影变更、契约守门测试变红）
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/holiday_repository.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late ChangeTracker tracker;
  late LocalRepository repo;

  HolidayEntry row(String date, bool isHoliday, String name) => HolidayEntry(
        date: date,
        year: int.parse(date.substring(0, 4)),
        isHoliday: isHoliday,
        name: name,
        fetchedAt: DateTime.utc(2026, 9, 28),
      );

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    tracker = ChangeTracker(db);
    repo = LocalRepository(db, changeTracker: tracker);
  });

  tearDown(() async {
    await db.close();
  });

  test('replaceYear 整年替换：旧行清除、跨年不误删', () async {
    await repo.replaceYear(2026, [
      row('2026-02-17', true, '初一'),
      row('2026-02-28', false, '春节后补班'),
    ]);
    await repo.replaceYear(2027, [row('2027-01-01', true, '元旦')]);
    expect((await repo.getByYear(2026)).map((e) => e.date),
        ['2026-02-17', '2026-02-28']);

    // 重新拉取 2026：旧行整年替换（不是追加）
    await repo.replaceYear(2026, [row('2026-10-01', true, '国庆节')]);
    expect((await repo.getByYear(2026)).map((e) => e.date), ['2026-10-01']);
    expect((await repo.getByYear(2027)).length, 1); // 跨年不误删
    expect(await repo.getAll(), hasLength(2));
  });

  test('replaceYear 空列表 = 只删不插（次年未发布时清掉过期行）', () async {
    await repo.replaceYear(2026, [row('2026-01-01', true, '元旦')]);
    await repo.replaceYear(2026, const []);
    expect(await repo.getByYear(2026), isEmpty);
    expect(await repo.getAll(), isEmpty);
  });

  test('getByDate 命中 / 未命中；getMeta 默认值不落库', () async {
    await repo.replaceYear(2026, [row('2026-02-17', true, '初一')]);
    expect((await repo.getByDate('2026-02-17'))!.name, '初一');
    expect(await repo.getByDate('2026-03-15'), isNull);

    final meta = await repo.getMeta();
    expect(meta.id, HolidayRepository.metaRowId);
    expect(meta.lastUpdateMs, 0);
    expect(meta.lastAttemptMs, 0);
    expect(meta.failureCount, 0);
    expect(meta.autoEnabled, isTrue);
    // 读默认值不得写库（首次真正落库发生在 saveMeta）
    expect(await db.select(db.holidayUpdateMeta).get(), isEmpty);
  });

  test('saveMeta：roundtrip + 单行归一', () async {
    await repo.saveMeta(HolidayUpdateMetaData(
      id: 99, // 外部 id 一律归一到固定单行
      lastUpdateMs: 111,
      lastAttemptMs: 222,
      failureCount: 3,
      autoEnabled: false,
      updatedAt: DateTime.utc(2026, 9, 28),
    ));
    final meta = await repo.getMeta();
    expect(meta.id, HolidayRepository.metaRowId);
    expect(meta.lastUpdateMs, 111);
    expect(meta.lastAttemptMs, 222);
    expect(meta.failureCount, 3);
    expect(meta.autoEnabled, isFalse);
    expect(await db.select(db.holidayUpdateMeta).get(), hasLength(1));

    // 再次保存仍是同一行（upsert 而非追加）
    await repo.saveMeta(HolidayUpdateMetaData(
      id: HolidayRepository.metaRowId,
      lastUpdateMs: 333,
      lastAttemptMs: 333,
      failureCount: 0,
      autoEnabled: true,
      updatedAt: DateTime.utc(2026, 9, 29),
    ));
    expect(await db.select(db.holidayUpdateMeta).get(), hasLength(1));
    expect((await repo.getMeta()).lastUpdateMs, 333);
  });

  test('红线：节假日缓存写入不产生 local_changes', () async {
    await repo.replaceYear(2026, [row('2026-02-17', true, '初一')]);
    await repo.saveMeta(HolidayUpdateMetaData(
      id: HolidayRepository.metaRowId,
      lastUpdateMs: 1,
      lastAttemptMs: 1,
      failureCount: 0,
      autoEnabled: true,
      updatedAt: DateTime.utc(2026, 9, 28),
    ));
    expect(await tracker.getUnpushedChangesForLedger(0), isEmpty);
  });
}
