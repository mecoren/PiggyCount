import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/tag_providers.dart';
import '../../providers/database_providers.dart';
import '../../services/billing/post_processor.dart';
import '../../services/data/tag_seed_service.dart';
import '../../styles/tokens.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/tag_chip.dart';

/// 以底部抽屉形式弹出标签编辑器（新建 / 编辑通用）。
///
/// 走项目统一的**悬浮卡片表单抽屉**（[PiggyFormSheet]），与预算 / 账户 / 周期账单
/// 编辑器同款；返回值是**保存后重读的 Tag**（调用方 `TagSelector` 的自动选中依赖它），
/// 取消则返回 null。表单逻辑仍在本文件的 [TagEditPage]。
Future<Tag?> showTagFormBottomSheet(
  BuildContext context, {
  Tag? tag,
}) {
  return showPiggyFormSheet<Tag>(
    context,
    builder: (_) => TagEditPage(tag: tag),
  );
}

/// 标签编辑表单（悬浮卡片抽屉内容）。
class TagEditPage extends ConsumerStatefulWidget {
  /// 要编辑的标签，为空表示新增
  final Tag? tag;

  const TagEditPage({super.key, this.tag});

  @override
  ConsumerState<TagEditPage> createState() => _TagEditPageState();
}

class _TagEditPageState extends ConsumerState<TagEditPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late String _selectedColor;
  bool _isSubmitting = false;

  bool get _isEditing => widget.tag != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.tag?.name ?? '');
    _selectedColor = widget.tag?.color ?? TagSeedService.getRandomColor();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return PiggyFormSheet(
      title: _isEditing ? l10n.tagEditTitle : l10n.tagAddTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: _isSubmitting ? null : _submit,
      confirmBusy: _isSubmitting,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 预览
            _buildPreview(),
            const SizedBox(height: PiggyDimens.p24),

            // 标签名称（字段直接浮在抽屉卡片底上，不再套描边卡片）
            _buildSectionLabel(context, l10n.tagNameLabel),
            const SizedBox(height: PiggyDimens.p8),
            TextFormField(
              controller: _nameController,
              decoration: piggyOutlinedDecoration(
                context,
                hint: l10n.tagNameHint,
              ),
              maxLength: 20,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return l10n.tagNameRequired;
                }
                return null;
              },
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: PiggyDimens.p16),

            // 颜色选择
            _buildSectionLabel(context, l10n.tagColorLabel),
            const SizedBox(height: PiggyDimens.p12),
            _buildColorPicker(),
          ],
        ),
      ),
    );
  }

  /// 表单分区标题（与预算 / 账户抽屉同一口径）。
  Widget _buildSectionLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: PiggyTextTokens.fs14,
          fontWeight: FontWeight.w500,
          color: PiggyTokens.textSecondary(context),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    return Center(
      child: TagChip(
        name: _nameController.text.isEmpty ? '标签预览' : _nameController.text,
        color: _selectedColor,
        size: TagChipSize.large,
      ),
    );
  }

  Widget _buildColorPicker() {
    final colors = TagSeedService.getColorPalette();

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: colors.map((colorHex) {
        final isSelected = _selectedColor == colorHex;
        final color = _parseColor(colorHex);

        return GestureDetector(
          onTap: () => setState(() => _selectedColor = colorHex),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: isSelected
                  ? Border.all(
                      color: PiggyTokens.isDark(context)
                          ? Colors.white
                          : Colors.black,
                      width: 3,
                    )
                  : null,
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.4),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: isSelected
                ? Icon(
                    Icons.check,
                    color: _isLightColor(color) ? Colors.black : Colors.white,
                    size: 20,
                  )
                : null,
          ),
        );
      }).toList(),
    );
  }

  Color _parseColor(String hex) {
    try {
      String h = hex;
      if (h.startsWith('#')) {
        h = h.substring(1);
      }
      if (h.length == 6) {
        h = 'FF$h';
      }
      return Color(int.parse(h, radix: 16));
    } catch (e) {
      return Colors.grey;
    }
  }

  bool _isLightColor(Color color) {
    final luminance = color.computeLuminance();
    return luminance > 0.5;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final name = _nameController.text.trim();
    final l10n = AppLocalizations.of(context);
    final repo = ref.read(repositoryProvider);

    // 检查名称是否重复
    final isDuplicate = await repo.isTagNameDuplicate(
      name: name,
      excludeId: widget.tag?.id,
    );

    if (isDuplicate) {
      if (mounted) {
        showToast(context, l10n.tagNameDuplicate);
      }
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      // 保存成功后重读已落库的 Tag,通过路由返回给调用方(TagSelector 的
      // 自动选中逻辑依赖这个返回值);读不到时返回 null 正常关页面。
      Tag? savedTag;
      if (_isEditing) {
        // 更新标签
        await repo.updateTag(
          widget.tag!.id,
          name: name,
          color: _selectedColor,
        );
        savedTag = await repo.getTagById(widget.tag!.id);
        if (mounted) {
          showToast(context, l10n.tagUpdateSuccess);
        }
      } else {
        // 创建标签
        final id = await repo.createTag(
          name: name,
          color: _selectedColor,
        );
        savedTag = await repo.getTagById(id);
        if (mounted) {
          showToast(context, l10n.tagCreateSuccess);
        }
      }

      ref.read(tagListRefreshProvider.notifier).state++;

      // 标签是 user-scoped，但 ChangeTracker 记在 ledgerId=0；_push(ledger) 会
      // 顺便把 ledgerId=0 的未推变更一起捎走。用当前激活的 ledgerId 触发 sync
      // 就能把这次重命名实时推到服务端，web 端 WS 收到后 2 秒内就能刷新。
      final activeLedgerId = ref.read(currentLedgerIdProvider);
      if (activeLedgerId > 0) {
        // 不 await：后台异步推送，不阻塞 UI 关闭。
        unawaited(PostProcessor.sync(ref, ledgerId: activeLedgerId));
      }

      if (mounted) {
        Navigator.of(context).pop(savedTag);
      }
    } catch (e) {
      if (mounted) {
        showToast(context, '${l10n.commonError}: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }
}
