import 'package:drift/drift.dart' as d;

import '../data/db.dart';
import '../data/models/custom_field_values.dart';
import '../data/repositories/base_repository.dart';
import '../data/repositories/transaction_repository.dart'
    show TransactionUpdateBySyncIdData, BatchAttachmentData;
import '../services/data_import_service.dart';
import '../services/system/logger_service.dart';

/// 同步合并「分阶段耗时」追踪开关（P2 性能定位用）。
///
/// 默认 **关闭**：开启后每个账本会多打一行 debug 级
/// `[perf] ledger=N phase=full categories=..ms accounts=..ms …`，
/// 供 `scripts/live_db/run_20260926/95_perf_report.sh` 汇总。
///
/// 定位已完成（2026-09-26：单账本 apply 由 ≈29.3s 降到 0.05~0.63s），
/// 常态运行无需该噪声；需要复测性能时把它改为 true 重新构建即可。
/// 汇总行 `批量更新: size=… 主表=…ms tag=…ms` 始终保持（单行、低频、有诊断价值）。
const bool kSyncPerfTraceEnabled = false;

/// 同步变更类型
enum SyncChangeType { added, modified, deleted }

/// 参与同步的**实体**种类（区别于交易行本身）。
///
/// 背景：合并路径此前只对「交易」产出 diff，账户 / 分类 / 标签 / 预算 /
/// 周期规则 / 手动汇率一律 upsert-only —— 对端删掉的实体在本地永不消失，
/// merge-then-publish 又把它们写回云端，形成永久 ping-pong
/// （与 D-1 分类、S11 附件同构的第四个洞）。自定义字段定义已由 D-4 先行补齐
/// （`mirrorDeleteAbsentCustomFields`，静默镜像删除），本枚举覆盖其余各类；
/// v11 起追加 `holding`（投资持仓，user-global，与 account 同款四道闸门）。
enum SyncEntityKind {
  account,
  holding,
  category,
  tag,
  budget,
  recurring,
  rateOverride,
}

/// [SyncEntityKind] → `local_changes.entity_type` 的词汇映射。
///
/// **必须与仓储写路径逐字一致**（`LocalRepository.deleteAccount` 记
/// `'account'`、`LocalExchangeRateRepository.removeOverride` 记
/// `'exchange_rate_override'`、v52 的 `deleteHolding` 记 `'holding'` …）——
/// 闸门 ④ 靠它比对未推送变更，口径错了等于闸门失效，本机新建未上传的实体会
/// 被误判成"对端已删"。
const Map<SyncEntityKind, String> _syncEntityChangeType = {
  SyncEntityKind.account: 'account',
  SyncEntityKind.holding: 'holding',
  SyncEntityKind.category: 'category',
  SyncEntityKind.tag: 'tag',
  SyncEntityKind.budget: 'budget',
  SyncEntityKind.recurring: 'recurring',
  SyncEntityKind.rateOverride: 'exchange_rate_override',
};

/// 一条「对端已删、本地还在」的实体删除候选。
///
/// [localId] 是本地主键；[syncId] 是跨设备身份锚点（缺失即本机新建、
/// 云端缺席不可信 → 不会产出候选）。
///
/// [name] 只放**实体自身的名字**（账户名 / 分类名 / 标签名 / 预算所属分类名 /
/// 周期规则备注），**空串表示该实体没有专属名字**（总预算、无备注的周期规则）
/// —— 预览由种类标签兜底。服务层不得塞任何面向用户的文案（AGENTS.md
/// 「文案禁硬编码」），也不得把 `type` 之类的原始枚举值漏给 UI。
class SyncEntityDelete {
  final SyncEntityKind kind;
  final int localId;
  final String? syncId;

  /// 实体自身名字；空串 = 只显示种类标签。**不是**本地化文案。
  final String name;

  /// 仅 [SyncEntityKind.rateOverride] 有值：`BASE/QUOTE`。
  /// 汇率覆盖的业务键是 (base, quote) 而非主键，删除时按业务键定位。
  final String? bizKey;

  const SyncEntityDelete({
    required this.kind,
    required this.localId,
    this.name = '',
    this.syncId,
    this.bizKey,
  });
}

/// 单条变更
class SyncChange {
  final SyncChangeType type;

  /// 云端版本（added/modified 有值）
  final ImportTransaction? cloudTransaction;

  /// 本地版本（modified/deleted 有值）
  final Transaction? localTransaction;

  /// 实体删除载荷。`type == deleted && entityDelete != null` 即「删除一条
  /// 实体（账户/分类/标签/预算/周期规则/汇率覆盖）」，此时
  /// [localTransaction] 为 null —— 预览与 apply 两侧都按本字段分流。
  final SyncEntityDelete? entityDelete;

  /// 本条是否实体删除（区别于删除交易行）。
  bool get isEntityDelete => entityDelete != null;

  /// 用户是否选中
  ///
  /// SYNC-05：默认值按类型区分——added/modified 默认选中，
  /// **deleted（本地独有交易将被删除）默认不选中**。旧实现一律默认 true，
  /// 「一键应用」会把"删除本地独有交易"这类破坏性变更静默包含在内；
  /// 现在用户需在预览中显式勾选才会执行删除。
  bool selected;

  /// 变更描述（用于 modified 类型显示差异）
  final List<String> diffDetails;

  SyncChange({
    required this.type,
    this.cloudTransaction,
    this.localTransaction,
    this.entityDelete,
    bool? selected,
    this.diffDetails = const [],
  }) : selected = selected ?? (type != SyncChangeType.deleted);
}

/// Diff 预览结果
class SyncPreview {
  final List<SyncChange> changes;

  int get addedCount =>
      changes.where((c) => c.type == SyncChangeType.added).length;

  int get modifiedCount =>
      changes.where((c) => c.type == SyncChangeType.modified).length;

  int get deletedCount =>
      changes.where((c) => c.type == SyncChangeType.deleted).length;

  /// 实体删除条数（[deletedCount] 的子集，交易行删除之外的另一半）。
  int get entityDeletedCount => changes.where((c) => c.isEntityDelete).length;

  /// 交易行删除条数（[deletedCount] 扣除实体删除）。
  int get transactionDeletedCount => deletedCount - entityDeletedCount;

  bool get isEmpty => changes.isEmpty;

  int get selectedCount => changes.where((c) => c.selected).length;

  const SyncPreview({required this.changes});
}

/// 应用变更结果
class SyncApplyResult {
  final int addedCount;
  final int modifiedCount;
  final int deletedCount;

  /// 实体删除实际执行条数（[deletedCount] 只统计交易行删除）。
  final int entityDeletedCount;

  const SyncApplyResult({
    this.addedCount = 0,
    this.modifiedCount = 0,
    this.deletedCount = 0,
    this.entityDeletedCount = 0,
  });

  int get totalCount =>
      addedCount + modifiedCount + deletedCount + entityDeletedCount;
}

