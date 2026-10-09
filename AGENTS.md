# AGENTS.md

> 本文件是本项目 AI 编码工具的**单一真相源**。其它工具入口若存在，只应引用本文件，不要重复维护规则。

PiggyCount（小猪记账）是开源、隐私可控、**离线优先**的个人记账 / 支出追踪 App。业务数据全部落在本地 SQLite（Drift），云端同步由用户自备（Supabase / WebDAV / S3 / iCloud），开发者不接触用户数据；无广告、无追踪、无埋点。目标平台 Android 7.0+（minSdk 24，取 Flutter 默认 `flutter.minSdkVersion`）与 iOS 15.5+，另含 Android / iOS 桌面小组件。许可证为 BSL 商业源代码许可证（个人 / 学习 / 开源贡献免费，商用需授权）。

## 快速原则

- **中文工作**：对话、commit message、文档、代码注释全部中文。commit 格式 `type(scope): 中文描述`，多批工作常在末尾附日期，如 `fix(sync): 同步一致性 D-1~D-4 修复 + 契约穷举守门测试（2026-09-27）`。
- **文件引用只写仓库内相对路径（2026-10-08）**：文档 / PRD / 注释 / PR 正文里引用文件，Markdown 链接写 `[db.dart](../lib/data/db.dart#L120)`（相对当前文件所在目录，可带 `#Lxx-Lyy` 片段），正文提及写 `lib/data/db.dart`。**三类路径一律禁止**：① `file:///` 绝对路径（含 `d:\Develop\...`、`C:/Develop/...` 这类盘符 + 机器目录，换机必失效）；② 任何本机绝对路径；③ 指向**外部兄弟项目**的路径（如 `C:\Develop\project\orbit`、`...\wait-home\mobile\...`，以及指向仓库外的相对链接 `../../../../wait-home/...`）—— 外部项目只能写成「外部项目 `orbit` / `wait-home` 的 `<该仓库内相对路径>`」。引用**已删除**的文件时不要留链接（点击落空），改写成代码文本 `` `sync_engine.dart:1122` ``。历史遗留：`docoments/`、`prd/` 里曾有 424 个 `file:///` 链接 + 143 处裸机器路径，2026-10-08 已全量改为相对引用，新增文档照此办理。`docoments/INDEX.md` 的「代码引用规范」是本条的细则来源。
- **Flutter 版本单一来源**：只改 `pubspec.yaml` 的 `environment.flutter`（当前 `3.47.6`），CI 用 `flutter-version-file: pubspec.yaml` 读取。**禁止**在 `.github/workflows/*.yml` 里另写版本号——历史上 `release.yml` 停留 3.27.3 而 `pubspec.lock` 已要求 >=3.44.0，漂移会让下一次打 tag 发版直接失败。
- **应用版本单一来源（2026-10-08 修订发版口径）**：真值在 `pubspec.yaml#version`（当前 `0.1.0`）。**发版前必须先把它改成本次要发布的版本（= 即将打的 tag 去掉 `v` 前缀），并与更新日志一起提交推送**，让 `pubspec` 与已发布版本对齐（发版人的手工步骤，见「发版流程」）。`release.yml` 自身**不修改** `pubspec.yaml`，而是把 tag 名经 `--build-name` / `--build-number` 注入构建（`--build-number` 取 `github.run_number`）；**产物名仍只跟 tag 走**。**禁止**在 CI 里用 `sed` 改 `pubspec.yaml`。
- **分层不可破**：UI 只碰 Provider；Provider 注入 Service / Repository；Service 只调 Repository；Repository 是数据库唯一入口。跨层调用一律 review 拒绝。
- **写操作必须经 Repository**：任何改库操作都要走 Repository，由其内部经 `ChangeTracker`（`lib/cloud/sync/change_tracker.dart`）写入 `local_changes`。**绕过 Repository 直接写 DB 是严重 bug**——本地变更不会进 `local_changes`，云端同步静默丢数据。
- **`ChangeTracker` 作用域契约**：调用方只用两个强类型入口——user-global 实体（account / category / tag / exchange_rate_override）走 `recordUserGlobalChange`（自动挂 `ledgerId = 0`），ledger-scoped 实体（transaction / budget / ledger / ledger_snapshot）走 `recordLedgerChange`（必须传 `> 0` 的具体账本 id）。**不要调私有的 `recordChange`**。作用域记错会让变更卡在本地永不推送。云→本地合并路径（apply / restore）必须用 `withRecordingSuppressed` 包裹，否则云端数据会回流成幻影变更。
- **同步是整账本快照（Path A）**：`lib/cloud/sync_service.dart` 定义 `SyncService` 抽象接口，`TransactionsSyncManager`（`lib/cloud/transactions_sync_manager.dart`）是主实现——导出整本账本 JSON 快照上传，拉取走下载 + 恢复 / 合并（`SyncDiffService` 出 diff 预览，`sync_fingerprint.dart` 出内容指纹）。本地内容变化用 `SyncService.markLocalChanged(ledgerId)` 失效缓存；后台自动上传用 `uploadCurrentLedgerDebounced`（2s 窗口收敛，手动 / 合并回传用立即语义的 `uploadCurrentLedger`）。**旧的增量引擎（Path B / `SyncEngine`）已整体下线**——代码里 `sync_engine.*` 之类的注释属历史残留，别按它找文件。Repository 不调用 SyncService，由 UI / Provider 经接口触发。
- **共享账本已彻底移除（2026-10-08，勿再新增引用）**：PiggyCount Cloud 多人协作账本已随云端协同整体下线，项目尚无老用户，**不存在需要兼容的存量数据**。残留已分两步清空：`ledger_members` 死表在 **v50** 迁移 DROP；其余（`ledgers` 的 `isShared / myRole / memberCount / ownerUserId`、`transactions` 的 `category/account/to_account_sync_id_override` 与死列 `tag_sync_ids_override`、`shared_ledger_{categories,accounts,tags}` 三张镜像表、`transaction_tag_overrides` 表）在 **v51** 迁移 DROP。同步契约三件套（`sync_fingerprint.dart` / `transactions_json.dart` / `sync_diff_service.dart`）与 `transactions_sync_manager.dart` 的 `ov` 信号键、契约守门测试 `sync_contract_coverage_test.dart` 已同批收窄，picker 的 synthetic 替换机制（原 `lib/utils/shared_ledger_picker_filter.dart`）整文件删除。**注意保留项**：`transactions.created_by_user_id / last_edited_by_user_id`（本地专有列，不进快照；共享账本下线后已无 UI 写入方，`markTxAuthor` 保留但暂无调用方）、快照契约键 `tagSyncIds`（来自主表 `transaction_tags ⨝ tags`，与已删的 override 表无关）——它们与共享账本无关，不得顺手删除。
- **快照格式版本 v12 + 升级一次性重传（2026-10-09）**：`transactions_json.dart` 的 `kSnapshotFormatVersion` 每逢新增实体段都要抬一版，且**每一版都改变了内容指纹的算法值**——v10 删掉共享账本四个 override 键；v11 新增 `holdings` 段 + `holdingCanon`；**v12 新增 `savingsGoals` 段 + `savingsGoalCanon`**（储蓄目标，ledger-scoped；段门控必须传引入版本 12，否则旧快照整段缺失会被判成「本地目标全删」）。云端若仍是旧版本 App 写入的 v9 快照，两端指纹**永远不相等**：状态卡永久「有差异」、启动检查每轮把账本判为方向未知而不处理（反复提示但永不收敛）。处理链：`TransactionsSyncManager.shouldRepublishSnapshotForFormatUpgrade` 判定「云端 `version` < 当前格式 **且** 按当前算法重算云端内容指纹 == 本地指纹」（白名单式指纹函数天然忽略旧快照残留键，故跨版本可比、只读不写）→ `StartupSyncChecker` 对判定为真的账本做一次性 `force` 全量重传，把云端改写为当前格式后即永久收敛；`_detectUploadConflict` 对「旧格式 + 内容一致」同样放行上传，避免手动上传路径逼用户二选一。**内容确实不同时一律不自动覆盖**，保持既有冲突/合并流程。上传 metadata 新增 `snapshotVersion` 键：已收敛账本的判定只花一次 HEAD（零下载）。**后续再动指纹白名单 / 字段集时，必须同步审阅本门控语义**（再升一版格式版本，否则老云端快照永远不收敛）。
- **上传禁止盲覆盖**：上传前用 `UploadProbe` 探测方向，冲突抛 `CloudConflictException`（`cloudNewer` / `unknown`），交 UI 让用户确认后再以 `force: true` 重试。恢复临界区由 `SyncRestoreGuard` 把守，`bypassRestoreGuard: true` **只允许恢复/合并已提交后的收尾回传**，用户主动上传入口绝不可传。
- **同步契约有穷举守门测试**：`test/cloud/sync_contract_coverage_test.dart` 校验「指纹白名单 ↔ diff 覆盖字段」逐一对应。相关测试变红通常意味着「某字段进了指纹却没进 diff」或「检测到了却应用不下去」——**不要直接改测试来通过**，先定位真实缺口。**实体段**（account / holding / savingsGoal / budget / recurring / rateOverride）另由各自的 `test/cloud/sync_contract_<entity>_test.dart` 守门（键集合从**两份源码派生**、本地专有列不得进快照、逐字段影响指纹、旧格式段缺失不判全删）——新增实体照抄一份，别只加段不守门。
- **合并路径有实体删除语义（2026-10-03）**：`computeDiff(cloudMeta:)` 会为「对端已删、本地还在」的账户 / 分类 / 标签 / 预算 / 周期规则 / 手动汇率覆盖产出 `SyncChange(type: deleted, entityDelete: …)`，**默认不勾选**（SYNC-05 口径），用户勾选后由 `applySyncChanges` 经 Repository 删除。没有它，这些实体只 upsert：删除永不传播、merge-then-publish 把残留推回云端、指纹永久不一致。四道闸门缺一不可：**version ≥ 8**（旧快照无删除语义）／**该段 `skippedItems` 无解析损坏**／**本地有 syncId**／**本地无未推送 local_changes**（`createAccount`/`createCategory`/`setOverride` 建行即自动生成 UUID syncId，光看 syncId 挡不住"本机刚建未上传"）。另有引用守卫 `BaseRepository.getSyncEntityReferences()`，**刻意放在 apply 侧**（`_applyEntityDeletes`）而不是预览侧：预览那一刻本地交易还在，「删账户 + 删它的交易」这种最常见的组合会因为账户仍被引用而不进候选 → 用户删完交易后本地已与云端一致 → 没有未勾选的删除 → S1 守卫放行 → force 回传把账户又写回云端 → **对端刚删的账户复活**。放 apply 侧按"交易落库后"的引用判定可单轮收敛；用户没勾引用交易时则拦下实体删除、不留悬空外键（那种场景交易变更必然未勾选，S1 守卫本就拦回传）。未勾选时靠 `shouldSkipMergePublish` 的 S1 守卫跳过回传防复活，**三个合并入口（启动检查一键应用/逐个确认 + 云同步页下载同步 + 账本页对比合并）必须共用这一个判据**，手动入口绕过它就等于给了"在启动检查拒绝删除、在手动入口把删除复活回去"的路径；且三个入口**都必须把跳过回传这件事告知用户**（`syncSkippedPublishUnselectedDelete`），静默跳过会让用户以为同步完了。服务层不得塞面向用户的文案（实体无专属名字时留空串，由 UI 的种类标签兜底），也不得把 `type` 之类原始枚举漏给 UI。自定义字段定义走的是 D-4 的**静默**镜像删除（`mirrorDeleteAbsentCustomFields`），语义与本条**故意不同**，改任一侧都要想清楚另一侧。守门测试：`test/cloud/sync_diff_entity_delete_test.dart`。
- **改 schema 必须升版本 + 幂等迁移**：`lib/data/db.dart` 的 `schemaVersion`（当前 **53**：v52 投资持仓、v53 储蓄目标）递增，`MigrationStrategy` 追加迁移块；迁移必须幂等、可重入。**禁止删除字段**（老用户数据会丢），必须废弃时加 `_deprecated_` 前缀保留 —— 唯一例外是「零读写死结构 + 项目无老用户」的共享账本残留（v50 DROP `ledger_members`、v51 清理其余，见上条），这类删除需在 PR 里显式说明豁免理由。
- **改 Drift 表 / `@JsonSerializable` / `@freezed` 后必跑 build_runner**：`dart run build_runner build`（build_runner 2.15 起 `--delete-conflicting-outputs` 已被移除，带上也只会被忽略）；`*.g.dart` / `*.freezed.dart` **必须提交**，不要加 `.gitignore`。
- **UI 强制走 Design Token**：颜色 / 间距 / 圆角 / 字体全部取 `lib/styles/tokens.dart` 的 `PiggyTokens` / `PiggyDimens` / `PiggyTextTokens` / `PiggyChartTokens` / `PiggyPosterTokens`。直接用 `Colors.white` / `Colors.black` / `Colors.grey.shadeXXX` 在暗黑模式下会出错。
- **Material 组件的圆角禁止吃框架默认值（2026-10-09）**：`FloatingActionButton` / `Card` / 各按钮这类**有主题入口**的组件，圆角一律在主题层用 `PiggyDimens` 显式声明（`lib/theme.dart` 的 `floatingActionButtonTheme.shape` = `radiusXl`、暗色 `cardTheme.shape` = `radiusXl`、`filledButtonTheme` / `outlinedButtonTheme` / `elevatedButtonTheme` = `radiusLg`；亮色的 `cardTheme` / 按钮落在 `lib/main.dart` 的 `_buildLightTheme`），**页面里不要再逐处写 `shape:`**；自绘容器继续取 `PiggyDimens.radius*`。理由：FAB 的 16 是 Flutter SDK 硬编码默认值（`_FloatingActionButtonDefaultsM3`），既没走 token，改 token 或升 Flutter 都会静默漂移，且亮 / 暗两套主题必须同值。**唯一注意点**：主题级 `shape` 会一并覆盖 `FloatingActionButton.small`（M3 默认 12）/ `.large`（28），要用这两个变体必须自行传 `shape` 并在 PR 里说明。守门测试 `test/styles/theme_component_shape_test.dart`。
- **文案禁硬编码**：所有面向用户的文案进 `lib/l10n/app_*.arb`，UI 用 `AppLocalizations.of(context)!.key` 引用。缺英文（`app_en.arb`，模板文件）会直接显示 key。
- **破坏性操作必须走危险确认分档（2026-10-09）**：删除 / 清空 / 覆盖 / 重置这类**不可逆**操作**禁止**用普通双按钮确认（`AppDialog.confirm(destructive: true)`、自绘 `showDialog` + `AppDialogShell`）。三个档位都在 `lib/widgets/ui/dialog.dart`，均为 `barrierDismissible=false` + `PopScope(canPop:false)`，且**确认键在倒计时归零前禁用并显示「确认（N秒）」**（即时停）：
  - **双重危险确认** `showDoubleDangerConfirmDialog`（连弹两次、各 3~5 秒）—— 不可恢复 **且影响面超过单行**：级联删除（删账户、删分类含子分类）、批量（批量删交易、清理未使用标签 / 分类、批量恢复 / 上传）、覆盖（覆盖式导入、从备份恢复、全量上传下载）、整库（清空账单、删账本 / 删云端账本、重置云端加密）、删自定义字段定义、回收站彻底删除、孤儿清理。
  - **单次危险确认** `showDangerConfirmDialog`（一次、3 秒）—— 不可恢复但**仅单行实体**：单条删标签 / 分类 / 预算 / 周期账单模板 / 投资持仓 / 储蓄目标、清空 AI 对话历史；危险开关（整库加密开关）与全量同步方向确认也归这一档。
  - **普通确认**（`AppDialog.confirm(destructive: true)` 或自绘）—— **只允许**两种情形：① 走软删除、可恢复（单条交易侧滑删除 → 回收站）；② 不删数据（退出登录 / 切换云服务）或纯编辑语义（清空输入框 = 更新字段）。
  - 要降档必须在 PR 或代码注释里写明理由。**已知待决项**：`lib/pages/auth/app_lock_screen.dart` 的「连续输错 → `wipeAllData`」目前仍是普通确认（安全路径，升级需产品确认，别顺手改）。
