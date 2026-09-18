# `prd/` 索引进出口

本目录存放**需求与设计文档**，约定每个需求一个子目录，内含
`requirements.md`（要做什么、验收标准）与 `design.md`（怎么实现、技术决策与取舍）。

> 约定：新增需求请建 `prd/<snake_case_id>/`，两个文件都写。
> `requirements.md` 是验收依据，缺了它这个需求就无法判定「做完了没有」。

## 本轮（2026-09 优化评估）新增

| 目录 | 主题 | 状态 |
|---|---|---|
| `p1a_webview_subscription_lifecycle` | WebView / StreamSubscription 生命周期审计 + 成文规范 | 已落地（`7012c81`） |
| `p1b_unawaited_log_error_exit` | 后台链路统一异常出口（`unawaitedLog`）+ 统计页错误态 | 已落地（`3658b85`） |
| `p1c_list_incremental_grouping` | 交易列表按日期段增量分组，替代全量重算 | 已落地（`62e6ed2`） |
| `p1d_style_token_convergence_batch1` | 样式令牌收敛第一批（图表色板 / 海报语义色 / 默认主色单源） | 已落地（`5317308`）；后续批次见文末 |
| `p1e_quick_entry_mode` | 快捷记账模式（记忆上次分类 + 金额优先的极简表单） | **设计待确认**——`requirements.md` 第五节 5 个待拍板项 |
| `p1f_rec6_error_observability` | 同步异常→用户提示映射表 + 本地库损坏恢复引导 | 已落地（`7330b26` → `74d3b16` → `4b337c6` → `dce6a0d`）|
| `p2a_analyzer_baseline` | 静态分析清零（566→0）+ CI 锁基线 | 已落地（`252a4e8`） |

## 报告 14 条建议 → 落地对照（截至 2026-09-18）

一张表回答「这条做完没有 / 证据在哪 / 有没有文档」，避免每次翻报告对进度。

| 建议 | 主题 | 状态 | 落地提交 | prd 文档 |
|---|---|---|---|---|
| 1 | 空 catch 治理（32 处） | 已落地 | `42fbabd` | 无（见提交说明） |
| 2 | iOS ATS 收紧 | 已落地 | `a25572f` | 无 |
| 3 | use_build_context_synchronously（100 处） | 已落地 | `340242d` | 无 |
| 4 | 启动路径瘦身 | 已落地 | `b66d228` | 无 |
| 5 | 无障碍基线 | 已落地（第一阶段） | `a61bd25` + `64d950d` + `f298cca` | 无 |
| 6 | 可观测性封装 + 异常映射表 | 已落地 | `7330b26`→`74d3b16`→`4b337c6`→`dce6a0d`；`.then onError` 部分 `3658b85` | `p1f_rec6_error_observability`、`p1b_unawaited_log_error_exit` |
| 7 | 列表增量分组 + provider 收敛 | 已落地 | `62e6ed2` | `p1c_list_incremental_grouping` |
| 8 | 样式令牌收敛 + 图表响应式 | **部分完成** | `5317308`（第一批） | `p1d_style_token_convergence_batch1` |
| 9 | 记账效率：快捷记账模式 | **待拍板** | — | `p1e_quick_entry_mode`（设计就绪，等第五节 5 个决策） |
| 10 | WebView / 订阅生命周期 | 已落地 | `7012c81` | `p1a_webview_subscription_lifecycle` |
| 11 | 静态分析清零 + CI 基线 | 已落地 | `252a4e8` | `p2a_analyzer_baseline` |
| 12 | 高风险页面回归测试 | **部分完成** | `0317fb8`（deep link 契约 50 例） | 无 |
| 13 | 运行时性能监控接入 | **未开始** | — | 无 |
| 14 | 平台能力与文档治理 | **部分完成** | `e62f122` + `c6f879e`（文档部分） | 无 |

**仍在进行中的四项余量**：

- **8 余量**：`pages/` 下约 338 处硬编码 `fontSize`、图表响应式、`tokens.dart` 静态亮色常量下线。
- **9**：等 `p1e_quick_entry_mode/requirements.md` 第五节拍板后实施。
- **12 余量**：云同步页 / 账本页 / 编辑器的**页面级**回归（deep link 契约已覆盖）。
- **13**：冷启动 / 页面切换 / 列表滚动帧率基线 + 仪表盘。
- **14 余量**：`PlatformFeature` 封装（58 处 `Platform.is`）。

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
- 进度类事项（哪条建议未完成）统一看上面「剩余未完成」表，此处不重复维护。
