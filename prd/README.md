# `prd/` 索引进出口

本目录存放**需求与设计文档**，约定每个需求一个子目录，内含
`requirements.md`（要做什么、验收标准）与 `design.md`（怎么实现、技术决策与取舍）。

> 约定：新增需求请建 `prd/<snake_case_id>/`，两个文件都写。
> `requirements.md` 是验收依据，缺了它这个需求就无法判定「做完了没有」。

## 本轮（2026-10-08 订阅视图 + 到期/超支提醒）新增

| 目录 | 主题 | 状态 |
|---|---|---|
| `subscription_and_overspend_alerts` | 从周期账单派生「订阅」视图（年支出/月均折算，零识别）+ 周期账单到期提醒（扣款前 3 天 10:00）+ 预算超支实时推送（仅 100%，同预算同周期只推一次）+ 两个全局提醒开关（含配置导出/导入）+ 周期账单编辑器改统一**表单抽屉**（`showRecurringFormBottomSheet`，含列表两入口与订阅页入口）。**零数据模型改动**：无新表、不升 `schemaVersion`、不动同步契约 | 实施中 |
| `ui_bottom_drawer`（追加 2026-10-08 节） | **存量表单页全量收口**：标签 / 分类 / AI 服务商 / AI 提示词 / 周期账单五处整屏表单统一到 `PiggyFormSheet` 抽屉（各页新增 `showXxxFormBottomSheet`，调用点全部改道；标题栏动作逐项安置不丢）。证据：`test/widgets/form_drawer_unification_test.dart`、`recurring_form_drawer_test.dart`、`tag_edit_page_result_test.dart` | 已落地 |

## 本轮（2026-10-05 加固批次）新增

方案正文不在仓库（会话内批准），落地证据以本表列出的门禁测试为入口。

| 目录 / 入口 | 主题 | 状态 |
|---|---|---|
| `sqlcipher_db_encryption` | 整库加密：落盘即密文 / 密钥进系统安全区 / 明文→密文迁移（可往返）/ 健康探测适配 / 开关 | **代码已完整、默认休眠**：密钥层 + 连接层 `setup` 注入 + 明文→密文迁移（含中断恢复）+ 密文→明文关闭路径 + 健康探测适配 + 「引擎不支持就拒绝用密钥」护栏 + 六态开关 UI，49 例测试（不支持时报明原因跳过；配 sqlcipher hook 后 **48/48 实测全绿**）。**Android 打包已实测打通**（自备 `jniLibs` + `name_android: sqlcipher`，运行态日志确认 `SQLCipher 4.18.0 community`）。**端到端已在真机跑通**（非 UI 探针 `tool/db_encryption_device_probe.dart`：真 16.6MB 库加密后文件头非明文、40008 行完好、关闭后回到明文）。剩余：**制品/许可决定**（jniLibs 二进制入库 or 构建期拉取）与 iOS CI |
| `mem_baseline_and_leaks`（追加 2026-10-05 节） | M2-a 首页窗口化（keyset/limit + 日合计下沉 SQL + 首页切流 + `jumpToMonth` 降级）；M2-b 判为不做；M18 / M19 / M12b 三项定论 | 已落地；**收益未实测**（无真机） |
| `ui_consistency_optimization`（追加） | U1 字号收敛**完成**（`PiggyTextTokens.fs*` 纯字号刻度，506 处迁移，ratchet 基线压到 0/0）；U2-b 亮色色阶重排达标 + 对比度门禁进 CI | 已落地；U2-c（读屏/热区/大字号）仍欠真机 |
| 安全三项（未建 prd 目录，入口=代码注释 + 测试） | 备份强制加密（未开 E2EE 禁止云端明文备份）/ AI 发送二次确认（会话级 + 工厂二道关）/ 备注敏感标记（**设备本地**，AI 外发与列表掩码） | 已落地 |
| 性能三基线 + debug 仪表盘（未建 prd 目录） | 冷启动/切页采集脚本 + 应用内帧率仪表盘（release 零常驻） | 已落地；**数字未实测**（`docs/evidence/perf-baseline-2026-10-05.md` 为空表） |
| M13 归档流式（B11 存档设计的实现） | 附件导出与云备份 ZIP 改磁盘到磁盘流式（顺序/名称与旧格式一致） | 已落地 |

