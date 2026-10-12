# 工程债清理批次（2026-10-12）— 需求文档

> 本批次来自 2026-10-12 的全项目缺口盘点（用户「还有哪些没做的」之问）。
> 盘点发现 `prd/README.md` 的「五项余量」里两条已过期、两项仍是实的，本批次只收口
> **低成本高确定性**的部分；高成本项（549 处字号收敛、性能三条基线、真机无障碍）
> 明确不在本批次。

## 一、背景（盘点结论的两处修正）

2026-10-12 代码级核实，与 `prd/README.md`「仍在进行中的五项余量」对照：

| README 记载 | 核实结果 | 本批次动作 |
|---|---|---|
| 「5 余量：对比度一项**测了没改**（亮色 `textTertiary` 2.18/2.41 < 4.5）」 | **已过期**：`lib/styles/tokens.dart:196-198` 亮色已是 `#5F6B7A`（页面底 4.65 / 卡片底 5.15），`test/styles/contrast_token_test.dart` + CI `scripts/contrast_check.py` 双门禁 | 更正文档（README:96、`ui_consistency_optimization/requirements.md:68`），写清改到位的时间与证据 |
| 「14 余量：`Platform.is` 剩 27 处」 | **已过期**：全库裸 `Platform.is` 只剩 `lib/utils/platform_info.dart:42-43`（抽象自身）；`test/`、`packages/` 零命中 | 更正文档（README:99），并**补源码扫描型守门测试**防复发（这是真缺口：当前无任何测试禁止裸 `Platform.is`） |

仍是实的两项 + 盘点新发现的一项，构成本批次范围。

## 二、需求范围

### R1 平台抽象守门测试（防 `Platform.is` 复发）

- 新增源码扫描型测试：断言 `lib/` 下除 `platform_info.dart` 自身外**零裸
  `Platform.is`**；`packages/` 同样扫描（子包不得反向依赖，也不该裸判平台）。
- 结构照 `test/styles/contrast_token_test.dart`（读源码字符串 + 正则）与
  `font_size_token_ratchet_test.dart` 的 ratchet 范式。
- 允许清单（白名单，逐条写理由）：`platform_info.dart` 自身；`update_permissions.dart`
  的 `Platform.version`（Android API 级判定，`PlatformInfo` 无对等能力——
  若应补能力则一并补，见 design.md）。

### R2 壳页面清理

- `lib/pages/settings/automation_page.dart`（53 行，仅剩「记账提醒」一项；原「周期记账 /
  订阅管理」已移至 `mine_page` 账本设置分区）：**删除页面**，「记账提醒」入口上移
  `mine_page` 原「自动化功能」section 下，少一层跳转。
- `lib/pages/settings/app_icon_page.dart`（48 行，仅全屏图标预览，无任何切换能力；
  iOS 侧 `flutter_launcher_icons` 被显式关闭、无 alternate icons 配置）：**删除页面**
  并移除 `about_page.dart:204-215` 的入口——名不副实的设置项比没有更糟。
- 连带清理：两页的 l10n 键（四个 arb 同步）、导航测试里对这两页的引用（若有）。

### R3 关键路径测试补强（无设备可跑）

- `integration_test/` 仅 1 个文件且 CI 不跑（需设备）；本批次在 `test/pages/` 下补
  **内存库 + ProviderScope** 范式的关键路径测试（照 `recent_entry_inherit_test.dart`
  的 override 手法 + 既有 21 个页面测试模式），覆盖「新建支出 → 列表可见 → 统计
  入账」主链路（若既有测试已覆盖则改补「编辑回显 → 保存 → 列表刷新」路径，实施时
  以不重复为原则选定）。
- CI 的 integration_test job（需 Android 模拟器）**不在本批次**，写入后续项。

### R4 文档债更正

- `prd/README.md`：第 96 行「测了没改」、第 99 行「27 处」两处过期记载更正；
  新增「本轮（2026-10-12 工程债清理）」节登记本批次与 F1-b。
- `prd/ui_consistency_optimization/requirements.md:68`：U2-b 行的「测了没改」更正。
- `prd/README.md` 第 13 行 `subscription_and_overspend_alerts` 状态「实施中」→「已落地」
  （订阅视图 + 两类提醒 + 表单抽屉均已上线，属纯文档状态过期）。

## 三、验收标准

1. R1 守门测试存在且红转绿路径可验证：临时在任意 lib 文件加一行 `Platform.isIOS`
   测试必须失败（评审时人工核对断言逻辑，不真的提交）。
2. R2 两页面文件删除后 `flutter analyze --fatal-infos` 0 issue；全量 `flutter test` 绿；
   「我的」页与「关于」页不再出现两入口；记账提醒三步可达性不变（原：我的 → 自动化
   → 记账提醒；新：我的 → 记账提醒）。
3. R3 新增测试在无设备环境 `flutter test` 可跑过。
4. R4 三处文档与代码事实一致，无新增过期数字。

## 四、明确不做

- 549 处硬编码字号收敛（需先给 `PiggyTextTokens` 补 16/13 档位，独立批次）。
- 性能三条基线（冷启动 / 切页 / FPS）——需真机。
- 真机无障碍三件（读屏实测 / 热区 / 大字号）——需真机。
- CI integration_test job——需模拟器基建，单独排期。
- 编辑器 / 设置 / 账户页面级回归测试补齐（README 12 余量）——量大，单独批次。
