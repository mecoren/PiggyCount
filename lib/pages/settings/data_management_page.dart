import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../data/import_page.dart';
import '../data/export_page.dart';
import '../category/category_manage_page.dart';
import '../category/category_migration_page.dart';
import '../tag/tag_manage_page.dart';
import '../settings/config_import_export_page.dart';
import '../settings/storage_management_page.dart';
import '../settings/attachment_preview_page.dart';
import '../maintenance/orphan_cleanup_page.dart';
import '../../l10n/app_localizations.dart';
import '../../services/attachment_export_import_service.dart';

/// 数据管理二级页面
class DataManagementPage extends ConsumerStatefulWidget {
  const DataManagementPage({super.key});

  @override
  ConsumerState<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends ConsumerState<DataManagementPage> {
  bool _isExporting = false;
  bool _isImporting = false;
  int _exportProgress = 0;
  int _exportTotal = 0;
  int _exportAttachmentCount = 0;
  int _exportIconCount = 0;
  int _importProgress = 0;
  int _importTotal = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.dataManagementPageTitle,
        showBack: true,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          PiggyTokens.topScrollablePadding(context, extra: 16),
          16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          // 提示文案
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              l10n.dataManagementAttachmentHint,
              style: PiggyTextTokens.label(context)
                  .copyWith(color: PiggyTokens.textTertiary(context)),
            ),
          ),
          // 导入导出
          SettingsCard(
            children: [
              // 导入数据
              Consumer(builder: (ctx, r, _) {
                final p = r.watch(importProgressProvider);
                if (!p.running && p.total == 0) {
                  return SettingsNavItem(
                    icon: Icons.file_upload_outlined,
                    title: l10n.mineImport,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ImportPage()),
                      );
                    },
                  );
                }
                if (p.running) {
                  final percent =
                      p.total == 0 ? null : (p.done / p.total).clamp(0.0, 1.0);
                  return SettingsNavItem(
                    icon: Icons.upload_outlined,
                    title: l10n.mineImportProgressTitle,
                    subtitle: l10n.mineImportProgressSubtitle(
                        p.done, p.fail, p.ok, p.total),
                    trailing: SizedBox(
                        width: 72,
                        child: LinearProgressIndicator(value: percent)),
                    enabled: false,
                  );
                }
                final allOk = (p.done == p.total) && (p.fail == 0);
                if (allOk) return const _ImportSuccessTile();
                return SettingsNavItem(
                  icon: Icons.info_outline,
                  title: l10n.mineImportCompleteTitle,
                  subtitle:
                      '${l10n.commonSuccess} ${p.ok}，${l10n.commonFailed} ${p.fail}',
                  enabled: false,
                );
              }),
              // 导出数据
              SettingsNavItem(
                icon: Icons.file_download_outlined,
                title: l10n.mineExport,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ExportPage()),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 附件导出导入
          _buildAttachmentSection(context, ref),
          const SizedBox(height: 16),
          // 分类管理
          SettingsCard(
            children: [
              // 分类管理
              SettingsNavItem(
                icon: Icons.category_outlined,
                title: l10n.mineCategoryManagement,
                subtitle: l10n.mineCategoryManagementSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const CategoryManagePage()),
                  );
                },
              ),
              // 分类迁移
              SettingsNavItem(
                icon: Icons.swap_horiz,
                title: l10n.mineCategoryMigration,
                subtitle: l10n.mineCategoryMigrationSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const CategoryMigrationPage()),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 标签管理
          SettingsCard(
            children: [
              SettingsNavItem(
                icon: Icons.label_outline,
                title: l10n.tagManageTitle,
                subtitle: l10n.tagManageSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TagManagePage()),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 配置管理
          SettingsCard(
            children: [
              // 配置导入导出
              SettingsNavItem(
                icon: Icons.settings_backup_restore,
                title: l10n.configImportExportTitle,
                subtitle: l10n.configImportExportSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const ConfigImportExportPage()),
                  );
                },
              ),
              // 存储空间管理
              SettingsNavItem(
                icon: Icons.storage_outlined,
                title: l10n.storageManagementTitle,
                subtitle: l10n.storageManagementSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const StorageManagementPage()),
                  );
                },
              ),
              // 数据清理(孤儿数据)
              SettingsNavItem(
                icon: Icons.cleaning_services_outlined,
                title: l10n.maintenanceOrphanCleanupTitle,
                subtitle: l10n.maintenanceOrphanCleanupSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const OrphanCleanupPage()),
                  );
                },
              ),
            ],
          ),
          // 应用锁已挪到「个性化设置」页面(语义上属于应用偏好)。
        ],
      ),
    );
  }

  // ============================================
  // 附件导出导入相关
  // ============================================

  Widget _buildAttachmentSection(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final primary = ref.watch(primaryColorProvider);

    return SettingsCard(
      children: [
        // 导出附件
        SettingsNavItem(
          icon: Icons.upload_file,
          title: l10n.attachmentExportTitle,
          subtitle: l10n.attachmentExportSubtitle,
          trailing: _isExporting
              ? SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: primary,
                  ),
                )
              : IconButton(
                  icon: Icon(Icons.preview, color: primary),
                  onPressed: _handleExportPreview,
                ),
          onTap: _isExporting ? null : _handleExport,
          enabled: !_isExporting,
        ),
        // 导出进度
        if (_isExporting && _exportTotal > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: _exportProgress / _exportTotal,
                  backgroundColor: PiggyTokens.divider(context),
                  color: primary,
                ),
                const SizedBox(height: 4),
                Text(
                  _exportAttachmentCount > 0 || _exportIconCount > 0
                      ? l10n.attachmentExportProgressDetail(
                          _exportAttachmentCount,
                          _exportIconCount,
                          _exportProgress,
                          _exportTotal,
                        )
                      : l10n.attachmentExportProgress(
                          _exportProgress, _exportTotal),
                  style: PiggyTextTokens.label(context),
                ),
              ],
            ),
          ),
        // 导入附件
        SettingsNavItem(
          icon: Icons.download,
          title: l10n.attachmentImportTitle,
          subtitle: l10n.attachmentImportSubtitle,
          trailing: _isImporting
              ? SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: primary,
                  ),
                )
              : null,
          onTap: _isImporting ? null : _selectImportFile,
          enabled: !_isImporting,
        ),
        // 导入进度
        if (_isImporting && _importTotal > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: _importProgress / _importTotal,
                  backgroundColor: PiggyTokens.divider(context),
                  color: primary,
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.attachmentImportProgress(_importProgress, _importTotal),
                  style: PiggyTextTokens.label(context),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 预览即将导出的附件和自定义图标
  Future<void> _handleExportPreview() async {
    final service = ref.read(attachmentExportImportServiceProvider);
    final previewData = await service.getExportPreviewImages();

    if (!mounted) return;

    if (previewData.isEmpty) {
      showToast(context, AppLocalizations.of(context).attachmentExportEmpty);
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AttachmentPreviewPage(
          exportData: previewData,
          title: AppLocalizations.of(context).attachmentExportPreviewTitle,
        ),
      ),
    );
  }

  Future<void> _handleExport() async {
    final l10n = AppLocalizations.of(context);
    final service = ref.read(attachmentExportImportServiceProvider);

    // 先获取实际存在的文件数用于进度显示
    final previewData = await service.getExportPreviewImages();
    final attachmentCount = previewData.attachments.length;
    final iconCount = previewData.customIcons.length;
    final actualFileCount = attachmentCount + iconCount;

    setState(() {
      _isExporting = true;
      _exportProgress = 0;
      _exportTotal = actualFileCount; // 使用实际文件数（附件 + 图标）
      _exportAttachmentCount = attachmentCount;
      _exportIconCount = iconCount;
    });

    final exportPath = await service.exportAttachments(
      onProgress: (current, total) {
        if (mounted) {
          setState(() {
            _exportProgress = current;
            _exportTotal = total;
          });
        }
      },
    );

    setState(() {
      _isExporting = false;
    });

    if (!mounted) return;

    if (exportPath != null) {
      showToast(context, l10n.attachmentExportSuccess);

      // iOS 弹出分享
      if (Platform.isIOS) {
        await Share.shareXFiles([XFile(exportPath)]);
      } else {
        // Android 显示保存路径
        showToast(context, l10n.attachmentExportSavedTo(exportPath));
      }
    } else {
      // exportPath 为 null 表示没有内容需要导出
      showToast(context, l10n.attachmentExportEmpty);
    }
  }

  Future<void> _selectImportFile() async {
    final pickerResult = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['gz', 'tar'],
    );

    if (pickerResult == null || pickerResult.files.isEmpty) return;

    final filePath = pickerResult.files.first.path;
    if (filePath == null) return;

    final service = ref.read(attachmentExportImportServiceProvider);
    final info = await service.previewArchive(filePath);

    if (!mounted) return;

    if (info == null) {
      showToast(context, AppLocalizations.of(context).attachmentImportFailed);
      return;
    }

    // 显示确认弹窗
    final dialogResult = await _showImportConfirmDialog(filePath, info);
    if (dialogResult == null) return;
    if (!mounted) return;

    final conflictStrategy = dialogResult['strategy'] as String;
    final shouldPreview = dialogResult['preview'] as bool? ?? false;

    if (shouldPreview) {
      // 显示预览
      await _handleImportPreview(filePath);
    } else if (conflictStrategy ==
        AttachmentExportImportService.conflictOverwrite) {
      // 覆盖策略破坏性强：双重危险确认（各 3 秒倒计时）后才导入。
      // 跳过策略不动现有文件，保持原有单次确认即可。
      // l10n 提前取：确认弹窗 await 后再取需重新判 mounted
      final l10n = AppLocalizations.of(context);
      final reconfirmed = await showDoubleDangerConfirmDialog(
        context,
        title: l10n.attachmentImportReconfirmTitle,
        firstMessage: l10n.attachmentImportReconfirmMessage,
        secondMessage: l10n.attachmentImportReconfirmMessage,
        countdownSeconds: 3,
      );
      if (!mounted) return;
      if (reconfirmed) {
        await _handleImport(filePath, info, conflictStrategy);
      }
    } else {
      // 直接导入（跳过策略）
      await _handleImport(filePath, info, conflictStrategy);
    }
  }

  /// 预览归档中的附件和自定义图标
  Future<void> _handleImportPreview(String filePath) async {
    final service = ref.read(attachmentExportImportServiceProvider);
    final previewData = await service.getArchivePreviewImages(filePath);

    if (!mounted) return;

    if (previewData.isEmpty) {
      showToast(context, AppLocalizations.of(context).attachmentPreviewEmpty);
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AttachmentPreviewPage(
          archiveData: previewData,
          title: AppLocalizations.of(context).attachmentImportPreviewTitle,
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _showImportConfirmDialog(
    String filePath,
    AttachmentArchiveInfo info,
  ) async {
    final l10n = AppLocalizations.of(context);
    final primary = ref.read(primaryColorProvider);
    String conflictStrategy = AttachmentExportImportService.conflictSkip;

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text(l10n.attachmentImportTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 文件名
                  Row(
                    children: [
                      Icon(Icons.archive, size: 20, color: primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          filePath.split('/').last,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 归档信息
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.attachmentArchiveInfo(
                          info.count,
                          info.exportedAt != null
                              ? DateFormat('yyyy-MM-dd HH:mm')
                                  .format(info.exportedAt!)
                              : '-',
                        ),
                        style: PiggyTextTokens.body(ctx)
                            .copyWith(color: PiggyTokens.textSecondary(ctx)),
                      ),
                      if (info.customIconCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '自定义图标: ${info.customIconCount} 个',
                            style: PiggyTextTokens.body(ctx).copyWith(
                                color: PiggyTokens.textSecondary(ctx)),
                          ),
                        ),
                      if (info.hasAvatar)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '包含头像',
                            style: PiggyTextTokens.body(ctx).copyWith(
                                color: PiggyTokens.textSecondary(ctx)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // 冲突策略
                  Text(
                    l10n.attachmentImportConflictStrategy,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  // 跳过选项
                  RadioListTile<String>(
                    title: Text(l10n.attachmentImportConflictSkip,
                        style: const TextStyle(fontSize: 14)),
                    value: AttachmentExportImportService.conflictSkip,
                    groupValue: conflictStrategy,
                    onChanged: (v) {
                      if (v != null) {
                        setDialogState(() => conflictStrategy = v);
                      }
                    },
                    activeColor: primary,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    visualDensity: VisualDensity.compact,
                  ),
                  // 覆盖选项
                  RadioListTile<String>(
                    title: Text(l10n.attachmentImportConflictOverwrite,
                        style: const TextStyle(fontSize: 14)),
                    value: AttachmentExportImportService.conflictOverwrite,
                    groupValue: conflictStrategy,
                    onChanged: (v) {
                      if (v != null) {
                        setDialogState(() => conflictStrategy = v);
                      }
                    },
                    activeColor: primary,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: Text(l10n.commonCancel),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop({
                    'strategy': conflictStrategy,
                    'preview': true,
                  }),
                  child: Text(l10n.attachmentPreview),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop({
                    'strategy': conflictStrategy,
                    'preview': false,
                  }),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(l10n.attachmentStartImport),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _handleImport(
    String filePath,
    AttachmentArchiveInfo info,
    String conflictStrategy,
  ) async {
    final l10n = AppLocalizations.of(context);
    final service = ref.read(attachmentExportImportServiceProvider);

    setState(() {
      _isImporting = true;
      _importProgress = 0;
      _importTotal = info.count;
    });

    final result = await service.importAttachments(
      archivePath: filePath,
      conflictStrategy: conflictStrategy,
      onProgress: (current, total) {
        if (mounted) {
          setState(() {
            _importProgress = current;
            _importTotal = total;
          });
        }
      },
    );

    setState(() {
      _isImporting = false;
    });

    if (!mounted) return;

    if (result.success) {
      // 构建详细的导入结果消息
      final parts = <String>[];

      // 交易附件结果
      if (result.imported > 0 ||
          result.skipped > 0 ||
          result.overwritten > 0 ||
          result.failed > 0) {
        parts.add(l10n.attachmentImportResult(
          result.imported,
          result.skipped,
          result.overwritten,
          result.failed,
        ));
      }

      // 头像导入结果
      if (result.avatarImported) {
        parts.add('头像已导入');
      }

      // 自定义图标导入结果
      if (result.customIconsImported > 0 || result.customIconsSkipped > 0) {
        parts.add(
            '自定义图标：导入${result.customIconsImported}个${result.customIconsSkipped > 0 ? '，跳过${result.customIconsSkipped}个' : ''}');
      }

      // 如果没有任何导入结果，显示提示
      if (parts.isEmpty &&
          !result.avatarImported &&
          result.customIconsImported == 0) {
        parts.add('未导入任何内容');
      }

      showToast(context, parts.join('；'));
    } else {
      showToast(context, result.message ?? l10n.attachmentImportFailed);
    }
  }
}

// 导入完成后的短暂动画提示：线性进度条从 0 -> 100%
class _ImportSuccessTile extends StatelessWidget {
  const _ImportSuccessTile();

  @override
  Widget build(BuildContext context) {
    final primary = PiggyTokens.primary(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (ctx, v, child) {
        return SettingsNavItem(
          icon: Icons.check_circle_outline,
          title: AppLocalizations.of(ctx).mineImportCompleteTitle,
          subtitle: AppLocalizations.of(ctx).mineImportCompleteAllSuccess,
          trailing: SizedBox(
            width: 72,
            child: LinearProgressIndicator(
              value: v,
              valueColor: AlwaysStoppedAnimation(primary),
            ),
          ),
        );
      },
    );
  }
}
