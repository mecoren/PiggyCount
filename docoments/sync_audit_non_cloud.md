# PiggyCount 同步相关代码检查报告（非 PiggyCount Cloud 范围）

> 检查日期：2026-08-14
> 检查方式：静态代码审阅（未运行，未修改任何代码）
> 范围：本项目所有**非 PiggyCount Cloud 同步**的同步机制、数据传输逻辑、状态管理与错误处理

---

## 一、检查范围界定

### 已排除（PiggyCount Cloud 同步，按用户决议一并排除）

- `lib/cloud/` 整个目录：`sync_service.dart`、`sync_engine.dart` 及其所有 `sync_engine_*` part 文件（`_apply` / `_attachments` / `_pull` / `_realtime` / `_profile` / `_serialization` / `_resolvers` / `_status`）、`transactions_sync_manager.dart`、`transactions_json.dart`、`sync_diff_service.dart`、`sync_fingerprint.dart`、`startup_sync_checker.dart`、`startup_sync_overlay.dart`（整个 `SyncEngine` 实现 `app.SyncService`，底层依赖 `PiggyCountCloudProvider` / `flutter_cloud_sync`，属云同步）。
- `lib/pages/cloud/` 整个目录：云备份/账户页、加密设置、设备页、成员/邀请/加入共享账本等协作页面。
- `lib/providers/sync_providers.dart`、`lib/providers/cloud_mode_providers.dart`、`lib/providers/shared_ledger_providers.dart`（含共享账本协作同步）。
- `lib/data/encryption/`（云同步 E2EE：`encrypted_cloud_provider.dart`、`encrypted_cloud_storage.dart`、`encryption_service_impl.dart`、`argon2_key_derivation.dart`、`aes_gcm_cipher.dart`、`secure_key_storage.dart`）。

### 本次检查覆盖（非云同步 / 数据传输）

| 模块 | 关键文件 |
| --- | --- |
| 桌面小组件数据同步（App ↔ 系统小组件） | `lib/widget/widget_data_service.dart`、`widget_manager.dart`、`widget_spec.dart`、`views/*`、`lib/providers/widget_provider.dart` |
| CSV / JSON 数据导入 | `lib/services/data_import_service.dart` |
| 文件读取与编码识别 | `lib/services/import/file_reader.dart` |
| 附件导出 / 导入（tar.gz） | `lib/services/attachment_export_import_service.dart` |
| 应用配置导出 / 导入（YAML） | `lib/services/export/config_export_service.dart` |
| 导入状态管理（Provider） | `lib/providers/import_export_providers.dart` |

> 说明：检查同时覆盖云同步与本地导入**共用**的代码路径（如 `DataImportService` 既服务 CSV 导入也服务云恢复），但仅就其在**本地/非云导入**场景下的表现给出结论。

---

## 二、问题总览（按严重度）

