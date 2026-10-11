/// v13 自定义字段**同步契约守门**（照 `sync_contract_savings_goal_test.dart` 的四条锁定）。
///
/// 现有 `sync_contract_coverage_test.dart` 只从**交易段**派生指纹白名单 —— 定义段
/// 的字段漂移它看不见。本文件补上「自定义字段定义」这条盲区，锁死四件事：
///
/// 1. **导出字段 ↔ 指纹白名单一字不差**（键集合由两份源码**派生**，不是手抄副本）；
/// 2. **本地专有列绝不进快照 / 指纹** —— `updatedAt` / `createdAt` / `id` /
///    `ledgerId` 一旦进指纹，本机一次无关 UPDATE 或换设备后自增 id 不同，都会让
///    跨设备指纹永久不相等；
/// 3. **每个可同步字段都真的影响指纹**（尤其 v13 新增的 `options`）；
/// 4. **导入的键存在语义**：旧快照缺 `options` 键 → 保留本地选项；显式空数组 →
///    清空为无选项。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

/// 从源码里 `anchor` 之后第一个 `{` 起的**配平块**中，抽取所有 `'key':` 形态的键。
Set<String> _deriveKeys(String source, String anchor) {
  final at = source.indexOf(anchor);
  if (at <= 0) {
    throw StateError('源码锚点未找到（实现结构已变，需更新派生逻辑）: $anchor');
  }
  final open = source.indexOf('{', at);
  var depth = 0;
  var end = -1;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) {
        end = i;
        break;
      }
    }
  }
  if (end <= open) throw StateError('大括号不配平: $anchor');
  final block = source.substring(open, end);
  return RegExp(r"'([A-Za-z_][A-Za-z0-9_]*)'\s*:")
      .allMatches(block)
      .map((m) => m.group(1)!)
      .toSet();
}

/// 自定义字段定义**导出**字段（`transactions_json.dart` 的 customFieldItems 段）
Set<String> deriveCustomFieldExportKeys() => _deriveKeys(
      File('lib/cloud/transactions_json.dart').readAsStringSync(),
      'final customFieldItems = ledgerCustomFields.map',
    );

/// 自定义字段定义**指纹白名单**（`sync_fingerprint.dart` 的 customFieldCanon 段）
Set<String> deriveCustomFieldCanonKeys() => _deriveKeys(
      File('lib/cloud/sync_fingerprint.dart').readAsStringSync(),
      'final customFieldCanon = customFields',
    );

