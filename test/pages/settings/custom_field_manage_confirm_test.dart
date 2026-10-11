/// 自定义字段**破坏性修改**判定的守门测试。
///
/// 背景：编辑抽屉里改字段类型 / 删除已保存选项，此前点「保存」直接生效 ——
/// 选项被清空、历史值语义变化，用户没有感知。现在这两类（以及清空选项文本）
/// 一律走 [showDoubleDangerConfirmDialog]（两次确认、各带倒计时）；纯改名 /
/// 新增选项 / 排序不弹（纯编辑语义）。
///
/// 判定逻辑抽成纯函数 [detectCustomFieldEditHazard]（页面里只是按判定结果弹窗），
/// 因此这里不需要 pump 页面（该页依赖 drift StreamProvider，组件测试会留 pending
/// Timer）。弹窗接线由设备端手测覆盖。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/pages/settings/custom_field_manage_page.dart';

void main() {
  group('detectCustomFieldEditHazard', () {
    test('新建字段：无既有数据 → 永不构成破坏性变更', () {
      expect(
        detectCustomFieldEditHazard(
          isEditing: false,
          originalType: 'singleSelect',
          newType: 'text',
          removedPersistedOptions: const ['a'],
          clearedPersistedOptions: const ['b'],
        ),
        (typeChanged: false, removedOptions: const <String>[]),
      );
    });

    test('改字段类型：typeChanged=true（优先于选项删除）', () {
      final h = detectCustomFieldEditHazard(
        isEditing: true,
        originalType: 'singleSelect',
        newType: 'text',
        removedPersistedOptions: const ['a'],
        clearedPersistedOptions: const [],
      );
      expect(h.typeChanged, isTrue);
      expect(h.removedOptions, isEmpty);
    });

    test('类型不变 + 删除已保存选项 → removedOptions 非空', () {
      final h = detectCustomFieldEditHazard(
        isEditing: true,
        originalType: 'multiSelect',
        newType: 'multiSelect',
        removedPersistedOptions: const ['red'],
        clearedPersistedOptions: const [],
      );
      expect(h.typeChanged, isFalse);
      expect(h.removedOptions, ['red']);
    });

    test('类型不变 + 选项文本被清空 → 视同删除', () {
      final h = detectCustomFieldEditHazard(
        isEditing: true,
        originalType: 'singleSelect',
        newType: 'singleSelect',
        removedPersistedOptions: const [],
        clearedPersistedOptions: const ['b'],
      );
      expect(h.removedOptions, ['b']);
    });

    test('删除 + 清空并存 → 合并去重', () {
      final h = detectCustomFieldEditHazard(
        isEditing: true,
        originalType: 'singleSelect',
        newType: 'singleSelect',
        removedPersistedOptions: const ['a', 'x'],
        clearedPersistedOptions: const ['x', 'y'],
      );
      expect(h.removedOptions.toSet(), {'a', 'x', 'y'});
    });

    test('类型不变 + 纯改名 / 新增选项 → 无破坏性变更（不弹确认）', () {
      final h = detectCustomFieldEditHazard(
        isEditing: true,
        originalType: 'singleSelect',
        newType: 'singleSelect',
        removedPersistedOptions: const [],
        clearedPersistedOptions: const [],
      );
      expect(h.typeChanged, isFalse);
      expect(h.removedOptions, isEmpty);
    });
  });
}
