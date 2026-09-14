library;

import 'dart:developer' as dev;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// Supabase implementation of [CloudDatabaseService].
///
/// Provides CRUD operations and realtime subscriptions for Supabase PostgreSQL database.
///
/// Example:
/// ```dart
/// final client = supabase.Supabase.instance.client;
/// final dbService = SupabaseDatabaseService(client);
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
/// );
/// ```
class SupabaseDatabaseService implements CloudDatabaseService {
  final supabase.SupabaseClient _client;

  SupabaseDatabaseService(this._client);

  @override
  Future<Map<String, dynamic>> insert({
    required String table,
    required Map<String, dynamic> data,
    bool autoInjectUserId = true,
  }) async {
    try {
      // Check authentication
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // 自动注入 user_id（审计 S20：强制覆盖而非仅补缺——
      // 调用方自带伪造 user_id 可把记录写到他人名下）
      final insertData = Map<String, dynamic>.from(data);
      if (autoInjectUserId) {
        insertData['user_id'] = user.id;
      }

      // Insert and return the created record
      final response = await _client
          .from(table)
          .insert(insertData)
          .select()
          .single();

      return response;
    } on supabase.PostgrestException catch (e) {
      throw CloudStorageException('Insert failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Insert failed: $e', e);
    }
  }

  @override
  Future<Map<String, dynamic>> update({
    required String table,
    required String id,
    required Map<String, dynamic> data,
    bool autoFilterByUser = true,
  }) async {
    try {
      // Check authentication
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // Build query
      var query = _client
          .from(table)
          .update(data)
          .eq('id', id);

      // 自动添加用户过滤
      if (autoFilterByUser) {
        query = query.eq('user_id', user.id);
      }

      // Update and return the updated record
      final response = await query.select().single();

      return response;
    } on supabase.PostgrestException catch (e) {
      throw CloudStorageException('Update failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Update failed: $e', e);
    }
  }

  @override
  Future<void> delete({
    required String table,
    required String id,
    bool autoFilterByUser = true,
  }) async {
    try {
      // Check authentication
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // Build query
      var query = _client
          .from(table)
          .delete()
          .eq('id', id);

      // 自动添加用户过滤
      if (autoFilterByUser) {
        query = query.eq('user_id', user.id);
      }

      // Delete record
      await query;
    } on supabase.PostgrestException catch (e) {
      throw CloudStorageException('Delete failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Delete failed: $e', e);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> query({
    required String table,
    List<QueryFilter>? filters,
    String? orderBy,
    bool descending = false,
    int? limit,
    int? offset,
    bool autoFilterByUser = true,
  }) async {
    try {
      // Check authentication
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // Build query
      dynamic query = _client.from(table).select();

      // 自动添加用户过滤
      if (autoFilterByUser) {
        query = query.eq('user_id', user.id);
      }

      // Apply filters
      if (filters != null) {
        for (final filter in filters) {
          query = _applyFilter(query, filter);
        }
      }

      // Apply ordering
      if (orderBy != null) {
        query = query.order(orderBy, ascending: !descending);
      }

      // Apply pagination（P-M6）：当 offset != null 时统一用 range，
      // 不再叠加 limit（避免 limit + range 双重分页导致返回行数不符预期）
      if (offset != null) {
        final effectiveLimit = limit ?? 1000;
        query = query.range(offset, offset + effectiveLimit - 1);
      } else if (limit != null) {
        query = query.limit(limit);
      }

      // Execute query
      final response = await query;

      // SUP-D2（2026-09-12 P1）：防御式转换——服务端返回非 List 形态
      // （RLS 策略改写/视图/标量）时 `as List` 抛 TypeError（Error 类，
      // 穿透 catch (Exception) 边界），改走可捕获的 CloudStorageException
      if (response is! List) {
        throw CloudStorageException(
            'Query failed: unexpected response type '
            '${response.runtimeType} (expected List)');
      }
      return List<Map<String, dynamic>>.from(response);
    } on supabase.PostgrestException catch (e) {
      throw CloudStorageException('Query failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Query failed: $e', e);
    }
  }

  @override
  Future<Map<String, dynamic>?> getById({
    required String table,
    required String id,
  }) async {
    try {
      // Check authentication
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // 审计 S20：与 update/delete/query 一致补上 user_id 过滤——
      // getById 是唯一无过滤的读路径，服务端 RLS 缺失时可跨用户读取。
      final response = await _client
          .from(table)
          .select()
          .eq('id', id)
          .eq('user_id', user.id)
          .maybeSingle();

      return response;
    } on supabase.PostgrestException catch (e) {
      throw CloudStorageException('Get by ID failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Get by ID failed: $e', e);
    }
  }

  @override
  Stream<DatabaseEvent> subscribe({
    required String table,
    List<QueryFilter>? filters,
    String event = '*',
  }) {
    // Note: Realtime subscriptions should be handled by SupabaseRealtimeService
    // This method is kept for interface compatibility but delegates to realtime service
    //
    // SUP-D1（2026-09-12 P1）：原实现裸抛 UnimplementedError（Error 而非
    // Exception），会穿透调用方 `catch (Exception)` 的异常边界直达 zone
    // 顶层。改抛 CloudConfigurationException（包契约异常）：当前 App 无
    // 消费方（realtime 走 SupabaseRealtimeService），但任何未来调用方
    // 都应得到可捕获、可归类的配置类异常而非进程级 Error。
    throw CloudConfigurationException(
      'SupabaseDatabaseService does not support subscribe; '
      'use SupabaseRealtimeService for realtime subscriptions',
    );
  }

  @override
  Future<List<Map<String, dynamic>>> batchInsert({
    required String table,
    required List<Map<String, dynamic>> data,
    bool autoInjectUserId = true,
  }) async {
    try {
      // Check authentication
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // 自动注入 user_id（复用 insert 的注入逻辑，P-M2；审计 S20：强制覆盖）
      final payload = autoInjectUserId
          ? data.map((r) {
              final c = Map<String, dynamic>.from(r);
              c['user_id'] = user.id;
              return c;
            }).toList()
          : data;

      // Batch insert
      final response = await _client.from(table).insert(payload).select();

      return List<Map<String, dynamic>>.from(response as List);
    } on supabase.PostgrestException catch (e) {
      throw CloudStorageException('Batch insert failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Batch insert failed: $e', e);
    }
  }

  @override
  Future<void> batchUpdate({
    required String table,
    required List<Map<String, dynamic>> data,
    String idField = 'id',
    bool autoFilterByUser = true,
  }) async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw CloudNotAuthenticatedException('User not authenticated');
    }

    // 预校验所有记录的 idField 不为 null，避免半途失败留下脏状态（C6）
    for (final record in data) {
      if (record[idField] == null) {
        throw CloudStorageException('Record missing $idField field');
      }
    }

    try {
      // 优先尝试 RPC 事务保证原子性：所有记录要么全部更新成功，要么全部回滚。
      // 需在 Supabase 后端预先创建 batch_update_records RPC 函数。
      await _client.rpc('batch_update_records', params: {
        'p_table': table,
        'p_id_field': idField,
        'p_user_id': autoFilterByUser ? user.id : null,
        'p_records': data,
      });
    } on supabase.PostgrestException catch (e) {
      // RPC 不存在或不可用时回退到逐条更新，并记录 warning 便于排查（C6）。
      // 回退路径无法保证原子性，但保持原有行为兼容。
      dev.log(
        '[Supabase] batchUpdate RPC unavailable, fallback to loop: ${e.message}',
        name: 'SupabaseDatabase',
        level: 900,
      );
      for (final record in data) {
        var query =
            _client.from(table).update(record).eq(idField, record[idField]);
        if (autoFilterByUser) {
          query = query.eq('user_id', user.id);
        }
        await query;
      }
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Batch update failed: $e', e);
    }
  }

