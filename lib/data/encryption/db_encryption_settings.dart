import 'package:shared_preferences/shared_preferences.dart';

/// 整库加密的**非机密**开关意图（R6 关闭路径）。
///
/// 为什么不直接删密钥来表示"关闭"：删了密钥，密文库就再也打不开了 —— 关闭必须
/// 是"下次启动先把库解回明文、成功了再删钥匙"。于是在"用户已点关闭"到"下次启动
/// 真正执行"之间，需要一个跨进程存活的意图标记。它本身不是机密（知道它也无法
/// 解密），所以放 prefs 而不是安全区。
///
/// 顺序很重要：**先写意图，重启后由 [DbEncryptionMigration] 执行解密，成功才删钥**。
/// 反过来（先删钥再解）在中途崩溃时会直接丢数据。
class DbEncryptionSettings {
  const DbEncryptionSettings();

  /// prefs 键名。**一旦发布不可改**：改了等于丢掉"待关闭"意图（用户以为关了、
  /// 其实还在加密）。
  static const String disableRequestedKey = 'db_encryption_disable_requested';

  /// 读取"待关闭"意图。
  ///
  /// **读不到一律当"没有"**：本方法在**开库路径**上被调用（见
  /// `DbEncryptionMigration.prepareKeyForOpen`），抛异常等于应用起不来；而两个
  /// 方向的后果不对称 —— 误判成"有待关闭"会在用户没要求的情况下解密一份加密库，
  /// 误判成"没有"最多是"这次没关成，下次再点一次"。所以这里吞异常并留痕。
  Future<bool> isDisableRequested() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(disableRequestedKey) ?? false;
    } catch (e) {
      // 不引 logger：本类处于 data 层最内圈，且开库路径上的日志已由迁移侧记录。
      return false;
    }
  }

  /// 用户点了"关闭整库加密"：登记意图，等下次启动执行。
  Future<void> requestDisable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(disableRequestedKey, true);
  }

  /// 意图已兑现（或放弃）后清掉。
  Future<void> clearDisableRequest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(disableRequestedKey, false);
  }

  /// 「本机曾启用过整库加密」标记。
  ///
  /// 用途只有一个，但很关键：**把"加密库缺钥"与"文件根本不是库"区分开**。
  /// 两者在文件层面长得一样（前 16 字节都不是明文 SQLite 头），可处置动作却
  /// 完全相反 —— 前者不能隔离（那是唯一可能被解开的副本），后者恰恰需要隔离
  /// 重置。没有这个标记就只能靠猜，而猜错的代价是让用户把还能挽回的密文当
  /// 垃圾搬走。
  static const String wasEnabledKey = 'db_encryption_was_enabled';

  /// 读不到一律当 false：false 会走既有的"损坏/不可读"分支（审计 P1-6 原有
  /// 行为），比误报成"加密库缺钥"更保守。
  Future<bool> wasEverEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(wasEnabledKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 用户开启加密时登记。
  Future<void> markEverEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(wasEnabledKey, true);
  }

  /// 关闭加密**成功**后清掉（失败不清：库还是密文，标记必须留着）。
  Future<void> clearEverEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(wasEnabledKey, false);
  }
}
