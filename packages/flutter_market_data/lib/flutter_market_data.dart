/// PiggyCount 行情（market data）核心包 —— **纯接口层**。
///
/// 定位与 `flutter_cloud_sync` 完全同构：本包只定义「行情源」统一接口与模型，
/// 不包含任何具体行情商的实现，也**不得反向引用应用主工程的 `lib/`**。
///
/// 后期接入真实行情源的正确姿势：新增一个 provider 子包
/// （如 `flutter_market_data_eastmoney` / `_yahoo` / `_coingecko`），
/// 实现 [QuoteProvider] 并在应用装配层注册即可 —— 不需要改数据库 schema、
/// 不需要升快照格式版本、不需要改同步契约（持仓表在 v52 已预留
/// `market` / `auto_quote` 可同步列与三个本地专有行情缓存列）。
library;

export 'src/core/quote.dart';
export 'src/core/quote_capability.dart';
export 'src/core/quote_exception.dart';
export 'src/core/quote_provider.dart';
export 'src/core/manual_quote_provider.dart';
