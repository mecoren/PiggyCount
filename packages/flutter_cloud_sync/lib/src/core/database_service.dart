/// Cloud Database Service
///
/// Abstract interface for cloud database operations (CRUD + Realtime).
/// This enables record-level synchronization instead of file-level.
library;

/// Database event types
enum DatabaseEventType {
  /// Record inserted
  insert,

  /// Record updated
  update,

  /// Record deleted
  delete,
}

/// Database event
class DatabaseEvent {
  /// Event type
  final DatabaseEventType type;

  /// Table name
  final String table;

  /// New/current record data
  final Map<String, dynamic> record;

  /// Old record data (for update/delete events)
  final Map<String, dynamic>? oldRecord;

  /// Event timestamp
  final DateTime timestamp;

  DatabaseEvent({
    required this.type,
    required this.table,
    required this.record,
    this.oldRecord,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() {
    return 'DatabaseEvent(type: $type, table: $table, record: $record)';
  }
}

/// Query filter
class QueryFilter {
  /// Column name
  final String column;

  /// Operator (eq, gt, lt, gte, lte, like, in, etc.)
  final String operator;

  /// Value
  final dynamic value;

  const QueryFilter({
    required this.column,
    required this.operator,
    required this.value,
  });

  /// Equal filter
  static QueryFilter eq(String column, dynamic value) {
    return QueryFilter(column: column, operator: 'eq', value: value);
  }

  /// Greater than filter
  static QueryFilter gt(String column, dynamic value) {
    return QueryFilter(column: column, operator: 'gt', value: value);
  }

  /// Less than filter
  static QueryFilter lt(String column, dynamic value) {
    return QueryFilter(column: column, operator: 'lt', value: value);
  }

  /// Greater than or equal filter
  static QueryFilter gte(String column, dynamic value) {
    return QueryFilter(column: column, operator: 'gte', value: value);
  }

  /// Less than or equal filter
  static QueryFilter lte(String column, dynamic value) {
    return QueryFilter(column: column, operator: 'lte', value: value);
  }

  /// Like filter (pattern matching)
  static QueryFilter like(String column, String pattern) {
    return QueryFilter(column: column, operator: 'like', value: pattern);
  }

  /// In filter (value in list)
  static QueryFilter inList(String column, List<dynamic> values) {
    return QueryFilter(column: column, operator: 'in', value: values);
  }

  @override
  String toString() {
    return 'QueryFilter($column $operator $value)';
  }
}

/// Cloud database service interface
///
/// Provides CRUD operations and realtime subscriptions for cloud databases.
///
/// Example:
/// ```dart
/// final dbService = SupabaseDatabaseProvider(client);
///
/// // Insert
/// final record = await dbService.insert(
///   table: 'transactions',
///   data: {'amount': 100, 'note': 'Test'},
/// );
///
/// // Query
/// final records = await dbService.query(
///   table: 'transactions',
///   filters: [QueryFilter.eq('user_id', userId)],
///   orderBy: 'created_at',
///   descending: true,
///   limit: 10,
/// );
///
/// // Subscribe to changes
/// dbService.subscribe(
///   table: 'transactions',
///   filters: [QueryFilter.eq('ledger_id', ledgerId)],
/// ).listen((event) {
///   print('${event.type}: ${event.record}');
/// });
/// ```
abstract class CloudDatabaseService {
  /// Insert a record
  ///
  /// Returns the inserted record (with server-generated fields like id, timestamps).
  ///
  /// - [autoInjectUserId]: 自动注入当前用户ID (默认: true)
  Future<Map<String, dynamic>> insert({
    required String table,
    required Map<String, dynamic> data,
    bool autoInjectUserId = true,
  });

  /// Update a record
  ///
  /// Uses [id] to identify the record to update.
  /// Returns the updated record.
  ///
  /// - [autoFilterByUser]: 自动添加用户过滤(防止修改其他用户数据, 默认: true)
  Future<Map<String, dynamic>> update({
    required String table,
    required String id,
    required Map<String, dynamic> data,
    bool autoFilterByUser = true,
  });

  /// Delete a record
  ///
  /// Uses [id] to identify the record to delete.
  ///
  /// - [autoFilterByUser]: 自动添加用户过滤(防止删除其他用户数据, 默认: true)
  Future<void> delete({
    required String table,
    required String id,
    bool autoFilterByUser = true,
  });

  /// Query records
  ///
  /// - [filters]: List of query filters (AND logic)
  /// - [orderBy]: Column to sort by
  /// - [descending]: Sort descending (default: false)
  /// - [limit]: Maximum number of records to return
  /// - [offset]: Number of records to skip
  /// - [autoFilterByUser]: 自动添加用户过滤(默认: true)
  Future<List<Map<String, dynamic>>> query({
    required String table,
    List<QueryFilter>? filters,
    String? orderBy,
    bool descending = false,
    int? limit,
    int? offset,
    bool autoFilterByUser = true,
  });

  /// Get a single record by ID
  ///
  /// Returns null if not found.
  Future<Map<String, dynamic>?> getById({
    required String table,
    required String id,
  });

  /// Subscribe to table changes (Realtime)
  ///
  /// Returns a stream of database events.
  /// The stream emits events when records are inserted, updated, or deleted.
  ///
  /// - [filters]: Filter which events to receive
  /// - [event]: Filter by event type (insert/update/delete), '*' for all
  Stream<DatabaseEvent> subscribe({
    required String table,
    List<QueryFilter>? filters,
    String event = '*',
  });

  /// Batch insert multiple records
  ///
  /// Returns the inserted records.
  ///
  /// - [autoInjectUserId]: 自动注入当前用户ID (默认: true)
  Future<List<Map<String, dynamic>>> batchInsert({
    required String table,
    required List<Map<String, dynamic>> data,
    bool autoInjectUserId = true,
  });

  /// Batch update multiple records
  ///
  /// Uses [idField] to identify records (default: 'id').
  /// Each data map should contain the id field.
  ///
  /// - [autoFilterByUser]: 自动添加用户过滤(防止修改其他用户数据, 默认: true)
  Future<void> batchUpdate({
    required String table,
    required List<Map<String, dynamic>> data,
    String idField = 'id',
    bool autoFilterByUser = true,
  });

  /// Batch delete multiple records
  ///
  /// Deletes all records matching the filters.
  Future<void> batchDelete({
    required String table,
    required List<QueryFilter> filters,
  });

  /// Execute a predefined RPC by name (provider-specific)
  ///
  /// 仅允许调用预定义的数据库函数（RPC），禁止传入原始 SQL 文本，
  /// 以避免 SQL 注入风险。调用前需在 Supabase 后端创建对应的 RPC 函数，
  /// 并通过 [params] 传递命名参数。
  ///
  /// - [queryName]: 预定义 RPC 函数名
  /// - [params]: 传给 RPC 的命名参数
  Future<List<Map<String, dynamic>>> rawQuery(
    String queryName, {
    Map<String, dynamic>? params,
  });
}
