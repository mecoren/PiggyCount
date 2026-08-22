# PiggyCount 项目全面审查报告

> 审查时间：2026-08-20
> 审查范围：同步功能与同步加密（逻辑一致性 / 数据完整性 / 安全性）、UI 层（交互体验 / 视觉一致性 / 渲染）
> 审查方式：源码逐文件精读（加密核心、同步引擎、云同步协议包、UI 主题与核心页面）+ 子代理并行审查云协议包与 UI 层，关键高危结论均二次核实。

---

## 第一部分：同步功能与同步加密

### 1.1 关键高危发现（致命 / 高）

| # | 问题类别 | 严重等级 | 具体位置 | 问题描述 | 建议修复方案 |
|---|---------|---------|---------|---------|------------|
| S1 | 数据完整性 / 同步逻辑 | **高（可升级为致命）** | `lib/cloud/sync/sync_engine.dart:1271-1284`、`1247-1295`；`lib/cloud/sync/sync_engine_apply.dart:19-23` | 拉取路径 `_decryptPullResult` 对**任何解密失败**（密码错、salt 错配、密文损坏）的变更，将 payload 置 `null` 而非报错；`applyRemoteChange` 对 `payload==null` 且非 delete 的变更直接 `return false`（跳过）；`_applyPullPage` 仅在 `ok==true` 时计数、不抛异常；随后 `_runPullLoop` 仍执行 `appCursor.commit(serverCursor)` **推进游标**。结果：解密失败的变更被**永久静默丢弃且游标前进**，完全绕过了已有的 `pullErrors` 隔离/暂停机制。 | 解密失败的变更应视为"应用失败"，进入 `pullErrors` 记录并**阻塞该页（cursor 不前进）**，与 `_applyPullPage` 的整页回滚逻辑一致，而非静默跳过。避免本地 DB 与服务端权威态永久分歧。 |
| S2 | 加密一致性 / 密钥轮换 | **高** | `lib/data/encryption/encryption_service_impl.dart:362-422`、`434-508`；推送加密点 `lib/cloud/sync/sync_engine.dart:1224` | `changePasswordWithCloudReEncryption` 仅调用 `_reEncryptCloudDataWithKeys` 重加密 `ledger_*.json` **快照文件**，但**从未重加密 PiggyCount Cloud 的 `sync_changes` 增量日志**。而增量推送路径 `_encryptPayloadsIfNeeded` 用当前激活密钥加密每个 change 的 payload。改密后，服务端已推送的 `sync_changes` 仍用**旧密钥**加密。新设备/其他设备拉取这些旧 change 时触发 S1 的解密失败 → 被静默丢弃。**S1 + S2 组合在"改密后加入新设备"场景下可导致真实数据丢失。** | 改密流程必须同时重加密 `sync_changes` 增量日志（旧 key 解密→新 key 加密→回写），或改为"加入/恢复时强制先 fullPull 快照（已重加密）再增量，且增量回放对解密失败的旧 change 忽略而不前进游标"。更稳妥：增量日志也纳入重加密范围。 |
| S3 | 数据泄露 / 凭据存储 | **高** | `packages/flutter_cloud_sync/lib/src/providers/piggycount_cloud_provider.dart:1757`；`toJson()` `:3484-3490` | PiggyCount Cloud 登录后会话（`accessToken` + `refreshToken`）通过 `prefs.setString(_sessionStorageKey, jsonEncode(session.toJson()))` 写入**默认 `SharedPreferences`**（Android 明文 XML / iOS plist，**非加密**）。任何具备 root / ADB / 备份读取权限的进程可窃取 bearer token，进而以用户身份访问云端账本。同工程 WebDAV/S3 凭据已用 `FlutterSecureStorage(encryptedSharedPreferences:true)`，此处后端不一致。 | 改用 `FlutterSecureStorage`（与 `CloudServiceStore` 同一安全后端）持久化会话，或至少对 token 字段加密后再写入。 |
| S4 | 数据泄露 / 传输安全 | **高** | `packages/flutter_cloud_sync_s3/lib/src/s3_client.dart:574`；`s3_endpoint.dart:36` | S3 后端允许 `useSSL=false` 走明文 `http`；更关键的是 `parseS3Endpoint` 在 endpoint 带 `http://` 前缀时会**强制覆盖** `useSSL=false`。而 WebDAV 后端（`webdav_provider.dart:73-78`）硬性拒绝非 HTTPS。当自建 S3（MinIO 等）使用 `http://` 时，账本明文内容与 SigV4 签名均在裸链路传输，可被窃听/中间人篡改。 | 像 WebDAV 一样默认拒绝明文 HTTP，除非用户显式勾选"仅受信任内网"并弹二次确认告警；UI 在检测到 `http://` endpoint 时强制提示风险。 |
| S5 | 数据完整性 / 冲突解决 | **高（快照模型固有限制）** | `packages/flutter_cloud_sync/lib/src/cloud_sync_manager.dart:451-479`；`lib/cloud/transactions_sync_manager.dart:1096-1098` | 路径 A（WebDAV/S3/iCloud 自建存储）采用**整账本快照覆盖**模型，无逐实体（按 syncId）合并。两设备离线各编辑同一账本后，方向判定为 `different`/`unknown`，一旦用户在任一端"选边"，**另一端独有交易被整体覆盖丢失**，无任何 merge。 | 向用户明确披露此限制（文档 + UI 提示）；所有触发 `SyncDiff.different` 的路径必须强制二次确认（当前启动检查器已部分规避，需保证非启动路径也弹确认）；中长期引入按 syncId 的实体级合并或"双向保留为新账本"。 |