- **编辑抽屉的删除入口走 `PiggyFormSheet.deleteLabel`，不要塞进字段区（2026-10-09）**：表单抽屉中间的内容区是**滚动区**，把删除入口写在 `child` 末尾时，长表单（周期账单有十几个字段）会把入口推到屏幕外 —— 用户以为「这个实体没有删除」。正确写法：

  ```dart
  PiggyFormSheet(
    // ...title / cancelLabel / confirmLabel / onCancel / onConfirm
    deleteLabel: _isEdit ? l10n.commonDelete : null, // 新建态传 null = 不渲染
    onDelete: _confirmDelete,
    deleteBusy: _saving,
    child: ..., // 字段区里不要再出现删除按钮
  )
  ```

  组件会把它渲染成**标题栏左上角的垃圾桶图标**（**只要图标**，`deleteLabel` 只作 tooltip / 无障碍朗读）：既不占底部动作行的空间，也不随字段区滚动。此前五处各写一种变体（底部全宽描边按钮 / 底部带图标按钮 / 居中文字按钮 / 字段区末尾的「危险操作」区）且都在滚动区末尾，统一后只有标题栏一种外观。改完**实测一遍长表单抽屉**（打开即应看到左上角图标），别只看截图里的短表单。
  **位置与右上角槽（2026-10-09 修订）**：删除**统一在左上角** —— 不可逆动作远离右拇指常停留的位置，与右下角的主动作（保存）成对角；**不要**再把删除挪回右上角。标题栏右上角另有**一个**固定 48 宽的自定义图标槽 `trailingAction`（值为自绘 `IconButton`，只放图标、文案走 `tooltip`，塞文字按钮会把居中标题挤偏）。当前唯一在用者：账户抽屉（`lib/pages/account/account_edit_page.dart`）在右上角放**可逆**的「隐藏 / 恢复」（`Icons.visibility_off_outlined` / `Icons.visibility_outlined`，主色），删除仍走 `deleteLabel` 落在左上角。
