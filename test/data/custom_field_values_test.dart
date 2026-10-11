/// v46 自定义字段值 codec 的规范化契约。
///
/// 这些断言保护的是「指纹/差分两端算出同一串」这一前提：任何一条不成立，
/// 都会表现为跨设备假差异（要么每笔都判 modified 空转，要么改动永不传播）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/models/custom_field_values.dart';

void main() {
  group('encode / decode', () {
    test('往返一致：金额 + 文本 + 日期', () {
      final values = <String, dynamic>{
        'cf-a': 12.5,
        'cf-b': '发票 2024-001',
        'cf-c': '2024-03-01T00:00:00.000',
      };
      final encoded = CustomFieldValueCodec.encode(values);
      expect(encoded, isNotNull);

      final decoded = CustomFieldValueCodec.decode(encoded);
      expect(decoded['cf-a'], 12.5);
      expect(decoded['cf-b'], '发票 2024-001');
      expect(decoded['cf-c'], '2024-03-01T00:00:00.000');
    });

    test('空输入 → null（列写 NULL，而不是 {}）', () {
      expect(CustomFieldValueCodec.encode(null), isNull);
      expect(CustomFieldValueCodec.encode(const {}), isNull);
      expect(CustomFieldValueCodec.encode({'cf-a': null}), isNull);
      expect(CustomFieldValueCodec.encode({'cf-a': '   '}), isNull);
    });

    test('键排序输出：同值不同插入顺序得到逐字节相同的 JSON', () {
      final a = CustomFieldValueCodec.encode({'z': 1.0, 'a': 'x'});
      final b = CustomFieldValueCodec.encode({'a': 'x', 'z': 1.0});
      expect(a, b);
      expect(a, '{"a":"x","z":1.0}');
    });

    test('decode 对坏数据静默降级为空 map，绝不抛', () {
      expect(CustomFieldValueCodec.decode(null), isEmpty);
      expect(CustomFieldValueCodec.decode(''), isEmpty);
      expect(CustomFieldValueCodec.decode('  '), isEmpty);
      expect(CustomFieldValueCodec.decode('not-json'), isEmpty);
      expect(CustomFieldValueCodec.decode('[1,2,3]'), isEmpty);
      expect(CustomFieldValueCodec.decode('"text"'), isEmpty);
    });

    test('normalize 剔除空值但保留金额 0', () {
      final norm = CustomFieldValueCodec.normalize({
        'keep-zero': 0.0,
        'drop-null': null,
        'drop-blank': '  ',
        'drop-nested': {'a': 1},
        '  ': 'empty-key',
        'trim-me': '  hello  ',
      });
      expect(norm.keys, containsAll(['keep-zero', 'trim-me']));
      expect(norm['keep-zero'], 0.0);
      expect(norm['trim-me'], 'hello');
      expect(norm.containsKey('drop-null'), isFalse);
      expect(norm.containsKey('drop-blank'), isFalse);
      expect(norm.containsKey('drop-nested'), isFalse);
    });
  });

  group('canonical（指纹/差分比较契约）', () {
    test('null 与 {} 与「全空值对象」等价 —— 旧快照缺键不产生假差异', () {
      final empty = CustomFieldValueCodec.canonical(null);
      expect(CustomFieldValueCodec.canonical(const {}), empty);
      expect(CustomFieldValueCodec.canonical({'cf-a': null}), empty);
      expect(CustomFieldValueCodec.canonical({'cf-a': '  '}), empty);
      expect(empty, isEmpty);
    });

    test('键顺序无关', () {
      final a = CustomFieldValueCodec.canonical({'x': 1, 'y': 'z'});
      final b = CustomFieldValueCodec.canonical({'y': 'z', 'x': 1});
      expect(a, b);
    });

    test('数值表示统一：1 / 1.0 / 1.00 同串', () {
      final i = CustomFieldValueCodec.canonical({'cf': 1});
      final d = CustomFieldValueCodec.canonical({'cf': 1.0});
      final s = CustomFieldValueCodec.canonical({'cf': 1.00});
      expect(i, d);
      expect(d, s);
    });

    test('文本首尾空白不产生差异', () {
      expect(
        CustomFieldValueCodec.canonical({'cf': 'abc'}),
        CustomFieldValueCodec.canonical({'cf': '  abc '}),
      );
    });

    test('真实差异必须被识别（否则改动永不传播）', () {
      expect(
        CustomFieldValueCodec.canonical({'cf': 1}),
        isNot(CustomFieldValueCodec.canonical({'cf': 2})),
      );
      expect(
        CustomFieldValueCodec.canonical({'cf': 'a'}),
        isNot(CustomFieldValueCodec.canonical({'cf': 'b'})),
      );
      // 键集合不同也算差异
      expect(
        CustomFieldValueCodec.canonical({'a': 1}),
        isNot(CustomFieldValueCodec.canonical({'a': 1, 'b': 2})),
      );
    });

    test('equals 走同一口径', () {
      expect(CustomFieldValueCodec.equals(null, const {}), isTrue);
      expect(CustomFieldValueCodec.equals({'a': 1}, {'a': 1.0}), isTrue);
      expect(CustomFieldValueCodec.equals({'a': 1}, {'a': 2}), isFalse);
    });
  });

  group('表单辅助', () {
    test('fromInput：金额解析失败/空白 → null（= 未填）', () {
      expect(CustomFieldValueCodec.fromInput(CustomFieldType.amount, '12.5'),
          12.5);
      expect(CustomFieldValueCodec.fromInput(CustomFieldType.amount, ''),
          isNull);
      expect(CustomFieldValueCodec.fromInput(CustomFieldType.amount, 'abc'),
          isNull);
      expect(CustomFieldValueCodec.fromInput(CustomFieldType.amount, '1.2.3'),
          isNull);
      // 金额 0 是合法输入
      expect(CustomFieldValueCodec.fromInput(CustomFieldType.amount, '0'), 0.0);
    });

    test('fromInput：文本 trim 后返回（与 normalize 同口径，避免空白假差异）', () {
      expect(CustomFieldValueCodec.fromInput(CustomFieldType.text, ' a '),
          'a');
      expect(CustomFieldValueCodec.fromInput(CustomFieldType.text, '   '),
          isNull);
    });

    test('toDisplayString：数值去尾零，空白文本视为无值', () {
      expect(CustomFieldValueCodec.toDisplayString(12.0), '12');
      expect(CustomFieldValueCodec.toDisplayString(12.5), '12.5');
      expect(CustomFieldValueCodec.toDisplayString('  '), isNull);
      expect(CustomFieldValueCodec.toDisplayString(null), isNull);
    });
  });

  group('类型枚举', () {
    test('合法类型集合与校验', () {
      expect(CustomFieldType.all, [
        'amount',
        'text',
        'date',
        'singleSelect',
        'multiSelect',
      ]);
      expect(CustomFieldType.isValid('amount'), isTrue);
      expect(CustomFieldType.isValid('date'), isTrue);
      expect(CustomFieldType.isValid('text'), isTrue);
      expect(CustomFieldType.isValid('singleSelect'), isTrue);
      expect(CustomFieldType.isValid('multiSelect'), isTrue);
      expect(CustomFieldType.isValid('number'), isFalse);
      expect(CustomFieldType.isValid(''), isFalse);
      expect(CustomFieldType.hasOptions('singleSelect'), isTrue);
      expect(CustomFieldType.hasOptions('multiSelect'), isTrue);
      expect(CustomFieldType.hasOptions('text'), isFalse);
    });
  });

  group('v54 多选列表值与选项编解码', () {
    test('列表值：去重 + 字典序排序，空集合按缺失处理', () {
      expect(CustomFieldValueCodec.normalizeValue(['b', 'a', 'a', ' ']),
          ['a', 'b']);
      expect(CustomFieldValueCodec.normalizeValue([]), isNull);
      expect(CustomFieldValueCodec.normalizeValue(['', '  ']), isNull);
      // 非字符串元素剔除（值域是选项值字符串）。
      expect(CustomFieldValueCodec.normalizeValue([1, 'a', null]), ['a']);
    });

    test('列表值 canonical：顺序无关，缺键/空等价', () {
      expect(CustomFieldValueCodec.canonical({'f': ['b', 'a']}),
          CustomFieldValueCodec.canonical({'f': ['a', 'b']}));
      expect(CustomFieldValueCodec.canonical({'f': <String>[]}), '');
      expect(CustomFieldValueCodec.canonical({'f': <String>[]}),
          CustomFieldValueCodec.canonical(null));
    });

    test('列表值 encode 落 JSON 数组且确定性', () {
      expect(CustomFieldValueCodec.encode({'f': ['b', 'a']}), '{"f":["a","b"]}');
      expect(CustomFieldValueCodec.encode({'f': <String>[]}), isNull);
    });

    test('toDisplayString 列表以逗号连接', () {
      expect(CustomFieldValueCodec.toDisplayString(['a', 'b']), 'a, b');
      expect(CustomFieldValueCodec.toDisplayString(<String>[]), isNull);
    });

    test('选项编解码：trim、去重保序、空即缺失', () {
      expect(
          CustomFieldOptionsCodec.normalize([' 已报销 ', '未报销', '已报销', '']),
          ['已报销', '未报销']);
      expect(CustomFieldOptionsCodec.encode([]), isNull);
      expect(CustomFieldOptionsCodec.encode(['a', 'b']), '["a","b"]');
      expect(CustomFieldOptionsCodec.decode('["a","b"]'), ['a', 'b']);
      expect(CustomFieldOptionsCodec.decode('bad'), isEmpty);
      expect(CustomFieldOptionsCodec.canonical(null), '');
      expect(CustomFieldOptionsCodec.canonical(<String>[]), '');
      // 保序：不同顺序 → 不同规范串（顺序即展示顺序）。
      expect(CustomFieldOptionsCodec.canonical(['a', 'b']),
          isNot(CustomFieldOptionsCodec.canonical(['b', 'a'])));
    });
  });
}
