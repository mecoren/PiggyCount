# flutter_market_data

PiggyCount 的**行情（market data）核心包**：只定义「行情源」的统一接口与模型，不含任何具体行情商实现。

定位与 [`flutter_cloud_sync`](../flutter_cloud_sync/README.md) 完全同构——核心包定契约，各后端/各行情商各写一个 provider 子包。

## 为什么先只做接口

持仓（`lib/data/db.dart` 的 `holdings`，v52）已经预留了接入实时行情所需的全部字段：

- **可同步**：`market`（SH / SZ / HK / US / FUND / CRYPTO）、`auto_quote`（该笔是否允许自动刷新）
- **本地专有**（不进快照、不进指纹、不写 `local_changes`）：`quote_price` / `quote_fetched_at` / `quote_source_id`

所以后期接入真实行情源 = **新增一个 provider 子包 + 在设置里能被选中**，
不需要改 schema、不需要升快照格式版本、不需要重走同步契约测试。

## 结构

```text
lib/
├── flutter_market_data.dart          # barrel
└── src/core/
    ├── quote.dart                    # Quote / QuoteRequest / QuoteRequestItem / QuoteMarket
    ├── quote_capability.dart         # QuoteCapability：支持的市场、是否批量、最小刷新间隔
    ├── quote_exception.dart          # QuoteException + QuoteErrorKind 分类
    ├── quote_provider.dart           # QuoteProvider 接口
    └── manual_quote_provider.dart    # ManualQuoteProvider：当前唯一实现（不发网络请求）
```

## 约束

- 本包**不得反向引用**应用主工程的 `lib/`（与 `packages/` 下其它子包同规矩）。
- 接口里**不出现面向用户的文案**：`providerName` 只是开发者可读名，
  设置页用 `providerId` 映射 l10n。
- 节流 / 缓存 / 落库都不属于本包：那是应用主工程 `QuoteService` 的职责。

## 新增一个行情源

1. 建子包 `packages/flutter_market_data_<vendor>/`，依赖本包；
2. 实现 `QuoteProvider`（`providerId` 用稳定的英文短标识，如 `eastmoney`）；
3. 在应用装配层（`lib/providers/quote_providers.dart`）注册，设置页自动出现该项；
4. 失败一律抛 `QuoteException` 并选对 `QuoteErrorKind`，编排层按类别降级。