/// Diff 计算服务
class SyncDiffService {
  /// 计算本地与云端的差异
  ///
  /// [repo] - 数据仓库
  /// [ledgerId] - 账本 ID
  /// [cloudTransactions] - 云端交易列表（含 syncId）
  /// [localTransactions] - 本地交易列表（可选，不传则自动查询）
  /// [cloudMeta] - 云端快照的**元数据段**（账户/分类/标签/预算/周期规则/
  ///   汇率覆盖 + payload version）。传了才会计算实体删除候选；不传则只出
  ///   交易 diff（保持既有调用方与单测的语义不变）。
  ///
  /// 返回 null 表示云端数据不含 syncId，无法计算 diff
  Future<SyncPreview?> computeDiff({
    required BaseRepository repo,
    required int ledgerId,
    required List<ImportTransaction> cloudTransactions,
    List<Transaction>? localTransactions,
    ImportData? cloudMeta,
  }) async {
    // 检查云端数据是否含有 syncId
    final hasSyncId = cloudTransactions.any((t) => t.syncId != null);
    if (!hasSyncId && cloudTransactions.isNotEmpty) {
      logger.info('SyncDiff', '云端数据不含 syncId，无法计算 diff');
      return null;
    }

    // 获取本地交易
    final local = localTransactions ??
        await repo.getTransactionsByLedger(ledgerId);

    // M1 空快照守卫：云端 items 为空（缺失/损坏/被清空）无法区分
    // 「云端合法清空」与「快照异常」，一律拒绝 diff（返回 null）。
    // 调用方降级走全量替换确认路径，该路径另有 restoreLedgerFromJson
    // 的空快照守卫，两层守卫共同防止「全部本地交易被误标 deleted 一键应用」。
    if (cloudTransactions.isEmpty && local.isNotEmpty) {
      logger.warning('SyncDiff',
          '云端交易列表为空但本地有 ${local.length} 条，拒绝计算 diff（防误删）');
      return null;
    }

    // 批量获取本地交易的标签
    final localTxIds = local.map((t) => t.id).toList();
    final tagsMap = localTxIds.isNotEmpty
        ? await repo.getTagsForTransactions(localTxIds)
        : <int, List<Tag>>{};

    // 批量获取本地交易的附件（附件差异贯通：与指纹口径一致，
    // 否则"只加/删/换附件"的 modified 检测不出 → 云端差异永不落本地，
    // 且 merge-then-publish 会把无附件快照回传覆盖云端，形成 ping-pong）
    final attachmentsMap = localTxIds.isNotEmpty
        ? await repo.getAttachmentsForTransactions(localTxIds)
        : <int, List<TransactionAttachment>>{};

    // 批量获取本地交易涉及的账户名称
    final accountIds = <int>{};
    for (final tx in local) {
      if (tx.accountId != null) accountIds.add(tx.accountId!);
      if (tx.toAccountId != null) accountIds.add(tx.toAccountId!);
    }
    final accounts = accountIds.isNotEmpty
        ? await repo.getAccountsByIds(accountIds.toList())
        : <Account>[];
    final accountIdToName = <int, String>{};
    for (final acc in accounts) {
      accountIdToName[acc.id] = acc.name;
    }

    // 批量获取本地交易涉及的分类（名称 + kind）。
    //
    // 与账户名同款解析：`_compareTx` 需要「本机分类的 kind|name」去和快照里的
    // `categoryKind`/`categoryName` 比对。`sync_fingerprint.dart` 早已把这两项
    // 纳入指纹白名单，diff 却不比较 → 出现「指纹说不同、diff 说无变化」的
    // 自相矛盾：同步状态卡一直显示"本地与云端有差异"，用户点「下载同步」
    // 却一条变更都点不出来，且 merge-then-publish 会把本地旧分类回传覆盖
    // 云端，两端形成永久 ping-pong（与审计 S11「指纹已纳入附件、diff 不比较
    // 附件」完全同构的遗留半截，故此处一并补齐）。
    //
    // transfer 无分类语义：导出侧与指纹侧都按 `isTransfer ? '' : ...` 归空，
    // 这里提前剔除，保证 diff 口径与指纹口径严格同源。
    final categoryIds = <int>{};
    for (final tx in local) {
      if (tx.categoryId != null && tx.type != 'transfer') {
        categoryIds.add(tx.categoryId!);
      }
    }
    final categoriesById = categoryIds.isNotEmpty
        ? await repo.getCategoriesByIds(categoryIds)
        : <int, Category>{};

    // 本地周期规则 id → syncId（用于比对交易上的周期锚点 recurringSyncId）。
    //
    // 语义必须与导出侧 `transactions_json.dart` 一字不差：那边是
    // `if (t.recurringId != null && (recurringIdToSyncId[id] ?? '').isNotEmpty)`，
    // 即「锚点解析不到（规则已删 / 无 syncId）＝ 无锚点，不写键」。这里同样只
    // 保留可解析的映射，解析不到 → 视为无锚点，两端口径才能对齐。
    final recurringRows =
        await repo.getRecurringTransactionsByLedger(ledgerId);
    final recurringIdToSyncId = <int, String>{
      for (final r in recurringRows)
        if (r.syncId != null && r.syncId!.isNotEmpty) r.id: r.syncId!,
    };

    // 建立映射：syncId → 交易
    final localBySyncId = <String, Transaction>{};
    for (final tx in local) {
      if (tx.syncId != null) {
        localBySyncId[tx.syncId!] = tx;
      }
    }

    final cloudBySyncId = <String, ImportTransaction>{};
    for (final tx in cloudTransactions) {
      if (tx.syncId != null) {
        cloudBySyncId[tx.syncId!] = tx;
      }
    }

    // H1（audit S5）：无 syncId 本地交易的业务键兜底索引。
    // 此前这些行完全不进索引 → 云端同业务内容版本被误判 added，
    // 恢复合并时重复插入。键与 _compareTx 的时间口径一致（精确到秒）；
    // 仅当该键在本地位**唯一**时才参与配对（多行同键无法可靠配对，
    // 宁可维持旧行为也不误配）。
    // 已知取舍：键包含 note —— note 本身不同的行无法经键配对，维持旧行为
    // 判为 added。刻意不放宽为「时间+金额」宽松匹配：那会把同秒同额、
    // 备注不同的两笔合法交易误合并（覆盖备注），风险大于重复插入。
    final localBizKeyCounts = <String, int>{};
    final localByBizKey = <String, Transaction>{};
    String bizKeyOf(DateTime at, double amount, String? note) =>
        '${at.millisecondsSinceEpoch ~/ 1000}'
        '|${amount.toStringAsFixed(2)}|${note ?? ''}';
    for (final tx in local) {
      if (tx.syncId != null && tx.syncId!.isNotEmpty) continue;
      final key =
          bizKeyOf(tx.happenedAt, tx.amount, tx.note);
      localBizKeyCounts[key] = (localBizKeyCounts[key] ?? 0) + 1;
      localByBizKey[key] = tx;
    }

    final changes = <SyncChange>[];

    // 1. 遍历云端交易
    for (final entry in cloudBySyncId.entries) {
      final syncId = entry.key;
      final cloudTx = entry.value;
      var localTx = localBySyncId[syncId];
      var matchedViaBizKey = false;

      if (localTx == null) {
        // 云端有、本地无 syncId 匹配 → 尝试业务键唯一兜底配对
        final key = bizKeyOf(
            cloudTx.happenedAt, cloudTx.amount, cloudTx.note);
        if ((localBizKeyCounts[key] ?? 0) == 1) {
          localTx = localByBizKey[key];
          matchedViaBizKey = true;
        }
      }

      if (localTx == null) {
        // 云端有、本地无 → added
        changes.add(SyncChange(
          type: SyncChangeType.added,
          cloudTransaction: cloudTx,
        ));
      } else {
        // 都有，检查是否有差异
        final localTagNames = (tagsMap[localTx.id] ?? [])
            .map((t) => t.name)
            .toSet()
            .toList();
        localTagNames.sort();
        final localAccountName = localTx.accountId != null
            ? accountIdToName[localTx.accountId]
            : null;
        final localToAccountName = localTx.toAccountId != null
            ? accountIdToName[localTx.toAccountId]
            : null;
        final localCategory = localTx.categoryId != null
            ? categoriesById[localTx.categoryId]
            : null;
        final localRecurringSyncId = localTx.recurringId != null
            ? recurringIdToSyncId[localTx.recurringId]
            : null;
        final diffs = _compareTx(
          localTx,
          cloudTx,
          localTagNames: localTagNames,
          localAccountName: localAccountName,
          localToAccountName: localToAccountName,
          localCategoryName: localCategory?.name,
          localCategoryKind: localCategory?.kind,
          localRecurringSyncId: localRecurringSyncId,
          localAttachments: attachmentsMap[localTx.id] ?? const [],
        );
        if (diffs.isNotEmpty) {
          changes.add(SyncChange(
            type: SyncChangeType.modified,
            cloudTransaction: cloudTx,
            localTransaction: localTx,
            diffDetails: diffs,
          ));
        } else if (matchedViaBizKey) {
          // 内容一致但身份缺失：仍需进入变更列表让 apply 阶段认领 syncId，
          // 否则每次预览都重复出现同一伪差异且本地行永远拿不到稳定身份。
          changes.add(SyncChange(
            type: SyncChangeType.modified,
            cloudTransaction: cloudTx,
            localTransaction: localTx,
            selected: true,
            diffDetails: const ['本地交易缺少同步标识，将绑定云端身份'],
          ));
        }
        // 相同（syncId 已匹配）→ unchanged，不加入变更列表
      }
    }

    // 2. 遍历本地交易，查找本地有但云端无的
    for (final entry in localBySyncId.entries) {
      final syncId = entry.key;
      if (!cloudBySyncId.containsKey(syncId)) {
        // 本地有、云端无 → deleted
        changes.add(SyncChange(
          type: SyncChangeType.deleted,
          localTransaction: entry.value,
        ));
      }
    }

    // 3. 实体删除候选（账户/分类/标签/预算/周期规则/汇率覆盖）。
    //    交易行之外的元数据实体此前 upsert-only，对端删除永不传播。
    if (cloudMeta != null) {
      changes.addAll(await computeEntityDeletes(
        repo: repo,
        ledgerId: ledgerId,
        cloud: cloudMeta,
      ));
    }

    // 按类型排序：新增 → 修改 → 删除
    changes.sort((a, b) => a.type.index.compareTo(b.type.index));

    logger.info('SyncDiff',
        '差异计算完成: 新增=${changes.where((c) => c.type == SyncChangeType.added).length}, '
        '修改=${changes.where((c) => c.type == SyncChangeType.modified).length}, '
        '删除=${changes.where((c) => c.type == SyncChangeType.deleted).length}');

    return SyncPreview(changes: changes);
  }