- **筛选 / 字段行的尾部图标：「有值」换成清除键，绝不与箭头并排（2026-10-09）**：`PiggyValueRow`（`lib/widgets/ui/value_row.dart`，搜索筛选抽屉 `lib/widgets/biz/search_filter_sheet.dart` 等在用）的尾部只有**一个固定 32×32 槽位**，三态**互斥**、按优先级取一：① `value` / `valueWidget` 有值 **且** `onClear` 非空 → **清除键**（`Icons.close`，size 20，`PiggyTokens.error`，语义是「移除本行值」）；② `trailingCaption` 非空 → 只读小字；③ `onTap` 非空 → **箭头** `Icons.chevron_right`（size 20，`PiggyTokens.iconTertiary`）；纯展示行也留同样的空槽，值右缘才与其它行对齐成一条竖线。**清除键是「取代」箭头而不是与它并排** —— 并排会白吃一段宽度，把长值挤到贴着行首图标（原实现踩过）；清除只清本行值，整行 `onTap` 仍可继续改选。配套的值区样式两条态：**已设置** → `PiggyTokens.primary` + `FontWeight.w600`；**未设置** → `PiggyTokens.textTertiary` + `w400`（显示 `placeholder`，如「未设置」）。因此「已设置 = 主色粗体值 + 红色 X，未设置 = 灰字 + 右箭头」这种行一律走这个组件，**不要在页面里自绘一套**。守门测试 `test/widgets/search_filter_sheet_test.dart`（断言无值时是 chevron、有值时换成 `Icons.close` 且颜色 == `PiggyTokens.error`）。改图标 / 颜色 / 槽位宽度都要同步这两个态与测试。
- **零告警门禁**：CI 用 `flutter analyze --fatal-infos`（基线 0 error / 0 warning / 0 info，2026-09-18 起）。本地提交前必须 `flutter analyze` 干净。
- **`packages/` 子包不得反向引用 `lib/`**：子包要能独立复用；`lib/` 可引用子包。
- **尊重并发会话**：同一仓库常有并行会话 WIP；收尾核对改动的归属，不回滚非本批改动。

## 技术栈

| 维度 | 选型 |
| --- | --- |
| 框架 | Flutter 3.47.6（stable，Dart 3.13.5）+ Dart SDK `^3.6.0`，`flutter_lints ^6.0.0` |
| Android 构建 | compileSdk **37**（Android 17，`permission_handler_android 14.x` 硬要求）+ AGP **9.1.0** + Gradle **9.3.1** + NDK **28.2.13676358** + Java 17 / Kotlin **2.4.0**（见 `android/app/build.gradle`、`android/settings.gradle`；compileSdk 37 的平台包在 SDK 仓库里只有 `platforms;android-37.0`（**没有** `platforms;android-37`），故 `android/app/build.gradle` 的 `compileSdk = 37` 必须配 `compileSdkMinor = 0`，否则 AGP（含 9.1.0）会把目标 hash 拼成 `android-37`，报 Failed to find target with hash string。Flutter 3.47.6 的兼容矩阵已不含 AGP 8.x，故 AGP 9 / Gradle 9 / Kotlin 2.4 三者必须同批升；AGP 9 起 `resValues` build feature 默认关闭，靠 `android/gradle.properties` 的 `android.defaults.buildfeatures.resvalues=true` 显式打开，否则报 “Build Type debug contains custom resource values, but the feature is disabled”；`android/build.gradle` 已改用 `layout.buildDirectory` —— Gradle 9 移除了 `Project.buildDir`） |
| 状态与 DI | Riverpod **3.4.3**（`flutter_riverpod`）——唯一状态管理方案，同时承担 DI（3.x 迁移要点见下方「Riverpod 3 迁移注意」） |
| 本地数据库 | Drift 2.35 ORM + `sqlite3_flutter_libs` / `sqlite3`（`PiggyDatabase`，schemaVersion 53）；Android 侧整库加密走自带的 `libsqlcipher.so`（见「版本约束注意」） |
| 路由 | Navigator 1.0（`MaterialPageRoute` + `Navigator.push`），**不用** go_router / auto_route |
| 云同步（自研） | `packages/flutter_cloud_sync`（核心）+ 各 provider 子包：`_supabase` / `_webdav` / `_s3` / `_icloud` |
| AI（自研） | `packages/flutter_ai_kit`（6 种执行策略）+ `_zhipu`（GLM-4 / glm-4v-flash）+ `_openai` |
| 加密 | E2EE = AES-256-GCM + Argon2id（`cryptography`，纯 Dart）；密钥存 `flutter_secure_storage`（iOS Keychain / Android Keystore）。**整库加密（SQLCipher）已于 2026-10-06 在 Android 启用** —— 详见下方「版本约束注意」 |
| 网络 | `dio`（OTA 更新 / 汇率 / AI 调用等复杂 HTTP）+ `http`（轻量场景），自建云后端各用其 provider 子包的客户端 |
| UI / 媒体 | Material 3、`fl_chart` 图表、`table_calendar`、`reorderable_grid_view`、`webview_flutter`、`flutter_svg` / `jovial_svg`、`image_picker` + `flutter_image_compress` + `image_cropper` |
| 平台集成 | `home_widget`（桌面小组件）、`flutter_local_notifications` + `timezone`、`quick_actions`、`local_auth`（应用锁）、`app_links`（`piggycount://`）、`permission_handler` |
| 导入导出 | `csv`、`excel`、`yaml`、`file_picker`、`archive`、`gbk_codec`（支付宝 / 微信账单） |
| 测试 | `flutter_test` + `mocktail`（不用 mockito，避免 codegen）+ Drift `NativeDatabase.memory()` |
| CI | GitHub Actions：`analyze.yml`（analyze 0-issue 门 + test 同步契约门）、`release.yml`（tag 触发多平台构建发布） |

**版本约束注意**：`dependency_overrides` 只钉 `jni_flutter: 1.0.3`（1.0.4 已被 pub 撤回，而 `path_provider_android 2.3.1` 的 `^1.0.1` 仍会把 1.0.4 选为最高版——镜像源版本列表不带 retracted 标记，pub 不会自动避开；等上游换掉该依赖后可移除）；两条历史 pin 分别随 `record 7.1.1`（`record_platform_interface: 1.2.0`，record 7 的平台实现统一要求 `^2.1.0`）与 `image_cropper 12.2.1`（`image_cropper_platform_interface: 7.1.0`，12.x 与 8.x 配套）移除；`hooks.user_defines.sqlite3` 用 `source: system` + `name_android: sqlcipher`，让 Android 运行时 `dlopen('libsqlcipher.so')` —— **整库加密已于 2026-10-06 启用**：三个 ABI 的库已入库到 `android/app/src/main/jniLibs/<abi>/libsqlcipher.so`（~16.45MB，即 `prd/sqlcipher_db_encryption/design.md` §7 的「入库」分支 —— 实测 GitHub release 会 302 到 `objects.githubusercontent.com`、国内直连超时 WinError 10060，构建期拉取会失败）。取库命令：`python scripts/fetch_sqlcipher_android_libs.py --mirror https://ghfast.top/`（按 sqlite3 包内 sha256 强校验）。**`name_android` 与 `jniLibs` 必须同在**：缺任一 ABI 的库，应用连 SQLite 都加载不了、起不来（护栏：`test/data/sqlcipher_android_packaging_contract_test.dart`）。`flutter_launcher_icons.ios: false`，iOS 图标手工维护（0.14.x 会重写 `Contents.json`）。

**Riverpod 3 迁移注意**（2026-10-06 由 2.5 升到 3.4.3；`analyze --fatal-infos` 0 issue + 1842 测试全绿后落地）：

1. **`StateProvider` / `StateNotifierProvider` 已移出主入口**，改从 `package:flutter_riverpod/legacy.dart` 导入（本项目 37 个文件在用，含 `StateNotifier` / `StateController`）。只用到 legacy API 的文件要**删掉** `flutter_riverpod.dart` 主 import，否则报 `unused_import` 破 0-issue 门。
2. **`AsyncValue.valueOrNull` 被移除**，一律改用 `.value`（3.x 的 `value` 在 error 时返回 `null`，即旧 `valueOrNull` 语义）。本批改了 38 个文件。
3. **`StreamProvider` 在没有「主动监听者」时会暂停其 `StreamSubscription`** —— 此时 `read(provider.future)` **永不完成**（测试里表现为挂到 10 分钟超时）。测试若要 `await xxx.future`，需先 `container.listen(provider, (_, __) {})` 保活。
4. **provider 失败会自动重试**（指数退避 Timer，默认开启）。测试中对故意失败的用例会残留 pending timer，用 `ProviderContainer(retry: (_, __) => null)` 或 `ProviderScope(retry: ...)` 关掉。
5. **`ProviderObserver.didUpdateProvider` 由 4 参改 3 参**：`(ProviderObserverContext context, Object? previousValue, Object? newValue)`，`provider` / `container` 从 `context` 取；`ProviderObserver` 是 `base class`，子类必须显式声明 `base` / `final` / `sealed`。`ProviderBase` 不再公开导出。
6. **`ProviderListenable` 改从 `package:flutter_riverpod/misc.dart` 导出**（主入口不再导出）。
7. **`Ref` 是 `sealed class`**，测试里不能 `implements Ref` 伪造；改为「在真实 provider 内调用」拿真实 `Ref`：`container.read(FutureProvider<bool>((ref) => fn(ref)).future)`。
8. **drift 的 `QueryStream` 在 dispose 时用 `Timer(Duration.zero)` 异步关闭**：widget 测试卸载 `ProviderScope` 后必须 `pump()` 再 `pump(Duration(milliseconds: 1))` 推进时间，否则 pending-timer 断言失败（该断言在测试体结束、`tearDown` 之前跑，`addTearDown` 兜不住）。

