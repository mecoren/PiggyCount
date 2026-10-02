# 同步 E2E 测试工具（单一入口）

本项目**同步回归**的唯一工具链，分设备端驱动与宿主端判据两层，二者都有版本管理。

| 层 | 文件 | 位置 |
|---|---|---|
| 设备端驱动 | `main.dart` | 真机/模拟器上运行（`flutter run -t tool/sync_e2e/main.dart`） |
| 宿主端判据 | `run.py` | 开发机运行（取数 / 比对 / 门禁 / 委派） |

## 为什么收敛成一个入口

历史上同步判据分散在两处、且各自演进：

* `scripts/live_db/compare_sync_final.py`：**DB 级 + 契约派生**比对（v4，从 Dart 实现派生
  「真会被搬运」的字段集并三向校验），比载荷细，但看不到「快照序列化口径」这一层；
* 各轮测试写在自己的 `run_*/` 临时脚本里（`field_coverage.py` 等）——该目录已在
  `.gitignore`，**实现随目录丢失**，判据因此不可复现（2026-10-02 复核确认已不存在）。

后果是「同一个词（一致）在不同轮次指不同东西」。现在：**判据只住在这里**，
DB 级比对以委派方式复用既有实现，不重写（不新增漂移源）。

## 三层判据（互补，缺一层就可能漏一类缺陷）

| # | 命令 | 判据 | 专抓 |
|---|---|---|---|
| 1 | `compare` | 两端各自导出的 `ledger_*.json` **除 `exportedAt` 外逐字节相同** + 账本/表计数一致 | 「指纹相同、字节不同」的**静默不对称**（2026-10-02 抓到 3 处：转账分类归空 / 导出排序兜底键 / 预算启用态 —— 这三处指纹全判不出差异） |
| 2 | `coverage` | 声明「本次必须真被覆盖」的字段，**双端**都要有实测证据 | 「差异=0」其实因为该字段**两端都是空**的平凡通过 |
| 3 | `db` | 委派 `scripts/live_db/compare_sync_final.py` | 逐列/契约内外的细粒度差异（载荷级看不到的 DB 语义） |

## 用法

```bash
# 设备端（每台目标设备各跑一次；命令见「设备端命令」一节）
flutter run -d 127.0.0.1:16384 --flavor dev -t tool/sync_e2e/main.dart \
  --dart-define=E2E_CMD=dump

# 宿主端
python tool/sync_e2e/run.py pull  <serial> <outdir>        # 取回 dump.json + payloads/
python tool/sync_e2e/run.py compare <dirA> <dirB>          # 判据 1
python tool/sync_e2e/run.py coverage <dirA> [<dirB>] [--require standard|full|a,b,c]
python tool/sync_e2e/run.py all <dirA> <dirB> [--require standard]   # 判据 1+2，单一总判定
python tool/sync_e2e/run.py db <A.sqlite> <B.sqlite> [--label WebDAV] # 判据 3（委派）
```

退出码：`0` 全部通过 / `1` 有判据不成立 / `2` 用法或环境错误（可直接用于 CI 或脚本串联）。

### 覆盖度档位

| 档位 | 内容 |
|---|---|
| `standard`（默认） | 现成夹具（`seed`）即可满足：`transfer / income / adjustment / original_amount / original_amount_zero / custom_values / multi_currency / exclude_flags / tags` |
| `full` | 追加 `recurring_anchor / attachments`（需夹具额外造数，默认不纳入，显式声明才判定） |

字段目录与判定函数在 `run.py` 的 `COVERAGE_CATALOG`；**新增要求 = 往那里加一项**（不要临时写脚本）。

## 设备端命令

| 命令 | 用途 |
|---|---|
| `probe` | 打印云配置存在性 + E2EE 状态 + 表计数 + 账本清单（判「云配置零删除」用） |
| `seed` | 造数：8 账本 × 5000 笔（含 1999-2018 历史账本、微信/支付宝、转账/收入/调整、多币种、自定义字段、账单标记、tag、显式 `originalAmount=0`）；幂等（已存在 `[E2E]` 账本即跳过） |
| `mutate` | 制造变更：+137 笔 / 改名 + 月起始日 / 删 40 笔 / 改 25 备注（首笔显式 `originalAmount=0`） |
| `dump` | 逐账本导出快照到 `app_flutter/e2e-dump/`，并输出聚合指纹 + 各账本指纹 |
| `checks` | 结构化诊断：按类型统计、缺分类行数、重复 syncId、孤儿分类引用、表计数 |
| `rename` | 按 `E2E_SYNC_ID` 精确改名（构造「云端账本名与本地不同」场景） |
| `wipe` | 只清业务表（不动 `shared_prefs`，云配置零删除） |
| `set-backend` | 切换激活后端（`E2E_BACKEND=s3\|webdav`，不动凭据） |
| `set-ledger` | 修正 `current_ledger_id` 指向真实账本（清库后自增 id 有空洞时用） |
| `reset` | 组合：`wipe` →（可选 `E2E_SEED`）`seed` →（可选）`set-backend` |
| `netcheck` | 探测 WebDAV / S3 端点可达性（本机 + 设备各一次，区分「服务没起」与「应用问题」） |

结果双通道输出：`print`（flutter run 日志）+ 落盘 `app_flutter/e2e-result/<cmd>-latest.json`（`run.py pull` 取回，更可靠）。

派生的 `--dart-define`：`E2E_CMD` / `E2E_BACKEND` / `E2E_SEED` / `E2E_SYNC_IDS` / `E2E_SYNC_ID` / `E2E_NEW_NAME`。

## 标准流程（双端）

1. 起后端（S3 用真实桶；WebDAV 用仓库自带 `scripts/webdav_test/start.sh`，模拟器访问 `https://10.0.2.2:8443`）；
2. A 端 `reset`（wipe + seed + set-backend）→ B 端 `reset --dart-define=E2E_SEED=false`（只清库 + 切后端）；
3. A 端 UI「全量上传」→ B 端冷启动「下载 / 全量下载」（UI 路径即生产路径，别用工具绕过）；
4. 两端 `dump` → `run.py pull` ×2 → `run.py all <A> <B>`；
5. 需要 DB 级复核时再 `adb pull` 两端 sqlite + `run.py db`；
6. 变更轮次：A 端 `mutate` → UI 上传 → B 端下载 → 重复第 4 步。

> 判据 2 若 FAIL，**先看是真缺字段还是夹具没造**：是真缺就修产品，是夹具缺就补夹具
> （例如 2026-10-02 就是夹具漏了 `originalAmount=0`，补进 `seed`/`mutate` 后即通过）。
> 不要为了让门禁变绿而删要求 —— 那等于把「验证过」降级成「碰巧没差异」。