| 编号 | 位置 | 类型 | 严重度 |
| --- | --- | --- | --- |
| B1 | data_import_service.dart `importAccounts/importCategories/importTags` | 粗粒度异常捕获，单条坏数据中断整段导入 | 🔴 高 |
| B2 | data_import_service.dart `importData` 返回 `ImportResult` | 账户/分类/标签导入失败不计入结果，UI 误报成功 | 🔴 高 |
| D1 | attachment_export_import_service.dart `importAttachments` 覆盖分支 | 先删后写，写入失败导致附件数据丢失 | 🔴 高 |
| A1 | widget_manager.dart / widget_provider.dart 多触发点 | 小组件刷新触发器无去抖/合并 | 🟠 中 |
| A2 | widget_manager.dart `_renderView` / `WidgetGatherBatch` | 整条同步管线在 main isolate，阻塞 UI | 🟠 中 |
| A3 | widget_provider.dart `updateAppWidget` | 静默吞掉所有异常（连日志都没有） | 🟠 中 |
| A4 | widget_manager.dart `updateAllWidgets` 末端 `updateWidget` 循环 | 单个 refresh 失败中断其余组件刷新 | 🟠 中 |
| B3 | data_import_service.dart `importCategories` | 二级分类依赖顺序，父级缺失则子级静默丢弃 | 🟠 中 |
| C1 | file_reader.dart `decodeBytes` | GBK 启发式误判，特定编码下静默乱码 | 🟠 中 |
| D2 | attachment_export_import_service.dart | 不校验 transactionId，产生孤儿附件 | 🟠 中 |
| D3 | attachment_export_import_service.dart | 导出/导入全程内存构建归档，大文件 OOM 风险 | 🟠 中 |
| E1 | config_export_service.dart `exportToYaml` | 手动拼 YAML 未转义，特殊字符致损坏/注入 | 🟠 中 |
| E2 | config_export_service.dart `mask` + `importFromYaml` | 脱敏 `****` 被当真实值导入 | 🟠 中 |
| F1 | import_export_providers.dart `ImportProgress` | 进度不覆盖账户/分类/标签阶段，与 B2 叠加 | 🟠 中 |
| B4 | data_import_service.dart `importData` | 重复导入无按 syncId 幂等去重 | 🟡 低-中 |
| B6 | data_import_service.dart `flush` | 整批 flush 失败不重试 | 🟡 低 |
| B7 | data_import_service.dart `importTransactions` transfer 分支 | `failed++` 未触发 `onProgress` | 🟡 低 |
| C2 | file_reader.dart | 无 BOM 的 UTF-16 不支持 | 🟡 低 |
| C3 | file_reader.dart `_readFileWithProgress` | 大文件全量读入内存 | 🟡 低 |
| D4 | attachment_export_import_service.dart | 单附件删/写/建记录无事务，部分失败状态不一致 | 🟡 低-中 |
| D5 | attachment_export_import_service.dart | metadata 字段缺空安全 | 🟡 低 |
| A5 | widget_manager.dart 预热路径 | 多一次无谓 `getInstalledWidgets` 平台调用 | 🟡 低 |
| A6 | widget_data_service.dart `WidgetGatherBatch` | 同批次重复 `getLedgerById` | 🟡 低 |
| B5 | data_import_service.dart `importAccounts` | 账户全局按名去重，跨账本串接风险 | 🟡 低 |
| E3 | config_export_service.dart `importFromYaml` 后半 | 未完整审阅（文件长），建议单独复核 | ⚪ 备注 |

---

## 三、详细发现

### A. 桌面小组件数据同步（App ↔ 系统小组件）

#### A1. 触发器无去抖/合并（性能）🟠
- **位置**：触发点分散——
  - `lib/providers/widget_provider.dart:14` `updateAppWidget`（记账保存后、`language_settings_page.dart` 4 处）
  - `lib/app.dart:953` 前台恢复 → `updateAllWidgetsLocalized`
  - `lib/main.dart:197` `_WidgetUpdateObserver`（currentLedgerId 变更）→ `warmUpAllSpecs:true`
  - `lib/pages/main/ledgers_page_new.dart:766` 改账本起始日
  - `lib/providers/theme_providers.dart:79`、`473` 主题色 / 收支配色变更
- **问题**：上述触发可几乎同时到达（如「记一笔 + 主题切换」「登录后预热 + 前台恢复」）。`updateAllWidgets` 通过 `_renderGate` **串行化**多个批次（正确，避免全局 hook 交错），但**不做去抖/合并**——N 个触发 = N 个完整批次依次执行。每个批次都含 DB 查询（30 天净值趋势属重查询）与离屏渲染。
- **影响**：低配设备 / 大数据量下，多次完整渲染串行排队 → UI 卡顿、启动与切账本时的全目录预热（`warmUpAllSpecs`，12 个 spec）尤为昂贵。
- **建议**：引入 300–500ms 合并窗口（同 `ledgerId` 的多次触发合并为一次）；仅在 app 启动 / 切账本走 `warmUpAllSpecs`，高频数据变更维持「只渲已安装」快路径（该区分已存在，但各触发点各自独立调用，未聚合）。