## 架构边界

**五层架构 + 同步旁路**（分层见下；`docoments/04-system-architecture.md` 的同步部分为历史文档，以代码为准）

```text
UI (pages / widgets)
  └─> Provider (Riverpod)
        ├─> Service (业务编排)
        │     └─> Repository (数据访问唯一入口)
        └─> Repository
              └─> Data (Drift / SQLite)
```

| 层 | 位置 | 允许 | 禁止 |
| --- | --- | --- | --- |
| UI | `lib/pages/`、`lib/widgets/` | Provider | 直接访问 Repository / DB / CloudProvider |
| Provider | `lib/providers/`（`all_providers.dart` barrel 导出） | Service、Repository、其他 Provider | 直接访问 DB |
| Service | `lib/services/<module>/` | Repository、其他 Service | 直接访问 DB、Provider |
| Repository | `lib/data/repositories/` | Drift、其他 Repository | Provider、UI、SyncService |
| Data | `lib/data/db.dart` | SQLite | 任何上层 |

- **Repository 三层结构**：抽象接口（`lib/data/repositories/<name>_repository.dart`，无 `I` 前缀）→ 本地实现（`lib/data/repositories/local/local_<name>_repository.dart`）→ 聚合委托（`local_repository.dart` 继承 `BaseRepository`，持 12 个子 Repository：account / ai / attachment / budget / category / custom_field / exchange_rate / ledger / recurring_transaction / statistics / tag / transaction，注入 `ChangeTracker` 与多币种折算等横切逻辑）。
- **多后端抽象**：`CloudProvider` 接口在 `packages/flutter_cloud_sync/lib/src/core/cloud_provider.dart`；`createCloudServices`（`lib/cloud/provider_factory.dart`）按 `CloudServiceConfig` 装配 Supabase / WebDAV / iCloud / S3 四种后端。**PiggyCount Cloud 协议已随云端协同整体下线**（`docoments/` 中相关章节为历史文档）。所有后端统一走快照语义，`lib/cloud/transactions_sync_manager.dart` 是唯一编排入口。
- **写路径**：`Repository → Drift 写入 → ChangeTracker 记 local_changes →（内容代际回调失效指纹缓存）→ 用户 / 后台触发 `SyncService.uploadCurrentLedger(Debounced)` → CloudProvider`。ID 用本地 `id`（int 自增）+ 跨设备 `syncId`（UUID 字符串，各表唯一索引）。
- **同步编排与守卫**：`lib/cloud/` 下 `sync_service.dart`（接口 + `SyncStatus` + 冲突模型）、`transactions_sync_manager.dart`（主实现）、`sync_diff_service.dart`（对比 / 预览 / 应用）、`sync_fingerprint.dart`（指纹，与 diff 字段一一对应）、`transactions_json.dart`（快照序列化）、`sync_restore_guard.dart`（恢复临界区）、`sync_metrics_service.dart`（本地成功率指标）、`startup_sync_checker.dart` + `startup_sync_overlay.dart`（启动检查状态机）、`backend_identity.dart`（后端标识文案）、`gzip_cloud_storage.dart`（传输压缩）；`sync/change_tracker.dart` 记变更；`backup/` 是全量备份（`cloud_backup_service.dart` / `backup_scheduler.dart`）。**修改 push / pull / diff / 指纹逻辑必须补对应单测**，不得移除 `SyncRestoreGuard`、ETag 条件写、去重缓存等既有防线。

## 目录约定

```text
lib/
  ai/                    # AI 集成层（providers / core / privacy）
  cloud/
    sync_service.dart    # SyncService 接口 + SyncStatus + CloudConflictException / UploadProbe
    transactions_sync_manager.dart  # 快照同步主实现（导出/上传/下载/恢复/合并）
    sync_diff_service.dart          # 对比预览与应用（SyncChange / SyncPreview）
    sync_fingerprint.dart           # 内容指纹（与 diff 字段一一对应，契约守门）
    transactions_json.dart          # 账本快照序列化
    sync_restore_guard.dart / sync_metrics_service.dart / backend_identity.dart / gzip_cloud_storage.dart
    startup_sync_checker.dart / startup_sync_overlay.dart / provider_factory.dart
    sync/change_tracker.dart        # 变更登记（user-global ledgerId=0 / ledger-scoped）
    backup/                        # 云端全量备份与恢复、备份调度
  data/
    db.dart              # PiggyDatabase（Drift 表定义 + MigrationStrategy，schemaVersion=53）
    db.g.dart            # codegen 产物（提交）
    repositories/        # 抽象接口 + local/ 本地实现 + local_repository.dart 聚合
    encryption/          # AES-GCM / Argon2 / 密文格式 / 加密云 provider 与存储 / 安全密钥存储
    models/              # 数据模型
    database_health_service.dart   # 只读连接 PRAGMA quick_check 探测损坏
  domain/encryption/     # E2EE 领域服务与设置（encryption_service.dart / encryption_settings.dart）
  l10n/                  # app_zh.arb（官方）+ app_zh_TW.arb + app_en.arb（模板）+ app_ko.arb（社区）
  models/                # 业务模型
  pages/<module>/        # 业务页面（account/ai/attachment/auth/automation/budget/calendar/category/
                         #   cloud/currency/data/main/maintenance/report/settings/tag/transaction）
                         #   页面专用子组件放 pages/<module>/widgets/<page>_<purpose>.dart
  providers/             # Riverpod provider，all_providers.dart 汇总导出
  services/<module>/     # 业务服务（ai/automation/billing/currency/data/export/import/maintenance/
                         #   marketing/platform/security/system/ui/update）
  styles/
    tokens.dart          # PiggyTokens / PiggyDimens / PiggyChartTokens / PiggyPosterTokens / PiggyTextTokens
    header_skins.dart    # 顶部皮肤注册表 + 各 *_skin.dart（CustomPainter / SVG）
  utils/                 # 工具函数（含 platform_info.dart 的 PlatformFeature）
  widget/                # 桌面小组件逻辑
  widgets/               # 通用组件库（ai/analytics/biz/category/charts/currency/posters/ui）
  app.dart               # 应用根 Widget     main.dart # 入口     theme.dart # 主题
packages/                # 8 个本地 path 子包（flutter_ai_kit[_openai|_zhipu]、flutter_cloud_sync[_supabase|_webdav|_s3|_icloud]）
prd/<snake_case_id>/     # 需求与设计文档：requirements.md（验收依据）+ design.md（技术决策与取舍）
docoments/               # 01-17 工程文档（注意目录名就是 docoments）+ INDEX.md
docs/                    # 审计报告 / 优化计划 / 贡献指南（contributing/）/ 设计 token（design/）/ 证据（evidence/）
test/                    # 镜像 lib/ 结构（ai/backup/cloud/data/encryption/maintenance/pages/providers/
                         #   repositories/services/styles/utils/widget/widgets）
```

**文件归属**：业务页面 `lib/pages/<module>/`；通用组件 `lib/widgets/biz/` 或 `lib/widgets/ui/`；Provider `lib/providers/`；业务服务 `lib/services/<module>/`；工具 `lib/utils/`；主题相关 `lib/styles/`。单文件 ≤ 500 行，`build()` ≤ 100 行，超出即拆。

## 常用命令

```bash
# 依赖与代码生成
flutter pub get
dart run build_runner build       # 改 db.dart / freezed / JsonSerializable 后必跑
                                  # （2.15 起 --delete-conflicting-outputs 已移除）
dart run build_runner watch                                # 开发期监听

# 质量门禁（提交/PR 前本机跑通同等检查）
dart format .                        # 必须无修改
flutter analyze                      # CI 用 `flutter analyze --fatal-infos`（0 issue 门禁）
flutter test                         # 全量测试

# 运行与构建
flutter run --flavor dev             # dev 是默认 flavor
flutter build apk --flavor prod --release
flutter build appbundle --flavor prod --release            # AAB（release.yml 产物）
dart run flutter_launcher_icons      # 生成 Android 图标（iOS 图标手工维护）
flutter gen-l10n                     # 改 .arb 后重新生成本地化类

# 图标素材（scripts/）
python scripts/gen_icons_from_image.py    # 从源图抠图产出 legacy / adaptive / monochrome
python scripts/gen_adaptive_icons.py
python scripts/gen_ios_icons.py
```

