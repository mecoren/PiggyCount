/// 备注敏感标记（设备本地）契约：
/// - 脱敏纯函数口径（固定掩码、不泄露长度）；
/// - 本地存储增删查与清理；
/// - AI 提示词与交易列表**确实**接了脱敏（源码契约，防重构静默退化）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/services/security/sensitive_note_service.dart';
import 'package:piggycount/utils/sensitive_data_masker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SensitiveDataMasker', () {
    test('非空备注 → 固定掩码；空/null → 空串（不显示掩码）', () {
      expect(SensitiveDataMasker.maskNote('午餐'), SensitiveDataMasker.mask);
      expect(SensitiveDataMasker.maskNote('a'), SensitiveDataMasker.mask,
          reason: '掩码不随原文长度变化（避免长度侧信道）');
      expect(SensitiveDataMasker.maskNote(''.padLeft(50, 'x')),
          SensitiveDataMasker.mask);
      expect(SensitiveDataMasker.maskNote(''), '');
      expect(SensitiveDataMasker.maskNote(null), '');
    });

    test('maskNoteIf：敏感才掩码，否则原样', () {
      expect(SensitiveDataMasker.maskNoteIf(true, '午餐'),
          SensitiveDataMasker.mask);
      expect(SensitiveDataMasker.maskNoteIf(false, '午餐'), '午餐');
      expect(SensitiveDataMasker.maskNoteIf(false, null), '');
    });
  });

  group('SensitiveNoteService（设备本地存储）', () {
    const service = SensitiveNoteService();

    test('标记 / 取消 / 查询 / 幂等', () async {
      expect(await service.load(), isEmpty);

      await service.setSensitive(7, true);
      await service.setSensitive(7, true); // 幂等
      expect(await service.load(), {7});
      expect(await service.isSensitive(7), isTrue);
      expect(await service.isSensitive(8), isFalse);

      await service.setSensitive(7, false);
      expect(await service.load(), isEmpty);
    });

    test('purge 只移除给定 id，其余保留', () async {
      await service.setSensitive(1, true);
      await service.setSensitive(2, true);
      await service.setSensitive(3, true);

      await service.purge([1, 3]);

      expect(await service.load(), {2});
    });
  });

  group('脱敏接线契约（源码守卫）', () {
    test('AI 最近交易提示词接入 SensitiveDataMasker 掩码', () {
      final src =
          File('lib/services/ai/ai_quick_command_service.dart').readAsStringSync();
      expect(src.contains('SensitiveDataMasker.maskNoteIf'), isTrue,
          reason: 'AI 外发前必须对敏感备注脱敏');
      expect(src.contains(r"' (${t.note})'"), isFalse,
          reason: '旧的明文拼接已移除，敏感备注不得原样外发');
    });

    test('交易列表展示接入 SensitiveDataMasker 掩码', () {
      final src = File('lib/widgets/biz/transaction_list.dart').readAsStringSync();
      expect(src.contains('SensitiveDataMasker.maskNoteIf'), isTrue,
          reason: '列表展示敏感备注应走掩码');
    });
  });
}
