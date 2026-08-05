import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import '../../widgets/biz/piggy_icon.dart';
import '../../widgets/ui/ui.dart';

/// 应用图标预览页 — 以大尺寸居中展示图标,同时保留与屏幕边缘的安全边距。
class AppIconPage extends ConsumerWidget {
  const AppIconPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.appName,
        showBack: true,
      ),
      body: Padding(
        // 留出状态栏与标题栏高度,让图标在可视区域内居中,不被 app bar 遮挡。
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 56,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 取可用宽高较小值,并留出四周边距,确保图标不会贴边。
            final availableSize = math.min(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            final iconSize = (availableSize - 32.0).clamp(200.0, 512.0);

            return Center(
              child: PiggyIcon(size: iconSize),
            );
          },
        ),
      ),
    );
  }
}
