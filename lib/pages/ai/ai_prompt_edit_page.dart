import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../widgets/ui/ui.dart';
import '../../widgets/biz/section_card.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../providers/theme_providers.dart';
import '../../l10n/app_localizations.dart';
import '../../ai/core/prompt_builder.dart';
import '../../ai/providers/ai_constants.dart';
import '../../ai/providers/ai_provider_manager.dart';

/// 以底部抽屉形式弹出 AI 自定义提示词编辑器。
///
/// 走项目统一的**悬浮卡片表单抽屉**（[PiggyFormSheet]）：标题 + 卡片内滚动内容 +
/// 底部「取消｜保存」。原先挂在标题栏的「分享 / 粘贴」两个动作移入提示词区块标题行
/// （抽屉外壳不提供标题栏 action）；「预览 / 恢复默认」仍留在内容里（预览要能看到
/// 编辑结果，属于编辑过程而非收尾动作）。
Future<void> showAIPromptFormBottomSheet(BuildContext context) {
  return showPiggyFormSheet<void>(
    context,
    builder: (_) => const AIPromptEditPage(),
  );
}

/// AI 自定义提示词编辑表单（悬浮卡片抽屉内容）。
class AIPromptEditPage extends ConsumerStatefulWidget {
  const AIPromptEditPage({super.key});

  @override
  ConsumerState<AIPromptEditPage> createState() => _AIPromptEditPageState();
}

class _AIPromptEditPageState extends ConsumerState<AIPromptEditPage> {
  late TextEditingController _promptController;
  bool _loading = true;
  bool _hasChanges = false;
  String _savedPrompt = '';

  /// 使用 PromptBuilder 中定义的默认模板
  static String get defaultPrompt => PromptBuilder.defaultTemplate;

  /// 变量说明列表 —— 从 [PromptBuilder.placeholders] 登记表生成,不再手工维护
  /// (移植 BeeCount #437;以前手写会漏列新占位符)。
  List<Map<String, String>> _getVariables(AppLocalizations l10n) => [
        for (final p in PromptBuilder.placeholders)
          {'name': p.token, 'desc': _placeholderDesc(p.token, l10n)},
      ];

  String _placeholderDesc(String token, AppLocalizations l10n) =>
      switch (token) {
        '{{BILL_GUARD}}' => l10n.aiPromptVarBillGuard,
        '{{INPUT_SOURCE}}' => l10n.aiPromptVarInputSource,
        '{{CURRENT_TIME}}' => l10n.aiPromptVarCurrentTime,
        '{{CURRENT_DATE}}' => l10n.aiPromptVarCurrentDate,
        '{{OCR_TEXT}}' => l10n.aiPromptVarOcrText,
        '{{CATEGORIES}}' => l10n.aiPromptVarCategories,
        '{{ACCOUNTS}}' => l10n.aiPromptVarAccounts,
        '{{CURRENCIES}}' => l10n.aiPromptVarCurrencies,
        _ => token,
      };

  /// 当前模板缺失的、会导致能力失效的占位符(移植 BeeCount #437 A7)。
  ///
  /// **无状态检测**:直接算「默认模板的占位符集合 − 用户模板里有的」,不引
  /// 版本号 —— 自定义模板会跨设备同步,版本号会在多端间漂移;集合差在哪台
  /// 设备上算都一样。
  List<PromptPlaceholder> get _missingPlaceholders =>
      PromptBuilder.missingPlaceholdersIn(_promptController.text);

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController();
    _loadPrompt();
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _loadPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(AIConstants.keyAiCustomPrompt);
    // 空字符串也回退到默认，避免编辑页显示空内容
    final customPrompt =
        (saved != null && saved.trim().isNotEmpty) ? saved : defaultPrompt;

