// 统一的providers导出文件，方便统一导入所有providers

// 主题相关
export 'theme_providers.dart';

// 数据库相关  
export 'database_providers.dart';

// 统计相关
export 'statistics_providers.dart';

// 多币种相关
export 'currency_providers.dart';

// 同步相关
export 'sync_providers.dart';

// UI状态相关
export 'ui_state_providers.dart';

// 导入导出相关
export 'import_export_providers.dart';

// 更新相关
export 'update_providers.dart';

// 提醒相关
export 'reminder_providers.dart';

// 语言相关
export 'language_provider.dart';

// 小组件相关
export 'widget_provider.dart';

// 标签相关
export 'tag_providers.dart';

// 智能记账相关
export 'smart_billing_providers.dart';

// 快捷记账模式相关（P1-E）
export 'quick_entry_providers.dart';

// 日历节假日相关
export 'holiday_providers.dart';

// 备注敏感标记相关（设备本地，不参与同步）
export 'sensitive_note_providers.dart';

// 首页交易窗口（M2-a：keyset/limit + 日合计下沉 SQL）
export 'home_tx_window_providers.dart';

// 投资持仓（v52：持仓列表 / 折算汇总 / 行情汇率桥接）
export 'holding_providers.dart';

// 行情源装配（v52 预留：当前仅「手动录入」，零网络请求）
export 'quote_providers.dart';