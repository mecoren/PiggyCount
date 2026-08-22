# PiggyCount 全面审查报告（2026-08-22）

> 审查范围：同步功能与同步加密（逻辑一致性 / 数据完整性 / 安全性）、UI 层（交互体验 / 视觉一致性 / 渲染）。
> 审查方式：对 2026-08-20 既有审计逐项**源码复核**（确认当前状态），并**额外审查 08-20 之后的 3 个同步提交**（`3967883`、`5215bdd`、`337950c`），外加对 UI 层的全仓扫描与新发现挖掘。所有高危结论均已二次核实源码。

---

## 第一部分：近期同步修改的正确性验证（用户重点关注）

| 提交 | 验证结论 | 残留风险 |
|---|---|---|
| `3967883` 修复 S3 快照导入 adjustment 丢失 + 分类 syncId 漂移 | **正确且完整**。导入类型白名单已加 `'adjustment'`（`transactions_json.dart:477`）；`importCategories` 新建分类透传 `syncId` 并写入 changeTracker（`data_import_service.dart:607-629` + `local_repository.dart:1196/1226`），根因（新 UUID 被 H3 镜像误删）已消除；并配有 `s3_roundtrip_consistency_test` 回归测试。 | 无。建议顺带确认 CSV 导入路径无同类 `adjustment` 过滤（本次范围外）。 |
| `5215bdd` recurring 周期实例双重防重 | **同设备、同时区下正确且完整**。A 方案（生成器 `existsRecurringInstance` 命中跳过）+ B 方案（恢复侧按 `(recurringId, happenedAt)` 去重）双向拦截，`recurringId` 全局唯一主键已隐式隔离账本。 | 见 REC-01~04：跨时区恢复、手动非 0 点实例、单条周期规则 import 失败、导入期 N 次查询性能。 |
| `337950c` 特性开关停用 PiggyCount Cloud 实时协同 | **主通道有效阻断**。路径 B（SyncEngine 实时协同）的两处拦截点（`syncServiceProvider:186`、`piggycountCloudProviderInstance:571`）生效，路径 A（S3/WebDAV/Supabase/iCloud）不受影响。 | 见 REC-05~06：直连 `createCloudServices` 路径与 `syncEngineProvider` 空守卫未覆盖。 |

### 近期修改新增发现

| # | 问题类别 | 严重等级 | 具体位置 | 问题描述 | 建议修复方案 |
|---|---|---|---|---|---|
| REC-01 | 同步逻辑 / 跨时区 | 中 | `transactions_json.dart:166`(导出 `.toUtc()`) / `:750`(导入 `.toLocal()`)；去重键 `data_import_service.dart:1356` | 去重键为精确 `DateTime` 相等。导出 UTC、导入本地，跨时区恢复时导入实例的本地时刻与生成器本地 0 点落在**不同日历日** → `existsRecurringInstance` 漏判 → 仍重复。 | 去重键改为"日期维度"归一（UTC `yyyy-mm-dd` 或同日历日），而非精确时刻相等。 |
| REC-02 | 同步逻辑 / 手动实例 | 低 | `recurring_transaction_service.dart:221,233`；`local_transaction_repository.dart:674` | 生成器 `nextDate` 恒为 0 点，但用户手动"现在生成"的实例可能落在 14:30 等非 0 点；精确匹配 0 点会漏掉 → 重复。 | 同 REC-01，按日期维度去重。 |
| REC-03 | 同步健壮性 | 中 | `data_import_service.dart:977`(吞异常) + `:1353-1356` | 若某周期规则在 `importRecurrings` 被 try/catch 跳过，其实例 `resolvedRecurringId=null` → B 方案失效，且以 `recurringId=null` 落库 → A 方案也查不到 → 重复。 | 单条规则失败应使整批交易导入失败或显式告警，避免静默失防。 |
| REC-04 | 性能 | 低 | `data_import_service.dart:1366` | 每笔带 recurring 的交易在批量写库前同步查一次 `existsRecurringInstance`，大快照产生 N 次额外查询。 | 导入前先按 `(recurringId,happenedAt)` 预查去重集合，循环内 O(1) 查内存。 |
| REC-05 | 安全 / 防御纵深 | 中 | `devices_page.dart:91`；`cloud_service_page.dart:1565,1917,1951` | 开关仅在两个 Provider 拦截点生效，**未覆盖**页面内直连 `createCloudServices(config)` 的代码路径（深链/常驻页/既有配置仍可能触发登录与设备拉取）。 | 在 `createCloudServices` 调用点加 `if(!kPiggyCountCloudEnabled) return/throw;` 集中拦截。 |
| REC-06 | 健壮性 / 空守卫 | 低 | `cloud/sync/sync_providers.dart:25`；`shared_ledger_providers.dart:165`；`join_shared_ledger_page.dart:102` | `syncEngineProvider` 本身不查开关；其调用点在 `cloud==null`（开关关）时直接 `syncEngineProvider(cloud)` 传 null（参数非可空）→ 崩溃。当前这些页随开关不可达。 | 调用前加 `if (cloud == null) return;` 防崩溃。 |