  /// 计算「对端已删、本地还在」的实体删除候选（账户 / 分类 / 标签 / 预算 /
  /// 周期规则 / 手动汇率覆盖）。
  ///
  /// 【为什么必须有】合并路径此前对这些实体只 upsert：对端删除 → 本地留残留 →
  /// merge-then-publish 把残留写回云端 → 对端再同步时「删掉的又回来了」，
  /// 两端指纹永久不一致（每次启动都判 cloudNewer 反复弹窗）。全量恢复路径
  /// 早有镜像删除（`_mirrorDeleteAbsentEntities`），只有合并路径漏了 ——
  /// 与 D-1 分类、S11 附件完全同构的第四个洞。
  ///
  /// 【四条安全闸门，缺一不可】
  /// ① **version ≥ 8**：旧快照根本不携带这些段，"云端缺席"不具备删除语义
  ///    （与恢复路径 `_mirrorDeleteAbsentEntities` 的门控逐字一致）。
  /// ② **解析未损坏**：`skippedItems` 记录了因字段损坏被跳过的条目数 ——
  ///    跳过的条目在云端"缺席"只是解析失败，删掉本地就是数据丢失。
  /// ③ **本地有 syncId**：无 syncId 是本机新建、尚未上传过，云端缺席不代表
  ///    用户删过它。
  /// ④ **本地无未推送变更**（关键闸门）：`createAccount` / `createCategory` /
  ///    `setOverride` 等**建行即自动生成 UUID syncId**，所以闸门 ③ 挡不住
  ///    "本机刚建、还没上传"的实体。`local_changes` 里有该实体的未推送行
  ///    ⇒ 用户刚动过它、云端还没收到 ⇒ 云端缺席是**信息滞后**而非删除。
  ///    快照上传成功后 `markSnapshotPushed` 会清空未推送队列，此后闸门放行。
  ///
  /// 另加**引用守卫**，但刻意放在 **apply** 侧而不是这里（见
  /// `_applyEntityDeletes`）：预览时按"合并前"的引用判定会漏掉最常见的场景
  /// ——「删账户 + 删它的交易」在预览那一刻交易还在、账户仍被引用，于是账户
  /// 不进候选；用户勾掉交易删除后本地已与云端一致 → 没有未勾选的删除 →
  /// S1 守卫放行 → force 回传把账户又写回云端 → **对端刚删的账户复活**。
  /// 放到 apply 侧按"交易落库后"的引用判定，同一轮即可收敛，且用户若没勾
  /// 交易删除则拦下账户删除、不留悬空外键（那种情况下交易删除未勾选，S1
  /// 守卫本来也会拦住回传）。
  ///
  /// 返回的 [SyncChange] 一律 `selected = false`（SYNC-05 口径：删除是破坏性
  /// 变更，必须用户显式勾选）。未勾选时启动检查的 S1 守卫会跳过本轮回传，
  /// 删除不会以"复活"的形式被推回云端。
  Future<List<SyncChange>> computeEntityDeletes({
    required BaseRepository repo,
    required int ledgerId,
    required ImportData cloud,
  }) async {
    final version = cloud.version;
    if (version == null || version < 8) {
      logger.info('SyncDiff',
          '快照 version=$version < 8，不计算实体删除（旧快照无删除语义）');
      return const [];
    }
    // 该段有解析跳过的条目 → 云端清单不完整，不敢据此判定"对端已删"
    bool sectionLost(String key) => (cloud.skippedItems[key] ?? 0) > 0;

    // v11 段门控：**段不存在 ≠ 对端删光了该段实体**。
    // 各段有各自的引入版本（holdings 是 v11 新增）。若不按引入版本判定，
    // 读 v8~v10 快照时 holdings 段"整段缺失"会被当成"云端一条都没有"，
    // 于是本地每一条持仓都变成「对端已删」候选 —— 用户勾一下就把全部持仓
    // 删了，这是比「删除不传播」严重得多的数据丢失。
    bool sectionAbsent(String key, int introducedIn) =>
        version < introducedIn || sectionLost(key);
    final lostSections = <String>[
      for (final k in const [
        'accounts',
        'holdings',
        'categories',
        'tags',
        'budgets',
        'recurring',
        'rateOverrides'
      ])
        if (sectionLost(k)) k,
    ];
    if (lostSections.isNotEmpty) {
      logger.warning('SyncDiff',
          '快照元数据段存在解析损坏（${lostSections.join('/')}），'
          '跳过这些段的实体删除判定（云端缺席只是解析失败，不是删除）');
    }

    // 闸门 ④：本地尚未推送的变更涉及这些实体 → 云端缺席不可信
    final tracker = repo.changeTracker;
    final pending = tracker == null
        ? const <String>{}
        : <String>{
            for (final c in await tracker.getUnpushedChanges())
              '${c.entityType}:${c.entitySyncId}',
          };

    final changes = <SyncChange>[];

    bool cloudSyncIdPresent(SyncEntityKind kind, String sid) {
      switch (kind) {
        case SyncEntityKind.account:
          return cloud.accounts.any((a) => a.syncId == sid);
        case SyncEntityKind.holding:
          return cloud.holdings.any((h) => h.syncId == sid);
        case SyncEntityKind.category:
          return cloud.categories.any((c) => c.syncId == sid);
        case SyncEntityKind.tag:
          return cloud.tags.any((t) => t.syncId == sid);
        case SyncEntityKind.budget:
          return cloud.budgets.any((b) => b.syncId == sid);
        case SyncEntityKind.recurring:
          return cloud.recurrings.any((r) => r.syncId == sid);
        case SyncEntityKind.rateOverride:
          return cloud.rateOverrides.any((o) => o.syncId == sid);
      }
    }

    void offer({
      required SyncEntityKind kind,
      required int localId,
      required String? syncId,
      required String name,
      String? bizKey,
    }) {
      final sid = syncId?.trim();
      if (sid == null || sid.isEmpty) return; // 闸门 ③
      if (cloudSyncIdPresent(kind, sid)) return;
      // 注意：本处的 if/return 不能写成 formatter 偏好的单行 return 形态 ——
      // 那会触发 curly_braces_in_flow_control_structures，而 CI 的
      // `flutter analyze --fatal-infos` 是硬门禁。linter 优先于 formatter。
      if (pending.contains('${_syncEntityChangeType[kind]}:$sid')) {
        return; // 闸门 ④
      }
      changes.add(SyncChange(
        type: SyncChangeType.deleted,
        entityDelete: SyncEntityDelete(
          kind: kind,
          localId: localId,
          syncId: sid,
          name: name,
          bizKey: bizKey,
        ),
      ));
    }

    // ---- 账户（user-global）----
    if (!sectionLost('accounts')) {
      for (final a in await repo.getAllAccounts()) {
        offer(
          kind: SyncEntityKind.account,
          localId: a.id,
          syncId: a.syncId,
          name: a.name,
        );
      }
    }

    // ---- 投资持仓（user-global，v11）----
    //
    // 展示名用持仓自身名字（「贵州茅台」「沪深300ETF」）；空串时预览由种类
    // 标签兜底。持仓无外部引用（它是引用方，不是被引用方），因此删除不会
    // 留悬空外键 —— 但反过来要注意：账户被删时持仓由仓储级联删除，不会走到
    // 这里的候选判定。
    //
    // ⚠️ 段门控用 [sectionAbsent]（带引入版本 v11）而不是 sectionLost：
    // v8~v10 快照没有 holdings 段，整段缺失不具删除语义。
    if (!sectionAbsent('holdings', 11)) {
      for (final h in await repo.getAllHoldings()) {
        offer(
          kind: SyncEntityKind.holding,
          localId: h.id,
          syncId: h.syncId,
          name: h.name,
        );
      }
    }

    // ---- 分类（user-global）----
    if (!sectionLost('categories')) {
      for (final c in await repo.getAllCategories()) {
        offer(
          kind: SyncEntityKind.category,
          localId: c.id,
          syncId: c.syncId,
          name: c.name,
        );
      }
    }

    // ---- 标签（user-global）----
    if (!sectionLost('tags')) {
      for (final t in await repo.getAllTags()) {
        offer(
          kind: SyncEntityKind.tag,
          localId: t.id,
          syncId: t.syncId,
          name: t.name,
        );
      }
    }

    // ---- 预算（ledger-scoped，无外部引用）----
    //
    // 展示名只给**分类预算的分类名**；总预算没有专属名字（空串），预览由
    // 「预算」这个种类标签兜底 —— 服务层不塞「总预算/分类预算」这种面向用户的
    // 文案（AGENTS.md 文案禁硬编码），也不塞 `type` 原始枚举。
    if (!sectionLost('budgets')) {
      final budgets = await repo.getAllBudgets(ledgerId);
      final budgetCategoryIds = <int>{
        for (final b in budgets)
          if (b.categoryId != null) b.categoryId!,
      };
      final budgetCategories = budgetCategoryIds.isEmpty
          ? const <int, Category>{}
          : await repo.getCategoriesByIds(budgetCategoryIds);
      for (final b in budgets) {
        offer(
          kind: SyncEntityKind.budget,
          localId: b.id,
          syncId: b.syncId,
          name: b.categoryId == null
              ? ''
              : (budgetCategories[b.categoryId]?.name ?? ''),
        );
      }
    }

    // ---- 周期规则（ledger-scoped）----
    // 展示名只用备注；没备注就留空串（不把 `type` 枚举值漏给 UI）。
    if (!sectionLost('recurring')) {
      for (final r in await repo.getRecurringTransactionsByLedger(ledgerId)) {
        offer(
          kind: SyncEntityKind.recurring,
          localId: r.id,
          syncId: r.syncId,
          name: r.note ?? '',
        );
      }
    }

    // ---- 手动汇率覆盖（user-global，无引用）----
    if (!sectionLost('rateOverrides')) {
      for (final o in await repo.getAllOverrides()) {
        offer(
          kind: SyncEntityKind.rateOverride,
          localId: o.id,
          syncId: o.syncId,
          name: '${o.baseCurrency}/${o.quoteCurrency}',
          bizKey: '${o.baseCurrency}/${o.quoteCurrency}',
        );
      }
    }

    logger.info('SyncDiff',
        '实体删除候选 ${changes.length} 条: '
        '账户=${changes.where((c) => c.entityDelete!.kind == SyncEntityKind.account).length} '
        '分类=${changes.where((c) => c.entityDelete!.kind == SyncEntityKind.category).length} '
        '标签=${changes.where((c) => c.entityDelete!.kind == SyncEntityKind.tag).length} '
        '预算=${changes.where((c) => c.entityDelete!.kind == SyncEntityKind.budget).length} '
        '周期=${changes.where((c) => c.entityDelete!.kind == SyncEntityKind.recurring).length} '
        '汇率=${changes.where((c) => c.entityDelete!.kind == SyncEntityKind.rateOverride).length}');

    return changes;
  }

