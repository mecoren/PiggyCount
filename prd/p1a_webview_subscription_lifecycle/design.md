# P1-A WebView / 订阅生命周期规范 — 设计文档

> 需求见同目录 `requirements.md`。落地提交：`7012c81`
> （`fix(lifecycle): P1-A WebView/订阅生命周期审计——清除单例 dispose 陷阱并成文规范`）。
> 改动面：`docs/contributing/CONTRIBUTING_{ZH,EN}.md`(+29/+33)、两个 WebView 页各 +3
> （审计结论注释）、`lib/services/payment/donation_service.dart`(+21/-13)。共 5 文件。

## 一、需求理解

这一项**主要是审计，不是改代码**。它的价值来自两条：

1. **把「无泄漏」这个结论本身变成可追溯的** —— 现状若无问题，最大的成本不是修，而是
   下一个人无法知道「已经有人看过了」，于是重新审一遍。所以结论必须就地留痕。
2. **在有泄漏的地方，泄漏形态往往是「多了一个不该有的释放方法」，而不是「少了一个」**
   （见决策 2）。审计必须对「看起来更安全」的写法保持怀疑。

## 二、审计结论（逐处）

### WebView（2 处）

| 页面 | 结论 | 依据 |
|---|---|---|
| `lib/pages/settings/privacy_policy_page.dart` | 无泄漏 | `webview_flutter` 4.x 的 `WebViewController` **无公开 dispose API**；原生视图由 `WebViewWidget` 挂载时创建、随其卸载自动释放 |
| `lib/pages/settings/help_center_page.dart` | 同上 | 同上 |

两页均在源码内补了「P1 生命周期审计（2026-09）」注释，记录结论与依据——
避免后续把「没有 dispose 调用」误读成「漏了 dispose」。

### StreamSubscription（按归属形态分四类）

| 形态 | 位置 | 收尾方式 | 判定 |
|---|---|---|---|
| 页面级 | `donation_page.dart` 双订阅（`_successSubscription` / `_errorSubscription`） | `dispose()` 中 cancel | ✓ |
| Provider 级 | `sync_providers.dart` `txTableSub2` | `ref.onDispose(() => sub?.cancel())` | ✓ |
| Repository 桥接流 | `local_transaction_repository.dart`（txSub / sharedCatSub / sharedAccSub）、`local_category_repository.dart`（×2）、`local_tag_repository.dart`（×2） | `onListen` 订阅 / `onCancel` 取消，成对闭合 | ✓ |
| 全局单例 | `app_link_service.dart` `_appIntentSubscription`（AppIntents EventChannel） | 生命周期随 app，**刻意不随页面取消** | ✓（已登记清单） |

## 三、关键技术决策

### 决策 1：判据是「订阅的归属形态」，不是「有没有 cancel()」

同一个 `StreamSubscription`，取消与不取消**都可能是对的**：

- 页面级订阅不取消 = 泄漏（返回再进入会叠加监听）。
- 全局单例订阅被取消 = **功能永久损坏**（见决策 2）。

所以审计不能停留在「搜 `StreamSubscription` 看有没有 `.cancel()`」，必须先判定归属，
再对照该形态的正确收尾方式。这也是规范为什么按**三种合法形态**写，而不是写一句
「订阅必须取消」——后者会诱导出决策 2 那种错误修复。

### 决策 2：删除 `DonationService.dispose()` —— 单例不得暴露整体释放方法

这是本次审计发现的**唯一真实缺陷，且缺陷形态是「多了一个方法」**：

- `DonationService` 是 **app 级单例**，却暴露了 `dispose()`：关闭广播
  `StreamController` + 取消 IAP `purchaseStream` 订阅。
- 它**没有任何调用方**（所以不会造成现行故障），但一旦被误调：
  1. **延迟补单 / 后台完成的购买事件永久丢失** —— 这些事件可能在该服务被"释放"之后才送达；
  2. 被 close 的广播 `StreamController` **无法复用**，单例就此永久致残（后续 `add()` 会抛）。
- 处置：**删除该方法**，并连带删除只为它存在的 `_subscription` 字段；类尾部加注释说明
  「为何刻意不提供 dispose（IAP 后台补单需 app 级存活）」。

**推广出的约定**（已写入规范）：全局单例**不得**暴露 `dispose()` 之类的整体释放方法——
单例的「释放」在语义上不存在（它不该被释放），提供该方法只是把一颗地雷放在那里。

### 决策 3：规范写进 `docs/contributing/`，中英双语同步

- 位置选 `docs/contributing/CONTRIBUTING_{ZH,EN}.md` 的代码规范章节，而不是 `prd/`：
  规范是**给未来改代码的人看的行为约束**，必须与提交规范、代码风格同处一份文档，
  否则没人会在写代码前想起来去翻 `prd/`。
- 中英两份**同构**（同一小节、同一份清单、同序条目）——双语文档最容易发生的就是
  一侧更新一侧遗忘，因此条目一一对应、便于核对。
- 三种合法形态各给一个**仓内范例文件**（`donation_page.dart` / `sync_providers.dart` /
  `local_transaction_repository.dart`），让规范可直接照抄。

### 决策 4：不引入自动检测（取舍记录）

Dart 生态没有现成的「`StreamSubscription` 未取消」静态规则；自建 analyzer 插件或脚本的
成本远超报告给本项的「工作量 小」定位，且这类检测天然容易误报（决策 1 说明取消与不取消
都可能正确）。因此以**清单 + code review** 治理，并接受「新订阅靠人判断」的代价。
若未来订阅数显著增长（例如 >30 处），再评估自动化。

## 四、实现步骤

1. 全量检索 `lib/` 下 `StreamSubscription` 与 `WebView*`，逐处判定归属形态。
2. 两个 WebView 页补审计结论注释（写明依据）。
3. 发现并修复 `DonationService.dispose()` 陷阱（删方法 + 删死字段 + 留注释）。
4. `CONTRIBUTING_ZH.md` / `CONTRIBUTING_EN.md` 新增小节：三种合法形态 + 全局单例订阅清单 +
   WebView 结论 + 「单例不得暴露整体 dispose」。
5. `flutter analyze` + 全量 `flutter test`。

## 五、边界条件与风险

| 风险 | 缓解 |
|------|------|
| **把「取消」当成万能正确解**，误取消单例订阅 → 功能永久损坏 | 规范按归属形态分三种合法形态（决策 1）；全局单例订阅单独列清单并写明「刻意不取消」 |
| 「无泄漏」的结论过一段时间失效（依赖升级后框架行为改变） | 结论注释**写明依据**（4.x 无 dispose API + 随 `WebViewWidget` 卸载释放）；升级 `webview_flutter` 主版本时应重审 |
| 双语规范一侧更新一侧遗忘 | 中英同构、条目一一对应（决策 3） |
| 新订阅仍靠人工判断，可能漏 | 接受；触发自动化的条件是订阅数显著增长（决策 4） |
| 「顺手重构」扩大改动面 | 非目标已明确：只改确认有缺陷的，审计不改归属形态 |