---

## 第二部分：同步功能与同步加密（高危 / 中危 / 低危）

### 2.1 高危（含可致命项）

| # | 问题类别 | 严重等级 | 具体位置 | 问题描述 | 建议修复方案 |
|---|---|---|---|---|---|
| SYNC-01 | 数据完整性 / 同步逻辑 | **高（可升级致命）** | `sync_engine.dart:1271-1284`、`1380`；`sync_engine_apply.dart:19-23` | `_decryptPullResult` 对**任何解密失败**（密码错/盐错配/密文损坏）的变更将 `payload` 置 `null` 而非报错；`applyRemoteChange` 对 `payload==null` 且非 delete 直接 `return false`（静默跳过）；`_runPullLoop` 不区分是否全部应用成功，仍执行 `appCursor.commit(serverCursor)` **推进游标**。该失败**不进 `pullErrors`**（仅抛异常才记录），错误横幅完全无感知。结果：解密失败的变更被**永久静默丢弃且游标前进**，本地 DB 与服务端权威态永久分歧。 | 解密失败的 change 应视为"应用失败"：收集进 `pullErrors` 且**不推进该页 cursor**（与整页回滚一致），并提供可观测的错误态供 UI 提示。 |
| SYNC-02 | 加密一致性 / 密钥轮换 | **高** | `encryption_service_impl.dart:451`（`changePasswordWithCloudReEncryption`） | 改密仅重加密 `ledger_*.json` **快照文件**，但**从不重加密 PiggyCount Cloud 的 `sync_changes` 增量日志**（服务端权威、E2EE 下服务端无法重加密）。旧 change 仍用旧密钥，新设备/其他设备拉取这些旧 change 触发 SYNC-01 静默丢弃。**SYNC-01 + SYNC-02 在"改密后加入新设备"场景可导致真实数据丢失。** | 改密后广播 "rekey epoch"，令其他设备强制 fullPull 快照（已重加密）并**丢弃增量游标**；或客户端无法单点修复时，由服务端协同按 epoch 回放增量。 |
| SYNC-03 | 数据泄露 / 凭据存储 | **高** | `packages/flutter_cloud_sync/lib/src/providers/piggycount_cloud_provider.dart:1757` | 登录后会话（`accessToken`+`refreshToken`）经 `prefs.setString(_sessionStorageKey, jsonEncode(session.toJson()))` 写入默认 `SharedPreferences`（Android 明文 XML / iOS plist，**非加密**）。任何具备 root/ADB/备份权限的进程可窃取 bearer token 以用户身份访问云端账本。同工程 WebDAV/S3 凭据已用 `FlutterSecureStorage(encryptedSharedPreferences:true)`，后端不一致。 | 改用 `FlutterSecureStorage`（与 `CloudServiceStore` 同安全后端）持久化会话，或至少对 token 字段加密后再写入。 |
| SYNC-04 | 数据泄露 / 传输安全 | **高** | `packages/flutter_cloud_sync_s3/lib/src/s3_endpoint.dart:43`；`s3_client.dart:574` | S3 后端允许 `useSSL=false` 走明文 HTTP；`parseS3Endpoint` 遇 `http://` 前缀**强制覆盖** `useSSL=false`。WebDAV 后端硬性拒绝非 HTTPS，二者不一致。自建 S3（MinIO 等）用 `http://` 时账本明文与 SigV4 签名均裸链路传输，可被窃听/中间人篡改。 | 像 WebDAV 默认拒绝明文 HTTP，仅当用户显式勾选"仅受信任内网"时放行并二次确认告警；UI 检测到 `http://` endpoint 强制提示风险。 |
| SYNC-05 | 数据完整性 / 冲突解决 | **高（快照模型固有限制）** | `packages/flutter_cloud_sync/lib/src/cloud_sync_manager.dart:440-479`；`transactions_sync_manager.dart` 全账本 restore | 路径 A（WebDAV/S3/iCloud 自建存储）采用**整账本快照覆盖**模型，无逐实体（按 syncId）合并。两设备离线各编辑同一账本后方向判定 `different/unknown`，用户任一侧"选边"即**覆盖另一端独有交易**，无任何 merge。 | 多设备离线并发编辑时强制二次确认（保证所有触发 `SyncDiff.different` 的路径都弹确认）；中长期引入按 syncId 实体级合并或"双向保留为新账本"；文档披露此限制。 |

