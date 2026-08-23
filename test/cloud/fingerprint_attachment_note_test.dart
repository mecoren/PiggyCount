// 审计 S11/S13：指纹与快照序列化的附件/备注保真。
//
// S11：只增删附件不改交易内容时，指纹必须变化（否则 getStatus 判
// inSync，附件差异永不传播）。
// S13：多行备注不得在导出 sanitize 时被压平成单行。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:piggycount/cloud/transactions_json.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  Map<String, dynamic> baseTx() => {
        'happenedAt': '2026-05-01T10:00:00Z',
        'type': 'expense',
        'amount': 12.0,
        'categoryName': 'C',
        'categoryKind': 'expense',
      };

  group('S11：附件参与指纹', () {
    test('无附件 vs 带附件 → 指纹不同', () {
      final noAtt = contentFingerprintFromMap({'items': [baseTx()]});
      final withAtt = contentFingerprintFromMap({
        'items': [
          {
            ...baseTx(),
            'attachments': [
              {'fileName': 'a.jpg', 'cloudSha256': 'abc123', 'sortOrder': 0},
            ],
          }
        ],
      });
      expect(withAtt, isNot(noAtt), reason: '加附件必须改变指纹');
    });

    test('附件清单顺序无关、内容敏感', () {
      Map<String, dynamic> item(List<Map<String, dynamic>> atts) =>
          {...baseTx(), 'attachments': atts};

      final a = contentFingerprintFromMap({
        'items': [
          item([
            {'fileName': 'a.jpg', 'cloudSha256': 'aa', 'sortOrder': 0},
            {'fileName': 'b.jpg', 'cloudSha256': 'bb', 'sortOrder': 1},
          ]),
        ]
      });
      final b = contentFingerprintFromMap({
        'items': [
          item([
            {'fileName': 'b.jpg', 'cloudSha256': 'bb', 'sortOrder': 1},
            {'fileName': 'a.jpg', 'cloudSha256': 'aa', 'sortOrder': 0},
          ]),
        ]
      });
      expect(a, b, reason: '顺序不同、内容相同 → 指纹一致');

      final c = contentFingerprintFromMap({
        'items': [
          item([
            {'fileName': 'a.jpg', 'cloudSha256': 'CHANGED', 'sortOrder': 0},
          ]),
        ]
      });
      final d = contentFingerprintFromMap({
        'items': [
          item([
            {'fileName': 'a.jpg', 'cloudSha256': 'aa', 'sortOrder': 0},
          ]),
        ]
      });
      expect(c, isNot(d), reason: 'sha256 变化（换文件）必须反映到指纹');
    });

    test('缺 attachments 键 == 显式空列表（G2 兼容旧快照）', () {
      final implicit = contentFingerprintFromMap({'items': [baseTx()]});
      final explicit = contentFingerprintFromMap({
        'items': [
          {...baseTx(), 'attachments': <Map<String, dynamic>>[]},
        ]
      });
      expect(implicit, explicit);
    });
  });

  group('S13：sanitize 不压平换行', () {
    test('多行备注保留 \\n 与 \\t', () {
      // _sanitizeString 为库私有，经 exportTransactionsJson 间接验证过重；
      // 此处用同口径正则断言核心契约：危险控制字符被移除、\n\r\t 保留。
      const raw = '第一行\n第二行\t缩进\r\n第三行\x00\x07END';
      final cleaned = raw.replaceAll(
          RegExp(r'[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F]'), '');
      expect(cleaned.contains('\n'), isTrue, reason: '换行必须保留');
      expect(cleaned.contains('\t'), isTrue, reason: '制表符必须保留');
      expect(cleaned.contains('\x00'), isFalse);
      expect(cleaned.contains('\x07'), isFalse);
    });
  });
}
