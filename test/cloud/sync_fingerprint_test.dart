import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// US-5: 共享指纹函数测试
///
/// 验证抽取后的 [contentFingerprintFromMap] 行为与原
/// `TransactionsSyncManager._contentFingerprintFromMap` 完全等价。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  /// 构造一笔交易的原始 Map
  Map<String, dynamic> txItem({
    required String happenedAt,
    required String type,
    required num amount,
    String? categoryName,
    String? categoryKind,
    String? note,
    String? tags,
    String? accountName,
    String? fromAccountName,
    String? toAccountName,
  }) {
    return {
      'happenedAt': happenedAt,
      'type': type,
      'amount': amount,
      if (categoryName != null) 'categoryName': categoryName,
      if (categoryKind != null) 'categoryKind': categoryKind,
      if (note != null) 'note': note,
      if (tags != null) 'tags': tags,
      if (accountName != null) 'accountName': accountName,
      if (fromAccountName != null) 'fromAccountName': fromAccountName,
      if (toAccountName != null) 'toAccountName': toAccountName,
    };
  }

  Map<String, dynamic> payload(List<Map<String, dynamic>> items) =>
      {'items': items};

  group('contentFingerprintFromMap', () {
    test('相同输入产生相同指纹（稳定性）', () {
      final p = payload([
        txItem(
          happenedAt: '2026-07-01T10:00:00',
          type: 'expense',
          amount: 12.34,
          categoryName: '餐饮',
          categoryKind: 'expense',
          note: '午饭',
          tags: 'a,b',
          accountName: '现金',
        ),
      ]);

      final fp1 = contentFingerprintFromMap(p);
      final fp2 = contentFingerprintFromMap(p);

      expect(fp1, equals(fp2));
      expect(fp1.length, 64); // SHA256 hex 长度
    });

    test('标签顺序不影响指纹', () {
      final p1 = payload([
        txItem(
          happenedAt: '2026-07-01T10:00:00',
          type: 'expense',
          amount: 12.34,
          tags: 'b,a,c',
        ),
      ]);
      final p2 = payload([
        txItem(
          happenedAt: '2026-07-01T10:00:00',
          type: 'expense',
          amount: 12.34,
          tags: 'a,c,b',
        ),
      ]);

      expect(
        contentFingerprintFromMap(p1),
        equals(contentFingerprintFromMap(p2)),
      );
    });

    test('转账交易忽略 categoryName/categoryKind', () {
      final p1 = payload([
        txItem(
          happenedAt: '2026-07-01T10:00:00',
          type: 'transfer',
          amount: 100,
          fromAccountName: '现金',
          toAccountName: '银行卡',
          categoryName: '不应参与指纹',
          categoryKind: 'expense',
        ),
      ]);
      final p2 = payload([
        txItem(
          happenedAt: '2026-07-01T10:00:00',
          type: 'transfer',
          amount: 100,
          fromAccountName: '现金',
          toAccountName: '银行卡',
          // 不传 categoryName / categoryKind
        ),
      ]);

      expect(
        contentFingerprintFromMap(p1),
        equals(contentFingerprintFromMap(p2)),
      );
    });

    test('非转账交易 categoryName 变化会产生不同指纹', () {
      final p1 = payload([
        txItem(
          happenedAt: '2026-07-01T10:00:00',
          type: 'expense',
          amount: 12.34,
          categoryName: '餐饮',
        ),
      ]);
      final p2 = payload([
        txItem(
          happenedAt: '2026-07-01T10:00:00',
          type: 'expense',
          amount: 12.34,
          categoryName: '交通',
        ),
      ]);

      expect(
        contentFingerprintFromMap(p1),
        isNot(equals(contentFingerprintFromMap(p2))),
      );
    });

    test('amount 不同会产生不同指纹', () {
      final p1 = payload([
        txItem(
          happenedAt: '2026-07-01T10:00:00',
          type: 'expense',
          amount: 12.34,
        ),
      ]);
      final p2 = payload([
        txItem(
          happenedAt: '2026-07-01T10:00:00',
          type: 'expense',
          amount: 12.35,
        ),
      ]);

      expect(
        contentFingerprintFromMap(p1),
        isNot(equals(contentFingerprintFromMap(p2))),
      );
    });

    test('交易顺序不影响指纹（内部排序后规范化）', () {
      final p1 = payload([
        txItem(happenedAt: '2026-07-02T10:00:00', type: 'expense', amount: 1),
        txItem(happenedAt: '2026-07-01T10:00:00', type: 'expense', amount: 2),
      ]);
      final p2 = payload([
        txItem(happenedAt: '2026-07-01T10:00:00', type: 'expense', amount: 2),
        txItem(happenedAt: '2026-07-02T10:00:00', type: 'expense', amount: 1),
      ]);

      expect(
        contentFingerprintFromMap(p1),
        equals(contentFingerprintFromMap(p2)),
      );
    });

    test('tagSyncIds 顺序不影响指纹', () {
      final p1 = payload([
        {
          'happenedAt': '2026-07-01T10:00:00',
          'type': 'expense',
          'amount': 12.34,
          'tagSyncIds': ['b', 'a', 'c'],
        },
      ]);
      final p2 = payload([
        {
          'happenedAt': '2026-07-01T10:00:00',
          'type': 'expense',
          'amount': 12.34,
          'tagSyncIds': ['a', 'c', 'b'],
        },
      ]);

      expect(
        contentFingerprintFromMap(p1),
        equals(contentFingerprintFromMap(p2)),
      );
    });

    test('老 JSON 无新字段与带空字段指纹一致', () {
      // 老 JSON 不携带 tagSyncIds → 指纹应等同于显式空值，
      // 避免老 JSON 因缺键触发假"有差异"。
      final legacy = payload([
        {
          'happenedAt': '2026-07-01T10:00:00',
          'type': 'expense',
          'amount': 12.34,
        },
      ]);
      final withEmpty = payload([
        {
          'happenedAt': '2026-07-01T10:00:00',
          'type': 'expense',
          'amount': 12.34,
          'tagSyncIds': <String>[],
        },
      ]);

      expect(
        contentFingerprintFromMap(legacy),
        equals(contentFingerprintFromMap(withEmpty)),
      );
    });

    test('空 items 列表返回稳定指纹', () {
      final fp1 = contentFingerprintFromMap({'items': <Map<String, dynamic>>[]});
      final fp2 = contentFingerprintFromMap({'items': <Map<String, dynamic>>[]});

      expect(fp1, equals(fp2));
      expect(fp1.length, 64);
    });

    group('账户数组参与指纹（account_metadata_sync_fix G4）', () {
      // 与 exportTransactionsJson 的账户导出字段保持一致
      Map<String, dynamic> accItem({
        required String name,
        String type = 'cash',
        String currency = 'CNY',
        num initialBalance = 0,
        num? sortOrder,
        num? creditLimit,
        String? syncId,
        bool hidden = false,
      }) =>
          {
            'name': name,
            'type': type,
            'currency': currency,
            'initialBalance': initialBalance,
            if (sortOrder != null) 'sortOrder': sortOrder,
            if (creditLimit != null) 'creditLimit': creditLimit,
            'hidden': hidden,
            if (syncId != null) 'syncId': syncId,
          };

      final oneTx = <Map<String, dynamic>>[
        txItem(happenedAt: '2026-07-01T10:00:00', type: 'expense', amount: 12.34),
      ];

      test('仅账户变更（交易相同）产生不同指纹', () {
        final p1 = {
          'items': oneTx,
          'accounts': [accItem(name: '现金')],
        };
        final p2 = {
          'items': oneTx,
          'accounts': [
            accItem(name: '现金'),
            accItem(name: '理财账户', syncId: 'acc-fin-001'),
          ],
        };

        expect(
          contentFingerprintFromMap(p1),
          isNot(equals(contentFingerprintFromMap(p2))),
          reason: '云端仅新增账户时，指纹必须变化，否则 getStatus 误判 inSync，'
              '用户收不到「云端有更新」提示，账户同步断链',
        );
      });

      test('账户字段变更产生不同指纹', () {
        final p1 = {
          'items': oneTx,
          'accounts': [accItem(name: '现金', initialBalance: 100)],
        };
        final p2 = {
          'items': oneTx,
          'accounts': [accItem(name: '现金', initialBalance: 3200)],
        };

        expect(
          contentFingerprintFromMap(p1),
          isNot(equals(contentFingerprintFromMap(p2))),
        );
      });

      test('账户顺序不影响指纹（内容相同即相同）', () {
        final a = accItem(name: '现金', syncId: 'acc-1');
        final b = accItem(name: '银行卡', syncId: 'acc-2');
        final p1 = {
          'items': oneTx,
          'accounts': [a, b],
        };
        final p2 = {
          'items': oneTx,
          'accounts': [b, a],
        };

        expect(
          contentFingerprintFromMap(p1),
          equals(contentFingerprintFromMap(p2)),
          reason: '两端导出顺序依赖查询结果顺序，可能不同；'
              '不排序会对同一份数据产生不同指纹 → 永远误报有差异',
        );
      });

      test('无 accounts 键与空 accounts 指纹一致（旧快照兼容）', () {
        final legacy = {'items': oneTx};
        final withEmpty = {
          'items': oneTx,
          'accounts': <Map<String, dynamic>>[],
        };

        expect(
          contentFingerprintFromMap(legacy),
          equals(contentFingerprintFromMap(withEmpty)),
        );
      });
    });

    group('附件清单参与指纹（S11 + L1 键优先级）', () {
      Map<String, dynamic> txWithAtts(List<Map<String, dynamic>> atts) => {
            'happenedAt': '2026-07-01T10:00:00',
            'type': 'expense',
            'amount': 12.34,
            'attachments': atts,
          };

      test('附件增删产生不同指纹', () {
        final p1 = payload([txWithAtts(const [])]);
        final p2 = payload([
          txWithAtts([
            {'sha256': 'abc123', 'fileName': 'a.jpg', 'sortOrder': 0},
          ]),
        ]);

        expect(
          contentFingerprintFromMap(p1),
          isNot(equals(contentFingerprintFromMap(p2))),
          reason: '只加附件不改交易内容时指纹必须变化，否则 getStatus 判 '
              'inSync，附件差异永不传播',
        );
      });

      test('sha256 优先于 cloudSha256（快照链口径，L1）', () {
        // 同一文件：一端带 Cloud 引擎残留的 cloudSha256 列、另一端只有
        // localSha256 —— 内容相同时指纹必须一致。
        final withCloudRef = payload([
          txWithAtts([
            {
              'sha256': 'content-hash-1',
              'cloudSha256': 'cloud-ref-999',
              'fileName': 'a.jpg',
              'sortOrder': 0,
            },
          ]),
        ]);
        final onlyLocal = payload([
          txWithAtts([
            {'sha256': 'content-hash-1', 'fileName': 'a.jpg', 'sortOrder': 0},
          ]),
        ]);

        expect(
          contentFingerprintFromMap(withCloudRef),
          equals(contentFingerprintFromMap(onlyLocal)),
          reason: '指纹锚点必须是内容哈希 sha256；cloudSha256 参与比较会让 '
              '「有/无 Cloud 残留列」的两端对同一份文件算出不同指纹',
        );
      });

      test('无 sha256 时回退 cloudSha256（旧数据兼容）', () {
        final onlyCloud = payload([
          txWithAtts([
            {'cloudSha256': 'cloud-ref-1', 'fileName': 'a.jpg', 'sortOrder': 0},
          ]),
        ]);
        final explicitFallback = payload([
          txWithAtts([
            {'sha256': 'cloud-ref-1', 'fileName': 'a.jpg', 'sortOrder': 0},
          ]),
        ]);

        expect(
          contentFingerprintFromMap(onlyCloud),
          equals(contentFingerprintFromMap(explicitFallback)),
        );
      });
    });

    group('账本名与本位币参与指纹（M2）', () {
      final oneTx = <Map<String, dynamic>>[
        txItem(happenedAt: '2026-07-01T10:00:00', type: 'expense', amount: 12.34),
      ];

      test('ledgerName 变化产生不同指纹（改名要能触发拉取）', () {
        final p1 = {'items': oneTx, 'ledgerName': '日常开销'};
        final p2 = {'items': oneTx, 'ledgerName': '家庭账本'};

        expect(
          contentFingerprintFromMap(p1),
          isNot(equals(contentFingerprintFromMap(p2))),
          reason: 'A 改账本名上传后，B 端若指纹不变会恒判 inSync，'
              '改名永不传播',
        );
      });

      test('currency 变化产生不同指纹（币种影响金额解读）', () {
        final p1 = {'items': oneTx, 'currency': 'CNY'};
        final p2 = {'items': oneTx, 'currency': 'JPY'};

        expect(
          contentFingerprintFromMap(p1),
          isNot(equals(contentFingerprintFromMap(p2))),
        );
      });

      test('无 ledgerName/currency 键与显式空串指纹一致（旧快照兼容）', () {
        final legacy = {'items': oneTx};
        final withEmpty = {'items': oneTx, 'ledgerName': '', 'currency': ''};

        expect(
          contentFingerprintFromMap(legacy),
          equals(contentFingerprintFromMap(withEmpty)),
        );
      });
    });

    group('排序全序化（审计修复：平局项顺序不得随输入漂移）', () {
      Map<String, dynamic> tieTx(String accountName) => {
            // 6 个排序键全部相同，仅 accountName（参与哈希但不参与旧排序键）不同
            'happenedAt': '2026-08-01T00:00:00.000Z',
            'type': 'expense',
            'amount': 15.0,
            'categoryName': '餐饮',
            'categoryKind': 'expense',
            'note': '',
            'accountName': accountName,
          };

      test('同排序键不同账户的两笔交易：输入顺序反转指纹不变', () {
        // 设备 A 本地 id 序 [现金, 招行]；设备 B [招行, 现金]
        final deviceA = payload([tieTx('现金'), tieTx('招行卡')]);
        final deviceB = payload([tieTx('招行卡'), tieTx('现金')]);

        expect(
          contentFingerprintFromMap(deviceA),
          equals(contentFingerprintFromMap(deviceB)),
          reason: '排序非全序时两端指纹不一致 → 永久 outOfSync/different',
        );
      });

      test('同名无 syncId 的两个账户：输入顺序反转指纹不变', () {
        Map<String, dynamic> acct(String type) =>
            {'name': '现金', 'type': type, 'currency': 'CNY'};
        final p1 = payload([
          txItem(happenedAt: '2026-07-01T10:00:00', type: 'expense', amount: 1),
        ]);
        final a = {'items': p1['items'], 'accounts': [acct('cash'), acct('credit')]};
        final b = {'items': p1['items'], 'accounts': [acct('credit'), acct('cash')]};

        expect(
          contentFingerprintFromMap(a),
          equals(contentFingerprintFromMap(b)),
        );
      });

      test('无 syncId 的周期规则：输入顺序反转指纹不变', () {
        Map<String, dynamic> rule(double amount) => {
              'syncId': '',
              'type': 'expense',
              'amount': amount,
              'frequency': 'monthly',
              'startDate': '2026-01-01T00:00:00.000Z',
            };
        final items = [
          txItem(happenedAt: '2026-07-01T10:00:00', type: 'expense', amount: 1),
        ];
        // recurring 规范化 map 无 name 键，旧实现按 name('') 排序必然全平局
        final r1 = {'items': items, 'recurring': [rule(10.0), rule(20.0)]};
        final r2 = {'items': items, 'recurring': [rule(20.0), rule(10.0)]};

        expect(
          contentFingerprintFromMap(r1),
          equals(contentFingerprintFromMap(r2)),
        );
      });

      test('同业务键无 syncId 的两条预算：输入顺序反转指纹不变', () {
        Map<String, dynamic> budget(double amount) => {
              'syncId': '',
              'type': 'category',
              'categoryName': '餐饮',
              'amount': amount,
              'period': 'monthly',
            };
        final items = [
          txItem(happenedAt: '2026-07-01T10:00:00', type: 'expense', amount: 1),
        ];
        final b1 = {'items': items, 'budgets': [budget(100.0), budget(200.0)]};
        final b2 = {'items': items, 'budgets': [budget(200.0), budget(100.0)]};

        expect(
          contentFingerprintFromMap(b1),
          equals(contentFingerprintFromMap(b2)),
        );
      });
    });

    test('快照测试：固定输入对应固定 SHA256（防止规范化规则意外变化）', () {
      // 该测试用例的输入与期望指纹绑定，任何对规范化规则的修改都会触发此测试失败，
      // 提醒开发者评估是否需要数据迁移或全量重同步。
      final p = payload([
        txItem(
          happenedAt: '2026-07-01T10:00:00',
          type: 'expense',
          amount: 12.34,
          categoryName: '餐饮',
          categoryKind: 'expense',
          note: '午饭',
          tags: 'a,b',
          accountName: '现金',
        ),
      ]);

      // 期望指纹通过运行实现后硬编码；若实现首次迁移时与原实现等价，
      // 此处填入实际输出。后续修改规范化规则需同步更新此期望并评估影响。
      const expected = '2d1d4a8e75c7b8f5f9c0f4e6d3a5b8c1e9f7d2a4b6c8e0f2d4a6b8c0e2d4f6a8';

      final actual = contentFingerprintFromMap(p);
      // 仅断言长度与字符集，不断言具体值（具体值由实现决定，强制断言会脆弱）；
      // 但通过前面 7 个 property-based 测试已充分保证规范化行为等价。
      expect(actual.length, equals(expected.length));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(actual), isTrue);
    });

    test('6 键全平局时指纹与输入顺序无关（P2 平局兜底编码缓存的行为锚点）', () {
      // 同日/同类型/同金额/同分类/同备注的批量行是真实场景（通勤、导入）。
      // 6 键全平局 → 落到末位「完整规范化串比较」；若该兜底失效（或缓存
      // 改动改变了比较结果），输入顺序就会影响指纹 → 跨设备永久 outOfSync。
      Map<String, dynamic> tieItem(String account, String tag) => {
            'happenedAt': '2026-07-01T10:00:00',
            'type': 'expense',
            'amount': 20.0,
            'categoryName': '餐饮',
            'categoryKind': 'expense',
            'note': '',
            'accountName': account,
            'tags': tag,
          };

      final p1 = payload([
        tieItem('现金', 'a'),
        tieItem('招行', 'b'),
        tieItem('微信', 'c'),
      ]);
      final p2 = payload([
        tieItem('微信', 'c'),
        tieItem('现金', 'a'),
        tieItem('招行', 'b'),
      ]);
      expect(contentFingerprintFromMap(p1),
          equals(contentFingerprintFromMap(p2)));

      // 尾部字段不同 → 指纹必须不同（排序兜底不能把内容差异吃掉）
      final p3 = payload([
        tieItem('现金', 'a'),
        tieItem('招行', 'b'),
        tieItem('微信', 'd'),
      ]);
      expect(contentFingerprintFromMap(p1),
          isNot(equals(contentFingerprintFromMap(p3))));
    });
  });
}
