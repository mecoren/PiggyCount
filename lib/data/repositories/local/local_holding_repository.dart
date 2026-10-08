import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../../../services/system/logger_service.dart';
import '../holding_repository.dart';

/// 本地持仓 Repository 实现（v52）。
///
/// 与 [LocalAccountRepository] 同款分工：本类只做**裸 Drift 读写**，不持有
/// ChangeTracker —— 变更登记由聚合层 `LocalRepository` 在事务里统一完成
/// （见 `lib/data/repositories/local/local_repository.dart` 的持仓段）。
/// 这样「写表 + 记 change 同事务」这条纪律只有一个落点，不会两头漂移。
class LocalHoldingRepository implements HoldingRepository {
  static const _uuid = Uuid();
  final PiggyDatabase db;

  LocalHoldingRepository(this.db);

  /// 账户内展示顺序：先 sortOrder、再 id（同 sortOrder 时仍保证全序 ——
  /// 快照导出与指纹依赖它跨设备可比）。
  d.OrderingTerm _bySortOrder($HoldingsTable h) =>
      d.OrderingTerm(expression: h.sortOrder);

  d.OrderingTerm _byId($HoldingsTable h) =>
      d.OrderingTerm(expression: h.id);

  @override
  Stream<List<Holding>> watchHoldingsByAccount(int accountId) {
    return (db.select(db.holdings)
          ..where((h) => h.accountId.equals(accountId))
          ..orderBy([_bySortOrder, _byId]))
        .watch();
  }

  @override
  Future<List<Holding>> getHoldingsByAccount(int accountId) {
    return (db.select(db.holdings)
          ..where((h) => h.accountId.equals(accountId))
          ..orderBy([_bySortOrder, _byId]))
        .get();
  }

  @override
  Future<List<Holding>> getAllHoldings() {
    // 按 id 稳定排序：快照导出与指纹必须跨设备可比（同账户导出的口径）。
    return (db.select(db.holdings)..orderBy([_byId])).get();
  }

  @override
  Future<Holding?> getHolding(int id) {
    return (db.select(db.holdings)..where((h) => h.id.equals(id)))
        .getSingleOrNull();
  }

  @override
  Future<bool> hasHoldings(int accountId) async {
    final row = await db
        .customSelect(
          'SELECT 1 FROM holdings WHERE account_id = ?1 LIMIT 1',
          variables: [d.Variable.withInt(accountId)],
          readsFrom: {db.holdings},
        )
        .getSingleOrNull();
    return row != null;
  }

  @override
  Future<Set<int>> getAccountIdsWithHoldings() async {
    final rows = await db
        .customSelect(
          'SELECT DISTINCT account_id FROM holdings',
          readsFrom: {db.holdings},
        )
        .get();
    return rows.map((r) => r.read<int>('account_id')).toSet();
  }

  @override
  Future<int> createHolding({
    required int accountId,
    required String name,
    required String currency,
    String? symbol,
    String? market,
    String assetClass = 'other',
    double quantity = 0.0,
    double unitCost = 0.0,
    double unitPrice = 0.0,
    bool autoQuote = false,
    String? note,
    int? sortOrder,
    String? syncId,
  }) async {
    try {
      // 未指定排序时追加到该账户末尾（与 createAccount 的同类型 max+1 同款）。
      var order = sortOrder;
      if (order == null) {
        final row = await db.customSelect(
          'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM holdings '
          'WHERE account_id = ?1',
          variables: [d.Variable.withInt(accountId)],
          readsFrom: {db.holdings},
        ).getSingle();
        order = (row.data['max_order'] as int) + 1;
      }

      final id = await db.into(db.holdings).insert(
            HoldingsCompanion.insert(
              accountId: accountId,
              name: name,
              currency: d.Value(currency),
              symbol: d.Value(symbol),
              market: d.Value(market),
              assetClass: d.Value(assetClass),
              quantity: d.Value(quantity),
              unitCost: d.Value(unitCost),
              unitPrice: d.Value(unitPrice),
              autoQuote: d.Value(autoQuote),
              note: d.Value(note),
              sortOrder: d.Value(order),
              syncId: d.Value(syncId ?? _uuid.v4()),
              createdAt: d.Value(DateTime.now()),
              updatedAt: d.Value(DateTime.now()),
            ),
          );
      logger.debug('HoldingCreate',
          '持仓创建: id=$id account=$accountId name=$name currency=$currency');
      return id;
    } catch (e, stack) {
      logger.error('HoldingCreate', '创建持仓失败 name=$name', e, stack);
      rethrow;
    }
  }