### 2.2 中危

| # | 问题类别 | 严重等级 | 具体位置 | 问题描述 | 建议修复方案 |
|---|---|---|---|---|---|
| SYNC-06 | 加密一致性（潜在） | **中（当前被开关缓解）** | `sync_engine_attachments.dart:119,196,265`；`piggycount_cloud_provider.dart:399,431` | 经核实：**路径 A 的收据附件已加密**（`uploadAttachmentObjects` 走 `provider.storage.upload`，经 `EncryptedCloudStorageService.encrypt` 加密，见 `encrypted_cloud_storage.dart:54`）。未加密的仅是 **PiggyCount Cloud（路径 B）** 的 `uploadAttachment/downloadAttachment`（分类图标/头像），而路径 B 当前已被 `kPiggyCountCloudEnabled=false` 停用。属**潜在**风险：路径 B 重新启用前必须补齐附件加密装饰。 | 在重新启用路径 B 前，于 `EncryptedCloudProvider`/PiggyCount Cloud 链路上覆盖 `uploadAttachment/downloadAttachment`，用 `AesGcmCipher` 加解密后再传；或在恢复路径 B 的 PR 中显式登记此 Todo。 |
| SYNC-07 | 加密安全模型 | 中 | `encryption_service_impl.dart:586-594`；`secure_key_storage.dart` | 主密码在 App 启动后**无需重新输入**：派生 AES 密钥持久化于 secure storage，`encrypt/decrypt` 在 `_activeKey==null` 时自动从 secure storage 加载进内存；此后只要设备已解锁即可读写云端密文，**无需主加密密码**。用户可能误以为"主密码"是数据访问闸门。 | 若需主密码门控，应在进后台/锁屏后 `_clearActiveKey`，下次加密操作前强制重输密码派生；或在隐私文档显式声明此设计取舍。 |
| SYNC-08 | 加密密钥存储 | 中 | `secure_key_storage.dart:45-47` | 直接存储**派生后的 32 字节 AES 密钥**（而非仅密码/盐）。设备被攻破（root/jailbreak 绕过 Keystore/Keychain）时该密钥可直接解密云端全部历史密文，无需主密码。 | 极高安全场景密钥不落盘、仅会话内由密码派生驻留内存（配合 SYNC-07）；否则在隐私文档声明风险边界。 |
| SYNC-09 | 上传原子性 / 数据丢失窗口 | 中 | `packages/flutter_cloud_sync_webdav/.../webdav_storage_service.dart:61-69` | WebDAV `uploadBinary` "先 `remove(fullPath)` 再 `rename(tempPath, fullPath)`"：若 `rename` 失败（网络中断），catch 清理临时文件，旧文件已删 → 云端该账本文件短暂/永久丢失直到下次上传。 | 改为先 `rename` 到临时目标名、成功后再 `remove` 旧文件，或优先 `put(overwrite:true)`，消除删除-重命名失效窗口。 |
| SYNC-10 | 错误处理 / 数据恢复 | 中（部分修复） | `transactions_sync_manager.dart:342-347`、`:797-804` | "本地未开启加密"现已抛 `CloudEncryptedLocallyDisabledException` 引导；但"密钥存在但密文损坏/错配"仍 `return null` → 静默 `return (inserted:0,...)`，用户看到"什么都没发生"且无错误提示。 | 损坏/错配场景也应抛明确异常或返回带错误标记的结果，UI 弹"密文损坏/密钥不匹配"提示。 |
| SYNC-11 | 同步状态准确性 | 中 | `sync_engine.dart:273-335` | `getStatus` 仅依"本地未推送数 + 远端文件是否存在"判定，**永远检测不到 remoteNewer**；UI 可能显示 `inSync` 而实际远端已有未拉取数据。 | 引入"远端未拉取 change 数"探测（或 appCursor 与 server latest cursor 对比），区分 `localNewer/remoteNewer/inSync`。 |
| SYNC-12 | 密码强度策略 | 中 | `encryption_service_impl.dart:757`（`_validatePassword`） | 仅校验非空与长度 ≥ 8，**无复杂度/弱密码/常见密码拦截**；`12345678` 之类弱密码 Argon2id 难以抵消离线爆破风险。 | 增加弱密码字典/复杂度提示（至少 UI 反馈强度），并接入设置页。 |
| SYNC-13 | 改密健壮性（新发现） | 中 | `encryption_service_impl.dart:395-421` | `_reEncryptCloudDataWithKeys` 单文件失败仅计入 `failed` 不中断，`changePasswordWithCloudReEncryption` 随后仍持久化新密钥并激活 → 云端出现"部分旧密钥/部分新密钥"混合快照，叠加 SYNC-01 造成选择性丢失。 | 出现任何 `failed` 时中止改密并回滚（恢复旧 key），或显式把 failed 列表回报 UI 让用户知悉哪些账本未重加密。 |