- **Windows 本地跑测试的坑**：依赖 `NativeDatabase.memory()`（drift FFI）的用例需要 `sqlite3.dll` 在 PATH 上（CI 的 ubuntu-latest 自带 libsqlite3）。本地先把 DLL 目录加进 PATH 再 `flutter test`（如 `$env:PATH="D:\DevTools\sqlite3-bin;$env:PATH"`）；纯 mock 用例不需要。**不要**给 `flutter_cloud_sync_s3` 子包加 `meta` 依赖——会引发解析冲突导致 `flutter pub get` 静默失败。
- **别跑全仓 `dart format .`**：本机 SDK 的 formatter 与仓库格式化基线不一致，一次会把几百个无关文件重排（2026-10-02 实测 **418 个**，并顺带引入 4 条 `curly_braces_in_flow_control_structures` 新 info）。只格式化自己新增/改动的文件；误跑后按「除本批改动外的文件」逐个 `git checkout --` 回退，别整仓回退（会连自己的改动一起丢）。
- **本地镜像会改写 `pubspec.lock`**：设了 `PUB_HOSTED_URL`（如 `pub.flutter-io.cn`）时，`flutter pub get` 会把 lock 里 200+ 行 `url` 全量改写成镜像地址，并可能顺带抬几个 patch 版本（实测 254 行 url + 4 处版本漂移）。提交前必须 `git status` 确认没把它带上——CI 的 analyze job 已加守卫拦这道（`pubspec.lock 镜像守卫`）。
- **CI**（`.github/workflows/analyze.yml`）两个 job：`analyze`（`flutter analyze --fatal-infos`）+ `test`（`flutter test`，承担同步契约结构性回归门禁：`test/cloud/sync_contract_coverage_test.dart`、`sync_diff_category_and_zero_amount_test.dart`、`restore_preserves_local_only_columns_test.dart`）。issue-lint / pullfrog 为辅助检查。
- **发版**：唯一入口 `.github/workflows/release.yml`，当前开发主线分支 `wait`。**发版前须先更新全局版本号 + 更新日志并提交推送，再打 tag**（见下方「发版流程」检查清单）。完整链路、产物命名与踩坑清单见下方「发版流程」章节。

## 发版流程

**唯一入口**：`.github/workflows/release.yml`。

### 触发与守门

| 触发方式 | 条件 | 结果 |
| --- | --- | --- |
| 打 tag（推荐） | `git tag vX.Y.Z && git push origin vX.Y.Z`（必须是 `v*` tag，且 tag 提交在 `wait` 上） | GitHub Release（非 prerelease）+ Play `internal` 轨道 |
| 手动 `workflow_dispatch` | **仅允许 `wait` 分支**；可指定 tag 名，留空则用 `manual-<short_sha>` | `dry_run` 默认 `true`：只构建并出 Actions Artifacts，**不建 Release、不上传 Play / TestFlight**；显式传 `dry_run=false` 才真正发布 |

`audit` job 是**全流程守门**（tag / 手动都跑，`android` / `ios` / `release` 均 `needs: [audit]`）：

1. 手动触发校验分支必须是 `wait`；
2. tag 触发用 `git merge-base --is-ancestor` 校验 tag 提交在 `origin/wait` 上——**任意分支打 tag 不再能发版**（否则会直推 Play / TestFlight）；
3. 版本单调性：取历史 `v*` tag 中版本最高者，新 tag 版本低于它即拒绝，防止误发低版本；
4. 单点计算发布意图 `publish`（push tag 恒 `true`；手动触发看 `dry_run`），下游 Play / TestFlight / Release 上传环节统一引用它。

**版本对齐口径（2026-10-08 修订）**：发版版本仍以 tag 为唯一真值，由 `release.yml` 经 `--build-name` / `--build-number` 注入构建；但**发版人必须在打 tag 前先把 `pubspec.yaml#version` 更新为同一版本**（并同步更新应用内更新日志，见「更新日志维护」），让 `pubspec` 与已发布版本保持一致。CI 侧**仍不做 tag ↔ pubspec 一致性硬校验**（历史 `manual-<short_sha>` 等非语义 tag 会误报），对齐靠流程保证。

### 版本注入与对齐（CI 不写回 pubspec.yaml）

- **版本真值**：`pubspec.yaml#version`（当前 `0.1.0`）。**发版前由发版人先更新为本次发布版本**，让开发主线版本与已发布版本对齐；开发中它代表主线当前版本。
- **发版版本**：`release.yml` 把 tag 名注入构建，**CI 不写回 `pubspec.yaml`**——`--build-name=<tag 去掉 v 前缀>` + `--build-number=github.run_number`，并 `--dart-define=CI_VERSION=<tag>` 供应用内「关于」页与 OTA 检查读取（`lib/pages/settings/about_page.dart`、`lib/services/update/update_checker.dart`，未定义时回退 `PackageInfo`）。
- **禁止**再用 `sed -i "s/^version: .*//"` 改 `pubspec.yaml`：Android job 是 GNU sed、iOS job 是 BSD sed（`-i ""`），口径不一致且会污染工作区。
- **产物名只跟 tag 走**：打 `v0.1.0` 得到 `piggycount-v0.1.0-*`，与 `pubspec.yaml` 当前值无关。**Release 页停在旧版本 ≠ 代码没更新，只是没打新 tag**。

### 更新日志维护

应用内「更新日志」页的数据源是 `lib/pages/settings/changelog_data.dart` 的 `kChangelogVersions`（中文硬编码，最新版本在前；页面标题等界面文案仍走 l10n），入口在「关于」页（`lib/pages/settings/about_page.dart`）。**每次发版都必须在打 tag 前补齐本版本条目**：

1. 从**上一个发版 tag** 到当前 `HEAD` 提取提交记录（`--no-merges` 收敛合并提交，仅作人工归纳素材）：
   ```bash
   git --no-pager log --no-merges --pretty=format:"%h %s" v<上一版本>..HEAD
   ```
2. 从记录中**人工提炼面向用户的重要信息**（新功能 / 体验改进 / 关键修复），按 `ChangelogSection`（`icon` + `title` + `items`）分组整理，`summary` 写一句话概述。
3. 在 `kChangelogVersions` **头部插入**新条目：`version` = 本次版本号（与 tag 去 `v` 前缀一致）、`date` = 发版日，保持日期倒序（最新在前）。
4. 与 `pubspec.yaml#version` 的改动放进**同一次提交**（见检查清单第 4 步）。

### 产物命名

Android（`splits.abi` 拆 3 ABI + universal，见 `android/app/build.gradle`）：

| Gradle 内部名 | Release 资产名 | 用途 |
| --- | --- | --- |
| `app-prod-arm64-v8a-release-v*.apk` | `piggycount-<VERSION>-arm64-v8a.apk` | 主流真机 / Apple Silicon 模拟器（主分发） |
| `app-prod-armeabi-v7a-release-v*.apk` | `piggycount-<VERSION>-armeabi-v7a.apk` | 32 位老设备 |
| `app-prod-x86_64-release-v*.apk` | `piggycount-<VERSION>-x86_64.apk` | Intel / Win / Linux 模拟器 |
| `app-prod-universal-release-v*.apk` | `piggycount-<VERSION>-universal.apk` | 三 ABI 兜底 |
| `app-prod-release.aab` | `piggycount-<VERSION>.aab` | Google Play（按设备分发 ABI） |

- **四个 APK 必须都带 ABI 后缀**：历史上 arm64-v8a 被命名成不带 ABI 的 `piggycount-<VERSION>.apk`，Release 页上看起来「没有 v8a 包」——已修正为显式 `-arm64-v8a`（这会改变主分发的下载文件名，属对外可感知变更）。
- **AAB 绝不能开 `splits.abi`**：`build.gradle` 已按 task name 动态判定（含 `bundle` 时关 splits），否则 R8 同次 minify 产出 4 份 shrunk-resources，AGP 报 "Multiple shrunk-resources files found"。
- iOS：`piggycount-<VERSION>-{signed,unsigned}.ipa`、`-iphoneos.app.zip`、`-iphonesimulator.app.zip`。

### 上传目标

| 目标 | 条件 | 备注 |
| --- | --- | --- |
| Google Play | 配了 `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | 只推 **`internal` 轨道**，生产发布在 Play Console 手动提升。**不要改回 `production`**——tag 触发即直推生产，无人工复核 |
| TestFlight | 配了 `APPLE_ID` + `APPLE_APP_SPECIFIC_PASSWORD` + iOS 签名 secrets | 未配置则跳过 |
| Telegram | 配了 `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` | 可选通知 |

secret 缺失时对应步骤**跳过而非失败**（`exit 0`），构建产物仍在 Actions Artifacts 里。

### 发版检查清单

1. `wait` 分支上 `dart format .`（无修改）→ `flutter analyze --fatal-infos`（0 issue）→ `flutter test` 全绿。
2. **更新全局版本号**：把 `pubspec.yaml#version` 改为本次发布版本（= 即将打的 tag 去掉 `v` 前缀）——这是唯一真值，`android/app/build.gradle` 的 `versionName` / `versionCode` 由 `flutter.versionName` 派生，不用另改。
3. **更新应用内更新日志**：按「更新日志维护」，从上一个发版 tag 到 `HEAD` 的提交记录中提取重要信息，在 `lib/pages/settings/changelog_data.dart` 的 `kChangelogVersions` 头部插入新条目（版本号与日期对齐第 2 步）。
4. **提交并推送**：把第 2、3 步改动一次性提交（如 `chore(release): 版本号与更新日志更新至 vX.Y.Z`）并 push 到 `wait`，确认工作区干净——**必须在打 tag 前完成，否则 tag 指向的提交里没有这些改动**。
5. 打 tag：`git tag vX.Y.Z && git push origin vX.Y.Z`（必须在 `wait` 上，且版本高于历史 `v*` tag）。
6. 等 `audit` → `android` / `ios` → `release` 全绿；**动过 iOS 签名必须实跑回归**。
7. Release 页核对资产：4 个 APK（含 `-arm64-v8a`）+ AAB + iOS 四件套齐全。

### 已知坑

