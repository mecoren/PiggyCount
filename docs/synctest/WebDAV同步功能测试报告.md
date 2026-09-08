# WebDAV 快照同步功能测试报告

- 测试日期:2026-09-08
- 测试人:自动化流程(ZCode 会话)
- 结论:**通过**(8 张同步表全部一致;唯一差异为 1 项已知设计边界,与 S3 轮完全相同,非同步缺陷,见 §4)

## 1. 测试环境

| 项 | 值 |
|---|---|
| 应用 | PiggyCount dev 风味 debug 包,version 0.7.8(含本次 BeeCount 移植代码,DB schema v42) |
| 模拟器1(A 端,写入方) | 127.0.0.1:16384,Android 15(API 35),x64 |
| 模拟器2(B 端,读取方) | 127.0.0.1:16416,Android 15(API 35),x64 |
| WebDAV 服务器 | `scripts/webdav_test/` 内置单文件 HTTPS 服务器(`start.sh --fresh` 干净环境启动),模拟器经 `https://10.0.2.2:8443` 访问宿主 |
| 凭据 / remotePath | pctest / piggy123,`/piggycount/` |
| 云配置 | 两端激活后端均由 s3 切换为 webdav(修改 `cloud_active_type`,凭据条目存于 EncryptedSharedPreferences 未动);清理过程中云配置保持完整 |
| 测试数据 | `scripts/inject_16384_sync_test.py` 重新注入(全新 syncId 体系):6 账本 × 1000 + 1 seed = 6006 笔 |

## 2. 测试步骤

### 2.1 数据清理阶段(重复 S3 轮步骤)
1. 两端仅删除本地数据库与附件(`piggycount.sqlite*`、`attachments/*`),**不触碰 shared_prefs 中的云配置**。
2. `cloud_active_type` 由 s3 改为 webdav(base64 流式推送 prefs XML;S3 凭据条目原样保留在加密存储中,切回即用)。
3. WebDAV 服务器以 `--fresh` 启动,数据目录清零,无历史槽位干扰(与 S3 轮的桶内遗留形成对照)。

### 2.2 测试数据准备(仅 A 端 16384)
同 S3 轮:6 账本(含 2013-2015 历史回忆账本)、每账本微信零钱/支付宝账户、多币种账户、层级分类、标签、预算、周期规则、汇率覆盖、附件,`local_changes` 6143 条。

### 2.3 同步操作
1. **A 端(同步到云端)**:我的 → 同步 → 「全量上传」→ 双重危险确认(两次 3 秒倒计时)。
   - 日志:6 账本串行 `Starting upload → Post-upload verify passed → Upload completed`,最终 `上传完成: 6`。
   - **服务器端验证**:`data/piggycount/` 落盘 6 个 `ledger_<slotKey>.json` + attachments 目录;server.log 逐一记录 PUT(原子写 `.tmp` → MOVE)→ OPTIONS → GET(verify)完整链,每个请求携带 Basic 凭据(预置 BasicAuth 的 W5 行为符合预期)。
2. **B 端(同步云端)**:启动 StartupSyncChecker 弹「云端发现 6 个本机没有的账本」,点「下载」。
   - 日志:`StartupSyncChecker: 云端新账本导入完成 6/6 个`,每账本 `交易导入完成: 总数=1001 成功=1001 跳过=0 失败=0`,分类/标签/周期/预算/汇率各导入环节完整。

### 2.4 数据验证
对比工具与口径同 S3 轮(`scripts/live_db/compare_sync_final.py`,按 syncId 对齐)。结果:

| 维度 | A | B | 仅A | 仅B | 字段差异 |
|---|---|---|---|---|---|
| ledgers | 6 | 6 | 0 | 0 | 1 项(见 §4) |
| accounts | 48 | 48 | 0 | 0 | 0 |
| categories(含父链归一) | 29 | 29 | 0 | 0 | 0 |
| tags | 15 | 15 | 0 | 0 | 0 |
| **transactions 逐字段** | **6006** | **6006** | **0** | **0** | **0** |
| transaction_tags 链接 | 1748 | 1748 | - | - | 0 |
| budgets | 18 | 18 | 0 | 0 | 0 |
| recurring_transactions | 18 | 18 | 0 | 0 | 0 |
| exchange_rate_overrides | 9 | 9 | 0 | 0 | 0 |

交易逐字段口径:type/amount/分类链/账户链/转入账户链/happened_at/note/exclude_stats/exclude_budget/currency_code/native_amount —— **6006 笔全部一致**。

## 3. 测试结果

**通过。** WebDAV 快照同步在干净服务端环境下一次通过:A→云端→B 全链路(原子写、鉴权、条件写协商、verify 回读)行为正确,6 账本 6006 笔交易两端逐字段一致。与 S3 轮结果互为印证,排除了后端实现差异引入的问题。

## 4. 问题分析

### 4.1 已知边界(非缺陷):ledgers.is_shared / member_count 不随快照同步
与 S3 轮完全相同:「家庭共用账本」A 端 `is_shared=1, member_count=2` → B 端 `0/1`。快照 JSON 账本字段仅含 name/currency/monthStartDay(`lib/cloud/transactions_json.dart:445`),共享元数据属已下线的 PiggyCountCloud 协同协议,路径 A 设计上不携带。两轮(不同后端)表现一致,确认为设计边界而非实现 bug。

### 4.2 与 S3 轮对照
- 无云端遗留干扰(fresh 服务器):B 端启动发现恰好 6 个账本,一键下载即与 A 端 syncId 集合完全一致 —— 反向验证了 S3 轮的 17 槽位问题纯属桶内历史遗留,非同步功能缺陷。
- WebDAV 特有验证点:原子写(.tmp + MOVE)、BasicAuth 预置、自签证书放宽(仅 debug + 10.0.2.2)均按 `scripts/webdav_test/README.md` 的预期行为工作。

## 5. 复现路径(关键节点)

1. `cd scripts/webdav_test && ./start.sh --fresh`
2. 清库 + `cloud_active_type` 切 webdav(或 App 内「云服务」页配置 `https://10.0.2.2:8443`,pctest/piggy123)
3. `python scripts/inject_16384_sync_test.py` 注入 A 端
4. A 端:我的 → 同步 → 全量上传(两次确认)
5. B 端:启动 → 云端发现弹窗 → 下载
6. `python scripts/live_db/compare_sync_final.py <A快照> <B快照> --label WebDAV`

快照留档:`scripts/live_db/_goal_shots/wd_16384.sqlite`、`wd_16416.sqlite`;服务器落盘证据:`scripts/webdav_test/data/piggycount/`;截屏证据:`scripts/live_db/_goal_shots/wd_*.png`。
