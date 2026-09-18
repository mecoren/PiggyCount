# P2-A 静态分析清零 + CI 基线 — 需求文档

## 一、背景

优化评估报告（`docs/optimization-assessment-report/optimization-assessment-report.html`，建议 11）测得：

| 规则 | 数量 | 报告判断 |
|------|------|----------|
| `unnecessary_non_null_assertion` | 207 | 可批量自动修复 |
| `avoid_print` | 154 | 脚本可豁免；packages 建议换 logger |
| `deprecated_member_use` | 50 | **依赖升级前置项** |
| `dangling_library_doc_comments` | 30 | 低风险，批量补 |
| 其余 15 项 | 127 | 常规清理 |

报告治理建议：「`dart fix --apply` 批量清零 → CI 锁定『不新增』→ 逐月消化存量」。

本次复测基线为 **566 条**（250 warning / 316 info；`use_build_context_synchronously`
的 100 条已在 P0 批次清零，故低于报告中的 668）。

## 二、需求范围

### R1 存量清零

- `unnecessary_non_null_assertion` 207 条清零（`dart fix --apply` + 人工修回被改坏的语法）。
- `avoid_print` 154 条：CLI/示例走文件级豁免，库代码换成 release 零开销的
  `debugLog`（见 design 决策 2/3）。
- `deprecated_member_use` 50 条全部迁移，**不允许用 `// ignore` 绕过**。
- 其余 warning/info（`unused_element` / `unused_local_variable` / `unused_field` /
  `unnecessary_null_comparison` / `dead_null_aware_expression` /
  `unused_shown_name` / `undefined_shown_name` / `dangling_library_doc_comments` /
  `unintended_html_in_doc_comment` / `curly_braces_in_flow_control_structures` /
  `use_super_parameters` 等）逐条修掉或删除对应死代码。

### R2 CI 门禁

- 新增 `Analyze` workflow：push / PR 触发，`flutter analyze --fatal-infos`。
- 因存量已为 0，门禁设为「任何一条（含 info）即失败」，不引入基线文件。

### R3 附带发现须一并处理

- `ProviderScope(parent: container)` 造成的双容器分裂（见 design 决策 5）。
- 因删代码而暴露的后续告警（如删除唯一调用点后 `_getDescription` 自身也成死代码）。

## 三、验收标准

### AC-R1

| # | 场景 | 预期 |
|---|------|------|
| 1 | `flutter analyze` | `No issues found!`（0 error / 0 warning / 0 info） |
| 2 | `dart fix` 后语法完整性 | analyze 无 error 级输出；两处被改坏的构造函数已修回且语义等价 |
| 3 | `avoid_print` | `lib/` 与 `packages/*/lib/` 内 `print(` 零命中（`debugPrint` 不算） |
| 4 | `deprecated_member_use` | 零命中；`RadioListTile` 的 `groupValue`/`onChanged` 不再出现在 lib/ |
| 5 | 死代码删除 | 删除前后全量测试结果一致（无行为变化） |

### AC-R2

| # | 场景 | 预期 |
|---|------|------|
| 1 | PR 引入一条 info 级告警 | Analyze workflow 失败 |
| 2 | 仓库当前状态 | Analyze workflow 通过 |

### AC-R3

| # | 场景 | 预期 |
|---|------|------|
| 1 | widget 侧 `ref` 与启动后台任务读同一 provider | 命中同一份 state（不再是子容器副本） |
| 2 | `_WidgetUpdateObserver` | 对 widget 侧 provider 活动同样生效 |

### AC-通用

- 全量 `flutter test` 通过（本轮基线 1184 passed / 1 skipped）。

> 注：本机跑测试须先清空 `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`
> （代理会拦断 `flutter_tester` 的 localhost WebSocket，表现为 152 个文件
> 全部 `Invalid WebSocket upgrade request`）。

## 四、非目标

- **不改 `release.yml` 的 `FLUTTER_VERSION`**：该值仍为 `3.27.3`，与
  `pubspec.lock` 的 `flutter: ">=3.44.0"` 冲突，属独立的历史漂移问题，
  需单独决策（本轮只上报，不动）。新增的 `analyze.yml` 取 3.44.3 与本机一致。
- **不为 `unnecessary_non_null_assertion` 建基线白名单**：既然能清到 0，就不留豁免名单。
- **不把 `flutter test` 加进 CI**：部分 cloud 测试依赖本地服务端
  （`scripts/webdav_test`），未验证前不盲加。
