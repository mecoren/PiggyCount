/// 备注敏感标记的统一脱敏口径（纯函数，便于单测与跨处复用）。
///
/// 设计口径：
/// - 敏感备注在**外发**（AI 提示词）与**列表展示**时一律以**固定掩码**呈现；
/// - 掩码不保留原文长度 —— 否则「字数」本身就是一条侧信道。
class SensitiveDataMasker {
  SensitiveDataMasker._();

  /// 固定掩码（与原文长度无关）。
  static const String mask = '••••';

  /// 敏感备注 → 掩码；null / 空串原样返回空串（不显示掩码）。
  static String maskNote(String? note) {
    if (note == null || note.isEmpty) return '';
    return mask;
  }

  /// 按是否敏感决定：敏感 → 掩码，否则原样（null → 空串）。
  static String maskNoteIf(bool sensitive, String? note) =>
      sensitive ? maskNote(note) : (note ?? '');
}
