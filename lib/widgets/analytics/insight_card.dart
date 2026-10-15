import 'package:flutter/widgets.dart';

/// 洞察卡片注册表条目（prd/analytics_card_registry）。
///
/// [build] 返回「卡片 + 其后置间距」的 widget 片段而非单卡 Widget：卡片间距
/// 并不均匀（排行榜卡与自定义字段卡之间现状无间距），片段化才能让 ListView
/// 的 children 序列与收编前逐节点一致（设计文档 §二.4 树形红线）。
class InsightCardDef {
  const InsightCardDef({
    required this.id,
    required this.visible,
    required this.build,
  });

  /// 卡片标识（调试与新增卡片时定位用）。
  final String id;

  /// 是否渲染。清单在 build 作用域组装，谓词值即当前帧的显隐结论。
  final bool visible;

  /// 卡片片段构建器（卡片 + 后置间距）。
  final List<Widget> Function() build;
}