/// 本地专有列 —— **任何情况下都不得**出现在快照或指纹里。
const _localOnlyKeys = <String>['updatedAt', 'createdAt', 'id', 'ledgerId'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final exportKeys = deriveCustomFieldExportKeys();
  final canonKeys = deriveCustomFieldCanonKeys();

  group('① 导出字段 ↔ 指纹白名单', () {
    test('两份源码的键集合一字不差', () {
      expect(
        canonKeys,
        exportKeys,
        reason: '导出有而指纹没有 → 改了这个字段指纹不变、永不传播；'
            '指纹有而导出没有 → 云端那个键恒缺，两端指纹永不相等',
      );
    });

    test('键数量下限（防正则静默匹配不到 → 空集恒真 → 守门失效）', () {
      expect(exportKeys.length, greaterThanOrEqualTo(5),
          reason: '自定义字段可同步字段至少 5 个'
              '（syncId/name/fieldType/options/sortOrder）');
    });

    test('本地专有列不在任何一侧', () {
      for (final k in _localOnlyKeys) {
        expect(exportKeys, isNot(contains(k)),
            reason: '$k 是本地专有列，进快照会让两端内容恒不等');
        expect(canonKeys, isNot(contains(k)),
            reason: '$k 进指纹 = 本机一次无关 UPDATE 就让跨设备指纹永久不一致');
      }
    });
  });

  group('② 快照与指纹里的自定义字段（端到端）', () {
    late PiggyDatabase db;
    late LocalRepository repo;

    setUp(() {
      db = PiggyDatabase.forTesting(NativeDatabase.memory());
      repo = LocalRepository(db);
    });

    tearDown(() async => db.close());

    Future<int> seedSelectField({List<String> options = const ['A', 'B']}) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      return repo.createDefinition(
        ledgerId: 1,
        name: '状态',
        fieldType: CustomFieldType.singleSelect,
        options: options,
        syncId: 'cf-1',
      );
    }

    Future<Map<String, dynamic>> exportPayload() async =>
        jsonDecode(await exportTransactionsJson(db, 1).then((e) => e.jsonStr))
            as Map<String, dynamic>;

    test('导出携带 options 键（恒写，含空数组），不含本地专有列', () async {
      await seedSelectField();
      final payload = await exportPayload();
      final items = (payload['customFields'] as List).cast<Map<String, dynamic>>();

      expect(items, hasLength(1));
      final f = items.single;
      expect(f['name'], '状态');
      expect(f['fieldType'], CustomFieldType.singleSelect);
      expect(f['syncId'], 'cf-1');
      expect(f['options'], ['A', 'B']);
      expect(f['sortOrder'], 0);
      for (final k in _localOnlyKeys) {
        expect(f.containsKey(k), isFalse, reason: '快照不得携带本地专有列 $k');
      }
      // 导出的键集合与派生结果一致（多一个少一个都算契约破坏）
      expect(f.keys.toSet(), exportKeys);
    });

    test('每个可同步字段单独变化都改变指纹', () async {
      await seedSelectField();
      final baseFp = contentFingerprintFromMap(await exportPayload());

      Object? mutateValue(Object? v) {
        if (v is bool) return !v;
        if (v is num) return v + 1;
        if (v is String) return '${v}x';
        return 'FILLED';
      }

      for (final key in exportKeys) {
        final payload = await exportPayload();
        final item =
            (payload['customFields'] as List).cast<Map<String, dynamic>>().single;
        if (item.containsKey(key)) {
          item[key] = mutateValue(item[key]);
        } else {
          item[key] = 'FILLED';
        }
        expect(
          contentFingerprintFromMap(payload),
          isNot(baseFp),
          reason: '改了自定义字段 `$key` 指纹却不变 → 该字段永不跨设备传播',
        );
      }
    });

    test('缺 options 键 == 空数组（旧快照向后兼容，同指纹）', () async {
      await seedSelectField(options: const []);
      final missing = await exportPayload();
      final empty = await exportPayload();

      // 模拟旧快照（v12 及以前不写 options 键）与显式空数组两种形态。
      (empty['customFields'] as List).cast<Map<String, dynamic>>().single
          .remove('options');
      expect((missing['customFields'] as List).cast<Map<String, dynamic>>().single
          .containsKey('options'), isTrue);

      expect(contentFingerprintFromMap(missing),
          contentFingerprintFromMap(empty),
          reason: '缺键与显式空数组必须归一化到同一指纹');
    });

    test('往返一致：A 导出 → B 导入 → B 再导出，指纹相同且选项落库', () async {
      await seedSelectField();
      final exported = await exportTransactionsJson(db, 1);
      final fpA = contentFingerprintFromMap(jsonDecode(exported.jsonStr));

      final dbB = PiggyDatabase.forTesting(NativeDatabase.memory());
      addTearDown(dbB.close);
      final repoB = LocalRepository(dbB);
      await dbB.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

      await dataImportService.importData(
        repoB,
        1,
        parseJsonToImportData(exported.jsonStr),
        defaultCurrency: 'CNY',
      );

      final defsB = await repoB.getDefinitionsForLedger(1);
      expect(defsB, hasLength(1));
      expect(defsB.single.fieldType, CustomFieldType.singleSelect);
      expect(CustomFieldOptionsCodec.decode(defsB.single.optionsJson), ['A', 'B']);

      final fpB = contentFingerprintFromMap(
          jsonDecode((await exportTransactionsJson(dbB, 1)).jsonStr));
      expect(fpB, fpA, reason: '往返后指纹必须一致，否则每轮同步都判「有差异」');
    });
  });

  group('③ 导入 options 的键存在语义', () {
    test('解析：缺 options 键 → null（保留本地）；显式空数组 → 空列表（清空）', () {
      Map<String, dynamic> payloadWith(Object? optionsOrNull) => {
            'version': 13,
            'items': <dynamic>[],
            'customFields': [
              {
                'syncId': 'cf-1',
                'name': '状态',
                'fieldType': 'singleSelect',
                'sortOrder': 0,
                if (optionsOrNull != null) 'options': optionsOrNull,
              },
            ],
          };

      final legacy = parseJsonToImportData(jsonEncode(payloadWith(null)));
      expect(legacy.customFields.single.options, isNull,
          reason: '旧快照缺键 → null → 导入侧不得覆盖本地选项');

      final empty = parseJsonToImportData(jsonEncode(payloadWith(<String>[])));
      expect(empty.customFields.single.options, isEmpty,
          reason: '显式空数组 → 云端权威为「无选项」→ 覆盖本地为空');

      final filled =
          parseJsonToImportData(jsonEncode(payloadWith(['X', 'Y'])));
      expect(filled.customFields.single.options, ['X', 'Y']);
    });

    test('缺键保留本地选项、显式空数组清空本地选项', () async {
      final db = PiggyDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = LocalRepository(db);
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      await repo.createDefinition(
        ledgerId: 1,
        name: '状态',
        fieldType: CustomFieldType.singleSelect,
        options: ['A', 'B'],
        syncId: 'cf-1',
      );

      // ① 旧快照（缺 options 键，options = null）→ 本地选项保留。
      await dataImportService.importCustomFields(repo, 1, const [
        ImportCustomField(
          name: '状态',
          fieldType: CustomFieldType.singleSelect,
          syncId: 'cf-1',
        ),
      ]);
      var def = (await repo.getDefinitionsForLedger(1)).single;
      expect(CustomFieldOptionsCodec.decode(def.optionsJson), ['A', 'B'],
          reason: '旧快照不能清空本地选项配置');

      // ② 显式空数组 → 清空为无选项。
      await dataImportService.importCustomFields(repo, 1, const [
        ImportCustomField(
          name: '状态',
          fieldType: CustomFieldType.singleSelect,
          syncId: 'cf-1',
          options: <String>[],
        ),
      ]);
      def = (await repo.getDefinitionsForLedger(1)).single;
      expect(def.optionsJson, isNull, reason: '显式空数组 = 云端权威为无选项');

      // ③ 云端带选项 → 覆盖本地。
      await dataImportService.importCustomFields(repo, 1, const [
        ImportCustomField(
          name: '状态',
          fieldType: CustomFieldType.singleSelect,
          syncId: 'cf-1',
          options: ['C'],
        ),
      ]);
      def = (await repo.getDefinitionsForLedger(1)).single;
      expect(CustomFieldOptionsCodec.decode(def.optionsJson), ['C']);
    });
  });
}
