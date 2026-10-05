# SQLCipher 整库加密 —— 需求文档

> 状态：**设计中，待评审**。本文件与本目录 `design.md` **不动任何代码**；
> 实现属独立大件，需先评审选型与迁移方案（见 `design.md` §7「待定问题」）。

## 一、背景

PiggyCount 是离线优先的记账 app，业务数据全部落在本机 SQLite
（`PiggyCount` / `piggycount.sqlite`，drift 2.35.0，`schemaVersion=49`）。
库文件落在应用私有目录，但在 **root/越狱设备、ADB 备份提取、云备份/整机备份** 场景下
是明文可读的 —— 金额、备注、账户名、银行卡后四位全部暴露。

审计早已点名（`docs/security-and-ui-audit-2026-08-22.md` 表 #7、
`docoments/16-known-issues.md` 3.x、`docoments/12-security.md` 4.1.1）：

> 全局 Grep `sqlcipher|SQLCipher|encrypted.*database` 在 `lib/` 中**零匹配**。

笔记：仓库已有一套 **E2EE**（AES-256-GCM + Argon2id）保护**云端**快照与备份
（`lib/data/encryption/`），但那是「上传前加密」；**本地库本身仍是明文**，
两者是可叠加的两件事，不互相替代。

## 二、目标与非目标

### 目标（本轮要实现的能力）

- **R1 落盘即密文**：数据库主文件（含 `-wal` / `-shm`）在不持有密钥时不可读；
  用外部 `sqlite3` 工具直接打开应报「非数据库/需密钥」。
- **R2 密钥在系统安全区**：数据库密钥不以明文出现在 prefs、日志、异常信息、
  导出产物中；存放位置与同步密钥同级（`flutter_secure_storage`：
  Android Keystore / iOS Keychain）。
- **R3 老用户平滑迁移**：升级后首启把既有**明文库**一次性迁到加密库；
  迁移**幂等可重入**、**失败可回退**（迁移中途崩溃不得留下半个库或双份库）。
- **R4 不破坏既有能力**：健康探测（`quick_check`）、WAL、备份/恢复、附件归档、
  E2EE 云同步、清除数据、日志中心、性能基线脚本，行为不因加密而改变或失效。
- **R5 密钥丢失有明确出口**：密钥不可得时 app **不得静默清库**；必须给出
  可解释的界面（复用既有 `database_recovery_overlay` 通路）与「用云端备份重建」
  的引导。
- **R6 可关**：用户能显式关闭整库加密（回到明文），且关机路径同样原子、可回退。

### 非目标（明确不做）

- **不做字段级加密**（备注/金额单独加密）——整库加密已覆盖落盘风险，
  字段级会牵动全部查询与统计 SQL，收益不成立。
- **不引入「忘记密钥」的后门**：不做密钥托管、不上传密钥、不做弱 KDF 兜底
  （这意味着**密钥丢失 = 本地数据不可读**，产品上必须如实告知，见 R5）。
- **不替换 E2EE**：云端快照/备份的加密链路不动。
- **本轮不承诺性能数字**：加解密有成本，具体开销待真机基线（见 `design.md` §6）。

## 三、验收标准

1. **落盘不可读**：用系统 `sqlite3`（或 `python3 -c "import sqlite3..."`）直接打开
   迁移后的 `piggycount.sqlite`，必须失败（`file is not a database` / 需密钥）；
   `hexdump` 前 16 字节不得是明文 SQLite 头 `SQLite format 3\0`。
2. **持有密钥可读**：应用内一切读写（含 `PRAGMA quick_check` 健康探测）正常，
   全量 `flutter test` 与既有门禁（`sync_contract_coverage_test` 等）保持绿。
3. **迁移幂等 + 可回退**：构造「明文库 + 已存在加密库」「迁移中途 kill」两种态，
   重启后均得到**唯一且完整**的库；`PRAGMA integrity_check = ok`。
4. **密钥不泄漏**：`grep` 日志/异常字符串不存在密钥明文；导出的备份产物、
   配置导出里没有数据库密钥。
