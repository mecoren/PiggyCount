# P2-A 静态分析清零 + CI 基线 — 设计文档

## 一、需求理解

评估报告（2026-09-17）第 11 条：668 条静态分析存量里 207 条
`unnecessary_non_null_assertion` 可一键修复、50 条 deprecated 用法阻塞依赖
升级；并要求在 CI 中把 analyzer 锁成「不新增」，存量逐步消化。

本轮直接做到**清零**（0 error / 0 warning / 0 info），因此 CI 门禁用
「任何一条即失败」，不再需要「允许存量」的基线文件。

## 二、关键技术决策

### 决策 1：先 `dart fix --apply`，再人工复核，最后才敢锁 CI

自动修复一次改了 89 个文件 323 处。但 `dart fix` 的
`unused_element_parameter` 修复存在缺陷：它删除构造参数后会残留初始化列表
片段，且分隔符写成 `:` 而非 `,`，直接产出语法错误。本轮实测两处
（`update_result.dart` 私有构造、`category_manage_page.dart` 的
`_CategoryItem`）被改坏，靠 `flutter analyze` 的 error 级输出抓出后手工修回。
**结论：`dart fix` 之后必须跑一次 analyze 并确认 0 error，不能直接提交。**

### 决策 2：`avoid_print` 按「是否为 CLI/示例」分流，不做一刀切豁免

| 位置 | 处理 | 理由 |
|------|------|------|
| `scripts/i18n/check_status.dart` | `// ignore_for_file: avoid_print` | 命令行工具，print 就是输出通道 |
| `packages/flutter_cloud_sync/example/**` | 同上 | 示例程序，控制台即输出 |
| `packages/flutter_ai_kit{,_zhipu}/lib/**` | 新增 `debugLog(() => ...)` 替 `print` | 库代码，release 不该往 stdout 吐内部状态 |
| 根 `test/cloud/s3_roundtrip_consistency_test.dart` | 单行 `// ignore:` | 落盘报告同时打屏，供 CI 查看 |

不采用 `analyzer.exclude: scripts/**`：那会让这几个文件彻底失去类型检查，
而它们恰恰是「无人 review 的脚本」，更需要分析器兜底。

### 决策 3：`debugLog` 用 `assert` 短路 + 闭包参数

```dart
void debugLog(String Function() buildMessage) {
  assert(() { debugPrint(buildMessage()); return true; }());
}
```

- `assert` 的参数在 release 编译期整段移除 → 闭包本身不被创建，零开销；
- 以**闭包**而非 `String` 为参数：`debugLog('x=$x')` 这种写法在 release 仍会
  拼串，闭包写法连插值都不发生（zhipu 的调试日志在每次请求的主路径上）。

### 决策 4：deprecated_member_use 分三类迁移，不逐条 `// ignore`

| 家族 | 数量 | 迁移 |
|------|------|------|
| `RadioListTile.groupValue/onChanged` | 30 | 上提为 `RadioGroup` 祖先 |
| `Share.share/shareXFiles` | 18 | `SharePlus.instance.share(ShareParams(...))` |
| `ProviderScope.parent` | 1 | `UncontrolledProviderScope(container: ...)` |
| Supabase `anonKey` | 1 | `publishableKey` |

`RadioGroup` 迁移的原则：**包住逻辑组整体，不逐 tile 包**。逐 tile 包会生成
单元素组，`RadioGroup` 内部的 `_SkipUnselectedRadioPolicy` 会把「未选中的
单个 radio」排除出 Tab 焦点序列 → 键盘可达性反而退化。

### 决策 5：`ProviderScope.parent` 不只是弃用问题，是双容器缺陷

`ProviderScope(parent: x)` 在 `initState` 里执行
`ProviderContainer(parent: x, observers: widget.observers)`——**新建一个子
容器**。而 `main.dart` 里 `container` 被显式创建并传给后台任务链
（`_setupUrlListener(container)`、`_runOrphanFileGcPeriodic(container)` 等）。
于是：① widget 侧与后台侧读写的是两份独立 state；② 子容器未继承 observers，
`_WidgetUpdateObserver` 只看得见后台侧。改用 `UncontrolledProviderScope`
（这正是 `ProviderScope.build` 内部返回的同一个组件）一并修掉。

## 三、实现步骤

1. `dart fix --apply` → `flutter analyze` 抓 error → 手工修回 2 处被改坏的构造。
2. avoid_print 分流处理（见决策 2），新增 `flutter_ai_kit/lib/src/utils/debug_log.dart` 并从包入口导出。
3. `unintended_html_in_doc_comment` 13 处：doc 注释里的 `<...>` 加反引号。
4. deprecated 四家族迁移（见决策 4）。
5. 死代码清理：`unused_element` 7 个（含 app.dart 里已被新实现取代的
   同步完成 toast 聚合方法及其 3 个残留字段）、`unused_local_variable`、
   `unused_field`、语义已死的 `?? 0.0` / 恒真 `if` 外壳等。
6. 新增 `.github/workflows/analyze.yml`，`flutter analyze --fatal-infos` 锁 0。
7. 验证：`flutter analyze` 0 条；全量 `flutter test` 1184 passed / 1 skipped。

## 四、边界条件与风险

| 风险 | 缓解 |
|------|------|
| `dart fix` 改坏语法 | 每轮 fix 后必跑 analyze 确认 0 error（本轮实测 2 处） |
| RadioGroup 迁移改变已有布局 | 包住原容器整体；需要独立 Column 时显式 `mainAxisSize.min` + `crossAxisAlignment.stretch`，保持 ListTile 满宽 |
| 原先 `onChanged: null` 的单项禁用语义丢失 | 改用 `RadioListTile.enabled: false`（与旧实现同为 `_enabled=false`），并在组回调里再兜一道 |
| 删除「死代码」时误删有副作用的初始化调用 | 逐条先读上下文；`createLedger` 这类有前置副作用的改为保留调用、只丢变量 |
| CI 的 FLUTTER_VERSION 与 lock 不符 | analyze.yml 与本机一致取 3.44.3；**release.yml 仍为 3.27.3，属历史漂移，已单独上报** |
| 曾出现：删死代码的脚本按「2 空格缩进 = 成员收尾」定位块 | 该规则只对类成员成立；顶层函数（0 缩进 `}`）会被误扩到下一个成员。本轮因此在 `theme_providers.dart` 误删 9 行，已修回。后续删块前先确认目标缩进层级 |