### 1.2 中危发现（建议修复）

| # | 问题类别 | 严重等级 | 具体位置 | 问题描述 | 建议修复方案 |
|---|---------|---------|---------|---------|------------|
| S6 | 加密安全模型 | **中** | `lib/data/encryption/encryption_service_impl.dart:586-594`、`lib/data/encryption/secure_key_storage.dart` | 主密码在 App 启动后**无需重新输入**：派生 AES 密钥持久化于 secure storage，`encrypt/decrypt` 在 `_activeKey==null` 时自动从 secure storage 加载进内存。此后只要设备已解锁（或 App 锁为简单 PIN），即可读取/写入云端密文，**无需主加密密码**。用户可能误以为"主密码"是数据访问闸门。 | 若需主密码门控，应在 App 进入后台/锁屏后清空内存密钥（`_clearActiveKey`），并在下次加密操作前强制重新输入密码派生；或在文档中明确该设计取舍。当前为可用性与安全的权衡，需显式决策。 |
| S7 | 加密密钥存储 | **中** | `lib/data/encryption/secure_key_storage.dart:45-47` | 直接存储**派生后的 32 字节 AES 密钥**（而非仅密码/盐）。若设备被攻破（root/jailbreak 绕过 Keystore/Keychain），该密钥可直接用于解密云端全部历史密文，无需主密码。 | 对极高安全需求场景，可考虑密钥不落盘、仅在会话内由密码派生并驻留内存（配合 S6）；否则至少在隐私文档中声明风险边界。 |
| S8 | 上传原子性 / 数据丢失窗口 | **中** | `packages/flutter_cloud_sync_webdav/lib/.../webdav_storage_service.dart:59-69` | WebDAV `uploadBinary` 采用"先 `remove(fullPath)` 再 `rename(tempPath, fullPath)`"，删除旧文件与重命名完成之间存在窗口：若 `rename` 失败（网络中断），旧文件已删而临时文件在 catch 中被清理（`:72-77`），**云端该账本文件短暂/永久丢失**直到下次上传。属于"先删后传"风险。 | 改为"先 rename 到临时目标名、成功后再 remove 旧文件"，或优先用支持覆盖的 `put(overwrite:true)`，消除删除-重命名之间的失效窗口。 |
| S9 | 错误处理 / 数据恢复 | **中** | `lib/cloud/transactions_sync_manager.dart:796-804` | `_decryptIfNeeded` 在密钥存在但密文解密失败时返回 `null`，`downloadAndRestoreToCurrentLedger` 直接 `return (inserted:0,...)` 静默结束。若单个账本密文损坏/密钥错配，整个恢复**静默无操作**，用户看到"什么都没发生"且无错误提示。 | 解密失败应抛出明确异常（或返回带错误标记的 result），由 UI 弹窗提示"密文损坏/密钥不匹配，无法恢复"，而非静默返回 0。 |
| S10 | 同步状态准确性 | **中** | `lib/cloud/sync/sync_engine.dart:272-335` | `getStatus` 仅依据"本地未推送变更数 + 远端文件是否存在"判定，无法感知"**云端有本地尚未拉取的更新**"。UI 可能显示 `inSync` 而实际远端已有未拉取数据。 | 在变更日志路径引入"远端未拉取 change 数"的探测（或维护本地已应用的 cursor 与远端 latest cursor 对比），使状态能区分 `localNewer` / `remoteNewer` / `inSync`。 |
| S11 | 密码强度策略 | **中** | `lib/data/encryption/encryption_service_impl.dart:753-762` | `_validatePassword` 仅校验非空与长度 ≥ 8，**无复杂度/弱密码/常见密码拦截**。用户可设 `12345678` 之类弱密码，Argon2id 难以抵消弱口令的离线爆破风险。 | 增加弱密码字典/复杂度提示（至少提示而非强制），并在 UI 设置页给出强度反馈。 |

