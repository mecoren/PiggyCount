# P1-F 可观测性封装（同步异常→用户提示映射）+ 本地库损坏恢复 — 设计文档

> 需求见同目录 `requirements.md`。本文档写「怎么实现」与取舍。
> 落地提交：`7330b26`（主体）→ `74d3b16`（自查修正）→ `4b337c6`（性能）→ `dce6a0d`（widget 回归）。
>
> 命名说明：提交信息里的「P1-6」指优化评估报告**建议 6**；本文档目录名 `p1f_rec6_*` 是本轮
> P1 批次的编号。两者指同一件事。

## 一、需求理解

拆成两条互不依赖的线：

- **A 线（同步侧，纯映射）**：`classifyError` 的枚举与判定顺序补齐 + 展示层复用归因并本地化。
  无新组件、无新交互，属纯修 bug。
- **B 线（本地库侧，新能力）**：加一条「探测 + 引导恢复」链路。这条线的新增面积大得多，
  且**误报的代价远大于漏报**（见决策 2），所以设计重心全在「怎么不误报」上。

## 二、关键技术决策

### 决策 1：探测用独立只读连接，不复用 `PiggyDatabase`

复用主库实例会跑迁移，对已损坏的库存在**写入并扩大损坏面**的风险，还会与主连接争 WAL 锁。
只读连接（`sqlite3.open(path, mode: OpenMode.readOnly)`）在文件层面就不具备写入能力，
是探测应有的最小权限。代价：探测结果与主库状态可能有一帧差异（可接受，探测是启发式诊断）。

### 决策 2：四态判定 + 误报代价不对称 —— 只在有正面证据时报损坏

「打不开就报损坏」是这套设计里最容易犯的错：**环境问题（文件被占用、权限、云盘同步瞬间的锁）
会被判成损坏，然后把全屏引导推给所有正常用户**。而正确的失败方向恰好相反：
漏报 = 用户看到和改动前一样的空界面（不好，但没变坏）；误报 = 把正常用户吓到以为数据丢了，
甚至诱导他按「重置」。

因此判定顺序与证据要求如下（`DatabaseHealthService.check`）：

| 观察到的 | 判定 | 依据 |
|---|---|---|
| 打开成功 + `quick_check` 返回 `ok` | `ok` | 正面证据 |
| 打开成功 + `quick_check` 返回非 `ok` | `corrupted` | 正面证据（页级损坏/索引不一致/校验和不匹配） |
| 打开成功 + 后续语句报错 | 头合法 → `corrupted`；头非法 → `unreadable` | 以 SQLite 魔数（`_hasSqliteHeader`）区分「不是数据库」与「是数据库但坏了」 |
| 打开失败 + 头非法 | `unreadable` | 非 SQLite 文件 / 被截断 |
| 打开失败 + **头合法** | **`ok`**（并留 `detail` 痕迹） | 打不开是环境问题，不是损坏证据。**这一格是误报防线的核心** |
| 文件不存在（首次安装） | `ok` | 不是异常 |

### 决策 3：WAL 库的只读打开陷阱（决策 2 的具体来源）

SQLite 打开 WAL 模式的库需要一个**可写的 `-shm`**（共享内存索引）。若只读打开、
而 `-shm` 又不可写（或旁路文件缺失），SQLite 可能直接报 `SQLITE_CANTOPEN`／
`SQLITE_READONLY`——**于是一个完全健康的 WAL 库会被判 `unreadable`，触发全屏引导**。
这正是决策 2 里「打开失败 + 头合法 → 不报损坏」那一格的现实来源。

同时，`PRAGMA quick_check` 的调用要区分「open 失败」与「open 成功后的语句失败」——
两类失败在健康判定里的含义完全相反，混在一起就无法区分环境问题与真损坏。

### 决策 4：`quick_check` 测量结果 → 移出 UI isolate