  @override
  Future<void> updateHolding(
    int id, {
    String? name,
    String? symbol,
    String? market,
    String? assetClass,
    String? currency,
    double? quantity,
    double? unitCost,
    double? unitPrice,
    bool? autoQuote,
    String? note,
    int? sortOrder,
    bool clearOptionalFields = false,
    String? syncId,
  }) {
    return (db.update(db.holdings)..where((h) => h.id.equals(id))).write(
      HoldingsCompanion(
        name: name != null ? d.Value(name) : const d.Value.absent(),
        symbol: clearOptionalFields
            ? const d.Value(null)
            : (symbol != null ? d.Value(symbol) : const d.Value.absent()),
        market: clearOptionalFields
            ? const d.Value(null)
            : (market != null ? d.Value(market) : const d.Value.absent()),
        note: clearOptionalFields
            ? const d.Value(null)
            : (note != null ? d.Value(note) : const d.Value.absent()),
        assetClass:
            assetClass != null ? d.Value(assetClass) : const d.Value.absent(),
        currency: currency != null ? d.Value(currency) : const d.Value.absent(),
        quantity: quantity != null ? d.Value(quantity) : const d.Value.absent(),
        unitCost: unitCost != null ? d.Value(unitCost) : const d.Value.absent(),
        unitPrice:
            unitPrice != null ? d.Value(unitPrice) : const d.Value.absent(),
        autoQuote:
            autoQuote != null ? d.Value(autoQuote) : const d.Value.absent(),
        sortOrder: sortOrder != null ? d.Value(sortOrder) : const d.Value.absent(),
        // 仅回填、不清空（老行恢复快照时收敛跨设备身份）
        syncId: syncId != null ? d.Value(syncId) : const d.Value.absent(),
        updatedAt: d.Value(DateTime.now()),
      ),
    );
  }

  @override
  Future<void> deleteHolding(int id) {
    return (db.delete(db.holdings)..where((h) => h.id.equals(id))).go();
  }

  @override
  Future<int> deleteHoldingsByAccount(int accountId) async {
    final count = await (db.delete(db.holdings)
          ..where((h) => h.accountId.equals(accountId)))
        .go();
    if (count > 0) {
      logger.debug('HoldingDelete', '级联删除账户 $accountId 的 $count 条持仓');
    }
    return count;
  }

  @override
  Future<void> updateHoldingSortOrders(
      List<({int id, int sortOrder})> updates) async {
    // 与 updateAccountSortOrders 同款：逐条 UPDATE，走 updated_at 触碰触发器。
    await db.batch((b) {
      for (final u in updates) {
        b.update(
          db.holdings,
          HoldingsCompanion(sortOrder: d.Value(u.sortOrder)),
          where: (h) => h.id.equals(u.id),
        );
      }
    });
  }

  @override
  Future<void> writeQuoteCache(
    int id, {
    double? price,
    DateTime? fetchedAt,
    String? sourceId,
  }) {
    // ⚠️ 本地专有列：这里**刻意不碰** unitPrice / updatedAt 之外的任何可同步
    // 字段，也不登记 local_changes（由聚合层保证不记）。行情刷新必须对同步
    // 完全不可见 —— 否则每次刷新都产生上传噪声并污染跨设备指纹。
    return (db.update(db.holdings)..where((h) => h.id.equals(id))).write(
      HoldingsCompanion(
        quotePrice: price != null ? d.Value(price) : const d.Value.absent(),
        quoteFetchedAt:
            fetchedAt != null ? d.Value(fetchedAt) : const d.Value.absent(),
        quoteSourceId:
            sourceId != null ? d.Value(sourceId) : const d.Value.absent(),
      ),
    );
  }

  @override
  Future<int> clearQuoteCache({String? sourceId}) {
    final query = db.update(db.holdings);
    if (sourceId != null) {
      query.where((h) => h.quoteSourceId.equals(sourceId));
    }
    return query.write(
      const HoldingsCompanion(
        quotePrice: d.Value(null),
        quoteFetchedAt: d.Value(null),
        quoteSourceId: d.Value(null),
      ),
    );
  }
}