  /// 比较本地和云端交易的差异
  List<String> _compareTx(
    Transaction local,
    ImportTransaction cloud, {
    List<String> localTagNames = const [],
    String? localAccountName,
    String? localToAccountName,
    String? localCategoryName,
    String? localCategoryKind,
    String? localRecurringSyncId,
    List<TransactionAttachment> localAttachments = const [],
  }) {
    final diffs = <String>[];

    // ================= 字段比较的两种策略（务必按类别选）=================
    //
    // ① **严格比较**（归一后逐值比，`local != cloud`）：
    //    该字段自引入版本起就在导出侧，**缺键 = 无该属性**。
    //    适用：type / amount / happenedAt / note / 账户名 / tags /
    //    excludeFromStats / excludeFromBudget / 分类(kind+name) /
    //    周期锚点(recurringSyncId) / attachments。
    //
    // ② **「缺键不改动」**（先 `cloud.x != null &&` 再比）：
    //    用于有历史包袱的字段 —— 旧版客户端导出时**不写该键**，此时缺键必须
    //    理解为"不改动本地值"，否则旧快照会静默抹掉本地已填值。
    //    适用：currencyCode / nativeAmount / originalAmount / customValues。
    //    ⚠️ **新增字段一律用 ①**。错用 ② 会让「云端真的删掉了该属性」也传不
    //    下来 → 两端指纹不同而 diff 为空 → 永久不收敛（D-2 的机制）。
    //
    // 两类都受 `test/cloud/sync_contract_coverage_test.dart` 的**穷举覆盖**守护：
    // 指纹白名单里每个键都必须能被这里判成 modified，豁免需写明可复核的理由。
    // ================================================================

    if (local.type != cloud.type) {
      diffs.add('类型: ${local.type} → ${cloud.type}');
    }
    if ((local.amount - cloud.amount).abs() > 0.001) {
      diffs.add('金额: ${local.amount} → ${cloud.amount}');
    }
    // 比较时间（精确到秒）
    final localTime = DateTime(
      local.happenedAt.year,
      local.happenedAt.month,
      local.happenedAt.day,
      local.happenedAt.hour,
      local.happenedAt.minute,
      local.happenedAt.second,
    );
    final cloudTime = DateTime(
      cloud.happenedAt.year,
      cloud.happenedAt.month,
      cloud.happenedAt.day,
      cloud.happenedAt.hour,
      cloud.happenedAt.minute,
      cloud.happenedAt.second,
    );
    if (localTime != cloudTime) {
      diffs.add('时间变更');
    }
    if ((local.note ?? '') != (cloud.note ?? '')) {
      diffs.add('备注: "${local.note ?? ''}" → "${cloud.note ?? ''}"');
    }

    // 比较账户
    if (cloud.type == 'transfer') {
      if ((localAccountName ?? '') != (cloud.fromAccountName ?? '')) {
        final from = localAccountName ?? '无';
        final to = cloud.fromAccountName ?? '无';
        diffs.add('转出账户: $from → $to');
      }
      if ((localToAccountName ?? '') != (cloud.toAccountName ?? '')) {
        final from = localToAccountName ?? '无';
        final to = cloud.toAccountName ?? '无';
        diffs.add('转入账户: $from → $to');
      }
    } else {
      if ((localAccountName ?? '') != (cloud.accountName ?? '')) {
        final from = localAccountName ?? '无';
        final to = cloud.accountName ?? '无';
        diffs.add('账户: $from → $to');
      }
    }

    // 比较分类（名称 + kind）。
    //
    // 不比较则「只改分类」的编辑永不跨设备传播 —— 而且不是"静默不同步"这么
    // 简单：`sync_fingerprint.dart` 早已把 categoryName/categoryKind 纳入指纹
    // 白名单，于是两端指纹不一致但 diff 为空，同步状态卡永久显示
    // 「本地与云端有差异」，用户点「下载同步」却一条变更都没有（无法自愈）；
    // 更糟的是 merge-then-publish 会把本地旧分类回传覆盖云端，形成 ping-pong。
    // 与审计 S11 附件差异（指纹已纳入、diff 未比较）同构，故与附件一并纳入。
    //
    // 口径与导出/指纹严格同源：transfer 归空（`isTransfer ? '' : ...`），
    // 避免转账行因主表残留 categoryId 产生伪差异。
    final localCatName =
        (local.type == 'transfer') ? '' : (localCategoryName ?? '');
    final localCatKind =
        (local.type == 'transfer') ? '' : (localCategoryKind ?? '');
    final cloudCatName =
        (cloud.type == 'transfer') ? '' : (cloud.categoryName ?? '');
    final cloudCatKind =
        (cloud.type == 'transfer') ? '' : (cloud.categoryKind ?? '');
    if (localCatName != cloudCatName || localCatKind != cloudCatKind) {
      diffs.add('分类: ${localCatName.isEmpty ? '无' : localCatName} → '
          '${cloudCatName.isEmpty ? '无' : cloudCatName}');
    }

    // 比较 v8 G2 周期规则锚点（recurringSyncId）。
    //
    // 指纹白名单早已纳入它（`sync_fingerprint.dart` 的 `'recurringSyncId'`），
    // 但这里此前**完全没比** —— 与 D-1 分类、S11 附件同构的第三个洞
    // （由 `test/cloud/sync_contract_coverage_test.dart` 的穷举检查直接抓出：
    // 构造"只改周期锚点"的快照，computeDiff 返回空 changes）。
    //
    // 口径：**严格比较，刻意不加 `cloud != null` 守卫**。理由：导出侧是
    // `if (t.recurringId != null && resolved.isNotEmpty)` —— 「无锚点不写键」
    // 是确定性的，不存在 `originalAmount` 那种"旧快照缺键"的历史包袱；
    // 两端都按 `?? ''` 归一后比较，与指纹逐字同口径，不会出现
    // 「指纹说不同、diff 说没变化」。
    if ((localRecurringSyncId ?? '') != (cloud.recurringSyncId ?? '')) {
      diffs.add('周期锚点: ${localRecurringSyncId ?? '无'} → '
          '${cloud.recurringSyncId ?? '无'}');
    }

    // 比较标签（去重，避免历史脏数据产生重复标签名导致伪差异）
    final cloudTagNames = (cloud.tagNames ?? []).toSet().toList();
    cloudTagNames.sort();
    if (localTagNames.join(',') != cloudTagNames.join(',')) {
      final from = localTagNames.isEmpty ? '无' : localTagNames.join(', ');
      final to = cloudTagNames.isEmpty ? '无' : cloudTagNames.join(', ');
      diffs.add('标签: $from → $to');
    }

    // 比较账单标记（不计入统计/预算）：不比较则 A 端只改标记时，B 端
    // diff 识别不出 modified，标记永不跨设备同步。
    if (local.excludeFromStats != cloud.excludeFromStats) {
      diffs.add(
          '不计入统计: ${local.excludeFromStats ? '是' : '否'} → ${cloud.excludeFromStats ? '是' : '否'}');
    }
    if (local.excludeFromBudget != cloud.excludeFromBudget) {
      diffs.add(
          '不计入预算: ${local.excludeFromBudget ? '是' : '否'} → ${cloud.excludeFromBudget ? '是' : '否'}');
    }
    // 比较 v30 多币种字段（原币种 + 折算值）。老 JSON 缺键 → null，
    // 此时仅当本地也是 null 才认为无差异（避免老 JSON 触发全量 modified）。
    if (cloud.currencyCode != null && local.currencyCode != cloud.currencyCode) {
      diffs.add('币种: ${local.currencyCode ?? '无'} → ${cloud.currencyCode}');
    }
    // 折算金额：严格按值比较，**不做 `?? 0` 兜底**。
    //
    // 旧写法 `(local.nativeAmount ?? 0) != cloud.nativeAmount` 把「本地未折算
    // (null)」与「云端显式 0」判成相同 → 云端 0 永不落本地；而导出侧 0 是
    // 非空（会写键）、null 不写键（`transactions_json.dart`），两端指纹
    // `''` vs `'0.0'` 不同 → 该行永久不收敛（每次启动判方向未知）。
    // 与 `originalAmount` 同款缺陷，一并修正。
    if (cloud.nativeAmount != null &&
        local.nativeAmount != cloud.nativeAmount) {
      diffs.add('折算金额: ${local.nativeAmount} → ${cloud.nativeAmount}');
    }
    // v45 原始金额：仅当云端**显式携带该键**时才比较（旧快照缺键 → null，
    // 此时不触发 modified，避免"本地已填值 vs 云端无此键"被判成差异并被覆写）。
    //
    // ⚠️ 这里的判据必须是 `local.originalAmount != cloud.originalAmount`，
    // **不能**写成 `(local.originalAmount ?? 0) != cloud.originalAmount`：
    // `originalAmount == 0` 是合法业务值（编辑器 `double.tryParse` 直接接受
    // `0`，如"折扣 0 元/赠品"），而 `null ?? 0 == 0` 会把「本地未填写」与
    // 「云端显式 0」判成相同 → 云端 0 永不落本地。导出侧 0 会写键、null 不写键
    // → 两端指纹 `'0.0'` vs `''` 不同 → 指纹说不同、diff 说无变化，
    // 该行永久不收敛（同上方 nativeAmount）。
    if (cloud.originalAmount != null &&
        local.originalAmount != cloud.originalAmount) {
      diffs.add('原始金额: ${local.originalAmount} → ${cloud.originalAmount}');
    }
    // v46 自定义字段值：仅当云端显式携带该键时才比较（旧快照缺键 → null，
    // 不触发 modified，避免"本地已填值 vs 云端无此键"被判成差异并被覆写）。
    // 用 codec 的规范化比较（键排序 + 数值表示统一），否则键序 / int↔double
    // 表示抖动会产生假差异，把每笔交易都判成 modified。
    if (cloud.customValues != null &&
        !CustomFieldValueCodec.equals(
            CustomFieldValueCodec.decode(local.customValuesJson),
            cloud.customValues)) {
      diffs.add('自定义字段值变更');
    }

    // 比较附件清单（附件差异贯通）。规范化口径与 contentFingerprintFromMap
    // 的 S11 规则一致：排序后的 (sha256, fileName, sortOrder)；键优先级
    // 对齐快照链（L1）：localSha256/sha256 优先，cloudSha256 仅兜底。
    String attKey(String? sha, String? cloudSha, Object? name, int? order) =>
        [(sha ?? cloudSha ?? ''), (name ?? '').toString(), (order ?? 0).toString()]
            .join('|');
    final localAttKeys = localAttachments
        .map((a) => attKey(a.localSha256, a.cloudSha256, a.fileName, a.sortOrder))
        .toSet();
    final cloudAttKeys = (cloud.attachments ?? const [])
        .map((a) => attKey(a.sha256, a.cloudSha256, a.fileName, a.sortOrder))
        .toSet();
    if (!(localAttKeys.length == cloudAttKeys.length &&
        localAttKeys.containsAll(cloudAttKeys))) {
      // 集合不等价（顺序无关的多/少/换附件）
      final added = cloudAttKeys.difference(localAttKeys).length;
      final removed = localAttKeys.difference(cloudAttKeys).length;
      diffs.add('附件变更: 云端多 $added 项 / 本地独有 $removed 项');
    }

    return diffs;
  }

