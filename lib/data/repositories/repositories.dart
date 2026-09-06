// Repository 基类和接口
export 'base_repository.dart';
export 'ledger_repository.dart';
export 'transaction_repository.dart';
export 'category_repository.dart';
export 'account_repository.dart';
export 'statistics_repository.dart';
export 'recurring_transaction_repository.dart';
export 'ai_repository.dart';
export 'tag_repository.dart';

// Local 实现
//
// 历史上还有 Cloud* 系列(数据完全存 Supabase)与「LocalRepository +
// ChangeTracker 推 PiggyCount Cloud」的实时协同范式;前者早已删除,
// 后者已随云端协同下线移除。现仅保留 LocalRepository(离线优先 +
// 快照同步),这里不再 export 其它实现。
export 'local/local_repository.dart';
export 'local/local_ledger_repository.dart';
export 'local/local_transaction_repository.dart';
export 'local/local_category_repository.dart';
export 'local/local_account_repository.dart';
export 'local/local_statistics_repository.dart';
export 'local/local_tag_repository.dart';