### 2.3 低危 / 可接受

| # | 问题类别 | 严重等级 | 具体位置 | 问题描述 | 建议修复方案 |
|---|---|---|---|---|---|
| SYNC-14 | 日志脱敏 | 低 | `s3_auth_service.dart:18` | `CloudUser.id='s3-${client.accessKey}'` 进入日志/realtime channel 扩散敏感标识。 | 日志中脱敏 accessKey（仅显示前/后 4 位）。 |
| SYNC-15 | 状态缓存 TTL | 低 | `cloud_sync_manager.dart:94` | 状态缓存 30s，另一设备在此期间上传后本地 `getStatus` 可能短暂误判 `synced`。性能/一致性权衡，知悉即可。 | 保留；或在关键操作后主动失效缓存。 |

### 2.4 设计局限（可接受）

- **元信息泄露（可接受）**：E2EE 下 `entity_type`/`ledger_id`/`action`/`updated_at` 以明文上行供服务端路由（LWW 服务端裁决所需），仅 payload 内容加密。属"服务端权威 LWW + 内容 E2EE"固有权衡。
- **明文云端（用户选择）**：E2EE 关闭时 `EncryptedCloudStorageService` 返回原文，账本 JSON 明文落云端，属用户主动选择，非缺陷。

---

## 第三部分：UI 层审查

### 3.1 中危