**本轮遗留**：SQLCipher 的**连接层接线 / 迁移 bootstrap / 健康探测适配**（三者必须一起落，见其 design.md §7「仍待做」）；`final-gates` 因此未收口。另有 1 项判为不做（M2-b，理由与复访条件见 `mem_baseline_and_leaks/design.md`）。


## 本轮（2026-09-28 日历节假日与月历样式）新增

| 目录 | 主题 | 状态 |
|---|---|---|
| `calendar_holiday` | 月历 orbit 风格改造（农历/节气/节日副标签 + 休/班徽标 + 周末色 + 今天实心/选中描边，保留金额）+ 中国法定节假日联网更新（本地缓存 / 按年预置兜底 / 每日自动 + 手动更新 / 独立设置页 / **按年份补写历史数据（2000 ~ 明年）**，schemaVersion 49） | 设计中，待评审 |

## 本轮（2026-09-25 自定义字段 v46+v47）新增

| 目录 | 主题 | 状态 |
|---|---|---|
| `custom_field_full_link` | 账本自定义字段全链路（v46 定义/值 + v47 周期模板注入，明细/统计/CSV 扩面 + E2/D1 收尾） | 已落地，`fe72cd0`；明细角标仅主列表、统计卡仅区间报表、快照下删定义不传播（余量与发布说明候选见 requirements.md「明确不做」） |

## 本轮（2026-09-19 内存专项 + F1/F2 + U1/U2）新增

方案正文只有一份：`docs/optimization-plan-2026-09-19.md`（编号表 M10-M21 / B6-B11 / F1-F3 / U1-U3
与 §13 批次记录都在里面，file:line 证据以它为准）。本轮**未提交**，所以「落地」列写的是测试与门禁，不是 commit。

| 目录 | 主题 | 状态 |
|---|---|---|
| `mem_baseline_and_leaks` | 内存基线设施 + 泄漏收口（B6-B10 / M10-M21） | 代码与门禁已落地；**RSS 数字未测**（无设备），见 `docs/evidence/mem-baseline-2026-09-19.md` 空表 |
| `transaction_model_completion` | 退款/冲正 + 报销 + 软删除回收站（F1，v44 迁移） | F1-a 回收站/软删除已落地；F1-b 退款关联移交并写明理由 |
| `report_range_and_comparison` | 任意日期区间报表 + 环比/同比 + 标签维度（F2） | 已落地，`test/data/report_range_aggregation_test.dart`（9）+ `test/pages/report/range_report_page_test.dart`（3） |
| `ui_consistency_optimization`（既有目录，追加第五/六节） | 字号令牌收敛门禁 + 图表无障碍（U1/U2） | U2-a 已落地；**U1 交的是 ratchet 不是收敛**；U2-b 对比度测了没改 |

## 上一轮（2026-09-14 评估）新增

| 目录 | 主题 | 状态 |
|---|---|---|
| `p1a_webview_subscription_lifecycle` | WebView / StreamSubscription 生命周期审计 + 成文规范 | 已落地（`7012c81`） |
| `p1b_unawaited_log_error_exit` | 后台链路统一异常出口（`unawaitedLog`）+ 统计页错误态 | 已落地（`3658b85`） |
| `p1c_list_incremental_grouping` | 交易列表按日期段增量分组，替代全量重算 | 已落地（`62e6ed2`） |
| `p1d_style_token_convergence_batch1` | 样式令牌收敛第一批（图表色板 / 海报语义色 / 默认主色单源） | 已落地（`5317308`）；后续批次见「仍在进行中的五项余量」 |
| `p1e_quick_entry_mode` | 快捷记账模式（记忆上次分类 + 金额优先的极简表单） | 已落地（R1-R4，`c8c6e9c` + `ad807bc`），见下方对照表第 9 行 |
| `p1f_rec6_error_observability` | 同步异常→用户提示映射表 + 本地库损坏恢复引导 | 已落地（`7330b26` → `74d3b16` → `4b337c6` → `dce6a0d`）|
| `p2a_analyzer_baseline` | 静态分析清零（566→0）+ CI 锁基线 | 已落地（`252a4e8`） |

