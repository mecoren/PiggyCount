# UI 一致性优化需求文档

## 一、需求理解

根据 `prd/piggycount.md` 中识别的 UI 一致性问题清单，对 PiggyCount Flutter 项目进行系统性优化，建立 **BeeTokens 作为颜色/间距的唯一来源**，消除三层主题（`tokens.dart` / `theme.dart` / `main.dart`）中的冲突值，并将散布在各页面中的硬编码颜色、旧 API、混用 `Theme.of(context)` 统一迁移到 Token 体系。

## 二、优化范围（P0-P3 全覆盖）

### P0 - 关键问题（必须修复）

| 编号 | 问题 | 当前状态 | 期望状态 |
|------|------|----------|----------|
| P0-1 | `scaffoldBackgroundColor` 三处值不一致 | `theme.dart`: `paperIvory`(#FFF8E1) / `main.dart`: `Colors.white` / `tokens.dart`: `Colors.grey.shade50` | 以 `tokens.dart` 为单一来源，`theme.dart`/`main.dart` 引用同一常量 |
| P0-2 | `cardTheme.borderRadius` 亮暗不一致 | 亮 `radiusXl`、暗 `radiusLg` | 统一为 `radiusXl` |
| P0-3 | `dividerColor` 在 main.dart 硬编码 `Colors.black.withOpacity(0.06)` | 未走 Token | 提取到 `BeeTokens.divider(context)` |
| P0-4 | `splash_page.dart` 仍混用 `Theme.of` + `withOpacity` + `Colors.white` | 部分已导入 tokens.dart | 全部替换为 Token 调用 |

### P1 - 高优先级

| 编号 | 问题 | 范围 |
|------|------|------|
| P1-1 | 34 个文件混用 `Theme.of(context)` 与 `BeeTokens.xxx(context)` | 全部统一到 `BeeTokens` |
| P1-2 | 约 15 个文件硬编码 `Colors.red/green/orange` 等语义色 | 替换为 `BeeTokens.error/success/warning(context)` |
| P1-3 | `home_page.dart` 中 `Color(0xFF1E1E1E)` 重复 3 次 | 提取为 Token 常量 |

### P2 - 中优先级

| 编号 | 问题 | 范围 |
|------|------|------|
| P2-1 | 25+ 处 `withOpacity` 旧 API | 全部替换为 `.withValues(alpha:)` |
| P2-2 | `annual_report_page.dart` 大量硬编码 `0xFF4CAF50`/`0xFFFF5252` 等 | 使用 `BeeTokens.chartIncome/Expense(context)` |

### P3 - 低优先级

| 编号 | 问题 | 范围 |
|------|------|------|
| P3-1 | 间距体系不统一（const vs `.scaled()`） | 统一策略，提取重复值为 `BeeDimens` 常量 |
| P3-2 | `home_page.dart` 中 `EdgeInsets.fromLTRB(12, 4, 12, 8)` 重复 3 次 | 提取为 `BeeDimens` 常量 |
| P3-3 | `transaction_editor_page.dart` PrimaryHeader padding 与主流不一致 | 统一 |

## 三、不在范围内

- 不重构现有 `BeeTokens` 类的 API（保持 `static Color xxx(BuildContext)` 签名不变）
- 不引入第三方 UI 库
- 不修改 `BeeTheme.lightTheme/darkTheme` 的方法签名
- 不调整 `.scaled()` 自适应缩放机制本身（只统一基础间距值）
- 不重写组件库结构，仅修改颜色/间距取值方式

## 四、验收标准

1. `flutter analyze` 0 错误，警告数不增加
2. `grep -r "withOpacity" lib/` 结果为空
3. `grep -r "Colors\.red\b\|Colors\.green\b\|Colors\.orange\b" lib/pages/` 仅出现在合理的业务上下文（如红色删除按钮的特殊语义）— 否则应已替换为 `BeeTokens.error/success/warning(context)`
4. `theme.dart` 中 `scaffoldBackgroundColor` 不再直接写字面量颜色，而是引用 `tokens.dart` 常量
5. `main.dart` 中不再出现 `scaffoldBackgroundColor`、`dividerColor`、`cardTheme.color` 等覆盖（保留 `primaryColor`、`colorScheme.primary` 等动态主色覆盖）
6. `splash_page.dart` 全部使用 `BeeTokens` / `BeeTextTokens` / `BeeDimens`，不再使用 `Theme.of(context).colorScheme`、`Colors.white.withOpacity`
7. 亮色/暗色模式下视觉无回归（背景色统一为 `Colors.grey.shade50` 浅灰；卡片圆角统一为 `radiusXl`）

## 五、追加（2026-09-19，`docs/optimization-plan-2026-09-19.md` §五 U1/U2）

本文档前五节写于 `BeeTokens` 时期，类名已改 `PiggyTokens` / `PiggyTextTokens` / `PiggyDimens`，
按现名读。本节是本轮实际验收的部分，与上面 P0-P3 的清单**并列**，不覆盖它们。

| 编号 | 需求 | 状态 | 验收依据 |
|------|------|------|----------|
| U1 | `pages/` + `widgets/` 硬编码字号收敛到令牌 | **交付门禁，未做收敛** | `test/styles/font_size_token_ratchet_test.dart`：基线 340（pages）/ 209（widgets），新增一处即红 |
| U2-a | 图表在语义树里有可读节点 | 已落地（柱状图 + 折线图） | `test/widgets/chart_semantics_test.dart` 3 例（含 `hideAmounts` 不泄露金额） |
| U2-b | 文字/背景对比度 ≥4.5:1（WCAG 1.4.3） | **测了没改**：亮色 `textTertiary` 2.18/2.41 不合格，`textSecondary` 页面底 4.44；暗色全过 | `scripts/contrast_check.py`（可复跑），数字与候选值记在 §13 |
| U2-c | 读屏实测、热区 ≥48×48 全量核查、大字号下 UI 不破 | **未开始**：无真机/模拟器 | —— |

U1 判"本轮不收敛"的三条理由（数字与 `file:line` 见 §13），共同点是**它们互相咬着**：
① 最高频的 16（125 次）与 13（64 次）在 `PiggyTextTokens` 里没有档位，要先做设计决定；
② 令牌成员返回整只 `TextStyle`（含 color/weight，`tokens.dart:800-856`），替换即改视觉；
③ 本方案给 U1 定的出口就是"每批带视觉 diff 截图"，本轮无设备。
U2-b 同理：能把 `textTertiary` 改到合格的 `#5F6B7A` 与 `textSecondary` 的合成色几乎同色 ——
一次机械调暗会把三级文字并到二级上去。**两项都等到有截图回归条件再动，届时的开手顺序由门禁的直方图给出。**