    setState(() {
      _promptController.text = customPrompt;
      _savedPrompt = customPrompt;
      _loading = false;
    });
  }

  Future<void> _savePrompt() async {
    // 走 AIProviderManager.saveCustomPrompt 而不是直接 setString,
    // 这样 onConfigChanged 能触发把整组 AI 配置推到 server,跨设备同步。
    await AIProviderManager.saveCustomPrompt(_promptController.text);

    setState(() {
      _savedPrompt = _promptController.text;
      _hasChanges = false;
    });

    if (mounted) {
      showToast(context, AppLocalizations.of(context).aiPromptSaved);
    }
  }

  Future<void> _resetToDefault() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialogShell(
        title: Text(l10n.aiPromptResetConfirmTitle),
        content: Text(l10n.aiPromptResetConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        _promptController.text = defaultPrompt;
        _hasChanges = _promptController.text != _savedPrompt;
      });
    }
  }

  /// 把某个占位符的段落追加到用户模板末尾(移植 BeeCount #437 A7 的一键补丁)。
  ///
  /// **不整段重置** —— 用户的定制照旧保留,只补上缺的能力;也**不自动保存**,
  /// 让用户先看一眼再点保存。只有 [PromptPlaceholder.appendSnippet] 非空的占位符
  /// 才提供这个按钮:`{{BILL_GUARD}}` 必须在最前面、`{{OCR_TEXT}}` 位置有语义,
  /// 盲目追加到末尾反而会写坏模板。
  void _insertPlaceholderSection(PromptPlaceholder p) {
    final snippet = p.appendSnippet;
    if (snippet == null) return;
    final text = _promptController.text.trimRight();
    _promptController.text = '$text\n$snippet';
    setState(() {
      _hasChanges = _promptController.text != _savedPrompt;
    });
    showToast(context,
        AppLocalizations.of(context).aiPromptVarSectionInserted(p.token));
  }

  Future<void> _pastePrompt() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      setState(() {
        _promptController.text = data.text!;
        _hasChanges = _promptController.text != _savedPrompt;
      });
      if (mounted) {
        showToast(context, AppLocalizations.of(context).aiPromptPasted);
      }
    }
  }

  /// 分享提示词
  Future<void> _sharePrompt() async {
    final l10n = AppLocalizations.of(context);
    final text = _promptController.text;
    if (text.isEmpty) return;

    await SharePlus.instance.share(ShareParams(
      text: text,
      subject: l10n.aiPromptEditTitle,
    ));
  }

  /// 生成预览内容
  String _generatePreview() {
    final template = _promptController.text;

    // 获取当前日期时间
    final now = DateTime.now();
    final currentDate =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final currentHour = now.hour.toString().padLeft(2, '0');
    final currentMinute = now.minute.toString().padLeft(2, '0');
    final currentTime = '$currentDate $currentHour:$currentMinute';

    // 示例分类
    const exampleCategories = '分类列表：\n支出：餐饮、交通、购物、娱乐、居家\n收入：工资、理财、红包';

    // 示例账户(多币种:外币账户会带币种后缀)
    const exampleAccounts = '\n账户列表：微信、支付宝、现金、Chase(USD)';

    // 示例币种上下文
    const exampleCurrencies = '\n账本主币种：CNY；账本内已有外币账户：USD';

    // 示例OCR文本
    const exampleOcrText = '商品名称：星巴克拿铁咖啡\n金额：￥35.00\n支付时间：2025-01-15 14:30';

    // 示例输入源描述
    const exampleInputSource = '从以下支付账单文本中';

    // 替换变量
    return template
        .replaceAll('{{INPUT_SOURCE}}', exampleInputSource)
        .replaceAll('{{CURRENT_TIME}}', currentTime)
        .replaceAll('{{CURRENT_DATE}}', currentDate)
        .replaceAll('{{OCR_TEXT}}', exampleOcrText)
        .replaceAll('{{CATEGORIES}}', exampleCategories)
        .replaceAll('{{ACCOUNTS}}', exampleAccounts)
        .replaceAll('{{CURRENCIES}}', exampleCurrencies);
  }

  /// 显示预览对话框
  void _showPreviewDialog() {
    final l10n = AppLocalizations.of(context);
    final preview = _generatePreview();
    final primaryColor = ref.read(primaryColorProvider);

    // 外壳走项目弹窗语言（[AppDialogShell]）：Icon + 标题 + 可滚动内容 +
    // 底部分栏动作区；不再自绘 Dialog(surfaceElevated + radiusXl) 与主题色标题栏。
    showDialog(
      context: context,
      builder: (dialogContext) => AppDialogShell(
        wide: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.preview, color: primaryColor, size: 20),
            const SizedBox(width: PiggyDimens.p8),
            Flexible(child: Text(l10n.aiPromptPreviewTitle)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 提示词预览（等宽字体 + 1.5 行高，便于读 YAML 结构）
            SelectableText(
              preview,
              style: const TextStyle(
                fontSize: PiggyTextTokens.fs13,
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
            const SizedBox(height: PiggyDimens.p16),
            Text(
              l10n.aiPromptPreviewNote,
              style: PiggyTextTokens.label(dialogContext),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.commonClose),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);

    if (_loading) {
      // 抽屉外壳下的加载态：同一张悬浮卡片里转圈，避免先闪一个空白抽屉
      return PiggySheetCard(
        child: SizedBox(
          height: 160.0.scaled(context, ref),
          child: Center(
            child: PiggySpinner(size: 36, color: PiggyTokens.primary(context)),
          ),
        ),
      );
    }

    return PiggyFormSheet(
      title: l10n.aiPromptEditTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.aiPromptSave,
      onCancel: () => Navigator.of(context).pop(),
      // 无改动时禁用保存（沿用原 `_hasChanges` 门控）。保存后不自动关抽屉：
      // 「未保存」角标消失即已落库，用户可继续预览 / 微调（原整屏页行为不变）。
      onConfirm: _hasChanges ? _savePrompt : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 变量说明
          _buildVariablesSection(primaryColor),

          // 能力缺失提示(移植 BeeCount #437 A7):默认模板新增占位符后,
          // 老的自定义模板拿不到对应能力 —— 我们不覆盖用户模板,只给
          // 提示 + 可安全追加的一键补丁。
          if (_missingPlaceholders.isNotEmpty) ...[
            SizedBox(height: 8.0.scaled(context, ref)),
            _buildMissingPlaceholderHint(primaryColor),
          ],

          SizedBox(height: 8.0.scaled(context, ref)),

          // 提示词编辑区
          _buildPromptEditor(primaryColor),

          SizedBox(height: 8.0.scaled(context, ref)),

          // 预览 / 恢复默认（保存已由抽屉底部「取消｜保存」承担）
          _buildActionButtons(primaryColor),
        ],
      ),
    );
  }

  /// 「模板缺能力」提示条:列出缺的占位符 + 可自动补的给按钮 + 恢复默认兜底。
  Widget _buildMissingPlaceholderHint(Color primaryColor) {
    final l10n = AppLocalizations.of(context);
    final missing = _missingPlaceholders;
    final insertable = missing.where((p) => p.appendSnippet != null).toList();
    return SectionCard(
      flat: true,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    color: PiggyTokens.warning(context), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.aiPromptMissingVarsHint(
                        missing.map((p) => p.token).join('、')),
                    style: TextStyle(
                      fontSize: PiggyTextTokens.fs13,
                      height: 1.5,
                      color: PiggyTokens.textSecondary(context),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 有安全追加片段的逐个给一键补丁;位置有语义的只提示(上面的变量
            // 说明卡里有它的用途),用户自己放,或者用「恢复默认」兜底。
            for (final p in insertable) ...[
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _insertPlaceholderSection(p),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.aiPromptInsertVarSection(p.token)),
                  style: FilledButton.styleFrom(
                    backgroundColor: primaryColor,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _resetToDefault,
                icon: const Icon(Icons.restore, size: 18),
                label: Text(l10n.aiPromptResetDefault),
                style: OutlinedButton.styleFrom(
                  foregroundColor: PiggyTokens.textSecondary(context),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVariablesSection(Color primaryColor) {
    final l10n = AppLocalizations.of(context);
    final variables = _getVariables(l10n);

    return SectionCard(
      flat: true,
      child: ExpansionTile(
        leading: Icon(Icons.code, color: primaryColor, size: 20),
        title: Text(
          l10n.aiPromptVariables,
          style: const TextStyle(
              fontSize: PiggyTextTokens.fs15, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(l10n.aiPromptVariablesHint,
            style: const TextStyle(fontSize: PiggyTextTokens.fs12)),
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final v in variables)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: primaryColor.withValues(alpha: 0.1),
                            borderRadius:
                                BorderRadius.circular(PiggyDimens.radiusXs),
                          ),
                          child: Text(
                            v['name']!,
                            style: TextStyle(
                              fontSize: PiggyTextTokens.fs12,
                              fontFamily: 'monospace',
                              color: primaryColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            v['desc']!,
                            style: TextStyle(
                              fontSize: PiggyTextTokens.fs13,
                              color: PiggyTokens.textSecondary(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPromptEditor(Color primaryColor) {
    final l10n = AppLocalizations.of(context);

    return SectionCard(
      flat: true,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.edit_note, color: primaryColor, size: 20),
                const SizedBox(width: 8),
                Text(
                  l10n.aiPromptContent,
                  style: const TextStyle(
                      fontSize: PiggyTextTokens.fs15,
                      fontWeight: FontWeight.w600),
                ),
                if (_hasChanges) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color:
                          PiggyTokens.warning(context).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                    ),
                    child: Text(
                      l10n.aiPromptUnsaved,
                      style: PiggyTextTokens.caption(context)
                          .copyWith(color: PiggyTokens.warning(context)),
                    ),
                  ),
                ],
                const Spacer(),
                // 分享 / 粘贴：原先挂在标题栏（抽屉外壳无 action 位），
                // 落到提示词区块标题行 —— 两者都作用于这段文本。
                IconButton(
                  icon: const Icon(Icons.share, size: 20),
                  tooltip: l10n.tooltipShare,
                  visualDensity: VisualDensity.compact,
                  onPressed: _sharePrompt,
                ),
                IconButton(
                  icon: const Icon(Icons.paste, size: 20),
                  tooltip: l10n.tooltipPaste,
                  visualDensity: VisualDensity.compact,
                  onPressed: _pastePrompt,
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promptController,
              maxLines: 20,
              minLines: 10,
              style: const TextStyle(
                fontSize: PiggyTextTokens.fs13,
                fontFamily: 'monospace',
                height: 1.5,
              ),
              decoration: piggyOutlinedDecoration(
                context,
                hint: l10n.aiPromptInputHint,
              ),
              onChanged: (value) {
                setState(() {
                  _hasChanges = value != _savedPrompt;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(Color primaryColor) {
    final l10n = AppLocalizations.of(context);

    return SectionCard(
      flat: true,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 预览（保存已由抽屉底部按钮承担，此处不再重复放一个保存键）
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _showPreviewDialog,
                icon: const Icon(Icons.preview),
                label: Text(l10n.aiPromptPreview),
                style: OutlinedButton.styleFrom(
                  foregroundColor: primaryColor,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 恢复默认按钮
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _resetToDefault,
                icon: const Icon(Icons.restore),
                label: Text(l10n.aiPromptResetDefault),
                style: OutlinedButton.styleFrom(
                  foregroundColor: PiggyTokens.textSecondary(context),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
