import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import 'segmented_control.dart' show kPiggySelectableFillAlpha;

/// 「已应用」的可移除标签（筛选条件 / 已填选项）。
///
/// 为什么不用 Material 的 `InputChip` / `Chip`：它们吃 M3 默认值 —— 8 号默认
/// 圆角、`surface` 底色 + 中性描边、字号 14、左右各 8 的 label 留白，删除叉还是
/// `error` 红。塞进项目里跟同排的筛选入口（`OutlinedButton` 走主题 `radiusLg` +
/// 主色）并排时，圆角 / 配色 / 字号 / 高度四项全不一致，像是从别的 App 搬来的；
/// 洞察页筛选行曾因此出现「蓝色描边胶囊 + 白底灰边红叉胶囊」两种体系。
///
/// 本组件把四项都对齐到项目 token：
/// - 圆角 [PiggyDimens.radiusLg]（与主题里按钮同值），高度 32（与
///   `VisualDensity.compact` 的 `OutlinedButton` 齐平），文字放大时按需长高；
/// - 浅主色底（[kPiggySelectableFillAlpha]）+ 1px 主色描边 + 主色文字，与
///   `PiggySelectChip` / 分段控件的选中态同源；
/// - 字号 [PiggyTextTokens.fs12] / w600，删除叉 14 号主色 —— **刻意不用**
///   `error` 红：移除一条筛选条件不是破坏性操作，红色在数据页面上会抢走对数字的
///   注意力（与 `PiggyValueRow` 的「清除本行值」红色 X 语义不同，别照抄那边）。
class PiggyClosableChip extends StatelessWidget {
  const PiggyClosableChip({
    super.key,
    required this.label,
    required this.onDeleted,
    this.maxWidth = 240,
  });

  /// chip 文案（如「收入」「商户：咖啡」）。单行，超宽省略。
  final String label;

  /// 移除本条件（整枚 chip 唯一的可点区域是右侧的叉）。
  final VoidCallback onDeleted;

  /// 文案最大宽度。默认 240：筛选行里横滑或 `Wrap` 换行时，一条超长自定义
  /// 字段值不会把整行顶爆；被省略的完整值仍可从筛选抽屉里看到。
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final primary = PiggyTokens.primary(context);
    return Material(
      color: primary.withValues(alpha: kPiggySelectableFillAlpha),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        side: BorderSide(color: primary),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        // min 而非固定高：系统字号放大时跟着长高，不裁掉文字。
        constraints: const BoxConstraints(minHeight: 32),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(
                left: PiggyDimens.p12,
                top: PiggyDimens.p4,
                bottom: PiggyDimens.p4,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: PiggyTextTokens.fs12,
                    fontWeight: FontWeight.w600,
                    color: primary,
                  ),
                ),
              ),
            ),
            // 叉的命中区 26×26（图标 14，四周留 6）：比裸图标好点中，
            // 又不像 `IconButton` 那样按 48 把 chip 撑高。
            SizedBox(
              width: 26,
              height: 26,
              child: Semantics(
                button: true,
                label: MaterialLocalizations.of(context).deleteButtonTooltip,
                child: InkResponse(
                  onTap: onDeleted,
                  radius: 13,
                  child: Icon(Icons.close, size: 14, color: primary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