### 1.3 设计局限 / 可接受项（知悉即可）

| # | 类别 | 说明 | 位置 |
|---|------|------|------|
| S12 | 元信息泄露（可接受） | E2EE 下 `entity_type`/`ledger_id`/`action`/`updated_at` 以明文上行供服务端路由（LWW 服务端裁决所需），仅 payload 内容加密。属"服务端权威 LWW + 内容 E2EE"的固有权衡。 | `sync_engine.dart:1224`、`_encryptPayloadsIfNeeded` |
| S13 | 明文云端（用户选择） | E2EE 关闭时 `EncryptedCloudStorageService` 返回原文，账本 JSON（含金额/备注）明文落云端，属用户主动选择，非缺陷。 | `encrypted_cloud_storage.dart:39-42` |
| S14 | S3 accessKey 入日志（低） | `CloudUser.id` 拼接 `accessKey`，进入日志/realtime channel 等辅助输出，扩散敏感标识。 | `s3_auth_service.dart:18` |
| S15 | 状态缓存 TTL（低） | `cloud_sync_manager` 状态缓存 30s，另一设备在此期间上传后本地 `getStatus` 可能短暂误判 `synced`。性能/一致性权衡。 | `cloud_sync_manager.dart:94` |

---

## 第二部分：UI 层（交互体验 / 视觉一致性 / 渲染）

### 2.1 中危发现

| # | 问题类别 | 严重等级 | 具体位置 | 问题描述 | 建议修复方案 |
|---|---------|---------|---------|---------|------------|
| U1 | 国际化 (i18n) | **中** | `lib/widgets/biz/transaction_list_item.dart:420-421` | 侧滑删除确认框使用**写死的中文字符串**（`'确认删除'` / `'确定要删除这笔交易吗？此操作无法撤销。'`），未走 `AppLocalizations`；英文环境下显示中文，而同文件 `transaction_list.dart:631` 已正确使用 l10n，前后不一致。 | 改用 `l10n.deleteConfirmTitle` / `l10n.deleteConfirmMessage`。 |
| U2 | 暗色模式 / 视觉一致性 | **中** | `lib/widgets/biz/ledger_card.dart:304,311,318`；`lib/widgets/ui/message_popover_menu.dart:214`；`lib/widgets/biz/transaction_list.dart:627` / `transaction_list_item.dart:409`；`lib/app.dart:1400`（FAB 禁用态）；`lib/pages/main/analytics_page.dart:259`；`lib/pages/account/accounts_page.dart:1515,1824`；`lib/widgets/ui/wheel_date_picker.dart:567` | 多处组件**硬编码 `Colors.*`**（green/red/grey/0xFF2C2C2C 等）而非 `PiggyTokens`。暗色模式下浮层背景、同步状态色、删除色、FAB 禁用态、周期导航圈等与 token 体系割裂，对比度偏低或不跟随主题。 | 统一替换为 `PiggyTokens.success/error/iconTertiary/surfaceElevated/overlay/border/warning(context)`，消除散落魔法值。 |
| U3 | 可访问性 / 触摸热区 | **中** | `lib/pages/main/home_page.dart:815-877` | 头部多个 `IconButton` 设 `tapTargetSize: MaterialTapTargetSize.shrinkWrap` + `minimumSize: Size.zero`，触摸目标**远小于 48×48**，单手/无障碍操作困难。 | 保留视觉紧凑的同时至少维持默认 `minimumSize`（48×48）或加 `padding` 扩大热区。 |
| U4 | 渲染 / 大字体裁切 | **中** | `lib/main.dart:593-604`（全局 `TextScaler`） | 字体缩放通过包裹 `MediaQuery(textScaler)` 全局生效，但**仅缩放文字、不缩放图标/固定高度容器**。固定高度头部（56）、分段控件（32-38）、底部导航标签（`fontSize:10`）在自定义档位约 1.5× 时，文字可能超出固定容器被裁切。 | 对固定高度控件内文字用 `FittedBox`/`Expanded` 或限制最大缩放上限；关键标题区用 `MediaQuery` 排除缩放。 |