原实现假定 `quick_check` 是「零成本」的。**实测推翻了这一假定**：在 36KB–9.6MB 区间耗时
4–44ms，总体随体积线性增长（≈4.5ms/MB，小库由固定开销主导），**没有上界**。
在 UI isolate 同步执行会让重度用户（大库）在启动首帧掉帧——而这条链路恰好只在启动时跑一次，
正是最不该掉帧的时刻。

改为 `Isolate.run` 后台执行，探测函数写成**纯函数**（返回记录而非依赖外部状态），
以便在 isolate 间传递。**注意**：后台 isolate 没有 `BackgroundIsolateBinaryMessenger`，
**不能用全局 `logger`**（其 MethodChannel 在后台 isolate 不可用），失败细节只能随结果返回、
由主 isolate 记录。

实测效果：300k 行的库在探测等待期间，主 isolate 正常转 1349 圈——即主线程未被阻塞。

### 决策 5：隔离 = 移动不删除；导出 = 复制不移动

- `quarantine`：把主库及其 WAL 旁路（`-wal`/`-shm`）**移**到保留目录，目录名带时间戳防碰撞。
  移动而非删除，因为损坏库往往仍可被专业工具部分恢复。
- `exportCopy`：**复制**一份到用户可见位置，不动原文件——导出是「留存证据」，不是「搬走」。
- **绝不自动执行**：两者都只在用户显式确认后调用。

### 决策 6：覆盖层挂在 `MaterialApp.builder` 的 Stack 顶层 → 一切交互内联

`DatabaseRecoveryOverlay` 返回 `Positioned.fill` 的 `Material`，插在
`MaterialApp.builder` 的 Stack 里，位置**在 Navigator 之上**。推论：

- 不能用 `Navigator.of(context)`、不能弹 `AppDialog`——那些 API 在这个位置没有可用的 Navigator。
- 因此「重置」的二次确认态（`_confirmingReset`）与所有反馈都必须**内联**在该组件内
  （就地切换按钮状态/文案），而不是弹对话框。
- 组件为 `ConsumerStatefulWidget`，只 watch `dbHealthProvider` 与 `dbHealthDismissedProvider`
  两个 provider，不引入其它依赖。

### 决策 7：`dbHealthProvider` 不进 `main()` 的启动并行链

`main()` 的启动链是 `Future.wait` 并行预热，**刻意不把健康探测加进去**：探测有 IO 开销，
把它串进启动关键路径会拖慢首帧。改为由 UI 首帧惰性订阅（覆盖层自己 watch），
探测结果回来前 `valueOrNull` 为 null → 覆盖层不渲染 → 健康用户零感知。

`dbHealthDismissedProvider`（`StateProvider<bool>`）**仅本会话隐藏**，不持久化：
下次启动仍会探一次，避免「用户上次忽略了损坏，之后就永远不再提示」。

### 决策 8：A 线的判定顺序（`notConfigured` 先于 auth）

`SyncErrorClass` 已是既有枚举，本需求只补 `notConfigured` 并调整判定顺序：
「未配置」必须**先于** auth 判定——未配置云端时抛出的异常形态可能与认证失败相似，
顺序反了就会把「你还没配置」说成「登录过期」。`label` 保持稳定串（可聚合的日志口径），
**不由 l10n 决定**；本地化发生在展示层（决策 9）。

### 决策 9：本地化边界 —— 归因不翻译，展示才翻译

`classifyError` 返回的枚举与 `label` 是**诊断口径**，保持英文稳定串；
`sync_health_card` 的 `_errorClassLabel(l10n, cls)` 负责把它翻成用户语言，
未知枚举落 `l10n.syncErrOther`。这样新增枚举时不会因为漏了一条 ARB 词条就显示英文枚举名。
`cloud_sync_page` 的备份/下载失败提示改为复用 `classifyError`（原先自判 auth/非 auth，
把「未配置」与「数据损坏」兜成了网络问题，等于把 A 线修好的归因在展示层又抹掉一次）。

## 三、实现步骤

1. **A 线**：补 `SyncErrorClass.notConfigured` + 判定顺序 + `CloudNotAuthenticatedException`
   归入 `auth` → `sync_health_card` 走 l10n → `cloud_sync_page` 复用 `classifyError`。