- **iOS widget 签名靠 bundle id 精确匹配**：`Configure Xcode project for signing` 用 perl 按 `PRODUCT_BUNDLE_IDENTIFIER` 匹配后插入 `PROVISIONING_PROFILE_SPECIFIER`。工程里的值是 `com.wait.piggycount.PiggyCountWidgetExtension`，脚本一度写成 `com.tntlikely.piggycount...`，**匹配不上 → Widget 扩展签名配置根本没插入**。改 iOS bundle id 时，必须同步改 release.yml 的正则与 `ios/ExportOptions.plist` 的 `provisioningProfiles` 键。
- **`docoments/13-build-release.md` 的产物表**随本流程一起维护，改命名规则时同步更新，否则又成新的漂移源。
- **漏写更新日志 CI 不会拦**：`test/pages/settings/changelog_page_test.dart` 只校验数据结构（字段非空 + 日期倒序），**不校验最新条目版本号是否等于发版 tag / `pubspec.yaml#version`**——所以「发版前补更新日志」这一步只靠检查清单第 3 步人工保证。
- **其余历史文档里的旧版本号不要照抄**：`docoments/01`、`03`、`16`、`17`、`prd/*`、`docs/optimization-plan-*` 仍写着 `Flutter 3.27.3` / `version: 0.0.1` 等旧值（成于 2026-07，属历史留存，**刻意不改**）。版本相关一律以 `pubspec.yaml` + 本文件 + 代码为准；`test/`、`docs/synctest/` 下的测试报告记录的是**当时实测版本**，更不得回改。
- **发版不可并发取消**：`release.yml` 的 `concurrency.cancel-in-progress: false`（与 `analyze.yml` 刻意相反）——半套资产比排队更糟，**不要手动取消进行中的 release run**。
- **相关 secrets**：`ANDROID_KEYSTORE_BASE64` / `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD`、`APPLE_CERTIFICATE_P12` / `APPLE_CERTIFICATE_PASSWORD` / `APPLE_PROVISIONING_PROFILE` / `APPLE_PROVISIONING_PROFILE_WIDGET` / `APPLE_TEAM_ID`、`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`、`APPLE_ID` / `APPLE_APP_SPECIFIC_PASSWORD`；缺失时对应环节降级为未签名 / 跳过上传，仅告警不失败。
- **tag 打错需修正**：先删远端再重打（`git push origin :refs/tags/vX.Y.Z`），不要强推覆盖已有 tag。

## 数据模型与迁移

- **表名复数、字段 camelCase**；主键 `id`（int 自增）+ `syncId`（UUID，跨设备标识，唯一索引）。外键用 `references()`，但 SQLite 默认未启用外键约束。
- **迁移在 `lib/data/db.dart` 的 `MigrationStrategy`**：新增表 / 字段必须升 `schemaVersion` 并追加迁移块，用 `CREATE ... IF NOT EXISTS` 等保证幂等；破坏性变更走重建表。新增索引需评估读写比（高频：`syncId`、`(ledger_id, happened_at)`、`category_id` / `account_id`）。**跨表迁移操作（如 `_updatedAtTouchTables` 建 `updated_at` 触发器）前必须先查 `sqlite_master` 确认表存在**，跳过后续版本才建的表，由对应建表迁移块补齐——否则老用户升级路径上 `CREATE TRIGGER` 作用于不存在的表会让迁移崩溃、App 打不开。
- **查询必须参数化**：用 `Variable<T>` 绑定，**禁止**字符串拼接 SQL。批量写入用 `db.transaction(() async { ... })`。响应式 UI 用 `watch()` 返回 Stream。
- **测试注入内存库**：`PiggyDatabase.forTesting(NativeDatabase.memory())`（跳过文件系统 / 平台副作用）。
- 当前版本演进要点：v44 回收站 `deleted_transactions`（软删搬行）、v45 `transactions.original_amount`、v46 账本自定义字段 `custom_field_definitions` + `transactions.custom_values_json`、v47 周期模板注入 `recurring_transactions.template_field_values`、v48 索引修复型迁移、v49 日历节假日本地缓存 `holiday_entries` + 更新记账 `holiday_update_meta`（均不进同步 / 备份）。历史 migrations 明细见 `docoments/07-data-model.md`（该文档版本较旧，以 `db.dart` 为准）。

## UI / 前端约定