| # | 问题类别 | 严重等级 | 具体位置 | 问题描述 | 建议修复方案 |
|---|---|---|---|---|---|
| UI-01 | 国际化 (i18n) | 中 | `transaction_list_item.dart:420-421` | 侧滑删除确认框写死中文（`'确认删除'` / `'确定要删除这笔交易吗？此操作无法撤销。'`），未走 `AppLocalizations`；英文环境显示中文，同文件 `transaction_list.dart:631` 已正确使用 l10n，前后不一致。 | 改用 `l10n.commonDelete` + 新增 `deleteConfirmTitle/Message`。 |
| UI-02 | 暗色模式 / 视觉一致性 | 中 | `ledger_card.dart:304/311/318`；`transaction_list_item.dart:409/412`；`analytics_page.dart:259`；`message_popover_menu.dart:214/264`；`app.dart:1382/1400/1428`；`accounts_page.dart:1824/2273` | 多处组件硬编码 `Colors.green/red/grey/white/black`、`Color(0xFF…)`，不跟随 `PiggyTokens`，暗色下同步状态色/删除色/FAB 禁用态/弹层背景/图表边框对比度偏低或割裂。 | 统一替换为 `PiggyTokens.success/error/iconTertiary/surfaceElevated/overlay/border/warning(context)`。 |
| UI-03 | 可访问性 / 触摸热区 | 中 | `home_page.dart:813-877` | 头部多个 `IconButton` 设 `tapTargetSize:shrinkWrap` + `minimumSize:Size.zero`，命中区 ≈36px < 48×48，单手/无障碍操作困难。 | 保留视觉紧凑的同时至少维持默认 `minimumSize`（48×48）或加 `Padding` 扩大热区。 |
| UI-04 | 渲染 / 大字体裁切 | 中（已缓解→降级） | `main.dart:593-604` | 全局 `TextScaler` 已加 `clamp(max 1.15)`，文字溢出风险大降；但固定高度行（如 `home_month_summary_card` 固定高度）在极端缩放仍可能裁切。 | 复核固定高度控件，改 `min` 高度或对标题区用 `MediaQuery` 排除缩放。 |
| UI-10 | 暗色可见性 / 主题 | 中 | `analytics_page.dart:259` | `BorderSide(color: Color(0xFFCFD8DC))` 硬编码浅灰边框，暗色模式下图表轴/网格线几乎不可见且脱离主题。 | 改用 `PiggyTokens.border(context)` 或 `divider`。 |

### 3.2 低危 / 优化

| # | 问题类别 | 严重等级 | 具体位置 | 问题描述 | 建议修复方案 |
|---|---|---|---|---|---|
| UI-05 | 列表性能 | 低 | `category_selector.dart:192-194,400-402` | `GridView.builder(shrinkWrap:true,NeverScrollableScrollPhysics)` 嵌套 `ListView`，一次性构建全部网格项，弱化 builder 懒加载。 | 改用 `SliverGrid` 或合并为单一滚动容器 + 卡片内 `Wrap`。 |
| UI-06 | 布局溢出 | 低 | `transaction_list_item.dart:354-395` | 右侧金额 `Column` 未包 `Expanded/Flexible`，长金额（亿级）+「≈折算」第二行时可能触发 `RenderFlex overflow`。 | 给金额 `Column` 外包 `Expanded/Flexible`，`AmountText` 加 `maxLines/overflow`。 |
| UI-07 | 一致性 / 字号魔法值 | 低 | 多处（`ledger_card`、`transaction_list_item:286`、底部导航 `app.dart:1231`） | 字号散落硬编码（10/11/12/14/15/16/18），未收口 `PiggyTextTokens/PiggyDimens`。 | 收口到字号 token。 |
| UI-08 | 一致性 / 主题色 | 低 | `app.dart:1161`（底部导航未选中色 `isDark?white70:black54`）；`home_page.dart:711-773`（FAB 长按拖动无边界 clamp） | 未选中色绕过 token 体系；中心按钮拖出屏幕后子按钮可能飞出可视区。 | 复用 `PiggyTokens.iconSecondary(context)`；拖动加 `clamp` 边界限制。 |
| UI-09 | 一致性 / 遮罩 | 低 | `analytics_page.dart:550`；`product_promo_card:430` | loading 遮罩写死 `black*0.3`，token `overlay` 为亮 0.5 / 暗 0.7，暗色下偏淡且不统一。 | 统一走 `PiggyTokens.overlay(context)`。 |
| UI-11 | i18n | 低 | `subcategory_container.dart:67,76` | `label:'添加'/'编辑'` 硬编码，绕过 `AppLocalizations`。 | 改用 `commonAdd/commonEdit`。 |
| UI-12 | 主题一致性 | 低 | `message_popover_menu.dart:214,264` | 浮层背景 `isDark?0xFF2C2C2C:white` 与 `surfacePopoverCard` 不符；图标 `isDark?white:black87` 未用 `iconPrimary`。 | 替换为对应 Token。 |
| UI-13 | 主题 / 魔法值 | 低 | `accounts_page.dart:1824,2273-2274` | `mutedColor` 与选中背景 `white10/black06` 硬编码，未用 `textTertiary/surfaceSelected`。 | 替换为 Token。 |
| UI-14 | 渲染 / 可访问性 | 低 | `amount_editor_sheet.dart:1145/1151` | 按键图标 `isEnabled?Colors.white:textTertiary` 硬编码白，亮色白键背景上白色图标不可见；键盘背景未用 `surfaceKey`。 | 按键背景用 `PiggyTokens.surfaceKey`，图标用 `textOnPrimary/textDisabled`。 |
| UI-15 | 渲染一致性 | 低 | `transaction_list_item.dart:114-115` | 选中背景 `white10/black06` 硬编码，未用 `PiggyTokens.surfaceSelected`（暗色为 primary 15%，语义更清晰）。 | 替换为 `surfaceSelected`。 |

