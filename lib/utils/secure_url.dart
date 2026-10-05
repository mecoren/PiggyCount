/// 云同步地址的纯传输安全 helper。
///
/// 连接测试层（Supabase / WebDAV）早已硬拦非 HTTPS（见
/// `cloud_service_page.dart` 的 SEC-01/SEC-02），这里把同一口径前移到
/// 输入层：显式 `http://` 内联报错；缺协议自动补 `https://`。
bool isExplicitHttpUrl(String raw) {
  final text = raw.trim();
  if (!text.contains('://')) return false;
  return Uri.tryParse(text)?.scheme.toLowerCase() == 'http';
}

/// 缺协议时补 `https://`，其余原样返回（含显式 `http://`，由调用方报错）。
String normalizeCloudUrl(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text.contains('://')) return text;
  return 'https://$text';
}