- **Design Token 单源**（`lib/styles/tokens.dart`）：`PiggyTokens.scaffoldBackground/surface/surfaceSecondary/textPrimary/textSecondary/divider/success|warning|error|info(context)`；`PiggyDimens.p8/p12/p16`、圆角语义档 `radiusXs(4)/radiusSm(8)/radiusMd(10)/radiusLg(12)/radiusXl(16)/radius2xl(20)/radius3xl(24)`（`radius12/radius16` 为别名）；`PiggyTextTokens.title/body/label(context)`。无 `BuildContext` 的场景（`CustomPainter`、主题定义）用静态常量（仅亮色值，暗黑必须走带 context 的方法）。
- **不允许裸魔法值**：布局尺寸 / 颜色 / 圆角 / 字体一律取 token；新 Token 加进 `tokens.dart` 而不是散落页面。
- **主题色驱动页面背景**：亮色 Scaffold 背景不是写死的常量——由 `PiggyTheme.deriveLightScaffoldBackground(primary)` 从主题色派生同色系淡色（HSL 明度 0.95），`PiggyTokens.scaffoldBackground(context)` 直接读 `Theme.scaffoldBackgroundColor`，换主题色后背景 / AppBar / Tab 栏自动跟随。`PiggyTheme.lightTheme/darkTheme` 必传 `primary`。**已删除的旧常量禁止再引用**：`scaffoldBackgroundLightStatic`、`honeyGold` / `hiveBrown` / `energyOrange` / `paperIvory`。
- **输入型 / 确认型交互走底部抽屉**：项目近一轮 UI 统一为底部抽屉口径（见 `prd/ui_bottom_drawer/`）；新增选择 / 确认交互沿用既有抽屉组件，不要新造 `AlertDialog` 列表。
- **弹窗外壳统一 `AppDialogShell`**：`AppDialog` 纯文本 API 表达不了的自定义内容弹窗（表单 / 选择器等）才用共用外壳 `AppDialogShell`（`lib/widgets/ui/dialog.dart`）；确认 / 通知一律走 `AppDialog` API（见下），禁止手写 `showDialog + AlertDialog/AppDialogShell + Outlined/Filled` 双按钮，禁止手写 `backgroundColor: PiggyTokens.surfaceElevated(context)` + `shape: RoundedRectangleBorder(radiusXl)` 这类逐处复制的样板。
- **确认 / 通知弹窗统一 iOS 警示框**：一律调 `AppDialog.confirm/info/error/warning`。外观：270 宽窄卡片（`PiggyDimens.alertWidth`）+ 标题 `titleLarge w600` 居中 + 说明 `bodySmall` + `textSecondary` 居中（`\\n` 转义由外壳统一处理，arb 里写真换行）+ 底部 iOS 分栏（横竖 1px 中性 hairline，不用 `divider()`，后者暗黑泛主题色；取消正文色｜确认主题 primary；单按钮通知为单个全宽确认钮；说明超长时内部滚动，按钮常驻可见）。
- **删除类确认标 `destructive: true`**：确认侧 error 色 + 动词文案（`okLabel: commonDelete`）。不可逆删除（删账本含云端备份）走 `showDoubleDangerConfirmDialog`（双重 + 倒计时 + 点外部/返回键不可关），保持 friction，**不得降级为单确认**。
- **表单类弹窗不套窄卡片**：含输入框 / 导航行的（如账本编辑框）内容区保持宽卡片，底部按钮用共用 `PiggyDialogActions`（取消｜确认分栏，确认默认 primary）与确认框同一语言。按钮文字颜色必须显式写进 `Text.style`（`bodyLarge` 自带 onSurface 默认色会盖掉按钮 `foregroundColor`）。
- **表单输入框统一描边式 `piggyOutlinedDecoration`**（2026-09-30 起，基准实现：云同步配置三表单 `cloud_service_page.dart` 的 `_CloudConfigSheet` + 加密「设置密码」弹窗 `password_setup_dialog.dart`）：表单类输入框一律调共用装饰（`lib/widgets/ui/piggy_input.dart`，经 `widgets/ui/ui.dart` 导出）——待机 1px 中性描边 + 聚焦主题色 2px + 浮动标签（`labelText`）+ 圆角 `radiusSm` + `contentPadding` 12/14；颜色 / 线宽沿用 `OutlineInputBorder` 的 M3 默认推导，不要各页重写。**禁止各页自拼 `InputDecoration`**（手写 `OutlineInputBorder` / `UnderlineInputBorder` 下划线 / 自拼 filled 底色）。例外：贴合卡片或列表的**无边框内嵌输入**（标题栏搜索框、币种 / 分类选择器与下拉组件内的搜索行、记账金额显示位等）保留各自轻量样式，用 `piggyFilledDecoration`（仅限这类场景，不再用于表单），**不要硬套描边**。
- **底部抽屉操作按钮统一双等宽大按钮**：底部一行两个等宽按钮——左侧取消（`OutlinedButton`）+ 右侧确认/保存（`FilledButton`），高 48（`PiggySheetActions.kHeight`），一律用共用组件 `PiggySheetActions`（`lib/widgets/ui/sheet_actions.dart`，经 `widgets/ui/ui.dart` 导出）。**表单类抽屉同样走底部按钮行**（2026-09-30 二次统一：加密「设置密码」抽屉 `password_setup_dialog.dart` 与同步配置三表单共用外壳 `_CloudConfigSheet` 已从「标题栏两端图标」改回底部双按钮，旧的顶栏图标口径作废）。不要在各抽屉手写右对齐小按钮；抽屉内容含 `TextField` 等 Material 系组件时，外壳必须显式包 `Material`（transparent 路由底不提供 Material 祖先，缺失直接红屏）。
- **表单字段用行式组件（2026-10-09）**：表单 / 筛选抽屉里「挑一个值」的字段（账户 / 分类 / 标签 / 币种 / 日期…）一律用 `lib/widgets/ui/value_row.dart` 的 `PiggyValueRow`（图标 + 名称 + 右对齐值 + 尾部槽位：有 `onClear` 显示警示色清除键，否则有 `onTap` 显示箭头），分组小标题用同文件的 `PiggySectionLabel`；2~3 个互斥选项用 `lib/widgets/ui/segmented_control.dart` 的 `PiggySegmentedControl`（高 40 / `radiusSm` / 选中 = 主色 12% 底 + 1.5 描边）；三者经 `widgets/ui/ui.dart` 导出。**不要再各页手写**：两行堆叠 `ListTile`、并排 `ChoiceChip`（各自成块、留白零碎、高度对不齐）都不合格。要素细节有三处坑：值区必须独享 `Expanded` 且右对齐（否则值右缘参差）、行名**不参与 flex**（否则尾部图标被推到行中间）、尾部只有一个 32 宽槽位（清除键**取代**箭头，不并排）。值要自绘走 `AmountText`（跟随「隐藏金额」开关）时传 `valueWidget`；`placeholder` 由调用方给，组件不绑死 l10n key。基准实现 `lib/widgets/biz/search_filter_sheet.dart`（2026-10-09 抽出公共组件，储蓄目标表单同批改用，契约见 `test/pages/savings_goals_page_test.dart` 的「分段来源 + 行式字段」用例 + `test/widgets/search_filter_sheet_test.dart`）。
- **表单抽屉一律用悬浮卡片外壳**（2026-09-30 起；**唯一外壳 = `lib/widgets/ui/form_sheet.dart` 的 `PiggyFormSheet` + `showPiggyFormSheet`**，2026-10-08 起所有表单抽屉都直接复用它，禁止各页再自抄外壳）：含输入框 / 搜索框 / 长列表的抽屉（选择器类见下条 `PiggyPickerSheet`）同口径——弹层底 `Colors.transparent`，键盘避让（`KeyboardBottomInsetPadding(extra: p16)`，或等价的 `Padding(viewInsets.bottom)`）→ `SafeArea(top: false)`（统一吃掉底部安全区，**内部不要再叠 `paddingOf.bottom`，否则双重留白**）→ 左右留距 `p16` → 显式 `Material`（`surfaceElevated` 底 + `radiusXl` 四角圆角 + `Clip.antiAlias`；transparent 路由底没有 Material 祖先，缺了直接红屏）→ 卡片内边距 `p20`，内容 `mainAxisSize.min` + `CrossAxisAlignment.stretch`。**表单抽屉结构固定为**：抓取条（32×4 中性色圆角条，既是可下拉关闭的把手也是视觉提示）→ 标题居中（`PiggyTextTokens.strongTitle` + `fontSize: 17`）→ `p16` → 字段区（`Flexible(loose)` + `SingleChildScrollView`）→ `p20` → `PiggySheetActions`。**标题与底部按钮行常驻不滚动，只有字段区滚动** —— 长表单（周期账单 12+ 字段、分类图标网格、AI 提示词）不必滚到底才能点保存；**下拉关闭整卡一条通路**（2026-10-09 重做，`showPiggyFormSheet` 传 `enableDrag: false`；**实现已抽成公共件 `lib/widgets/ui/sheet_drag.dart`，表单抽屉与列表型选择器共用，别再各写一份**）：`PiggySheetDragScope` 把整卡垫在 `RepaintBoundary` + `Transform` 上（长表单必须带 `RepaintBoundary`，否则下拉 / 回弹逐帧重绘整张表单直接卡顿）、纵向位移由 `AnimationController` 进度决定；非滚动区（抓取条 / 标题 / 按钮行 / 选择器顶栏）由外层 `GestureDetector` 取手指位移，内容滚动区（`PiggySheetDragContent`，表单抽屉里就是字段区）从 `OverscrollNotification` 取位移（内容区物理统一链 `ClampingScrollPhysics` —— 回弹物理不发 `OverscrollNotification`，各平台必须一致 —— 再用挂在其上的钉顶装饰器：抽屉一下拉就把内容钉在顶部，于是**手指折返上滑 1:1 收回抽屉而内容不动**，内容从收回到底后那一帧起才交回滚动）。两路**只是输入源**，位移 / 判定 / 收尾共用：拖动中跟手且可停住，松手按「位移超过卡片高度一半、或下滑速度 > 700px/s」关闭，否则回弹归位（旧的两套 —— 「字段区攒够 72 逻辑像素直接 pop」与「折返时另起定时回弹动画」—— 都已废；回弹动画一次下拉只许起一次，别每帧 `animateBack`）。门禁测试：`test/widgets/form_sheet_shell_test.dart`（含跟手 1:1、折返上滑收回时内容不动、停住、两路一致、快速下滑两路各一例）。
- **`PiggyDialogActions` 只服务弹窗窄卡片**：它自带底部圆角裁切，仅供居中弹窗紧贴底边使用，**不要垫进悬浮卡片抽屉内部**（外垫留白会让圆角与卡片错位、按压器被切）；抽屉（含表单抽屉）一律用 `PiggySheetActions`。
- **选择器抽屉统一外壳 `PiggyPickerSheet`**（2026-09-30 起，`lib/widgets/ui/picker_sheet.dart`）：**所有**选择器 / 动作菜单类抽屉（滚轮：日期 / 时间 / 通用 / 年份范围；列表：币种 / 账户 / 分类 / 账本设置 / 折算详情；网格：1~28 日；少选项单选；附件来源等）一律 `showPiggyPickerSheet<T>(context, builder:)` 弹出，内容包 `PiggyPickerSheet(title:, subtitle?, onConfirm?, confirmEnabled?, maxHeight?, child:)`。外壳与表单抽屉同款悬浮卡片（transparent 弹层底 + `Padding(viewInsets.bottom)` 键盘避让 + `SafeArea(top: false)` + 左右 / 底部 `p16` + `Material(surfaceElevated / radiusXl / Clip.antiAlias)`），差异只在操作区走**顶栏两端图标**：取消 `Icons.close` 在左（中性色）+ 标题居中（`strongTitle` 17，可选 `subtitle` 小号三级色）+ 确认 `Icons.check` 主色在右，底部**不放按钮行**；**没有确认动作的选择器（点选即应用 / 点选即收起）不传 `onConfirm`**，右侧自动补等宽占位保证标题居中（数据未就绪时传 `confirmEnabled: false` 呈禁用态）。长列表 / 搜索列表 / 网格用 `maxHeight`（固定值如币种 440、网格 320，或按屏高比例 `screen * 0.7`）+ 内部滚动，宽度靠左右 `p16` 留距**不要**再设人为卡高。共用入口：1~28 日网格 `showDayOfMonthPickerSheet`（`widgets/biz/day_of_month_picker.dart`）、币种 `showCurrencyPickerSheet`（`widgets/currency/currency_picker_sheet.dart`）、账户 `AccountPicker.show`、少选项单选 `showPiggyOptionSheet`、附件来源 `showAttachmentSourceSheet`（`widgets/biz/attachment_source_sheet.dart`）。旧的全宽平底弹层（`surfaceElevated` + `BorderRadius.vertical(top:)`）、纯文本「取消｜标题｜确定」头部 `WheelPickerHeader`、以及各选择器自带的 `Container` / `DraggableScrollableSheet` 外壳**已全部删除**，不要再新造，也不要在调用方复制外壳样板。**可下拉关闭按内容类型开**（2026-10-09 加）：`showPiggyPickerSheet(context, dragToDismiss: true, builder:)` —— 只有**内容是可滚动列表 / 网格**的选择器才开（内容区手势在手势竞技场里归它，模态抽屉自身的拖拽够不到内容区，列表滚到顶后继续下拉原本什么也不会发生）；判定 / 跟手 / 钉顶物理与表单抽屉同一套（`sheet_drag.dart`），代价是内容区物理统一 Clamping（iOS 上这些列表不再回弹）。**滚轮型（`CupertinoPicker`：日期 / 时间 / 通用 / 年份范围、账户）必须保持默认 false** —— 竖直拖拽本身就是滚轮操作，钉顶会把滚轮手势抢走；内容不可滚动的动作菜单 / 日历也**不必开**（整卡本来就能被模态抽屉自身拖走，开了只会白丢拖拽时的遮挡层淡出）。白名单由 `test/widgets/picker_sheet_drag_test.dart` 从源码派生守门（含「拖滚轮不动抽屉」用例）。
- **顶栏本体抽成 `PiggySheetHeader`**（`lib/widgets/ui/sheet_header.dart`，2026-10-02）：「X 左 / 标题居中 `strongTitle` 17 / ✓ 右（无确认动作补 48 占位）」这段顶栏被 `PiggyPickerSheet` 与「金额表单优先」记账抽屉（`TransactionEditorPage._buildQuickEntrySheet`，标题 + 支出/收入/转账分段 + 数字键盘「完成」自收尾）共用，**顶栏样式不许再各写一份**。三种外壳的分工：`PiggyFormSheet`（表单，标题 + 字段 + 底部双按钮）/ `PiggyPickerSheet`（选择器 / 动作菜单，顶栏 + 内容 + `maxHeight`）/ `PiggySheetCard`（内容自备时只给卡片，顶栏另拼 `PiggySheetHeader`）。记账 / 编辑抽屉走第三条：`PiggySheetCard` + `PiggySheetHeader` + 分段 + `AmountEditorSheet`，**不要再用全宽 `Material` + `PiggyTitleBar`**（旧的 `scaffoldBackground` 平底弹层已下线）。
- **单选列表抽屉的选项行规范**（基准实现 `showPiggyOptionSheet` + `appearance_settings_page.dart`）：选项行视觉对齐 `SettingsNavItem`——裸前置标识（图标或原生字符，**不用背景盒**，统一占 24px 槽位居中，保证各选项标题起点同一条竖线；纯文字选项不占槽位）+ 标识后 12 间距 + 标题 `bodyMedium w500` + 内边距 16/14；带说明的选项在标题下加副文案（`PiggyTextTokens.label`，不随选中变色）；**高亮只给选中项**：选中项前置标识 / 标题 / 尾部 check 用主色（标题加粗 w600），未选中项一律中性色（`iconSecondary` / `textPrimary`），不要全列表都上主色；语言类选项的前置标识用它自己的**原生字符**（中 / 繁 / EN / 한），不要拿同一个 globe 图标冒充所有语言。不放分割线。
- **加载指示器统一 `PiggySpinner`**（`lib/widgets/ui/piggy_spinner.dart`，2026-10-03）：全项目唯一的「不定态加载动效」——静止细环 + 实心点沿环内轨道匀速绕行（描边 / 轨道半径 / 点半径按 `size` 比例推导，任意尺寸观感一致；动画经 `CustomPainter(repaint:)` 驱动，不触发 rebuild）。**凡是「只在转、没有确切百分比」的加载一律用它，不要再手写 `CircularProgressIndicator`**（历史上散出 94 处、尺寸分六档）。尺寸口径：按钮内 16~20、内容区居中 36（= M3 原默认值，保持布局不变）、遮罩 40~50。**颜色必须显式传**：旧 `CircularProgressIndicator` 不传色时隐式取 `colorScheme.primary`，迁移时统一写 `color: PiggyTokens.primary(context)` 才不偏色；主题色按钮 / 深色遮罩上传 `textOnPrimary` / `Colors.white`。组件自带方形占位，外面不必再套 `SizedBox`。**不要用它替代语义进度**：预算 / 额度 / 分类占比 / 海报排名等 6 处 `LinearProgressIndicator` 与「关于」页 OTA 下载百分比环（`about_page.dart`，唯一承载进度处）保留原生控件——百分比/计数已有文案承载时才可换（如开屏同步遮罩的 `checked/total`）。
- **i18n**：新文案先写 `app_zh.arb`，再补 `app_en.arb`（模板，必填）；`flutter gen-l10n`（或 `flutter pub get`）重新生成本地化类。key 用 camelCase + 模块前缀（`budget_` / `transaction_` …）+ 动作后缀（`_title` / `_desc` / `_btn` / `_hint`）。
- **性能**：长列表用 `flutter_list_view`（支持精准 `jumpToIndex`）而非 `ListView.builder`；列表项 key 用 `ValueKey(item.id)`（**不要拼 index**）；长列表 item / 复杂图表 / 动画用 `RepaintBoundary`；大数据解析放 `compute()` isolate；列表 / 统计类 Provider 加 `autoDispose`。
- **用户设置**存 SharedPreferences；云凭据存 `flutter_secure_storage`（iOS Keychain / Android Keystore），云配置读写集中在 `packages/flutter_cloud_sync/lib/src/config/cloud_service_store.dart`。