  /// 应用选中的变更
  ///
  /// [repo] - 数据仓库
  /// [ledgerId] - 账本 ID
  /// [selectedChanges] - 用户选中的变更列表
  /// [importData] - 原始导入数据（用于导入分类/账户/标签）
  Future<SyncApplyResult> applySyncChanges({
    required BaseRepository repo,
    required int ledgerId,
    required List<SyncChange> selectedChanges,
    required ImportData importData,
  }) async {
    // M3：云→本地合并全程抑制 change 记录。合并内部会路过大量带
    // changeTracker 的 repo 写方法（账户/分类/标签/预算 upsert、交易批量
    // 插入/更新/删除），任何一处回流 local_changes 都会把云端数据反向
    // 登记「本地编辑」→ Cloud 引擎推送幻影变更 / 触发重复上传。
    final tracker = repo.changeTracker;
    if (tracker == null) {
      return _applySyncChangesInternal(
        repo: repo,
        ledgerId: ledgerId,
        selectedChanges: selectedChanges,
        importData: importData,
      );
    }
    return tracker.withRecordingSuppressed(() => _applySyncChangesInternal(
          repo: repo,
          ledgerId: ledgerId,
          selectedChanges: selectedChanges,
          importData: importData,
        ));
  }

  Future<SyncApplyResult> _applySyncChangesInternal({
    required BaseRepository repo,
    required int ledgerId,
    required List<SyncChange> selectedChanges,
    required ImportData importData,
  }) async {
    // P2 定位用：分阶段耗时（毫秒）。合并路径实测单账本可达数十秒而全量
    // 恢复路径同函数仅几百毫秒，先量化各阶段再决定优化点。debug 级输出，
    // 默认不刷屏；定位完成后保留汇总口径便于后续回归对比。
    final perf = <String, int>{};
    Future<T> timed<T>(String label, Future<T> Function() body) async {
      final sw = Stopwatch()..start();
      try {
        return await body();
      } finally {
        perf[label] = (perf[label] ?? 0) + sw.elapsedMilliseconds;
      }
    }

    void logPerf(String phase) {
      if (!kSyncPerfTraceEnabled) return;
      logger.debug(
          'SyncDiff',
          '[perf] ledger=$ledgerId phase=$phase '
          '${perf.entries.map((e) => '${e.key}=${e.value}ms').join(' ')}');
    }

    // 分类/账户/标签:复用 DataImportService(同一份 batch 优化只在一处维护)。
    // 元数据合并不依赖交易 diff —— 必须在空变更早退之前执行:云端仅有
    // 账户/分类/标签变更时 computeDiff 返回空 preview,若此处先早退,
    // importAccounts 永远不会被调用,账户同步即断链(account_metadata_sync_fix
    // G1+G2)。元数据导入是幂等增量 upsert,多账本循环重复合并无害。
    final categoryCache = await timed('categories',
        () => dataImportService.importCategories(repo, importData.categories));
    final accountNameToId = await timed(
        'accounts',
        () => dataImportService.importAccounts(
              repo,
              importData.accounts,
              defaultCurrency: importData.currency ?? 'CNY',
            ));
    final tagMaps = await timed(
        'tags', () => dataImportService.importTags(repo, importData.tags));
    // v11 投资持仓：与账户同为 user-global 元数据，同样**必须在空变更早退之前**
    // 合并（理由同上方账户注释：云端只有持仓变化时 computeDiff 可能返回空
    // preview，早退就会让持仓同步断链）。幂等增量 upsert，多账本循环重复合并无害。
    // 依赖 accountNameToId → 必须排在 importAccounts 之后。
    await timed(
        'holdings',
        () => dataImportService.importHoldings(
              repo,
              importData.holdings,
              accountNameToId: accountNameToId,
            ));
    // v46 自定义字段定义：必须先于交易落库。交易值以 fieldSyncId 为键，
    // 定义缺失时这些值在编辑表单里没有渲染位（数据仍在，只是看不见）。
    await timed(
        'customFields',
        () => dataImportService.importCustomFields(
              repo,
              ledgerId,
              importData.customFields,
            ));
    // D-4：合并路径同样要**镜像删除**对端已删的字段定义。
    // 恢复路径有 `_mirrorDeleteAbsentEntities`，合并路径此前漏了 →
    // 「删除字段」永不传播，且对端 merge-then-publish 会把它们写回云端
    // （用户视角："删掉的字段又出现了"）。version 门控与恢复路径一致
    // （null / <8 = 旧快照，不删）；无 syncId 的本地新建字段保留。
    await timed(
        'customFieldsMirrorDelete',
        () async => dataImportService.mirrorDeleteAbsentCustomFields(
              repo: repo,
              ledgerId: ledgerId,
              cloudFields: importData.customFields,
              version: importData.version,
            ));

    // 合并范围对齐指纹范围(sync_fingerprint 覆盖 8 类实体):此前只合并
    // 账户/分类/标签,预算/周期规则/手动汇率/月起始日的云端差异永远不落
    // 本地 → 本地指纹与云端永久不一致 → 每次启动都判 cloudNewer 反复弹
    // 「云端有更新」,下载却因交易无 diff 而"导入 0 条"。以下复用全量恢复
    // 路径(DataImportService.importData)的幂等 upsert,语义一致。
    // 周期规则必须在交易之前导入:added 交易靠 recurringSyncIdToId 映射
    // 回填 transactions.recurringId 外键。
    final recurringSyncIdToId = await timed(
        'recurrings',
        () => dataImportService.importRecurrings(
              repo,
              ledgerId,
              importData.recurrings,
              accountNameToId: accountNameToId,
              categoryCache: categoryCache,
            ));
    await timed(
        'budgets',
        () => dataImportService.importBudgets(
              repo,
              ledgerId,
              importData.budgets,
              categoryCache: categoryCache,
            ));
    await timed('rates',
        () => dataImportService.importRateOverrides(repo, importData.rateOverrides));
    // 账本名 / 本位币同样参与快照指纹（sync_fingerprint M2：顶层
    // ledgerName/currency 进指纹），但增量合并此前只回写 monthStartDay：
    // A 端改名后 B 端永远拿不到新名，且本地指纹与云端永久不一致 →
    // 每次启动反复判 cloudNewer 弹「云端有更新」。口径与全量恢复路径
    // (DataImportService.importData) 对齐。
    if (importData.ledgerName != null || importData.currency != null) {
      try {
        await repo.updateLedger(
          id: ledgerId,
          name: importData.ledgerName,
          currency: importData.currency,
        );
      } catch (e) {
        // 失败不阻断交易合并，保留异常细节便于排查（同 F7 口径）。
        logger.debug('SyncDiff', '账本名/币种更新失败(忽略): $e');
      }
    }
    if (importData.monthStartDay != null) {
      // 月起始日以云端快照为准(v8 G5 同语义);失败不阻断交易合并
      try {
        await repo.updateLedger(
          id: ledgerId,
          monthStartDay: importData.monthStartDay!.clamp(1, 28),
        );
      } catch (e) {
        // F7: monthStartDay 更新失败不阻断 diff 流程,但保留异常细节便于排查。
        logger.debug('SyncDiff', 'monthStartDay 更新失败(忽略): $e');
      }
    }

    if (selectedChanges.isEmpty) {
      // 用户没勾任何变更（含实体删除）:仅完成上述元数据 upsert,计数全为 0。
      // 实体删除同样要过这一关 —— 「云端删了个账户」不产生任何交易 diff，
      // 若这里直接 return 而实体删除只在末尾执行，纯元数据场景的删除就永远
      // 落不了地（正是 D-4 之前 customFields 的形状）。勾选为空时二者都无事
      // 可做，所以早退是安全的。
      logPerf('meta-only');
      return const SyncApplyResult();
    }
    final tagNameToId = tagMaps.byName;
    final tagSyncIdToId = tagMaps.bySyncId;

    int addedCount = 0;
    int modifiedCount = 0;
    int deletedCount = 0;

    // 按类型分桶 — added 走批量(WebDAV/Supabase 从远端拉账本场景一次可能上万
    // 条全 added,单条 for 循环要几十分钟;modified/deleted 数量通常小,保持
    // 单条 await)
    final addedChanges = <SyncChange>[];
    final modifiedChanges = <SyncChange>[];
    final deletedChanges = <SyncChange>[];
    for (final c in selectedChanges) {
      switch (c.type) {
        case SyncChangeType.added:
          addedChanges.add(c);
          break;
        case SyncChangeType.modified:
          modifiedChanges.add(c);
          break;
        case SyncChangeType.deleted:
          // 实体删除与交易行删除共用 deleted 桶语义但走不同落地路径
          if (c.isEntityDelete) break;
          deletedChanges.add(c);
          break;
      }
    }

    // ============ added: 复用 DataImportService 的批量插入路径 ============
    // 把 SyncChange → ImportTransaction(cloudTransaction 本来就是 ImportTransaction
    // 类型),直接交给 DataImportService.importTransactions 走 batch:500 条 /
    // 批,一个 db.transaction 内 batch insert tx + tag + attachment + local_changes,
    // 把 N 次单条 await(WebDAV 1 万条全 added 要几十分钟)折叠成 N/500 批。
    if (addedChanges.isNotEmpty) {
      final addedTxs = addedChanges
          .map((c) => c.cloudTransaction!)
          .toList(growable: false);
      final result = await timed(
          'added',
          () => dataImportService.importTransactions(
                repo,
                ledgerId,
                addedTxs,
                accountNameToId: accountNameToId,
                categoryCache: categoryCache,
                tagNameToId: tagNameToId,
                tagSyncIdToId: tagSyncIdToId,
                recurringSyncIdToId: recurringSyncIdToId,
                recordChanges: false, // M3：云→本地路径不回流 local_changes
              ));
      addedCount = result.inserted;
      if (result.skippedRecurring > 0) {
        logger.warning('SyncDiff',
            '云→本应用 added 时有 ${result.skippedRecurring} 笔同日周期实例被判重跳过'
            '（同规则同日且syncId或金额+备注相同），请核对远端是否存在同日多笔合法交易');
      }
    }

    // ============ H1：业务键配对的身份认领 ============
    // 业务键兜底配出的 modified（本地行无 syncId）先回填云端 syncId，
    // 后续按 syncId 的批量更新才能命中这些行。认领失败（目标行已有身份 /
    // syncId 已被其他行占用 / 行已消失）的配对整条放弃 —— 既不新增也不
    // 覆盖，避免重复插入或误写他者；该差异会在下次预览中继续呈现。
    if (modifiedChanges.isNotEmpty) {
      final adopted = <SyncChange>[];
      for (final c in modifiedChanges) {
        final localTx = c.localTransaction;
        final syncId = c.cloudTransaction?.syncId;
        if (localTx != null &&
            (localTx.syncId == null || localTx.syncId!.isEmpty) &&
            syncId != null &&
            syncId.isNotEmpty) {
          final ok = await repo.adoptTransactionSyncId(localTx.id, syncId);
          if (!ok) {
            logger.warning('SyncDiff',
                '业务键配对认领失败，放弃该变更 '
                '(本地id=${localTx.id}, 云端syncId=$syncId)');
            continue;
          }
        }
        adopted.add(c);
      }
      modifiedChanges
        ..clear()
        ..addAll(adopted);
    }

    // ============ modified: 主表用批量 UPDATE,tag 关联单条 await ============
    // 主表 update 跨 isolate boundary 是 N 次但 BEGIN/COMMIT 一次。tag 更新仍
    // 是 N 次单条(每条 tx 的 tagIds 不同,需要先 DELETE WHERE tx_id = ? 再
    // INSERT 新关联);如果 modified 量大到 tag update 也成瓶颈,后续可加专
    // 门的 batch tag-update 接口。
    //
    // Major-09/10 修复：主表更新与 tag 更新分离。主表更新失败时不尝试
    // tag 更新（避免对已回滚的数据写 tag）。tag 更新失败时记录失败计数
    // 并汇总日志，不再静默吞掉。
    if (modifiedChanges.isNotEmpty) {
      final sw = Stopwatch()..start();
      // 账本位币：与 importTransactions 的规则一致（账本币种兜底 CNY）。
      // 用于 modified 路径重算 nativeAmount，避免"只更新 amount、不更新
      // native_amount"导致统计合计（SUM(COALESCE(native_amount, amount))）
      // 读到旧折算值（明细新、合计旧）。
      final ledgerBase =
          ((importData.currency?.isNotEmpty ?? false) ? importData.currency! : 'CNY')
              .toUpperCase();
      // 单币种账本下的 nativeAmount = amount；外币账本保持本地原值
      // （null → update 时 absent），由 L11 检测按需捞回，避免引入汇率
      // 查询复杂度。单币种是本 bug 的主战场。
      final updates = <TransactionUpdateBySyncIdData>[];
      final tagIdsBySyncId = <String, List<int>>{};
      for (final change in modifiedChanges) {
        final cloud = change.cloudTransaction!;
        final syncId = cloud.syncId!;
        final categoryId = _resolveCategoryId(cloud, categoryCache);
        final accountId = _resolveAccountId(cloud, accountNameToId);
        final toAccountId = _resolveToAccountId(cloud, accountNameToId);
        final tagIds =
            _resolveTagIds(cloud, tagNameToId, tagSyncIdToId).toSet().toList();
        final cloudCurrency =
            ((cloud.currencyCode?.isNotEmpty ?? false) ? cloud.currencyCode! : null);
        final isSameBase = cloudCurrency == null || cloudCurrency.toUpperCase() == ledgerBase;
        // 附件清单（云→本 modified 合并）：快照是全量清单，云端条目
        // （含空表）整体替换本地行；sha256 落 localSha256 列供
        // attachments/<sha>.bin 后台补齐。
        final cloudAttachments = (cloud.attachments ?? const [])
            .map((a) => BatchAttachmentData(
                  fileName: a.fileName,
                  originalName: a.originalName,
                  fileSize: a.fileSize,
                  width: a.width,
                  height: a.height,
                  sortOrder: a.sortOrder,
                  cloudFileId: a.cloudFileId,
                  cloudSha256: a.cloudSha256,
                  localSha256: a.sha256,
                ))
            .toList();
        updates.add(TransactionUpdateBySyncIdData(
          syncId: syncId,
          type: cloud.type,
          amount: cloud.amount,
          categoryId: cloud.type == 'transfer' ? null : categoryId,
          accountId: accountId,
          toAccountId: toAccountId,
          happenedAt: cloud.happenedAt,
          note: cloud.note,
          currencyCode: isSameBase ? ledgerBase : cloudCurrency,
          nativeAmount: cloud.nativeAmount ??
              (isSameBase ? cloud.amount : null),
          // 账单标记：diff 合并也要带上，避免"不计入统计/预算"跨设备丢失
          excludeFromStats: cloud.excludeFromStats,
          excludeFromBudget: cloud.excludeFromBudget,
          // v45 原始金额：云端缺键 → null → 本地保持原值（见 Data 类注释）
          originalAmount: cloud.originalAmount,
          // v46 自定义字段值：云端缺键 → null → 本地保持原值；非 null
          // （含空 map = 云端显式清空）才写入。
          customValues: cloud.customValues,
          // v8 G2 周期锚点：云端 recurringSyncId → 本地规则 id 后写入。
          //
          // **检测与应用必须成对**：只加检测不加写入，会让「只改周期锚点」
          // 的差异每轮都被报出来却永远应用不了 —— 用户体验是从"静默不同步"
          // 变成"每轮都提示有变更、点了也没用"，比原来更差。
          //
          // 三态：快照未携带该键 → `Value(null)` 清空（与指纹口径一致，见
          // _compareTx 的严格比较说明）；携带则解析为本地 id，规则已被删 /
          // 未在快照里 → 解析失败同样写 null（清掉悬空锚点）。
          recurringId: d.Value(cloud.recurringSyncId == null
              ? null
              : recurringSyncIdToId[cloud.recurringSyncId]),
          attachments: cloudAttachments,
        ));
        tagIdsBySyncId[syncId] = tagIds;
      }

      // 主表更新（原子操作：单条 BEGIN/COMMIT）
      Map<String, int> syncIdToTxId;
      try {
        syncIdToTxId = await timed('modifiedMain',
            () => repo.updateTransactionsBatchBySyncId(updates, recordChanges: false));
        modifiedCount = syncIdToTxId.length;
      } catch (e, st) {
        // 主表更新失败：不尝试 tag 更新（数据已回滚），记录错误并跳过
        logger.error('SyncDiff', '批量更新主表失败，跳过 tag 更新', e, st);
        syncIdToTxId = {};
      }

      // tag 关联逐条 update（仅主表更新成功的行才更新 tag）
      // Major-10 修复：跟踪失败计数，汇总日志，不再静默吞掉
      if (syncIdToTxId.isNotEmpty) {
        int tagFailCount = 0;
        int tagSkipped = 0;
        // P2 定位用：逐条 updateTransactionTags 的耗时抽样（每行一次事务，
        // 历史注释已标注「量大时需专门的 batch tag-update 接口」）。
        final tagSlow = <(int, String)>[];
        await timed('modifiedTags', () async {
          // 先批量读一次现有 tag 关联，只对**真正变化**的行写库：合并场景下
          // 绝大多数 modified 只是金额/备注变了，tag 集合没变 —— 旧实现每行
          // 都开一次事务先删后插（实测 1407 行 = 5553ms，是主表批量更新的
          // 3.9 倍），属于纯 N 次无谓事务。
          final existingTags =
              await repo.getTagsForTransactions(syncIdToTxId.values.toList());
          for (final entry in tagIdsBySyncId.entries) {
            final txId = syncIdToTxId[entry.key];
            if (txId == null) continue;
            final desired = entry.value.toSet();
            final current =
                (existingTags[txId] ?? const <Tag>[]).map((t) => t.id).toSet();
            if (desired.length == current.length &&
                desired.containsAll(current)) {
              tagSkipped++;
              continue;
            }
            final itemSw = Stopwatch()..start();
            try {
              await repo.updateTransactionTags(
                transactionId: txId,
                tagIds: entry.value,
              );
            } catch (e, st) {
              tagFailCount++;
              logger.error('SyncDiff', 'tag 关联更新失败 syncId=${entry.key}', e, st);
            }
            itemSw.stop();
            if (itemSw.elapsedMilliseconds >= 50) {
              tagSlow.add((itemSw.elapsedMilliseconds, entry.key));
            }
          }
        });
        if (kSyncPerfTraceEnabled && tagSlow.isNotEmpty) {
          tagSlow.sort((a, b) => b.$1.compareTo(a.$1));
          logger.debug('SyncDiff',
              '[perf] tag 慢行 top${tagSlow.length > 3 ? 3 : tagSlow.length}: '
              '${tagSlow.take(3).map((e) => '${e.$1}ms(${e.$2.substring(0, 8)})').join(' ')}');
        }
        if (tagFailCount > 0) {
          logger.warning('SyncDiff',
              'tag 关联更新完成: 成功=${tagIdsBySyncId.length - tagFailCount}, '
              '失败=$tagFailCount（主表数据已更新，tag 可能不一致）');
        }
        logger.info('SyncDiff',
            '批量更新: size=${updates.length} 成功=$modifiedCount '
            '主表=${perf['modifiedMain']}ms tag=${perf['modifiedTags']}ms '
            '(tag 未变跳过 $tagSkipped 行) 合计=${sw.elapsedMilliseconds}ms');
      }
    }

    // ============ deleted: 批量按 syncId 删除 ============
    // 有 syncId 的批量走单条 DELETE WHERE IN;没 syncId 的(老数据)兜底单条
    if (deletedChanges.isNotEmpty) {
      final withSyncIds = <String>[];
      final fallbackIds = <int>[];
      for (final change in deletedChanges) {
        final localTx = change.localTransaction!;
        if (localTx.syncId != null && localTx.syncId!.isNotEmpty) {
          withSyncIds.add(localTx.syncId!);
        } else {
          fallbackIds.add(localTx.id);
        }
      }
      if (withSyncIds.isNotEmpty) {
        try {
          final n = await timed(
              'deleted',
              () => repo.deleteTransactionsBatchBySyncIds(withSyncIds,
                  recordChanges: false)); // M3
          deletedCount += n;
          logger.info('SyncDiff',
              '批量删除: syncId 路径 size=${withSyncIds.length} 实删=$n');
        } catch (e, st) {
          logger.error('SyncDiff', '批量删除失败', e, st);
        }
      }
      for (final id in fallbackIds) {
        try {
          await repo.deleteTransaction(id);
          deletedCount++;
        } catch (e, st) {
          logger.error('SyncDiff', '兜底单条删除失败 id=$id', e, st);
        }
      }
    }

    // 实体删除放在交易删除之后：交易先落定，被引用关系收窄，最后再收敛实体。
    // 顺序不是装饰 —— 引用守卫在 apply 侧按"交易落库后"的引用判定，
    // 放早了会把本轮可删的实体误判成"仍被引用"。
    final entityDeletedCount = await timed(
        'entityDeletes',
        () => _applyEntityDeletes(
              repo: repo,
              ledgerId: ledgerId,
              selectedChanges: selectedChanges,
            ));

    logger.info('SyncDiff',
        '变更已应用: 新增=$addedCount, 修改=$modifiedCount, 删除=$deletedCount, '
        '实体删除=$entityDeletedCount');
    logPerf('full');

    return SyncApplyResult(
      addedCount: addedCount,
      modifiedCount: modifiedCount,
      deletedCount: deletedCount,
      entityDeletedCount: entityDeletedCount,
    );
  }