#### A2. 整条同步管线在 main isolate（性能）🟠
- **位置**：`widget_manager.dart:_renderView`、`widget_data_service.dart:WidgetGatherBatch`、`widget_manager.dart` 各 `_renderXxx`。
- **问题**：`WidgetGatherBatch` 的 DB 聚合查询（尤其 `getNetWorthTrendSeries` 逐日余额）与 `HomeWidget.renderFlutterWidget` 离屏渲染都在主 isolate 的 async 流程内同步占用 CPU，无 `compute()` / 后台 isolate。
- **影响**：交易量大时，小组件刷新期间主线程被重查询+渲染占用，交互掉帧。
- **建议**：将重查询下沉到后台 isolate（注意 `HomeWidget` 平台通道需在 main isolate 调用，可 isolate 算数据、主 isolate 渲染）；或对 30 天趋势做缓存 + 节流。

#### A3. `updateAppWidget` 静默吞掉所有异常（可观测性）🟠
- **位置**：`lib/providers/widget_provider.dart:59`
  ```dart
  } catch (e) {
    // Silently fail to avoid disrupting the app
  }
  ```
- **问题**：有 `BuildContext` 的调用路径（记账保存、语言切换）吞掉**包括日志在内的**所有异常。与之相对，`updateAllWidgetsLocalized`（无 context 路径）在 `widget_manager.dart:323` 有 `logger.error`。两者错误处理不一致。
- **影响**：小组件同步一旦损坏（如某 spec 渲染异常、数据查询异常），用户/开发者完全无感知，问题被掩盖。
- **建议**：至少 `logger.warning(_tag, '小组件更新失败', e)`；与无 context 路径保持一致。

#### A4. 原生刷新循环单点失败中断其余组件（健壮性）🟠
- **位置**：`widget_manager.dart:302-317`
  ```dart
  for (final kind in kinds) {
    await HomeWidget.updateWidget(iOSName: kind);   // 无 try/catch
  }
  // Android 同理
  ```
- **问题**：渲染全部 spec 后，循环逐个 `HomeWidget.updateWidget(iOSName:)` / `qualifiedAndroidName:` 触发原生刷新。循环体未被 try/catch 包裹，任一 kind/provider 抛异常会跳出到外层 catch，导致**后续未刷新的组件停留在旧图**。
- **影响**：单个 iOS kind / Android provider 刷新失败 → 其余组件不刷新。
- **建议**：每个 kind/provider 单独 `try { await HomeWidget.updateWidget(...) } catch (e) { logger.warning(...) }`。

#### A5. 预热路径多一次无谓平台调用（性能/低）🟡
- **位置**：`widget_manager.dart:234` `orderCatalogForWarmUp(await _resolveSpecsToRender())`。
- **问题**：`warmUpAll` 模式本就忽略 installed 列表、渲染全目录，却仍调用 `getInstalledWidgets()` 平台通道，仅为了拿 ordering（退化对覆盖面无影响）。
- **建议**：warm-up 时直接 `orderCatalogForWarmUp([])`，省去每次启动的一次平台往返。

#### A6. 同批次重复 `getLedgerById`（性能/低）🟡
- **位置**：`widget_data_service.dart` `gatherGlance`(L133)、`gatherQuickAddCategories`(L279)、`gatherTopSpendingShares`(L344) 各自调用 `repository.getLedgerById(ledgerId)`，且未被 `WidgetGatherBatch` 缓存（`ledgerCurrency()` 有缓存，上述三处没有）。
- **影响**：单批次内同一 ledger 多查几次 DB（轻量，但可省）。
- **建议**：在 `WidgetGatherBatch` 内缓存 ledger 对象，三处复用。

