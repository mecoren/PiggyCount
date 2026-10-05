import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../models/note_history.dart';
import '../../services/data/note_history_service.dart';
import '../../styles/tokens.dart';
import '../../providers.dart';
import '../ui/dialog.dart';
import '../ui/piggy_spinner.dart';

/// 备注选择弹窗
/// 支持本地与共享账本分类标识，用于筛选历史备注。
class NotePickerDialog extends ConsumerStatefulWidget {
  final int ledgerId;
  final int? categoryId; // 可选：本地分类ID
  final String? categorySyncId; // 可选：共享账本分类同步ID
  final ValueChanged<String> onNotePicked;

  const NotePickerDialog({
    super.key,
    required this.ledgerId,
    this.categoryId,
    this.categorySyncId,
    required this.onNotePicked,
  });

  @override
  ConsumerState<NotePickerDialog> createState() => _NotePickerDialogState();
}

class _NotePickerDialogState extends ConsumerState<NotePickerDialog> {
  List<NoteHistoryEntry> _notes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    try {
      final repo = ref.read(repositoryProvider);
      final notes = await NoteHistoryService.getHistoryNotes(
        repository: repo,
        ledgerId: widget.ledgerId,
        scope: ref.read(noteHistoryScopeProvider),
        sort: ref.read(noteHistorySortProvider),
        categoryId: widget.categoryId,
        categorySyncId: widget.categorySyncId,
        limit: ref.read(noteHistoryLimitProvider),
      );
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AppDialogShell(
      wide: true,
      title: Text(l10n.appearanceNoteHistory),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 备注列表
            if (_isLoading)
              Padding(
                padding: const EdgeInsets.all(32),
                child:
                    PiggySpinner(size: 36, color: PiggyTokens.primary(context)),
              )
            else if (_notes.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  l10n.commonEmpty,
                  style: TextStyle(color: PiggyTokens.textSecondary(context)),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _notes.map((item) {
                      return InkWell(
                        onTap: () {
                          widget.onNotePicked(item.note);
                          Navigator.pop(context);
                        },
                        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: PiggyTokens.surfaceChip(context),
                            borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
                            border: PiggyTokens.isDark(context)
                                ? Border.all(color: PiggyTokens.border(context))
                                : null,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                item.note,
                                style: TextStyle(
                                  fontSize: PiggyTextTokens.fs13,
                                  color: PiggyTokens.textSecondary(context),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: PiggyTokens.error(context),
                                  borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                                ),
                                child: Text(
                                  '${item.usageCount}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: PiggyTextTokens.fs9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonClose),
        ),
      ],
    );
  }
}
