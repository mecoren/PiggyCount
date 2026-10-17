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

/// 回环地址（本地服务）判定：只有它们允许明文 HTTP。
///
/// 自建 AI（Ollama / LM Studio）常跑在 `http://127.0.0.1:11434`，
/// 本机回环不经过网络链路，放行不构成传输层风险；其余主机一律要求 HTTPS。
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' ||
      h == '127.0.0.1' ||
      h == '::1' ||
      h == '[::1]' ||
      h.endsWith('.localhost');
}

/// 传输安全 S5：`true` = 该地址会把凭据 / 数据放在明文或非 HTTP(S) 链路。
///
/// 用于用户可自配的端点（AI 服务商 Base URL 等）。规则：
/// - 空串 / 可省略协议：按 `https://` 补全后再判，不算不安全；
/// - `https://`：放行；
/// - `http://`：仅回环地址放行；
/// - 其它协议（`file://` / `ftp://` …）或无法解析：拒绝。
///
/// 云同步端点（WebDAV / S3 / Supabase）另有 provider 层硬校验，此处不替代。
bool isInsecureRemoteUrl(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return false;
  final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
  if (uri == null || uri.host.isEmpty) return true;
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') return false;
  if (scheme == 'http') return !isLoopbackHost(uri.host);
  return true;
}