---

### B. CSV / JSON 数据导入

#### B1. 粗粒度异常捕获，单条坏数据中断整段导入（一致性）🔴
- **位置**：`data_import_service.dart:288`(`importAccounts`)、`:379`(`importCategories`)、`:487`(`importTags`)——各自仅一个 `try { ...整个循环... } catch`。
- **问题**：循环中任一行抛异常（例如 `importAccounts` 里 `createAccount` 成功后紧接着的 `updateAccount(hidden:)` 失败）会**跳出整个循环**，返回部分映射（`accountNameToId`/`categoryCache`/`tagMaps` 只含已处理部分）。
- **影响**：
  1. 一条坏数据使后续同类实体全部跳过；
  2. 下游 `importTransactions` 用不完整的 `accountNameToId` → 大量交易因 `accountId==null` 被 `failed++`（见 L737-749），但根因（账户导入中断）只在日志里，且**不计入 `ImportResult.failed`**（见 B2）。
- **建议**：把 try/catch 下沉到单行——单个实体失败仅 `skip + 记录`，继续处理其余；避免「一条坏数据淹没整段」。

#### B2. `ImportResult` 只统计交易级失败，账户/分类/标签失败不可见（一致性）🔴
- **位置**：`data_import_service.dart:224` `importData` 仅返回 `importTransactions` 的结果；`importAccounts`/`importCategories`/`importTags` 的 create/update 失败被各自 catch 吞掉，失败数不回传。
- **问题**：`ImportResult(inserted, failed)` 的 `failed` 仅含交易层。账户导入失败时，调用方显示「导入成功」（failed 仅含下游交易），实际部分数据已丢失且无提示。
- **影响**：用户/UI 看到「导入完成」但账户、分类或标签缺失，且无任何失败计数提示。
- **建议**：让 `importAccounts/importCategories/importTags` 返回 `(created, updated, failed)` 并汇总进 `ImportResult`；UI 展示各阶段失败数（与 F1 联动）。

#### B3. 二级分类依赖顺序，父级未先建则子级静默丢弃（数据丢失）🟠
- **位置**：`data_import_service.dart:427-456` `importCategories` 二级分支。
- **问题**：`parentId` 来自 `categoryCache[parentKey]`；若导入数据里**二级分类排在父级之前**（或父级因与现有重名而未创建），`parentId == null` → 该二级分类被跳过，**无 failed 计数、无日志警告**。
- **影响**：分类导入顺序不当时，二级分类静默丢失（用户账本结构残缺）。
- **建议**：两遍 pass（先建所有一级 + 收集父名映射，再建二级）；或对缺失父级的子级延迟补建；至少返回 `skipped` 计数供 UI 提示。

#### B4. 重复导入无按 syncId 幂等去重（幂等性）🟡
- **位置**：`data_import_service.dart:224` `importData`（整体无基于 `entity_sync_id` 的去重）。
- **问题**：`importTransactions` 对每笔交易生成 `effectiveSyncId = tx.syncId ?? Uuid().v4()`（L819，已修复「不生成 syncId」问题），但对**已存在 syncId 的交易没有 upsert/跳过逻辑**——同一 JSON 对非空账本重复导入会产生重复交易。CSV 场景（无稳定 id）可接受，但 JSON 全量恢复路径缺少幂等保护。
- **影响**：重复执行导入 → 数据重复。
- **建议**：导入前按 `entity_sync_id` 检测已存在记录并跳过/更新（账户/分类/标签已有 syncId 字段，可扩展到交易）。

#### B5. 账户全局按名去重，跨账本串接风险（一致性）🟡
- **位置**：`data_import_service.dart:290-292` `importAccounts`（`accountNameToId` 来自 `getAllAccounts()`，账户全局 `ledgerId:0`）。
- **问题**：为某账本导入 CSV 时，若另一账本已有同名账户，会复用其 id。账户本身设计全局，影响有限，但语义上可能不符合「为这个账本导入」的预期。
- **建议**：文档化该行为；或导入时按 `(name, type, currency)` 更精确匹配。

