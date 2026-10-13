# flutter_market_data_eastmoney

PiggyCount 的东方财富（Eastmoney）行情源子包：实现 [`flutter_market_data`](../flutter_market_data/README.md) 的 `QuoteProvider` 契约。

覆盖市场（免费公开、免密钥）：

- **A 股**：沪市（`SH`）、深市（`SZ`），6 位代码
- **港股**（`HK`），1~5 位代码左补零到 5 位
- **场外基金**（`FUND`），6 位代码

报价币种：A 股 / 基金 = CNY，港股 = HKD。**不含**美股 / 加密（东方财富免费接口不覆盖），编排层会按 `QuoteCapability.supports` 跳过。

## 结构

```text
lib/
├── flutter_market_data_eastmoney.dart   # barrel
└── src/
    ├── eastmoney_codec.dart             # 代码规范化 / secid / 价格缩放（纯函数）
    └── eastmoney_quote_provider.dart    # QuoteProvider 实现
```

## 约束

- 失败一律抛 `QuoteException`（`network` / `parse` / `unsupportedMarket`）；
- 「未命中」（代码合法但源无数据）不出现在返回 map，由编排层保留旧缓存；
- 不节流 / 不落库 —— 那是应用主工程 `QuoteService` 的职责。
