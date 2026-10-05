import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/security/sensitive_note_service.dart';

/// 备注敏感标记本地存储服务（设备本地，不参与同步）。
final sensitiveNoteServiceProvider =
    Provider<SensitiveNoteService>((ref) => const SensitiveNoteService());

/// 变更 tick：标记 / 取消标记后自增，驱动 [sensitiveNoteIdsProvider] 刷新。
final sensitiveNoteRefreshProvider = StateProvider<int>((ref) => 0);

/// 敏感备注交易 id 集合（响应式）。
final sensitiveNoteIdsProvider = FutureProvider<Set<int>>((ref) async {
  ref.watch(sensitiveNoteRefreshProvider);
  return ref.watch(sensitiveNoteServiceProvider).load();
});