## 报告 14 条建议 → 落地对照（截至 2026-09-19）

一张表回答「这条做完没有 / 证据在哪 / 有没有文档」，避免每次翻报告对进度。

| 建议 | 主题 | 状态 | 落地提交 | prd 文档 |
|---|---|---|---|---|
| 1 | 空 catch 治理（32 处） | 已落地 | `42fbabd` | 无（见提交说明） |
| 2 | iOS ATS 收紧 | 已落地 | `a25572f` | 无 |
| 3 | use_build_context_synchronously（100 处） | 已落地 | `340242d` | 无 |
| 4 | 启动路径瘦身 | 已落地 | `b66d228` | 无 |
| 5 | 无障碍基线 | 已落地（第一阶段 + 09-19 图表语义摘要） | `a61bd25` + `64d950d` + `f298cca`；09-19 部分**未提交** | `ui_consistency_optimization` 第五/六节 |
| 6 | 可观测性封装 + 异常映射表 | 已落地 | `7330b26`→`74d3b16`→`4b337c6`→`dce6a0d`；`.then onError` 部分 `3658b85` | `p1f_rec6_error_observability`、`p1b_unawaited_log_error_exit` |
| 7 | 列表增量分组 + provider 收敛 | 已落地 | `62e6ed2` | `p1c_list_incremental_grouping` |
| 8 | 样式令牌收敛 + 图表响应式 | **部分完成**（09-19 只交了字号 ratchet 门禁，收敛未做） | `5317308`（第一批）；09-19 部分**未提交** | `p1d_style_token_convergence_batch1`、`ui_consistency_optimization` 第五/六节 |
| 9 | 记账效率：快捷记账模式 | 已落地（R1-R4） | `c8c6e9c` + `ad807bc` | `p1e_quick_entry_mode` |
| 10 | WebView / 订阅生命周期 | 已落地 | `7012c81` | `p1a_webview_subscription_lifecycle` |
| 11 | 静态分析清零 + CI 基线 | 已落地 | `252a4e8` | `p2a_analyzer_baseline` |
| 12 | 高风险页面回归测试 | **部分完成** | `0317fb8`（deep link 契约 50 例）+ `dae4ab2`（同步冲突 10）+ `39938d5`（账本删除/清空 10）+ `ee17696`（导入流程 13） | 无 |
| 13 | 运行时性能监控接入 | **部分完成**（09-19 只接了内存这一条：30s 心跳 + 基线脚本；FPS / 冷启动 / 页面切换三条仍未开始） | **未提交**，见 `lib/app.dart` `_startMemoryHeartbeat()`、`scripts/profile_memory.py` | `mem_baseline_and_leaks` |
| 14 | 平台能力与文档治理 | **部分完成** | `e62f122` + `c6f879e`（文档部分）+ `63a02e9`（14a `PlatformFeature`，见 `lib/utils/platform_info.dart`） | 无 |

**仍在进行中的五项余量**：

- **8 余量**：硬编码字号实测 **549 处字面量**（`pages/` 340 / `widgets/` 209，最高频 `16×125`、`13×64`），
  09-19 起由 `test/styles/font_size_token_ratchet_test.dart` 钉死只减不增，**收敛本身未做**
  （16/13 在 `PiggyTextTokens` 里没有档位 + 令牌返回整只 `TextStyle`，理由见 `ui_consistency_optimization` 第五节）。
  另有图表响应式、`tokens.dart` 静态亮色常量下线。
