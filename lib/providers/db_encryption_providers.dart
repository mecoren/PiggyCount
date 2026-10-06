import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../data/encryption/local_db_encryption_service.dart';

/// 整库加密的开关编排服务（R2/R5/R6）。
final localDbEncryptionServiceProvider = Provider<LocalDbEncryptionService>(
    (ref) => const LocalDbEncryptionService());

/// 变更 tick：开关动作后自增，驱动 [localDbEncryptionStateProvider] 重读。
/// 与 `sensitiveNoteRefreshProvider` 同款手势。
final localDbEncryptionRefreshProvider = StateProvider<int>((ref) => 0);

/// 当前状态（只读）。UI 只 switch 它，不自己推导"开没开"。
final localDbEncryptionStateProvider =
    FutureProvider<LocalDbEncryptionState>((ref) async {
  ref.watch(localDbEncryptionRefreshProvider);
  return ref.watch(localDbEncryptionServiceProvider).state();
});
