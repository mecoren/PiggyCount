import 'package:flutter_cloud_sync_webdav/flutter_cloud_sync_webdav.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('webdavValidateStatus (W1: 只拒 3xx，其余放行)', () {
    test('2xx 成功状态放行', () {
      expect(webdavValidateStatus(200), isTrue);
      expect(webdavValidateStatus(201), isTrue);
      expect(webdavValidateStatus(204), isTrue);
      expect(webdavValidateStatus(207), isTrue); // PROPFIND multistatus
    });

    test('401 必须放行（上游靠 401 响应协商 Basic/Digest 认证）', () {
      expect(webdavValidateStatus(401), isTrue);
    });

    test('4xx/5xx 放行（由上游各操作显式检查状态码抛错）', () {
      expect(webdavValidateStatus(403), isTrue);
      expect(webdavValidateStatus(404), isTrue);
      expect(webdavValidateStatus(409), isTrue);
      expect(webdavValidateStatus(500), isTrue);
      expect(webdavValidateStatus(502), isTrue);
    });

    test('3xx 重定向一律拒绝', () {
      expect(webdavValidateStatus(301), isFalse);
      expect(webdavValidateStatus(302), isFalse);
      expect(webdavValidateStatus(303), isFalse);
      expect(webdavValidateStatus(307), isFalse);
      expect(webdavValidateStatus(308), isFalse);
    });

    test('null 状态拒绝（9ecf378：放行 null 会让 _statusCodeOf 拿不到'
        '结构化码，错误分类退化到字符串匹配；null 交由 dio 异常通道）', () {
      expect(webdavValidateStatus(null), isFalse);
    });
  });
}
