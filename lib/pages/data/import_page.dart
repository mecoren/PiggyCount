import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';
import '../../utils/xlsx_reader.dart';
import '../../services/import/file_reader.dart';
import '../../styles/tokens.dart';
import 'import_confirm_page.dart';

/// 账单类型
enum BillSourceType {
  generic, // 通用CSV
  alipay, // 支付宝
  wechat, // 微信
}

class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  final _controller = TextEditingController();
  final bool _hasHeader = true;
  PlatformFile? _picked;
  bool _reading = false;
  double? _readProgress; // 0~1
  bool _cancelRead = false;
  BillSourceType _billType = BillSourceType.generic; // 默认通用CSV

  @override
  void initState() {
    super.initState();
    // 访问一次平台通道，促使插件在部分场景下完成注册（修复热重载后 MissingPluginException 的偶现）
    // ignore: unawaited_futures
    FilePicker.clearTemporaryFiles();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: AppLocalizations.of(context).importTitle,
        showBack: true,
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(AppLocalizations.of(context).importSelectCsvFile),
                        const SizedBox(height: 16),
                        // 账单类型选择器
                        Text(AppLocalizations.of(context).importBillType,
                            style: PiggyTextTokens.body(context).copyWith(
                                color: PiggyTokens.textSecondary(context))),
                        const SizedBox(height: 8),
                        WaitSlidingSegmentedControl<BillSourceType>(
                          selected: _billType,
                          segments: [
                            WaitSlidingSegment(
                              value: BillSourceType.generic,
                              label: AppLocalizations.of(context)
                                  .importBillTypeGeneric,
                            ),
                            WaitSlidingSegment(
                              value: BillSourceType.alipay,
                              label: AppLocalizations.of(context)
                                  .importBillTypeAlipay,
                            ),
                            WaitSlidingSegment(
                              value: BillSourceType.wechat,
                              label: AppLocalizations.of(context)
                                  .importBillTypeWechat,
                            ),
                          ],
                          onValueChanged: (BillSourceType value) {
                            setState(() {
                              _billType = value;
                            });
                          },
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            FilledButton.icon(
                              onPressed: _pickFile,
                              icon: const Icon(Icons.folder_open),
                              label: Text(AppLocalizations.of(context)
                                  .importChooseFile),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _picked?.name ??
                                    AppLocalizations.of(context)
                                        .importNoFileSelected,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        if (_picked == null)
                          Text(AppLocalizations.of(context).importHint,
                              style: TextStyle(
                                  color: PiggyTokens.textTertiary(context))),
                      ],
                    ),
                  ),
                  if (_reading)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.4),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: PiggyTokens.surfaceElevated(context),
                              borderRadius:
                                  BorderRadius.circular(PiggyDimens.radiusLg),
                            ),
                            width: 320,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(AppLocalizations.of(context)
                                    .importReading),
                                const SizedBox(height: 12),
                                LinearProgressIndicator(value: _readProgress),
                                const SizedBox(height: 8),
                                Text(_readProgress == null
                                    ? AppLocalizations.of(context)
                                        .importPreparing
                                    : '${((_readProgress ?? 0) * 100).clamp(0, 100).toStringAsFixed(0)}%'),
                                const SizedBox(height: 12),
                                TextButton(
                                  onPressed: () {
                                    setState(() => _cancelRead = true);
                                  },
                                  child: Text(AppLocalizations.of(context)
                                      .commonCancel),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onImport() async {
    String csvText = _controller.text.trim();
    if (_picked != null) {
      csvText = await _readFileStreaming(_picked!);
      if (!mounted) return;
    }
    if (csvText.isEmpty) return; // 可能读取被取消
    if (!mounted) return;
    // 跳转到确认映射页，批量导入在新页面执行
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImportConfirmPage(
          csvText: csvText,
          hasHeader: _hasHeader,
          billType: _billType,
        ),
      ),
    );
    if (!mounted) return;
  }

  Future<void> _pickFile() async {
    try {
      // file_picker 12+：单选用 pickFile()（pickFiles 的 allowMultiple 已移除）；
      // withData 同样移除——需要字节时由 FileReaderService 经 readAsBytes() 取。
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['csv', 'tsv', 'txt', 'xlsx'],
      );
      if (!context.mounted) return;
      if (picked != null) {
        setState(() => _picked = picked);
        // 选中即进入确认页
        await _onImport();
        if (!context.mounted) return;
      }
    } on Exception catch (e) {
      if (!mounted) return;
      showToast(context,
          AppLocalizations.of(context).importFileOpenError(e.toString()));
    }
  }

  // 流式读取文件并显示进度（State 内部方法，可使用 setState）
  Future<String> _readFileStreaming(PlatformFile picked) async {
    if (!mounted) return '';

    setState(() {
      _reading = true;
      _readProgress = 0;
      _cancelRead = false;
    });

    try {
      final text = await FileReaderService.readFile(
        picked,
        onProgress: (progress) {
          if (_cancelRead) return;
          if (mounted) {
            setState(() {
              _readProgress = progress;
            });
          }
        },
        xlsxConverter: (bytes) {
          try {
            return XlsxReader.convertXlsxToCSV(bytes);
          } catch (e) {
            if (mounted) {
              showToast(
                context,
                AppLocalizations.of(context).importFileOpenError(e.toString()),
              );
            }
            return '';
          }
        },
      );

      if (mounted) {
        setState(() {
          _reading = false;
          _readProgress = null;
        });
      }

      return text;
    } catch (e) {
      if (mounted) {
        setState(() {
          _reading = false;
          _readProgress = null;
        });
        showToast(
          context,
          AppLocalizations.of(context).importFileOpenError(e.toString()),
        );
      }
      return '';
    }
  }
}

// 预览组件已移除
