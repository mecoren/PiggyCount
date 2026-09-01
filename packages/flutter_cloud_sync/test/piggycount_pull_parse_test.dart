import 'dart:convert';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 审计 C4：pull 解析层对 ledger_id=null 的防御
///
/// 客户端推用户级实体（account/category/tag/exchange_rate_override）时
/// payload 的 'ledger_id' 就是 null；server 原样回放 NULL 时，旧实现的
/// 硬校验 `is! String` 会把整条 change 静默丢弃（无错误记录、游标照常
/// 推进）→ 该实体变更永久不同步且无感知。修复后与文件内其余解析口径
/// 对齐：null/缺失 → ''（user-global 形态）。
class _FakeAuth extends PiggyCountCloudAuthService {
  _FakeAuth() : super(baseUrl: 'https://api.example.com', apiPrefix: '/api/v1');

  @override
  Future<String> requireAccessToken() async => 'test-token';

  @override
  Future<bool> tryRefreshSession() async => false;

  @override
  String? get currentDeviceId => 'device-under-test';
}

PiggyCountCloudStorageService _service(MockClient mock) =>
    PiggyCountCloudStorageService(
      baseUrl: 'https://api.example.com',
      apiPrefix: '/api/v1',
      auth: _FakeAuth(),
      httpClient: mock,
    );

void main() {
  test('ledger_id=null 的用户级 change 不再被静默丢弃', () async {
    final mock = MockClient((request) async {
      expect(request.url.path, endsWith('/sync/pull'));
      return http.Response(
        jsonEncode({
          'changes': [
            // user-global 实体：server 回放 NULL ledger_id
            {
              'change_id': 7,
              'ledger_id': null,
              'entity_type': 'account',
              'entity_sync_id': 'acc-sync-1',
              'action': 'upsert',
              'payload': {'name': 'cash'},
            },
            // 常规账本级 change 保持原样
            {
              'change_id': 8,
              'ledger_id': 'ledger-ext-1',
              'entity_type': 'transaction',
              'entity_sync_id': 'tx-sync-1',
              'action': 'upsert',
              'payload': {'amount': 1},
            },
          ],
          'server_cursor': 100,
          'has_more': false,
        }),
        200,
      );
    });

    final result = await _service(mock).pullChanges(
      since: 0,
      persistCursor: false, // 纯解析层测试，避免依赖 SharedPreferences
    );

    expect(result.changes.length, 2);
    expect(result.serverCursor, 100);
    expect(result.hasMore, isFalse);

    final first = result.changes[0];
    expect(first.changeId, 7);
    expect(first.ledgerId, ''); // NULL → 空串（user-global 形态）
    expect(first.entityType, 'account');
    expect(first.entitySyncId, 'acc-sync-1');

    final second = result.changes[1];
    expect(second.ledgerId, 'ledger-ext-1');
  });

  test('真正畸形（缺 change_id/entity 字段）的 change 仍被跳过', () async {
    final mock = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'changes': [
            {
              'change_id': null,
              'ledger_id': 'l1',
              'entity_type': 'transaction',
              'entity_sync_id': 'tx-1',
              'action': 'upsert',
            },
            {
              'change_id': 9,
              'ledger_id': 'l1',
              'entity_type': 'transaction',
              'entity_sync_id': null,
              'action': 'upsert',
            },
          ],
          'server_cursor': 5,
          'has_more': false,
        }),
        200,
      );
    });

    final result = await _service(mock).pullChanges(
      since: 0,
      persistCursor: false,
    );
    expect(result.changes, isEmpty);
    expect(result.serverCursor, 5);
  });
}
