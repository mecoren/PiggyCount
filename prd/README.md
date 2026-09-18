# `prd/` 索引进出口

本目录存放**需求与设计文档**，约定每个需求一个子目录，内含
`requirements.md`（要做什么、验收标准）与 `design.md`（怎么实现、技术决策与取舍）。

> 约定：新增需求请建 `prd/<snake_case_id>/`，两个文件都写。
> `requirements.md` 是验收依据，缺了它这个需求就无法判定「做完了没有」。

## 本轮（2026-09 优化评估）新增

| 目录 | 主题 | 状态 |
|---|---|---|
| `p1c_list_incremental_grouping` | 交易列表按日期段增量分组，替代全量重算 | 已落地（`62e6ed2`） |
| `p1d_style_token_convergence_batch1` | 样式令牌收敛第一批（图表色板 / 海报语义色 / 默认主色单源） | 已落地（`5317308`）；后续批次见文末 |
| `p2a_analyzer_baseline` | 静态分析清零（566→0）+ CI 锁基线 | 已落地（`252a4e8`） |
| `p1f_rec6_error_observability` | 同步异常→用户提示映射表 + DB 损坏恢复引导 | 设计待确认 |

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
- 样式令牌收敛仍有余量：`pages/` 下约 338 处硬编码 `fontSize`、
  `tokens.dart` 图表响应式，见 `p1d_style_token_convergence_batch1`。