## 测试与质量门禁

- **测试分层**：单元（`test/`，Repository / Service / 纯函数）/ Widget（`test/widget/`）/ 页面级回归（`test/pages/`）。测试文件镜像被测路径，如 `test/repositories/local_account_repository_test.dart`。
- **必测场景**：正常路径 / 空数据 / 边界 / 错误路径，外加**同步兼容**——写操作是否产生 `local_changes` 记录。
- **Mock 用 mocktail**，不用 mockito（避免 codegen）。同步相关测试用假 `CloudProvider` / 内存库（见 `test/cloud/`、`test/backup/`）驱动，不要连真实后端。
- **同步相关改动**：修改 push / pull / diff / 指纹逻辑必须同步更新契约覆盖测试的字段清单，并保证 `flutter analyze --fatal-infos` + `flutter test` 全绿。
- **字体令牌 ratchet**：`test/styles/font_size_token_ratchet_test.dart` 钉死硬编码字号「只减不增」，新增裸字号字面量会让它变红。
- **验收证据**：声称完成前提供可复核证据（测试输出 / 门禁结果 / 实机截图），不要仅凭类型通过就下结论。

## Python 脚本与实测工具链（`scripts/`）

- `scripts/` 下是数据注入、图标生成、内存 / 帧率 profile、对比校验等辅助脚本（Python），它们是开发工具，**不参与 App 构建**。
- 包名 / 路径约定（模拟器双端同步实测）：dev 包 `com.wait.piggycount.dev.debug`，本地库 `app_flutter/piggycount.sqlite`，附件 `app_flutter/attachments/`。
- 拉 / 推二进制必须用 `adb exec-out`（`adb shell cat` 会把 `\n` 转成 `\r\n`，拉 sqlite 必坏）；`adb push` 用 Windows 原生路径。
- **清库只删 `piggycount.sqlite*` + `attachments/`，绝不碰 `shared_prefs/`**（含库加密主密钥与云配置）。
- **拉库取证必须连 `-wal` / `-shm` 一起拉**：Drift 全程 WAL 模式，App 运行期间的提交可能还留在 `piggycount.sqlite-wal` 里没 checkpoint。只拉主库会**静默丢行** —— 实测 2026-10-03 S3 双端轮因此把 A 端的 40008 笔看成 40000 笔，凭空多出 8 笔「仅 B 有」的假差异，差一步就当成同步缺陷上报。正确做法：`adb exec-out` 拉 `sqlite` + `-wal` + `-shm` 三件套**同目录同名**落盘（`<x>.sqlite` / `<x>.sqlite-wal` / `<x>.sqlite-shm`），由 Python `sqlite3` 打开时自动重放 WAL；`force-stop` 只能提高 checkpoint 概率，**不能**替代拉 `-wal`。
- 对比脚本退出码：`0` = 无非预期差异，`2` = 存在不一致，`3` = 契约漂移（三向校验失败）。

## Git 约定

- **分支**：`wait` 是开发主线（release 手动触发仅限此分支）；功能分支 `feature/<name>`、修复 `fix/<desc>`、重构 `refactor/<module>`、文档 `docs/<name>`。
- **Conventional Commits（中文）**：`<type>(<scope>): <简短描述>`，类型 `feat` / `fix` / `refactor` / `style` / `perf` / `test` / `docs` / `chore` / `ci` / `revert`；简短描述 ≤ 50 字符、祈使句，正文说「为什么」。正文要点用列表，批量工作可在标题末尾附日期。
- **PR**：小而专注（目标 ≤ 500 行）；按 `.github/PULL_REQUEST_TEMPLATE.md` 填写；CI 必过（`dart format` 无修改需求、`flutter analyze` 0 issue、`flutter test` 全绿）。
- **提交前自检**：`dart format .` → `flutter analyze` → `flutter test` →（改过 schema / codegen 源）`build_runner build` → 新功能有测试 → 暗黑模式正常 → 文案进 `.arb`。
- **不要主动提交**：除非用户明确要求，否则只改工作区、把结果交用户确认。

## 外部文档

- 贡献与开发流程：`docs/contributing/CONTRIBUTING_ZH.md`（英文 `CONTRIBUTING_EN.md`）
- Design Token 对照：`docs/design/DESIGN_TOKENS.md`；UI 评审：`docs/design/UI_OPTIMIZATION_REVIEW.md`
- 工程文档：`docoments/01-17`（01 项目总览 / 03 技术栈 / 04 系统架构 / 06 数据同步 / 07 数据模型 / 08 数据访问 / 09 错误处理 / 10 测试策略 / 11 性能 / 12 安全 / 13 构建发布 / 14 日志 / 15 开发规范 / 16 已知问题 / 17 版本演进）+ `docoments/INDEX.md`。**注意：这批文档成于 2026-07，同步架构 / 类名（`SyncEngine`、`BeeDatabase`、`BeeTokens` 等）已滞后于代码，遇到冲突一律以代码与 `pubspec.yaml` 为准。**
- 需求与设计留档：`prd/README.md`（索引与进度对照）+ 各 `prd/<id>/{requirements,design}.md`
- 云同步配置：`docs/cloud-setup.md`；加密边界：`docs/encryption-security-boundary.md`
- 优化计划与审计：`docs/optimization-plan-2026-09-19.md`、`docs/sync-comprehensive-audit-*.md`、`docs/s3-webdav-sync-audit-*.md`
- 上游工程：Riverpod <https://riverpod.dev/> · Drift <https://drift.simonbinder.eu/> · Effective Dart <https://dart.dev/guides/language/effective-dart> · Conventional Commits <https://www.conventionalcommits.org/zh-hans/>