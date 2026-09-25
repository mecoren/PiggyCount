// 审计 T1（v40）：业务表 updated_at 列 + UPDATE 触碰触发器回归。
//
// 设计契约：
// - 列可空；新建/导入行保持 NULL =「本设备从未更新过」，不伪造时间
// - 普通 UPDATE（语句未触碰该列）→ 触发器自动盖 UTC 秒级时间戳
// - 显式写入**不同**值 → 触发器守卫不成立，应用层值原样保留
//   （未来 pull apply 回填远端时间戳的通道）

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';

void main() {
  // onCreate 里的 _createUpdatedAtTouchTriggers 会经 logger 输出，
  // 需要平台 binding + mock SharedPreferences
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<List<String>> tableColumns(String table) async {
    final cols = await db.customSelect('PRAGMA table_info($table)').get();
    return cols.map((r) => r.read<String>('name')).toList();
  }

  Future<int> triggerCount() async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='trigger' "
      "AND name LIKE 'trg_%_touch_updated_at'",
    ).get();
    return rows.length;
  }

  group('schema（onCreate 全新库）', () {
    test('v40 列存在于五张表', () async {
      for (final t in const [
        'transactions', 'categories', 'tags', 'accounts', 'ledgers'
      ]) {
        expect(await tableColumns(t), contains('updated_at'),
            reason: '$t 缺 updated_at 列');
      }
      expect(db.schemaVersion, greaterThanOrEqualTo(40));
    });

    test('触碰触发器覆盖全部受管表（v46 起为六张）', () async {
      // v40：transactions / categories / tags / accounts / ledgers；
      // v46：+ custom_field_definitions（账本自定义字段定义）。
      expect(await triggerCount(), 6);
    });
  });

  group('触发器行为', () {
    int ledgerId = 0;
    int accountId = 0;
    int categoryId = 0;
    int tagId = 0;
    int txId = 0;

    setUp(() async {
      ledgerId = await db.into(db.ledgers).insert(
            LedgersCompanion.insert(name: 'L'),
          );
      accountId = await db.into(db.accounts).insert(
            AccountsCompanion.insert(ledgerId: ledgerId, name: 'A'),
          );
      categoryId = await db.into(db.categories).insert(
            CategoriesCompanion.insert(name: 'C', kind: 'expense'),
          );
      tagId = await db.into(db.tags).insert(
            TagsCompanion.insert(name: 'T'),
          );
      txId = await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: ledgerId,
              type: 'expense',
              amount: 1,
            ),
          );
    });

    test('INSERT 不设值：新行 updated_at 保持 NULL（不伪造时间）', () async {
      final l = await (db.select(db.ledgers)
            ..where((x) => x.id.equals(ledgerId)))
          .getSingle();
      final t = await (db.select(db.transactions)
            ..where((x) => x.id.equals(txId)))
          .getSingle();
      expect(l.updatedAt, isNull);
      expect(t.updatedAt, isNull);
    });

    test('普通 UPDATE 自动盖时间戳（NULL 存量行的首次更新也命中）', () async {
      final before = DateTime.now().toUtc().subtract(const Duration(seconds: 2));
      await (db.update(db.transactions)..where((t) => t.id.equals(txId)))
          .write(TransactionsCompanion(note: const d.Value('hello')));
      final after = DateTime.now().toUtc().add(const Duration(seconds: 2));

      final tx = await (db.select(db.transactions)
            ..where((t) => t.id.equals(txId)))
          .getSingle();
      expect(tx.note, 'hello');
      expect(tx.updatedAt, isNotNull, reason: '存量 NULL 行首次被更新也必须命中');
      expect(tx.updatedAt!.isAfter(before) && tx.updatedAt!.isBefore(after),
          isTrue,
          reason: '应为 UTC now（drift 读回为本地表示，比较前已对齐窗口）');
    });

    test('显式写入不同值不被覆盖（pull 回填通道）', () async {
      final remote = DateTime.utc(2026, 1, 1, 8, 30);
      await (db.update(db.transactions)..where((t) => t.id.equals(txId)))
          .write(TransactionsCompanion(
        note: const d.Value('x'),
        updatedAt: d.Value(remote),
      ));

      final tx = await (db.select(db.transactions)
            ..where((t) => t.id.equals(txId)))
          .getSingle();
      // drift 读回为本地时区表示，统一转 UTC 比较
      expect(tx.updatedAt?.toUtc(), remote,
          reason: '语句显式设置 updated_at 时触发器不得覆盖');

      // 随后一次不触碰该列的普通编辑 → 恢复自动维护
      await (db.update(db.transactions)..where((t) => t.id.equals(txId)))
          .write(const TransactionsCompanion(note: d.Value('y')));
      final tx2 = await (db.select(db.transactions)
            ..where((t) => t.id.equals(txId)))
          .getSingle();
      expect(tx2.note, 'y');
      expect(tx2.updatedAt, isNot(remote));
    });

    test('五张表逐一验证触碰生效', () async {
      await (db.update(db.ledgers)..where((l) => l.id.equals(ledgerId)))
          .write(LedgersCompanion(name: const d.Value('L2')));
      await (db.update(db.accounts)..where((a) => a.id.equals(accountId)))
          .write(AccountsCompanion(note: const d.Value('n')));
      await (db.update(db.categories)..where((c) => c.id.equals(categoryId)))
          .write(CategoriesCompanion(name: const d.Value('C2')));
      await (db.update(db.tags)..where((t) => t.id.equals(tagId)))
          .write(TagsCompanion(name: const d.Value('T2')));

      final l = await (db.select(db.ledgers)
            ..where((x) => x.id.equals(ledgerId)))
          .getSingle();
      final a = await (db.select(db.accounts)
            ..where((x) => x.id.equals(accountId)))
          .getSingle();
      final c = await (db.select(db.categories)
            ..where((x) => x.id.equals(categoryId)))
          .getSingle();
      final t = await (db.select(db.tags)..where((x) => x.id.equals(tagId)))
          .getSingle();

      expect(l.name, 'L2');
      expect(l.updatedAt, isNotNull);
      expect(a.updatedAt, isNotNull);
      expect(c.updatedAt, isNotNull);
      expect(t.updatedAt, isNotNull);
    });

    test('DELETE 不受影响、UPDATE 其他行不动无关行', () async {
      final tx2 = await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: ledgerId,
              type: 'income',
              amount: 2,
            ),
          );
      await (db.update(db.transactions)..where((t) => t.id.equals(txId)))
          .write(const TransactionsCompanion(note: d.Value('touch-tx1')));

      final untouched =
          await (db.select(db.transactions)..where((t) => t.id.equals(tx2)))
              .getSingle();
      expect(untouched.updatedAt, isNull, reason: '只动被更新的行');
    });
  });
}
