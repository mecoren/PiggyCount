import 'package:shared_preferences/shared_preferences.dart';

/// 备注敏感标记的本地存储（**设备本地，不参与云同步 / 备份**）。
///
/// 为什么放 prefs 而不是给 `transactions` 加列：加列会进入快照协议
/// （`transactions_json` 字段白名单 / 指纹 / diff 契约），触碰线上格式按仓库
/// 约定属独立立项；而敏感标记只服务本机两件事 —— AI 外发脱敏与本地列表
/// 掩码 —— 天然是设备本地语义（与回收站、加密设置同定位）。代价明写：
/// 换设备 / 重装后标记不跟随，需要在该设备重新打标。
class SensitiveNoteService {
  const SensitiveNoteService();

  static const String prefsKey = 'sensitive_note_tx_ids';

  Future<Set<int>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(prefsKey) ?? const <String>[];
    return raw.map(int.tryParse).whereType<int>().toSet();
  }

  Future<bool> isSensitive(int transactionId) async =>
      (await load()).contains(transactionId);

  /// 标记 / 取消标记；返回更新后的集合。
  Future<Set<int>> setSensitive(int transactionId, bool sensitive) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(prefsKey) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    if (sensitive) {
      ids.add(transactionId);
    } else {
      ids.remove(transactionId);
    }
    await prefs.setStringList(
        prefsKey, ids.map((e) => e.toString()).toList());
    return ids;
  }

  /// 交易被彻底删除 / 账本清理时移除标记，避免无界增长。
  Future<void> purge(Iterable<int> transactionIds) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList(prefsKey) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    final before = ids.length;
    ids.removeAll(transactionIds);
    if (ids.length != before) {
      await prefs.setStringList(
          prefsKey, ids.map((e) => e.toString()).toList());
    }
  }
}