2. **B 线 - 服务**：`DatabaseHealthService`（`check` / `_probeOffMain` / `_probeSync` /
   `_hasSqliteHeader` / `quarantine` / `exportCopy`）。先写 RED 单测（AC-R3 的 8 个场景，
   真实临时文件），再实现。
3. **B 线 - UI**：`dbHealthProvider` + `dbHealthDismissedProvider` →
   `DatabaseRecoveryOverlay` → 挂进 `main.dart` 的 `MaterialApp.builder` Stack。
4. **l10n**：12 条 `dbHealth*` 词条 × 4 语言（en / zh / zh_TW / ko），en 侧含 4 条占位符元数据。
5. **依赖**：`sqlite3` 从传递依赖升为直声明（`pubspec.yaml`）——直接 import 的包不该靠传递依赖。
6. `flutter analyze --fatal-infos` + 全量 `flutter test`。
7. **自查**（产出了 `74d3b16`）：逐条重读自己写的判定与断言，修正误报防线与恢复动作顺序。
8. **性能修复**（`4b337c6`）：决策 4。
9. **widget 回归**（`dce6a0d`）：补 UI 接线测试——此前只有服务层单测，属「逻辑对但没接线」的缺口。

## 四、边界条件与风险

| 风险 | 缓解 |
|------|------|
| **误报损坏（最高危）**：健康 WAL 库被判 `unreadable` → 全屏引导推给所有用户 | 决策 2 的四态表 + 决策 3；「打不开 + 头合法 → `ok`」；AC-R3 #5 专门覆盖「WAL + 主连接仍打开」 |
| 探测本身被误判为「文件被改」 | 只读连接 + AC-R3 #8 断言探测前后文件字节/mtime 不变 |
| 用户按「重置」丢失本可恢复的数据 | 二次确认态 + 隔离语义是移动而非删除（决策 5）+ 导出入口前置在重置之前 |
| 引导层挡住健康用户的界面 | `valueOrNull` 为 null 时不渲染；AC-R4 #1 断言健康态不占屏 |
| 大库探测卡首帧 | 决策 4（`Isolate.run`）+ 决策 7（不进启动并行链） |
| 后台 isolate 用全局 `logger` 崩溃 | 探测写成纯函数，细节随结果返回、主 isolate 记录 |
| 每次启动都提示已忽略的损坏 | `dbHealthDismissedProvider` 不持久化（决策 7）——这是**有意**让提示在下次启动回来 |
| 新增枚举漏配 l10n 词条 → 显示英文 | 未知枚举统一落 `syncErrOther`（决策 9） |
| 测试把 bug 固化成断言 | 见第五节：`sync_health_card_test` 原断言 `'Network timeout'` 实际固化了 i18n bug，已改为「网络超时」 |

## 五、复查记录（本轮自己写错、并已修正的三处）

> 这三处都属「写完自测通过、但结论是错的」，记在这里作为后续同类工作的检查项。

1. **「零成本」性能断言错误**：原注释断言 `quick_check` 可忽略。实测 4.5ms/MB 且无上界，
   已改为后台 isolate（决策 4）。**教训：性能结论必须实测，不能靠体量直觉。**
2. **0 字节文件的断言写错（代码是对的）**：0 字节文件在 SQLite 是合法空库、`quick_check`
   返回 `ok`，原断言却写成 `unreadable`。已改为断言 `ok`——**测试写错时不能改代码去迁就测试。**
3. **「从云端备份恢复」按钮必然失败**：云端恢复要写库，库坏时写不进。已移除该入口，
   动作重排为「导出留存 → 重置 → 稍后处理」。**教训：恢复路径里的每个动作都要先问「库坏时它还成立吗」。**

另外补了一处 UI 接线缺口：服务层 13 个单测全绿，但覆盖层与 provider 的接线完全没测
（`dce6a0d` 补 7 个 widget 用例）。**服务层单测不能替代 UI 接线测试，两者验证的是不同的东西。**