  /// 执行用户勾选的实体删除（账户 / 分类 / 标签 / 预算 / 周期规则 / 汇率覆盖）。
  ///
  /// 全程已在 `applySyncChanges` 的 `withRecordingSuppressed` 内 —— 仓储的
  /// delete* 会记 user-global / ledger-scoped change，云端权威的删除若回流
  /// local_changes 就是幻影变更。
  ///
  /// **引用守卫在这里（而不是预览时）**：预览那一刻本地交易还在，"删账户 +
  /// 删它的交易"这种最常见的组合会因为账户仍被引用而不进候选 → 用户删完交易
  /// 后本地与云端已一致 → 没有未勾选的删除 → S1 守卫放行 → force 回传把账户
  /// 又写回云端 → 对端刚删的账户复活。放到这里按**交易落库之后**的引用判定，
  /// 同一轮即可收敛。
  ///
  /// 代价：用户勾了实体删除但没勾引用它的那些交易变更时，这里会拦下并保留该
  /// 实体（不留悬空外键）。这种场景下那些交易变更必然处于未勾选态，S1 守卫
  /// 本来就会拦住回传，所以不会有"删不掉又被推回去"的空转。
  ///
  /// 单条失败只记日志不中断：一条实体删不掉不该回滚整个账本的合并
  /// （外层事务会整体回滚，见 `applyPreviewChanges`）。
  Future<int> _applyEntityDeletes({
    required BaseRepository repo,
    required int ledgerId,
    required List<SyncChange> selectedChanges,
  }) async {
    final targets = selectedChanges
        .where((c) => c.isEntityDelete)
        .map((c) => c.entityDelete!)
        .toList(growable: false);
    if (targets.isEmpty) return 0;

    // 交易删除已在调用方落定，这里读到的引用关系是"合并后"的
    final refs = await repo.getSyncEntityReferences();
    var blocked = 0;

    bool stillReferenced(SyncEntityDelete t) {
      switch (t.kind) {
        case SyncEntityKind.account:
          return refs.accountIds.contains(t.localId);
        case SyncEntityKind.holding:
          return false; // 持仓无外部引用（它是引用账户的一方）
        case SyncEntityKind.category:
          return refs.categoryIds.contains(t.localId);
        case SyncEntityKind.tag:
          return refs.tagIds.contains(t.localId);
        case SyncEntityKind.budget:
          return false; // 预算无外部引用
        case SyncEntityKind.recurring:
          return refs.recurringIds.contains(t.localId);
        case SyncEntityKind.rateOverride:
          return false; // 汇率覆盖无外部引用
      }
    }

    var deleted = 0;
    for (final t in targets) {
      if (stillReferenced(t)) {
        blocked++;
        logger.warning('SyncDiff',
            '实体删除被拦下（合并后仍被本地引用，留悬空外键比留实体更糟）: '
            '${t.kind.name} id=${t.localId} "${t.name}"');
        continue;
      }
      try {
        switch (t.kind) {
          case SyncEntityKind.account:
            await repo.deleteAccount(t.localId);
            break;
          case SyncEntityKind.holding:
            // 经 Repository 删除 → 记 user-global 'delete' 变更（不直接写库）。
            await repo.deleteHolding(t.localId);
            break;
          case SyncEntityKind.category:
            await repo.deleteCategory(t.localId);
            break;
          case SyncEntityKind.tag:
            await repo.deleteTag(t.localId);
            break;
          case SyncEntityKind.budget:
            // 总预算删除会级联清掉本账本**所有**预算（仓储既有语义，预算页
            // 手动删除同款）。用户只勾了总预算、没勾那些分类预算时，会被顺带
            // 清掉 —— 显式记一笔，否则"删一条却少了好几条"在日志里无从追查。
            final siblings = await repo.getAllBudgets(ledgerId);
            final victim = siblings.where((b) => b.id == t.localId);
            if (victim.isNotEmpty && victim.first.type == 'total') {
              final others = siblings.where((b) => b.id != t.localId).length;
              if (others > 0) {
                logger.warning('SyncDiff',
                    '删除总预算会级联清掉本账本其余 $others 个预算'
                    '（与预算页手动删除同款语义）: ledgerId=$ledgerId');
              }
            }
            await repo.deleteBudget(t.localId);
            break;
          case SyncEntityKind.recurring:
            await repo.deleteRecurringTransaction(t.localId);
            break;
          case SyncEntityKind.rateOverride:
            final parts = (t.bizKey ?? '').split('/');
            if (parts.length != 2) {
              logger.warning('SyncDiff',
                  '汇率覆盖删除跳过：业务键非法 "${t.bizKey}"');
              continue;
            }
            await repo.removeOverride(base: parts[0], quote: parts[1]);
            break;
        }
        deleted++;
      } catch (e, st) {
        logger.error('SyncDiff',
            '实体删除失败 ${t.kind.name} id=${t.localId} "${t.name}"', e, st);
      }
    }
    if (deleted > 0 || blocked > 0) {
      logger.info('SyncDiff',
          '实体镜像删除已应用: $deleted/${targets.length} 条'
          '${blocked > 0 ? '（另有 $blocked 条因合并后仍被引用而保留）' : ''}'
          '（账户/分类/标签/预算/周期规则/汇率覆盖，对端已删）');
    }
    return deleted;
  }