  @override
  Future<void> batchDelete({
    required String table,
    required List<QueryFilter> filters,
    bool autoFilterByUser = true,
  }) async {
    try {
      // Check authentication
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // Build delete query with filters
      var query = _client.from(table).delete();

      // P2-8：自动添加用户过滤，与 delete()/batchUpdate() 保持一致，
      // 防止 filters 未含 user_id 时误删其他用户的记录（跨用户越权删除）。
      if (autoFilterByUser) {
        query = query.eq('user_id', user.id);
      }

      for (final filter in filters) {
        query = _applyFilter(query, filter);
      }

      await query;
    } on supabase.PostgrestException catch (e) {
      throw CloudStorageException('Batch delete failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Batch delete failed: $e', e);
    }
  }

  @override
  Future<List<Map<String, dynamic>>> rawQuery(
    String queryName, {
    Map<String, dynamic>? params,
  }) async {
    try {
      // Check authentication
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // 仅允许调用预定义 RPC 函数，禁止传入原始 SQL 文本（C7 防 SQL 注入）。
      // 调用前需在 Supabase 后端创建名为 [queryName] 的 RPC 函数。
      final response =
          await _client.rpc(queryName, params: params ?? <String, dynamic>{});

      return List<Map<String, dynamic>>.from(response as List);
    } on supabase.PostgrestException catch (e) {
      throw CloudStorageException('Raw query failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Raw query failed: $e', e);
    }
  }

  /// Apply filter to query
  dynamic _applyFilter(dynamic query, QueryFilter filter) {
    switch (filter.operator) {
      case 'eq':
        return query.eq(filter.column, filter.value);
      case 'neq':
        return query.neq(filter.column, filter.value);
      case 'gt':
        return query.gt(filter.column, filter.value);
      case 'gte':
        return query.gte(filter.column, filter.value);
      case 'lt':
        return query.lt(filter.column, filter.value);
      case 'lte':
        return query.lte(filter.column, filter.value);
      case 'like':
        return query.like(filter.column, filter.value);
      case 'ilike':
        return query.ilike(filter.column, filter.value);
      case 'in':
        return query.inFilter(filter.column, filter.value as List);
      case 'is':
        return query.isFilter(filter.column, filter.value);
      case 'contains':
        return query.contains(filter.column, filter.value);
      case 'containedBy':
        return query.containedBy(filter.column, filter.value);
      case 'overlaps':
        return query.overlaps(filter.column, filter.value as List);
      default:
        throw CloudStorageException('Unsupported filter operator: ${filter.operator}');
    }
  }
}