### 2.2 低危 / 优化项

| # | 问题类别 | 严重等级 | 具体位置 | 问题描述 | 建议修复方案 |
|---|---------|---------|---------|---------|------------|
| U5 | 列表性能 | **低（优化）** | `lib/widgets/category/category_selector.dart:192-201,400-408` | `GridView.builder(shrinkWrap:true, NeverScrollableScrollPhysics)` 嵌套在 `ListView` 内，且每行分类再包一层 `GridView`；`shrinkWrap` 一次性构建全部网格项，弱化 builder 懒加载。 | 分类数量可控可暂保留；否则改用单一 `ListView.separated` + 卡片内 `Wrap`，避免双重滚动树全量构建。 |
| U6 | 布局溢出 | **低** | `lib/widgets/biz/transaction_list_item.dart:354-395` | 右侧金额 `Column` 未包 `Expanded`/`Flexible`，仅靠左侧 `Expanded` 挤压；金额含币种符号且数值极大（亿级）+「≈折算」第二行时，右侧列按固有宽度占用，可能触发 `Row` 溢出（RenderFlex overflow）。 | 给金额 `Column` 外包 `Expanded`/`Flexible`，并在 `AmountText` 加 `maxLines/overflow` 保证超长省略。 |
| U7 | 一致性（字号魔法值） | **低** | 多处（`ledger_card.dart`、`transaction_list_item.dart:286`、底部导航 `app.dart:1231` 等） | 字号散落硬编码（10/11/12/14/15/16/18），未收口到 `PiggyTextTokens`/`PiggyDimens`。 | 收口到字号 token，便于统一字体缩放与改版。 |
| U8 | 一致性（主题色） | **低** | `lib/app.dart:1161`（`_PiggyBottomBar`）；`lib/pages/main/home_page.dart:711-773` | 底部导航未选中色写死 `isDark ? Colors.white70 : Colors.black54`（与 token 等价但绕过体系）；中心按钮长按拖动未做边界 clamp，拖出屏幕后子按钮可能飞出可视区。 | 复用 `PiggyTokens.iconSecondary(context)`；长按拖动加 `clamp` 边界限制。 |
| U9 | 一致性（遮罩） | **低** | `lib/pages/main/analytics_page.dart:550` | 分享海报 loading 遮罩写死 `Colors.black.withValues(alpha:0.3)`，而 token `overlay` 为亮 0.5 / 暗 0.7，暗色下偏淡。 | 改用 `PiggyTokens.overlay(context)`。 |

---

## 第三部分：审查结论与优先级

### 已确认的优点
- 加密核心架构专业：Argon2id（memory-hard）+ AES-256-GCM（AEAD）+ verifier 校验 + secure storage + single-flight 密钥加载，注释详尽，缺陷修复记录完整。
- 同步引擎工程扎实：in-flight 单飞锁（push/fullPush/pull/fullPull/user-global）、cursor 安全（appCursor 接管、整页失败回滚隔离）、legacy backfill、LWW、N+1 消除（LookupCache/PushLookupCache）、附件内容寻址 + sha256 校验，均处理到位。
- UI tokens 体系完整，暗色模式以 token 单一来源为主；交易列表对上万条数据做了充分性能优化；空态/骨架/危险操作倒计时确认等交互细节到位。

### 必须优先处理（按风险排序）
1. **S1 + S2（联动致命）**：增量拉取解密失败被静默丢弃且游标前进，叠加改密未重加密 `sync_changes` → 真实数据丢失。修复 S1（解密失败进 pullErrors 并阻塞游标），并让 S2 覆盖增量日志重加密。
2. **S3**：PiggyCount Cloud 会话令牌明文落盘 → 改 `FlutterSecureStorage`。
3. **S4**：S3 明文 HTTP → 强制 HTTPS 或显式风险确认。
4. **S5**：多设备离线并发编辑快照覆盖丢失 → UI 强制二次确认 + 文档披露。
5. **UI**：U1（i18n）、U4（大字体裁切）、U3（触摸热区）、U2（暗色一致性）。

### 需产品决策的设计取舍
- **S6/S7**：主加密密码是否在每次访问时强制重新输入 / 派生密钥是否落盘。当前为"可用性优先"方案，需明确安全边界并在隐私文档声明。