---

## 第四部分：结论与优先级

### 已确认的优点
- 加密核心架构专业：Argon2id（memory-hard）+ AES-256-GCM（AEAD）+ verifier 校验 + secure storage + single-flight 密钥加载，注释详尽。AES nonce 每次随机且嵌入密文格式（`ciphertext_format.dart`），无复用风险。
- 同步引擎工程扎实：in-flight 单飞锁、cursor 安全（appCursor 接管 + 整页失败回滚隔离）、LWW、N+1 消除（LookupCache/PushLookupCache）、附件内容寻址 + sha256 校验均到位。
- 路径 A 收据附件**已加密**（`EncryptedCloudStorageService`），近期 `3967883` 修复完整、`5215bdd` 同设备同环境下正确。
- UI tokens 体系完整，大字体裁切已通过 `clamp(1.15)` 缓解。

### 必须优先处理（按风险排序）
1. **SYNC-01 + SYNC-02（联动致命）**：增量拉取解密失败被静默丢弃且游标前进，叠加改密未重加密 `sync_changes` → 真实数据丢失。修复 SYNC-01（解密失败进 `pullErrors` 并阻塞游标），SYNC-02 改为 epoch 强制 fullPull。
2. **SYNC-03**：PiggyCount Cloud 会话令牌明文落盘 → 改 `FlutterSecureStorage`。
3. **SYNC-04**：S3 明文 HTTP → 强制 HTTPS 或显式风险确认。
4. **SYNC-05**：多设备离线并发编辑快照覆盖丢失 → UI 强制二次确认 + 文档披露。
5. **近期修改**：REC-01 跨时区去重键归一、REC-05 开关防御纵深补齐。
6. **UI**：UI-01（i18n）、UI-10（暗色图表边框）、UI-03（触摸热区）、UI-02（暗色一致性）。

### 需产品决策的设计取舍
- **SYNC-07/SYNC-08**：主加密密码是否在每次访问时强制重输 / 派生密钥是否落盘。当前为"可用性优先"，需明确安全边界并在隐私文档声明（当前路径 B 停用，风险面收窄）。

---

## 第五部分：源码复核修正与本轮修复记录（2026-08-22 追加）

> 对本文档全部 36 项结论逐条源码复核。26 项属实、8 项部分属实（描述有偏差）、2 项不成立/不存在。以下为修正与修复状态。

### 5.1 复核修正（原文档结论有误或不准确的项）