  // --- 辅助方法 ---

  int? _resolveCategoryId(
      ImportTransaction tx, Map<String, int> categoryCache) {
    if (tx.categoryId != null) return tx.categoryId;
    if (tx.categoryName != null && tx.categoryKind != null) {
      return categoryCache['${tx.categoryKind}|${tx.categoryName}'];
    }
    return null;
  }

  int? _resolveAccountId(
      ImportTransaction tx, Map<String, int> accountNameToId) {
    if (tx.type == 'transfer') {
      if (tx.fromAccountName != null) {
        return accountNameToId[tx.fromAccountName];
      }
    } else {
      if (tx.accountName != null) {
        return accountNameToId[tx.accountName];
      }
    }
    return null;
  }

  int? _resolveToAccountId(
      ImportTransaction tx, Map<String, int> accountNameToId) {
    if (tx.type == 'transfer' && tx.toAccountName != null) {
      return accountNameToId[tx.toAccountName];
    }
    return null;
  }

  List<int> _resolveTagIds(ImportTransaction tx, Map<String, int> tagNameToId,
      Map<String, int>? tagSyncIdToId) {
    final result = <int>{};
    // 优先按 syncId 解析（跨设备 rename 稳定锚定）。v7 JSON 里 tagSyncIds
    // 是权威锚点，name 只是可读参考。仅当所有 syncId 都完整命中时才直接
    // 返回；否则继续用 name 兜底，避免部分 miss 导致标签缺失并触发无限
    // diff 循环。
    if (tagSyncIdToId != null &&
        tx.tagSyncIds != null &&
        tx.tagSyncIds!.isNotEmpty) {
      for (final syncId in tx.tagSyncIds!) {
        final id = tagSyncIdToId[syncId];
        if (id != null) result.add(id);
      }
      if (result.isNotEmpty && result.length == tx.tagSyncIds!.length) {
        return result.toList();
      }
    }
    // fallback 到 name 解析（老 JSON 无 tagSyncIds / syncId 全部 miss）
    if (tx.tagNames != null) {
      for (final name in tx.tagNames!) {
        final id = tagNameToId[name];
        if (id != null) result.add(id);
      }
    }
    return result.toList();
  }

  // 分类/账户/标签的导入逻辑统一委托给 DataImportService.importCategories /
  // importAccounts / importTags(本文件之前有 3 个"简化版"副本,跟主文件不
  // 一致 + 双份维护成本,2026-05-24 重构合并)。
}

/// 全局单例
final syncDiffService = SyncDiffService();