5. **清除数据仍可用**：应用锁「清除全部数据」后（`AppLockService.wipeAllData`），
   旧库与密钥都被清掉，重新启动得到全新的加密空库（或按用户选择回明文）。
6. **关闭加密**：显式关闭后，库回到明文且正常打开；再开启一次仍然通过第 1 条。
7. **健康探测不误报**：加密库上 `DatabaseHealthService.check()` 返回
   `DbHealth.ok`（**不得**把加密库误判成 `unreadable/corrupted` 并弹「数据可能已损坏」）。
8. 静态门禁：`flutter analyze --fatal-infos` → 0 issue；相关新测试全部绿且
   **负向验证过**（去掉密钥注入后断言必须变红）。

## 四、影响面与配套改动（供评审确认范围）

| 面 | 需要动 | 依据 |
|---|---|---|
| 依赖与构建 | `pubspec.yaml` 的 `hooks.user_defines.sqlite3` 选 `sqlcipher`/`sqlite3mc` 变体，或改走「自带 native 库 + `source: system, name:`」；`sqlite3_flutter_libs` 的去留 | `design.md` §2 |
| 连接层 | `lib/data/db.dart` 的 `_openConnection` / `migration.beforeOpen` 加 `setup`（`PRAGMA key`） | `design.md` §3 |
| 密钥层 | 新增 `lib/data/encryption/database_key_service.dart` | `design.md` §3 |
| 健康探测 | `lib/data/database_health_service.dart` 的只读探测连接必须带密钥 | `design.md` §4 |
| 恢复/引导 | `lib/widgets/biz/database_recovery_overlay.dart` 增加「密钥不可得」分支 | R5 |
| 设置 UI | 加密设置里增加「整库加密」开关 + 风险告知 + 迁移进度 | R3/R6 |
| 迁移 | 明文→密文的一次性迁移（临时文件 + 原子替换 + 回退） | R3 |
| 文档/脚本 | `docoments/16-known-issues.md` 状态更新；`scripts/seed_mem_baseline.py`、`scripts/profile_memory.py`、`docs/evidence/mem-baseline-*.md` 的「拉库/灌库」流程对加密库失效，需要新说明 | 见 §5 |

## 五、已知会在实现期「踩」到的地方（先记账）

1. **基线脚本会失效**：`docs/evidence/mem-baseline-2026-09-19.md` 的「adb 拉库 → 灌语料
   → 推回」流程，拉下来的将是一份**加密库**，`scripts/seed_mem_baseline.py`（裸 sqlite3）
   打不开。需在文档里写明：基线只在**未加密构建**上跑，或把密钥交给脚本。
2. **`hooks.user_defines.sqlite3.source: system` 是既有构建约束**（AGENTS 明说不要删，
   否则构建期会去 GitHub 下预编译 libsqlite3，国内网络失败）。而 SQLCipher 的
   预编译资产**同样来自 GitHub releases** —— 选型的核心矛盾就在这，`design.md` §2 给方案。
3. **许可**：`sqlite3` 包文档明确提示 SQLCipher/SQLite3MultipleCiphers **另有许可**，
   且 SQLCipher 构建在 Windows/Linux/Android 上链接 **OpenSSL**；对 BSL 授权的
   本项目需一次许可复核（属产品/法务动作，不是代码动作）。
4. **加密构建的 SQLite 版本可能落后于上游**（`sqlite3` 包文档原文），需确认
   我们依赖的 SQL 特性/Pragma 都在。

## 六、交付物（实现阶段的 DoD）

- `prd/sqlcipher_db_encryption/design.md`（本目录）评审通过，§7 待定项全部落定。
- 代码：密钥服务 + 连接层 `setup` + 原子迁移 + 健康探测适配 + 开关与引导 UI。
- 测试：`test/data/db_sqlcipher_test.dart`（加密连接/迁移往返/回退/密钥缺失分支）
  + 负向验证记录。
- 文档：`docoments/16-known-issues.md` 状态更新、基线脚本文档的加密说明、
  `AGENTS.md` 的「改 schema/依赖」注意项按需补充。
