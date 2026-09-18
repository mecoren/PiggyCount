# P1-B 后台链路统一异常出口 — 设计文档

> 需求见同目录 `requirements.md`。落地提交：`3658b85`
> （`fix(observability): P1-B 后台链路统一异常出口——新增 unawaitedLog 封装，统计页查询失败渲染错误态`）。
> 改动面 6 文件 +132/-61：`logger_service.dart`、`app.dart`、`transactions_sync_manager.dart`、
`accounts_page.dart`、`analytics_page.dart`、`attachment_preview_page.dart`。

## 一、需求理解

两条线，都是「把静默失败变成有出口的失败」：

- **后台线**：不改变 fire-and-forget 的执行语义（不改「不阻塞前台」这个前提），
  只把异常**收进日志**。核心是给「吞掉」这个行为加上**上下文**与**可检索性**。
- **前台线**：给查询失败补一个画面（错误提示 + 重试），把「无限转圈」这个最坏的失败形态
  （用户无法自我解释、也无法自救）消掉。

## 二、关键技术决策

### 决策 1：封装成顶层函数，而不是扩展方法或工具类

`unawaitedLog` 是 `lib/services/system/logger_service.dart` 末尾的顶层函数（同文件已导出
全局 `logger`）：

```dart
void unawaitedLog(Future<void> future, String context) {
  unawaited(() async {
    try {
      await future;
    } catch (e, st) {
      logger.warning('Unawaited', '$context 失败（后台链路，不阻塞前台）: $e\n$st');
    }
  }());
}
```

选顶层函数而非 `Future` 扩展或 `AsyncUtils` 类，理由是本项目的既有习惯：**日志相关能力
与 `logger` 放同一处**，调用方一行 import 即可，不必额外记住一个工具类的名字。签名刻意
保持最小（future + context），不做可配置的日志级别/是否重试——需要那些的链路本来就不该用它。

### 决策 2：固定 tag `Unawaited`，让失败可聚合

日志 tag 写死 `'Unawaited'`，与调用方各自的业务 `context` 分开。这样：

- 按 tag 检索 = 「所有后台链路失败」的完整清单（**一个 grep 拿到全貌**）；
- `context` 提供「是哪个动作」，文案格式统一为 `'$context 失败（后台链路，不阻塞前台）: ...'`，
  括号里那句是**给下一个读日志的人**解释「为什么这里没有把错误抛给用户」。

`context` 由调用方写明业务动作，规范上不允许写「保存失败」这类无主语文案——否则
日志仍然无法定位。

### 决策 3：不改变「不阻塞」语义 —— 用 `unawaited` 包一层 async 闭包

实现上仍然是 `unawaited(...)`，只是被包的闭包内部 `try/catch`。这一点是刻意的：

- 调用方（UI 回调、拖拽结束、页面退出）的时序与改造前**逐帧一致**，没有引入新的 await；
- 因此本改造不会带来任何可感知的交互变化，回归面极小 —— 这是它值得先做的前提。

### 决策 4：涉及 `BuildContext` 的链路必须补 `mounted` 守卫

附件回执等链路在异步回调里使用了页面的 `context`（弹提示/跳转）。加了 `unawaitedLog`
后异常被吞，但**异步回调本身仍可能在页面销毁后执行**——因此接入时一并补 `mounted` 守卫
（AC-R2 #2）。这与项目里既有的 `use_build_context_synchronously` 治理
（提交 `340242d`）是同一条原则，只是这条链路此前被 `unawaited` 掩盖了。

### 决策 5：`unawaitedLog` 的适用边界（写进文档，防止被误用）

它**只适用于「失败也不影响正确性、只需留痕」的链路**。判断标准是一句话：

> 如果这个操作失败了，用户是否需要知道？如果需要 → 不要用 `unawaitedLog`，
> 走 `await` + 显式错误处理；如果不需要 → 用它。

反例：交易写入、同步主流程、账本删除。这些链路失败必须让用户看到，用 `unawaitedLog`
会把「必须被知道的失败」降级成「一条没人看的日志」。这条边界写进了
`requirements.md` 的非目标，因为它是这个封装最容易被滥用的方向。

### 决策 6：错误态必须带「重试」，且重试靠既有刷新 provider 驱动

`analytics_page` 的 `hasError` 分支渲染错误提示 + 重试按钮，重试**不新写查询逻辑**，
而是 bump 既有的 `statsRefreshProvider` 触发重查 —— 与页面其它刷新入口共用同一条链路。
这样避免出现「第二条查询路径」（两条路径的数据口径/过滤条件容易漂移）。

只给文案不给重试入口是不够的：查询失败时用户唯一的自救手段本就是「重进页面」，
若界面不提供按钮，我们就只是把沉默的转圈换成了沉默的文案。

## 三、实现步骤

1. `logger_service.dart` 新增 `unawaitedLog`（决策 1、2）。
2. 逐处替换裸 `unawaited` 后台链路，写明业务 `context`：
   `app.dart`（深链持久化）、`transactions_sync_manager.dart`（启动期附件补齐）、
   `accounts_page.dart`（拖拽排序落库）、`attachment_preview_page.dart`（大图关闭回执）。
3. `attachment_preview_page` 的异步回执补 `mounted` 守卫（决策 4）。
4. `analytics_page` 补 `hasError` 错误态 + 重试（决策 6）。
5. `flutter analyze` + 全量 `flutter test`。

## 四、边界条件与风险

| 风险 | 缓解 |
|------|------|
| **被误用于需要错误传播的链路** → 把「必须让用户知道的失败」降级成一条日志 | 决策 5 的适用边界写进 `requirements.md` 非目标；判断标准是一条可判定的问句 |
| 日志被 `context` 文案质量问题废掉（写成无主语） | 规范要求 `context` 写明业务动作；AC-R2 #1 以此为验收口径 |
| `mounted` 守卫遗漏 → 页面销毁后二次抛错 | AC-R2 #2；接入时逐处检查是否使用 `context` |
| 重试入口变成第二条查询路径 | 决策 6：只 bump 既有 `statsRefreshProvider`，不新写查询 |
| 改造引入交互时序变化 | 决策 3：仍是 `unawaited`，无新增 await，时序与改造前一致 |
| 后台异常从此只进日志、无人跟进 | 与 rec 13（运行时性能/错误监控接入）衔接；本项只负责「有出口」，不负责「有看板」 |
