import 'dart:ui';

/// 官网 URL 管理
///
/// 统一管理官网链接，方便未来域名变更
class WebsiteUrls {
  WebsiteUrls._();

  /// 官网基础域名
  /// 未来换域名时只需修改这里
  static const String baseUrl = 'https://count.beejz.com';

  /// 获取语言前缀
  /// 中文不需要前缀，英文需要 /en 前缀
  static String _langPrefix(Locale? locale) {
    if (locale == null) return '';
    // 简体中文和繁体中文使用默认路径
    if (locale.languageCode == 'zh') return '';
    // 其他语言使用 /en 路径
    return '/en';
  }

  /// 官网首页
  static String home([Locale? locale]) => '$baseUrl${_langPrefix(locale)}';

  /// 功能介绍
  static String docsFeature(String feature, [Locale? locale]) =>
      '$baseUrl${_langPrefix(locale)}/docs/features/$feature';

  /// 记账相关文档
  static String docsRecord(String topic, [Locale? locale]) =>
      '$baseUrl${_langPrefix(locale)}/docs/record/$topic';

  /// AI 相关文档
  static String docsAi(String topic, [Locale? locale]) =>
      '$baseUrl${_langPrefix(locale)}/docs/ai/$topic';

  /// FAQ
  static String faq([Locale? locale]) =>
      '$baseUrl${_langPrefix(locale)}/docs/faq';

  /// 隐私政策 — App 内嵌(embed)模式(隐藏 navbar/footer 外链,跟随暗黑与主题色)。
  static String privacy(Locale? locale,
          {required bool dark, required String primaryHex}) =>
      '$baseUrl${_langPrefix(locale)}/privacy'
      '?embed=1&theme=${dark ? 'dark' : 'light'}&primary=$primaryHex';
}