#### B6. 整批 flush 失败不重试（健壮性）🟡
- **位置**：`data_import_service.dart:676` `flush()`。
- **问题**：`insertTransactionsBatchWithRelations` 抛异常 → 整批 500 条计 `failed` 并继续下一批，瞬时 DB 错误导致整批数据丢失且不重试。
- **影响**：瞬时错误（如 SQLite busy）造成一批交易无声丢失（有日志）。
- **建议**：flush 失败时重试一次（带退避）；或将失败明细返回供 UI 展示具体行。

#### B7. transfer 分支 `failed++` 未触发 `onProgress`（一致性/低）🟡
- **位置**：`data_import_service.dart:737-749`（`fromAccountName`/`toAccountName` 未解析到时 `failed++; processed++; continue;`）。
- **问题**：该分支跳过 `onProgress?.call(processed, total)`（仅在 `flush()` 内调用），进度条短暂滞后。
- **建议**：在此分支也调用 `onProgress?.call(processed, total)`。

---

### C. 文件读取与编码识别

#### C1. GBK 检测靠「是否含汉字」启发式，可能静默乱码（数据正确性）🟠
- **位置**：`file_reader.dart:105` `decodeBytes`。
- **问题**：解码顺序为 UTF-16 BOM → UTF-8 BOM → UTF-8(`allowMalformed:false`) → GBK → `allowMalformed` UTF-8 → latin1。关键缺陷：
  - 一个**合法的 UTF-8 中文文件**若因某字节损坏使 `utf8.decode(allowMalformed:false)` 抛异常 → 回退 GBK → 用 GBK 解读 UTF-8 字节 → **输出乱码且不报错**；
  - 反之纯英文/数字的 GBK 文件（不含汉字）可能不被识别为 GBK，落到 latin1，同样乱码。
- **影响**：特定编码组合下 CSV 内容被静默解读错误 → 导入数据错乱（金额/分类名乱码），用户无感知。
- **建议**：优先用带 BOM / 明确标记的编码；对「UTF-8 含 U+FFFD」不要直接回退 GBK，可先尝试 `allowMalformed` 的 UTF-8；GBK 仅作为「无 BOM 且 UTF-8 明确失败且文件疑似 GBK」的最后手段，并保留原始 bytes 以便回退。

#### C2. UTF-16 无 BOM 不支持（兼容性/低）🟡
- **位置**：`file_reader.dart:106-126`。
- **问题**：仅检测 `FF FE`/`FE FF` BOM；无 BOM 的 UTF-16 会被误判。
- **建议**：如有需求可补充无 BOM UTF-16 探测（风险低，备注即可）。

#### C3. 大文件全量读入内存（性能/低）🟡
- **位置**：`file_reader.dart:56` `_readFileWithProgress`（分块读入多个 `List<int>` 再 `addAll` 拼接，峰值 ≈ 2× 文件大小）；`decodeBytes` 构造完整 `String`。
- **影响**：超大 CSV 内存峰值高。
- **建议**：流式解析（逐行），避免一次性物化整文件。

---

### D. 附件导出 / 导入（tar.gz）

#### D1. 覆盖模式先删后写，写入失败导致附件数据丢失（数据丢失）🔴
- **位置**：`attachment_export_import_service.dart:344-357` 覆盖分支。
  ```dart
  if (existsLocally) await localFile.delete();
  if (existsInDb) await repo.deleteAttachmentByFileName(fileName);
  overwritten++;
  // ... 之后才：
  await localFile.writeAsBytes(imageFile.content as List<int>);  // 若失败
  await repo.createAttachment(...);                              // 不会执行
  ```