- **5 余量**：无障碍欠的是需要真机的那半张清单 —— 读屏实测、热区 ≥48×48 全量核查、大字号下 UI 不破；
  外加对比度一项**测了没改**（亮色 `textTertiary` 2.18/2.41 < 4.5，`scripts/contrast_check.py`）。
- **12 余量**：编辑器 / 设置页 / 账户页的**页面级**回归（deep link 契约、同步冲突、账本删除清空、导入流程已覆盖）。
- **13**：冷启动 / 页面切换 / 列表滚动帧率基线 + 仪表盘。**内存维度另立专项**，见 `docs/optimization-plan-2026-09-19.md`。
- **14 余量**：`PlatformFeature` 尚未收口的 `Platform.is` 剩 27 处（报告原文称 58 处，14a `63a02e9` 后见 `lib/utils/platform_info.dart`）。

> 注：建议 1–5、12、13、14 落地时未建 `prd/` 目录，需求与决策只存在于提交说明与代码注释里。
> 这是文档治理的遗留缺口，按「不追溯补写已验收完毕的历史工作」处理——需要时以提交为入口。

> 另有一项报告外的工程修复：`af240eb fix(ci)` 消除 Flutter 版本漂移（`pubspec.yaml` 成为唯一版本源）。

## 历史需求（按主题分组）

### 同步与云端
| 目录 | 主题 |
|---|---|
| `cloud_backup` | 云端全量备份与恢复 |
| `cloud_recurring_sync` | 周期交易云端同步 |
| `remote_ledger_discovery` | 云端账本发现 |
| `ledger_upload` | 账本上传 |
| `startup_sync_check` | 启动时同步状态检查 |
| `sync_gap_closure` | 同步缺口收敛 |
| `sync_review_fix` | 同步审计修复批次 |
| `sync_encryption_fixes` | 同步加密缺陷修复（含 `verification_report.md`） |
| `webdav_new_device_auth_prompt` | WebDAV 新设备认证提示 |
| `account_sync_fix` | 账户同步修复 |
| `account_metadata_sync_fix` | 账户元数据同步修复 |
| `account_dedup` | 账户去重收敛（user-global，`ledger_id=0`） |
| `attachment_binary_sync` | 附件二进制同步 |

### 加密
| 目录 | 主题 |
|---|---|
| `encryption` | E2EE 加密（含 `multi_device_join_*` 多设备加入） |

### UI / UX
| 目录 | 主题 |
|---|---|
| `ui_optimization_review` | UI 优化评审 |
| `ui_consistency_optimization` | UI 一致性优化 |
| `settings_ui_redesign` | 设置页改版 |
| `ui_bottom_drawer` | 底部抽屉 |
| `titlebar_glass_unification` | 标题栏毛玻璃统一 |
| `piggy_pink_theme_ui_polish` | 小猪粉主题 UI 打磨 |
| `mine_header_fullwidth` | 「我的」页头部全宽主题色改造 |
| `star_entry_removal` | 星标入口移除 |
| `home_perf_and_sync_fixes` | 首页性能与同步修复 |

### 品牌 / 其他
| 目录 | 主题 |
|---|---|
| `piggycount_rename` | 项目改名（含 `execution_plan.md`） |
| `url_and_icon_update` | 链接与应用图标更新 |

## 归档

`_archive/` 存放已过时或非结构化、仅作参考的文档（含探索式对话残留），
不参与需求追溯。详见 `_archive/README.md`。

## 已知待办

- `mine_header_fullwidth` 原先只有 `design.md`，本轮补了 `requirements.md`。
- 进度类事项（哪条建议未完成）统一看上面「仍在进行中的五项余量」，此处不重复维护。