| # | 原结论 | 复核结果 |
|---|---|---|
| REC-06 | syncEngineProvider 空守卫缺失会崩溃 | **不成立，删除**。3 处调用方（`shared_ledger_providers.dart:155`、`join_shared_ledger_page.dart:101`、`sync_providers.dart:189`）全部先判空；且 family 参数非可空，传空无法通过编译 |
| SYNC-05 | 整账本覆盖、无合并、无确认 | **高估**。存在交易级 diff 合并（`sync_diff_service.dart:81-199` 按 syncId）与多重 UI 强制确认（`startup_sync_checker.dart:564` 等 4 处）。真实风险：冲突对话框仅"二选一整本覆盖"无合并选项；`_applyAll` 二次确认后默认全选含"删除本地独有交易"项。建议降级为"中"，改写为"覆盖型冲突模型 + applyAll 默认全选删除项" |
| REC-02 | 用户手动"现在生成"入口导致非 0 点实例 | 手动生成入口**不存在**。真实触发路径：新建 daily/weekly 规则默认 `startDate=DateTime.now()` 带时刻（`recurring_transaction_edit_page.dart:68`），首笔及后续实例落非 0 点 |
| SYNC-14 | accessKey 进入日志 | id 构造属实，但全库无打印该 id 的日志语句；实际是随快照对象元数据上云（`cloud_sync_manager.dart:162`） |
| UI-04 后半 | 月度卡片固定高度裁切 | 不存在。卡片为 `MainAxisSize.min` + `FittedBox(scaleDown)` 兜底 |
| UI-07 部分 | `transaction_list_item.dart:286` 字号魔法值 | 该处为图标尺寸非字号；文件正文样式已走 PiggyTextTokens |
| UI-08 后半 | FAB 长按拖动飞出屏幕 | 不存在。实为径向 speed-dial 悬停选择，按钮不移动，无需 clamp |
| UI-09 部分 | `product_promo_card.dart:430` loading 遮罩 black*0.3 | 实为 `black87` 且是截图画廊路由 barrier 非 loading 遮罩 |
| UI-14 部分 | 键盘背景未用 surfaceKey | 已用（`amount_editor_sheet.dart:707`）；仅白色图标硬编码属实 |
| UI-15 | 选中背景 white10/black06 | white10/black06 属实但位置是 flag pill 底色而非批量选中背景 |
| SYNC-06 引用 | 路径 B 附件走 provider.storage.upload 未加密装饰 | 行号引用有误：实际走专用明文 HTTP 端点（`piggycount_cloud_provider.dart:2368+` multipart），与经 `EncryptedCloudStorageService` 装饰的路径 A 是两套通道。核心结论不变 |

另：REC-03 实际**比原文更严重**——try 包住整个循环而非单条（原 `data_import_service.dart:849/977`），一条规则失败即中断其后所有规则导入。

### 5.2 本轮已修复（P0：路径 A 线上生效的数据完整性/安全）

| # | 修复内容 | 关键改动 |
|---|---|---|
| REC-03 | 周期规则导入单条隔离 | `data_import_service.dart` importRecurrings 循环体内 try/catch，单条失败跳过并记 error（含 syncId），不再中断其余规则；完成日志含失败数 |
| REC-01 + REC-04 | 去重键日期归一化 + 批量预加载 | 新增 `TransactionRepository.recurringInstanceKey`（本地日历日维度）与 `getRecurringInstanceKeys` 批量接口；导入前一次查库构建内存集合 O(1) 判重并支持批内去重；`existsRecurringInstance` 改按同日匹配（同时修复 REC-02 非 0 点漏判）。已知局限：两端时区差跨午夜仍可能漏判，根治需存储生成意图日 |
| SYNC-09 | WebDAV 上传原子性 | `webdav_storage_service.dart` 改为先 `rename(overwrite:true)`，失败（不支持覆盖的服务器）才降级先删后重试，消除常规路径的旧文件丢失窗口 |
| SYNC-13 | 改密部分失败中止并回滚 | `ReEncryptResult` 增加 successPaths；新增 `_rollbackReEncryptedFiles` 反向恢复旧密钥密文；`failed>0` 时回滚→zeroing 新密钥→抛 `ReEncryptPartialFailureException`（UI catch 弹窗呈现），不再激活新密钥 |
| SYNC-04 | S3 默认拒绝明文 HTTP | `s3_provider.dart` initialize 中 `useSSL=false` 时抛 `CloudConfigurationException`（对齐 WebDAV P2-7 策略）。后续优化：UI 的 useSSL 开关取消勾选将直接报错，可考虑隐藏开关 |

### 5.3 待处理优先级更新

1. **P1（安全加固）**：SYNC-03 会话令牌迁移 FlutterSecureStorage；REC-05 在 createCloudServices 内部集中拦截开关（残留激活配置场景 `cloud_service_page.dart:1917` 与 `sync_providers.dart:158` 可绕过）
2. **P2（UI 中危）**：UI-01 / UI-10 / UI-03 / UI-02
3. **P3（重新启用路径 B 前必须）**：SYNC-01 / SYNC-02 / SYNC-06 附件加密 / SYNC-11 remoteNewer
4. **P4**：其余 UI 低危、SYNC-12 弱密码提示、SYNC-14 元数据脱敏、SYNC-05 applyAll 默认全选项调整