- **问题**：在 `writeAsBytes` **之前**就删除了旧附件文件与 DB 记录。若写新文件失败（磁盘满 / 权限 / 进程中断），旧附件已删、新记录未建 → **旧新皆失**。
- **影响**：覆盖导入遇写入失败 → 用户永久丢失该附件。
- **建议**：先写临时文件 → 成功后再原子替换（重命名覆盖）旧文件、再改 DB；或写新文件名（带后缀）成功后删除旧文件，保证「至少保留一份」。

#### D2. 导入不校验 transactionId 存在性 → 孤儿附件（一致性）🟠
- **位置**：`attachment_export_import_service.dart:313-318` 注释明确「不检查交易是否存在」。
- **问题**：若交易导入失败/缺失，附件记录指向不存在的 `transactionId`，产生孤儿附件。
- **影响**：孤儿附件（引用空交易），UI/统计可能出现悬挂；导出再导入循环会持续携带。
- **建议**：导入交易完成后再做孤儿附件关联/清理；或在导入末尾跑一次「附件 transactionId 不存在则删除/暂存」的 GC。

#### D3. 导出/导入全程内存构建归档（性能/内存）🟠
- **位置**：`attachment_export_import_service.dart:85-175`（导出）、`:265-268`（导入）。
- **问题**：
  - 导出：`Archive` 把所有附件/图标 bytes 全部读入内存，`TarEncoder().encode` + `GZipEncoder().encode` 全量编码（常驻 ≈ 2–3× 总大小）；
  - 导入：`GZipDecoder().decodeBytes(bytes)` + `TarDecoder().decodeBytes(tarData)` 一次性解码整个归档到内存。
- **影响**：附件多/体积大（数百 MB）时内存尖峰，可能 OOM。
- **建议**：使用 archive 包的流式 encoder/decoder 或分卷处理；大文件边读边写。

#### D4. 单附件删/写/建记录无事务，部分失败状态不一致（一致性）🟡
- **位置**：`attachment_export_import_service.dart:346-368`。
- **问题**：`localFile.writeAsBytes` 成功但 `repo.createAttachment` 失败 → 有文件无记录（孤儿文件）；覆盖模式下旧已删、新记录未建 → 数据断点。三步无事务包装。
- **建议**：先建/更新 DB 再写文件，或写文件成功后再提交 DB，保证「文件 + 记录」原子。

#### D5. metadata 字段缺空安全（健壮性/低）🟡
- **位置**：`attachment_export_import_service.dart:294` `metadata['attachments'] as List<dynamic>`。
- **问题**：若 `metadata.json` 缺 `attachments` 键 → `as List` 抛 TypeError → 被外层 catch 返回 `success:false`，错误信息不够明确。
- **建议**：提前判空并给出「缺少 attachments 字段」的明确错误。

---

### E. 应用配置导出 / 导入（YAML）

#### E1. 手动拼接 YAML 未转义，特殊字符致损坏/注入（数据正确性）🟠
- **位置**：`config_export_service.dart:1791-2000+` `exportToYaml` 用 `buffer.writeln('  password: "${bc['password']}"')` 手写字符串。
- **问题**：值未做 YAML 转义。若密码 / `base_url` / AI `apiKey` 等字段含 `"` `\` 或换行/控制字符，生成的 YAML 非法或被注入额外键（如值内出现换行可制造新键）。
- **影响**：含特殊字符的配置导出后无法正确 import（解析错误或字段错乱），甚至被构造的恶意值注入配置项。
- **建议**：用 `yaml` 包的 `yamlEncode` 统一序列化（而非手写 `buffer`），或至少对值做 `jsonEncode`/`yamlEscape` 处理。

#### E2. 脱敏标记 `****` 被当真实值导入（数据正确性）🟠
- **位置**：`config_export_service.dart:1283` `mask` 与 `:2257` `importFromYaml`。
  ```dart
  String? mask(String? v) => options.includeCredentials
      ? v
      : (v != null && v.isNotEmpty ? '****' : v);
  ```
- **问题**：`includeCredentials=false`（默认）时，非空密码/密钥被替换为字面量 `'****'` 并写出。而 `importFromYaml` **不识别 `****` 哨兵**，直接把 `password:'****'` / `apiKey:'****'` 写回 prefs / provider 配置。
- **影响**：用户导出「不含凭据」（默认）的配置再导入 → 密码被设为字面量 `****`，登录失败 / AI provider 密钥损坏。
- **建议**：导出时对脱敏字段**直接不写该键**（而非写 `****`）；或导入时把 `****` 视为「跳过此字段，保留现有值」。

#### E3. `importFromYaml` 后半段未完整审阅（备注）⚪
- **位置**：`config_export_service.dart:2257` 起，`importFromYaml` 的账户/分类/标签/预算/周期账单数据导入段（约 2544 行之后）因文件较长未在本轮完整审阅。
- **建议**：单独复核后半段是否对各数据段一致地 try/catch、是否有与 B1/B2 类似的「失败不计入结果」问题。

#### E4. 配置导入按名去重，重名跨账本风险（一致性/低）🟡
- **位置**：`config_export_service.dart:2521` 账本按 `name.toLowerCase()` 去重（与 B5 同类）。
- **建议**：备注即可，文档化行为。

---

### F. 导入状态管理（Provider）

#### F1. `ImportProgress` 仅反映交易导入，UI 误报成功（可观测性）🟠
- **位置**：`import_export_providers.dart:4` `ImportProgress`（`total/done/ok/fail`）。
- **问题**：进度由导入流程驱动，而由于 B2（账户/分类/标签失败不计入 `ImportResult`），进度里的 `fail` 与实际失败数不符，UI 显示「成功」但实际部分失败。
- **建议**：与 B2 联动，扩展进度模型纳入各阶段结果（账户/分类/标签的 created/updated/failed）。

#### F2. Cloud 恢复状态 Provider 已排除（范围）
- **位置**：`import_export_providers.dart:57` `CloudRestoreProgress` / `:101` `CloudRestoreSummary` / `:120` `cloudRestoreLogProvider`。
- **说明**：这些属于云恢复状态，按用户决议排除，不在本报告范围。

---

## 四、优先修复建议（按 ROI）

1. **🔴 B1 + B2（一起修）**：把 `importAccounts/importCategories/importTags` 的异常捕获下沉到单行，并让各方法返回 `(created, updated, failed)` 汇总进 `ImportResult` + `ImportProgress`。这是当前数据导入最隐蔽的「静默丢数据」来源。
2. **🔴 D1**：覆盖导入改为「写临时文件 → 原子替换 → 再改 DB」，杜绝先删后写的数据丢失。
3. **🟠 A1 + A2**：小组件刷新加去抖 + 重查询下沉 isolate，改善卡顿与启动/切账本开销。
4. **🟠 A3 + A4**：统一小组件同步的错误日志；`updateWidget` 循环逐点 try/catch。
5. **🟠 C1**：修正编码探测顺序，避免合法 UTF-8 中文文件被误当 GBK 而静默乱码。
6. **🟠 E1 + E2**：配置导出改用 `yamlEncode` 并修正脱敏哨兵处理，保证导出/导入往返正确。
7. **🟠 D2 + D3**：附件导入补孤儿清理、大归档改流式处理。

---

## 五、未覆盖 / 需补充

- `config_export_service.dart` 的 `importFromYaml` 后半（账户/分类/标签/预算/周期账单数据导入段，约 2544 行起）本轮未完整审阅（E3）。
- `lib/services/attachment_service.dart`（`getAttachmentDirectory` / `createAttachment` 等）仅通过调用方间接审阅，未逐行检查其文件写入/路径处理细节。
- 本次为纯静态审阅，未运行测试或构造边界数据验证上述假设；建议对 B1/B2/D1/E2 编写针对性单测。
