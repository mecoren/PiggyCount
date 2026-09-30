// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get aiConsentTitle => '开启 AI 功能前,请知悉';

  @override
  String get aiConsentBody =>
      'AI 功能需将相关数据发送给你所配置的第三方 AI 服务商进行处理:\n\n• 发送给谁:默认「智谱 GLM」(open.bigmodel.cn,由智谱华章运营);若你自行配置了其它第三方 AI 服务商,则发送给你填写的服务商。\n• 发送什么:你主动用于识别/对话的内容 —— 账单图片、语音录音、你输入的文字,以及为完成识别/分析所需的分类名称、账户名称和相关交易记录。\n• 用途:仅用于账单识别、记账与你发起的对话分析;小猪记账自身不收集、不存储这些数据。\n\n数据由该第三方服务商按其隐私政策处理。开启即表示你同意上述数据共享。';

  @override
  String get aiConsentAgree => '同意并开启';

  @override
  String get aboutPrivacyPolicy => '隐私政策';

  @override
  String get changelogTitle => '更新日志';

  @override
  String changelogVersionSubtitle(String date, int count) {
    return '$date · $count 项更新';
  }

  @override
  String get appTitle => '小猪记账';

  @override
  String get tabHome => '明细';

  @override
  String get tabInsights => '洞察';

  @override
  String get tabAssets => '资产';

  @override
  String get tabRecord => '记账';

  @override
  String get tabMine => '我的';

  @override
  String get commonCancel => '取消';

  @override
  String get conflictUploadTitle => '检测到同步冲突';

  @override
  String get conflictUploadCloudNewerMessage =>
      '云端快照比本地更新（可能另一台设备刚同步过）。继续上传会覆盖云端数据，且云端版本将丢失。确定要覆盖上传吗？';

  @override
  String get conflictUploadUnknownMessage =>
      '无法判定本地与云端哪个更新（内容不同但时间相同）。继续上传会覆盖云端数据。确定要覆盖上传吗？';

  @override
  String get conflictForceUploadAction => '覆盖上传';

  @override
  String get conflictCompareMergeAction => '对比合并';

  @override
  String get cloudConfigCorruptWarning => '云端配置读取失败，自动同步已暂停。请重新配置云服务。';

  @override
  String get cloudMigrationWarning =>
      '云凭据安全迁移失败，凭据暂以明文形式留在本机。建议重新保存云配置以完成安全迁移。';

  @override
  String get commonConfirm => '确定';

  @override
  String get commonSave => '保存';

  @override
  String get commonDelete => '删除';

  @override
  String get commonAdd => '添加';

  @override
  String get commonEdit => '编辑';

  @override
  String get commonMore => '更多';

  @override
  String get commonOk => '确定';

  @override
  String get commonKnow => '知道了';

  @override
  String get commonEmpty => '暂无数据';

  @override
  String get commonError => '错误';

  @override
  String get startupSyncCheckTitle => '云端有更新';

  @override
  String startupSyncCheckSummaryMessage(int count) {
    return '检测到 $count 个账本有云端更新，是否合并到本地？';
  }

  @override
  String startupSyncCheckLedgerMessage(
      String ledger, int added, int modified, int deleted) {
    return '账本「$ledger」检测到云端有 $added 条新增、$modified 条修改、$deleted 条删除，是否合并到本地？';
  }

  @override
  String get startupSyncCheckApplyAll => '一键应用全部';

  @override
  String get startupSyncCheckConfirmEach => '逐个确认';

  @override
  String get startupSyncCheckViewDetail => '查看详情并应用';

  @override
  String get startupSyncCheckSkip => '暂不合并';

  @override
  String get startupSyncCheckSkipRest => '跳过剩余';

  @override
  String get startupSyncCheckCancelHint => '可稍后在「我的-云同步」手动检查';

  @override
  String get startupSyncCheckCheckingTitle => '正在检查云端更新';

  @override
  String get startupSyncCheckCheckingHint => '请稍候...';

  @override
  String startupSyncCheckCheckingProgress(int checked, int total) {
    return '正在检查 $checked/$total';
  }

  @override
  String get startupSyncCheckApplyingTitle => '正在合并云端数据';

  @override
  String startupSyncCheckApplyingProgress(int applied, int total) {
    return '正在合并 $applied/$total';
  }

  @override
  String get startupSyncCheckUpToDate => '所有账本都是最新的';

  @override
  String get startupSyncConflictTooltip => '本地有改动将被云端覆盖';

  @override
  String get startupSyncConflictConfirmTitle => '覆盖确认';

  @override
  String startupSyncConflictConfirmMessage(int count, String names) {
    return '将用云端覆盖 $count 个账本的本地改动（$names），是否继续？';
  }

  @override
  String get startupSyncConflictConfirmOk => '覆盖本地';

  @override
  String get startupSyncConflictConfirmCancel => '取消';

  @override
  String startupSyncConflictAndMore(int count) {
    return '等 $count 个';
  }

  @override
  String get startupSyncNewLedgersTitle => '发现云端账本';

  @override
  String startupSyncNewLedgersMessage(int count, String names) {
    return '云端发现 $count 个本机没有的账本：$names。是否下载到本机？';
  }

  @override
  String get startupSyncNewLedgersOk => '下载';

  @override
  String get startupSyncNewLedgersCancel => '跳过';

  @override
  String startupSyncNewLedgersBackend(String backend) {
    return '当前后端：$backend';
  }

  @override
  String startupSyncDuplicateSlots(Object detail) {
    return '注意：以下名称在云端存在多个槽位，全部下载会产生重复账本（可稍后在 账本管理-云端账本 按 ID 甄别下载）：$detail';
  }

  @override
  String get commonSuccess => '成功';

  @override
  String get commonFailed => '失败';

  @override
  String get commonBack => '返回';

  @override
  String get commonNext => '下一步';

  @override
  String get fabActionCamera => '拍照';

  @override
  String get fabActionGallery => '相册';

  @override
  String get fabActionVoice => '语音';

  @override
  String get fabActionVoiceDisabled => '需要启用AI并配置API Key';

  @override
  String get voiceRecordingTitle => '语音记账';

  @override
  String get voiceRecordingPreparing => '准备录音...';

  @override
  String get voiceRecordingInProgress => '正在录音...';

  @override
  String get voiceRecordingProcessing => '正在识别...';

  @override
  String voiceRecordingDuration(int duration) {
    return '录音时长: $duration秒';
  }

  @override
  String get voiceRecordingSuccess => '语音记账成功';

  @override
  String get voiceRecordingNoLedger => '未找到当前账本';

  @override
  String get voiceRecordingNoInfo => '未识别到记账信息';

  @override
  String get voiceRecordingPermissionDenied => '需要麦克风权限才能录音';

  @override
  String get voiceRecordingPermissionDeniedTitle => '需要麦克风权限';

  @override
  String get voiceRecordingPermissionDeniedMessage =>
      '语音记账功能需要使用麦克风权限。请在系统设置中允许小猪记账访问麦克风。';

  @override
  String voiceRecordingStartFailed(String error) {
    return '启动录音失败: $error';
  }

  @override
  String voiceRecordingFailed(String error) {
    return '录音失败: $error';
  }

  @override
  String voiceRecordingRecognizeFailed(String error) {
    return '识别失败: $error';
  }

  @override
  String voiceRecordingNoInfoDetected(String text) {
    return '未能识别账单信息: $text';
  }

  @override
  String get voiceRecordingNoSpeech => '未检测到语音输入';

  @override
  String get voiceRecordingHoldToTalk => '按住 说话';

  @override
  String get voiceRecordingReleaseToFinish => '松手结束录音';

  @override
  String get voiceRecordingTooShort => '录音时间过短';

  @override
  String get voiceRecordingResultLabel => '识别结果：';

  @override
  String get voiceRecordingAutoHintSpoken => '说完后停顿即可自动识别';

  @override
  String get voiceRecordingAutoHintWaiting => '请开始说话...';

  @override
  String get smartBillingVoiceTrigger => '语音触发方式';

  @override
  String get voiceTriggerModeAuto => '自动检测停顿';

  @override
  String get voiceTriggerModeAutoDesc => '录音后自动判断说完，适合短句快速记账';

  @override
  String get voiceTriggerModeHold => '按住说话';

  @override
  String get voiceTriggerModeHoldDesc => '长按录音、松开结束，适合一次说较多内容';

  @override
  String get smartBillingVoiceSilenceTimeout => '停顿结束时长';

  @override
  String smartBillingVoiceSilenceTimeoutValue(String seconds) {
    return '停顿 $seconds 秒后自动结束识别';
  }

  @override
  String get commonPrevious => '上一步';

  @override
  String get commonFinish => '完成';

  @override
  String get commonClose => '关闭';

  @override
  String get commonOther => '其他';

  @override
  String get commonYesterday => '昨天';

  @override
  String get commonSearch => '搜索';

  @override
  String get commonNoteHint => '备注…';

  @override
  String get commonSettings => '设置';

  @override
  String get commonGoSettings => '前往设置';

  @override
  String get commonLanguage => '语言';

  @override
  String get commonCurrent => '当前';

  @override
  String get commonTutorial => '教程';

  @override
  String get commonConfigure => '配置';

  @override
  String get commonPressAgainToExit => '再按一次退出应用';

  @override
  String get commonWeekdayMonday => '星期一';

  @override
  String get commonWeekdayTuesday => '星期二';

  @override
  String get commonWeekdayWednesday => '星期三';

  @override
  String get commonWeekdayThursday => '星期四';

  @override
  String get commonWeekdayFriday => '星期五';

  @override
  String get commonWeekdaySaturday => '星期六';

  @override
  String get commonWeekdaySunday => '星期日';

  @override
  String get homeIncome => '收入';

  @override
  String get homeExpense => '支出';

  @override
  String get homeBalance => '结余';

  @override
  String get homeMonthIncome => '本月收入';

  @override
  String get homeMonthExpense => '本月支出';

  @override
  String homeBudgetSet(String amount) {
    return '预算 $amount';
  }

  @override
  String get homeNoRecords => '还没有记账';

  @override
  String get homeSelectDate => '选择日期';

  @override
  String get homeAppTitle => '小猪记账';

  @override
  String get homeSearch => '搜索';

  @override
  String homeYear(int year) {
    return '$year年';
  }

  @override
  String homeMonth(String month) {
    return '$month月';
  }

  @override
  String get homeNoRecordsSubtext => '点击底部加号，马上记一笔';

  @override
  String get homeLastMonthReportSubtitle => '查看上月消费报告并分享';

  @override
  String get homeLastMonthReportView => '查看';

  @override
  String homeAnnualReportReminder(int year) {
    return '$year年度账单已生成，回顾你的财务足迹';
  }

  @override
  String get homeAnnualReportView => '查看';

  @override
  String get widgetTodayExpense => '今日支出';

  @override
  String get widgetTodayIncome => '今日收入';

  @override
  String get widgetMonthExpense => '本月支出';

  @override
  String get widgetMonthIncome => '本月收入';

  @override
  String get widgetMonthSuffix => '月';

  @override
  String get widgetToday => '今日';

  @override
  String get widgetQuickAddLabel => '记一笔';

  @override
  String get widgetBudgetTotal => '总额';

  @override
  String get widgetBudgetRemaining => '剩';

  @override
  String get widgetNoBudget => '未设预算';

  @override
  String get widgetNoTransactions => '暂无交易';

  @override
  String get widgetRecentTransactions => '最近交易';

  @override
  String get widgetNoAccounts => '暂无账户';

  @override
  String get searchTitle => '搜索';

  @override
  String get searchHint => '搜索备注、分类或金额...';

  @override
  String get searchCategoryHint => '搜索分类名称...';

  @override
  String get searchCategoryFilter => '分类筛选';

  @override
  String get searchMinAmount => '最小金额';

  @override
  String get searchMaxAmount => '最大金额';

  @override
  String get searchNoInput => '输入关键词开始搜索';

  @override
  String get searchNoResults => '未找到匹配的结果';

  @override
  String get searchBatchMode => '批量操作';

  @override
  String searchBatchModeWithCount(int selected, int total) {
    return '批量操作 ($selected/$total)';
  }

  @override
  String get searchExitBatchMode => '退出批量操作';

  @override
  String get searchSelectAll => '全选';

  @override
  String get searchDeselectAll => '取消全选';

  @override
  String searchSelectedCount(int count) {
    return '已选择 $count 项';
  }

  @override
  String get searchBatchSetNote => '设置备注';

  @override
  String get searchBatchChangeCategory => '调整分类';

  @override
  String get searchBatchDeleteConfirmTitle => '确认删除';

  @override
  String searchBatchDeleteConfirmMessage(int count) {
    return '确定要删除选中的 $count 笔记账吗?\n删除后可在回收站找回。';
  }

  @override
  String get searchBatchDeleteReconfirmMessage => '再次确认：这些记账将移入回收站。确定要继续吗？';

  @override
  String get searchBatchSetNoteTitle => '批量设置备注';

  @override
  String searchBatchSetNoteMessage(int count) {
    return '将为选中的 $count 笔记账设置相同的备注';
  }

  @override
  String get searchBatchSetNoteHint => '输入备注内容 (留空则清空备注)';

  @override
  String searchBatchDeleteSuccess(int count) {
    return '已将 $count 笔记账移入回收站';
  }

  @override
  String searchBatchDeleteFailed(String error) {
    return '删除失败: $error';
  }

  @override
  String searchBatchSetNoteSuccess(int count) {
    return '成功为 $count 笔记账设置备注';
  }

  @override
  String searchBatchSetNoteFailed(String error) {
    return '设置备注失败: $error';
  }

  @override
  String searchBatchChangeCategorySuccess(int count) {
    return '成功为 $count 笔记账调整分类';
  }

  @override
  String searchBatchChangeCategoryFailed(String error) {
    return '调整分类失败: $error';
  }

  @override
  String searchResultsCount(int count) {
    return '共 $count 条结果';
  }

  @override
  String get searchSummaryIncome => '收入';

  @override
  String get searchSummaryExpense => '支出';

  @override
  String get searchFilterTitle => '筛选';

  @override
  String get searchAmountFilter => '金额筛选';

  @override
  String get searchDateFilter => '时间筛选';

  @override
  String get searchStartDate => '开始日期';

  @override
  String get searchEndDate => '结束日期';

  @override
  String get searchNotSet => '未设置';

  @override
  String get searchClearFilter => '清空筛选';

  @override
  String get searchBatchCategoryTransferError => '选中的交易包含转账，无法修改分类';

  @override
  String get searchBatchCategoryTypeError => '选中的交易类型不一致，请选择全部为收入或全部为支出的交易';

  @override
  String get searchDateStart => '开始';

  @override
  String get searchDateEnd => '结束';

  @override
  String get analyticsWeek => '周';

  @override
  String get analyticsMonth => '月';

  @override
  String analyticsWeekTotal(Object type) {
    return '本周$type： ';
  }

  @override
  String get analyticsComparedToLastWeek => '比上周';

  @override
  String get analyticsThisWeek => '本周';

  @override
  String get analyticsThisMonth => '本月';

  @override
  String get analyticsThisYear => '今年';

  @override
  String analyticsTrendTitle(Object period) {
    return '$period趋势';
  }

  @override
  String analyticsCategoryComposition(Object type) {
    return '$type分类构成';
  }

  @override
  String analyticsTxCountShort(Object count) {
    return '$count笔';
  }

  @override
  String get analyticsYear => '年';

  @override
  String get analyticsAll => '全部';

  @override
  String get analyticsTotalAmount => '总计';

  @override
  String get analyticsNoDataSubtext => '可左右滑动切换周期，或点击按钮切换收入/支出';

  @override
  String get analyticsSwipeHint => '左右滑动切换周期';

  @override
  String analyticsSwitchTo(String type) {
    return '切换到$type';
  }

  @override
  String get analyticsAllYears => '全部年份';

  @override
  String get splashAppName => '小猪记账';

  @override
  String get splashSlogan => '小猪记账，越来越棒';

  @override
  String get splashSecurityTitle => '开源数据安全';

  @override
  String get splashSecurityFeature1 => '• 数据本地存储，隐私完全自控';

  @override
  String get splashSecurityFeature2 => '• 开源代码透明，安全值得信赖';

  @override
  String get splashSecurityFeature3 => '• 可选云端同步，多设备数据一致';

  @override
  String get splashInitializing => '正在初始化数据...';

  @override
  String get ledgersTitle => '账本管理';

  @override
  String get ledgersNew => '新建账本';

  @override
  String get ledgersClear => '清空账本';

  @override
  String ledgersClearMessage(String name) {
    return '确定要清空账本\"$name\"的所有账单吗？此操作不可恢复。\\n账本本身会保留，仅删除账单数据。';
  }

  @override
  String get ledgersClearReconfirmMessage =>
      '再次确认：清空后账本内的账单数据将永久删除、无法恢复。确定要继续吗？';

  @override
  String get ledgerDefaultName => '默认账本';

  @override
  String get ledgersEdit => '编辑账本';

  @override
  String get ledgersDelete => '删除账本';

  @override
  String get ledgersDeleteConfirm => '删除账本';

  @override
  String get ledgersDeleteMessage =>
      '确定要删除该账本及其全部记录吗？此操作不可恢复。\n若云端存在备份，也会一并删除。';

  @override
  String get ledgersDeleteReconfirmMessage =>
      '再次确认：删除后该账本及其全部记录将永久消失（含云端备份），无法恢复。确定要继续吗？';

  @override
  String get ledgersDeleted => '已删除';

  @override
  String get ledgersDeleteFailed => '删除失败';

  @override
  String get ledgersClearTitle => '清空账本';

  @override
  String get ledgersClearSuccess => '账本已清空';

  @override
  String get ledgersDeleteLocal => '仅删除本地账本';

  @override
  String get ledgersDeleteLocalTitle => '删除本地账本';

  @override
  String ledgersDeleteLocalMessage(String name) {
    return '确定要删除本地账本\"$name\"吗？\n云端备份会保留，您可以随时恢复。';
  }

  @override
  String get ledgersDeleteLocalReconfirmMessage =>
      '再次确认：仅删除本机上的该账本，云端备份保留、可随时恢复下载。确定要继续吗？';

  @override
  String get ledgersDeleteLocalSuccess => '本地账本已删除';

  @override
  String get ledgersName => '名称';

  @override
  String get ledgersDefaultLedgerName => '默认账本';

  @override
  String get ledgersCurrency => '币种';

  @override
  String get ledgersMonthStartDay => '每月起始日';

  @override
  String get ledgersMonthStartDayHint => '统计与预算按该日作为每月周期起点（1-28）';

  @override
  String get ledgersMonthStartDayNatural => '1日（自然月）';

  @override
  String ledgersMonthStartDayValue(int day) {
    return '每月$day日';
  }

  @override
  String get ledgersSelectCurrency => '选择币种';

  @override
  String get ledgersSearchCurrency => '搜索：中文或代码';

  @override
  String get ledgersCreate => '创建';

  @override
  String get ledgersActions => '操作';

  @override
  String ledgersRecords(String count) {
    return '笔数：$count';
  }

  @override
  String ledgersBalance(String balance) {
    return '余额：$balance';
  }

  @override
  String get ledgerCardDownloadCloud => '下载云账本';

  @override
  String get ledgerCardCloudUploaded => '云端上传时间';

  @override
  String ledgersRestoreAllDuplicateSlots(String detail) {
    return '注意：以下名称在云端存在多个槽位，全部恢复会依次相互覆盖，本地最终只保留其中一个（如需逐个甄别，可先在上方卡片按 ID 与上传时间选择下载）：$detail';
  }

  @override
  String get ledgersLocal => '本地账本';

  @override
  String get ledgersRemote => '云端账本';

  @override
  String get ledgersEmpty => '暂无账本';

  @override
  String get ledgersRestoreAll => '全部恢复';

  @override
  String ledgersSwitched(String name) {
    return '已切换到账本\"$name\"';
  }

  @override
  String get ledgersDownloadTitle => '下载账本';

  @override
  String ledgersDownloadMessage(String name) {
    return '确认下载账本\"$name\"到本地？本地同名账本的数据将被云端数据覆盖。';
  }

  @override
  String ledgersDownloadSuccess(String name) {
    return '账本\"$name\"下载成功';
  }

  @override
  String get ledgersDownload => '下载';

  @override
  String get ledgersDeleteRemote => '删除云端账本';

  @override
  String get ledgersDeleteRemoteConfirm => '删除云端账本';

  @override
  String ledgersDeleteRemoteMessage(String name) {
    return '确认删除云端账本\"$name\"？此操作不可恢复。';
  }

  @override
  String get ledgersDeleteRemoteReconfirmMessage =>
      '再次确认：删除后云端该账本及其全部数据将永久消失，多设备将无法再恢复它。确定要继续吗？';

  @override
  String get ledgersDeleting => '删除中...';

  @override
  String get ledgersDeleteRemoteSuccess => '已删除云端账本';

  @override
  String get ledgersRestoreAllTitle => '批量恢复';

  @override
  String ledgersRestoreAllMessage(int count) {
    return '确认恢复所有云端账本？共 $count 个。';
  }

  @override
  String get ledgersRestoreAllReconfirmMessage =>
      '再次确认：恢复将用云端内容覆盖本地账本数据，被覆盖的本地改动无法找回。确定要继续吗？';

  @override
  String get ledgersRestoreComplete => '恢复完成';

  @override
  String ledgersRestoreResult(int success, int failed) {
    return '成功: $success，失败: $failed';
  }

  @override
  String get ledgersUploadAll => '全部上传';

  @override
  String ledgersUploadAllMessage(int count) {
    return '确认将 $count 个本地账本上传到云端？云端现有内容将被本地内容覆盖。';
  }

  @override
  String get ledgersUploadAllReconfirmMessage => '再次确认：覆盖后云端原有数据无法恢复，确定要继续吗？';

  @override
  String get ledgersUploadAllComplete => '上传完成';

  @override
  String ledgersUploadAllResult(int success, int failed) {
    return '成功: $success，失败: $failed';
  }

  @override
  String ledgersUploadAllConflictSkipped(int success, int conflicts) {
    return '已上传 $success 个账本；$conflicts 个账本因云端更新被跳过，请核对后逐个上传。';
  }

  @override
  String ledgersUploadingProgress(int done, int total) {
    return '正在上传账本 $done/$total，请勿操作…';
  }

  @override
  String get ledgersUploadThis => '上传到云端';

  @override
  String get categoryTitle => '分类管理';

  @override
  String get categoryNew => '新建分类';

  @override
  String get categoryExpense => '支出';

  @override
  String get categoryIncome => '收入';

  @override
  String get categoryEmpty => '暂无分类';

  @override
  String get categoryReorderTip => '长按分类可拖拽调整顺序';

  @override
  String categoryLoadFailed(String error) {
    return '加载失败: $error';
  }

  @override
  String get iconPickerTitle => '选择图标';

  @override
  String get iconCategoryTransport => '交通';

  @override
  String get iconCategoryShopping => '购物';

  @override
  String get iconCategoryEntertainment => '娱乐';

  @override
  String get iconCategoryLife => '生活';

  @override
  String get iconCategoryHealth => '健康';

  @override
  String get iconCategoryEducation => '学习';

  @override
  String get iconCategoryWork => '工作';

  @override
  String get iconCategoryFinance => '理财';

  @override
  String get iconCategoryReward => '奖励';

  @override
  String get iconCategoryOther => '其他';

  @override
  String get iconCategoryDining => '餐饮';

  @override
  String get iconLabelRestaurant => '餐厅';

  @override
  String get iconLabelLocalDining => '用餐';

  @override
  String get iconLabelFastfood => '快餐';

  @override
  String get iconLabelLocalCafe => '咖啡';

  @override
  String get iconLabelLocalBar => '酒吧';

  @override
  String get iconLabelCake => '蛋糕';

  @override
  String get iconLabelLocalPizza => '披萨';

  @override
  String get iconLabelIcecream => '冰淇淋';

  @override
  String get iconLabelDirectionsCar => '汽车';

  @override
  String get iconLabelDirectionsBus => '公交';

  @override
  String get iconLabelDirectionsSubway => '地铁';

  @override
  String get iconLabelLocalTaxi => '出租车';

  @override
  String get iconLabelFlight => '飞机';

  @override
  String get iconLabelTrain => '火车';

  @override
  String get iconLabelDirectionsBike => '自行车';

  @override
  String get iconLabelDirectionsWalk => '步行';

  @override
  String get iconLabelLocalGasStation => '加油';

  @override
  String get iconLabelLocalParking => '停车';

  @override
  String get iconLabelShoppingCart => '购物车';

  @override
  String get iconLabelShoppingBag => '购物袋';

  @override
  String get iconLabelStore => '商店';

  @override
  String get iconLabelLocalMall => '商场';

  @override
  String get iconLabelLocalGroceryStore => '超市';

  @override
  String get iconLabelCheckroom => '服装';

  @override
  String get iconLabelWatch => '手表';

  @override
  String get iconLabelDiamond => '珠宝';

  @override
  String get iconLabelMovie => '电影';

  @override
  String get iconLabelMusicNote => '音乐';

  @override
  String get iconLabelSportsEsports => '游戏';

  @override
  String get iconLabelSportsSoccer => '足球';

  @override
  String get iconLabelSportsBasketball => '篮球';

  @override
  String get iconLabelTheaterComedy => '娱乐';

  @override
  String get iconLabelCameraAlt => '摄影';

  @override
  String get iconLabelPalette => '艺术';

  @override
  String get iconLabelHome => '居家';

  @override
  String get iconLabelLocalLaundryService => '洗衣';

  @override
  String get iconLabelCleaningServices => '清洁';

  @override
  String get iconLabelPlumbing => '维修';

  @override
  String get iconLabelElectricalServices => '电工';

  @override
  String get iconLabelHandyman => '维护';

  @override
  String get iconLabelPets => '宠物';

  @override
  String get iconLabelChildCare => '母婴';

  @override
  String get iconLabelLocalHospital => '医院';

  @override
  String get iconLabelMedicalServices => '医疗';

  @override
  String get iconLabelLocalPharmacy => '药店';

  @override
  String get iconLabelFitnessCenter => '健身';

  @override
  String get iconLabelSpa => '美容';

  @override
  String get iconLabelPsychology => '心理';

  @override
  String get iconLabelFace => '护肤';

  @override
  String get iconLabelContentCut => '理发';

  @override
  String get iconLabelSchool => '学校';

  @override
  String get iconLabelLibraryBooks => '书籍';

  @override
  String get iconLabelComputer => '电脑';

  @override
  String get iconLabelPhone => '通讯';

  @override
  String get iconLabelLanguage => '语言';

  @override
  String get iconLabelScience => '科学';

  @override
  String get iconLabelCalculate => '计算';

  @override
  String get iconLabelBrush => '绘画';

  @override
  String get iconLabelBusiness => '商务';

  @override
  String get iconLabelWork => '工作';

  @override
  String get iconLabelFlashOn => '水电';

  @override
  String get iconLabelWifi => '网络';

  @override
  String get iconLabelPhoneAndroid => '手机';

  @override
  String get iconLabelSmokingRooms => '烟酒';

  @override
  String get iconLabelFavorite => '捐赠';

  @override
  String get iconLabelCategory => '其他';

  @override
  String get iconLabelSalary => '工资';

  @override
  String get iconLabelBusinessCenter => '商务';

  @override
  String get iconLabelEngineering => '技术';

  @override
  String get iconLabelDesignServices => '设计';

  @override
  String get iconLabelAgriculture => '农业';

  @override
  String get iconLabelConstruction => '建筑';

  @override
  String get iconLabelLocalShipping => '物流';

  @override
  String get iconLabelRestaurantMenu => '餐饮';

  @override
  String get iconLabelAccountBalance => '银行';

  @override
  String get iconLabelSavings => '储蓄';

  @override
  String get iconLabelTrendingUp => '投资';

  @override
  String get iconLabelPaid => '利息';

  @override
  String get iconLabelCurrencyExchange => '汇率';

  @override
  String get iconLabelWallet => '钱包';

  @override
  String get iconLabelCreditCard => '信用卡';

  @override
  String get iconLabelAccountBalanceWallet => '余额';

  @override
  String get iconLabelCardGiftcard => '红包';

  @override
  String get iconLabelRedeem => '奖金';

  @override
  String get iconLabelEmojiEvents => '奖励';

  @override
  String get iconLabelStar => '评级';

  @override
  String get iconLabelGrade => '等级';

  @override
  String get iconLabelLoyalty => '积分';

  @override
  String get iconLabelVolunteerActivism => '礼金';

  @override
  String get iconLabelCelebration => '庆祝';

  @override
  String get iconLabelReceiptLong => '报销';

  @override
  String get iconLabelPartTime => '兼职';

  @override
  String get iconLabelUndo => '退款';

  @override
  String get iconLabelMoney => '现金';

  @override
  String get iconLabelApartment => '租金';

  @override
  String get iconLabelHandshake => '合作';

  @override
  String get iconLabelHelp => '未分类';

  @override
  String get tooltipSend => '发送';

  @override
  String get tooltipShare => '分享';

  @override
  String get tooltipPaste => '粘贴';

  @override
  String get tooltipTogglePassword => '显示或隐藏密码';

  @override
  String get tooltipToggleVisibility => '显示或隐藏';

  @override
  String get tooltipAddAttachment => '添加附件';

  @override
  String get tooltipClear => '清除';

  @override
  String get tooltipPreview => '预览';

  @override
  String get tooltipRefresh => '刷新';

  @override
  String get importTitle => '导入账单';

  @override
  String get importBillType => '账单类型';

  @override
  String get importBillTypeGeneric => '通用CSV';

  @override
  String get importBillTypeAlipay => '支付宝';

  @override
  String get importBillTypeWechat => '微信';

  @override
  String get importChooseFile => '选择文件';

  @override
  String get importNoFileSelected => '未选择文件';

  @override
  String get importHint => '提示：请选择一个文件开始导入（支持 CSV/TSV/XLSX）';

  @override
  String get importReading => '读取文件中…';

  @override
  String get importPreparing => '准备中…';

  @override
  String importColumnNumber(Object number) {
    return '第 $number 列';
  }

  @override
  String get importConfirmMapping => '确认映射';

  @override
  String get importCategoryMapping => '分类映射';

  @override
  String get importNoDataParsed => '未解析到任何数据，请返回上一页检查 CSV 内容或分隔符。';

  @override
  String get importFieldDate => '日期';

  @override
  String get importFieldType => '类型';

  @override
  String get importFieldAmount => '金额';

  @override
  String get importFieldCategory => '分类';

  @override
  String get importFieldAccount => '账户';

  @override
  String get importFieldNote => '备注';

  @override
  String get importPreview => '预览：';

  @override
  String importPreviewLimit(Object shown, Object total) {
    return '仅预览前 $shown 行，共 $total 行';
  }

  @override
  String get importCategoryNotSelected =>
      '未选择\"分类\"列，请点击\"上一步\"返回并设置\"分类\"的列，再继续。';

  @override
  String get importCategoryMappingDescription =>
      '请将左侧\"源分类名\"映射到系统内已有分类（或保持原名自动创建/合并）';

  @override
  String get importKeepOriginalName => '保持原名（自动创建/合并）';

  @override
  String importProgress(Object fail, Object ok) {
    return '导入中… 成功 $ok，失败 $fail';
  }

  @override
  String get importCancelImport => '取消导入';

  @override
  String get importCompleteTitle => '导入完成';

  @override
  String get importSelectCategoryFirst => '请先选择\"分类\"列再继续';

  @override
  String get importNextStep => '下一步';

  @override
  String get importPreviousStep => '上一步';

  @override
  String get importStartImport => '开始导入';

  @override
  String get importAutoDetect => '自动';

  @override
  String get importInProgress => '正在导入…';

  @override
  String importProgressDetail(
      Object done, Object fail, Object ok, Object total) {
    return '已完成：$done/$total，成功 $ok，失败 $fail';
  }

  @override
  String get importBackgroundImport => '后台导入';

  @override
  String get importCancelled => '（已取消）';

  @override
  String importCompleted(Object cancelled, Object fail, Object ok) {
    return '导入完成$cancelled：成功 $ok 条，失败 $fail 条';
  }

  @override
  String importSkippedNonTransactionTypes(Object count) {
    return '跳过 $count 条非收支记录（债务等）';
  }

  @override
  String importTransactionFailed(Object error) {
    return '导入失败，已回滚所有更改：$error';
  }

  @override
  String importFileOpenError(String error) {
    return '无法打开文件选择器：$error';
  }

  @override
  String get mineCloudBackupSection => '云同步与备份';

  @override
  String get mineFunctionSection => '功能管理';

  @override
  String get mineHelpSection => '帮助与信息';

  @override
  String get mineSupportSection => '支持我们';

  @override
  String get mineImport => '导入数据';

  @override
  String get mineExport => '导出数据';

  @override
  String get mineLanguageSettings => '语言';

  @override
  String get languageTitle => '语言设置';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSystemDefault => '跟随系统';

  @override
  String get deleteConfirmTitle => '删除确认';

  @override
  String get deleteConfirmMessage => '确定要删除这条记账吗？\n删除后可在回收站找回。';

  @override
  String get mineSlogan => '小猪记账，越来越棒';

  @override
  String get mineDisplayNameEditTitle => '设置昵称';

  @override
  String get mineDisplayNameHint => '输入昵称';

  @override
  String get mineDisplayNameSaved => '昵称已更新';

  @override
  String get mineGreetingMorning => '早上好';

  @override
  String get mineGreetingNoon => '中午好';

  @override
  String get mineGreetingAfternoon => '下午好';

  @override
  String get mineGreetingEvening => '晚上好';

  @override
  String get mineGreetingNight => '夜深了';

  @override
  String mineGreetingNamed(String greeting, String name) {
    return '$greeting，$name';
  }

  @override
  String get mineProfileEditTitle => '编辑资料';

  @override
  String get headerSkinTitle => '皮肤';

  @override
  String get headerSkinNone => '纯色';

  @override
  String get headerSkinAurora => '极光';

  @override
  String get headerSkinMountains => '山峦';

  @override
  String get headerSkinBokeh => '光斑';

  @override
  String get headerSkinWaves => '波浪';

  @override
  String get headerSkinSunset => '日落';

  @override
  String get headerSkinClouds => '云朵';

  @override
  String get headerSkinExample => '示例';

  @override
  String get headerSkinHoneycomb => '蜂巢';

  @override
  String get headerSkinStarry => '星河';

  @override
  String get headerSkinStripes => '斜纹';

  @override
  String get headerSkinSkyline => '城市';

  @override
  String get headerSkinSakura => '樱花';

  @override
  String get headerSkinMeteor => '流星';

  @override
  String get headerSkinMemphis => '孟菲斯';

  @override
  String get headerSkinSilk => '丝带';

  @override
  String get headerSkinBubbles => '气泡';

  @override
  String get headerSkinGalaxy => '星系';

  @override
  String get headerSkinLowPoly => '低多边形';

  @override
  String get headerSkinPrism => '棱镜';

  @override
  String get headerSkinTerrazzo => '水磨石';

  @override
  String get mineAvatarFromGallery => '从相册选择';

  @override
  String get mineAvatarFromCamera => '拍照';

  @override
  String get mineAvatarDelete => '删除头像';

  @override
  String get annualReportTitle => '年度账单';

  @override
  String annualReportSubtitle(int year) {
    return '回顾你的$year年财务足迹';
  }

  @override
  String get annualReportEntrySubtitle => '生成专属年度报告，分享你的记账故事';

  @override
  String annualReportNoData(int year) {
    return '暂无$year年数据';
  }

  @override
  String get annualReportPage1Title => '年度总览';

  @override
  String annualReportPage1Subtitle(int year) {
    return '$year年记账之旅';
  }

  @override
  String get annualReportTotalDays => '记账天数';

  @override
  String get annualReportTotalRecords => '记账笔数';

  @override
  String get annualReportTotalIncome => '总收入';

  @override
  String get annualReportTotalExpense => '总支出';

  @override
  String get annualReportNetSavings => '年度结余';

  @override
  String get annualReportPage2Title => '支出分析';

  @override
  String get annualReportPage2Subtitle => '你的钱花在哪了';

  @override
  String get annualReportPage3Title => '月度趋势';

  @override
  String get annualReportPage3Subtitle => '12个月的收支变化';

  @override
  String get annualReportHighestMonth => '支出最高月份';

  @override
  String get annualReportLowestMonth => '支出最低月份';

  @override
  String get annualReportPage4Title => '特别时刻';

  @override
  String get annualReportPage4Subtitle => '那些值得铭记的账单';

  @override
  String get annualReportLargestExpense => '年度最大支出';

  @override
  String get annualReportLargestIncome => '年度最大收入';

  @override
  String get annualReportFirstRecord => '第一笔记录';

  @override
  String get annualReportPage5Title => '年度成就';

  @override
  String get annualReportPage5Subtitle => '你的记账成就徽章';

  @override
  String get annualReportAchievementConsistent => '持之以恒';

  @override
  String annualReportAchievementConsistentDesc(int days) {
    return '连续记账超过$days天';
  }

  @override
  String get annualReportAchievementSaver => '精打细算';

  @override
  String get annualReportAchievementSaverDesc => '年度结余为正';

  @override
  String get annualReportAchievementDetail => '明察秋毫';

  @override
  String annualReportAchievementDetailDesc(int count) {
    return '记账笔数超过$count笔';
  }

  @override
  String get annualReportShareButton => '生成分享海报';

  @override
  String get annualReportGenerating => '正在生成年度报告...';

  @override
  String get annualReportSaveSuccess => '年度报告海报已保存';

  @override
  String get mineShareApp => '分享应用';

  @override
  String get mineShareWithFriends => '和好友分享小猪记账';

  @override
  String get mineCopyPromoText => '复制推广文案';

  @override
  String get mineCopyPromoSubtitle => '一键复制分享给好友';

  @override
  String get mineShareGenerating => '正在生成分享海报...';

  @override
  String get sharePosterAppName => '小猪记账';

  @override
  String get sharePosterSlogan => '一笔一蜜，记录美好生活';

  @override
  String get sharePosterFeature1 => '数据安全·你做主';

  @override
  String get sharePosterFeature2 => '完全开源·可审计';

  @override
  String get sharePosterFeature3 => 'AI智能记账·图片语音';

  @override
  String get sharePosterFeature4 => '拍照记账·自动识别';

  @override
  String get sharePosterFeature5 => '多账本·暗黑模式';

  @override
  String get sharePosterFeature6 => '自建云同步·永久免费';

  @override
  String get sharePosterScanText => '扫码访问开源项目';

  @override
  String get appPromoTagOpenSource => '开源';

  @override
  String get appPromoTagFree => '免费';

  @override
  String get appPromoFooterText => '让每一笔都有迹可循';

  @override
  String userProfileJourneyYears(int years) {
    return '记账达人 $years 年';
  }

  @override
  String get userProfileJourneyOneYear => '记账满一年';

  @override
  String get userProfileJourneyHalfYear => '坚持记账半年';

  @override
  String get userProfileJourneyThreeMonths => '记账三个月';

  @override
  String get userProfileJourneyOneMonth => '记账满一个月';

  @override
  String get userProfileJourneyOneWeek => '记账一周';

  @override
  String get userProfileJourneyStart => '开始记账之旅';

  @override
  String get userProfileDailyAverage => '日均记账';

  @override
  String get sharePosterSave => '保存到相册';

  @override
  String get sharePosterShare => '分享';

  @override
  String get sharePosterHideIncome => '隐藏收入';

  @override
  String get sharePosterShowIncome => '显示收入';

  @override
  String get sharePosterSaveSuccess => '已保存到相册';

  @override
  String get shareGuidanceCopyText =>
      '用小猪记账记录生活，开源免费无广告！🐷 下载地址：https://github.com/mecoren/PiggyCount';

  @override
  String get shareGuidanceCopied => '文案已复制';

  @override
  String get sharePosterSaveFailed => '保存失败';

  @override
  String get sharePosterPermissionDenied => '相册权限被拒绝，请在设置中开启';

  @override
  String get sharePosterGenerating => '生成中...';

  @override
  String get sharePosterGenerateFailed => '生成海报失败，请重试';

  @override
  String get sharePosterNoLedger => '请先选择一个账本';

  @override
  String get sharePosterYearTitle => '我的记账年度报告';

  @override
  String get sharePosterYearSubtitle => '用数据记录生活 用理性规划未来';

  @override
  String get sharePosterMonthTitle => '月度账单报告';

  @override
  String get sharePosterMonthSubtitle => '精打细算 理性消费';

  @override
  String get sharePosterLedgerTitle => '账本统计报告';

  @override
  String get sharePosterRecordDays => '记账天数';

  @override
  String get sharePosterRecordCount => '记账笔数';

  @override
  String get sharePosterTotalExpense => '总支出';

  @override
  String get sharePosterTotalIncome => '总收入';

  @override
  String get sharePosterYearBalance => '年度结余';

  @override
  String get sharePosterYearDeficit => '年度赤字';

  @override
  String get sharePosterMonthBalance => '月度结余';

  @override
  String get sharePosterBalance => '总结余';

  @override
  String get sharePosterAvgMonthlyExpense => '月均支出';

  @override
  String get sharePosterAvgMonthlyIncome => '月均收入';

  @override
  String get sharePosterAvgDailyExpense => '日均支出';

  @override
  String get sharePosterMaxExpenseMonth => '支出最高月份';

  @override
  String get sharePosterTopExpense => 'TOP 3 支出';

  @override
  String get sharePosterCompareLastMonth => '环比上月';

  @override
  String get sharePosterIncreaseRate => '较上月增长';

  @override
  String get sharePosterDecreaseRate => '较上月减少';

  @override
  String get sharePosterSavedMoneyTitle => '恭喜！本月比上月省了';

  @override
  String get sharePosterLedgerName => '账本名称';

  @override
  String get sharePosterUnitDay => '天';

  @override
  String get sharePosterUnitCount => '笔';

  @override
  String userProfilePosterStartDate(String date) {
    return '记账始于 $date';
  }

  @override
  String get userProfilePosterRecordDays => '记账天数';

  @override
  String get userProfilePosterDaysUnit => '天';

  @override
  String get userProfilePosterRecordCount => '记账笔数';

  @override
  String get userProfilePosterCountUnit => '笔';

  @override
  String get userProfilePosterDailyUnit => '笔/天';

  @override
  String get userProfilePosterLedgerCount => '账本数量';

  @override
  String get userProfilePosterLedgerUnit => '本';

  @override
  String get mineDaysCount => '记账天数';

  @override
  String get mineTotalRecords => '总笔数';

  @override
  String get mineCurrentBalance => '账本结余';

  @override
  String get mineCloudService => '云服务';

  @override
  String get mineCloudServiceLoading => '加载中…';

  @override
  String get mineCloudServiceOffline => '默认模式 (离线)';

  @override
  String get mineCloudServiceCustom => '自定义 Supabase';

  @override
  String get mineCloudServiceWebDAV => '自定义云服务 (WebDAV)';

  @override
  String get mineSyncTitle => '同步';

  @override
  String get mineSyncChecking => '同步中…';

  @override
  String get mineSyncNotLoggedIn => '未登录';

  @override
  String get mineSyncNotConfigured => '未配置云端';

  @override
  String get mineSyncNoRemote => '云端暂无数据';

  @override
  String mineSyncInSync(Object count) {
    return '已同步 (本地$count条)';
  }

  @override
  String get mineSyncInSyncSimple => '已同步';

  @override
  String mineSyncLocalNewer(Object count) {
    return '本地有更新 (本地$count条, 建议上传)';
  }

  @override
  String get mineSyncLocalNewerSimple => '本地有更新';

  @override
  String get mineSyncCloudNewer => '云端有更新 (建议下载同步)';

  @override
  String get mineSyncCloudNewerSimple => '云端有更新';

  @override
  String get mineSyncDifferent => '本地与云端有差异，建议下载对比';

  @override
  String syncPendingCloudDeletesMark(int count) {
    return '有 $count 条云端删除待处理（默认不自动应用；以云端为准请用下方「全量下载」）';
  }

  @override
  String get syncDirectionUnknownHint =>
      '方向无法判定（两端都有本地独有改动），可在下方用「全量下载」或「全量上传」以其中一端为准';

  @override
  String get mineSyncError => '状态获取失败';

  @override
  String get mineSyncDetailTitle => '同步状态详情';

  @override
  String mineSyncLocalRecords(Object count) {
    return '本地记录数: $count';
  }

  @override
  String mineSyncCloudRecords(Object count) {
    return '云端记录数: $count';
  }

  @override
  String mineSyncCloudLatest(Object time) {
    return '云端最新记账时间: $time';
  }

  @override
  String mineSyncLocalFingerprint(Object fingerprint) {
    return '本地指纹: $fingerprint';
  }

  @override
  String mineSyncCloudFingerprint(Object fingerprint) {
    return '云端指纹: $fingerprint';
  }

  @override
  String mineSyncMessage(Object message) {
    return '说明: $message';
  }

  @override
  String get mineUploadTitle => '上传';

  @override
  String get mineUploadNeedLogin => '需登录';

  @override
  String get mineUploadNeedCloudService => '仅限云服务模式可用';

  @override
  String get mineUploadInProgress => '正在上传中…';

  @override
  String get mineUploadRefreshing => '刷新中…';

  @override
  String get mineUploadSynced => '已同步';

  @override
  String get mineUploadSuccess => '已上传';

  @override
  String get mineUploadSuccessMessage => '所有账本已同步到云端';

  @override
  String get mineUploadUnverified => '已上传但未确认收敛';

  @override
  String get mineUploadUnverifiedMessage =>
      '数据已上传到云端，但未能确认云端内容与本次写入一致（可能被其他设备并发更新）。下次同步时会自动重新比对，无需立即处理。';

  @override
  String get backupRestoreInterrupted => '检测到上次恢复未完成';

  @override
  String get backupRestoreInterruptedMessage =>
      '上次从备份恢复时进程被中断，数据可能处于半恢复状态，自动备份已暂停。重新执行一次恢复即可修复（恢复是覆盖式，重复执行安全）。';

  @override
  String get syncBlockingDownloadTitle => '下载同步';

  @override
  String get syncBlockingUploadTitle => '上传同步';

  @override
  String get syncBlockingCheckCloud => '正在检查云端账本…';

  @override
  String syncBlockingDownloadLedger(int n, int m) {
    return '正在下载账本 $n/$m…';
  }

  @override
  String get syncBlockingApplying => '正在应用变更…';

  @override
  String get fullUploadTitle => '全量上传';

  @override
  String get fullUploadSubtitle => '以本地全部账本覆盖云端';

  @override
  String get fullDownloadTitle => '全量下载';

  @override
  String get fullDownloadSubtitle => '以云端全部账本覆盖本地';

  @override
  String fullUploadConfirm1Message(int count) {
    return '将把本地 $count 个账本全量上传，云端对应的账本数据将被本地数据完全覆盖。云端独有的账本会保留。';
  }

  @override
  String get fullUploadConfirm2Message => '再次确认：覆盖后云端原有数据无法恢复，确定要继续吗？';

  @override
  String get fullDownloadConfirm1Message =>
      '云端全部账本将完全覆盖本地对应的账本，云端独有的账本会导入为新建账本。本地独有的账本会保留。';

  @override
  String get fullDownloadConfirm2Message => '再次确认：覆盖后本地原有数据无法恢复，确定要继续吗？';

  @override
  String dangerConfirmCountdown(int seconds) {
    return '确认（$seconds秒）';
  }

  @override
  String get fullUploadBlockingStatus => '正在全量上传所有本地账本…';

  @override
  String get fullDownloadBlockingStatus => '正在全量恢复所有云端账本…';

  @override
  String get fullUploadNoLedgers => '没有可上传的本地账本。';

  @override
  String get fullUploadSuccessMessage => '全量上传完成，云端已与本地数据一致。';

  @override
  String fullDownloadResult(int success, int failed) {
    return '全量下载完成：成功 $success 个，失败 $failed 个。';
  }

  @override
  String get fullSyncUnsupported => '当前云后端不支持全量覆盖同步。';

  @override
  String get ledgersRestoreBlockingStatus => '正在从云端恢复账本…';

  @override
  String get ledgersUploadOneBlockingStatus => '正在上传账本…';

  @override
  String get ledgersDownloadOneBlockingStatus => '正在下载账本…';

  @override
  String get encryptionBlockingVerifying => '正在验证云端加密数据…';

  @override
  String get encryptionBlockingReencrypt => '正在加密云端数据…';

  @override
  String get encryptionBlockingReinit => '正在初始化加密同步…';

  @override
  String get encryptionBlockingChangePassword => '正在重新加密云端数据…';

  @override
  String get encryptionBlockingReset => '正在重置加密…';

  @override
  String get mineDownloadTitle => '下载同步';

  @override
  String get mineDownloadNeedCloudService => '仅限云服务模式可用';

  @override
  String get mineDownloadComplete => '同步完成';

  @override
  String mineDownloadResult(Object inserted) {
    return '导入：$inserted 条';
  }

  @override
  String get mineLoginTitle => '登录';

  @override
  String get mineLoginSubtitle => '仅在同步时需要';

  @override
  String get mineLoggedInEmail => '已登录';

  @override
  String get mineLogoutSubtitle => '点击可退出登录';

  @override
  String get mineLogoutConfirmTitle => '退出登录';

  @override
  String get mineLogoutConfirmMessage => '确定要退出当前账号登录吗？\n退出后将无法使用云同步功能。';

  @override
  String get mineLogoutButton => '退出';

  @override
  String get mineAutoSyncTitle => '自动同步账本';

  @override
  String get mineAutoSyncSubtitle => '记账后自动上传到云端';

  @override
  String get mineAutoSyncNeedLogin => '需登录后可开启';

  @override
  String get mineImportProgressTitle => '后台导入中…';

  @override
  String mineImportProgressSubtitle(
      Object done, Object fail, Object ok, Object total) {
    return '进度：$done/$total，成功 $ok，失败 $fail';
  }

  @override
  String get mineImportCompleteTitle => '导入完成';

  @override
  String get mineCategoryManagement => '分类管理';

  @override
  String get mineCategoryManagementSubtitle => '编辑自定义分类';

  @override
  String get mineCategoryMigration => '分类迁移';

  @override
  String get mineCategoryMigrationSubtitle => '将分类数据迁移到其他分类';

  @override
  String get mineRecurringTransactions => '周期账单';

  @override
  String get mineRecurringTransactionsSubtitle => '管理周期性账单';

  @override
  String get mineReminderSettings => '记账提醒';

  @override
  String get mineReminderSettingsSubtitle => '设置每日记账提醒';

  @override
  String get mineDisplayScale => '显示缩放';

  @override
  String get mineDisplayScaleSubtitle => '调整文字和界面元素大小';

  @override
  String get mineCheckUpdate => '检测更新';

  @override
  String get helpCenterOpenInBrowser => '在浏览器中打开';

  @override
  String get helpCenterLoadFailed => '加载失败，请检查网络';

  @override
  String get helpCenterRetry => '重试';

  @override
  String get categoryEditTitle => '编辑分类';

  @override
  String get categoryNewTitle => '新建分类';

  @override
  String get categoryDetailTooltip => '分类详情';

  @override
  String get categoryMigrationTooltip => '分类迁移';

  @override
  String get categoryMigrationTitle => '分类迁移';

  @override
  String get categoryMigrationDescription => '分类迁移说明';

  @override
  String get categoryMigrationDescriptionContent =>
      '• 将指定分类的所有交易记录迁移到另一个分类\n• 迁移后，原分类的交易数据将全部转移到目标分类\n• 此操作不可撤销，请谨慎选择';

  @override
  String get categoryMigrationTypeLabel => '选择类型';

  @override
  String get categoryMigrationFromLabel => '迁出分类';

  @override
  String get categoryMigrationFromHint => '选择要迁出的分类';

  @override
  String get categoryMigrationToLabel => '迁入分类';

  @override
  String get categoryMigrationToHint => '选择迁入的分类';

  @override
  String get categoryMigrationToHintFirst => '请先选择迁出分类';

  @override
  String get categoryMigrationStartButton => '开始迁移';

  @override
  String get categoryMigrationCannotTitle => '无法迁移';

  @override
  String get categoryMigrationCannotMessage => '选择的分类无法进行迁移，请检查分类状态。';

  @override
  String get categoryExpenseType => '支出分类';

  @override
  String get categoryIncomeType => '收入分类';

  @override
  String get categoryDefaultTitle => '默认分类';

  @override
  String get categoryNameLabel => '分类名称';

  @override
  String get categoryNameHint => '请输入分类名称';

  @override
  String get categoryNameRequired => '请输入分类名称';

  @override
  String get categoryNameTooLong => '分类名称不能超过4个字';

  @override
  String get categoryNameDuplicate => '分类名称已存在';

  @override
  String get categoryIconLabel => '分类图标';

  @override
  String get categoryCustomIconTitle => '自定义图标';

  @override
  String get categoryCustomIconTapToSelect => '点击选择图片';

  @override
  String get categoryCustomIconTapToChange => '点击更换图片';

  @override
  String get categoryCustomIconError => '选择图片时出错';

  @override
  String get categoryCustomIconRequired => '请选择自定义图标图片';

  @override
  String get categoryCustomIconCrop => '裁剪图标';

  @override
  String get categoryDangerousOperations => '危险操作';

  @override
  String get categoryDeleteTitle => '删除分类';

  @override
  String get categoryDeleteSubtitle => '删除后无法恢复';

  @override
  String get categorySaveError => '保存失败';

  @override
  String categoryUpdated(Object name) {
    return '分类\"$name\"已更新';
  }

  @override
  String categoryCreated(Object name) {
    return '分类\"$name\"已创建';
  }

  @override
  String get categoryCannotDelete => '无法删除';

  @override
  String categoryCannotDeleteMessage(Object count) {
    return '该分类下还有 $count 笔交易记录，请先处理这些记录。';
  }

  @override
  String get categoryShare => '分享分类';

  @override
  String get categoryImport => '导入分类';

  @override
  String get categoryClearUnused => '清空未使用分类';

  @override
  String get categoryClearUnusedTitle => '清空未使用分类';

  @override
  String categoryClearUnusedMessage(int count) {
    return '确定要删除 $count 个未使用的分类吗？此操作无法撤销。';
  }

  @override
  String get categoryClearUnusedReconfirmMessage =>
      '再次确认：删除后这些分类不可恢复，若误删需要重新创建。确定要继续吗？';

  @override
  String get categoryClearUnusedListTitle => '将被删除的分类：';

  @override
  String get categoryClearUnusedEmpty => '没有未使用的分类';

  @override
  String categoryClearUnusedSuccess(int count) {
    return '已删除 $count 个分类';
  }

  @override
  String get categoryClearUnusedFailed => '清空失败';

  @override
  String get categoryShareScopeTitle => '选择分享范围';

  @override
  String get categoryShareScopeExpense => '仅支出分类';

  @override
  String get categoryShareScopeIncome => '仅收入分类';

  @override
  String get categoryShareScopeAll => '全部分类';

  @override
  String categoryShareSuccess(String path) {
    return '已保存到 $path';
  }

  @override
  String get categoryShareSubject => 'PiggyCount 分类配置';

  @override
  String get categoryShareFailed => '分享失败';

  @override
  String get categoryImportInvalidFile => '请选择分类包文件（.zip）';

  @override
  String get categoryImportModeTitle => '选择导入模式';

  @override
  String get categoryImportModeMerge => '合并';

  @override
  String get categoryImportModeMergeDesc => '保留现有分类，新增不存在的';

  @override
  String get categoryImportModeOverwrite => '覆盖';

  @override
  String get categoryImportModeOverwriteDesc => '清空未使用分类后导入';

  @override
  String categoryImportSuccessDetail(int imported, int skipped, int icons) {
    return '已导入 $imported 个分类，跳过 $skipped 个，导入 $icons 个图标';
  }

  @override
  String get categoryImportFailed => '导入失败';

  @override
  String get categoryDeleteConfirmTitle => '删除分类';

  @override
  String categoryDeleteConfirmMessage(Object name) {
    return '确定要删除分类\"$name\"吗？此操作无法撤销。';
  }

  @override
  String get categoryDeleteError => '删除失败';

  @override
  String categoryDeleted(Object name) {
    return '分类\"$name\"已删除';
  }

  @override
  String get categorySubCategoryTitle => '二级分类';

  @override
  String get categorySubCategoryDescriptionEnabled => '此分类属于某个一级分类';

  @override
  String get categorySubCategoryDescriptionDisabled => '此分类为独立的一级分类';

  @override
  String get categoryParentCategoryTitle => '父分类';

  @override
  String get categoryParentCategoryHint => '请选择父分类';

  @override
  String get categorySelectParentTitle => '选择父分类';

  @override
  String categorySubCategoryCreated(Object name) {
    return '已添加二级分类：$name';
  }

  @override
  String get categoryParentRequired => '请选择父分类';

  @override
  String get categoryParentRequiredTitle => '错误';

  @override
  String get categoryExpenseList =>
      '餐饮-交通-购物-娱乐-居家-家庭-通讯-水电-住房-医疗-教育-宠物-运动-数码-旅行-烟酒-母婴-美容-维修-社交-学习-汽车-打车-地铁-外卖-物业-停车-捐赠-送礼-纳税-饮料-服装-零食-发红包-水果-游戏-书-爱人-装修-日用品-彩票-股票-社保-快递-工作';

  @override
  String get categoryIncomeList =>
      '工资-理财-收红包-奖金-报销-兼职-收礼-利息-退款-投资收益-二手转卖-社会保障-退税退费-公积金';

  @override
  String get categoryExpenseDining => '餐饮-早餐-午餐-晚餐-美团外卖-饿了么外卖-京东外卖-餐厅-美食';

  @override
  String get categoryExpenseSnacks => '零食-饼干-薯片-糖果-巧克力-坚果';

  @override
  String get categoryExpenseFruit => '水果-苹果-香蕉-橙子-葡萄-西瓜-其他水果';

  @override
  String get categoryExpenseBeverage => '饮品-奶茶-咖啡-果汁-汽水-矿泉水';

  @override
  String get categoryExpensePastry => '糕点-蛋糕-面包-甜点-曲奇';

  @override
  String get categoryExpenseCooking => '做饭食材-蔬菜-肉类-水产-调料-粮油';

  @override
  String get categoryExpenseShopping => '购物-服装-鞋帽-包包-配饰-日用百货';

  @override
  String get categoryExpensePets => '宠物-宠物食品-宠物用品-宠物医疗-宠物美容';

  @override
  String get categoryExpenseTransport => '交通-地铁-公交-出租车-网约车-停车费-加油';

  @override
  String get categoryExpenseCar => '汽车-汽车保养-汽车维修-汽车保险-洗车-违章罚款';

  @override
  String get categoryExpenseClothing => '服饰-上衣-裤子-裙子-鞋子-服饰配件';

  @override
  String get categoryExpenseDailyGoods => '日用品-洗护用品-纸品-清洁用品-厨房用品';

  @override
  String get categoryExpenseEducation => '教育-学费-培训费-书籍-文具-办公用品';

  @override
  String get categoryExpenseInvestLoss => '投资亏损-股票亏损-基金亏损-其他投资亏损';

  @override
  String get categoryExpenseEntertainment => '娱乐-电影-KTV-游乐场-酒吧-其他娱乐';

  @override
  String get categoryExpenseGame => '游戏-游戏充值-游戏装备-游戏会员';

  @override
  String get categoryExpenseHealthProducts => '保健品-维生素-保健食品-营养品';

  @override
  String get categoryExpenseSubscription => '订阅服务-视频会员-音乐会员-云存储-其他订阅';

  @override
  String get categoryExpenseSports => '运动-健身房-运动装备-运动课程-户外活动';

  @override
  String get categoryExpenseHousing => '住房-房租-物业费-房贷-装修';

  @override
  String get categoryExpenseHome => '居家-家具-家电-装饰品-床上用品';

  @override
  String get categoryExpenseBeauty => '美容-护肤品-化妆品-美容美发-美甲';

  @override
  String get categoryIncomeSalary => '工资-基本工资-绩效奖金-年终奖-加班费';

  @override
  String get categoryIncomeInvestment => '理财-基金收益-股票分红-理财产品-其他理财';

  @override
  String get categoryIncomeRedPacket => '红包-节日红包-生日红包-随礼回礼';

  @override
  String get categoryIncomeBonus => '奖金-年度奖金-季度奖-项目奖金-其他奖金';

  @override
  String get categoryIncomeReimbursement => '报销-差旅报销-餐费报销-其他报销';

  @override
  String get categoryIncomePartTime => '兼职-兼职收入-外快';

  @override
  String get categoryIncomeGift => '礼金-结婚礼金-生日礼金-其他礼金';

  @override
  String get categoryIncomeInterest => '利息-银行利息-其他利息';

  @override
  String get categoryIncomeRefund => '退款-购物退款-服务退款-其他退款';

  @override
  String get categoryIncomeInvestIncome => '投资收益-股票收益-基金投资-其他投资收益';

  @override
  String get categoryIncomeSecondHand => '二手交易-闲置物品-二手商品';

  @override
  String get categoryIncomeSocialBenefit => '社会福利-失业保险-生育津贴-其他补贴';

  @override
  String get categoryIncomeTaxRefund => '退税-个税退税-其他退费';

  @override
  String get categoryIncomeProvidentFund => '公积金-公积金提取-公积金利息';

  @override
  String get personalizeTitle => '主题色';

  @override
  String get personalizeSubtitle => '选择或自定义应用主题色';

  @override
  String get personalizeCustomColor => '选择自定义颜色';

  @override
  String get personalizeCustomTitle => '自定义';

  @override
  String personalizeHue(Object value) {
    return '色相 ($value°)';
  }

  @override
  String personalizeSaturation(Object value) {
    return '饱和度 ($value%)';
  }

  @override
  String personalizeBrightness(Object value) {
    return '亮度 ($value%)';
  }

  @override
  String get personalizeSelectColor => '选择此颜色';

  @override
  String get appearanceThemeMode => '外观模式';

  @override
  String get appearanceThemeModeSystem => '跟随系统';

  @override
  String get appearanceThemeModeLight => '亮色模式';

  @override
  String get appearanceThemeModeDark => '暗黑模式';

  @override
  String get appearanceAmountFormat => '余额显示格式';

  @override
  String get appearanceAmountFormatFull => '完整金额';

  @override
  String get appearanceAmountFormatFullDesc => '显示完整金额，如 123,456.78';

  @override
  String get appearanceAmountFormatCompact => '简洁显示';

  @override
  String get appearanceAmountFormatCompactDesc => '大金额缩写，如 12.3万（仅对账户余额生效）';

  @override
  String get appearanceShowTransactionTime => '显示交易时间';

  @override
  String get appearanceShowTransactionTimeDesc => '在账单列表显示时分，编辑时可选择时间';

  @override
  String get appearanceQuickEntryMode => '快捷记账模式';

  @override
  String get appearanceQuickEntryModeDesc => '点「记一笔」直接用最近用过的分类，直达金额输入；关闭则先选分类';

  @override
  String get appearanceNoteDisplay => '备注显示方式';

  @override
  String get appearanceNoteDisplayCategory => '分类优先';

  @override
  String get appearanceNoteDisplayCategoryDesc => '显示分类名,备注以括号附在后面';

  @override
  String get appearanceNoteDisplayNote => '备注优先';

  @override
  String get appearanceNoteDisplayNoteDesc => '有备注时显示备注,无备注时显示分类名';

  @override
  String get appearanceNoteHistory => '历史备注';

  @override
  String get appearanceNoteHistoryScope => '展示范围';

  @override
  String get appearanceNoteHistoryScopeAllCategories => '全部分类';

  @override
  String get appearanceNoteHistoryScopeCurrentCategory => '当前分类';

  @override
  String get appearanceNoteHistorySort => '排序方式';

  @override
  String get appearanceNoteHistorySortFrequency => '使用频次';

  @override
  String get appearanceNoteHistorySortRecent => '最近使用';

  @override
  String get appearanceNoteHistoryLimit => '显示数量';

  @override
  String get appearanceNoteHistoryLimitHint => '可设置 1 至 100 条';

  @override
  String get appearanceNoteHistoryLimitInvalid => '请输入 1 至 100 的整数';

  @override
  String get appearanceColorScheme => '收支颜色方案';

  @override
  String get appearanceColorSchemeOn => '红色收入 · 绿色支出';

  @override
  String get appearanceColorSchemeOff => '红色支出 · 绿色收入';

  @override
  String get appearanceColorSchemeOnDesc => '红色表示收入，绿色表示支出';

  @override
  String get appearanceColorSchemeOffDesc => '红色表示支出，绿色表示收入';

  @override
  String get appearanceColorSchemeBlue => '蓝色收入 · 橙色支出';

  @override
  String get appearanceColorSchemeBlueDesc => '蓝色表示收入，橙色表示支出';

  @override
  String fontSettingsCurrentScale(Object scale) {
    return '当前缩放：x$scale';
  }

  @override
  String get fontSettingsPreview => '实时预览';

  @override
  String get fontSettingsPreviewText =>
      '今天吃饭花了 23.50 元，记一笔；\n本月已记账 45 天，共 320 条记录；\n坚持就是胜利！';

  @override
  String fontSettingsCurrentLevel(Object level, Object scale) {
    return '当前档位：$level  (倍率 x$scale)';
  }

  @override
  String get fontSettingsQuickLevel => '快速档位';

  @override
  String get fontSettingsCustomAdjust => '自定义调整';

  @override
  String get fontSettingsDescription =>
      '说明：此设置确保所有设备在1.0倍时显示效果一致，设备差异已自动补偿；调整数值可在一致基础上进行个性化缩放。';

  @override
  String get fontSettingsExtraSmall => '极小';

  @override
  String get fontSettingsVerySmall => '很小';

  @override
  String get fontSettingsSmall => '较小';

  @override
  String get fontSettingsStandard => '标准';

  @override
  String get fontSettingsLarge => '较大';

  @override
  String get fontSettingsBig => '大';

  @override
  String get fontSettingsVeryBig => '很大';

  @override
  String get fontSettingsExtraBig => '极大';

  @override
  String get fontSettingsMoreStyles => '更多风格';

  @override
  String get fontSettingsPageTitle => '页面标题';

  @override
  String get fontSettingsBlockTitle => '区块标题';

  @override
  String get fontSettingsBodyExample => '正文示例';

  @override
  String get fontSettingsLabelExample => '标签说明';

  @override
  String get fontSettingsStrongNumber => '强调数字';

  @override
  String get fontSettingsListTitle => '列表项标题';

  @override
  String get fontSettingsListSubtitle => '辅助说明文本';

  @override
  String get fontSettingsScreenInfo => '屏幕适配信息';

  @override
  String get fontSettingsScreenDensity => '屏幕密度';

  @override
  String get fontSettingsScreenWidth => '屏幕宽度';

  @override
  String get fontSettingsDeviceScale => '设备缩放';

  @override
  String get fontSettingsUserScale => '用户缩放';

  @override
  String get fontSettingsFinalScale => '最终缩放';

  @override
  String get fontSettingsBaseDevice => '基准设备';

  @override
  String get fontSettingsRecommendedScale => '推荐缩放';

  @override
  String get fontSettingsYes => '是';

  @override
  String get fontSettingsNo => '否';

  @override
  String get fontSettingsScaleExample => '此方框和间距会根据设备自动缩放';

  @override
  String get fontSettingsPreciseAdjust => '精确调整';

  @override
  String get fontSettingsResetTo1x => '重置到1.0x';

  @override
  String get fontSettingsAdaptBase => '适配基准';

  @override
  String get reminderTitle => '记账提醒';

  @override
  String get reminderDailyTitle => '每日记账提醒';

  @override
  String get reminderDailySubtitle => '开启后将在指定时间提醒您记账';

  @override
  String get reminderTimeTitle => '提醒时间';

  @override
  String get commonSelectTime => '选择时间';

  @override
  String get reminderTestNotification => '发送测试通知';

  @override
  String get reminderTestSent => '测试通知已发送';

  @override
  String get reminderTestTitle => '测试通知';

  @override
  String get reminderTestBody => '这是一条测试通知，点击查看效果';

  @override
  String get reminderCheckBattery => '检查电池优化状态';

  @override
  String get reminderBatteryStatus => '电池优化状态';

  @override
  String reminderManufacturer(Object value) {
    return '设备制造商: $value';
  }

  @override
  String reminderModel(Object value) {
    return '设备型号: $value';
  }

  @override
  String reminderAndroidVersion(Object value) {
    return 'Android版本: $value';
  }

  @override
  String get reminderBatteryIgnored => '电池优化状态: 已忽略 ✅';

  @override
  String get reminderBatteryNotIgnored => '电池优化状态: 未忽略 ⚠️';

  @override
  String get reminderBatteryAdvice => '建议关闭电池优化以确保通知正常工作';

  @override
  String get reminderCheckChannel => '检查通知渠道设置';

  @override
  String get reminderChannelStatus => '通知渠道状态';

  @override
  String get reminderChannelEnabled => '渠道启用: 是 ✅';

  @override
  String get reminderChannelDisabled => '渠道启用: 否 ❌';

  @override
  String reminderChannelImportance(Object value) {
    return '重要性: $value';
  }

  @override
  String get reminderChannelSoundOn => '声音: 开启 🔊';

  @override
  String get reminderChannelSoundOff => '声音: 关闭 🔇';

  @override
  String get reminderChannelVibrationOn => '震动: 开启 📳';

  @override
  String get reminderChannelVibrationOff => '震动: 关闭';

  @override
  String get reminderChannelDndBypass => '勿扰模式: 可绕过';

  @override
  String get reminderChannelDndNoBypass => '勿扰模式: 不可绕过';

  @override
  String get reminderChannelAdvice => '⚠️ 建议设置：';

  @override
  String get reminderChannelAdviceImportance => '• 重要性：紧急或高';

  @override
  String get reminderChannelAdviceSound => '• 开启声音和震动';

  @override
  String get reminderChannelAdviceBanner => '• 允许横幅通知';

  @override
  String get reminderChannelAdviceXiaomi => '• 小米手机需单独设置每个渠道';

  @override
  String get reminderChannelGood => '✅ 通知渠道配置良好';

  @override
  String get reminderOpenAppSettings => '打开应用设置';

  @override
  String get reminderAppSettingsMessage => '请在设置中允许通知、关闭电池优化';

  @override
  String get reminderDescription => '提示：开启记账提醒后，系统会在每天指定时间发送通知提醒您记录收支。';

  @override
  String get reminderIOSInstructions =>
      '🍎 iOS通知设置：\n• 设置 > 通知 > 小猪记账\n• 开启\"允许通知\"\n• 设置通知样式：横幅或提醒\n• 开启声音和震动\n\n⚠️ 重要提示：\n• iOS本地通知依赖应用进程\n• 请勿在任务管理器中划掉应用\n• 应用在后台或前台时通知正常\n• 完全关闭应用会导致通知失效\n\n💡 使用建议：\n• 日常使用后直接按Home键退出\n• iOS会自动管理后台应用\n• 保持应用在后台即可收到提醒';

  @override
  String get reminderAndroidInstructions =>
      '如果通知无法正常工作，请检查：\n• 已允许应用发送通知\n• 关闭应用的电池优化/省电模式\n• 允许应用在后台运行和自启动\n• Android 12+需要精确闹钟权限\n\n📱 小米手机特殊设置：\n• 设置 > 应用管理 > 小猪记账 > 通知管理\n• 点击\"记账提醒\"渠道\n• 设置重要性为\"紧急\"或\"高\"\n• 开启\"横幅通知\"、\"声音\"、\"震动\"\n• 安全中心 > 应用管理 > 权限 > 自启动\n\n🔒 锁定后台方法：\n• 最近任务中找到小猪记账\n• 向下拉动应用卡片显示锁定图标\n• 点击锁定图标防止被清理';

  @override
  String get categoryDetailLoadFailed => '加载失败';

  @override
  String get categoryDetailSummaryTitle => '分类汇总';

  @override
  String get categoryDetailTotalCount => '总笔数';

  @override
  String get categoryDetailTotalAmount => '总金额';

  @override
  String get categoryDetailAverageAmount => '平均金额';

  @override
  String get categoryDetailSortTitle => '排序';

  @override
  String get categoryDetailSortTimeDesc => '时间↓';

  @override
  String get categoryDetailSortTimeAsc => '时间↑';

  @override
  String get categoryDetailSortAmountDesc => '金额↓';

  @override
  String get categoryDetailSortAmountAsc => '金额↑';

  @override
  String get categoryDetailNoTransactions => '暂无交易记录';

  @override
  String get categoryDetailNoTransactionsSubtext => '该分类下还没有任何交易记录';

  @override
  String get categoryDetailDeleteFailed => '删除失败';

  @override
  String get categoryMigrationConfirmTitle => '确认迁移';

  @override
  String categoryMigrationConfirmMessage(
      Object count, Object fromName, Object toName) {
    return '确定要将「$fromName」的 $count 笔交易迁移到「$toName」吗？\n\n此操作不可撤销！';
  }

  @override
  String get categoryMigrationConfirmOk => '确认迁移';

  @override
  String get categoryMigrationCompleteTitle => '迁移完成';

  @override
  String categoryMigrationCompleteMessage(
      Object count, Object fromName, Object toName) {
    return '成功将 $count 笔交易从「$fromName」迁移到「$toName」。';
  }

  @override
  String get categoryMigrationFailedTitle => '迁移失败';

  @override
  String categoryMigrationFailedMessage(Object error) {
    return '迁移过程中发生错误：$error';
  }

  @override
  String categoryMigrationTransactionLabel(int count) {
    return '$count笔';
  }

  @override
  String get mineImportCompleteAllSuccess => '全部成功';

  @override
  String get mineCheckUpdateDetecting => '检测更新中...';

  @override
  String get mineCheckUpdateSubtitleDetecting => '正在检查最新版本';

  @override
  String get mineUpdateDownloadTitle => '下载更新';

  @override
  String get cloudSupabaseUrlLabel => 'Supabase URL';

  @override
  String get cloudSupabaseUrlHint => 'https://xxx.supabase.co';

  @override
  String get cloudAnonKeyLabel => 'Anon Key';

  @override
  String get cloudMultiDeviceWarningTitle => '多设备使用提醒';

  @override
  String get cloudMultiDeviceWarningMessage =>
      '换设备前记得先上传，到新设备后先下载再记账。不要同时在两台设备上记同一个账本。点击查看详情 →';

  @override
  String get cloudWebdavUrlLabel => 'WebDAV 服务器地址';

  @override
  String get cloudWebdavUrlHint => 'https://dav.jianguoyun.com/dav/';

  @override
  String get cloudWebdavUsernameLabel => '用户名';

  @override
  String get cloudWebdavPasswordLabel => '密码';

  @override
  String get cloudWebdavPathHint => '/PiggyCount';

  @override
  String get cloudS3EndpointLabel => '端点地址';

  @override
  String get cloudS3EndpointHint => 's3.amazonaws.com 或自定义端点';

  @override
  String get cloudS3RegionLabel => '区域';

  @override
  String get cloudS3RegionHint => 'us-east-1（留空自动）';

  @override
  String get cloudS3AccessKeyLabel => 'Access Key';

  @override
  String get cloudS3AccessKeyHint => '您的 Access Key ID';

  @override
  String get cloudS3SecretKeyLabel => 'Secret Key';

  @override
  String get cloudS3SecretKeyHint => '您的 Secret Access Key';

  @override
  String get cloudS3BucketLabel => '存储桶名称';

  @override
  String get cloudS3BucketHint => '例如 my-bucket';

  @override
  String get cloudS3UseSSLLabel => '使用 HTTPS';

  @override
  String get cloudS3PortLabel => '端口（可选）';

  @override
  String get cloudS3PortHint => '留空使用默认端口';

  @override
  String get cloudSupabaseBucketLabel => 'Storage Bucket 名称';

  @override
  String get cloudSupabaseBucketHint => '留空使用默认值 piggycount-backups';

  @override
  String get authRememberAccount => '记住账号密码';

  @override
  String get authRememberAccountHint => '下次登录时自动填充（仅Supabase）';

  @override
  String get cloudConfigSaved => '配置已保存';

  @override
  String get authLogin => '登录';

  @override
  String get authEmail => '邮箱';

  @override
  String get authPassword => '密码';

  @override
  String get authInvalidEmail => '请输入有效的邮箱地址';

  @override
  String get authErrorInvalidCredentials => '邮箱或密码不正确。';

  @override
  String get authErrorEmailNotConfirmed => '邮箱未验证，请先到邮箱完成验证再登录。';

  @override
  String get authErrorRateLimit => '操作过于频繁，请稍后再试。';

  @override
  String get authErrorNetworkIssue => '网络异常，请检查网络后重试。';

  @override
  String get authErrorLoginFailed => '登录失败，请稍后再试。';

  @override
  String get importSelectCsvFile => '请选择文件进行导入（支持 CSV/TSV/XLSX 格式）';

  @override
  String get exportTitle => '导出';

  @override
  String get exportDescription =>
      '支持导出的数据类型：\n• 交易记录（收入/支出/转账）\n• 分类信息\n• 账户信息\n\n点击下方按钮选择保存位置，开始导出当前账本为 CSV 文件。';

  @override
  String get exportButtonIOS => '导出并分享';

  @override
  String get exportButtonAndroid => '导出数据';

  @override
  String exportSavedTo(String path) {
    return '已保存到：$path';
  }

  @override
  String get exportCsvHeaderType => '类型';

  @override
  String get exportCsvHeaderCategory => '分类';

  @override
  String get exportCsvHeaderSubCategory => '二级分类';

  @override
  String get exportCsvHeaderAmount => '金额';

  @override
  String get exportCsvHeaderAccount => '账户';

  @override
  String get exportCsvHeaderFromAccount => '转出账户';

  @override
  String get exportCsvHeaderToAccount => '转入账户';

  @override
  String get exportCsvHeaderNote => '备注';

  @override
  String get exportCsvHeaderTime => '时间';

  @override
  String get exportCsvHeaderTags => '标签';

  @override
  String get exportCsvHeaderAttachments => '附件';

  @override
  String get exportCsvHeaderCustomFields => '自定义字段';

  @override
  String get exportShareText => 'PiggyCount 导出文件';

  @override
  String get exportSuccessTitle => '导出成功';

  @override
  String exportSuccessMessageIOS(String path) {
    return '已保存并可在分享历史中找到：\n$path';
  }

  @override
  String exportSuccessMessageAndroid(String path) {
    return '已保存到：\n$path';
  }

  @override
  String get exportFailedTitle => '导出失败';

  @override
  String get exportTypeIncome => '收入';

  @override
  String get exportTypeExpense => '支出';

  @override
  String get exportTypeTransfer => '转账';

  @override
  String get personalizeThemeHoney => '蜜蜂黄';

  @override
  String get personalizeThemeOrange => '火焰橙';

  @override
  String get personalizeThemeGreen => '琉璃绿';

  @override
  String get personalizeThemePurple => '青莲紫';

  @override
  String get personalizeThemePink => '樱绯红';

  @override
  String get personalizeThemeBlue => '晴空蓝';

  @override
  String get personalizeThemeMint => '林间月';

  @override
  String get personalizeThemeSand => '黄昏沙丘';

  @override
  String get personalizeThemeLavender => '雪与松';

  @override
  String get personalizeThemeSky => '迷雾仙境';

  @override
  String get personalizeThemeWarmOrange => '暖阳橘';

  @override
  String get personalizeThemeMintGreen => '薄荷青';

  @override
  String get personalizeThemeRoseGold => '玫瑰金';

  @override
  String get personalizeThemeDeepBlue => '深海蓝';

  @override
  String get personalizeThemeMapleRed => '枫叶红';

  @override
  String get personalizeThemeEmerald => '翡翠绿';

  @override
  String get personalizeThemeLavenderPurple => '薰衣草';

  @override
  String get personalizeThemeAmber => '琥珀黄';

  @override
  String get personalizeThemeRouge => '胭脂红';

  @override
  String get personalizeThemeIndigo => '靛青蓝';

  @override
  String get personalizeThemeOlive => '橄榄绿';

  @override
  String get personalizeThemeCoral => '珊瑚粉';

  @override
  String get personalizeThemeDarkGreen => '墨绿色';

  @override
  String get personalizeThemeViolet => '紫罗兰';

  @override
  String get personalizeThemeSunset => '日落橙';

  @override
  String get personalizeThemePeacock => '孔雀蓝';

  @override
  String get personalizeThemeLime => '柠檬绿';

  @override
  String get personalizeThemePiggyPink => '小猪粉';

  @override
  String get personalizeThemeSkyBlue => '天空蓝';

  @override
  String get personalizeThemeGradientBlue => '渐变蓝';

  @override
  String get analyticsMonthlyAvg => '月均';

  @override
  String get analyticsDailyAvg => '日均';

  @override
  String get analyticsOverallAvg => '平均值';

  @override
  String get analyticsTotalExpense => '总支出： ';

  @override
  String get analyticsBalance => '结余： ';

  @override
  String get analyticsComparedToLastYear => '比上年';

  @override
  String get analyticsTxCount => '记账笔数';

  @override
  String get analyticsExpense => '支出';

  @override
  String get analyticsIncome => '收入';

  @override
  String analyticsTotal(String type) {
    return '总$type： ';
  }

  @override
  String get updateCheckTitle => '检查更新';

  @override
  String updateNewVersionTitle(String version) {
    return '发现新版本 $version';
  }

  @override
  String get updateNoApkFound => '未找到APK下载链接';

  @override
  String get updateAlreadyLatest => '当前已是最新版本';

  @override
  String get updateCheckFailed => '检查更新失败';

  @override
  String get updatePermissionDenied => '权限被拒绝';

  @override
  String get updateUserCancelled => '用户取消';

  @override
  String get updateDownloadTitle => '下载更新';

  @override
  String updateDownloading(String percent) {
    return '下载中: $percent%';
  }

  @override
  String get updateDownloadBackgroundHint => '可以将应用切换到后台，下载会继续进行';

  @override
  String get updateCancelButton => '取消';

  @override
  String get updateBackgroundDownload => '后台下载';

  @override
  String get updateLaterButton => '稍后';

  @override
  String get updateDownloadButton => '下载';

  @override
  String get updateInstallingCachedApk => '正在安装缓存的APK';

  @override
  String get updateInstallStarted => '下载完成，安装程序已启动';

  @override
  String get updateInstallFailed => '安装失败';

  @override
  String get updateDownloadFailed => '下载失败';

  @override
  String get updateInstallNow => '立即安装';

  @override
  String get updateNotificationPermissionTitle => '通知权限被拒绝';

  @override
  String get updateCheckFailedTitle => '检测更新失败';

  @override
  String get updateDownloadFailedTitle => '下载失败';

  @override
  String get updateGoToGitHub => '前往GitHub';

  @override
  String get updateManualVisit =>
      '请手动在浏览器中访问：\\nhttps://github.com/mecoren/PiggyCount/releases';

  @override
  String get updateNoLocalApkTitle => '未找到更新包';

  @override
  String get updateInstallPackageTitle => '安装更新包';

  @override
  String get updateMultiplePackagesTitle => '找到多个更新包';

  @override
  String get updateSearchFailedTitle => '查找失败';

  @override
  String get updateFoundCachedPackageTitle => '发现已下载的更新包';

  @override
  String get updateIgnoreButton => '忽略';

  @override
  String get updateInstallFailedTitle => '安装失败';

  @override
  String get updateInstallFailedMessage => '无法启动APK安装程序，请检查文件权限。';

  @override
  String get updateErrorTitle => '错误';

  @override
  String get updateCheckingPermissions => '检查权限...';

  @override
  String get updateCheckingCache => '检查本地缓存...';

  @override
  String get updatePreparingDownload => '准备下载...';

  @override
  String get updateUserCancelledDownload => '用户取消下载';

  @override
  String get updateStartingInstaller => '正在启动安装...';

  @override
  String get updateInstallerStarted => '安装程序已启动';

  @override
  String get updateInstallationFailed => '安装失败';

  @override
  String get updateDownloadCompleted => '下载完成';

  @override
  String get updateDownloadCompletedManual => '下载完成，可以手动安装';

  @override
  String get updateDownloadCompletedDialog => '下载完成，请手动安装（弹窗异常）';

  @override
  String get updateDownloadCompletedContext => '下载完成，请手动安装';

  @override
  String get updateDownloadFailedGeneric => '下载失败';

  @override
  String get updateCheckingUpdate => '正在检查更新...';

  @override
  String get updateCurrentLatestVersion => '当前已是最新版本';

  @override
  String get updateCheckFailedGeneric => '检查更新失败';

  @override
  String updateDownloadProgress(String percent) {
    return '下载中: $percent%';
  }

  @override
  String updateCheckingUpdateError(String error) {
    return '检查更新失败: $error';
  }

  @override
  String get updateNoLocalApkFoundMessage =>
      '没有找到已下载的更新包文件。\n\n请先通过\"检查更新\"下载新版本。';

  @override
  String updateInstallPackageFoundMessage(
      String fileName, String fileSize, String time) {
    return '找到更新包：\n\n文件名：$fileName\n大小：${fileSize}MB\n下载时间：$time\n\n是否立即安装？';
  }

  @override
  String updateMultiplePackagesFoundMessage(int count, String path) {
    return '找到 $count 个更新包文件。\n\n建议使用最新下载的版本，或手动到文件管理器中安装。\n\n文件位置：$path';
  }

  @override
  String updateSearchLocalApkError(String error) {
    return '查找本地更新包时发生错误：$error';
  }

  @override
  String updateCachedPackageFoundMessage(String fileName, String fileSize) {
    return '检测到之前下载的更新包：\n\n文件名：$fileName\n大小：${fileSize}MB\n\n是否立即安装？';
  }

  @override
  String updateReadCachedPackageError(String error) {
    return '读取缓存更新包失败：$error';
  }

  @override
  String get updateOk => '知道了';

  @override
  String get updateCannotOpenLinkTitle => '无法打开链接';

  @override
  String get updateCachedVersionTitle => '发现已下载版本';

  @override
  String get updateCachedVersionMessage =>
      '已找到之前下载的安装包...点击\\\"确定\\\"立即安装，点击\\\"取消\\\"关闭...';

  @override
  String get updateConfirmDownload => '立即下载并安装';

  @override
  String get updateDownloadCompleteTitle => '下载完成';

  @override
  String get updateInstallConfirmMessage => '新版本已下载完成，是否立即安装？';

  @override
  String get updateMirrorSelectTitle => '选择下载加速器';

  @override
  String get updateMirrorSelectHint => '如果下载缓慢，可以选择一个加速镜像。点击「测速」检测各镜像延迟。';

  @override
  String get updateMirrorTestButton => '测速';

  @override
  String updateMirrorTesting(int completed, int total) {
    return '正在测试 $completed/$total...';
  }

  @override
  String get updateMirrorDirectHint => '适合网络通畅的用户';

  @override
  String updateDownloadMirror(String mirror) {
    return '下载源: $mirror';
  }

  @override
  String get updateMirrorSettingTitle => '下载加速器';

  @override
  String get updateNotificationPermissionGuideText =>
      '下载进度通知被关闭，但不影响下载功能。如需查看进度：';

  @override
  String get updateNotificationGuideStep1 => '进入系统设置 > 应用管理';

  @override
  String get updateNotificationGuideStep2 => '找到\\\"小猪记账\\\"应用';

  @override
  String get updateNotificationGuideStep3 => '开启通知权限';

  @override
  String get updateNotificationGuideInfo => '即使不开启通知，下载也会在后台正常进行';

  @override
  String get currencyCNY => '人民币';

  @override
  String get currencyUSD => '美元';

  @override
  String get currencyEUR => '欧元';

  @override
  String get currencyJPY => '日元';

  @override
  String get currencyHKD => '港币';

  @override
  String get currencyTWD => '新台币';

  @override
  String get currencyGBP => '英镑';

  @override
  String get currencyAUD => '澳元';

  @override
  String get currencyCAD => '加元';

  @override
  String get currencyKRW => '韩元';

  @override
  String get currencySGD => '新加坡元';

  @override
  String get currencyMYR => '马来西亚林吉特';

  @override
  String get currencyTHB => '泰铢';

  @override
  String get currencyIDR => '印尼卢比';

  @override
  String get currencyPHP => '菲律宾比索';

  @override
  String get currencyVND => '越南盾';

  @override
  String get currencyINR => '印度卢比';

  @override
  String get currencyRUB => '俄罗斯卢布';

  @override
  String get currencyBYN => '白俄罗斯卢布';

  @override
  String get currencyNZD => '新西兰元';

  @override
  String get currencyCHF => '瑞士法郎';

  @override
  String get currencySEK => '瑞典克朗';

  @override
  String get currencyNOK => '挪威克朗';

  @override
  String get currencyDKK => '丹麦克朗';

  @override
  String get currencyBRL => '巴西雷亚尔';

  @override
  String get currencyMXN => '墨西哥比索';

  @override
  String get currencyTRY => '土耳其里拉';

  @override
  String get currencyZAR => '南非兰特';

  @override
  String get currencyAED => '阿联酋迪拉姆';

  @override
  String get currencySAR => '沙特里亚尔';

  @override
  String get currencyPLN => '波兰兹罗提';

  @override
  String get currencyCZK => '捷克克朗';

  @override
  String get currencyHUF => '匈牙利福林';

  @override
  String get currencyARS => '阿根廷比索';

  @override
  String get currencyCLP => '智利比索';

  @override
  String get currencyCOP => '哥伦比亚比索';

  @override
  String get currencyPEN => '秘鲁索尔';

  @override
  String get currencyEGP => '埃及镑';

  @override
  String get currencyNGN => '尼日利亚奈拉';

  @override
  String get currencyKZT => '哈萨克斯坦坚戈';

  @override
  String get currencyUAH => '乌克兰格里夫纳';

  @override
  String get currencyILS => '以色列新谢克尔';

  @override
  String get currencyPKR => '巴基斯坦卢比';

  @override
  String get currencyBDT => '孟加拉塔卡';

  @override
  String get currencyLKR => '斯里兰卡卢比';

  @override
  String get currencyMMK => '缅甸元';

  @override
  String get webdavConfiguredTitle => 'WebDAV 云服务已配置';

  @override
  String get webdavConfiguredMessage => 'WebDAV 云服务使用配置时提供的凭据，无需额外登录。';

  @override
  String get recurringTransactionTitle => '周期账单';

  @override
  String get recurringTransactionAdd => '添加周期账单';

  @override
  String get recurringTransactionEdit => '编辑周期账单';

  @override
  String get recurringTransactionFrequency => '周期频率';

  @override
  String get recurringTransactionDaily => '每天';

  @override
  String get recurringTransactionWeekly => '每周';

  @override
  String get recurringTransactionMonthly => '每月';

  @override
  String get recurringTransactionYearly => '每年';

  @override
  String get recurringTransactionInterval => '间隔';

  @override
  String get recurringTransactionDayOfMonth => '每月第几天';

  @override
  String get recurringTransactionStartDate => '开始日期';

  @override
  String get recurringTransactionEndDate => '结束日期';

  @override
  String get recurringTransactionNoEndDate => '永久周期';

  @override
  String get recurringTransactionDeleteConfirm => '确定要删除这个周期账单吗？';

  @override
  String get recurringTransactionEmpty => '暂无周期账单';

  @override
  String get recurringTransactionEmptyHint => '点击右上角 + 按钮添加';

  @override
  String recurringTransactionEveryNDays(int n) {
    return '每 $n 天';
  }

  @override
  String recurringTransactionEveryNWeeks(int n) {
    return '每 $n 周';
  }

  @override
  String recurringTransactionEveryNMonths(int n) {
    return '每 $n 个月';
  }

  @override
  String recurringTransactionEveryNYears(int n) {
    return '每 $n 年';
  }

  @override
  String get recurringTransactionUsageTitle => '使用说明';

  @override
  String get recurringTransactionUsageContent =>
      '周期记账会在每次冷启动进入App时自动扫描并生成账单。设置日期后，系统会在该日期之后的冷启动时创建对应账单。例如：设置11月27日，则会在11月27日之后的首次启动时自动记账。';

  @override
  String get ledgerSelectTitle => '选择账本';

  @override
  String get ledgerSelect => '选择账本';

  @override
  String get syncNotConfiguredMessage => '未配置云端';

  @override
  String get syncNotLoggedInMessage => '未登录';

  @override
  String get syncCloudBackupCorruptedMessage =>
      '云端备份内容无法解析，可能是早期版本编码问题造成的损坏。请点击\\\"上传当前账本到云端\\\"覆盖修复。';

  @override
  String get syncNoCloudBackupMessage => '云端暂无备份';

  @override
  String get syncAccessDeniedMessage => '403 拒绝访问（检查 storage RLS 策略与路径）';

  @override
  String get cloudTestConnection => '测试连接';

  @override
  String get cloudLocalStorageTitle => '本地存储';

  @override
  String get cloudLocalStorageSubtitle => '数据仅保存在本地设备';

  @override
  String get cloudCustomSupabaseTitle => '自定义 Supabase';

  @override
  String get cloudCustomSupabaseSubtitle => '点击配置自建Supabase服务';

  @override
  String get cloudCustomWebdavTitle => '自定义 WebDAV';

  @override
  String get cloudCustomWebdavSubtitle => '点击配置坚果云/Nextcloud等';

  @override
  String get cloudCustomS3Title => 'S3 协议存储';

  @override
  String get cloudCustomS3Subtitle => 'AWS S3 / Cloudflare R2 / MinIO';

  @override
  String get cloudTabOffline => '离线模式';

  @override
  String get cloudTabBackup => '备份同步';

  @override
  String get cloudIcloudSubtitle => '使用 Apple ID 自动同步';

  @override
  String get cloudIcloudNotAvailableTitle => 'iCloud 不可用';

  @override
  String get cloudIcloudNotAvailableMessage => '请在系统设置中登录 iCloud 账户后再试';

  @override
  String get cloudIcloudHelpTitle => 'iCloud 使用说明';

  @override
  String get cloudIcloudHelpPrerequisites => '前提条件';

  @override
  String get cloudIcloudHelpPrereq1 => '1. 设备已登录 Apple ID';

  @override
  String get cloudIcloudHelpPrereq2 => '2. 已开启 iCloud Drive';

  @override
  String get cloudIcloudHelpPrereq3 => '3. 设备已联网';

  @override
  String get cloudIcloudHelpCheckTitle => '如何检查 iCloud Drive';

  @override
  String get cloudIcloudHelpCheck1 => '1. 打开「设置」';

  @override
  String get cloudIcloudHelpCheck2 => '2. 点击顶部的 Apple ID';

  @override
  String get cloudIcloudHelpCheck3 => '3. 点击「iCloud」';

  @override
  String get cloudIcloudHelpCheck4 => '4. 确保「iCloud 云盘」已开启';

  @override
  String get cloudIcloudHelpFaqTitle => '常见问题';

  @override
  String get cloudIcloudHelpFaq1 => '如果提示不可用，请检查 iCloud Drive 是否开启';

  @override
  String get cloudIcloudHelpFaq2 => '首次使用可能需要等待几秒钟初始化';

  @override
  String get cloudIcloudHelpFaq3 => '数据存储在您的私人 iCloud 空间中';

  @override
  String get cloudIcloudHelpFaq4 => '同一 Apple ID 的设备可自动同步';

  @override
  String get cloudIcloudHelpNote => 'iCloud 同步使用您的 Apple ID，无需额外配置';

  @override
  String get cloudSupabaseHelpTitle => 'Supabase 配置说明';

  @override
  String get cloudSupabaseHelpIntro => '什么是 Supabase';

  @override
  String get cloudSupabaseHelpIntro1 => 'Supabase 是一个开源的后端即服务平台';

  @override
  String get cloudSupabaseHelpIntro2 => '提供免费套餐，足够个人使用';

  @override
  String get cloudSupabaseHelpIntro3 => '数据完全由您掌控';

  @override
  String get cloudSupabaseHelpSteps => '配置步骤';

  @override
  String get cloudSupabaseHelpStep1 => '1. 访问 supabase.com 注册账号';

  @override
  String get cloudSupabaseHelpStep2 => '2. 创建新项目（选择免费套餐）';

  @override
  String get cloudSupabaseHelpStep3 => '3. 进入项目设置 > API';

  @override
  String get cloudSupabaseHelpStep4 => '4. 复制 Project URL 和 anon key';

  @override
  String get cloudSupabaseHelpStep5 => '5. 粘贴到应用的配置中';

  @override
  String get cloudSupabaseHelpFaq => '常见问题';

  @override
  String get cloudSupabaseHelpFaq1 => '免费套餐有 500MB 存储空间';

  @override
  String get cloudSupabaseHelpFaq2 => '数据加密存储，安全可靠';

  @override
  String get cloudSupabaseHelpFaq3 => '支持多设备同步';

  @override
  String get cloudSupabaseHelpNote => '配置完成后需要注册/登录账号才能使用同步功能';

  @override
  String get cloudDetailedTutorial => '详细教程';

  @override
  String get cloudWebdavHelpTitle => 'WebDAV 配置说明';

  @override
  String get cloudWebdavHelpIntro => '什么是 WebDAV';

  @override
  String get cloudWebdavHelpIntro1 => 'WebDAV 是一种网络文件协议';

  @override
  String get cloudWebdavHelpIntro2 => '支持多种云盘和NAS设备';

  @override
  String get cloudWebdavHelpIntro3 => '数据存储在您自己的服务器上';

  @override
  String get cloudWebdavHelpProviders => '支持的服务商';

  @override
  String get cloudWebdavHelpProvider1 => '• 坚果云（推荐国内用户）';

  @override
  String get cloudWebdavHelpProvider2 => '• Nextcloud / ownCloud';

  @override
  String get cloudWebdavHelpProvider3 => '• 群晖 / 威联通 NAS';

  @override
  String get cloudWebdavHelpProvider4 => '• 其他支持 WebDAV 的服务';

  @override
  String get cloudWebdavHelpSteps => '配置步骤（以坚果云为例）';

  @override
  String get cloudWebdavHelpStep1 => '1. 登录坚果云网页版';

  @override
  String get cloudWebdavHelpStep2 => '2. 点击右上角账户名 > 账户信息';

  @override
  String get cloudWebdavHelpStep3 => '3. 选择「安全选项」标签';

  @override
  String get cloudWebdavHelpStep4 => '4. 添加应用密码（用于第三方应用）';

  @override
  String get cloudWebdavHelpStep5 => '5. 复制服务器地址、账号、应用密码';

  @override
  String get cloudWebdavHelpNote => '建议使用应用专用密码，而非账号密码';

  @override
  String get cloudS3HelpTitle => 'S3 存储配置说明';

  @override
  String get cloudS3HelpIntro => '什么是 S3';

  @override
  String get cloudS3HelpIntro1 => 'S3 是一种标准的对象存储协议';

  @override
  String get cloudS3HelpIntro2 => '支持多家云服务商';

  @override
  String get cloudS3HelpIntro3 => '数据存储在您选择的云服务中';

  @override
  String get cloudS3HelpProviders => '支持的服务商';

  @override
  String get cloudS3HelpProvider1 => '• AWS S3（Amazon Web Services）';

  @override
  String get cloudS3HelpProvider2 => '• Cloudflare R2（免费 10GB/月）';

  @override
  String get cloudS3HelpProvider3 => '• Backblaze B2（免费 10GB）';

  @override
  String get cloudS3HelpProvider4 => '• MinIO（自建服务）';

  @override
  String get cloudS3HelpProvider5 => '• 阿里云 OSS';

  @override
  String get cloudS3HelpProvider6 => '• 腾讯云 COS';

  @override
  String get cloudS3HelpProvider7 => '• 七牛云 Kodo';

  @override
  String get cloudS3HelpSteps => '配置步骤（以 Cloudflare R2 为例）';

  @override
  String get cloudS3HelpStep1 => '1. 登录 Cloudflare 控制台';

  @override
  String get cloudS3HelpStep2 => '2. 进入 R2 > 创建存储桶';

  @override
  String get cloudS3HelpStep3 => '3. 进入 R2 > 管理 R2 API 令牌';

  @override
  String get cloudS3HelpStep4 => '4. 创建 API 令牌并复制凭据';

  @override
  String get cloudS3HelpStep5 => '5. 粘贴端点、访问密钥、私密密钥和存储桶名称';

  @override
  String get cloudS3HelpNote => '推荐使用 Cloudflare R2，提供 10GB 免费存储且无流量费';

  @override
  String get cloudStatusNotTested => '未测试';

  @override
  String get cloudStatusNormal => '连接正常';

  @override
  String get cloudStatusFailed => '连接失败';

  @override
  String get cloudCannotOpenLink => '无法打开链接';

  @override
  String get cloudErrorAuthFailed => '认证失败: API Key 无效';

  @override
  String cloudErrorServerStatus(String code) {
    return '服务器返回状态码 $code';
  }

  @override
  String get cloudErrorWebdavNotSupported => '服务器不支持 WebDAV 协议';

  @override
  String get cloudErrorAuthFailedCredentials => '认证失败: 用户名或密码错误';

  @override
  String get cloudErrorAccessDenied => '访问被拒绝: 请检查权限';

  @override
  String cloudErrorPathNotFound(String path) {
    return '服务器路径不存在: $path';
  }

  @override
  String cloudErrorNetwork(String message) {
    return '网络错误: $message';
  }

  @override
  String get cloudTestSuccessTitle => '测试成功';

  @override
  String get cloudTestSuccessMessage => '连接正常,配置有效';

  @override
  String get cloudTestFailedTitle => '测试失败';

  @override
  String get cloudTestFailedMessage => '连接失败';

  @override
  String get cloudTestErrorTitle => '测试错误';

  @override
  String get cloudSwitchConfirmTitle => '切换云服务';

  @override
  String get cloudSwitchConfirmMessage =>
      '切换云服务将登出当前账号,确认切换?已保存的云服务凭据不会被删除,可随时切回。';

  @override
  String get cloudSwitchFailedTitle => '切换失败';

  @override
  String get cloudSwitchFailedConfigMissing => '请先配置该云服务';

  @override
  String get cloudConfigInvalidTitle => '配置无效';

  @override
  String get cloudConfigInvalidMessage => '请填写完整信息';

  @override
  String fieldCannotBeEmpty(String field) {
    return '$field不能为空';
  }

  @override
  String get cloudSaveFailed => '保存失败';

  @override
  String cloudSwitchedTo(String type) {
    return '已切换到$type';
  }

  @override
  String get cloudConfigureSupabaseTitle => '配置 Supabase';

  @override
  String get cloudConfigureWebdavTitle => '配置 WebDAV';

  @override
  String get cloudConfigureS3Title => '配置 S3';

  @override
  String get cloudSupabaseAnonKeyHintLong => '粘贴完整的 anon key';

  @override
  String get cloudWebdavRemotePathLabel => '远程路径';

  @override
  String get cloudWebdavRemotePathHelperText => '数据存储的远程目录路径';

  @override
  String get accountsTitle => '资产管理';

  @override
  String get accountsEmptyMessage => '还没有账户，点击右上角添加';

  @override
  String get accountAddTooltip => '添加账户';

  @override
  String get accountAddButton => '添加账户';

  @override
  String get accountBalance => '余额';

  @override
  String get accountEditTitle => '编辑账户';

  @override
  String get accountNewTitle => '新建账户';

  @override
  String get accountNameLabel => '账户名称';

  @override
  String get accountNameHint => '例如：工商银行、支付宝等';

  @override
  String get accountNameRequired => '请输入账户名称';

  @override
  String get accountNameDuplicate => '账户名称已存在，请使用其他名称';

  @override
  String get accountTypeCash => '现金';

  @override
  String get accountTypeBankCard => '银行卡';

  @override
  String get accountTypeCreditCard => '信用卡';

  @override
  String get accountTypeAlipay => '支付宝';

  @override
  String get accountTypeWechat => '微信';

  @override
  String get accountTypeOther => '其他';

  @override
  String get accountInitialBalance => '初始资金';

  @override
  String get accountInitialBalanceHint => '请输入初始资金（可选）';

  @override
  String get accountDeleteWarningTitle => '确认删除';

  @override
  String accountDeleteWarningMessage(int count) {
    return '该账户有 $count 笔关联交易，删除后交易记录中的账户信息将被清空。确认删除吗？';
  }

  @override
  String get accountDeleteConfirm => '确认删除该账户吗？';

  @override
  String get accountDeleteReconfirmMessage =>
      '再次确认：删除后该账户不可恢复，已保存的账户信息将永久丢失。确定要继续吗？';

  @override
  String get accountSelectTitle => '选择账户';

  @override
  String get accountNone => '不选择账户';

  @override
  String get accountsEnableFeature => '启用账户功能';

  @override
  String get accountHide => '隐藏账户';

  @override
  String get accountUnhide => '恢复账户';

  @override
  String get accountRestore => '恢复';

  @override
  String get accountHiddenTag => '已隐藏';

  @override
  String accountHiddenSectionSummary(int count, String total) {
    return '已隐藏 $count · 合计 $total';
  }

  @override
  String get accountHideConfirmTitle => '隐藏此账户？';

  @override
  String get accountHideConfirmBody => '隐藏后无法再记账到它，新增记账时也不再显示；历史交易与余额保留，可随时恢复。';

  @override
  String accountHideRecurringWarn(int count) {
    return '有 $count 个周期账单在用此账户，隐藏后这些账单将跳过生成，建议先改到其他账户。';
  }

  @override
  String get accountHideClearedDefault => '已取消其默认账户设置';

  @override
  String get accountHiddenToast => '已隐藏';

  @override
  String get accountRestoredToast => '已恢复';

  @override
  String get privacyOpenSourceUrlError => '无法打开链接';

  @override
  String get updateCorruptedFileTitle => '安装包已损坏';

  @override
  String get updateCorruptedFileMessage => '检测到之前下载的安装包不完整或已损坏，是否删除并重新下载？';

  @override
  String get welcomeTitle => '欢迎使用 PiggyCount';

  @override
  String get welcomeDescription => '一个真正尊重您隐私的记账应用';

  @override
  String get welcomeCurrencyDescription => '选择您常用的货币，之后可以随时在设置中更改';

  @override
  String get welcomeCreateDefaultLedger => '创建默认账本';

  @override
  String get welcomePrivacyTitle => '开源透明 · 社群驱动';

  @override
  String get welcomePrivacyFeature1 => '100% 开源代码，接受社区监督';

  @override
  String get welcomePrivacyFeature2 => '无隐私顾虑，数据完全本地存储';

  @override
  String get welcomeOpenSourceFeature1 => '活跃的开发者社群，持续改进';

  @override
  String get welcomeViewGitHub => '访问 GitHub 仓库';

  @override
  String get welcomeCloudSyncTitle => '可选的云同步';

  @override
  String get welcomeCloudSyncDescription => 'PiggyCount 支持多种同步方式，数据完全由你掌控';

  @override
  String get welcomeCloudSyncFeature1 => '完全离线使用，无需云服务';

  @override
  String get welcomeCloudSyncFeature2 => '多设备快照同步，数据存在你自己的云盘';

  @override
  String get welcomeCloudSyncFeature3 => 'iCloud / WebDAV / Supabase / S3 任选';

  @override
  String get widgetManagement => '桌面小组件';

  @override
  String get widgetManagementDesc => '在主屏幕快速查看收支情况';

  @override
  String get widgetGalleryTitle => '组件库';

  @override
  String get widgetGalleryDesc => '以下为示例效果，实际将显示当前账本的真实数据，主题色跟随 App 设置';

  @override
  String get widgetGalleryGlanceTitle => '收支速览';

  @override
  String get widgetGalleryGlanceDesc => '今日和本月收支一目了然';

  @override
  String get widgetGalleryNetWorthDesc => '总资产、总负债与净值趋势';

  @override
  String get widgetGalleryQuickAddTitle => '快速记账';

  @override
  String get widgetGalleryQuickAddDesc => '常用分类一键速记';

  @override
  String get widgetGalleryBudgetDesc => '预算进度实时掌握';

  @override
  String get widgetGalleryRecentDesc => '快速查看最近几笔账单';

  @override
  String get widgetGalleryDashboardTitle => '综合仪表盘';

  @override
  String get widgetDashboardTitle => '本月概览';

  @override
  String get widgetGalleryDashboardDesc => '收支、趋势与最近交易一屏看尽';

  @override
  String get widgetSizeSmall => '小号';

  @override
  String get widgetSizeMedium => '中号';

  @override
  String get widgetSizeLarge => '大号';

  @override
  String get howToAddWidget => '如何添加小组件';

  @override
  String get iosWidgetStep1 => '长按主屏幕空白区域，进入编辑模式';

  @override
  String get iosWidgetStep2 => '点击左上角的\"+\"按钮';

  @override
  String get iosWidgetStep3 => '搜索并选择\"小猪记账\"';

  @override
  String get iosWidgetStep4 => '选择中型小组件，添加到主屏幕';

  @override
  String get androidWidgetStep1 => '长按主屏幕空白区域';

  @override
  String get androidWidgetStep2 => '选择\"小组件\"或\"Widgets\"';

  @override
  String get androidWidgetStep3 => '找到并长按\"小猪记账\"小组件';

  @override
  String get androidWidgetStep4 => '拖动到主屏幕合适位置';

  @override
  String get aboutWidget => '关于小组件';

  @override
  String get widgetDescription =>
      '小组件会自动同步显示今日和本月的收支数据，每30分钟自动刷新一次。打开应用后会立即更新数据。';

  @override
  String get widgetQuickEntryTitle => '快捷记账';

  @override
  String get widgetQuickEntryDesc =>
      '点击小组件左侧区域可快速新建支出，点击右侧区域可快速新建收入。也可通过快捷指令使用 piggycount://new?type=transfer 快速发起转账。';

  @override
  String get appName => '小猪记账';

  @override
  String get autoScreenshotBilling => '截图自动记账';

  @override
  String get autoScreenshotBillingDesc => '截图后自动识别支付信息';

  @override
  String get autoScreenshotBillingTitle => '截图自动记账';

  @override
  String get featureDescription => '功能说明';

  @override
  String get featureDescriptionContent =>
      '截图支付页面后，系统会自动识别金额和商家信息，并创建支出记录。\n\n⚡ 识别速度约 2-3 秒（部分设备可能更长）\n🤖 智能匹配分类\n📝 自动填写备注\n\n⚠️ 注意：\n• 不同设备截图入库速度不同，识别延迟可能 5-10 秒\n• 部分设备可能无法正常工作，取决于系统实现\n• 识别成功后会自动跳过已处理的截图\n• 受Android分区存储限制（Android 10+），应用无法删除系统截图，需手动清理相册';

  @override
  String get autoBilling => '自动记账';

  @override
  String get enabled => '已启用';

  @override
  String get disabled => '已禁用';

  @override
  String get photosPermissionRequired => '需要照片权限才能监听截图';

  @override
  String get enableSuccess => '自动记账已启用';

  @override
  String get disableSuccess => '自动记账已禁用';

  @override
  String get autoBillingBatteryTitle => '保持后台运行';

  @override
  String get autoBillingBatteryGuideTitle => '电池优化设置';

  @override
  String get autoBillingBatteryDesc =>
      '自动记账需要应用在后台保持运行。部分手机会在锁屏后自动清理后台应用，导致自动记账功能失效。建议关闭电池优化以确保功能正常工作。';

  @override
  String get autoBillingCheckBattery => '检查电池优化状态';

  @override
  String get autoBillingBatteryWarning =>
      '⚠️ 未关闭电池优化，应用可能会被系统自动清理，导致自动记账失效。建议点击上方\"去设置\"按钮关闭电池优化。';

  @override
  String get enableFailed => '启用失败';

  @override
  String get disableFailed => '禁用失败';

  @override
  String get iosAutoFeatureDesc =>
      '通过iOS\"快捷指令\"应用，实现截图后自动识别支付信息并记账。设置后，每次截图都会自动触发识别。';

  @override
  String get iosAutoShortcutConfigTitle => '配置步骤：';

  @override
  String get iosAutoShortcutStep1 => '打开\"快捷指令\"应用，点击右上角\"+\"创建新快捷指令';

  @override
  String get iosAutoShortcutStep2 => '添加\"截屏\"操作';

  @override
  String get iosAutoShortcutStep3 => '搜索并添加\"小猪记账 - 截图自动记账\"操作';

  @override
  String get iosAutoShortcutStep4 => '将\"小猪记账\"的截图参数设置为上一步的\"截屏\"';

  @override
  String get iosAutoShortcutStep5 => '（可选）在系统设置 > 辅助功能 > 触控 > 轻点背面中，绑定此快捷指令';

  @override
  String get iosAutoShortcutStep6 => '完成！支付时双击手机背部即可快速记账';

  @override
  String get iosAutoShortcutRecommendedTip =>
      '✅ 推荐：在\"轻点背面\"中绑定快捷指令后，支付时双击手机背部即可自动截图并识别记账，无需手动截图。';

  @override
  String get iosAutoBackTapTitle => '💡 双击背部快速触发（推荐）';

  @override
  String get iosAutoBackTapDesc =>
      '设置 > 辅助功能 > 触控 > 轻点背面\n• 选择\"轻点两下\"或\"轻点三下\"\n• 选择刚创建的快捷指令\n• 完成后，支付时双击手机背面即可自动记账，无需截图';

  @override
  String get iosAutoTutorialTitle => '视频教程';

  @override
  String get iosAutoTutorialDesc => '查看详细配置视频教程';

  @override
  String get iosAutoImportTitle => '一键获取快捷指令';

  @override
  String get iosAutoImportDesc =>
      '点击下方按钮，自动导入已配置好的「截屏 → 自动记账」快捷指令，无需手动添加“截屏”操作和连接参数。导入后建议在「轻点背面」中绑定它。';

  @override
  String get iosAutoImportButton => '获取快捷指令';

  @override
  String get iosAutoImportFailed => '无法打开快捷指令链接，请检查网络后重试';

  @override
  String get iosAutoManualConfigTitle => '手动配置（高级）';

  @override
  String get iosAutoManualConfigDesc => '若一键导入不可用，可按以下步骤手动创建快捷指令。';

  @override
  String get aiSettingsTitle => 'AI小助手';

  @override
  String get aiSettingsSubtitle => '配置AI模型和识别策略';

  @override
  String get aiEnableTitle => '启用AI小助手';

  @override
  String get aiEnableSubtitle => '使用 AI 视觉识别账单截图,提取金额、商家、时间等信息,并支持自然语言对话';

  @override
  String get aiEnableToastOn => 'AI小助手已启用';

  @override
  String get aiEnableToastOff => 'AI小助手已关闭';

  @override
  String get aiStrategyTitle => '执行策略';

  @override
  String get aiStrategyLocalFirst => '本地优先（推荐）';

  @override
  String get aiStrategyCloudFirst => '云端优先';

  @override
  String get aiStrategyCloudFirstDesc => '优先使用云端API，失败后降级到本地';

  @override
  String get aiStrategyLocalOnly => '仅本地';

  @override
  String get aiStrategyCloudOnly => '仅云端';

  @override
  String get aiStrategyCloudOnlyDesc => '只使用云端API，不下载模型';

  @override
  String get aiStrategyUnavailable => '本地模型训练中，敬请期待';

  @override
  String aiStrategySwitched(String strategy) {
    return '已切换: $strategy';
  }

  @override
  String get aiCloudApiKeyHintCustom => '输入API Key';

  @override
  String get aiCloudApiKeyHelper => 'GLM-*-Flash模型完全免费';

  @override
  String get aiCloudApiGetKey => '获取API Key';

  @override
  String get aiCloudApiTutorial => '详细教程';

  @override
  String get aiCloudApiTestKey => '测试连接';

  @override
  String get aiChatConfigWarning => '未配置 AI 服务商，请先在设置中添加并绑定';

  @override
  String get aiChatGoToSettings => '去设置';

  @override
  String get aiOcrRecognizing => '正在识别账单...';

  @override
  String get aiNotConfiguredHint => '未配置 AI 服务，请前往「我的 → AI 设置」配置';

  @override
  String get aiOcrCheckLog => '识别失败，请查看日志了解详情';

  @override
  String get aiOcrNoBill => '未识别到账单信息，请确认图片是账单后重试';

  @override
  String get aiNotConfiguredNotificationTitle => '❌ 无法识别截图';

  @override
  String get aiNotConfiguredNotificationBody => '未配置 AI 服务，点击前往设置';

  @override
  String get autoBillingNotifyDetectedTitle => '✅ 检测到截图';

  @override
  String get autoBillingNotifyWaitingFileBody => '正在等待文件写入...';

  @override
  String get autoBillingNotifyRecognizingScreenshotTitle => '正在识别截图...';

  @override
  String get autoBillingNotifyVisionAnalyzingBody => '正在调用 AI 视觉分析支付信息，请稍候';

  @override
  String get autoBillingNotifyRecognizingTextTitle => '⏳ 正在识别';

  @override
  String get autoBillingNotifyTextAnalyzingBody => '正在调用 AI 解析支付信息...';

  @override
  String get autoBillingNotifyRecognizeFailedTitle => '❌ 识别失败';

  @override
  String get autoBillingNotifyRecognizeFailedBody => '无法从截图提取账单信息，请检查 AI 配置或图片';

  @override
  String get autoBillingNotifyNoBillTitle => '未识别到账单';

  @override
  String get autoBillingNotifyNoBillBody => '这张截图未识别到账单信息，可能不是账单';

  @override
  String get autoBillingNotifyFileUnavailableTitle => '识别失败';

  @override
  String get autoBillingNotifyFileUnavailableBody => '截图文件不可用';

  @override
  String get autoBillingNotifyNoLedgerTitle => '❌ 自动记账失败';

  @override
  String get autoBillingNotifyNoLedgerBody => '无可用账本，请先创建账本';

  @override
  String get autoBillingNotifyNoAmountBody => '未能识别出金额信息';

  @override
  String get autoBillingNotifyProcessFailedTitle => '❌ 处理失败';

  @override
  String autoBillingNotifyProcessFailedBody(String error) {
    return '错误：$error';
  }

  @override
  String autoBillingNotifySuccessSingleTitle(String amount) {
    return '✅ 自动记账成功 ¥$amount';
  }

  @override
  String autoBillingNotifySuccessMultiTitle(int count) {
    return '✅ 自动记账成功 $count 笔';
  }

  @override
  String autoBillingNotifySuccessMultiBody(String amount) {
    return '合计 ¥$amount';
  }

  @override
  String autoBillingNotifySuccessSingleBodyNote(String note) {
    return '备注：$note';
  }

  @override
  String get autoBillingNotifySuccessSingleBodyDefault => '已自动创建记录';

  @override
  String get aiOcrNoLedger => '未找到账本';

  @override
  String aiOcrSuccess(String type, String amount) {
    return '✅ $type账单创建成功 ¥$amount';
  }

  @override
  String aiOcrFailed(String error) {
    return '识别失败: $error';
  }

  @override
  String get aiTypeIncome => '收入';

  @override
  String get aiTypeExpense => '支出';

  @override
  String get cloudSyncPageTitle => '云同步';

  @override
  String get cloudSyncPageSubtitle => '手动上传和下载账本数据';

  @override
  String get cloudSyncHint =>
      '下载时可自动对比差异并逐条预览。非实时同步，请避免多设备同时编辑同一账本。同步范围为账本数据（含关联的账户、分类、标签），不含附件。';

  @override
  String get dataManagement => '数据管理';

  @override
  String get dataManagementDesc => '导入导出、分类账户管理';

  @override
  String get dataManagementPageTitle => '数据管理';

  @override
  String get dataManagementAttachmentHint =>
      '还原数据时，请先导入附件包，再导入账本数据（CSV或云同步），以确保附件正确关联。';

  @override
  String get smartBilling => '智能记账';

  @override
  String get smartBillingDesc => 'AI 助手、智能识别、自动记账';

  @override
  String get smartBillingPageTitle => '智能记账';

  @override
  String get smartBillingGuideHint => '长按首页底部中间的 + 按钮，即可快速使用这些功能';

  @override
  String get smartBillingImageBilling => '图片记账';

  @override
  String get smartBillingImageBillingDesc => '从相册选择支付截图进行识别';

  @override
  String get smartBillingImageBillingGuide =>
      '在首页长按底部中间的 + 按钮,选择「相册」即可使用图片记账功能。需先在「我的 → AI 设置」配置 AI 服务,AI 视觉模型会自动识别金额、商家、时间等账单信息。';

  @override
  String get smartBillingVisionAIRequired =>
      '图片识别必须配置 AI 视觉服务，请先在「我的 → AI 设置」中配置';

  @override
  String get smartBillingCameraBilling => '拍照记账';

  @override
  String get smartBillingCameraBillingDesc => '拍摄支付截图进行识别';

  @override
  String get smartBillingCameraBillingGuide =>
      '在首页长按底部中间的 + 按钮,选择「拍照」即可使用拍照记账功能。需先在「我的 → AI 设置」配置 AI 服务,AI 视觉模型会自动识别金额、商家、时间等账单信息。';

  @override
  String get smartBillingVoiceBilling => '语音记账';

  @override
  String get smartBillingVoiceBillingDesc => '通过语音输入快速记账';

  @override
  String get smartBillingVoiceBillingGuide =>
      '在首页长按底部中间的 + 按钮，选择「语音」即可使用语音记账功能。语音记账需要通过AI将语音转为文字并提取账单信息。';

  @override
  String get smartBillingAIRequired => '语音记账必须配置 AI 语音识别服务，请先在「我的 → AI 设置」中配置';

  @override
  String get smartBillingAutoTags => '自动关联标签';

  @override
  String get smartBillingAutoTagsDesc => '智能记账时自动根据分类关联常用标签';

  @override
  String get smartBillingAutoAttachment => '自动添加附件';

  @override
  String get smartBillingAutoAttachmentDesc => '图片/拍照记账时自动将原图添加为附件';

  @override
  String get autoScreenshotBillingIosTitle => '自动记账';

  @override
  String get autoScreenshotBillingIosDesc => '通过快捷指令自动识别支付信息记账';

  @override
  String get shareBilling => '分享记账';

  @override
  String get shareBillingDesc => '从支付宝/微信分享支付截图即可记账';

  @override
  String get shareBillingGuide =>
      '在支付宝、微信、相册等应用中看到支付截图时，点击「分享」并选择「小猪记账」，即可自动识别金额、商家、时间等信息并记账，无需先保存截图。';

  @override
  String get shareBillingActionHint => '分享后会在后台自动识别记账，无需手动打开小猪记账';

  @override
  String get automation => '自动化';

  @override
  String get automationDesc => '周期记账、记账提醒';

  @override
  String get automationPageTitle => '自动化功能';

  @override
  String get appearanceSettings => '个性化设置';

  @override
  String get appearanceSettingsDesc => '主题、字体、语言、应用锁等';

  @override
  String get appearanceSettingsPageTitle => '个性化设置';

  @override
  String get about => '关于';

  @override
  String get aboutDesc => '版本信息';

  @override
  String get mineRateApp => '给应用评分';

  @override
  String get mineRateAppSubtitle => '在App Store上为我们打分';

  @override
  String get aboutPageTitle => '关于';

  @override
  String get aboutPageLoadingVersion => '加载版本号中...';

  @override
  String get aboutDeveloperStoryTitle => '开发者的话';

  @override
  String get aboutDeveloperStory =>
      '从 2015 年实习起，我坚持记账至今已超过十年。因为担心记账软件的广告、付费、隐私泄露和停运跑路，我决定自己做一个——最初只是给自己和家人用的小工具。\n\n2025 年 9 月，小猪记账发布了第一个版本。说实话，那时候心里没什么底，不知道会不会有人用。但慢慢地，开始收到用户的反馈——有人说终于找到了一款干净的记账软件，有人提了很好的建议，也有人默默给了五星好评。每一条反馈都让我觉得，这件事值得继续做下去。\n\n小猪记账没有广告、没有会员、完全免费开源。你的每一笔数据都只存在你自己的手机里，不会被上传到任何第三方服务器。但上架和维护一款 App 并非零成本——开发者账号、服务器等开支目前靠社区捐赠勉强支撑，每一次适配新系统、修复 Bug、开发新功能，也都是工作之余一点点完成的。\n\n如果你觉得小猪记账对你有帮助，一个好评、一次分享或一笔捐赠，都能让这个小项目走得更远。谢谢你的信任。';

  @override
  String get aboutPiggyAssets => '小猪家当 PiggyAssets';

  @override
  String get aboutPiggyAssetsSubtitle => '可视化你的全部资产配置';

  @override
  String get aboutPiggyAssetsIntro =>
      '小猪记账侧重日常流水,小猪家当是它的姐妹产品,专注资产配置可视化:跨账户净资产趋势、房产 / 投资 / 加密资产分类、收益率与持仓时长、配置占比一目了然。';

  @override
  String get aboutPiggyDNS => '小猪域名 PiggyDNS';

  @override
  String get aboutPiggyDNSSubtitle => '简洁高效的 DNS 管理工具';

  @override
  String get aboutPiggyDNSIntro =>
      '如果你的域名分散在 Cloudflare 和阿里云,小猪域名把它们聚合在一处管理:批量改记录、A/AAAA 切换、解析迁移、子域名批量管理 — 不用在两家控制台来回切。';

  @override
  String get productPromoAndroidTitle => '申请加入内测';

  @override
  String get productPromoAndroidMessage =>
      '这款 App 还在 Google Play 内测阶段,需要邀请才能下载。\n\n申请方式:发邮件给我们,告诉我们你的 Google 账号邮箱(必填),以及简单说明使用场景(可选)。我们会在 1-3 天内回复并加你到内测白名单。';

  @override
  String get productPromoOpenStore => '前往应用商店';

  @override
  String get productPromoTestFlight => 'TestFlight 内测';

  @override
  String get productPromoEmailLabel => '申请邮箱(点击复制)';

  @override
  String get productPromoCopiedToast => '邮箱已复制到剪贴板';

  @override
  String get productPromoMailUnavailable => '未检测到邮件应用,邮箱已复制到剪贴板,请打开任意邮件应用粘贴发送';

  @override
  String get productPromoEmailButton => '发送邮件';

  @override
  String get productPromoWebsiteButton => '前往官网';

  @override
  String productPromoEmailSubject(String productName) {
    return '申请内测 - $productName';
  }

  @override
  String productPromoEmailBody(String productName) {
    return '你好,\n\n我希望加入「$productName」的 Google Play 内测,我的 Google 账号邮箱是:\n\n(请填写你的 Gmail / Google 账号邮箱)\n\n谢谢!';
  }

  @override
  String get logCenterTitle => '日志中心';

  @override
  String get logCenterSubtitle => '查看应用运行日志';

  @override
  String get logCenterSearchHint => '搜索日志内容或标签...';

  @override
  String get logCenterFilterLevel => '日志级别';

  @override
  String get logCenterFilterPlatform => '平台';

  @override
  String get logCenterTotal => '全部';

  @override
  String get logCenterFiltered => '已过滤';

  @override
  String get logCenterEmpty => '暂无日志';

  @override
  String get logCenterExport => '导出';

  @override
  String get logCenterClear => '清空';

  @override
  String get logCenterExportFailed => '导出失败';

  @override
  String get logCenterClearConfirmTitle => '清空日志';

  @override
  String get logCenterClearConfirmMessage => '确定要清空所有日志吗？此操作不可恢复。';

  @override
  String get logCenterCleared => '日志已清空';

  @override
  String get logCenterCopied => '已复制到剪贴板';

  @override
  String get configImportExportTitle => '配置导入导出';

  @override
  String get configImportExportSubtitle => '备份和恢复应用配置';

  @override
  String get configImportExportInfoTitle => '功能说明';

  @override
  String get configImportExportInfoMessage =>
      '此功能用于导出和导入应用配置，包括云服务配置、AI配置等。配置文件采用YAML格式，方便查看和编辑。\n\n⚠️ 配置文件包含敏感信息（如API密钥、密码等），请妥善保管。';

  @override
  String get configExportTitle => '导出配置';

  @override
  String get configExportSubtitle => '将当前配置导出为YAML文件';

  @override
  String get configExportShareSubject => 'PiggyCount 配置文件';

  @override
  String get configExportSuccess => '配置导出成功';

  @override
  String get configExportFailed => '配置导出失败';

  @override
  String get configImportTitle => '导入配置';

  @override
  String get configImportSubtitle => '从YAML文件恢复配置';

  @override
  String get configImportNoFilePath => '未选择文件';

  @override
  String get configImportConfirmTitle => '确认导入';

  @override
  String get configImportReconfirmTitle => '确认导入';

  @override
  String get configImportReconfirmMessage =>
      '再次确认：导入将覆盖现有配置且不可恢复，建议先备份。确定要继续吗？';

  @override
  String get configImportSuccess => '配置导入成功';

  @override
  String get configImportFailed => '配置导入失败';

  @override
  String get configImportRestartTitle => '需要重启';

  @override
  String get configImportRestartMessage => '配置已导入，部分配置需要重启应用后生效。';

  @override
  String get configImportExportIncludesTitle => '包含的配置项';

  @override
  String configExportSavedTo(String path) {
    return '已保存至: $path';
  }

  @override
  String get configExportViewContent => '查看内容';

  @override
  String get configExportCopyContent => '复制内容';

  @override
  String get configExportContentCopied => '已复制到剪贴板';

  @override
  String get configExportReadFileFailed => '读取文件失败';

  @override
  String get configIncludeLedgers => '账本';

  @override
  String get configIncludeSupabase => 'Supabase 云服务配置';

  @override
  String get configIncludeWebdav => 'WebDAV 云服务配置';

  @override
  String get configIncludeS3 => 'S3 云服务配置';

  @override
  String get configIncludeAI => 'AI 智能识别配置';

  @override
  String get configIncludeAISubtitle => '服务商、能力绑定、模型设置等';

  @override
  String get configIncludeAppSettings => '应用设置（语言、外观、提醒、默认账户等）';

  @override
  String get configIncludeRecurringTransactions => '周期账单';

  @override
  String get configIncludeAccounts => '账户';

  @override
  String get configIncludeCategories => '分类';

  @override
  String get configIncludeTags => '标签';

  @override
  String get configIncludeBudgets => '预算';

  @override
  String get configIncludeOtherSettings => '其他设置';

  @override
  String get configIncludeOtherSettingsSubtitle => '包含云服务配置、AI配置、应用设置等';

  @override
  String get configExportSelectTitle => '选择导出内容';

  @override
  String get configExportPreviewTitle => '导出预览';

  @override
  String get configExportConfirmTitle => '确认导出';

  @override
  String get configImportSelectTitle => '选择导入内容';

  @override
  String get configImportPreviewTitle => '导入预览';

  @override
  String get ledgersConflictTitle => '同步冲突';

  @override
  String get ledgersConflictMessage => '本地和云端账本数据不一致，请选择操作：';

  @override
  String ledgersConflictLocalInfo(int count) {
    return '本地：$count 笔账单';
  }

  @override
  String ledgersConflictRemoteInfo(int count) {
    return '云端：$count 笔账单';
  }

  @override
  String ledgersConflictRemoteUpdated(String time) {
    return '云端更新：$time';
  }

  @override
  String ledgersConflictLocalFingerprint(String fp) {
    return '本地指纹：$fp';
  }

  @override
  String ledgersConflictRemoteFingerprint(String fp) {
    return '云端指纹：$fp';
  }

  @override
  String get ledgersConflictUpload => '上传到云端';

  @override
  String get ledgersConflictDownload => '下载到本地';

  @override
  String get ledgersConflictUploading => '正在上传...';

  @override
  String get ledgersConflictDownloading => '正在下载...';

  @override
  String get ledgersConflictUploadSuccess => '上传成功';

  @override
  String ledgersConflictDownloadSuccess(int inserted) {
    return '下载成功，已合并 $inserted 笔账单';
  }

  @override
  String get storageManagementTitle => '存储空间管理';

  @override
  String get storageManagementSubtitle => '清理缓存释放空间';

  @override
  String get storageAIModels => 'AI模型';

  @override
  String get storageAPKFiles => '安装包';

  @override
  String get storageNoData => '无数据';

  @override
  String get storageFiles => '个文件';

  @override
  String get storageHint => '点击项目可清理对应的缓存文件';

  @override
  String get storageClearConfirmTitle => '确认清理';

  @override
  String storageClearAIModelsMessage(String size) {
    return '确定要清理所有AI模型吗？大小: $size';
  }

  @override
  String get storageClearReconfirmMessage => '再次确认：清理后需要重新下载，确定要继续吗？';

  @override
  String storageClearAPKMessage(String size) {
    return '确定要清理所有安装包吗？大小: $size';
  }

  @override
  String get storageClearSuccess => '清理成功';

  @override
  String get accountNoTransactions => '暂无交易记录';

  @override
  String get accountTransactionHistory => '交易记录';

  @override
  String get accountTotalBalance => '净资产';

  @override
  String get accountCurrencyLocked => '该账户已有交易记录，不允许修改币种';

  @override
  String get accountDefaultIncomeTitle => '默认收入账户';

  @override
  String get accountDefaultExpenseTitle => '默认支出账户';

  @override
  String get accountDefaultNone => '不设置';

  @override
  String get commonNotice => '提示';

  @override
  String get transferTitle => '转账';

  @override
  String get transferIconSettings => '转账图标设置';

  @override
  String get transferIconSettingsDesc => '自定义转账记录的显示图标';

  @override
  String get transferFromAccount => '转出账户';

  @override
  String get transferToAccount => '转入账户';

  @override
  String get transferSelectAccount => '选择账户';

  @override
  String get transferCreateSuccess => '转账创建成功';

  @override
  String get transferUpdateSuccess => '转账更新成功';

  @override
  String get transferDifferentCurrencyError => '转账仅支持相同币种的账户';

  @override
  String get transferToPrefix => '转账至';

  @override
  String get transferFromPrefix => '来自';

  @override
  String get welcomeCategoryModeTitle => '选择分类模式';

  @override
  String get welcomeCategoryModeDescription => '选择更适合您使用习惯的分类方式';

  @override
  String get welcomeCategoryModeFlatTitle => '一级分类';

  @override
  String get welcomeCategoryModeFlatDescription => '简单直观，快速记账';

  @override
  String get welcomeCategoryModeFlatFeature1 => '扁平化结构，操作简单';

  @override
  String get welcomeCategoryModeFlatFeature2 => '适合习惯简单分类的用户';

  @override
  String get welcomeCategoryModeFlatFeature3 => '快速选择，高效记账';

  @override
  String get welcomeCategoryModeHierarchicalTitle => '二级分类';

  @override
  String get welcomeCategoryModeHierarchicalDescription => '精细管理，清晰明了';

  @override
  String get welcomeCategoryModeHierarchicalFeature1 => '支持父子分类层级';

  @override
  String get welcomeCategoryModeHierarchicalFeature2 => '更细致的账单归类';

  @override
  String get welcomeCategoryModeHierarchicalFeature3 => '适合需要精细管理的用户';

  @override
  String get welcomeCategoryModeNoneTitle => '不创建分类';

  @override
  String get welcomeCategoryModeNoneDescription => '完全自定义，按需添加';

  @override
  String get welcomeCategoryModeNoneFeature1 => '不预置任何分类';

  @override
  String get welcomeCategoryModeNoneFeature2 => '完全按自己需求创建';

  @override
  String get welcomeCategoryModeNoneFeature3 => '适合有特殊分类需求的用户';

  @override
  String get welcomeExistingUserTitle => '老用户？';

  @override
  String get welcomeExistingUserButton => '导入配置';

  @override
  String get welcomeImportingConfig => '正在导入配置...';

  @override
  String get welcomeImportSuccess => '配置导入成功';

  @override
  String welcomeImportFailed(String error) {
    return '配置导入失败: $error';
  }

  @override
  String get welcomeImportNoFile => '未选择文件';

  @override
  String get welcomeImportAttachmentTitle => '导入附件';

  @override
  String get welcomeImportAttachmentDesc => '检测到您导入了配置文件，是否需要导入附件文件？';

  @override
  String get welcomeImportAttachmentButton => '选择附件文件';

  @override
  String get welcomeImportAttachmentSkip => '跳过';

  @override
  String welcomeImportAttachmentSuccess(int imported) {
    return '附件导入完成：导入 $imported 个';
  }

  @override
  String welcomeImportAttachmentFailed(String error) {
    return '附件导入失败: $error';
  }

  @override
  String get welcomeImportingAttachment => '正在导入附件...';

  @override
  String get iosVersionWarningTitle => '需要 iOS 16.0 或更高版本';

  @override
  String get iosVersionWarningDesc =>
      '截图自动记账功能使用了 iOS 16 引入的 App Intents 框架。您的设备系统版本较低，暂不支持此功能。\n\n请升级到 iOS 16 或更高版本以使用此功能。';

  @override
  String get aiChatTitle => 'AI助手';

  @override
  String get aiChatClearHistory => '清除对话历史';

  @override
  String get aiChatClearHistoryDialogTitle => '清除对话历史';

  @override
  String get aiChatClearHistoryDialogContent => '确定要清除所有对话记录吗?此操作不可恢复。';

  @override
  String get aiChatInputHint => '例如: 买了杯咖啡35块';

  @override
  String get aiChatThinking => '思考中...';

  @override
  String get aiChatHistoryCleared => '对话历史已清空';

  @override
  String get aiChatCopy => '复制';

  @override
  String get aiChatCopied => '已复制到剪贴板';

  @override
  String get aiChatDeleteMessageConfirm => '确定要删除这条消息吗？';

  @override
  String get aiChatMessageDeleted => '消息已删除';

  @override
  String get aiChatUndone => '已撤销';

  @override
  String get aiChatUndoFailed => '撤销失败';

  @override
  String get aiChatTransactionNotFound => '交易记录不存在';

  @override
  String get aiChatOpenEditorFailed => '打开编辑页面失败';

  @override
  String get aiChatSendFailed => '发送失败';

  @override
  String get billCardSuccess => '记账成功';

  @override
  String get billCardUndone => '已撤销';

  @override
  String get billCardAmount => '💰 金额';

  @override
  String get billCardCategory => '🏷️ 分类';

  @override
  String get billCardTime => '📅 时间';

  @override
  String get billCardNote => '📝 备注';

  @override
  String get billCardAccount => '💳 账户';

  @override
  String get billCardUndo => '撤销';

  @override
  String get billCardEdit => '修改';

  @override
  String get aiQuickCommandFinancialHealthTitle => '财务健康分析';

  @override
  String get aiQuickCommandFinancialHealthDesc => '分析收支平衡和储蓄率';

  @override
  String get aiQuickCommandFinancialHealthPrompt =>
      '请根据以下数据分析我的财务健康状况：\n\n[monthlyStats]\n\n[recentTrends]\n\n请从收支平衡、储蓄率、消费趋势等角度给出专业分析和建议。请用简体中文回复。';

  @override
  String get aiQuickCommandMonthlyExpenseTitle => '本月支出总结';

  @override
  String get aiQuickCommandMonthlyExpenseDesc => '月度支出分析和建议';

  @override
  String get aiQuickCommandMonthlyExpensePrompt =>
      '请总结我本月的支出情况：\n\n[monthlyStats]\n\n[categoryStats]\n\n请分析主要支出类别，并给出节约开支的建议。请用简体中文回复。';

  @override
  String get aiQuickCommandCategoryAnalysisTitle => '分类占比分析';

  @override
  String get aiQuickCommandCategoryAnalysisDesc => '各分类支出占比和趋势';

  @override
  String get aiQuickCommandCategoryAnalysisPrompt =>
      '请分析我的各分类支出占比：\n\n[categoryStats]\n\n请指出哪些分类支出过高，并给出优化建议。请用简体中文回复。';

  @override
  String get aiQuickCommandBudgetPlanningTitle => '预算规划建议';

  @override
  String get aiQuickCommandBudgetPlanningDesc => '基于历史数据的预算建议';

  @override
  String get aiQuickCommandBudgetPlanningPrompt =>
      '请基于以下数据帮我制定下月预算：\n\n[monthlyStats]\n\n[recentTrends]\n\n请给出各分类的预算建议和注意事项。请用简体中文回复。';

  @override
  String get aiQuickCommandAbnormalExpenseTitle => '异常支出提醒';

  @override
  String get aiQuickCommandAbnormalExpenseDesc => '识别大额或异常支出';

  @override
  String get aiQuickCommandAbnormalExpensePrompt =>
      '请检查我最近是否有异常支出：\n\n[recentTransactions]\n\n[monthlyStats]\n\n请指出可能的异常消费，并分析原因。请用简体中文回复。';

  @override
  String get aiQuickCommandSavingTipsTitle => '省钱小贴士';

  @override
  String get aiQuickCommandSavingTipsDesc => '根据消费习惯给建议';

  @override
  String get aiQuickCommandSavingTipsPrompt =>
      '请根据我的消费习惯给出省钱建议：\n\n[categoryStats]\n\n[recentTrends]\n\n请提供3-5条实用的省钱技巧。请用简体中文回复。';

  @override
  String get billCardUnknownLedger => '未知账本';

  @override
  String get aiPromptEditTitle => '提示词编辑';

  @override
  String get aiPromptEditSubtitle => '自定义AI账单识别提示词';

  @override
  String get aiPromptAdvancedSettings => '高级设置';

  @override
  String get aiAdvancedSettingsDesc => '模型选择、执行策略、本地模型、提示词';

  @override
  String get aiPromptEditEntry => '提示词编辑';

  @override
  String get aiPromptEditEntryDesc => '自定义AI账单识别提示词，可分享给其他用户';

  @override
  String get aiPromptVariables => '变量说明';

  @override
  String get aiPromptVariablesHint => '点击展开查看可用变量';

  @override
  String get aiPromptContent => '提示词内容';

  @override
  String get aiPromptUnsaved => '未保存';

  @override
  String get aiPromptInputHint => '输入提示词...';

  @override
  String get aiPromptPreview => '预览';

  @override
  String get aiPromptSave => '保存';

  @override
  String get aiPromptSaved => '提示词已保存';

  @override
  String get aiPromptResetDefault => '恢复默认';

  @override
  String get aiPromptResetConfirmTitle => '恢复默认';

  @override
  String get aiPromptResetConfirmMessage => '确定要恢复默认提示词吗？您的自定义内容将会丢失。';

  @override
  String get aiPromptPasted => '已粘贴';

  @override
  String get aiPromptPreviewTitle => '提示词预览';

  @override
  String get aiPromptPreviewNote => '以上预览使用示例数据替换变量，实际运行时会使用真实数据';

  @override
  String get aiPromptVarInputSource => '输入来源描述，如\"从以下支付账单文本中\"';

  @override
  String get aiPromptVarCurrentTime => '当前日期和时间，如\"2025-01-15 14:30\"';

  @override
  String get aiPromptVarCurrentDate => '当前日期，如\"2025-01-15\"';

  @override
  String get aiPromptVarOcrText => '用户输入的文本内容';

  @override
  String get aiPromptVarCategories => '支出和收入分类列表';

  @override
  String get aiPromptVarAccounts => '用户的账户列表（可能为空）';

  @override
  String get aiModelTitle => '文本推理模型';

  @override
  String get aiVisionModelTitle => '视觉模型';

  @override
  String get aiModelFast => '快速';

  @override
  String get aiModelAccurate => '准确';

  @override
  String aiModelSwitched(String modelName) {
    return '已切换到 $modelName';
  }

  @override
  String get aiCustomBaseUrlHelper =>
      '标准聊天补全API地址，例如 https://api.example.com/v1';

  @override
  String get aiTextModelTitle => '文本模型';

  @override
  String get aiAudioModelTitle => '语音模型';

  @override
  String get customFieldManageTitle => '自定义字段';

  @override
  String get customFieldManageSubtitle => '为本账本定义字段名称与类型';

  @override
  String get customFieldManageEmpty => '暂无自定义字段';

  @override
  String get customFieldManageEmptyHint => '添加「税费」「发票号」等字段，为每笔明细记录额外信息';

  @override
  String get customFieldAdd => '新增字段';

  @override
  String get customFieldAddTitle => '新建自定义字段';

  @override
  String get customFieldEditTitle => '编辑自定义字段';

  @override
  String get customFieldNameLabel => '字段名称';

  @override
  String get customFieldNameHint => '例如：税费';

  @override
  String get customFieldNameRequired => '请输入字段名称';

  @override
  String get customFieldNameDuplicate => '已存在同名字段';

  @override
  String get customFieldTypeLabel => '字段类型';

  @override
  String get customFieldTypeAmount => '金额';

  @override
  String get customFieldTypeText => '文本';

  @override
  String get customFieldTypeDate => '日期';

  @override
  String get customFieldCreateSuccess => '字段已添加';

  @override
  String get customFieldUpdateSuccess => '字段已更新';

  @override
  String get customFieldDeleteSuccess => '字段已删除';

  @override
  String get customFieldDeleteConfirmTitle => '删除自定义字段';

  @override
  String customFieldDeleteConfirmMessage(String name) {
    return '确定删除「$name」吗？本账本中已记录的该字段值将一并清除，且无法恢复。';
  }

  @override
  String get customFieldDeleteReconfirmMessage =>
      '再次确认：删除后该字段及本账本中已记录的值将永久清除、无法恢复。确定要继续吗？';

  @override
  String get customFieldSectionTitle => '自定义字段';

  @override
  String get customFieldSectionEmpty => '该账本还没有自定义字段';

  @override
  String get customFieldDatePick => '选择日期';

  @override
  String get customFieldTextHint => '请输入内容';

  @override
  String get customFieldAmountHint => '0.00';

  @override
  String get customFieldSortHint => '长按拖动排序';

  @override
  String get tagManageTitle => '标签管理';

  @override
  String get tagManageSubtitle => '管理交易标签';

  @override
  String get tagManageEmpty => '暂无标签';

  @override
  String get tagManageEmptyHint => '点击右上角添加标签';

  @override
  String get tagManageGenerateDefault => '生成默认标签';

  @override
  String get tagManageGenerateDefaultConfirm => '确定要生成默认标签吗？已有同名标签不会被覆盖。';

  @override
  String get tagManageGenerateDefaultSuccess => '默认标签已生成';

  @override
  String get tagEditTitle => '编辑标签';

  @override
  String get tagAddTitle => '新增标签';

  @override
  String get tagNameLabel => '标签名称';

  @override
  String get tagNameHint => '请输入标签名称';

  @override
  String get tagNameRequired => '标签名称不能为空';

  @override
  String get tagNameDuplicate => '标签名称已存在';

  @override
  String get tagColorLabel => '标签颜色';

  @override
  String get tagCreateSuccess => '标签创建成功';

  @override
  String get tagUpdateSuccess => '标签更新成功';

  @override
  String get tagDeleteConfirmTitle => '删除标签';

  @override
  String tagDeleteConfirmMessage(String name) {
    return '确定要删除标签「$name」吗？此操作不会影响已关联的交易记录。';
  }

  @override
  String get tagDeleteSuccess => '标签已删除';

  @override
  String get tagSelectTitle => '选择标签';

  @override
  String get tagSelectHint => '可多选';

  @override
  String get tagSelectCreateNew => '新建标签';

  @override
  String get tagSelectRecentlyUsed => '最近使用';

  @override
  String get tagSelectAllTags => '全部标签';

  @override
  String tagTransactionCount(int count) {
    return '$count笔';
  }

  @override
  String get tagDetailTitle => '标签详情';

  @override
  String get tagDetailTotalCount => '交易笔数';

  @override
  String get tagDetailTotalExpense => '总支出';

  @override
  String get tagDetailTotalIncome => '总收入';

  @override
  String get tagDetailTransactionList => '关联交易';

  @override
  String get tagDetailNoTransactions => '暂无关联交易';

  @override
  String get tagDetailNoTransactionsHint => '使用此标签的交易将在此显示';

  @override
  String get tagNotFound => '标签不存在';

  @override
  String get tagDefaultMeituan => '美团';

  @override
  String get tagDefaultEleme => '饿了么';

  @override
  String get tagDefaultTaobao => '淘宝';

  @override
  String get tagDefaultJD => '京东';

  @override
  String get tagDefaultPDD => '拼多多';

  @override
  String get tagDefaultStarbucks => '星巴克';

  @override
  String get tagDefaultLuckin => '瑞幸咖啡';

  @override
  String get tagDefaultMcDonalds => '麦当劳';

  @override
  String get tagDefaultKFC => '肯德基';

  @override
  String get tagDefaultHema => '盒马';

  @override
  String get tagDefaultSams => '山姆';

  @override
  String get tagDefaultCostco => 'Costco';

  @override
  String get tagDefaultBusinessTrip => '出差';

  @override
  String get tagDefaultTravel => '旅行';

  @override
  String get tagDefaultDining => '聚餐';

  @override
  String get tagDefaultOnlineShopping => '网购';

  @override
  String get tagDefaultDaily => '日常';

  @override
  String get tagDefaultReimbursement => '报销';

  @override
  String get tagDefaultRefundable => '可退款';

  @override
  String get tagDefaultRefunded => '已退款';

  @override
  String get tagDefaultVoiceBilling => '语音记账';

  @override
  String get tagDefaultImageBilling => '图片记账';

  @override
  String get tagDefaultCameraBilling => '拍照记账';

  @override
  String get tagDefaultAiBilling => 'AI记账';

  @override
  String get tagShare => '分享标签';

  @override
  String get tagImport => '导入标签';

  @override
  String get tagClearUnused => '清理未使用';

  @override
  String tagShareSuccess(String path) {
    return '已保存到 $path';
  }

  @override
  String get tagShareSubject => 'PiggyCount 标签配置';

  @override
  String get tagShareFailed => '分享失败';

  @override
  String get tagImportInvalidFile => '请选择 YAML 配置文件';

  @override
  String get tagImportNoTags => '文件中没有标签数据';

  @override
  String get tagImportModeTitle => '选择导入模式';

  @override
  String get tagImportModeMerge => '合并';

  @override
  String get tagImportModeMergeDesc => '保留现有标签，新增不存在的';

  @override
  String get tagImportModeOverwrite => '覆盖';

  @override
  String get tagImportModeOverwriteDesc => '清空未使用标签后导入';

  @override
  String get tagImportSuccess => '导入成功';

  @override
  String get tagImportFailed => '导入失败';

  @override
  String get tagClearUnusedEmpty => '没有未使用的标签';

  @override
  String get tagClearUnusedTitle => '清理未使用标签';

  @override
  String tagClearUnusedMessage(int count) {
    return '确定要删除 $count 个未使用的标签吗？';
  }

  @override
  String get tagClearUnusedReconfirmMessage =>
      '再次确认：删除后这些标签不可恢复，若误删需要重新创建。确定要继续吗？';

  @override
  String tagClearUnusedSuccess(int count) {
    return '已删除 $count 个标签';
  }

  @override
  String get tagClearUnusedFailed => '清理失败';

  @override
  String get homeSwitchLedger => '选择账本';

  @override
  String get homeManageLedgers => '管理账本';

  @override
  String get budgetTitle => '预算管理';

  @override
  String get budgetShowOnHome => '在首页显示预算';

  @override
  String get budgetEmptyHint => '还没有设置预算';

  @override
  String get budgetAddTotal => '添加总预算';

  @override
  String get budgetMonthlyBudget => '本月预算';

  @override
  String get budgetUsed => '已用';

  @override
  String get budgetRemaining => '剩余';

  @override
  String budgetDaysRemaining(int days) {
    return '剩余 $days 天';
  }

  @override
  String budgetDailyAvailable(String amount) {
    return '日均可用 $amount';
  }

  @override
  String get budgetCategoryBudgets => '分类预算';

  @override
  String get budgetEditTitle => '编辑预算';

  @override
  String get budgetAddTitle => '添加预算';

  @override
  String get budgetTypeTotalLabel => '总预算';

  @override
  String get budgetTypeCategoryLabel => '分类预算';

  @override
  String get budgetAmountLabel => '预算金额';

  @override
  String get budgetAmountHint => '请输入预算金额';

  @override
  String get budgetCategoryLabel => '选择分类';

  @override
  String get budgetCategoryHint => '请选择预算分类';

  @override
  String get budgetPeriodLabel => '周期';

  @override
  String get budgetSaveSuccess => '预算保存成功';

  @override
  String get budgetDeleteConfirm => '确定删除此预算？';

  @override
  String get budgetDeleteSuccess => '预算已删除';

  @override
  String get attachmentAdd => '添加图片';

  @override
  String get attachmentTakePhoto => '拍照';

  @override
  String get attachmentChooseFromGallery => '从相册选择';

  @override
  String get attachmentMaxReached => '已达到最大附件数量';

  @override
  String get attachmentDeleteConfirm => '确定删除此附件？';

  @override
  String get commonDeleted => '已删除';

  @override
  String get attachmentExportTitle => '导出附件';

  @override
  String get attachmentExportSubtitle => '将所有附件打包导出为压缩文件';

  @override
  String get attachmentImportTitle => '导入附件';

  @override
  String get attachmentImportSubtitle => '从压缩文件导入附件';

  @override
  String get attachmentExportEmpty => '没有附件需要导出';

  @override
  String attachmentExportProgress(int current, int total) {
    return '正在导出附件 ($current/$total)';
  }

  @override
  String attachmentExportProgressDetail(
      int attachmentCount, int iconCount, int current, int total) {
    return '正在导出 $attachmentCount 个附件 + $iconCount 个图标 ($current/$total)';
  }

  @override
  String get attachmentExportSuccess => '附件导出成功';

  @override
  String attachmentExportSavedTo(String path) {
    return '已保存到: $path';
  }

  @override
  String get attachmentImportConflictStrategy => '冲突处理策略';

  @override
  String get attachmentImportConflictSkip => '跳过已存在的附件';

  @override
  String get attachmentImportConflictOverwrite => '覆盖已存在的附件';

  @override
  String attachmentImportProgress(int current, int total) {
    return '正在导入附件 ($current/$total)';
  }

  @override
  String attachmentImportResult(
      int imported, int skipped, int overwritten, int failed) {
    return '导入 $imported 张，跳过 $skipped 张，覆盖 $overwritten 张，失败 $failed 张';
  }

  @override
  String get attachmentImportFailed => '附件导入失败';

  @override
  String attachmentArchiveInfo(int count, String date) {
    return '$count 个附件，导出于 $date';
  }

  @override
  String get attachmentStartImport => '开始导入';

  @override
  String get attachmentImportReconfirmTitle => '覆盖导入确认';

  @override
  String get attachmentImportReconfirmMessage =>
      '再次确认：选择「覆盖」后，同名附件将被归档中的文件替换且无法恢复。确定要继续吗？';

  @override
  String get attachmentPreview => '预览附件';

  @override
  String get attachmentPreviewEmpty => '暂无附件';

  @override
  String get attachmentExportPreviewTitle => '导出预览';

  @override
  String get attachmentImportPreviewTitle => '导入预览';

  @override
  String get shortcutsGuide => '快捷指令';

  @override
  String get shortcutsGuideDesc => '快速打开语音、拍照等记账方式';

  @override
  String get shortcutsIntroTitle => '快速记账';

  @override
  String get shortcutsIntroDesc => '使用快捷指令，可以在桌面直接打开语音记账、拍照记账等功能，无需先打开 App。';

  @override
  String get availableShortcuts => '可用快捷指令';

  @override
  String get shortcutVoice => '语音记账';

  @override
  String get shortcutVoiceDesc => '通过语音快速记录账单';

  @override
  String get shortcutImage => '图片记账';

  @override
  String get shortcutImageDesc => '从相册选择图片识别账单';

  @override
  String get shortcutCamera => '拍照记账';

  @override
  String get shortcutCameraDesc => '拍照识别账单';

  @override
  String get shortcutNewExpense => '快捷记支出';

  @override
  String get shortcutNewExpenseDesc => '直接打开支出记账页面';

  @override
  String get shortcutNewIncome => '快捷记收入';

  @override
  String get shortcutNewIncomeDesc => '直接打开收入记账页面';

  @override
  String get shortcutNewTransfer => '快捷记转账';

  @override
  String get shortcutNewTransferDesc => '直接打开转账记账页面';

  @override
  String get shortcutUrlCopied => '链接已复制到剪贴板';

  @override
  String get howToAddShortcut => '如何添加快捷指令';

  @override
  String get iosShortcutStep1 => '打开「快捷指令」App';

  @override
  String get iosShortcutStep2 => '点击右上角「+」新建快捷指令';

  @override
  String get iosShortcutStep3 => '添加「打开 URL」操作';

  @override
  String get iosShortcutStep4 => '粘贴上方复制的链接（如 piggycount://voice）';

  @override
  String get iosShortcutStep5 => '保存后，可添加到桌面使用';

  @override
  String get androidShortcutStep1 => '下载支持创建快捷方式的应用（如 Shortcut Maker）';

  @override
  String get androidShortcutStep2 => '选择「URL 快捷方式」';

  @override
  String get androidShortcutStep3 => '粘贴上方复制的链接（如 piggycount://voice）';

  @override
  String get androidShortcutStep4 => '设置图标和名称后添加到桌面';

  @override
  String get shortcutsTip => '小贴士';

  @override
  String get shortcutsTipDesc => '快捷指令需要配合 AI 功能使用。请确保已开启智能识别并配置好 API Key。';

  @override
  String get shortcutOpenShortcutsApp => '打开快捷指令 App';

  @override
  String get shortcutAutoAdd => '自动记账接口';

  @override
  String get shortcutAutoAddDesc => '通过 URL 参数自动创建账单，适合与快捷指令、自动化工具配合使用。';

  @override
  String get shortcutAutoAddExample => '示例链接：';

  @override
  String get shortcutAutoAddParams => '支持的参数：';

  @override
  String get shortcutParamAmount => '金额（必填）';

  @override
  String get shortcutParamType => '类型：expense（支出）/ income（收入）/ transfer（转账）';

  @override
  String get shortcutParamCategory => '分类名称（需与App中已有分类匹配）';

  @override
  String get shortcutParamNote => '备注';

  @override
  String get shortcutParamAccount => '账户名称（需与App中已有账户匹配）';

  @override
  String get shortcutParamTags => '标签（多个用逗号分隔）';

  @override
  String get shortcutParamDate => '日期（ISO格式，如 2024-01-15）';

  @override
  String get quickActionImage => '图片记账';

  @override
  String get quickActionCamera => '拍照记账';

  @override
  String get quickActionVoice => '语音记账';

  @override
  String get quickActionAiChat => 'AI 小助手';

  @override
  String get calendarTitle => '日历';

  @override
  String get calendarToday => '今天';

  @override
  String get calendarNoTransactions => '当天无交易';

  @override
  String get calendarAddTransaction => '在该日记账';

  @override
  String get commonUncategorized => '未分类';

  @override
  String get commonSaved => '已保存';

  @override
  String get aiProviderManageTitle => '服务商管理';

  @override
  String get aiProviderManageSubtitle => '管理AI服务商配置';

  @override
  String get aiProviderAdd => '添加服务商';

  @override
  String get aiProviderBuiltIn => '内置';

  @override
  String get aiProviderEmpty => '暂无服务商配置';

  @override
  String get aiProviderNoApiKey => '未配置 API Key';

  @override
  String get aiProviderTapToEdit => '点击编辑';

  @override
  String get aiProviderDeleteTitle => '删除服务商';

  @override
  String aiProviderDeleteConfirm(String name) {
    return '确定删除服务商「$name」吗？使用该服务商的能力将自动切换到默认服务商。';
  }

  @override
  String get aiProviderDeleted => '服务商已删除';

  @override
  String get aiProviderEditTitle => '编辑服务商';

  @override
  String get aiProviderAddTitle => '添加服务商';

  @override
  String get aiProviderBasicInfo => '基本信息';

  @override
  String get aiProviderName => '服务商名称';

  @override
  String get aiProviderNameHint => '如：硅基流动、DeepSeek';

  @override
  String get aiProviderNameRequired => '请输入服务商名称';

  @override
  String get aiProviderBaseUrlRequired => '请输入 Base URL';

  @override
  String get aiProviderModels => '模型配置';

  @override
  String get aiProviderModelsHint => '留空的能力将无法使用该服务商';

  @override
  String get aiCapabilityText => '文本';

  @override
  String get aiCapabilityVision => '视觉';

  @override
  String get aiCapabilitySpeech => '语音';

  @override
  String get aiCapabilitySelectTitle => '能力绑定';

  @override
  String get aiCapabilitySelectSubtitle => '为每个AI能力选择服务商';

  @override
  String get aiCapabilityTextChat => '文本对话';

  @override
  String get aiCapabilityTextChatDesc => '用于AI对话和文本账单提取';

  @override
  String get aiCapabilityImageUnderstand => '图片理解';

  @override
  String get aiCapabilityImageUnderstandDesc => '用于图片账单识别';

  @override
  String get aiCapabilitySpeechToText => '语音转文字';

  @override
  String get aiCapabilitySpeechToTextDesc => '用于语音记账';

  @override
  String get aiProviderTestRunning => '测试中...';

  @override
  String get aiProviderTestSuccess => '测试通过';

  @override
  String get aiProviderTestFailed => '测试失败';

  @override
  String get aiProviderTestAll => '一键测试全部';

  @override
  String get aiProviderTestAllRetry => '重新测试';

  @override
  String get aiModelInputHelper => '留空则使用默认模型';

  @override
  String get syncPreviewTitle => '同步预览';

  @override
  String get syncPreviewSelectAll => '全选';

  @override
  String get syncPreviewDeselectAll => '取消全选';

  @override
  String get syncPreviewAdded => '新增';

  @override
  String get syncPreviewModified => '修改';

  @override
  String get syncPreviewDeleted => '删除';

  @override
  String syncPreviewAddedCount(int count) {
    return '新增 $count 条';
  }

  @override
  String syncPreviewModifiedCount(int count) {
    return '修改 $count 条';
  }

  @override
  String syncPreviewDeletedCount(int count) {
    return '删除 $count 条';
  }

  @override
  String syncPreviewApply(int count) {
    return '应用 $count 项';
  }

  @override
  String get syncPreviewOldFormat => '云端数据格式较旧，将执行全量替换';

  @override
  String get syncPreviewOldFormatMessage =>
      '云端数据不包含同步标识，无法逐条对比。将清空当前账本数据并从云端重新导入。';

  @override
  String syncPreviewApplied(int count) {
    return '已应用 $count 项变更';
  }

  @override
  String get cloudSyncGuideTitle => '云同步使用指南';

  @override
  String get cloudSyncGuideGotIt => '我知道了';

  @override
  String get cloudSyncGuideHowItWorks => '工作原理';

  @override
  String get cloudSyncGuideHowItem1 => '上传：将当前账本的全部数据打包上传到云端，覆盖云端旧数据';

  @override
  String get cloudSyncGuideHowItem2 => '下载：从云端拉取数据，与本地逐条对比差异，你可以选择要同步哪些变更';

  @override
  String get cloudSyncGuideHowItem3 => '云端始终只保存最后一次上传的完整快照，不保留历史版本';

  @override
  String get cloudSyncGuideCorrect => '正确的使用方式';

  @override
  String get cloudSyncGuideCorrectItem1 => '同一时间只在一台设备上记账，完成后上传';

  @override
  String get cloudSyncGuideCorrectItem2 => '切换设备前，先在新设备上下载同步';

  @override
  String get cloudSyncGuideCorrectItem3 => '下载时仔细查看预览，确认每条变更再应用';

  @override
  String get cloudSyncGuideCorrectItem4 => '养成「编辑→上传→切换设备→下载→编辑」的习惯';

  @override
  String get cloudSyncGuideWrong => '应避免的用法';

  @override
  String get cloudSyncGuideWrongItem1 => '两台设备同时编辑同一个账本，后上传的会覆盖先上传的改动';

  @override
  String get cloudSyncGuideWrongItem2 =>
      '上传后立刻在另一台设备下载，文件服务可能有几秒到几分钟的同步延迟，等一会再试';

  @override
  String get cloudSyncGuideWrongItem3 => '长时间不同步后一次性下载大量变更，容易遗漏需要处理的差异';

  @override
  String get cloudSyncGuideLimitations => '已知限制';

  @override
  String get cloudSyncGuideLimitItem1 => '非实时同步：需要手动点击上传和下载';

  @override
  String get cloudSyncGuideLimitItem2 => '无冲突合并：不会自动合并两端的修改，以最后上传的为准';

  @override
  String get cloudSyncGuideLimitItem3 =>
      '文件服务延迟：上传后云端文件可能需要几秒到几分钟才能被其他设备读取，取决于你使用的云服务';

  @override
  String get cloudSyncGuideLimitItem4 => '不含附件：交易的图片附件不参与同步，需通过数据管理单独导出';

  @override
  String get appLockTitle => '应用锁';

  @override
  String get appLockDesc => 'PIN码与生物识别保护隐私';

  @override
  String get appLockEnable => '启用应用锁';

  @override
  String get appLockEnableDesc => '启动和切回应用时需要验证身份';

  @override
  String get appLockSetPin => '设置密码';

  @override
  String get appLockChangePin => '修改密码';

  @override
  String get appLockVerifyPin => '验证密码';

  @override
  String get appLockVerifyCurrentPin => '请输入当前密码';

  @override
  String get appLockSetNewPin => '请设置新密码';

  @override
  String get appLockConfirmPin => '请再次输入密码';

  @override
  String get appLockEnterPin => '请输入密码';

  @override
  String get appLockPinSetSuccess => '密码设置成功';

  @override
  String get appLockDisabled => '应用锁已关闭';

  @override
  String get appLockBiometric => '生物识别解锁';

  @override
  String get appLockBiometricDesc => '使用Face ID或指纹快速解锁';

  @override
  String get appLockBiometricReason => '请验证身份以解锁小猪记账';

  @override
  String get appLockTimeout => '自动锁定时间';

  @override
  String get appLockTimeoutImmediate => '立即';

  @override
  String get appLockTimeout1Min => '1分钟后';

  @override
  String get appLockTimeout5Min => '5分钟后';

  @override
  String get appLockTimeout15Min => '15分钟后';

  @override
  String get creditCardSettings => '信用卡设置';

  @override
  String get accountTabValuation => '估值账户';

  @override
  String get creditCardDaysRequired => '请选择账单日和还款日';

  @override
  String get creditLimit => '信用额度';

  @override
  String get creditLimitHint => '请输入信用额度';

  @override
  String get billingDay => '账单日';

  @override
  String get paymentDueDay => '还款日';

  @override
  String get creditUsed => '已用额度';

  @override
  String get creditAvailable => '可用额度';

  @override
  String get creditCardOwed => '待还款';

  @override
  String dayOfMonth(int day) {
    return '每月$day日';
  }

  @override
  String get creditCardReminderTitle => '还款提醒';

  @override
  String get creditCardReminderDesc => '在还款日前提醒还款';

  @override
  String creditCardReminderDaysBefore(int days) {
    return '提前$days天提醒';
  }

  @override
  String get creditCardInitialBalanceHint => '当前欠款（填负数）';

  @override
  String get selectDay => '选择日期';

  @override
  String get accountBankName => '开户行';

  @override
  String get accountBankNameHint => '例如：工商银行';

  @override
  String get accountCardLastFour => '卡号后四位';

  @override
  String get accountCardLastFourHint => '例如：1234';

  @override
  String get accountNote => '备注';

  @override
  String get accountNoteHint => '添加备注信息';

  @override
  String get accountMetaInfo => '账户信息';

  @override
  String get accountBalanceTrend => '余额趋势';

  @override
  String get accountCategoryBreakdown => '分类统计';

  @override
  String get accountCategoryExpense => '支出';

  @override
  String get accountCategoryIncome => '收入';

  @override
  String get accountNoMoreData => '没有更多数据了';

  @override
  String get totalAssets => '总资产';

  @override
  String get totalLiabilities => '总负债';

  @override
  String get assetAccounts => '资产账户';

  @override
  String get liabilityAccounts => '负债账户';

  @override
  String get assetComposition => '资产构成';

  @override
  String get accountTypeInvestment => '投资理财';

  @override
  String get accountTypeLoan => '贷款';

  @override
  String get accountTypeReceivable => '应收款';

  @override
  String get accountTypeRealEstate => '不动产';

  @override
  String get accountTypeVehicle => '车辆';

  @override
  String get accountTypeInsurance => '保险';

  @override
  String get accountTypeSocialFund => '公积金/社保';

  @override
  String get valuationCurrentValue => '当前估值';

  @override
  String get valuationCurrentDebt => '当前欠款';

  @override
  String get valuationUpdateValue => '更新估值';

  @override
  String get valuationUpdateDebt => '更新欠款';

  @override
  String valuationLastUpdated(String date) {
    return '上次更新: $date';
  }

  @override
  String get valuationAccountHint => '请输入当前估值';

  @override
  String get valuationDebtHint => '请输入当前欠款金额';

  @override
  String get accountGroupTradable => '日常账户';

  @override
  String get adjustmentTransaction => '估值调整';

  @override
  String creditCardBillingInfo(int billingDay, int paymentDueDay) {
    return '每月$billingDay日出账 · $paymentDueDay日还款';
  }

  @override
  String creditCardDaysUntilPayment(int days) {
    return '距还款日还有$days天';
  }

  @override
  String get creditCardPaymentDueToday => '今天是还款日';

  @override
  String get creditCardQuickRepay => '记一笔还款';

  @override
  String get budgetManagement => '预算管理';

  @override
  String get budgetSetupHint => '设置预算，轻松掌控每月开支';

  @override
  String get budgetSetupAction => '去设置';

  @override
  String get maintenanceOrphanCleanupTitle => '数据清理';

  @override
  String get maintenanceOrphanCleanupSubtitle => '检查并清理本地孤儿数据';

  @override
  String get maintenanceOrphanRescan => '重新扫描';

  @override
  String get maintenanceOrphanEmpty => '本地数据干净,未发现孤儿数据';

  @override
  String get maintenanceOrphanGroupDb => '数据库孤儿';

  @override
  String get maintenanceOrphanGroupFile => '磁盘文件孤儿';

  @override
  String get maintenanceOrphanGroupSync => '同步状态孤儿';

  @override
  String maintenanceOrphanSummary(int count) {
    return '发现 $count 项异常';
  }

  @override
  String maintenanceOrphanSummarySize(String size) {
    return '可释放空间约 $size';
  }

  @override
  String get maintenanceOrphanSelectAll => '全选';

  @override
  String get maintenanceOrphanDeselectAll => '取消全选';

  @override
  String get maintenanceOrphanDeleteOne => '删除此项';

  @override
  String maintenanceOrphanSelectedHint(int count) {
    return '已选 $count 项';
  }

  @override
  String get maintenanceOrphanCleanSelected => '清理已选';

  @override
  String get maintenanceOrphanConfirmTitle => '确认清理';

  @override
  String maintenanceOrphanConfirmDeleteOne(String title) {
    return '确定清理「$title」吗？操作不可撤销。';
  }

  @override
  String maintenanceOrphanConfirmDeleteBatch(int count) {
    return '确定清理选中的 $count 项吗？操作不可撤销。';
  }

  @override
  String get maintenanceOrphanReconfirmMessage =>
      '再次确认：清理后这些数据将被永久删除、无法找回。确定要继续吗？';

  @override
  String maintenanceOrphanCleanSuccess(int count) {
    return '已清理 $count 项';
  }

  @override
  String maintenanceOrphanCleanPartial(int ok, int fail) {
    return '成功 $ok 项,失败 $fail 项';
  }

  @override
  String get exchangeRatePageTitle => '汇率管理';

  @override
  String get exchangeRateEntrySubtitle => '自动获取汇率，支持手动修正';

  @override
  String get baseCurrencyLabel => '主币种';

  @override
  String get rateSourceAuto => '自动';

  @override
  String get rateSourceManual => '手动';

  @override
  String rateUpdatedAt(String date) {
    return '$date 更新';
  }

  @override
  String get rateNotFetched => '未获取';

  @override
  String get rateTapToSet => '点击手动设置';

  @override
  String get rateEditTitle => '编辑汇率';

  @override
  String rateInverseHint(String base, String rate, String quote) {
    return '反向参考:1 $base ≈ $rate $quote';
  }

  @override
  String get rateResetToAuto => '恢复自动';

  @override
  String get rateRefreshSuccess => '汇率已更新';

  @override
  String get rateRefreshFailed => '获取失败,可手动设置汇率';

  @override
  String get ratesEmptyHint => '给账户设置不同币种后,这里会出现可管理的汇率';

  @override
  String get rateDisclaimer => '数据来源:开源汇率数据,每日更新;折算仅供参考,可能与银行实际牌价有差异。';

  @override
  String convertedNetWorth(String currency) {
    return '净资产(折$currency)';
  }

  @override
  String convertedFootnote(String date) {
    return '按 $date 汇率折算,点击管理汇率';
  }

  @override
  String convertedPartialWarning(String currencies) {
    return '$currencies 未折算,点击设置汇率';
  }

  @override
  String get unconvertedBadge => '未折算';

  @override
  String get commonDetail => '详情';

  @override
  String get conversionDetailTitle => '折算详情';

  @override
  String rateManualApplied(int count) {
    return '已应用 $count 条手动汇率';
  }

  @override
  String get netWorthTrendTitle => '净值趋势';

  @override
  String get netWorthTrend3M => '3个月';

  @override
  String get netWorthTrend6M => '6个月';

  @override
  String get netWorthTrend12M => '12个月';

  @override
  String get netWorthTrendAll => '全部';

  @override
  String get netWorthTrendLineNet => '净资产';

  @override
  String get netWorthTrendLineAssets => '总资产';

  @override
  String get netWorthTrendLineLiabilities => '总负债';

  @override
  String get netWorthTrendMultiCurrencyNote => '历史净值为各币种原值相加,未折算';

  @override
  String get txFlagExcludeFromStats => '不计入收支';

  @override
  String get txFlagExcludeFromBudget => '不计入预算';

  @override
  String get txFlagDialogTitle => '账单标记';

  @override
  String get txFlagExcludeFromStatsHint => '不计入收支统计,但仍计入账户余额';

  @override
  String get txFlagExcludeFromBudgetHint => '不占用预算额度';

  @override
  String get txFlagExcludedTag => '不计收支';

  @override
  String get txFlagBudgetExcludedTag => '不计预算';

  @override
  String get txCurrencyLabel => '币种';

  @override
  String get txRateLabel => '汇率';

  @override
  String txConvertedPreview(Object amount, Object currency) {
    return '≈ $amount $currency';
  }

  @override
  String get txRateMissingHint => '请手动填写本笔汇率后保存';

  @override
  String get txOriginalAmountLabel => '原始金额（选填）';

  @override
  String get txOriginalAmountHint => '留空则按记账金额';

  @override
  String get txOriginalAmountPrefix => '原';

  @override
  String get amountDeviationTitle => '金额偏差分析';

  @override
  String get amountDeviationMetricLabel => '金额口径';

  @override
  String get amountDeviationMetricCurrency => '原币金额';

  @override
  String get amountDeviationMetricNative => '本位币折算';

  @override
  String get amountDeviationBasisLabel => '差异基准';

  @override
  String get amountDeviationBasisRecorded => '记账金额';

  @override
  String get amountDeviationBasisOriginal => '原始金额';

  @override
  String get amountDeviationEntrySubtitle => '原始金额与记账金额的差异汇总与洞察';

  @override
  String get amountDeviationTotalLabel => '明细总数';

  @override
  String get amountDeviationDeviatedLabel => '有偏差明细';

  @override
  String get amountDeviationDiffSumLabel => '差异合计';

  @override
  String get amountDeviationMaxDiffLabel => '最大偏差';

  @override
  String get amountDeviationTrendTitle => '差异趋势';

  @override
  String get amountDeviationCategoryTitle => '分类偏差排行';

  @override
  String get amountDeviationInsightTitle => '偏差洞察';

  @override
  String get amountDeviationSeveritySlight => '轻微';

  @override
  String get amountDeviationSeverityNotable => '明显';

  @override
  String get amountDeviationSeveritySevere => '严重';

  @override
  String get amountDeviationReasonAbove => '原始金额高于记账金额，疑似未记录优惠或折扣';

  @override
  String get amountDeviationReasonBelow => '原始金额低于记账金额，疑似追加费用或事后补录';

  @override
  String get amountDeviationReasonMultiple => '差值接近记账金额的整数倍，疑似单位或币种换算误差';

  @override
  String get amountDeviationReasonCategoryHabit =>
      '该分类多笔明细出现同向偏差，疑似录入口径存在系统性偏差';

  @override
  String get amountDeviationEmptySubtext => '记账时填写「原始金额」后，这里会展示偏差与原因';

  @override
  String get amountDeviationBottomFillHint => '未填写的原始金额按记账金额保存，不产生差异';

  @override
  String get amountDeviationNoDiff => '该区间没有偏差';

  @override
  String get ledgerBaseCurrencyLabel => '主币种';

  @override
  String statsConvertedFootnote(Object currency) {
    return '含外币,已按各笔记账时汇率折算为 $currency';
  }

  @override
  String get ledgerCurrencyChangeRecalcHint => '修改本位币将按当前汇率重算全部历史交易的折算值';

  @override
  String get recalcForeignTxBanner => '检测到该账本有未折算的外币交易';

  @override
  String get recalcForeignTxAction => '按当前汇率重算折算';

  @override
  String recalcForeignTxDone(Object count) {
    return '已重算 $count 笔外币交易的折算值';
  }

  @override
  String get txCurrencyPickerTitle => '选择币种';

  @override
  String recalcSyncCountHint(Object count) {
    return '将重算并同步 $count 笔交易';
  }

  @override
  String get exportCsvHeaderCurrency => '币种';

  @override
  String get importFieldCurrency => '币种';

  @override
  String get currencyMOP => '澳门元';

  @override
  String get currencyMNT => '蒙古图格里克';

  @override
  String get currencyKPW => '朝鲜元';

  @override
  String get currencyKHR => '柬埔寨瑞尔';

  @override
  String get currencyLAK => '老挝基普';

  @override
  String get currencyBND => '文莱元';

  @override
  String get currencyNPR => '尼泊尔卢比';

  @override
  String get currencyBTN => '不丹努尔特鲁姆';

  @override
  String get currencyMVR => '马尔代夫拉菲亚';

  @override
  String get currencyAFN => '阿富汗尼';

  @override
  String get currencyUZS => '乌兹别克斯坦索姆';

  @override
  String get currencyTJS => '塔吉克斯坦索莫尼';

  @override
  String get currencyTMT => '土库曼斯坦马纳特';

  @override
  String get currencyKGS => '吉尔吉斯斯坦索姆';

  @override
  String get currencyQAR => '卡塔尔里亚尔';

  @override
  String get currencyKWD => '科威特第纳尔';

  @override
  String get currencyBHD => '巴林第纳尔';

  @override
  String get currencyOMR => '阿曼里亚尔';

  @override
  String get currencyJOD => '约旦第纳尔';

  @override
  String get currencyLBP => '黎巴嫩镑';

  @override
  String get currencyIQD => '伊拉克第纳尔';

  @override
  String get currencyIRR => '伊朗里亚尔';

  @override
  String get currencyYER => '也门里亚尔';

  @override
  String get currencySYP => '叙利亚镑';

  @override
  String get currencyGEL => '格鲁吉亚拉里';

  @override
  String get currencyAMD => '亚美尼亚德拉姆';

  @override
  String get currencyAZN => '阿塞拜疆马纳特';

  @override
  String get currencyRON => '罗马尼亚列伊';

  @override
  String get currencyBGN => '保加利亚列弗';

  @override
  String get currencyRSD => '塞尔维亚第纳尔';

  @override
  String get currencyISK => '冰岛克朗';

  @override
  String get currencyMDL => '摩尔多瓦列伊';

  @override
  String get currencyALL => '阿尔巴尼亚列克';

  @override
  String get currencyMKD => '北马其顿第纳尔';

  @override
  String get currencyBAM => '波黑可兑换马克';

  @override
  String get currencyGIP => '直布罗陀镑';

  @override
  String get currencyGTQ => '危地马拉格查尔';

  @override
  String get currencyHNL => '洪都拉斯伦皮拉';

  @override
  String get currencyNIO => '尼加拉瓜科多巴';

  @override
  String get currencyCRC => '哥斯达黎加科朗';

  @override
  String get currencyPAB => '巴拿马巴波亚';

  @override
  String get currencyDOP => '多米尼加比索';

  @override
  String get currencyCUP => '古巴比索';

  @override
  String get currencyJMD => '牙买加元';

  @override
  String get currencyTTD => '特立尼达和多巴哥元';

  @override
  String get currencyBSD => '巴哈马元';

  @override
  String get currencyBBD => '巴巴多斯元';

  @override
  String get currencyBZD => '伯利兹元';

  @override
  String get currencyHTG => '海地古德';

  @override
  String get currencyXCD => '东加勒比元';

  @override
  String get currencyKYD => '开曼群岛元';

  @override
  String get currencyAWG => '阿鲁巴弗罗林';

  @override
  String get currencyANG => '荷属安的列斯盾';

  @override
  String get currencyBMD => '百慕大元';

  @override
  String get currencyUYU => '乌拉圭比索';

  @override
  String get currencyPYG => '巴拉圭瓜拉尼';

  @override
  String get currencyBOB => '玻利维亚诺';

  @override
  String get currencyVES => '委内瑞拉玻利瓦尔';

  @override
  String get currencyGYD => '圭亚那元';

  @override
  String get currencySRD => '苏里南元';

  @override
  String get currencyFJD => '斐济元';

  @override
  String get currencyPGK => '巴布亚新几内亚基那';

  @override
  String get currencySBD => '所罗门群岛元';

  @override
  String get currencyTOP => '汤加潘加';

  @override
  String get currencyVUV => '瓦努阿图瓦图';

  @override
  String get currencyWST => '萨摩亚塔拉';

  @override
  String get currencyXPF => '太平洋法郎';

  @override
  String get currencyKES => '肯尼亚先令';

  @override
  String get currencyGHS => '加纳塞地';

  @override
  String get currencyMAD => '摩洛哥迪拉姆';

  @override
  String get currencyDZD => '阿尔及利亚第纳尔';

  @override
  String get currencyTND => '突尼斯第纳尔';

  @override
  String get currencyLYD => '利比亚第纳尔';

  @override
  String get currencyETB => '埃塞俄比亚比尔';

  @override
  String get currencyUGX => '乌干达先令';

  @override
  String get currencyTZS => '坦桑尼亚先令';

  @override
  String get currencyRWF => '卢旺达法郎';

  @override
  String get currencyXAF => '中非法郎';

  @override
  String get currencyXOF => '西非法郎';

  @override
  String get currencyMUR => '毛里求斯卢比';

  @override
  String get currencyBWP => '博茨瓦纳普拉';

  @override
  String get currencyNAD => '纳米比亚元';

  @override
  String get currencyZMW => '赞比亚克瓦查';

  @override
  String get currencyMWK => '马拉维克瓦查';

  @override
  String get currencyMZN => '莫桑比克梅蒂卡尔';

  @override
  String get currencyAOA => '安哥拉宽扎';

  @override
  String get currencyCDF => '刚果法郎';

  @override
  String get currencyGMD => '冈比亚达拉西';

  @override
  String get currencyGNF => '几内亚法郎';

  @override
  String get currencyLRD => '利比里亚元';

  @override
  String get currencySLE => '塞拉利昂利昂';

  @override
  String get currencySDG => '苏丹镑';

  @override
  String get currencySSP => '南苏丹镑';

  @override
  String get currencySOS => '索马里先令';

  @override
  String get currencyDJF => '吉布提法郎';

  @override
  String get currencyERN => '厄立特里亚纳克法';

  @override
  String get currencyBIF => '布隆迪法郎';

  @override
  String get currencyCVE => '佛得角埃斯库多';

  @override
  String get currencySTN => '圣多美多布拉';

  @override
  String get currencySCR => '塞舌尔卢比';

  @override
  String get currencyKMF => '科摩罗法郎';

  @override
  String get currencyLSL => '莱索托洛蒂';

  @override
  String get currencySZL => '斯威士兰里兰吉尼';

  @override
  String get currencyMGA => '马达加斯加阿里亚里';

  @override
  String get currencyMRU => '毛里塔尼亚乌吉亚';

  @override
  String get cloudSyncEncryptTitle => '同步加密';

  @override
  String get cloudSyncEncryptSubtitle => '用密码加密云端备份，保护账本隐私';

  @override
  String get cloudSyncEncryptEnabled => '已开启';

  @override
  String get cloudSyncEncryptDisabled => '未开启';

  @override
  String get cloudSyncEncryptSettings => '加密设置';

  @override
  String get cloudSyncEncryptSetPassword => '设置密码';

  @override
  String get cloudSyncEncryptChangePassword => '修改密码';

  @override
  String get cloudSyncEncryptResetEncryption => '重置加密';

  @override
  String get cloudSyncEncryptPasswordLabel => '密码';

  @override
  String get cloudSyncEncryptConfirmPasswordLabel => '确认密码';

  @override
  String get cloudSyncEncryptOldPasswordLabel => '旧密码';

  @override
  String get cloudSyncEncryptNewPasswordLabel => '新密码';

  @override
  String get cloudSyncEncryptPasswordHint => '至少 8 个字符';

  @override
  String get cloudSyncEncryptPasswordMismatch => '两次输入的密码不一致';

  @override
  String get cloudSyncEncryptPasswordTooShort => '密码至少 8 个字符';

  @override
  String get cloudSyncEncryptWrongPassword => '密码错误';

  @override
  String get cloudSyncEncryptEnableSuccess => '加密已开启';

  @override
  String get cloudSyncEncryptChangeSuccess => '密码已修改';

  @override
  String get cloudSyncEncryptResetConfirmTitle => '重置加密';

  @override
  String get cloudSyncEncryptResetConfirmMessage => '重置将清空云端所有账本备份且不可恢复，确定继续吗？';

  @override
  String get cloudSyncEncryptResetReconfirmMessage =>
      '再次确认：重置后云端所有账本备份将永久删除，无法恢复。确定要继续吗？';

  @override
  String get cloudSyncEncryptResetSuccess => '加密已重置';

  @override
  String get cloudSyncEncryptDecryptFailed => '解密失败，请检查密码';

  @override
  String get cloudSyncEncryptMultiDeviceHint => '在其他设备上用相同密码即可解密';

  @override
  String cloudSyncEncryptReencryptPartialFailed(int count) {
    return '加密已开启，但有 $count 个云端文件重加密失败，下次同步时会自动重试。';
  }

  @override
  String get cloudSyncEncryptProbeFailedTitle => '探测云端失败';

  @override
  String get cloudSyncEncryptProbeFailedMessage =>
      '无法探测云端是否已有加密数据（可能是网络或权限问题）。如果其他设备已开启加密，继续将以新密码重加密云端数据，可能导致其他设备无法解密。确定继续吗？';

  @override
  String get cloudSyncEncryptProbeFailedContinue => '以首设备继续';

  @override
  String get saltMismatchNeedPasswordHint => '云端备份密钥与本地不匹配，点击重新输入密码';

  @override
  String get cloudEncryptedLocallyDisabledHint =>
      '云端备份为加密密文，但本设备未开启加密，点击开启加密以恢复数据';

  @override
  String get saltMismatchDialogTitle => '重新输入密码';

  @override
  String get saltMismatchRawStorageUnavailable => '云服务未初始化，无法恢复密钥';

  @override
  String get saltMismatchProbeFailed => '云端探测失败，请检查网络后重试';

  @override
  String get saltMismatchCloudCorrupted => '云端密文已损坏，无法恢复密钥';

  @override
  String get saltMismatchWebdavAuthTitle => '云端认证失败';

  @override
  String get saltMismatchWebdavAuthMessage =>
      '云存储（WebDAV）账号或密码错误，请前往云服务设置修正凭据后重试。';

  @override
  String get saltMismatchGoConfig => '去修改配置';

  @override
  String get startupSyncRecoveryFailedHint =>
      '密钥激活失败，同步未恢复。请确认密码后重试，或到同步设置重新操作。';

  @override
  String get backupNowTitle => '立即备份';

  @override
  String get backupNowSubtitle => '将全部账本与附件打包为一份当日备份，存入 piggycount-bak';

  @override
  String get backupNoLedgers => '没有可备份的账本。';

  @override
  String get backupRunningStatus => '正在创建备份…';

  @override
  String backupPackingProgress(int done, int total) {
    return '正在打包账本 $done/$total…';
  }

  @override
  String backupSuccessMessage(String fileName) {
    return '备份已上传：piggycount-bak/$fileName';
  }

  @override
  String get backupFailedAuthMessage => '云端认证失败，请检查云服务配置后重试。';

  @override
  String get backupFailedNetworkMessage => '备份失败，请检查网络后重试。';

  @override
  String get restoreFromBackupTitle => '从备份恢复';

  @override
  String get restoreFromBackupSubtitle => '用选定的每日备份覆盖本地数据（全部账本与附件）';

  @override
  String get backupListDialogTitle => '正在读取备份列表…';

  @override
  String get backupListEmptyMessage => '云端还没有备份。';

  @override
  String restoreConfirm1Message(String date) {
    return '将使用 $date 的备份覆盖本地全部账本数据（账户、分类、交易），比备份更新的本地改动将丢失。';
  }

  @override
  String get restoreConfirm2Message => '此操作不可撤销，确定要继续吗？';

  @override
  String get restoreRunningStatus => '正在从备份恢复…';

  @override
  String restoreLedgerProgress(int done, int total) {
    return '正在恢复账本 $done/$total…';
  }

  @override
  String restoreResultMessage(int success, int failed) {
    return '恢复完成：成功 $success 个，失败 $failed 个。';
  }

  @override
  String restoreSkippedRecurringHint(int count) {
    return '注意：恢复时有 $count 笔同日周期实例被判重跳过（同规则同日且 syncId 或金额+备注相同），如源端存在同日多笔交易请核对明细。';
  }

  @override
  String get backupAutoTitle => '定时备份';

  @override
  String get backupAutoSubtitle => '每日在设定时间自动备份一次（仅 App 运行期间生效）';

  @override
  String get backupTimeTitle => '每日备份时间';

  @override
  String lastBackupCaption(String date, String ok) {
    return '最近备份：$date · $ok';
  }

  @override
  String get lastBackupNone => '最近备份：尚无记录';

  @override
  String get ledgersCreatedSuccess => '账本创建成功';

  @override
  String ledgersCreateFailed(String error) {
    return '创建失败: $error';
  }

  @override
  String get budgetOnlyOwnerCanEdit => '只有账本所有者能编辑预算';

  @override
  String get transferSelectFromAccount => '请选择转出账户';

  @override
  String get transferSelectToAccount => '请选择转入账户';

  @override
  String get commonNoMessages => '暂无消息';

  @override
  String commonLoadFailed(String error) {
    return '加载失败: $error';
  }

  @override
  String get commonNoMatches => '无匹配项';

  @override
  String attachmentCustomIcons(int count) {
    return '自定义图标 ($count)';
  }

  @override
  String get annualReportInsightTitle => '年度洞察';

  @override
  String get annualReportInsightSubtitle => '从数据中发现你的消费习惯';

  @override
  String get annualReportAvgPerTxTitle => '平均每笔消费';

  @override
  String get annualReportAvgPerTxDesc => '你每次记账的平均金额';

  @override
  String get annualReportAvgDailyTitle => '日均支出';

  @override
  String get annualReportAvgDailyDesc => '平均每天花费金额';

  @override
  String get annualReportAvgMonthlyTitle => '月均支出';

  @override
  String get annualReportAvgMonthlyDesc => '平均每月花费金额';

  @override
  String get annualReportActiveMonthTitle => '最活跃月份';

  @override
  String get annualReportActiveMonthDesc => '记账活动最频繁的月份';

  @override
  String get annualReportCategoryCountTitle => '消费分类数';

  @override
  String get annualReportCategoryCountDesc => '你使用过的消费分类数量';

  @override
  String get annualReportSavingsRateTitle => '储蓄率';

  @override
  String get annualReportSavingsRateDescPos => '今年你攒下了收入的这个比例';

  @override
  String get annualReportSavingsRateDescNeg => '今年支出超过了收入';

  @override
  String get annualReportCompareTitle => '收支对比';

  @override
  String get annualReportCompareSubtitle => '每月收入与支出的对比';

  @override
  String get annualReportTopIncome => '收入最高';

  @override
  String get annualReportTopExpense => '支出最高';

  @override
  String get annualReportUnitDay => '天';

  @override
  String get annualReportUnitEntries => '笔';

  @override
  String get posterUnitPerDay => '元/天';

  @override
  String get posterUnitPerMonth => '元/月';

  @override
  String annualReportMonthValue(int month) {
    return '$month月';
  }

  @override
  String annualReportCategoryCountValue(int count) {
    return '$count个';
  }

  @override
  String get annualReportPosterSavedPos => '恭喜你攒下了';

  @override
  String get annualReportPosterOverspent => '今年花超了';

  @override
  String get annualReportPosterBookkeeping => '记账坚持';

  @override
  String get annualReportPosterTrend => '月度支出趋势';

  @override
  String get annualReportPosterAchieved => '已达成';

  @override
  String get annualReportPosterNotAchieved => '未达成';

  @override
  String get annualReportPosterQrCta => '扫码下载小猪记账，开启你的记账之旅';

  @override
  String annualReportConsecutiveDaysValue(int count) {
    return '$count天';
  }

  @override
  String aiBillingRateMissingHint(String currency) {
    return '⚠️ 未取到 $currency 汇率，已按 1:1 暂记，可在统计页「补折算」修正';
  }

  @override
  String get aiPromptVarCurrencies => '账本主币种 + 已在用的外币账户';

  @override
  String get aiPromptVarBillGuard => '账单过滤段（仅截图 / 自动记账时注入）';

  @override
  String aiPromptMissingVarsHint(String vars) {
    return '你的自定义模板缺少这些变量，对应能力会失效：$vars';
  }

  @override
  String aiPromptInsertVarSection(String name) {
    return '插入 $name 段落';
  }

  @override
  String aiPromptVarSectionInserted(String name) {
    return '已追加 $name 段落，确认后保存';
  }

  @override
  String get tagSelectOwnerManaged => '共享账本标签由所有者管理';

  @override
  String get syncHealthTitle => '同步健康';

  @override
  String get syncHealthEmpty => '近 30 天暂无同步记录';

  @override
  String syncHealthRate(String rate) {
    return '近 30 天成功率：$rate';
  }

  @override
  String syncHealthDetail(int success, int failed, int softFail, int conflict) {
    return '成功 $success · 失败 $failed · 未收敛 $softFail · 并发拦截 $conflict';
  }

  @override
  String get syncHealthTopErrors => '主要失败类别';

  @override
  String get syncHealthExport => '导出诊断数据';

  @override
  String syncHealthExported(String fileName) {
    return '诊断数据已导出：$fileName';
  }

  @override
  String syncHealthExportFailed(String error) {
    return '诊断数据导出失败：$error';
  }

  @override
  String get cloudCapabilityTitle => '后端能力';

  @override
  String cloudCapabilityLine(String concurrency, String binary) {
    return '并发保护：$concurrency · 二进制传输：$binary';
  }

  @override
  String get cloudCapYes => '原生支持';

  @override
  String get cloudCapApprox => '近似（校验兜底）';

  @override
  String get cloudCapNo => '降级模式';

  @override
  String get syncErrNotConfigured => '未配置';

  @override
  String get syncErrAuth => '认证失败';

  @override
  String get syncErrNetworkTimeout => '网络超时';

  @override
  String get syncErrGateway => '远端／网关异常';

  @override
  String get syncErrPrecondition => '并发冲突';

  @override
  String get syncErrDataCorruption => '数据完整性异常';

  @override
  String get syncErrOther => '其他';

  @override
  String get syncErrNotConfiguredMessage => '云端同步尚未配置。请先到「云服务」页填写服务地址与凭据，然后再试。';

  @override
  String get syncErrCorruptionMessage =>
      '数据完整性校验失败，本地或云端数据可能已损坏。建议先导出备份留存，再从云端快照恢复，避免直接覆盖本地数据。';

  @override
  String get syncErrGenericMessage => '同步失败，请稍后重试。若反复失败，可在「日志中心」导出诊断数据反馈。';

  @override
  String get dbHealthCorruptTitle => '本地数据库异常';

  @override
  String get dbHealthCorruptBodyCorrupted =>
      '本地数据库未通过完整性校验（页级损坏）。为避免进一步损坏，本机读写已暂停。建议先导出损坏文件留存，再重置本地数据库并重启应用；重启后可在「云服务」页用云端备份恢复数据。';

  @override
  String get dbHealthCorruptBodyUnreadable =>
      '无法读取本地数据库文件（可能被其他程序占用，或文件已不是有效的数据库）。请先彻底关闭并重新打开应用；若仍然如此，可导出文件留存，再重置本地数据库并重启。';

  @override
  String get dbHealthActionExport => '导出损坏文件';

  @override
  String get dbHealthActionReset => '重置本地数据库';

  @override
  String get dbHealthActionLater => '稍后处理';

  @override
  String dbHealthExported(String path) {
    return '已导出到：$path';
  }

  @override
  String dbHealthExportFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String get dbHealthResetConfirmTitle => '重置本地数据库？';

  @override
  String get dbHealthResetConfirmMessage =>
      '损坏的数据库文件会被移到一个保留目录（不会删除），随后需要重启应用以新建空数据库。之后可用云端备份或备份文件恢复数据。';

  @override
  String dbHealthResetDone(String path) {
    return '损坏文件已保留在：$path\n请完全退出并重新打开应用。';
  }

  @override
  String dbHealthResetFailed(String error) {
    return '重置失败：$error';
  }

  @override
  String get recycleBin => '回收站';

  @override
  String get recycleBinSubtitle => '已删除的交易留在这里，直到你彻底删除';

  @override
  String get recycleBinEmpty => '回收站是空的';

  @override
  String get recycleBinMoved => '已移入回收站';

  @override
  String get recycleBinRestored => '已恢复';

  @override
  String get recycleBinRestore => '恢复';

  @override
  String get recycleBinPurge => '彻底删除';

  @override
  String get recycleBinPurgeConfirm => '彻底删除后无法恢复，附件文件也会一并清除，确定吗？';

  @override
  String get recycleBinPurgeReconfirm => '再次确认：彻底删除后该交易及其附件将永久消失、无法恢复。确定要继续吗？';

  @override
  String get recycleBinRestoreConflict => '恢复失败：该位置已被另一笔交易占用';

  @override
  String get rangeReportTitle => '自定义区间报表';

  @override
  String get rangeReportEntrySubtitle => '任意起止区间，含环比与同比变化，另按标签维度拆分';

  @override
  String get rangeReportColumnCurrent => '本期';

  @override
  String get rangeReportColumnMom => '环比上期';

  @override
  String get rangeReportColumnYoy => '同比去年同期';

  @override
  String analyticsTagComposition(Object type) {
    return '$type标签构成';
  }

  @override
  String get rangeReportChangeRange => '更换区间';

  @override
  String get rangeReportCustomFieldTitle => '自定义字段汇总';

  @override
  String get rangeReportEmptySubtext => '这段时间还没有记账，点上方日期换一个区间';

  @override
  String semanticsChartSeries(int count, String points) {
    return '图表，共 $count 个点：$points';
  }

  @override
  String get holidaySettingsTitle => '日历与节假日';

  @override
  String get holidaySettingsDesc => '法定节假日标注与农历，数据每月自动更新';

  @override
  String get holidayCacheOverview => '缓存概览';

  @override
  String holidayCacheCount(int count, int off, int work) {
    return '共 $count 条（放假 $off · 补班 $work）';
  }

  @override
  String holidayCoverYears(String range) {
    return '覆盖年份：$range';
  }

  @override
  String holidayLastUpdate(String time) {
    return '上次成功更新：$time';
  }

  @override
  String get holidayNeverUpdated => '从未成功更新';

  @override
  String holidayFailureCount(int count) {
    return '连续失败 $count 次（旧缓存仍可使用）';
  }

  @override
  String get holidayUpdateNow => '立即更新';

  @override
  String get holidayUpdating => '正在更新…';

  @override
  String get holidayUpdateSuccess => '节假日数据已更新';

  @override
  String holidayUpdateFailed(String error) {
    return '更新失败：$error';
  }

  @override
  String get holidayAutoUpdate => '每月自动更新';

  @override
  String get holidayAutoUpdateDesc => '每月联网更新一次当年节假日，不含任何账本或设备信息';

  @override
  String get holidayBadgeOff => '休';

  @override
  String get holidayBadgeWork => '班';

  @override
  String get holidayLoadFailed => '节假日数据加载失败';

  @override
  String get holidayFetchByYear => '按年份范围获取';

  @override
  String get holidayFetchByYearDesc => '选择起止年份，联网补写该范围节假日';

  @override
  String get holidayUpdateYear => '更新该年';

  @override
  String holidayFetchYearDone(int year) {
    return '$year 年节假日已更新';
  }

  @override
  String holidayYearNoData(int year) {
    return '$year 年暂无节假日数据';
  }

  @override
  String holidayFetchYearFailed(String error) {
    return '获取失败：$error';
  }

  @override
  String get holidayYearRangeTitle => '选择年份范围';

  @override
  String get holidayYearRangeStart => '起始年份';

  @override
  String get holidayYearRangeEnd => '结束年份';

  @override
  String holidayFetchRangeDone(int count) {
    return '已补写 $count 个年份';
  }

  @override
  String holidayFetchRangeDoneNoData(int updated, int noData) {
    return '已补写 $updated 个年份，$noData 个年份无数据';
  }

  @override
  String holidayFetchRangePartial(int updated, int count) {
    return '已补写 $updated 个年份，$count 个年份获取失败';
  }
}

/// The translations for Chinese, as used in Taiwan (`zh_TW`).
class AppLocalizationsZhTw extends AppLocalizationsZh {
  AppLocalizationsZhTw() : super('zh_TW');

  @override
  String get aiConsentTitle => '開啟 AI 功能前,請知悉';

  @override
  String get aiConsentBody =>
      'AI 功能需將相關資料傳送給你所設定的第三方 AI 服務商進行處理:\n\n• 傳送給誰:預設「智譜 GLM」(open.bigmodel.cn,由智譜華章營運);若你自行設定了其它第三方 AI 服務商,則傳送給你填寫的服務商。\n• 傳送什麼:你主動用於辨識/對話的內容 —— 帳單圖片、語音錄音、你輸入的文字,以及為完成辨識/分析所需的分類名稱、帳戶名稱和相關交易記錄。\n• 用途:僅用於帳單辨識、記帳與你發起的對話分析;小豬記帳本身不收集、不儲存這些資料。\n\n資料由該第三方服務商依其隱私政策處理。開啟即表示你同意上述資料共享。';

  @override
  String get aiConsentAgree => '同意並開啟';

  @override
  String get aboutPrivacyPolicy => '隱私政策';

  @override
  String get changelogTitle => '更新日誌';

  @override
  String changelogVersionSubtitle(String date, int count) {
    return '$date · $count 項更新';
  }

  @override
  String get appTitle => '小豬記帳';

  @override
  String get tabHome => '明細';

  @override
  String get tabInsights => '洞察';

  @override
  String get tabAssets => '資產';

  @override
  String get tabRecord => '記帳';

  @override
  String get tabMine => '我的';

  @override
  String get commonCancel => '取消';

  @override
  String get conflictUploadTitle => '偵測到同步衝突';

  @override
  String get conflictUploadCloudNewerMessage =>
      '雲端快照比本機新（可能另一台裝置剛同步過）。繼續上傳會覆蓋雲端資料，且雲端版本將遺失。確定要覆蓋上傳嗎？';

  @override
  String get conflictUploadUnknownMessage =>
      '無法判定本機與雲端哪個較新（內容不同但時間相同）。繼續上傳會覆蓋雲端資料。確定要覆蓋上傳嗎？';

  @override
  String get conflictForceUploadAction => '覆蓋上傳';

  @override
  String get conflictCompareMergeAction => '對比合併';

  @override
  String get cloudConfigCorruptWarning => '雲端設定讀取失敗，自動同步已暫停。請重新設定雲端服務。';

  @override
  String get cloudMigrationWarning =>
      '雲端憑證安全遷移失敗，憑證暫以明文形式留在本機。建議重新儲存雲端設定以完成安全遷移。';

  @override
  String get commonConfirm => '確定';

  @override
  String get commonSave => '儲存';

  @override
  String get commonDelete => '刪除';

  @override
  String get commonAdd => '新增';

  @override
  String get commonEdit => '編輯';

  @override
  String get commonMore => '更多';

  @override
  String get commonOk => '確定';

  @override
  String get commonKnow => '知道了';

  @override
  String get commonEmpty => '暫無資料';

  @override
  String get commonError => '錯誤';

  @override
  String get startupSyncCheckTitle => '雲端有更新';

  @override
  String startupSyncCheckSummaryMessage(int count) {
    return '偵測到 $count 個帳本有雲端更新，是否合併到本地？';
  }

  @override
  String startupSyncCheckLedgerMessage(
      String ledger, int added, int modified, int deleted) {
    return '帳本「$ledger」偵測到雲端有 $added 筆新增、$modified 筆修改、$deleted 筆刪除，是否合併到本地？';
  }

  @override
  String get startupSyncCheckApplyAll => '一鍵套用全部';

  @override
  String get startupSyncCheckConfirmEach => '逐一確認';

  @override
  String get startupSyncCheckViewDetail => '查看詳情並套用';

  @override
  String get startupSyncCheckSkip => '暫不合併';

  @override
  String get startupSyncCheckSkipRest => '跳過剩餘';

  @override
  String get startupSyncCheckCancelHint => '可稍後在「我的-雲端同步」手動檢查';

  @override
  String get startupSyncCheckCheckingTitle => '正在檢查雲端更新';

  @override
  String get startupSyncCheckCheckingHint => '請稍候...';

  @override
  String startupSyncCheckCheckingProgress(int checked, int total) {
    return '正在檢查 $checked/$total';
  }

  @override
  String get startupSyncCheckApplyingTitle => '正在合併雲端資料';

  @override
  String startupSyncCheckApplyingProgress(int applied, int total) {
    return '正在合併 $applied/$total';
  }

  @override
  String get startupSyncCheckUpToDate => '所有帳本都是最新的';

  @override
  String get startupSyncConflictTooltip => '本地有改動將被雲端覆蓋';

  @override
  String get startupSyncConflictConfirmTitle => '覆蓋確認';

  @override
  String startupSyncConflictConfirmMessage(int count, String names) {
    return '將用雲端覆蓋 $count 個帳本的本地改動（$names），是否繼續？';
  }

  @override
  String get startupSyncConflictConfirmOk => '覆蓋本地';

  @override
  String get startupSyncConflictConfirmCancel => '取消';

  @override
  String startupSyncConflictAndMore(int count) {
    return '等 $count 個';
  }

  @override
  String get startupSyncNewLedgersTitle => '發現雲端賬本';

  @override
  String startupSyncNewLedgersMessage(int count, String names) {
    return '雲端發現 $count 個本機沒有的賬本：$names。是否下載到本機？';
  }

  @override
  String get startupSyncNewLedgersOk => '下載';

  @override
  String get startupSyncNewLedgersCancel => '跳過';

  @override
  String startupSyncNewLedgersBackend(String backend) {
    return '目前後端：$backend';
  }

  @override
  String startupSyncDuplicateSlots(Object detail) {
    return '注意：以下名稱在雲端存在多個槽位，全部下載會產生重複帳本（可稍後在 帳本管理-雲端帳本 按 ID 選別下載）：$detail';
  }

  @override
  String get commonSuccess => '成功';

  @override
  String get commonFailed => '失敗';

  @override
  String get commonBack => '返回';

  @override
  String get commonNext => '下一步';

  @override
  String get fabActionCamera => '拍照';

  @override
  String get fabActionGallery => '相簿';

  @override
  String get fabActionVoice => '語音';

  @override
  String get fabActionVoiceDisabled => '需要啟用AI並配置 GLM API';

  @override
  String get voiceRecordingTitle => '語音記帳';

  @override
  String get voiceRecordingPreparing => '準備錄音...';

  @override
  String get voiceRecordingInProgress => '正在錄音...';

  @override
  String get voiceRecordingProcessing => '正在識別...';

  @override
  String voiceRecordingDuration(int duration) {
    return '錄音時長: $duration秒';
  }

  @override
  String get voiceRecordingSuccess => '語音記帳成功';

  @override
  String get voiceRecordingNoLedger => '未找到當前帳本';

  @override
  String get voiceRecordingNoInfo => '未識別到記帳資訊';

  @override
  String get voiceRecordingPermissionDenied => '需要麥克風權限才能錄音';

  @override
  String get voiceRecordingPermissionDeniedTitle => '需要麥克風權限';

  @override
  String get voiceRecordingPermissionDeniedMessage =>
      '語音記帳功能需要使用麥克風權限。請在系統設定中允許小豬記帳存取麥克風。';

  @override
  String voiceRecordingStartFailed(String error) {
    return '啟動錄音失敗: $error';
  }

  @override
  String voiceRecordingFailed(String error) {
    return '錄音失敗: $error';
  }

  @override
  String voiceRecordingRecognizeFailed(String error) {
    return '識別失敗: $error';
  }

  @override
  String voiceRecordingNoInfoDetected(String text) {
    return '未能識別帳單資訊: $text';
  }

  @override
  String get voiceRecordingNoSpeech => '未檢測到語音輸入';

  @override
  String get voiceRecordingHoldToTalk => '按住 說話';

  @override
  String get voiceRecordingReleaseToFinish => '鬆手結束錄音';

  @override
  String get voiceRecordingTooShort => '錄音時間過短';

  @override
  String get voiceRecordingResultLabel => '識別結果：';

  @override
  String get voiceRecordingAutoHintSpoken => '說完後停頓即可自動識別';

  @override
  String get voiceRecordingAutoHintWaiting => '請開始說話...';

  @override
  String get smartBillingVoiceTrigger => '語音觸發方式';

  @override
  String get voiceTriggerModeAuto => '自動偵測停頓';

  @override
  String get voiceTriggerModeAutoDesc => '錄音後自動判斷說完，適合短句快速記帳';

  @override
  String get voiceTriggerModeHold => '按住說話';

  @override
  String get voiceTriggerModeHoldDesc => '長按錄音、鬆開結束，適合一次說較多內容';

  @override
  String get smartBillingVoiceSilenceTimeout => '停頓結束時長';

  @override
  String smartBillingVoiceSilenceTimeoutValue(String seconds) {
    return '停頓 $seconds 秒後自動結束辨識';
  }

  @override
  String get commonPrevious => '上一步';

  @override
  String get commonFinish => '完成';

  @override
  String get commonClose => '關閉';

  @override
  String get commonOther => '其他';

  @override
  String get commonYesterday => '昨天';

  @override
  String get commonSearch => '搜尋';

  @override
  String get commonNoteHint => '備註…';

  @override
  String get commonSettings => '設定';

  @override
  String get commonGoSettings => '前往設定';

  @override
  String get commonLanguage => '語言';

  @override
  String get commonCurrent => '當前';

  @override
  String get commonTutorial => '教學';

  @override
  String get commonConfigure => '配置';

  @override
  String get commonPressAgainToExit => '再按一次退出應用程式';

  @override
  String get commonWeekdayMonday => '星期一';

  @override
  String get commonWeekdayTuesday => '星期二';

  @override
  String get commonWeekdayWednesday => '星期三';

  @override
  String get commonWeekdayThursday => '星期四';

  @override
  String get commonWeekdayFriday => '星期五';

  @override
  String get commonWeekdaySaturday => '星期六';

  @override
  String get commonWeekdaySunday => '星期日';

  @override
  String get homeIncome => '收入';

  @override
  String get homeExpense => '支出';

  @override
  String get homeBalance => '結餘';

  @override
  String get homeMonthIncome => '本月收入';

  @override
  String get homeMonthExpense => '本月支出';

  @override
  String homeBudgetSet(String amount) {
    return '預算 $amount';
  }

  @override
  String get homeNoRecords => '還沒有記帳';

  @override
  String get homeSelectDate => '選擇日期';

  @override
  String get homeAppTitle => '小豬記帳';

  @override
  String get homeSearch => '搜尋';

  @override
  String homeYear(int year) {
    return '$year年';
  }

  @override
  String homeMonth(String month) {
    return '$month月';
  }

  @override
  String get homeNoRecordsSubtext => '點擊底部加號，馬上記一筆';

  @override
  String get homeLastMonthReportSubtitle => '查看上月消費報告並分享';

  @override
  String get homeLastMonthReportView => '查看';

  @override
  String homeAnnualReportReminder(int year) {
    return '$year年度帳單已生成，回顧你的財務足跡';
  }

  @override
  String get homeAnnualReportView => '查看';

  @override
  String get widgetTodayExpense => '今日支出';

  @override
  String get widgetTodayIncome => '今日收入';

  @override
  String get widgetMonthExpense => '本月支出';

  @override
  String get widgetMonthIncome => '本月收入';

  @override
  String get widgetMonthSuffix => '月';

  @override
  String get widgetToday => '今日';

  @override
  String get widgetQuickAddLabel => '記一筆';

  @override
  String get widgetBudgetTotal => '總額';

  @override
  String get widgetBudgetRemaining => '剩';

  @override
  String get widgetNoBudget => '未設預算';

  @override
  String get widgetNoTransactions => '暫無交易';

  @override
  String get widgetRecentTransactions => '最近交易';

  @override
  String get widgetNoAccounts => '暫無帳戶';

  @override
  String get searchTitle => '搜尋';

  @override
  String get searchHint => '搜尋備註、分類或金額...';

  @override
  String get searchCategoryHint => '搜尋分類名稱...';

  @override
  String get searchCategoryFilter => '分類篩選';

  @override
  String get searchMinAmount => '最小金額';

  @override
  String get searchMaxAmount => '最大金額';

  @override
  String get searchNoInput => '輸入關鍵詞開始搜尋';

  @override
  String get searchNoResults => '未找到符合的結果';

  @override
  String get searchBatchMode => '批次操作';

  @override
  String searchBatchModeWithCount(int selected, int total) {
    return '批次操作 ($selected/$total)';
  }

  @override
  String get searchExitBatchMode => '退出批次操作';

  @override
  String get searchSelectAll => '全選';

  @override
  String get searchDeselectAll => '取消全選';

  @override
  String searchSelectedCount(int count) {
    return '已選擇 $count 項';
  }

  @override
  String get searchBatchSetNote => '設定備註';

  @override
  String get searchBatchChangeCategory => '調整分類';

  @override
  String get searchBatchDeleteConfirmTitle => '確認刪除';

  @override
  String searchBatchDeleteConfirmMessage(int count) {
    return '確定要刪除選中的 $count 筆記帳嗎?\n刪除後可在回收筒找回。';
  }

  @override
  String get searchBatchDeleteReconfirmMessage => '再次確認：這些記帳將移入回收筒。確定要繼續嗎？';

  @override
  String get searchBatchSetNoteTitle => '批次設定備註';

  @override
  String searchBatchSetNoteMessage(int count) {
    return '將為選中的 $count 筆記帳設定相同的備註';
  }

  @override
  String get searchBatchSetNoteHint => '輸入備註內容 (留空則清空備註)';

  @override
  String searchBatchDeleteSuccess(int count) {
    return '已將 $count 筆記帳移入回收筒';
  }

  @override
  String searchBatchDeleteFailed(String error) {
    return '刪除失敗: $error';
  }

  @override
  String searchBatchSetNoteSuccess(int count) {
    return '成功為 $count 筆記帳設定備註';
  }

  @override
  String searchBatchSetNoteFailed(String error) {
    return '設定備註失敗: $error';
  }

  @override
  String searchBatchChangeCategorySuccess(int count) {
    return '成功為 $count 筆記帳調整分類';
  }

  @override
  String searchBatchChangeCategoryFailed(String error) {
    return '調整分類失敗: $error';
  }

  @override
  String searchResultsCount(int count) {
    return '共 $count 條結果';
  }

  @override
  String get searchSummaryIncome => '收入';

  @override
  String get searchSummaryExpense => '支出';

  @override
  String get searchFilterTitle => '篩選';

  @override
  String get searchAmountFilter => '金額篩選';

  @override
  String get searchDateFilter => '時間篩選';

  @override
  String get searchStartDate => '開始日期';

  @override
  String get searchEndDate => '結束日期';

  @override
  String get searchNotSet => '未設定';

  @override
  String get searchClearFilter => '清空篩選';

  @override
  String get searchBatchCategoryTransferError => '選中的交易包含轉帳，無法修改分類';

  @override
  String get searchBatchCategoryTypeError => '選中的交易類型不一致，請選擇全部為收入或全部為支出的交易';

  @override
  String get searchDateStart => '開始';

  @override
  String get searchDateEnd => '結束';

  @override
  String get analyticsWeek => '週';

  @override
  String get analyticsMonth => '月';

  @override
  String analyticsWeekTotal(Object type) {
    return '本週$type： ';
  }

  @override
  String get analyticsComparedToLastWeek => '比上週';

  @override
  String get analyticsThisWeek => '本週';

  @override
  String get analyticsThisMonth => '本月';

  @override
  String get analyticsThisYear => '今年';

  @override
  String analyticsTrendTitle(Object period) {
    return '$period趨勢';
  }

  @override
  String analyticsCategoryComposition(Object type) {
    return '$type分類構成';
  }

  @override
  String analyticsTxCountShort(Object count) {
    return '$count筆';
  }

  @override
  String get analyticsYear => '年';

  @override
  String get analyticsAll => '全部';

  @override
  String get analyticsTotalAmount => '總計';

  @override
  String get analyticsNoDataSubtext => '可左右滑動切換週期，或點擊按鈕切換收入/支出';

  @override
  String get analyticsSwipeHint => '左右滑動切換週期';

  @override
  String analyticsSwitchTo(String type) {
    return '切換到$type';
  }

  @override
  String get analyticsAllYears => '全部年份';

  @override
  String get splashAppName => '小豬記帳';

  @override
  String get splashSlogan => '小豬記帳，越來越棒';

  @override
  String get splashSecurityTitle => '開源資料安全';

  @override
  String get splashSecurityFeature1 => '• 資料本地儲存，隱私完全自控';

  @override
  String get splashSecurityFeature2 => '• 開源程式碼透明，安全值得信賴';

  @override
  String get splashSecurityFeature3 => '• 可選雲端同步，多裝置資料一致';

  @override
  String get splashInitializing => '正在初始化資料...';

  @override
  String get ledgersTitle => '帳本管理';

  @override
  String get ledgersNew => '新建帳本';

  @override
  String get ledgersClear => '清空當前帳本';

  @override
  String ledgersClearMessage(String name) {
    return '將刪除該帳本下所有交易記錄，且不可復原。';
  }

  @override
  String get ledgersClearReconfirmMessage =>
      '再次確認：清空後帳本內的帳單資料將永久刪除、無法復原。確定要繼續嗎？';

  @override
  String get ledgerDefaultName => '預設帳本';

  @override
  String get ledgersEdit => '編輯帳本';

  @override
  String get ledgersDelete => '刪除帳本';

  @override
  String get ledgersDeleteConfirm => '刪除帳本';

  @override
  String get ledgersDeleteMessage =>
      '確定要刪除該帳本及其全部記錄嗎？此操作不可復原。\n若雲端存在備份，也會一併刪除。';

  @override
  String get ledgersDeleteReconfirmMessage =>
      '再次確認：刪除後該帳本及其全部記錄將永久消失（含雲端備份），無法復原。確定要繼續嗎？';

  @override
  String get ledgersDeleted => '已刪除';

  @override
  String get ledgersDeleteFailed => '刪除失敗';

  @override
  String get ledgersClearTitle => '清空帳本';

  @override
  String get ledgersClearSuccess => '帳本已清空';

  @override
  String get ledgersDeleteLocal => '僅刪除本地帳本';

  @override
  String get ledgersDeleteLocalTitle => '刪除本地帳本';

  @override
  String ledgersDeleteLocalMessage(String name) {
    return '確定要刪除本地帳本「$name」嗎？\n雲端備份會保留，您可以隨時恢復。';
  }

  @override
  String get ledgersDeleteLocalReconfirmMessage =>
      '再次確認：僅刪除本機上的該帳本，雲端備份保留、可隨時恢復下載。確定要繼續嗎？';

  @override
  String get ledgersDeleteLocalSuccess => '本地帳本已刪除';

  @override
  String get ledgersName => '名稱';

  @override
  String get ledgersDefaultLedgerName => '預設帳本';

  @override
  String get ledgersCurrency => '幣種';

  @override
  String get ledgersMonthStartDay => '每月起始日';

  @override
  String get ledgersMonthStartDayHint => '統計與預算按該日作為每月週期起點（1-28）';

  @override
  String get ledgersMonthStartDayNatural => '1日（自然月）';

  @override
  String ledgersMonthStartDayValue(int day) {
    return '每月$day日';
  }

  @override
  String get ledgersSelectCurrency => '選擇幣種';

  @override
  String get ledgersSearchCurrency => '搜尋：中文或代碼';

  @override
  String get ledgersCreate => '建立';

  @override
  String get ledgersActions => '操作';

  @override
  String ledgersRecords(String count) {
    return '筆數：$count';
  }

  @override
  String ledgersBalance(String balance) {
    return '餘額：$balance';
  }

  @override
  String get ledgerCardDownloadCloud => '下載雲帳本';

  @override
  String get ledgerCardCloudUploaded => '雲端上傳時間';

  @override
  String ledgersRestoreAllDuplicateSlots(String detail) {
    return '注意：以下名稱在雲端存在多個槽位，全部復原會依次相互覆蓋，本機最終只保留其中一個（如需逐一選別，可先在上方卡片按 ID 與上傳時間選擇下載）：$detail';
  }

  @override
  String get ledgersLocal => '本地帳本';

  @override
  String get ledgersRemote => '雲端帳本';

  @override
  String get ledgersEmpty => '暫無帳本';

  @override
  String get ledgersRestoreAll => '全部恢復';

  @override
  String ledgersSwitched(String name) {
    return '已切換到帳本「$name」';
  }

  @override
  String get ledgersDownloadTitle => '下載帳本';

  @override
  String ledgersDownloadMessage(String name) {
    return '確認下載帳本「$name」到本地？本地同名帳本的資料將被雲端資料覆蓋。';
  }

  @override
  String ledgersDownloadSuccess(String name) {
    return '帳本「$name」下載成功';
  }

  @override
  String get ledgersDownload => '下載';

  @override
  String get ledgersDeleteRemote => '刪除雲端帳本';

  @override
  String get ledgersDeleteRemoteConfirm => '刪除雲端帳本';

  @override
  String ledgersDeleteRemoteMessage(String name) {
    return '確認刪除雲端帳本「$name」？此操作無法復原。';
  }

  @override
  String get ledgersDeleteRemoteReconfirmMessage =>
      '再次確認：刪除後雲端該帳本及其全部資料將永久消失，多裝置將無法再恢復它。確定要繼續嗎？';

  @override
  String get ledgersDeleting => '刪除中...';

  @override
  String get ledgersDeleteRemoteSuccess => '已刪除雲端帳本';

  @override
  String get ledgersRestoreAllTitle => '批次恢復';

  @override
  String ledgersRestoreAllMessage(int count) {
    return '確認恢復所有雲端帳本？共 $count 個。';
  }

  @override
  String get ledgersRestoreAllReconfirmMessage =>
      '再次確認：恢復將用雲端內容覆蓋本機帳本資料，被覆蓋的本機變更無法找回。確定要繼續嗎？';

  @override
  String get ledgersRestoreComplete => '恢復完成';

  @override
  String ledgersRestoreResult(int success, int failed) {
    return '成功: $success，失敗: $failed';
  }

  @override
  String get ledgersUploadAll => '全部上傳';

  @override
  String ledgersUploadAllMessage(int count) {
    return '確認將 $count 個本機帳本上傳到雲端？雲端現有內容將被本機內容覆蓋。';
  }

  @override
  String get ledgersUploadAllReconfirmMessage => '再次確認：覆蓋後雲端原有資料無法復原，確定要繼續嗎？';

  @override
  String get ledgersUploadAllComplete => '上傳完成';

  @override
  String ledgersUploadAllResult(int success, int failed) {
    return '成功: $success，失敗: $failed';
  }

  @override
  String ledgersUploadAllConflictSkipped(int success, int conflicts) {
    return '已上傳 $success 個帳本；$conflicts 個帳本因雲端較新被跳過，請核對後逐個上傳。';
  }

  @override
  String ledgersUploadingProgress(int done, int total) {
    return '正在上傳帳本 $done/$total，請勿操作…';
  }

  @override
  String get ledgersUploadThis => '上傳到雲端';

  @override
  String get categoryTitle => '分類管理';

  @override
  String get categoryNew => '新建分類';

  @override
  String get categoryExpense => '支出分類';

  @override
  String get categoryIncome => '收入分類';

  @override
  String get categoryEmpty => '暫無分類';

  @override
  String get categoryReorderTip => '長按分類可拖曳調整順序';

  @override
  String categoryLoadFailed(String error) {
    return '載入失敗: $error';
  }

  @override
  String get iconPickerTitle => '選擇圖示';

  @override
  String get iconCategoryTransport => '交通';

  @override
  String get iconCategoryShopping => '購物';

  @override
  String get iconCategoryEntertainment => '娛樂';

  @override
  String get iconCategoryLife => '生活';

  @override
  String get iconCategoryHealth => '健康';

  @override
  String get iconCategoryEducation => '學習';

  @override
  String get iconCategoryWork => '工作';

  @override
  String get iconCategoryFinance => '理財';

  @override
  String get iconCategoryReward => '獎勵';

  @override
  String get iconCategoryOther => '其他';

  @override
  String get iconCategoryDining => '餐飲';

  @override
  String get iconLabelRestaurant => '餐廳';

  @override
  String get iconLabelLocalDining => '用餐';

  @override
  String get iconLabelFastfood => '快餐';

  @override
  String get iconLabelLocalCafe => '咖啡';

  @override
  String get iconLabelLocalBar => '酒吧';

  @override
  String get iconLabelCake => '蛋糕';

  @override
  String get iconLabelLocalPizza => '披薩';

  @override
  String get iconLabelIcecream => '冰淇淋';

  @override
  String get iconLabelDirectionsCar => '汽車';

  @override
  String get iconLabelDirectionsBus => '公車';

  @override
  String get iconLabelDirectionsSubway => '捷運';

  @override
  String get iconLabelLocalTaxi => '計程車';

  @override
  String get iconLabelFlight => '飛機';

  @override
  String get iconLabelTrain => '火車';

  @override
  String get iconLabelDirectionsBike => '自行車';

  @override
  String get iconLabelDirectionsWalk => '步行';

  @override
  String get iconLabelLocalGasStation => '加油';

  @override
  String get iconLabelLocalParking => '停車';

  @override
  String get iconLabelShoppingCart => '購物車';

  @override
  String get iconLabelShoppingBag => '購物袋';

  @override
  String get iconLabelStore => '商店';

  @override
  String get iconLabelLocalMall => '商場';

  @override
  String get iconLabelLocalGroceryStore => '超市';

  @override
  String get iconLabelCheckroom => '服裝';

  @override
  String get iconLabelWatch => '手錶';

  @override
  String get iconLabelDiamond => '珠寶';

  @override
  String get iconLabelMovie => '電影';

  @override
  String get iconLabelMusicNote => '音樂';

  @override
  String get iconLabelSportsEsports => '遊戲';

  @override
  String get iconLabelSportsSoccer => '足球';

  @override
  String get iconLabelSportsBasketball => '籃球';

  @override
  String get iconLabelTheaterComedy => '娛樂';

  @override
  String get iconLabelCameraAlt => '攝影';

  @override
  String get iconLabelPalette => '藝術';

  @override
  String get iconLabelHome => '居家';

  @override
  String get iconLabelLocalLaundryService => '洗衣';

  @override
  String get iconLabelCleaningServices => '清潔';

  @override
  String get iconLabelPlumbing => '維修';

  @override
  String get iconLabelElectricalServices => '電工';

  @override
  String get iconLabelHandyman => '維護';

  @override
  String get iconLabelPets => '寵物';

  @override
  String get iconLabelChildCare => '母嬰';

  @override
  String get iconLabelLocalHospital => '醫院';

  @override
  String get iconLabelMedicalServices => '醫療';

  @override
  String get iconLabelLocalPharmacy => '藥局';

  @override
  String get iconLabelFitnessCenter => '健身';

  @override
  String get iconLabelSpa => '美容';

  @override
  String get iconLabelPsychology => '心理';

  @override
  String get iconLabelFace => '護膚';

  @override
  String get iconLabelContentCut => '理髮';

  @override
  String get iconLabelSchool => '學校';

  @override
  String get iconLabelLibraryBooks => '書籍';

  @override
  String get iconLabelComputer => '電腦';

  @override
  String get iconLabelPhone => '通訊';

  @override
  String get iconLabelLanguage => '語言';

  @override
  String get iconLabelScience => '科學';

  @override
  String get iconLabelCalculate => '計算';

  @override
  String get iconLabelBrush => '繪畫';

  @override
  String get iconLabelBusiness => '商務';

  @override
  String get iconLabelWork => '工作';

  @override
  String get iconLabelFlashOn => '水電';

  @override
  String get iconLabelWifi => '網路';

  @override
  String get iconLabelPhoneAndroid => '手機';

  @override
  String get iconLabelSmokingRooms => '煙酒';

  @override
  String get iconLabelFavorite => '捐贈';

  @override
  String get iconLabelCategory => '其他';

  @override
  String get iconLabelSalary => '工資';

  @override
  String get iconLabelBusinessCenter => '商務';

  @override
  String get iconLabelEngineering => '技術';

  @override
  String get iconLabelDesignServices => '設計';

  @override
  String get iconLabelAgriculture => '農業';

  @override
  String get iconLabelConstruction => '建築';

  @override
  String get iconLabelLocalShipping => '物流';

  @override
  String get iconLabelRestaurantMenu => '餐飲';

  @override
  String get iconLabelAccountBalance => '銀行';

  @override
  String get iconLabelSavings => '儲蓄';

  @override
  String get iconLabelTrendingUp => '投資';

  @override
  String get iconLabelPaid => '利息';

  @override
  String get iconLabelCurrencyExchange => '匯率';

  @override
  String get iconLabelWallet => '錢包';

  @override
  String get iconLabelCreditCard => '信用卡';

  @override
  String get iconLabelAccountBalanceWallet => '餘額';

  @override
  String get iconLabelCardGiftcard => '紅包';

  @override
  String get iconLabelRedeem => '獎金';

  @override
  String get iconLabelEmojiEvents => '獎勵';

  @override
  String get iconLabelStar => '評級';

  @override
  String get iconLabelGrade => '等級';

  @override
  String get iconLabelLoyalty => '積分';

  @override
  String get iconLabelVolunteerActivism => '禮金';

  @override
  String get iconLabelCelebration => '慶祝';

  @override
  String get iconLabelReceiptLong => '報銷';

  @override
  String get iconLabelPartTime => '兼職';

  @override
  String get iconLabelUndo => '退款';

  @override
  String get iconLabelMoney => '現金';

  @override
  String get iconLabelApartment => '租金';

  @override
  String get iconLabelHandshake => '合作';

  @override
  String get iconLabelHelp => '未分類';

  @override
  String get tooltipSend => '傳送';

  @override
  String get tooltipShare => '分享';

  @override
  String get tooltipPaste => '貼上';

  @override
  String get tooltipTogglePassword => '顯示或隱藏密碼';

  @override
  String get tooltipToggleVisibility => '顯示或隱藏';

  @override
  String get tooltipAddAttachment => '新增附件';

  @override
  String get tooltipClear => '清除';

  @override
  String get tooltipPreview => '預覽';

  @override
  String get tooltipRefresh => '重新整理';

  @override
  String get importTitle => '匯入帳單';

  @override
  String get importBillType => '帳單類型';

  @override
  String get importBillTypeGeneric => '通用CSV';

  @override
  String get importBillTypeAlipay => '支付寶';

  @override
  String get importBillTypeWechat => '微信';

  @override
  String get importChooseFile => '選擇檔案';

  @override
  String get importNoFileSelected => '未選擇檔案';

  @override
  String get importHint => '提示：請選擇一個檔案開始匯入（支援 CSV/TSV/XLSX）';

  @override
  String get importReading => '讀取檔案中…';

  @override
  String get importPreparing => '準備中…';

  @override
  String importColumnNumber(Object number) {
    return '第$number列';
  }

  @override
  String get importConfirmMapping => '確認對應';

  @override
  String get importCategoryMapping => '分類對應';

  @override
  String get importNoDataParsed => '未解析到任何資料，請返回上一頁檢查 CSV 內容或分隔符。';

  @override
  String get importFieldDate => '日期';

  @override
  String get importFieldType => '類型';

  @override
  String get importFieldAmount => '金額';

  @override
  String get importFieldCategory => '分類';

  @override
  String get importFieldAccount => '帳戶';

  @override
  String get importFieldNote => '備註';

  @override
  String get importPreview => '資料預覽';

  @override
  String importPreviewLimit(Object shown, Object total) {
    return '僅預覽前 $shown 行，共 $total 行';
  }

  @override
  String get importCategoryNotSelected =>
      '未選擇\"分類\"列，請點擊\"上一步\"返回並設定\"分類\"的列，再繼續。';

  @override
  String get importCategoryMappingDescription =>
      '請將左側\"源分類名\"對應到系統內已有分類（或保持原名自動建立/合併）';

  @override
  String get importKeepOriginalName => '保持原名（自動建立/合併）';

  @override
  String importProgress(Object fail, Object ok) {
    return '匯入中… 成功 $ok，失敗 $fail';
  }

  @override
  String get importCancelImport => '取消匯入';

  @override
  String get importCompleteTitle => '匯入完成';

  @override
  String get importSelectCategoryFirst => '請先選擇\"分類\"列再繼續';

  @override
  String get importNextStep => '下一步';

  @override
  String get importPreviousStep => '上一步';

  @override
  String get importStartImport => '開始匯入';

  @override
  String get importAutoDetect => '自動檢測';

  @override
  String get importInProgress => '正在匯入…';

  @override
  String importProgressDetail(
      Object done, Object fail, Object ok, Object total) {
    return '已完成：$done/$total，成功 $ok，失敗 $fail';
  }

  @override
  String get importBackgroundImport => '背景匯入';

  @override
  String get importCancelled => '（已取消）';

  @override
  String importCompleted(Object cancelled, Object fail, Object ok) {
    return '匯入完成$cancelled：成功 $ok 條，失敗 $fail 條';
  }

  @override
  String importSkippedNonTransactionTypes(Object count) {
    return '跳過 $count 條非收支記錄（債務等）';
  }

  @override
  String importTransactionFailed(Object error) {
    return '匯入失敗，已回滾所有更改：$error';
  }

  @override
  String importFileOpenError(String error) {
    return '無法開啟檔案選擇器：$error';
  }

  @override
  String get mineCloudBackupSection => '雲端同步與備份';

  @override
  String get mineFunctionSection => '功能管理';

  @override
  String get mineHelpSection => '說明與資訊';

  @override
  String get mineSupportSection => '支持我們';

  @override
  String get mineImport => '匯入資料';

  @override
  String get mineExport => '匯出資料';

  @override
  String get mineLanguageSettings => '語言';

  @override
  String get languageTitle => '語言設定';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSystemDefault => '跟隨系統';

  @override
  String get deleteConfirmTitle => '刪除確認';

  @override
  String get deleteConfirmMessage => '確定要刪除這條記帳嗎？\n刪除後可在回收筒找回。';

  @override
  String get mineSlogan => '小豬記帳，越來越棒';

  @override
  String get mineDisplayNameEditTitle => '設定暱稱';

  @override
  String get mineDisplayNameHint => '輸入暱稱';

  @override
  String get mineDisplayNameSaved => '暱稱已更新';

  @override
  String get mineGreetingMorning => '早安';

  @override
  String get mineGreetingNoon => '中午好';

  @override
  String get mineGreetingAfternoon => '午安';

  @override
  String get mineGreetingEvening => '晚安';

  @override
  String get mineGreetingNight => '夜深了';

  @override
  String mineGreetingNamed(String greeting, String name) {
    return '$greeting，$name';
  }

  @override
  String get mineProfileEditTitle => '編輯資料';

  @override
  String get headerSkinTitle => '皮膚';

  @override
  String get headerSkinNone => '純色';

  @override
  String get headerSkinAurora => '極光';

  @override
  String get headerSkinMountains => '山巒';

  @override
  String get headerSkinBokeh => '光斑';

  @override
  String get headerSkinWaves => '波浪';

  @override
  String get headerSkinSunset => '日落';

  @override
  String get headerSkinClouds => '雲朵';

  @override
  String get headerSkinExample => '示例';

  @override
  String get headerSkinHoneycomb => '蜂巢';

  @override
  String get headerSkinStarry => '星河';

  @override
  String get headerSkinStripes => '斜紋';

  @override
  String get headerSkinSkyline => '城市';

  @override
  String get headerSkinSakura => '櫻花';

  @override
  String get headerSkinMeteor => '流星';

  @override
  String get headerSkinMemphis => '孟菲斯';

  @override
  String get headerSkinSilk => '絲帶';

  @override
  String get headerSkinBubbles => '氣泡';

  @override
  String get headerSkinGalaxy => '星系';

  @override
  String get headerSkinLowPoly => '低多邊形';

  @override
  String get headerSkinPrism => '稜鏡';

  @override
  String get headerSkinTerrazzo => '水磨石';

  @override
  String get mineAvatarFromGallery => '從相簿選擇';

  @override
  String get mineAvatarFromCamera => '拍照';

  @override
  String get mineAvatarDelete => '刪除頭像';

  @override
  String get annualReportTitle => '年度帳單';

  @override
  String annualReportSubtitle(int year) {
    return '回顧你的$year年財務足跡';
  }

  @override
  String get annualReportEntrySubtitle => '生成專屬年度報告，分享你的記帳故事';

  @override
  String annualReportNoData(int year) {
    return '暫無$year年資料';
  }

  @override
  String get annualReportPage1Title => '年度總覽';

  @override
  String annualReportPage1Subtitle(int year) {
    return '$year年記帳之旅';
  }

  @override
  String get annualReportTotalDays => '記帳天數';

  @override
  String get annualReportTotalRecords => '記帳筆數';

  @override
  String get annualReportTotalIncome => '總收入';

  @override
  String get annualReportTotalExpense => '總支出';

  @override
  String get annualReportNetSavings => '年度結餘';

  @override
  String get annualReportPage2Title => '支出分析';

  @override
  String get annualReportPage2Subtitle => '你的錢花在哪了';

  @override
  String get annualReportPage3Title => '月度趨勢';

  @override
  String get annualReportPage3Subtitle => '12個月的收支變化';

  @override
  String get annualReportHighestMonth => '支出最高月份';

  @override
  String get annualReportLowestMonth => '支出最低月份';

  @override
  String get annualReportPage4Title => '特別時刻';

  @override
  String get annualReportPage4Subtitle => '那些值得銘記的帳單';

  @override
  String get annualReportLargestExpense => '年度最大支出';

  @override
  String get annualReportLargestIncome => '年度最大收入';

  @override
  String get annualReportFirstRecord => '第一筆記錄';

  @override
  String get annualReportPage5Title => '年度成就';

  @override
  String get annualReportPage5Subtitle => '你的記帳成就徽章';

  @override
  String get annualReportAchievementConsistent => '持之以恆';

  @override
  String annualReportAchievementConsistentDesc(int days) {
    return '連續記帳超過$days天';
  }

  @override
  String get annualReportAchievementSaver => '精打細算';

  @override
  String get annualReportAchievementSaverDesc => '年度結餘為正';

  @override
  String get annualReportAchievementDetail => '明察秋毫';

  @override
  String annualReportAchievementDetailDesc(int count) {
    return '記帳筆數超過$count筆';
  }

  @override
  String get annualReportShareButton => '生成分享海報';

  @override
  String get annualReportGenerating => '正在生成年度報告...';

  @override
  String get annualReportSaveSuccess => '年度報告海報已儲存';

  @override
  String get mineShareApp => '分享應用程式';

  @override
  String get mineShareWithFriends => '和好友分享小豬記帳';

  @override
  String get mineCopyPromoText => '複製推廣文案';

  @override
  String get mineCopyPromoSubtitle => '一鍵複製分享給好友';

  @override
  String get mineShareGenerating => '正在生成分享海報...';

  @override
  String get sharePosterAppName => '小豬記帳';

  @override
  String get sharePosterSlogan => '一筆一蜜，記錄美好生活';

  @override
  String get sharePosterFeature1 => '資料安全·你做主';

  @override
  String get sharePosterFeature2 => '完全開源·可審計';

  @override
  String get sharePosterFeature3 => 'AI智能記帳·圖片語音';

  @override
  String get sharePosterFeature4 => '拍照記帳·自動識別';

  @override
  String get sharePosterFeature5 => '多帳本·暗黑模式';

  @override
  String get sharePosterFeature6 => '自建雲同步·永久免費';

  @override
  String get sharePosterScanText => '掃碼訪問開源專案';

  @override
  String get appPromoTagOpenSource => '開源';

  @override
  String get appPromoTagFree => '免費';

  @override
  String get appPromoFooterText => '讓每一筆都有跡可循';

  @override
  String userProfileJourneyYears(int years) {
    return '記帳達人 $years 年';
  }

  @override
  String get userProfileJourneyOneYear => '記帳滿一年';

  @override
  String get userProfileJourneyHalfYear => '堅持記帳半年';

  @override
  String get userProfileJourneyThreeMonths => '記帳三個月';

  @override
  String get userProfileJourneyOneMonth => '記帳滿一個月';

  @override
  String get userProfileJourneyOneWeek => '記帳一週';

  @override
  String get userProfileJourneyStart => '開始記帳之旅';

  @override
  String get userProfileDailyAverage => '日均記帳';

  @override
  String get sharePosterSave => '儲存到相簿';

  @override
  String get sharePosterShare => '分享';

  @override
  String get sharePosterHideIncome => '隱藏收入';

  @override
  String get sharePosterShowIncome => '顯示收入';

  @override
  String get sharePosterSaveSuccess => '已儲存到相簿';

  @override
  String get shareGuidanceCopyText =>
      '用小豬記帳記錄生活，開源免費無廣告！🐷 下載地址：https://github.com/mecoren/PiggyCount';

  @override
  String get shareGuidanceCopied => '文案已複製';

  @override
  String get sharePosterSaveFailed => '儲存失敗';

  @override
  String get sharePosterPermissionDenied => '相簿權限被拒絕，請在設定中開啟';

  @override
  String get sharePosterGenerating => '生成中...';

  @override
  String get sharePosterGenerateFailed => '生成海報失敗，請重試';

  @override
  String get sharePosterNoLedger => '請先選擇一個帳本';

  @override
  String get sharePosterYearTitle => '我的記帳年度報告';

  @override
  String get sharePosterYearSubtitle => '用數據記錄生活 用理性規劃未來';

  @override
  String get sharePosterMonthTitle => '月度帳單報告';

  @override
  String get sharePosterMonthSubtitle => '精打細算 理性消費';

  @override
  String get sharePosterLedgerTitle => '帳本統計報告';

  @override
  String get sharePosterRecordDays => '記帳天數';

  @override
  String get sharePosterRecordCount => '記帳筆數';

  @override
  String get sharePosterTotalExpense => '總支出';

  @override
  String get sharePosterTotalIncome => '總收入';

  @override
  String get sharePosterYearBalance => '年度結餘';

  @override
  String get sharePosterYearDeficit => '年度赤字';

  @override
  String get sharePosterMonthBalance => '月度結餘';

  @override
  String get sharePosterBalance => '總結餘';

  @override
  String get sharePosterAvgMonthlyExpense => '月均支出';

  @override
  String get sharePosterAvgMonthlyIncome => '月均收入';

  @override
  String get sharePosterAvgDailyExpense => '日均支出';

  @override
  String get sharePosterMaxExpenseMonth => '支出最高月份';

  @override
  String get sharePosterTopExpense => 'TOP 3 支出';

  @override
  String get sharePosterCompareLastMonth => '環比上月';

  @override
  String get sharePosterIncreaseRate => '較上月增長';

  @override
  String get sharePosterDecreaseRate => '較上月減少';

  @override
  String get sharePosterSavedMoneyTitle => '恭喜！本月比上月省了';

  @override
  String get sharePosterLedgerName => '帳本名稱';

  @override
  String get sharePosterUnitDay => '天';

  @override
  String get sharePosterUnitCount => '筆';

  @override
  String userProfilePosterStartDate(String date) {
    return '記帳始於 $date';
  }

  @override
  String get userProfilePosterRecordDays => '記帳天數';

  @override
  String get userProfilePosterDaysUnit => '天';

  @override
  String get userProfilePosterRecordCount => '記帳筆數';

  @override
  String get userProfilePosterCountUnit => '筆';

  @override
  String get userProfilePosterDailyUnit => '筆/天';

  @override
  String get userProfilePosterLedgerCount => '帳本數量';

  @override
  String get userProfilePosterLedgerUnit => '本';

  @override
  String get mineDaysCount => '記帳天數';

  @override
  String get mineTotalRecords => '總筆數';

  @override
  String get mineCurrentBalance => '帳本結餘';

  @override
  String get mineCloudService => '雲服務';

  @override
  String get mineCloudServiceLoading => '載入中…';

  @override
  String get mineCloudServiceOffline => '預設模式 (離線)';

  @override
  String get mineCloudServiceCustom => '自訂 Supabase';

  @override
  String get mineCloudServiceWebDAV => '自訂雲服務 (WebDAV)';

  @override
  String get mineSyncTitle => '同步';

  @override
  String get mineSyncChecking => '同步中…';

  @override
  String get mineSyncNotLoggedIn => '未登入';

  @override
  String get mineSyncNotConfigured => '未設定雲端';

  @override
  String get mineSyncNoRemote => '雲端暫無資料';

  @override
  String mineSyncInSync(Object count) {
    return '已同步 (本地$count條)';
  }

  @override
  String get mineSyncInSyncSimple => '已同步';

  @override
  String mineSyncLocalNewer(Object count) {
    return '本機有更新 (本機$count條, 建議上傳)';
  }

  @override
  String get mineSyncLocalNewerSimple => '本機有更新';

  @override
  String get mineSyncCloudNewer => '雲端有更新 (建議下載同步)';

  @override
  String get mineSyncCloudNewerSimple => '雲端有更新';

  @override
  String get mineSyncDifferent => '本機與雲端有差異，建議下載對比';

  @override
  String syncPendingCloudDeletesMark(int count) {
    return '有 $count 筆雲端刪除待處理（預設不自動套用；以雲端為準請用下方「全量下載」）';
  }

  @override
  String get syncDirectionUnknownHint =>
      '方向無法判定（兩端都有本機獨有變更），可於下方用「全量下載」或「全量上傳」以其中一端為準';

  @override
  String get mineSyncError => '狀態取得失敗';

  @override
  String get mineSyncDetailTitle => '同步狀態詳情';

  @override
  String mineSyncLocalRecords(Object count) {
    return '本地記錄數: $count';
  }

  @override
  String mineSyncCloudRecords(Object count) {
    return '雲端記錄數: $count';
  }

  @override
  String mineSyncCloudLatest(Object time) {
    return '雲端最新記帳時間: $time';
  }

  @override
  String mineSyncLocalFingerprint(Object fingerprint) {
    return '本地指紋: $fingerprint';
  }

  @override
  String mineSyncCloudFingerprint(Object fingerprint) {
    return '雲端指紋: $fingerprint';
  }

  @override
  String mineSyncMessage(Object message) {
    return '說明: $message';
  }

  @override
  String get mineUploadTitle => '上傳';

  @override
  String get mineUploadNeedLogin => '需登入';

  @override
  String get mineUploadNeedCloudService => '僅限雲端服務模式可用';

  @override
  String get mineUploadInProgress => '正在上傳中…';

  @override
  String get mineUploadRefreshing => '重新整理中…';

  @override
  String get mineUploadSynced => '已同步';

  @override
  String get mineUploadSuccess => '已上傳';

  @override
  String get mineUploadSuccessMessage => '所有帳本已同步到雲端';

  @override
  String get mineUploadUnverified => '已上傳但未確認收斂';

  @override
  String get mineUploadUnverifiedMessage =>
      '資料已上傳到雲端，但未能確認雲端內容與本次寫入一致（可能被其他裝置並行更新）。下次同步時會自動重新比對，無需立即處理。';

  @override
  String get backupRestoreInterrupted => '偵測到上次恢復未完成';

  @override
  String get backupRestoreInterruptedMessage =>
      '上次從備份恢復時程序被中斷，資料可能處於半恢復狀態，自動備份已暫停。重新執行一次恢復即可修復（恢復是覆蓋式，重複執行安全）。';

  @override
  String get syncBlockingDownloadTitle => '下載同步';

  @override
  String get syncBlockingUploadTitle => '上傳同步';

  @override
  String get syncBlockingCheckCloud => '正在檢查雲端帳本…';

  @override
  String syncBlockingDownloadLedger(int n, int m) {
    return '正在下載帳本 $n/$m…';
  }

  @override
  String get syncBlockingApplying => '正在套用變更…';

  @override
  String get fullUploadTitle => '全量上傳';

  @override
  String get fullUploadSubtitle => '以本地全部帳本覆蓋雲端';

  @override
  String get fullDownloadTitle => '全量下載';

  @override
  String get fullDownloadSubtitle => '以雲端全部帳本覆蓋本地';

  @override
  String fullUploadConfirm1Message(int count) {
    return '將把本地 $count 個帳本全量上傳，雲端對應的帳本資料將被本地資料完全覆蓋。雲端獨有的帳本會保留。';
  }

  @override
  String get fullUploadConfirm2Message => '再次確認：覆蓋後雲端原有資料無法復原，確定要繼續嗎？';

  @override
  String get fullDownloadConfirm1Message =>
      '雲端全部帳本將完全覆蓋本地對應的帳本，雲端獨有的帳本會匯入為新建帳本。本地獨有的帳本會保留。';

  @override
  String get fullDownloadConfirm2Message => '再次確認：覆蓋後本地原有資料無法復原，確定要繼續嗎？';

  @override
  String dangerConfirmCountdown(int seconds) {
    return '確認（$seconds秒）';
  }

  @override
  String get fullUploadBlockingStatus => '正在全量上傳所有本地帳本…';

  @override
  String get fullDownloadBlockingStatus => '正在全量還原所有雲端帳本…';

  @override
  String get fullUploadNoLedgers => '沒有可上傳的本地帳本。';

  @override
  String get fullUploadSuccessMessage => '全量上傳完成，雲端已與本地資料一致。';

  @override
  String fullDownloadResult(int success, int failed) {
    return '全量下載完成：成功 $success 個，失敗 $failed 個。';
  }

  @override
  String get fullSyncUnsupported => '目前雲端後端不支援全量覆蓋同步。';

  @override
  String get ledgersRestoreBlockingStatus => '正在從雲端恢復帳本…';

  @override
  String get ledgersUploadOneBlockingStatus => '正在上傳帳本…';

  @override
  String get ledgersDownloadOneBlockingStatus => '正在下載帳本…';

  @override
  String get encryptionBlockingVerifying => '正在驗證雲端加密資料…';

  @override
  String get encryptionBlockingReencrypt => '正在加密雲端資料…';

  @override
  String get encryptionBlockingReinit => '正在初始化加密同步…';

  @override
  String get encryptionBlockingChangePassword => '正在重新加密雲端資料…';

  @override
  String get encryptionBlockingReset => '正在重置加密…';

  @override
  String get mineDownloadTitle => '下載同步';

  @override
  String get mineDownloadNeedCloudService => '僅限雲端服務模式可用';

  @override
  String get mineDownloadComplete => '同步完成';

  @override
  String mineDownloadResult(Object inserted) {
    return '匯入：$inserted 條';
  }

  @override
  String get mineLoginTitle => '登入';

  @override
  String get mineLoginSubtitle => '僅在同步時需要';

  @override
  String get mineLoggedInEmail => '已登入';

  @override
  String get mineLogoutSubtitle => '點擊可退出登入';

  @override
  String get mineLogoutConfirmTitle => '退出登入';

  @override
  String get mineLogoutConfirmMessage => '確定要退出當前帳號登入嗎？\n退出後將無法使用雲同步功能。';

  @override
  String get mineLogoutButton => '退出';

  @override
  String get mineAutoSyncTitle => '自動同步帳本';

  @override
  String get mineAutoSyncSubtitle => '記帳後自動上傳到雲端';

  @override
  String get mineAutoSyncNeedLogin => '需登入後可開啟';

  @override
  String get mineImportProgressTitle => '後台匯入中…';

  @override
  String mineImportProgressSubtitle(
      Object done, Object fail, Object ok, Object total) {
    return '進度：$done/$total，成功 $ok，失敗 $fail';
  }

  @override
  String get mineImportCompleteTitle => '匯入完成';

  @override
  String get mineCategoryManagement => '分類管理';

  @override
  String get mineCategoryManagementSubtitle => '編輯自訂分類';

  @override
  String get mineCategoryMigration => '分類遷移';

  @override
  String get mineCategoryMigrationSubtitle => '將分類資料遷移到其他分類';

  @override
  String get mineRecurringTransactions => '週期帳單';

  @override
  String get mineRecurringTransactionsSubtitle => '管理週期性帳單';

  @override
  String get mineReminderSettings => '記帳提醒';

  @override
  String get mineReminderSettingsSubtitle => '設定每日記帳提醒';

  @override
  String get mineDisplayScale => '顯示縮放';

  @override
  String get mineDisplayScaleSubtitle => '調整文字和介面元素大小';

  @override
  String get mineCheckUpdate => '檢測更新';

  @override
  String get helpCenterOpenInBrowser => '在瀏覽器中開啟';

  @override
  String get helpCenterLoadFailed => '載入失敗，請檢查網路';

  @override
  String get helpCenterRetry => '重試';

  @override
  String get categoryEditTitle => '編輯分類';

  @override
  String get categoryNewTitle => '新建分類';

  @override
  String get categoryDetailTooltip => '分類詳情';

  @override
  String get categoryMigrationTooltip => '分類遷移';

  @override
  String get categoryMigrationTitle => '分類遷移';

  @override
  String get categoryMigrationDescription => '分類遷移說明';

  @override
  String get categoryMigrationDescriptionContent =>
      '• 將指定分類的所有交易記錄遷移到另一個分類\n• 遷移後，原分類的交易資料將全部轉移到目標分類\n• 此操作不可撤銷，請謹慎選擇';

  @override
  String get categoryMigrationTypeLabel => '選擇類型';

  @override
  String get categoryMigrationFromLabel => '遷出分類';

  @override
  String get categoryMigrationFromHint => '選擇要遷出的分類';

  @override
  String get categoryMigrationToLabel => '遷入分類';

  @override
  String get categoryMigrationToHint => '選擇遷入的分類';

  @override
  String get categoryMigrationToHintFirst => '請先選擇遷出分類';

  @override
  String get categoryMigrationStartButton => '開始遷移';

  @override
  String get categoryMigrationCannotTitle => '無法遷移';

  @override
  String get categoryMigrationCannotMessage => '選擇的分類無法進行遷移，請檢查分類狀態。';

  @override
  String get categoryExpenseType => '支出分類';

  @override
  String get categoryIncomeType => '收入分類';

  @override
  String get categoryDefaultTitle => '預設分類';

  @override
  String get categoryNameLabel => '分類名稱';

  @override
  String get categoryNameHint => '請輸入分類名稱';

  @override
  String get categoryNameRequired => '請輸入分類名稱';

  @override
  String get categoryNameTooLong => '分類名稱不能超過4個字';

  @override
  String get categoryNameDuplicate => '分類名稱已存在';

  @override
  String get categoryIconLabel => '分類圖示';

  @override
  String get categoryCustomIconTitle => '自訂圖示';

  @override
  String get categoryCustomIconTapToSelect => '點擊選擇圖片';

  @override
  String get categoryCustomIconTapToChange => '點擊更換圖片';

  @override
  String get categoryCustomIconError => '選擇圖片時出錯';

  @override
  String get categoryCustomIconRequired => '請選擇自訂圖示圖片';

  @override
  String get categoryCustomIconCrop => '裁剪圖示';

  @override
  String get categoryDangerousOperations => '危險操作';

  @override
  String get categoryDeleteTitle => '刪除分類';

  @override
  String get categoryDeleteSubtitle => '刪除後無法復原';

  @override
  String get categorySaveError => '儲存失敗';

  @override
  String categoryUpdated(Object name) {
    return '分類\"$name\"已更新';
  }

  @override
  String categoryCreated(Object name) {
    return '分類\"$name\"已建立';
  }

  @override
  String get categoryCannotDelete => '無法刪除';

  @override
  String categoryCannotDeleteMessage(Object count) {
    return '該分類下還有 $count 筆交易記錄，請先處理這些記錄。';
  }

  @override
  String get categoryShare => '分享分類';

  @override
  String get categoryImport => '匯入分類';

  @override
  String get categoryClearUnused => '清空未使用分類';

  @override
  String get categoryClearUnusedTitle => '清空未使用分類';

  @override
  String categoryClearUnusedMessage(int count) {
    return '確定要刪除 $count 個未使用的分類嗎？此操作無法撤銷。';
  }

  @override
  String get categoryClearUnusedReconfirmMessage =>
      '再次確認：刪除後這些分類不可復原，若誤刪需要重新建立。確定要繼續嗎？';

  @override
  String get categoryClearUnusedListTitle => '將被刪除的分類：';

  @override
  String get categoryClearUnusedEmpty => '沒有未使用的分類';

  @override
  String categoryClearUnusedSuccess(int count) {
    return '已刪除 $count 個分類';
  }

  @override
  String get categoryClearUnusedFailed => '清空失敗';

  @override
  String get categoryShareScopeTitle => '選擇分享範圍';

  @override
  String get categoryShareScopeExpense => '僅支出分類';

  @override
  String get categoryShareScopeIncome => '僅收入分類';

  @override
  String get categoryShareScopeAll => '全部分類';

  @override
  String categoryShareSuccess(String path) {
    return '已儲存到 $path';
  }

  @override
  String get categoryShareSubject => 'PiggyCount 分類配置';

  @override
  String get categoryShareFailed => '分享失敗';

  @override
  String get categoryImportInvalidFile => '請選擇分類包檔案（.zip）';

  @override
  String get categoryImportModeTitle => '選擇匯入模式';

  @override
  String get categoryImportModeMerge => '合併';

  @override
  String get categoryImportModeMergeDesc => '保留現有分類，新增不存在的';

  @override
  String get categoryImportModeOverwrite => '覆蓋';

  @override
  String get categoryImportModeOverwriteDesc => '清空未使用分類後匯入';

  @override
  String categoryImportSuccessDetail(int imported, int skipped, int icons) {
    return '已匯入 $imported 個分類，跳過 $skipped 個，匯入 $icons 個圖示';
  }

  @override
  String get categoryImportFailed => '匯入失敗';

  @override
  String get categoryDeleteConfirmTitle => '刪除分類';

  @override
  String categoryDeleteConfirmMessage(Object name) {
    return '確定要刪除分類\"$name\"嗎？此操作無法撤銷。';
  }

  @override
  String get categoryDeleteError => '刪除失敗';

  @override
  String categoryDeleted(Object name) {
    return '分類\"$name\"已刪除';
  }

  @override
  String get categorySubCategoryTitle => '二級分類';

  @override
  String get categorySubCategoryDescriptionEnabled => '此分類屬於某個一級分類';

  @override
  String get categorySubCategoryDescriptionDisabled => '此分類為獨立的一級分類';

  @override
  String get categoryParentCategoryTitle => '父分類';

  @override
  String get categoryParentCategoryHint => '請選擇父分類';

  @override
  String get categorySelectParentTitle => '選擇父分類';

  @override
  String categorySubCategoryCreated(Object name) {
    return '已新增二級分類：$name';
  }

  @override
  String get categoryParentRequired => '請選擇父分類';

  @override
  String get categoryParentRequiredTitle => '錯誤';

  @override
  String get categoryExpenseList =>
      '餐飲-交通-購物-娛樂-居家-家庭-通訊-水電-住房-醫療-教育-寵物-運動-數碼-旅行-煙酒-母嬰-美容-維修-社交-學習-汽車-打車-地鐵-外賣-物業-停車-捐贈-送禮-納稅-飲料-服裝-零食-發紅包-水果-遊戲-書-愛人-裝修-日用品-彩票-股票-社保-快遞-工作';

  @override
  String get categoryIncomeList =>
      '工資-理財-收紅包-獎金-報銷-兼職-收禮-利息-退款-投資收益-二手轉賣-社會保障-退稅退費-公積金';

  @override
  String get categoryExpenseDining => '餐飲-早餐-午餐-晚餐-美團外賣-餓了麼外賣-京東外賣-餐廳-美食';

  @override
  String get categoryExpenseSnacks => '零食-餅乾-薯片-糖果-巧克力-堅果';

  @override
  String get categoryExpenseFruit => '水果-蘋果-香蕉-橙子-葡萄-西瓜-其他水果';

  @override
  String get categoryExpenseBeverage => '飲品-奶茶-咖啡-果汁-汽水-礦泉水';

  @override
  String get categoryExpensePastry => '糕點-蛋糕-麵包-甜點-曲奇';

  @override
  String get categoryExpenseCooking => '做飯食材-蔬菜-肉類-水產-調料-糧油';

  @override
  String get categoryExpenseShopping => '購物-服裝-鞋帽-包包-配飾-日用百貨';

  @override
  String get categoryExpensePets => '寵物-寵物食品-寵物用品-寵物醫療-寵物美容';

  @override
  String get categoryExpenseTransport => '交通-地鐵-公交-出租車-網約車-停車費-加油';

  @override
  String get categoryExpenseCar => '汽車-汽車保養-汽車維修-汽車保險-洗車-違章罰款';

  @override
  String get categoryExpenseClothing => '服飾-上衣-褲子-裙子-鞋子-服飾配件';

  @override
  String get categoryExpenseDailyGoods => '日用品-洗護用品-紙品-清潔用品-廚房用品';

  @override
  String get categoryExpenseEducation => '教育-學費-培訓費-書籍-文具-辦公用品';

  @override
  String get categoryExpenseInvestLoss => '投資虧損-股票虧損-基金虧損-其他投資虧損';

  @override
  String get categoryExpenseEntertainment => '娛樂-電影-KTV-遊樂場-酒吧-其他娛樂';

  @override
  String get categoryExpenseGame => '遊戲-遊戲儲值-遊戲裝備-遊戲會員';

  @override
  String get categoryExpenseHealthProducts => '保健品-維生素-保健食品-營養品';

  @override
  String get categoryExpenseSubscription => '訂閱服務-視頻會員-音樂會員-雲端儲存-其他訂閱';

  @override
  String get categoryExpenseSports => '運動-健身房-運動裝備-運動課程-戶外活動';

  @override
  String get categoryExpenseHousing => '住房-房租-物業費-房貸-裝修';

  @override
  String get categoryExpenseHome => '居家-傢俱-家電-裝飾品-床上用品';

  @override
  String get categoryExpenseBeauty => '美容-護膚品-化妝品-美容美髮-美甲';

  @override
  String get categoryIncomeSalary => '工資-基本工資-績效獎金-年終獎-加班費';

  @override
  String get categoryIncomeInvestment => '理財-基金收益-股票分紅-理財產品-其他理財';

  @override
  String get categoryIncomeRedPacket => '紅包-節日紅包-生日紅包-隨禮回禮';

  @override
  String get categoryIncomeBonus => '獎金-年度獎金-季度獎-項目獎金-其他獎金';

  @override
  String get categoryIncomeReimbursement => '報銷-差旅報銷-餐費報銷-其他報銷';

  @override
  String get categoryIncomePartTime => '兼職-兼職收入-外快';

  @override
  String get categoryIncomeGift => '禮金-結婚禮金-生日禮金-其他禮金';

  @override
  String get categoryIncomeInterest => '利息-銀行利息-其他利息';

  @override
  String get categoryIncomeRefund => '退款-購物退款-服務退款-其他退款';

  @override
  String get categoryIncomeInvestIncome => '投資收益-股票收益-基金投資-其他投資收益';

  @override
  String get categoryIncomeSecondHand => '二手交易-閒置物品-二手商品';

  @override
  String get categoryIncomeSocialBenefit => '社會福利-失業保險-生育津貼-其他補貼';

  @override
  String get categoryIncomeTaxRefund => '退稅-個稅退稅-其他退費';

  @override
  String get categoryIncomeProvidentFund => '公積金-公積金提取-公積金利息';

  @override
  String get personalizeTitle => '主題色';

  @override
  String get personalizeSubtitle => '選擇或自訂應用主題色';

  @override
  String get personalizeCustomColor => '選擇自訂顏色';

  @override
  String get personalizeCustomTitle => '自訂';

  @override
  String personalizeHue(Object value) {
    return '色相 ($value°)';
  }

  @override
  String personalizeSaturation(Object value) {
    return '飽和度 ($value%)';
  }

  @override
  String personalizeBrightness(Object value) {
    return '亮度 ($value%)';
  }

  @override
  String get personalizeSelectColor => '選擇此顏色';

  @override
  String get appearanceThemeMode => '外觀模式';

  @override
  String get appearanceThemeModeSystem => '跟隨系統';

  @override
  String get appearanceThemeModeLight => '亮色模式';

  @override
  String get appearanceThemeModeDark => '暗黑模式';

  @override
  String get appearanceAmountFormat => '餘額顯示格式';

  @override
  String get appearanceAmountFormatFull => '完整金額';

  @override
  String get appearanceAmountFormatFullDesc => '顯示完整金額，如 123,456.78';

  @override
  String get appearanceAmountFormatCompact => '簡潔顯示';

  @override
  String get appearanceAmountFormatCompactDesc => '大金額縮寫，如 12.3萬（僅對帳戶餘額生效）';

  @override
  String get appearanceShowTransactionTime => '顯示交易時間';

  @override
  String get appearanceShowTransactionTimeDesc => '在帳單列表顯示時分，編輯時可選擇時間';

  @override
  String get appearanceQuickEntryMode => '快捷記帳模式';

  @override
  String get appearanceQuickEntryModeDesc => '點「記一筆」直接用最近用過的類別，直達金額輸入；關閉則先選類別';

  @override
  String get appearanceNoteDisplay => '備註顯示方式';

  @override
  String get appearanceNoteDisplayCategory => '分類優先';

  @override
  String get appearanceNoteDisplayCategoryDesc => '顯示分類名,備註以括號附在後面';

  @override
  String get appearanceNoteDisplayNote => '備註優先';

  @override
  String get appearanceNoteDisplayNoteDesc => '有備註時顯示備註,無備註時顯示分類名';

  @override
  String get appearanceNoteHistory => '歷史備註';

  @override
  String get appearanceNoteHistoryScope => '顯示範圍';

  @override
  String get appearanceNoteHistoryScopeAllCategories => '全部分類';

  @override
  String get appearanceNoteHistoryScopeCurrentCategory => '目前分類';

  @override
  String get appearanceNoteHistorySort => '排序方式';

  @override
  String get appearanceNoteHistorySortFrequency => '使用頻次';

  @override
  String get appearanceNoteHistorySortRecent => '最近使用';

  @override
  String get appearanceNoteHistoryLimit => '顯示數量';

  @override
  String get appearanceNoteHistoryLimitHint => '可設定 1 至 100 筆';

  @override
  String get appearanceNoteHistoryLimitInvalid => '請輸入 1 至 100 的整數';

  @override
  String get appearanceColorScheme => '收支顏色方案';

  @override
  String get appearanceColorSchemeOn => '紅色收入 · 綠色支出';

  @override
  String get appearanceColorSchemeOff => '紅色支出 · 綠色收入';

  @override
  String get appearanceColorSchemeOnDesc => '紅色表示收入，綠色表示支出';

  @override
  String get appearanceColorSchemeOffDesc => '紅色表示支出，綠色表示收入';

  @override
  String get appearanceColorSchemeBlue => '藍色收入 · 橙色支出';

  @override
  String get appearanceColorSchemeBlueDesc => '藍色表示收入，橙色表示支出';

  @override
  String fontSettingsCurrentScale(Object scale) {
    return '當前縮放：x$scale';
  }

  @override
  String get fontSettingsPreview => '即時預覽';

  @override
  String get fontSettingsPreviewText =>
      '今天吃飯花了 23.50 元，記一筆；\n本月已記帳 45 天，共 320 條記錄；\n堅持就是勝利！';

  @override
  String fontSettingsCurrentLevel(Object level, Object scale) {
    return '當前檔位：$level  (倍率 x$scale)';
  }

  @override
  String get fontSettingsQuickLevel => '快速檔位';

  @override
  String get fontSettingsCustomAdjust => '自訂調整';

  @override
  String get fontSettingsDescription =>
      '說明：此設定確保所有裝置在1.0倍時顯示效果一致，裝置差異已自動補償；調整數值可在一致基礎上進行個性化縮放。';

  @override
  String get fontSettingsExtraSmall => '極小';

  @override
  String get fontSettingsVerySmall => '很小';

  @override
  String get fontSettingsSmall => '較小';

  @override
  String get fontSettingsStandard => '標準';

  @override
  String get fontSettingsLarge => '較大';

  @override
  String get fontSettingsBig => '大';

  @override
  String get fontSettingsVeryBig => '很大';

  @override
  String get fontSettingsExtraBig => '極大';

  @override
  String get fontSettingsMoreStyles => '更多風格';

  @override
  String get fontSettingsPageTitle => '頁面標題';

  @override
  String get fontSettingsBlockTitle => '區塊標題';

  @override
  String get fontSettingsBodyExample => '正文範例';

  @override
  String get fontSettingsLabelExample => '標籤說明';

  @override
  String get fontSettingsStrongNumber => '強調數字';

  @override
  String get fontSettingsListTitle => '清單項標題';

  @override
  String get fontSettingsListSubtitle => '輔助說明文字';

  @override
  String get fontSettingsScreenInfo => '螢幕適配資訊';

  @override
  String get fontSettingsScreenDensity => '螢幕密度';

  @override
  String get fontSettingsScreenWidth => '螢幕寬度';

  @override
  String get fontSettingsDeviceScale => '裝置縮放';

  @override
  String get fontSettingsUserScale => '使用者縮放';

  @override
  String get fontSettingsFinalScale => '最終縮放';

  @override
  String get fontSettingsBaseDevice => '基準裝置';

  @override
  String get fontSettingsRecommendedScale => '建議縮放';

  @override
  String get fontSettingsYes => '是';

  @override
  String get fontSettingsNo => '否';

  @override
  String get fontSettingsScaleExample => '此方框和間距會根據裝置自動縮放';

  @override
  String get fontSettingsPreciseAdjust => '精確調整';

  @override
  String get fontSettingsResetTo1x => '重設到1.0x';

  @override
  String get fontSettingsAdaptBase => '適配基準';

  @override
  String get reminderTitle => '記帳提醒';

  @override
  String get reminderDailyTitle => '每日記帳提醒';

  @override
  String get reminderDailySubtitle => '開啟後將在指定時間提醒您記帳';

  @override
  String get reminderTimeTitle => '提醒時間';

  @override
  String get commonSelectTime => '選擇時間';

  @override
  String get reminderTestNotification => '發送測試通知';

  @override
  String get reminderTestSent => '測試通知已發送';

  @override
  String get reminderTestTitle => '測試通知';

  @override
  String get reminderTestBody => '這是一條測試通知，點擊檢視效果';

  @override
  String get reminderCheckBattery => '檢查電池最佳化狀態';

  @override
  String get reminderBatteryStatus => '電池最佳化狀態';

  @override
  String reminderManufacturer(Object value) {
    return '裝置製造商: $value';
  }

  @override
  String reminderModel(Object value) {
    return '裝置型號: $value';
  }

  @override
  String reminderAndroidVersion(Object value) {
    return 'Android版本: $value';
  }

  @override
  String get reminderBatteryIgnored => '電池最佳化狀態: 已忽略 ✅';

  @override
  String get reminderBatteryNotIgnored => '電池最佳化狀態: 未忽略 ⚠️';

  @override
  String get reminderBatteryAdvice => '建議關閉電池最佳化以確保通知正常工作';

  @override
  String get reminderCheckChannel => '檢查通知頻道設定';

  @override
  String get reminderChannelStatus => '通知頻道狀態';

  @override
  String get reminderChannelEnabled => '頻道啟用: 是 ✅';

  @override
  String get reminderChannelDisabled => '頻道啟用: 否 ❌';

  @override
  String reminderChannelImportance(Object value) {
    return '重要性: $value';
  }

  @override
  String get reminderChannelSoundOn => '聲音: 開啟 🔊';

  @override
  String get reminderChannelSoundOff => '聲音: 關閉 🔇';

  @override
  String get reminderChannelVibrationOn => '震動: 開啟 📳';

  @override
  String get reminderChannelVibrationOff => '震動: 關閉';

  @override
  String get reminderChannelDndBypass => '勿擾模式: 可繞過';

  @override
  String get reminderChannelDndNoBypass => '勿擾模式: 不可繞過';

  @override
  String get reminderChannelAdvice => '⚠️ 建議設定：';

  @override
  String get reminderChannelAdviceImportance => '• 重要性：緊急或高';

  @override
  String get reminderChannelAdviceSound => '• 開啟聲音和震動';

  @override
  String get reminderChannelAdviceBanner => '• 允許橫幅通知';

  @override
  String get reminderChannelAdviceXiaomi => '• 小米手機需單獨設定每個頻道';

  @override
  String get reminderChannelGood => '✅ 通知頻道設定良好';

  @override
  String get reminderOpenAppSettings => '開啟應用程式設定';

  @override
  String get reminderAppSettingsMessage => '請在設定中允許通知、關閉電池最佳化';

  @override
  String get reminderDescription => '提示：開啟記帳提醒後，系統會在每天指定時間發送通知提醒您記錄收支。';

  @override
  String get reminderIOSInstructions =>
      '🍎 iOS通知設定：\n• 設定 > 通知 > 小豬記帳\n• 開啟\"允許通知\"\n• 設定通知樣式：橫幅或提醒\n• 開啟聲音和震動\n\n⚠️ 重要提示：\n• iOS本地通知依賴應用程序進程\n• 請勿在任務管理器中划掉應用\n• 應用在後台或前台時通知正常\n• 完全關閉應用會導致通知失效\n\n💡 使用建議：\n• 日常使用後直接按Home鍵退出\n• iOS會自動管理後台應用\n• 保持應用在後台即可收到提醒';

  @override
  String get reminderAndroidInstructions =>
      '如果通知無法正常工作，請檢查：\n• 已允許應用程式發送通知\n• 關閉應用程式的電池最佳化/省電模式\n• 允許應用程式在背景執行和自啟動\n• Android 12+需要精確鬧鐘權限\n\n📱 小米手機特殊設定：\n• 設定 > 應用程式管理 > 小豬記帳 > 通知管理\n• 點擊\"記帳提醒\"頻道\n• 設定重要性為\"緊急\"或\"高\"\n• 開啟\"橫幅通知\"、\"聲音\"、\"震動\"\n• 安全中心 > 應用程式管理 > 權限 > 自啟動\n\n🔒 鎖定背景方法：\n• 最近任務中找到小豬記帳\n• 向下拉動應用程式卡片顯示鎖定圖示\n• 點擊鎖定圖示防止被清理';

  @override
  String get categoryDetailLoadFailed => '載入失敗';

  @override
  String get categoryDetailSummaryTitle => '分類匯總';

  @override
  String get categoryDetailTotalCount => '總筆數';

  @override
  String get categoryDetailTotalAmount => '總金額';

  @override
  String get categoryDetailAverageAmount => '平均金額';

  @override
  String get categoryDetailSortTitle => '排序';

  @override
  String get categoryDetailSortTimeDesc => '時間↓';

  @override
  String get categoryDetailSortTimeAsc => '時間↑';

  @override
  String get categoryDetailSortAmountDesc => '金額↓';

  @override
  String get categoryDetailSortAmountAsc => '金額↑';

  @override
  String get categoryDetailNoTransactions => '暫無交易記錄';

  @override
  String get categoryDetailNoTransactionsSubtext => '該分類下還沒有任何交易記錄';

  @override
  String get categoryDetailDeleteFailed => '刪除失敗';

  @override
  String get categoryMigrationConfirmTitle => '確認遷移';

  @override
  String categoryMigrationConfirmMessage(
      Object count, Object fromName, Object toName) {
    return '確定要將「$fromName」的 $count 筆交易遷移到「$toName」嗎？\n\n此操作不可撤銷！';
  }

  @override
  String get categoryMigrationConfirmOk => '確認遷移';

  @override
  String get categoryMigrationCompleteTitle => '遷移完成';

  @override
  String categoryMigrationCompleteMessage(
      Object count, Object fromName, Object toName) {
    return '成功將 $count 筆交易從「$fromName」遷移到「$toName」。';
  }

  @override
  String get categoryMigrationFailedTitle => '遷移失敗';

  @override
  String categoryMigrationFailedMessage(Object error) {
    return '遷移過程中發生錯誤：$error';
  }

  @override
  String categoryMigrationTransactionLabel(int count) {
    return '$count筆';
  }

  @override
  String get mineImportCompleteAllSuccess => '全部成功';

  @override
  String get mineCheckUpdateDetecting => '檢測更新中...';

  @override
  String get mineCheckUpdateSubtitleDetecting => '正在檢查最新版本';

  @override
  String get mineUpdateDownloadTitle => '下載更新';

  @override
  String get cloudSupabaseUrlLabel => 'Supabase URL';

  @override
  String get cloudSupabaseUrlHint => 'https://xxx.supabase.co';

  @override
  String get cloudAnonKeyLabel => 'Anon Key';

  @override
  String get cloudMultiDeviceWarningTitle => '多裝置使用提醒';

  @override
  String get cloudMultiDeviceWarningMessage =>
      '換裝置前記得先上傳，到新裝置後先下載再記帳。不要同時在兩台裝置上記同一個帳本。點擊查看詳情 →';

  @override
  String get cloudWebdavUrlLabel => 'WebDAV 伺服器地址';

  @override
  String get cloudWebdavUrlHint => 'https://dav.jianguoyun.com/dav/';

  @override
  String get cloudWebdavUsernameLabel => '使用者名稱';

  @override
  String get cloudWebdavPasswordLabel => '密碼';

  @override
  String get cloudWebdavPathHint => '/PiggyCount';

  @override
  String get cloudS3EndpointLabel => '端點地址';

  @override
  String get cloudS3EndpointHint => 's3.amazonaws.com 或自訂端點';

  @override
  String get cloudS3RegionLabel => '區域';

  @override
  String get cloudS3RegionHint => 'us-east-1（留空自動）';

  @override
  String get cloudS3AccessKeyLabel => 'Access Key';

  @override
  String get cloudS3AccessKeyHint => '您的 Access Key ID';

  @override
  String get cloudS3SecretKeyLabel => 'Secret Key';

  @override
  String get cloudS3SecretKeyHint => '您的 Secret Access Key';

  @override
  String get cloudS3BucketLabel => '儲存桶名稱';

  @override
  String get cloudS3BucketHint => '例如 my-bucket';

  @override
  String get cloudS3UseSSLLabel => '使用 HTTPS';

  @override
  String get cloudS3PortLabel => '連接埠（選填）';

  @override
  String get cloudS3PortHint => '留空使用預設連接埠';

  @override
  String get cloudSupabaseBucketLabel => 'Storage Bucket 名稱';

  @override
  String get cloudSupabaseBucketHint => '留空使用預設值 piggycount-backups';

  @override
  String get authRememberAccount => '記住帳號密碼';

  @override
  String get authRememberAccountHint => '下次登入時自動填入（僅Supabase）';

  @override
  String get cloudConfigSaved => '設定已儲存';

  @override
  String get authLogin => '登入';

  @override
  String get authEmail => '電子郵件';

  @override
  String get authPassword => '密碼';

  @override
  String get authInvalidEmail => '請輸入有效的電子郵件地址';

  @override
  String get authErrorInvalidCredentials => '電子郵件或密碼不正確。';

  @override
  String get authErrorEmailNotConfirmed => '電子郵件未驗證，請先到電子郵件完成驗證再登入。';

  @override
  String get authErrorRateLimit => '操作過於頻繁，請稍後再試。';

  @override
  String get authErrorNetworkIssue => '網路異常，請檢查網路後重試。';

  @override
  String get authErrorLoginFailed => '登入失敗，請稍後再試。';

  @override
  String get importSelectCsvFile => '請選擇檔案進行匯入（支援 CSV/TSV/XLSX 格式）';

  @override
  String get exportTitle => '匯出';

  @override
  String get exportDescription =>
      '支援匯出的資料類型：\n• 交易記錄（收入／支出／轉帳）\n• 分類資訊\n• 帳戶資訊\n\n點擊下方按鈕選擇儲存位置，開始匯出目前帳本為 CSV 檔案。';

  @override
  String get exportButtonIOS => '匯出並分享';

  @override
  String get exportButtonAndroid => '匯出資料';

  @override
  String exportSavedTo(String path) {
    return '已儲存到：$path';
  }

  @override
  String get exportCsvHeaderType => '類型';

  @override
  String get exportCsvHeaderCategory => '分類';

  @override
  String get exportCsvHeaderSubCategory => '二級分類';

  @override
  String get exportCsvHeaderAmount => '金額';

  @override
  String get exportCsvHeaderAccount => '帳戶';

  @override
  String get exportCsvHeaderFromAccount => '轉出帳戶';

  @override
  String get exportCsvHeaderToAccount => '轉入帳戶';

  @override
  String get exportCsvHeaderNote => '備註';

  @override
  String get exportCsvHeaderTime => '時間';

  @override
  String get exportCsvHeaderTags => '標籤';

  @override
  String get exportCsvHeaderAttachments => '附件';

  @override
  String get exportCsvHeaderCustomFields => '自訂欄位';

  @override
  String get exportShareText => 'PiggyCount 匯出檔案';

  @override
  String get exportSuccessTitle => '匯出成功';

  @override
  String exportSuccessMessageIOS(String path) {
    return '已儲存並可在分享歷史中找到：\n$path';
  }

  @override
  String exportSuccessMessageAndroid(String path) {
    return '已儲存到：\n$path';
  }

  @override
  String get exportFailedTitle => '匯出失敗';

  @override
  String get exportTypeIncome => '收入';

  @override
  String get exportTypeExpense => '支出';

  @override
  String get exportTypeTransfer => '轉帳';

  @override
  String get personalizeThemeHoney => '蜜蜂黃';

  @override
  String get personalizeThemeOrange => '火焰橙';

  @override
  String get personalizeThemeGreen => '琉璃綠';

  @override
  String get personalizeThemePurple => '青蓮紫';

  @override
  String get personalizeThemePink => '櫻緋紅';

  @override
  String get personalizeThemeBlue => '晴空藍';

  @override
  String get personalizeThemeMint => '林間月';

  @override
  String get personalizeThemeSand => '黃昏沙丘';

  @override
  String get personalizeThemeLavender => '雪與松';

  @override
  String get personalizeThemeSky => '迷霧仙境';

  @override
  String get personalizeThemeWarmOrange => '暖陽橘';

  @override
  String get personalizeThemeMintGreen => '薄荷青';

  @override
  String get personalizeThemeRoseGold => '玫瑰金';

  @override
  String get personalizeThemeDeepBlue => '深海藍';

  @override
  String get personalizeThemeMapleRed => '楓葉紅';

  @override
  String get personalizeThemeEmerald => '翡翠綠';

  @override
  String get personalizeThemeLavenderPurple => '薰衣草';

  @override
  String get personalizeThemeAmber => '琥珀黃';

  @override
  String get personalizeThemeRouge => '胭脂紅';

  @override
  String get personalizeThemeIndigo => '靛青藍';

  @override
  String get personalizeThemeOlive => '橄欖綠';

  @override
  String get personalizeThemeCoral => '珊瑚粉';

  @override
  String get personalizeThemeDarkGreen => '墨綠色';

  @override
  String get personalizeThemeViolet => '紫羅蘭';

  @override
  String get personalizeThemeSunset => '日落橙';

  @override
  String get personalizeThemePeacock => '孔雀藍';

  @override
  String get personalizeThemeLime => '檸檬綠';

  @override
  String get personalizeThemePiggyPink => '小豬粉';

  @override
  String get personalizeThemeSkyBlue => '天空藍';

  @override
  String get personalizeThemeGradientBlue => '漸變藍';

  @override
  String get analyticsMonthlyAvg => '月均';

  @override
  String get analyticsDailyAvg => '日均';

  @override
  String get analyticsOverallAvg => '平均值';

  @override
  String get analyticsTotalExpense => '總支出： ';

  @override
  String get analyticsBalance => '結餘： ';

  @override
  String get analyticsComparedToLastYear => '比上年';

  @override
  String get analyticsTxCount => '記帳筆數';

  @override
  String get analyticsExpense => '支出';

  @override
  String get analyticsIncome => '收入';

  @override
  String analyticsTotal(String type) {
    return '總$type： ';
  }

  @override
  String get updateCheckTitle => '檢查更新';

  @override
  String updateNewVersionTitle(String version) {
    return '發現新版本 $version';
  }

  @override
  String get updateNoApkFound => '未找到APK下載連結';

  @override
  String get updateAlreadyLatest => '當前已是最新版本';

  @override
  String get updateCheckFailed => '檢查更新失敗';

  @override
  String get updatePermissionDenied => '權限被拒絕';

  @override
  String get updateUserCancelled => '使用者取消';

  @override
  String get updateDownloadTitle => '下載更新';

  @override
  String updateDownloading(String percent) {
    return '下載中: $percent%';
  }

  @override
  String get updateDownloadBackgroundHint => '可以將應用程式切換到背景，下載會繼續進行';

  @override
  String get updateCancelButton => '取消';

  @override
  String get updateBackgroundDownload => '背景下載';

  @override
  String get updateLaterButton => '稍後';

  @override
  String get updateDownloadButton => '下載';

  @override
  String get updateInstallingCachedApk => '正在安裝快取的APK';

  @override
  String get updateInstallStarted => '下載完成，安裝程式已啟動';

  @override
  String get updateInstallFailed => '安裝失敗';

  @override
  String get updateDownloadFailed => '下載失敗';

  @override
  String get updateInstallNow => '立即安裝';

  @override
  String get updateNotificationPermissionTitle => '通知權限被拒絕';

  @override
  String get updateCheckFailedTitle => '檢測更新失敗';

  @override
  String get updateDownloadFailedTitle => '下載失敗';

  @override
  String get updateGoToGitHub => '前往GitHub';

  @override
  String get updateManualVisit =>
      '請手動在瀏覽器中存取：\\nhttps://github.com/mecoren/PiggyCount/releases';

  @override
  String get updateNoLocalApkTitle => '未找到更新包';

  @override
  String get updateInstallPackageTitle => '安裝更新包';

  @override
  String get updateMultiplePackagesTitle => '找到多個更新包';

  @override
  String get updateSearchFailedTitle => '查找失敗';

  @override
  String get updateFoundCachedPackageTitle => '發現已下載的更新包';

  @override
  String get updateIgnoreButton => '忽略';

  @override
  String get updateInstallFailedTitle => '安裝失敗';

  @override
  String get updateInstallFailedMessage => '無法啟動APK安裝程式，請檢查檔案權限。';

  @override
  String get updateErrorTitle => '錯誤';

  @override
  String get updateCheckingPermissions => '檢查權限...';

  @override
  String get updateCheckingCache => '檢查本地快取...';

  @override
  String get updatePreparingDownload => '準備下載...';

  @override
  String get updateUserCancelledDownload => '使用者取消下載';

  @override
  String get updateStartingInstaller => '正在啟動安裝...';

  @override
  String get updateInstallerStarted => '安裝程式已啟動';

  @override
  String get updateInstallationFailed => '安裝失敗';

  @override
  String get updateDownloadCompleted => '下載完成';

  @override
  String get updateDownloadCompletedManual => '下載完成，可以手動安裝';

  @override
  String get updateDownloadCompletedDialog => '下載完成，請手動安裝（彈窗異常）';

  @override
  String get updateDownloadCompletedContext => '下載完成，請手動安裝';

  @override
  String get updateDownloadFailedGeneric => '下載失敗';

  @override
  String get updateCheckingUpdate => '正在檢查更新...';

  @override
  String get updateCurrentLatestVersion => '當前已是最新版本';

  @override
  String get updateCheckFailedGeneric => '檢查更新失敗';

  @override
  String updateDownloadProgress(String percent) {
    return '下載中: $percent%';
  }

  @override
  String updateCheckingUpdateError(String error) {
    return '檢查更新失敗: $error';
  }

  @override
  String get updateNoLocalApkFoundMessage =>
      '沒有找到已下載的更新包檔案。\n\n請先透過\"檢查更新\"下載新版本。';

  @override
  String updateInstallPackageFoundMessage(
      String fileName, String fileSize, String time) {
    return '找到更新包：\n\n檔案名：$fileName\n大小：${fileSize}MB\n下載時間：$time\n\n是否立即安裝？';
  }

  @override
  String updateMultiplePackagesFoundMessage(int count, String path) {
    return '找到 $count 個更新包檔案。\n\n建議使用最新下載的版本，或手動到檔案管理器中安裝。\n\n檔案位置：$path';
  }

  @override
  String updateSearchLocalApkError(String error) {
    return '查找本地更新包時發生錯誤：$error';
  }

  @override
  String updateCachedPackageFoundMessage(String fileName, String fileSize) {
    return '檢測到之前下載的更新包：\n\n檔案名：$fileName\n大小：${fileSize}MB\n\n是否立即安裝？';
  }

  @override
  String updateReadCachedPackageError(String error) {
    return '讀取快取更新包失敗：$error';
  }

  @override
  String get updateOk => '知道了';

  @override
  String get updateCannotOpenLinkTitle => '無法開啟連結';

  @override
  String get updateCachedVersionTitle => '發現已下載版本';

  @override
  String get updateCachedVersionMessage =>
      '已找到之前下載的安裝包...點擊\\\"確定\\\"立即安裝，點擊\\\"取消\\\"關閉...';

  @override
  String get updateConfirmDownload => '立即下載並安裝';

  @override
  String get updateDownloadCompleteTitle => '下載完成';

  @override
  String get updateInstallConfirmMessage => '新版本已下載完成，是否立即安裝？';

  @override
  String get updateMirrorSelectTitle => '選擇下載加速器';

  @override
  String get updateMirrorSelectHint => '如果下載緩慢，可以選擇一個加速映像。點擊「測速」檢測各映像延遲。';

  @override
  String get updateMirrorTestButton => '測速';

  @override
  String updateMirrorTesting(int completed, int total) {
    return '正在測試 $completed/$total...';
  }

  @override
  String get updateMirrorDirectHint => '適合網路暢通的使用者';

  @override
  String updateDownloadMirror(String mirror) {
    return '下載源: $mirror';
  }

  @override
  String get updateMirrorSettingTitle => '下載加速器';

  @override
  String get updateNotificationPermissionGuideText =>
      '下載進度通知被關閉，但不影響下載功能。如需檢視進度：';

  @override
  String get updateNotificationGuideStep1 => '進入系統設定 > 應用程式管理';

  @override
  String get updateNotificationGuideStep2 => '找到\\\"小豬記帳\\\"應用程式';

  @override
  String get updateNotificationGuideStep3 => '開啟通知權限';

  @override
  String get updateNotificationGuideInfo => '即使不開啟通知，下載也會在背景正常進行';

  @override
  String get currencyCNY => '人民幣';

  @override
  String get currencyUSD => '美元';

  @override
  String get currencyEUR => '歐元';

  @override
  String get currencyJPY => '日元';

  @override
  String get currencyHKD => '港幣';

  @override
  String get currencyTWD => '新台幣';

  @override
  String get currencyGBP => '英鎊';

  @override
  String get currencyAUD => '澳元';

  @override
  String get currencyCAD => '加元';

  @override
  String get currencyKRW => '韓元';

  @override
  String get currencySGD => '新加坡元';

  @override
  String get currencyMYR => '馬來西亞令吉';

  @override
  String get currencyTHB => '泰銖';

  @override
  String get currencyIDR => '印尼盾';

  @override
  String get currencyPHP => '菲律賓披索';

  @override
  String get currencyVND => '越南盾';

  @override
  String get currencyINR => '印度盧比';

  @override
  String get currencyRUB => '俄羅斯盧布';

  @override
  String get currencyBYN => '白俄羅斯盧布';

  @override
  String get currencyNZD => '紐西蘭元';

  @override
  String get currencyCHF => '瑞士法郎';

  @override
  String get currencySEK => '瑞典克朗';

  @override
  String get currencyNOK => '挪威克朗';

  @override
  String get currencyDKK => '丹麥克朗';

  @override
  String get currencyBRL => '巴西雷亞爾';

  @override
  String get currencyMXN => '墨西哥披索';

  @override
  String get currencyTRY => '土耳其里拉';

  @override
  String get currencyZAR => '南非蘭特';

  @override
  String get currencyAED => '阿聯酋迪拉姆';

  @override
  String get currencySAR => '沙烏地里亞爾';

  @override
  String get currencyPLN => '波蘭茲羅提';

  @override
  String get currencyCZK => '捷克克朗';

  @override
  String get currencyHUF => '匈牙利福林';

  @override
  String get currencyARS => '阿根廷披索';

  @override
  String get currencyCLP => '智利披索';

  @override
  String get currencyCOP => '哥倫比亞披索';

  @override
  String get currencyPEN => '秘魯索爾';

  @override
  String get currencyEGP => '埃及鎊';

  @override
  String get currencyNGN => '奈及利亞奈拉';

  @override
  String get currencyKZT => '哈薩克坦吉';

  @override
  String get currencyUAH => '烏克蘭格里夫納';

  @override
  String get currencyILS => '以色列新謝克爾';

  @override
  String get currencyPKR => '巴基斯坦盧比';

  @override
  String get currencyBDT => '孟加拉塔卡';

  @override
  String get currencyLKR => '斯里蘭卡盧比';

  @override
  String get currencyMMK => '緬甸元';

  @override
  String get webdavConfiguredTitle => 'WebDAV 雲服務已設定';

  @override
  String get webdavConfiguredMessage => 'WebDAV 雲服務使用設定時提供的憑證，無需額外登入。';

  @override
  String get recurringTransactionTitle => '週期帳單';

  @override
  String get recurringTransactionAdd => '新增週期帳單';

  @override
  String get recurringTransactionEdit => '編輯週期帳單';

  @override
  String get recurringTransactionFrequency => '週期頻率';

  @override
  String get recurringTransactionDaily => '每天';

  @override
  String get recurringTransactionWeekly => '每週';

  @override
  String get recurringTransactionMonthly => '每月';

  @override
  String get recurringTransactionYearly => '每年';

  @override
  String get recurringTransactionInterval => '間隔';

  @override
  String get recurringTransactionDayOfMonth => '每月第幾天';

  @override
  String get recurringTransactionStartDate => '開始日期';

  @override
  String get recurringTransactionEndDate => '結束日期';

  @override
  String get recurringTransactionNoEndDate => '永久週期';

  @override
  String get recurringTransactionDeleteConfirm => '確定要刪除這個週期帳單嗎？';

  @override
  String get recurringTransactionEmpty => '暫無週期帳單';

  @override
  String get recurringTransactionEmptyHint => '點擊右上角 + 按鈕新增';

  @override
  String recurringTransactionEveryNDays(int n) {
    return '每 $n 天';
  }

  @override
  String recurringTransactionEveryNWeeks(int n) {
    return '每 $n 週';
  }

  @override
  String recurringTransactionEveryNMonths(int n) {
    return '每 $n 個月';
  }

  @override
  String recurringTransactionEveryNYears(int n) {
    return '每 $n 年';
  }

  @override
  String get recurringTransactionUsageTitle => '使用說明';

  @override
  String get recurringTransactionUsageContent =>
      '週期記帳會在每次冷啟動進入 App 時自動掃描並產生帳單。設定日期後，系統會在該日期之後的冷啟動時建立對應帳單。例如：設定 11 月 27 日，則會在 11 月 27 日之後的首次啟動時自動記帳。';

  @override
  String get ledgerSelectTitle => '選擇帳本';

  @override
  String get ledgerSelect => '選擇帳本';

  @override
  String get syncNotConfiguredMessage => '未設定雲端';

  @override
  String get syncNotLoggedInMessage => '未登入';

  @override
  String get syncCloudBackupCorruptedMessage =>
      '雲端備份內容無法解析，可能是早期版本編碼問題造成的損壞。請點擊\\\"上傳當前帳本到雲端\\\"覆蓋修復。';

  @override
  String get syncNoCloudBackupMessage => '雲端暫無備份';

  @override
  String get syncAccessDeniedMessage => '403 拒絕存取（檢查 storage RLS 策略與路徑）';

  @override
  String get cloudTestConnection => '測試連線';

  @override
  String get cloudLocalStorageTitle => '本機儲存';

  @override
  String get cloudLocalStorageSubtitle => '資料僅儲存在本機裝置';

  @override
  String get cloudCustomSupabaseTitle => '自訂 Supabase';

  @override
  String get cloudCustomSupabaseSubtitle => '點擊設定自建Supabase服務';

  @override
  String get cloudCustomWebdavTitle => '自訂 WebDAV';

  @override
  String get cloudCustomWebdavSubtitle => '點擊設定堅果雲/Nextcloud等';

  @override
  String get cloudCustomS3Title => 'S3 協議儲存';

  @override
  String get cloudCustomS3Subtitle => 'AWS S3 / Cloudflare R2 / MinIO';

  @override
  String get cloudTabOffline => '離線模式';

  @override
  String get cloudTabBackup => '備份同步';

  @override
  String get cloudIcloudSubtitle => '使用 Apple ID 自動同步';

  @override
  String get cloudIcloudNotAvailableTitle => 'iCloud 不可用';

  @override
  String get cloudIcloudNotAvailableMessage => '請在系統設定中登入 iCloud 帳戶後再試';

  @override
  String get cloudIcloudHelpTitle => 'iCloud 使用說明';

  @override
  String get cloudIcloudHelpPrerequisites => '前提條件';

  @override
  String get cloudIcloudHelpPrereq1 => '1. 裝置已登入 Apple ID';

  @override
  String get cloudIcloudHelpPrereq2 => '2. 已開啟 iCloud Drive';

  @override
  String get cloudIcloudHelpPrereq3 => '3. 裝置已連網';

  @override
  String get cloudIcloudHelpCheckTitle => '如何檢查 iCloud Drive';

  @override
  String get cloudIcloudHelpCheck1 => '1. 開啟「設定」';

  @override
  String get cloudIcloudHelpCheck2 => '2. 點擊頂部的 Apple ID';

  @override
  String get cloudIcloudHelpCheck3 => '3. 點擊「iCloud」';

  @override
  String get cloudIcloudHelpCheck4 => '4. 確保「iCloud 雲碟」已開啟';

  @override
  String get cloudIcloudHelpFaqTitle => '常見問題';

  @override
  String get cloudIcloudHelpFaq1 => '如果提示不可用，請檢查 iCloud Drive 是否開啟';

  @override
  String get cloudIcloudHelpFaq2 => '首次使用可能需要等待幾秒鐘初始化';

  @override
  String get cloudIcloudHelpFaq3 => '資料儲存在您的私人 iCloud 空間中';

  @override
  String get cloudIcloudHelpFaq4 => '同一 Apple ID 的裝置可自動同步';

  @override
  String get cloudIcloudHelpNote => 'iCloud 同步使用您的 Apple ID，無需額外設定';

  @override
  String get cloudSupabaseHelpTitle => 'Supabase 設定說明';

  @override
  String get cloudSupabaseHelpIntro => '什麼是 Supabase';

  @override
  String get cloudSupabaseHelpIntro1 => 'Supabase 是一個開源的後端即服務平台';

  @override
  String get cloudSupabaseHelpIntro2 => '提供免費方案，足夠個人使用';

  @override
  String get cloudSupabaseHelpIntro3 => '資料完全由您掌控';

  @override
  String get cloudSupabaseHelpSteps => '設定步驟';

  @override
  String get cloudSupabaseHelpStep1 => '1. 前往 supabase.com 註冊帳號';

  @override
  String get cloudSupabaseHelpStep2 => '2. 建立新專案（選擇免費方案）';

  @override
  String get cloudSupabaseHelpStep3 => '3. 進入專案設定 > API';

  @override
  String get cloudSupabaseHelpStep4 => '4. 複製 Project URL 和 anon key';

  @override
  String get cloudSupabaseHelpStep5 => '5. 貼到應用程式的設定中';

  @override
  String get cloudSupabaseHelpFaq => '常見問題';

  @override
  String get cloudSupabaseHelpFaq1 => '免費方案有 500MB 儲存空間';

  @override
  String get cloudSupabaseHelpFaq2 => '資料加密儲存，安全可靠';

  @override
  String get cloudSupabaseHelpFaq3 => '支援多裝置同步';

  @override
  String get cloudSupabaseHelpNote => '設定完成後需要註冊/登入帳號才能使用同步功能';

  @override
  String get cloudDetailedTutorial => '詳細教學';

  @override
  String get cloudWebdavHelpTitle => 'WebDAV 設定說明';

  @override
  String get cloudWebdavHelpIntro => '什麼是 WebDAV';

  @override
  String get cloudWebdavHelpIntro1 => 'WebDAV 是一種網路檔案通訊協定';

  @override
  String get cloudWebdavHelpIntro2 => '支援多種雲端硬碟和 NAS 裝置';

  @override
  String get cloudWebdavHelpIntro3 => '資料儲存在您自己的伺服器上';

  @override
  String get cloudWebdavHelpProviders => '支援的服務商';

  @override
  String get cloudWebdavHelpProvider1 => '• 堅果雲（推薦國內用戶）';

  @override
  String get cloudWebdavHelpProvider2 => '• Nextcloud / ownCloud';

  @override
  String get cloudWebdavHelpProvider3 => '• 群暉 / 威聯通 NAS';

  @override
  String get cloudWebdavHelpProvider4 => '• 其他支援 WebDAV 的服務';

  @override
  String get cloudWebdavHelpSteps => '設定步驟（以堅果雲為例）';

  @override
  String get cloudWebdavHelpStep1 => '1. 登入堅果雲網頁版';

  @override
  String get cloudWebdavHelpStep2 => '2. 點擊右上角帳戶名 > 帳戶資訊';

  @override
  String get cloudWebdavHelpStep3 => '3. 選擇「安全選項」標籤';

  @override
  String get cloudWebdavHelpStep4 => '4. 新增應用程式密碼（用於第三方應用程式）';

  @override
  String get cloudWebdavHelpStep5 => '5. 複製伺服器地址、帳號、應用程式密碼';

  @override
  String get cloudWebdavHelpNote => '建議使用應用程式專用密碼，而非帳號密碼';

  @override
  String get cloudS3HelpTitle => 'S3 儲存設定說明';

  @override
  String get cloudS3HelpIntro => '什麼是 S3';

  @override
  String get cloudS3HelpIntro1 => 'S3 是一種標準的物件儲存通訊協定';

  @override
  String get cloudS3HelpIntro2 => '支援多家雲端服務商';

  @override
  String get cloudS3HelpIntro3 => '資料儲存在您選擇的雲端服務中';

  @override
  String get cloudS3HelpProviders => '支援的服務商';

  @override
  String get cloudS3HelpProvider1 => '• AWS S3（Amazon Web Services）';

  @override
  String get cloudS3HelpProvider2 => '• Cloudflare R2（免費 10GB/月）';

  @override
  String get cloudS3HelpProvider3 => '• Backblaze B2（免費 10GB）';

  @override
  String get cloudS3HelpProvider4 => '• MinIO（自建服務）';

  @override
  String get cloudS3HelpProvider5 => '• 阿里雲 OSS';

  @override
  String get cloudS3HelpProvider6 => '• 騰訊雲 COS';

  @override
  String get cloudS3HelpProvider7 => '• 七牛雲 Kodo';

  @override
  String get cloudS3HelpSteps => '設定步驟（以 Cloudflare R2 為例）';

  @override
  String get cloudS3HelpStep1 => '1. 登入 Cloudflare 控制台';

  @override
  String get cloudS3HelpStep2 => '2. 進入 R2 > 建立儲存桶';

  @override
  String get cloudS3HelpStep3 => '3. 進入 R2 > 管理 R2 API 令牌';

  @override
  String get cloudS3HelpStep4 => '4. 建立 API 令牌並複製憑據';

  @override
  String get cloudS3HelpStep5 => '5. 貼上端點、存取金鑰、私密金鑰和儲存桶名稱';

  @override
  String get cloudS3HelpNote => '推薦使用 Cloudflare R2，提供 10GB 免費儲存且無流量費';

  @override
  String get cloudStatusNotTested => '未測試';

  @override
  String get cloudStatusNormal => '連線正常';

  @override
  String get cloudStatusFailed => '連線失敗';

  @override
  String get cloudCannotOpenLink => '無法開啟連結';

  @override
  String get cloudErrorAuthFailed => '認證失敗: API Key 無效';

  @override
  String cloudErrorServerStatus(String code) {
    return '伺服器返回狀態碼 $code';
  }

  @override
  String get cloudErrorWebdavNotSupported => '伺服器不支援 WebDAV 通訊協定';

  @override
  String get cloudErrorAuthFailedCredentials => '認證失敗: 使用者名稱或密碼錯誤';

  @override
  String get cloudErrorAccessDenied => '存取被拒絕: 請檢查權限';

  @override
  String cloudErrorPathNotFound(String path) {
    return '伺服器路徑不存在: $path';
  }

  @override
  String cloudErrorNetwork(String message) {
    return '網路錯誤: $message';
  }

  @override
  String get cloudTestSuccessTitle => '測試成功';

  @override
  String get cloudTestSuccessMessage => '連線正常，設定有效';

  @override
  String get cloudTestFailedTitle => '測試失敗';

  @override
  String get cloudTestFailedMessage => '連線失敗';

  @override
  String get cloudTestErrorTitle => '測試錯誤';

  @override
  String get cloudSwitchConfirmTitle => '切換雲端服務';

  @override
  String get cloudSwitchConfirmMessage =>
      '切換雲端服務將登出目前帳號。確認切換？已儲存的雲端服務憑證不會被刪除，可隨時切回。';

  @override
  String get cloudSwitchFailedTitle => '切換失敗';

  @override
  String get cloudSwitchFailedConfigMissing => '請先設定此雲端服務';

  @override
  String get cloudConfigInvalidTitle => '無效設定';

  @override
  String get cloudConfigInvalidMessage => '請填寫完整資訊';

  @override
  String fieldCannotBeEmpty(String field) {
    return '$field不能為空';
  }

  @override
  String get cloudSaveFailed => '儲存失敗';

  @override
  String cloudSwitchedTo(String type) {
    return '已切換至 $type';
  }

  @override
  String get cloudConfigureSupabaseTitle => '設定 Supabase';

  @override
  String get cloudConfigureWebdavTitle => '設定 WebDAV';

  @override
  String get cloudConfigureS3Title => '設定 S3';

  @override
  String get cloudSupabaseAnonKeyHintLong => '貼上完整的 anon key';

  @override
  String get cloudWebdavRemotePathLabel => '遠端路徑';

  @override
  String get cloudWebdavRemotePathHelperText => '資料儲存的遠端目錄路徑';

  @override
  String get accountsTitle => '資產管理';

  @override
  String get accountsEmptyMessage => '還沒有帳戶，點擊右上角添加';

  @override
  String get accountAddTooltip => '添加帳戶';

  @override
  String get accountAddButton => '添加帳戶';

  @override
  String get accountBalance => '餘額';

  @override
  String get accountEditTitle => '編輯帳戶';

  @override
  String get accountNewTitle => '新建帳戶';

  @override
  String get accountNameLabel => '帳戶名稱';

  @override
  String get accountNameHint => '例如：工商銀行、支付寶等';

  @override
  String get accountNameRequired => '請輸入帳戶名稱';

  @override
  String get accountNameDuplicate => '帳戶名稱已存在，請使用其他名稱';

  @override
  String get accountTypeCash => '現金';

  @override
  String get accountTypeBankCard => '銀行卡';

  @override
  String get accountTypeCreditCard => '信用卡';

  @override
  String get accountTypeAlipay => '支付寶';

  @override
  String get accountTypeWechat => '微信';

  @override
  String get accountTypeOther => '其他';

  @override
  String get accountInitialBalance => '初始資金';

  @override
  String get accountInitialBalanceHint => '請輸入初始資金（可選）';

  @override
  String get accountDeleteWarningTitle => '確認刪除';

  @override
  String accountDeleteWarningMessage(int count) {
    return '該帳戶有 $count 筆關聯交易，刪除後交易記錄中的帳戶信息將被清空。確認刪除嗎？';
  }

  @override
  String get accountDeleteConfirm => '確認刪除該帳戶嗎？';

  @override
  String get accountDeleteReconfirmMessage =>
      '再次確認：刪除後該帳戶不可復原，已儲存的帳戶資訊將永久丟失。確定要繼續嗎？';

  @override
  String get accountSelectTitle => '選擇帳戶';

  @override
  String get accountNone => '不選擇帳戶';

  @override
  String get accountsEnableFeature => '啟用帳戶功能';

  @override
  String get accountHide => '隱藏帳戶';

  @override
  String get accountUnhide => '恢復帳戶';

  @override
  String get accountRestore => '恢復';

  @override
  String get accountHiddenTag => '已隱藏';

  @override
  String accountHiddenSectionSummary(int count, String total) {
    return '已隱藏 $count · 合計 $total';
  }

  @override
  String get accountHideConfirmTitle => '隱藏此帳戶？';

  @override
  String get accountHideConfirmBody => '隱藏後無法再記帳到它，新增記帳時也不再顯示；歷史交易與餘額保留，可隨時恢復。';

  @override
  String accountHideRecurringWarn(int count) {
    return '有 $count 個週期帳單在用此帳戶，隱藏後這些帳單將跳過產生，建議先改到其他帳戶。';
  }

  @override
  String get accountHideClearedDefault => '已取消其預設帳戶設定';

  @override
  String get accountHiddenToast => '已隱藏';

  @override
  String get accountRestoredToast => '已恢復';

  @override
  String get privacyOpenSourceUrlError => '無法打開鏈接';

  @override
  String get updateCorruptedFileTitle => '安裝包已損壞';

  @override
  String get updateCorruptedFileMessage => '檢測到之前下載的安裝包不完整或已損壞，是否刪除並重新下載？';

  @override
  String get welcomeTitle => '歡迎使用 PiggyCount';

  @override
  String get welcomeDescription => '一個真正尊重您隱私的記帳應用';

  @override
  String get welcomeCurrencyDescription => '選擇您常用的貨幣，之後可以隨時在設定中更改';

  @override
  String get welcomeCreateDefaultLedger => '建立預設帳本';

  @override
  String get welcomePrivacyTitle => '開源透明 · 社群驅動';

  @override
  String get welcomePrivacyFeature1 => '100% 開源代碼，接受社區監督';

  @override
  String get welcomePrivacyFeature2 => '無隱私顧慮，資料完全本地儲存';

  @override
  String get welcomeOpenSourceFeature1 => '活躍的開發者社群，持續改進';

  @override
  String get welcomeViewGitHub => '訪問 GitHub 倉庫';

  @override
  String get welcomeCloudSyncTitle => '可選的雲端同步';

  @override
  String get welcomeCloudSyncDescription => 'PiggyCount 支援多種同步方式，資料完全由你掌控';

  @override
  String get welcomeCloudSyncFeature1 => '完全離線使用，無需雲端服務';

  @override
  String get welcomeCloudSyncFeature2 => '多裝置快照同步，資料存在你自己的雲端';

  @override
  String get welcomeCloudSyncFeature3 => 'iCloud / WebDAV / Supabase / S3 任選';

  @override
  String get widgetManagement => '桌面小組件';

  @override
  String get widgetManagementDesc => '在主屏幕快速查看收支情况';

  @override
  String get widgetGalleryTitle => '組件庫';

  @override
  String get widgetGalleryDesc => '以下為示例效果，實際將顯示目前帳本的真實資料，主題色跟隨 App 設定';

  @override
  String get widgetGalleryGlanceTitle => '收支速覽';

  @override
  String get widgetGalleryGlanceDesc => '今日和本月收支一目了然';

  @override
  String get widgetGalleryNetWorthDesc => '總資產、總負債與淨值趨勢';

  @override
  String get widgetGalleryQuickAddTitle => '快速記帳';

  @override
  String get widgetGalleryQuickAddDesc => '常用分類一鍵速記';

  @override
  String get widgetGalleryBudgetDesc => '預算進度即時掌握';

  @override
  String get widgetGalleryRecentDesc => '快速查看最近幾筆帳單';

  @override
  String get widgetGalleryDashboardTitle => '綜合儀表盤';

  @override
  String get widgetDashboardTitle => '本月概覽';

  @override
  String get widgetGalleryDashboardDesc => '收支、趨勢與最近交易一屏看盡';

  @override
  String get widgetSizeSmall => '小號';

  @override
  String get widgetSizeMedium => '中號';

  @override
  String get widgetSizeLarge => '大號';

  @override
  String get howToAddWidget => '如何添加小組件';

  @override
  String get iosWidgetStep1 => '長按主屏幕空白區域，進入編輯模式';

  @override
  String get iosWidgetStep2 => '點擊左上角的\"+\"按鈕';

  @override
  String get iosWidgetStep3 => '搜索並選擇\"小豬記帳\"';

  @override
  String get iosWidgetStep4 => '選擇中型小組件，添加到主屏幕';

  @override
  String get androidWidgetStep1 => '長按主屏幕空白區域';

  @override
  String get androidWidgetStep2 => '選擇\"小組件\"或\"Widgets\"';

  @override
  String get androidWidgetStep3 => '找到並長按\"小豬記帳\"小組件';

  @override
  String get androidWidgetStep4 => '拖動到主屏幕合适位置';

  @override
  String get aboutWidget => '關于小組件';

  @override
  String get widgetDescription =>
      '小組件會自動同步顯示今日和本月的收支數據，每30分鐘自動刷新一次。打開應用後會立即更新數據。';

  @override
  String get widgetQuickEntryTitle => '快捷記帳';

  @override
  String get widgetQuickEntryDesc =>
      '點擊小組件左側區域可快速新建支出，點擊右側區域可快速新建收入。也可透過捷徑使用 piggycount://new?type=transfer 快速發起轉帳。';

  @override
  String get appName => '小豬記帳';

  @override
  String get autoScreenshotBilling => '截圖自動記帳';

  @override
  String get autoScreenshotBillingDesc => '截圖後自動識別支付資訊';

  @override
  String get autoScreenshotBillingTitle => '截圖自動記帳';

  @override
  String get featureDescription => '功能說明';

  @override
  String get featureDescriptionContent =>
      '截圖支付頁面後，系統會自動識別金額和商家資訊，並建立支出記錄。\n\n⚡ 識別速度約 2-3 秒\n🤖 智慧配對分類\n📝 自動填寫備註';

  @override
  String get autoBilling => '自動記帳';

  @override
  String get enabled => '已啟用';

  @override
  String get disabled => '已停用';

  @override
  String get photosPermissionRequired => '需要相片權限才能監聽截圖';

  @override
  String get enableSuccess => '自動記帳已啟用';

  @override
  String get disableSuccess => '自動記帳已停用';

  @override
  String get autoBillingBatteryTitle => '保持背景執行';

  @override
  String get autoBillingBatteryGuideTitle => '電池最佳化設定';

  @override
  String get autoBillingBatteryDesc =>
      '自動記帳需要應用程式在背景保持執行。部分手機會在鎖屏後自動清理背景應用程式，導致自動記帳功能失效。建議關閉電池最佳化以確保功能正常工作。';

  @override
  String get autoBillingCheckBattery => '檢查電池最佳化狀態';

  @override
  String get autoBillingBatteryWarning =>
      '⚠️ 未關閉電池最佳化，應用程式可能會被系統自動清理，導致自動記帳失效。建議點擊上方「前往設定」按鈕關閉電池最佳化。';

  @override
  String get enableFailed => '啟用失敗';

  @override
  String get disableFailed => '停用失敗';

  @override
  String get iosAutoFeatureDesc =>
      '透過 iOS「捷徑」應用程式，實現截圖後自動識別支付資訊並記帳。設定後，每次截圖都會自動觸發識別。';

  @override
  String get iosAutoShortcutConfigTitle => '設定步驟（推薦方式 - URL 參數傳遞）：';

  @override
  String get iosAutoShortcutStep1 => '開啟「捷徑」應用程式，點擊右上角「+」建立新捷徑';

  @override
  String get iosAutoShortcutStep2 => '新增「截圖」操作';

  @override
  String get iosAutoShortcutStep3 => '搜尋並新增「小豬記帳 - 截圖自動記帳」操作';

  @override
  String get iosAutoShortcutStep4 => '將「小豬記帳」的截圖參數設定為上一步的「截圖」';

  @override
  String get iosAutoShortcutStep5 => '（可選）在系統設定 > 輔助使用 > 觸控 > 輕點背面中，綁定此捷徑';

  @override
  String get iosAutoShortcutStep6 => '完成！支付時雙擊手機背部即可快速記帳';

  @override
  String get iosAutoShortcutRecommendedTip =>
      '✅ 推薦：在「輕點背面」中綁定捷徑後，支付時雙擊手機背部即可自動截圖並識別記帳，無需手動截圖。';

  @override
  String get iosAutoBackTapTitle => '💡 雙擊背面快速觸發（推薦）';

  @override
  String get iosAutoBackTapDesc =>
      '設定 > 輔助使用 > 觸控 > 背面輕點\n• 選擇「點兩下」或「點三下」\n• 選擇剛建立的捷徑\n• 完成後，支付時雙擊手機背面即可自動記帳，無需截圖';

  @override
  String get iosAutoTutorialTitle => '影片教學';

  @override
  String get iosAutoTutorialDesc => '查看詳細設定影片教學';

  @override
  String get iosAutoImportTitle => '一鍵取得捷徑';

  @override
  String get iosAutoImportDesc =>
      '點擊下方按鈕，自動匯入已設定好的「截圖 → 自動記帳」捷徑，無需手動新增“截圖”操作和連接參數。匯入後建議在「輕點背面」中綁定它。';

  @override
  String get iosAutoImportButton => '取得捷徑';

  @override
  String get iosAutoImportFailed => '無法開啟捷徑連結，請檢查網路後重試';

  @override
  String get iosAutoManualConfigTitle => '手動設定（進階）';

  @override
  String get iosAutoManualConfigDesc => '若一鍵匯入無法使用，可依照以下步驟手動建立捷徑。';

  @override
  String get aiSettingsTitle => 'AI 小助手';

  @override
  String get aiSettingsSubtitle => '設定 AI 模型和識別策略';

  @override
  String get aiEnableTitle => '啟用 AI 小助手';

  @override
  String get aiEnableSubtitle => '使用 AI 視覺識別帳單截圖,提取金額、商家、時間等資訊,並支援自然語言對話';

  @override
  String get aiEnableToastOn => 'AI 小助手已啟用';

  @override
  String get aiEnableToastOff => 'AI 小助手已關閉';

  @override
  String get aiStrategyTitle => '執行策略';

  @override
  String get aiStrategyLocalFirst => '本機優先（推薦）';

  @override
  String get aiStrategyCloudFirst => '雲端優先';

  @override
  String get aiStrategyCloudFirstDesc => '優先使用雲端 API，失敗後降級到本機';

  @override
  String get aiStrategyLocalOnly => '僅本機';

  @override
  String get aiStrategyCloudOnly => '僅雲端';

  @override
  String get aiStrategyCloudOnlyDesc => '只使用雲端 API，不下載模型';

  @override
  String get aiStrategyUnavailable => '本機模型訓練中，敬請期待';

  @override
  String aiStrategySwitched(String strategy) {
    return '已切換: $strategy';
  }

  @override
  String get aiCloudApiKeyHintCustom => '輸入 API Key';

  @override
  String get aiCloudApiKeyHelper => 'GLM-*-Flash 模型完全免費';

  @override
  String get aiCloudApiGetKey => '取得 API Key';

  @override
  String get aiCloudApiTutorial => '詳細教學';

  @override
  String get aiCloudApiTestKey => '測試連線';

  @override
  String get aiChatConfigWarning => '未設定 AI 服務商，請先在設定中新增並綁定';

  @override
  String get aiChatGoToSettings => '前往設定';

  @override
  String get aiOcrRecognizing => '正在識別帳單...';

  @override
  String get aiNotConfiguredHint => '未配置 AI 服務，請前往「我的 → AI 設定」配置';

  @override
  String get aiOcrCheckLog => '識別失敗，請查看日誌瞭解詳情';

  @override
  String get aiOcrNoBill => '未識別到帳單資訊，請確認圖片是帳單後重試';

  @override
  String get aiNotConfiguredNotificationTitle => '❌ 無法識別截圖';

  @override
  String get aiNotConfiguredNotificationBody => '未配置 AI 服務，點選前往設定';

  @override
  String get autoBillingNotifyDetectedTitle => '✅ 偵測到截圖';

  @override
  String get autoBillingNotifyWaitingFileBody => '正在等待檔案寫入...';

  @override
  String get autoBillingNotifyRecognizingScreenshotTitle => '正在識別截圖...';

  @override
  String get autoBillingNotifyVisionAnalyzingBody => '正在呼叫 AI 視覺分析支付資訊，請稍候';

  @override
  String get autoBillingNotifyRecognizingTextTitle => '⏳ 正在識別';

  @override
  String get autoBillingNotifyTextAnalyzingBody => '正在呼叫 AI 解析支付資訊...';

  @override
  String get autoBillingNotifyRecognizeFailedTitle => '❌ 識別失敗';

  @override
  String get autoBillingNotifyRecognizeFailedBody => '無法從截圖提取帳單資訊，請檢查 AI 配置或圖片';

  @override
  String get autoBillingNotifyNoBillTitle => '未識別到帳單';

  @override
  String get autoBillingNotifyNoBillBody => '這張截圖未識別到帳單資訊，可能不是帳單';

  @override
  String get autoBillingNotifyFileUnavailableTitle => '識別失敗';

  @override
  String get autoBillingNotifyFileUnavailableBody => '截圖檔案不可用';

  @override
  String get autoBillingNotifyNoLedgerTitle => '❌ 自動記帳失敗';

  @override
  String get autoBillingNotifyNoLedgerBody => '無可用帳本，請先建立帳本';

  @override
  String get autoBillingNotifyNoAmountBody => '未能識別出金額資訊';

  @override
  String get autoBillingNotifyProcessFailedTitle => '❌ 處理失敗';

  @override
  String autoBillingNotifyProcessFailedBody(String error) {
    return '錯誤：$error';
  }

  @override
  String autoBillingNotifySuccessSingleTitle(String amount) {
    return '✅ 自動記帳成功 ¥$amount';
  }

  @override
  String autoBillingNotifySuccessMultiTitle(int count) {
    return '✅ 自動記帳成功 $count 筆';
  }

  @override
  String autoBillingNotifySuccessMultiBody(String amount) {
    return '合計 ¥$amount';
  }

  @override
  String autoBillingNotifySuccessSingleBodyNote(String note) {
    return '備註：$note';
  }

  @override
  String get autoBillingNotifySuccessSingleBodyDefault => '已自動建立記錄';

  @override
  String get aiOcrNoLedger => '未找到帳本';

  @override
  String aiOcrSuccess(String type, String amount) {
    return '✅ $type帳單建立成功 ¥$amount';
  }

  @override
  String aiOcrFailed(String error) {
    return '識別失敗: $error';
  }

  @override
  String get aiTypeIncome => '收入';

  @override
  String get aiTypeExpense => '支出';

  @override
  String get cloudSyncPageTitle => '雲同步';

  @override
  String get cloudSyncPageSubtitle => '手動上傳和下載帳本資料';

  @override
  String get cloudSyncHint =>
      '下載時可自動對比差異並逐條預覽。非即時同步，請避免多裝置同時編輯同一帳本。同步範圍為帳本資料（含關聯的帳戶、分類、標籤），不含附件。';

  @override
  String get dataManagement => '資料管理';

  @override
  String get dataManagementDesc => '匯入匯出、分類帳戶管理';

  @override
  String get dataManagementPageTitle => '資料管理';

  @override
  String get dataManagementAttachmentHint =>
      '還原資料時，請先匯入附件包，再匯入帳本資料（CSV或雲同步），以確保附件正確關聯。';

  @override
  String get smartBilling => '智慧記帳';

  @override
  String get smartBillingDesc => 'AI 助手、智慧識別、自動記帳';

  @override
  String get smartBillingPageTitle => '智慧記帳';

  @override
  String get smartBillingGuideHint => '長按首頁底部中間的 + 按鈕，即可快速使用這些功能';

  @override
  String get smartBillingImageBilling => '圖片記帳';

  @override
  String get smartBillingImageBillingDesc => '從相簿選擇支付截圖進行識別';

  @override
  String get smartBillingImageBillingGuide =>
      '在首頁長按底部中間的 + 按鈕,選擇「相簿」即可使用圖片記帳功能。需先在「我的 → AI 設定」配置 AI 服務,AI 視覺模型會自動識別金額、商家、時間等帳單資訊。';

  @override
  String get smartBillingVisionAIRequired =>
      '圖片辨識必須配置 AI 視覺服務，請先在「我的 → AI 設定」中配置';

  @override
  String get smartBillingCameraBilling => '拍照記帳';

  @override
  String get smartBillingCameraBillingDesc => '拍攝支付截圖進行識別';

  @override
  String get smartBillingCameraBillingGuide =>
      '在首頁長按底部中間的 + 按鈕,選擇「拍照」即可使用拍照記帳功能。需先在「我的 → AI 設定」配置 AI 服務,AI 視覺模型會自動識別金額、商家、時間等帳單資訊。';

  @override
  String get smartBillingVoiceBilling => '語音記帳';

  @override
  String get smartBillingVoiceBillingDesc => '透過語音輸入快速記帳';

  @override
  String get smartBillingVoiceBillingGuide =>
      '在首頁長按底部中間的 + 按鈕，選擇「語音」即可使用語音記帳功能。語音記帳需要透過AI將語音轉為文字並提取帳單資訊。';

  @override
  String get smartBillingAIRequired => '語音記帳必須配置 AI 語音辨識服務，請先在「我的 → AI 設定」中配置';

  @override
  String get smartBillingAutoTags => '自動關聯標籤';

  @override
  String get smartBillingAutoTagsDesc => '智慧記帳時自動根據分類關聯常用標籤';

  @override
  String get smartBillingAutoAttachment => '自動新增附件';

  @override
  String get smartBillingAutoAttachmentDesc => '圖片/拍照記帳時自動將原圖新增為附件';

  @override
  String get autoScreenshotBillingIosTitle => '自動記帳';

  @override
  String get autoScreenshotBillingIosDesc => '透過快捷指令自動識別支付資訊記帳';

  @override
  String get shareBilling => '分享記帳';

  @override
  String get shareBillingDesc => '從支付寶/微信分享支付截圖即可記帳';

  @override
  String get shareBillingGuide =>
      '在支付寶、微信、相簿等應用中看到支付截圖時，點擊「分享」並選擇「小豬記帳」，即可自動識別金額、商家、時間等資訊並記帳，無需先儲存截圖。';

  @override
  String get shareBillingActionHint => '分享後會在背景自動識別記帳，無需手動開啟小豬記帳';

  @override
  String get automation => '自動化';

  @override
  String get automationDesc => '週期記帳、記帳提醒';

  @override
  String get automationPageTitle => '自動化功能';

  @override
  String get appearanceSettings => '個性化設定';

  @override
  String get appearanceSettingsDesc => '主題、字體、語言、應用鎖等';

  @override
  String get appearanceSettingsPageTitle => '個性化設定';

  @override
  String get about => '關於';

  @override
  String get aboutDesc => '版本資訊';

  @override
  String get mineRateApp => '給應用評分';

  @override
  String get mineRateAppSubtitle => '在App Store上為我們打分';

  @override
  String get aboutPageTitle => '關於';

  @override
  String get aboutPageLoadingVersion => '載入版本號中...';

  @override
  String get aboutDeveloperStoryTitle => '開發者的話';

  @override
  String get aboutDeveloperStory =>
      '從 2015 年實習起，我堅持記帳至今已超過十年。因為擔心記帳軟體的廣告、付費、隱私洩露和停運跑路，我決定自己做一個——最初只是給自己和家人用的小工具。\n\n2025 年 9 月，小豬記帳發佈了第一個版本。說實話，那時候心裡沒什麼底，不知道會不會有人用。但慢慢地，開始收到用戶的回饋——有人說終於找到了一款乾淨的記帳軟體，有人提了很好的建議，也有人默默給了五星好評。每一條回饋都讓我覺得，這件事值得繼續做下去。\n\n小豬記帳沒有廣告、沒有會員、完全免費開源。你的每一筆資料都只存在你自己的手機裡，不會被上傳到任何第三方伺服器。但上架和維護一款 App 並非零成本——開發者帳號、伺服器等開支目前靠社群捐贈勉強支撐，每一次適配新系統、修復 Bug、開發新功能，也都是工作之餘一點點完成的。\n\n如果你覺得小豬記帳對你有幫助，一個好評、一次分享或一筆捐贈，都能讓這個小專案走得更遠。謝謝你的信任。';

  @override
  String get aboutPiggyAssets => '小豬家當 PiggyAssets';

  @override
  String get aboutPiggyAssetsSubtitle => '視覺化你的全部資產配置';

  @override
  String get aboutPiggyAssetsIntro =>
      '小豬記帳側重日常流水,小豬家當是它的姐妹產品,專注資產配置視覺化:跨帳戶淨資產趨勢、房產 / 投資 / 加密資產分類、收益率與持倉時長、配置占比一目了然。';

  @override
  String get aboutPiggyDNS => '小豬域名 PiggyDNS';

  @override
  String get aboutPiggyDNSSubtitle => '簡潔高效的 DNS 管理工具';

  @override
  String get aboutPiggyDNSIntro =>
      '如果你的域名分散在 Cloudflare 和阿里雲,小豬域名把它們聚合在一處管理:批次改記錄、A/AAAA 切換、解析遷移、子網域批次管理 — 不用在兩家控制台來回切。';

  @override
  String get productPromoAndroidTitle => '申請加入內測';

  @override
  String get productPromoAndroidMessage =>
      '這款 App 還在 Google Play 內測階段,需要邀請才能下載。\n\n申請方式:寄信給我們,告訴我們你的 Google 帳號信箱(必填),以及簡單說明使用場景(選填)。我們會在 1-3 天內回覆並加你到內測白名單。';

  @override
  String get productPromoOpenStore => '前往應用商店';

  @override
  String get productPromoTestFlight => 'TestFlight 內測';

  @override
  String get productPromoEmailLabel => '申請信箱(點擊複製)';

  @override
  String get productPromoCopiedToast => '信箱已複製到剪貼簿';

  @override
  String get productPromoMailUnavailable => '未偵測到郵件應用,信箱已複製到剪貼簿,請開啟任意郵件應用貼上寄出';

  @override
  String get productPromoEmailButton => '寄送郵件';

  @override
  String get productPromoWebsiteButton => '前往官網';

  @override
  String productPromoEmailSubject(String productName) {
    return '申請內測 - $productName';
  }

  @override
  String productPromoEmailBody(String productName) {
    return '你好,\n\n我希望加入「$productName」的 Google Play 內測,我的 Google 帳號信箱是:\n\n(請填寫你的 Gmail / Google 帳號信箱)\n\n謝謝!';
  }

  @override
  String get logCenterTitle => '日誌中心';

  @override
  String get logCenterSubtitle => '查看應用程式執行日誌';

  @override
  String get logCenterSearchHint => '搜尋日誌內容或標籤...';

  @override
  String get logCenterFilterLevel => '日誌級別';

  @override
  String get logCenterFilterPlatform => '平台';

  @override
  String get logCenterTotal => '全部';

  @override
  String get logCenterFiltered => '已過濾';

  @override
  String get logCenterEmpty => '暫無日誌';

  @override
  String get logCenterExport => '匯出';

  @override
  String get logCenterClear => '清空';

  @override
  String get logCenterExportFailed => '匯出失敗';

  @override
  String get logCenterClearConfirmTitle => '清空日誌';

  @override
  String get logCenterClearConfirmMessage => '確定要清空所有日誌嗎？此操作無法復原。';

  @override
  String get logCenterCleared => '日誌已清空';

  @override
  String get logCenterCopied => '已複製到剪貼簿';

  @override
  String get configImportExportTitle => '配置匯入匯出';

  @override
  String get configImportExportSubtitle => '備份和恢復應用配置';

  @override
  String get configImportExportInfoTitle => '功能說明';

  @override
  String get configImportExportInfoMessage =>
      '此功能用於匯出和匯入應用配置，包括雲端服務配置、AI配置等。配置檔案採用YAML格式，方便檢視和編輯。\\n\\n⚠️ 配置檔案包含敏感資訊（如API金鑰、密碼等），請妥善保管。';

  @override
  String get configExportTitle => '匯出配置';

  @override
  String get configExportSubtitle => '將目前配置匯出為YAML檔案';

  @override
  String get configExportShareSubject => 'PiggyCount 配置檔案';

  @override
  String get configExportSuccess => '配置匯出成功';

  @override
  String get configExportFailed => '配置匯出失敗';

  @override
  String get configImportTitle => '匯入配置';

  @override
  String get configImportSubtitle => '從YAML檔案恢復配置';

  @override
  String get configImportNoFilePath => '未選擇檔案';

  @override
  String get configImportConfirmTitle => '確認匯入';

  @override
  String get configImportReconfirmTitle => '確認匯入';

  @override
  String get configImportReconfirmMessage =>
      '再次確認：匯入將覆蓋現有配置且不可復原，建議先備份。確定要繼續嗎？';

  @override
  String get configImportSuccess => '配置匯入成功';

  @override
  String get configImportFailed => '配置匯入失敗';

  @override
  String get configImportRestartTitle => '需要重新啟動';

  @override
  String get configImportRestartMessage => '配置已匯入，部分配置需要重新啟動應用程式後生效。';

  @override
  String get configImportExportIncludesTitle => '包含的配置項';

  @override
  String configExportSavedTo(String path) {
    return '已儲存至: $path';
  }

  @override
  String get configExportViewContent => '檢視內容';

  @override
  String get configExportCopyContent => '複製內容';

  @override
  String get configExportContentCopied => '已複製到剪貼簿';

  @override
  String get configExportReadFileFailed => '讀取檔案失敗';

  @override
  String get configIncludeLedgers => '帳本';

  @override
  String get configIncludeSupabase => 'Supabase 雲端服務配置';

  @override
  String get configIncludeWebdav => 'WebDAV 雲端服務配置';

  @override
  String get configIncludeS3 => 'S3 雲端服務配置';

  @override
  String get configIncludeAI => 'AI 智慧識別配置';

  @override
  String get configIncludeAISubtitle => '服務商、能力綁定、模型設定等';

  @override
  String get configIncludeAppSettings => '應用程式設定（語言、外觀、提醒、預設帳戶等）';

  @override
  String get configIncludeRecurringTransactions => '週期帳單';

  @override
  String get configIncludeAccounts => '帳戶';

  @override
  String get configIncludeCategories => '分類';

  @override
  String get configIncludeTags => '標籤';

  @override
  String get configIncludeBudgets => '預算';

  @override
  String get configIncludeOtherSettings => '其他設定';

  @override
  String get configIncludeOtherSettingsSubtitle => '包含雲端服務配置、AI配置、應用程式設定等';

  @override
  String get configExportSelectTitle => '選擇匯出內容';

  @override
  String get configExportPreviewTitle => '匯出預覽';

  @override
  String get configExportConfirmTitle => '確認匯出';

  @override
  String get configImportSelectTitle => '選擇匯入內容';

  @override
  String get configImportPreviewTitle => '匯入預覽';

  @override
  String get ledgersConflictTitle => '同步衝突';

  @override
  String get ledgersConflictMessage => '本地和雲端帳本資料不一致，請選擇操作：';

  @override
  String ledgersConflictLocalInfo(int count) {
    return '本地：$count 筆帳單';
  }

  @override
  String ledgersConflictRemoteInfo(int count) {
    return '雲端：$count 筆帳單';
  }

  @override
  String ledgersConflictRemoteUpdated(String time) {
    return '雲端更新：$time';
  }

  @override
  String ledgersConflictLocalFingerprint(String fp) {
    return '本地指紋：$fp';
  }

  @override
  String ledgersConflictRemoteFingerprint(String fp) {
    return '雲端指紋：$fp';
  }

  @override
  String get ledgersConflictUpload => '上傳到雲端';

  @override
  String get ledgersConflictDownload => '下載到本地';

  @override
  String get ledgersConflictUploading => '正在上傳...';

  @override
  String get ledgersConflictDownloading => '正在下載...';

  @override
  String get ledgersConflictUploadSuccess => '上傳成功';

  @override
  String ledgersConflictDownloadSuccess(int inserted) {
    return '下載成功，已合併 $inserted 筆帳單';
  }

  @override
  String get storageManagementTitle => '儲存空間管理';

  @override
  String get storageManagementSubtitle => '清理快取釋放空間';

  @override
  String get storageAIModels => 'AI模型';

  @override
  String get storageAPKFiles => '安裝包';

  @override
  String get storageNoData => '無資料';

  @override
  String get storageFiles => '個檔案';

  @override
  String get storageHint => '點擊項目可清理對應的快取檔案';

  @override
  String get storageClearConfirmTitle => '確認清理';

  @override
  String storageClearAIModelsMessage(String size) {
    return '確定要清理所有AI模型嗎？大小：$size';
  }

  @override
  String get storageClearReconfirmMessage => '再次確認：清理後需要重新下載，確定要繼續嗎？';

  @override
  String storageClearAPKMessage(String size) {
    return '確定要清理所有安裝包嗎？大小：$size';
  }

  @override
  String get storageClearSuccess => '清理成功';

  @override
  String get accountNoTransactions => '無交易記錄';

  @override
  String get accountTransactionHistory => '交易歷史';

  @override
  String get accountTotalBalance => '淨資產';

  @override
  String get accountCurrencyLocked => '該帳戶已有交易記錄，無法變更幣別';

  @override
  String get accountDefaultIncomeTitle => '預設收入帳戶';

  @override
  String get accountDefaultExpenseTitle => '預設支出帳戶';

  @override
  String get accountDefaultNone => '不設定';

  @override
  String get commonNotice => '提示';

  @override
  String get transferTitle => '轉帳';

  @override
  String get transferIconSettings => '轉帳圖示設定';

  @override
  String get transferIconSettingsDesc => '自訂轉帳記錄的顯示圖示';

  @override
  String get transferFromAccount => '轉出帳戶';

  @override
  String get transferToAccount => '轉入帳戶';

  @override
  String get transferSelectAccount => '選擇帳戶';

  @override
  String get transferCreateSuccess => '轉帳記錄建立成功';

  @override
  String get transferUpdateSuccess => '轉帳記錄更新成功';

  @override
  String get transferDifferentCurrencyError => '轉帳只支援相同幣別的帳戶';

  @override
  String get transferToPrefix => '轉入';

  @override
  String get transferFromPrefix => '轉出';

  @override
  String get welcomeCategoryModeTitle => '選擇分類模式';

  @override
  String get welcomeCategoryModeDescription => '選擇適合您需求的分類結構';

  @override
  String get welcomeCategoryModeFlatTitle => '扁平分類';

  @override
  String get welcomeCategoryModeFlatDescription => '簡單快捷';

  @override
  String get welcomeCategoryModeFlatFeature1 => '扁平化結構，簡單易用';

  @override
  String get welcomeCategoryModeFlatFeature2 => '適合簡單分類需求';

  @override
  String get welcomeCategoryModeFlatFeature3 => '快速選擇，高效記帳';

  @override
  String get welcomeCategoryModeHierarchicalTitle => '階層分類';

  @override
  String get welcomeCategoryModeHierarchicalDescription => '精細管理';

  @override
  String get welcomeCategoryModeHierarchicalFeature1 => '支援父子分類層級';

  @override
  String get welcomeCategoryModeHierarchicalFeature2 => '更精細的交易分類';

  @override
  String get welcomeCategoryModeHierarchicalFeature3 => '適合精細化管理';

  @override
  String get welcomeCategoryModeNoneTitle => '不建立分類';

  @override
  String get welcomeCategoryModeNoneDescription => '完全自訂，按需新增';

  @override
  String get welcomeCategoryModeNoneFeature1 => '不預設任何分類';

  @override
  String get welcomeCategoryModeNoneFeature2 => '完全按自己需求建立';

  @override
  String get welcomeCategoryModeNoneFeature3 => '適合有特殊分類需求的使用者';

  @override
  String get welcomeExistingUserTitle => '老用戶？';

  @override
  String get welcomeExistingUserButton => '匯入配置';

  @override
  String get welcomeImportingConfig => '正在匯入配置...';

  @override
  String get welcomeImportSuccess => '配置匯入成功';

  @override
  String welcomeImportFailed(String error) {
    return '配置匯入失敗: $error';
  }

  @override
  String get welcomeImportNoFile => '未選擇檔案';

  @override
  String get welcomeImportAttachmentTitle => '匯入附件';

  @override
  String get welcomeImportAttachmentDesc => '檢測到您匯入了配置檔案，是否需要匯入附件檔案？';

  @override
  String get welcomeImportAttachmentButton => '選擇附件檔案';

  @override
  String get welcomeImportAttachmentSkip => '跳過';

  @override
  String welcomeImportAttachmentSuccess(int imported) {
    return '附件匯入完成：匯入 $imported 個';
  }

  @override
  String welcomeImportAttachmentFailed(String error) {
    return '附件匯入失敗: $error';
  }

  @override
  String get welcomeImportingAttachment => '正在匯入附件...';

  @override
  String get iosVersionWarningTitle => '需要 iOS 16.0 或更高版本';

  @override
  String get iosVersionWarningDesc =>
      '截圖自動記帳功能使用了 iOS 16 引入的 App Intents 框架。您的裝置系統版本較低，暫不支援此功能。\n\n請升級到 iOS 16 或更高版本以使用此功能。';

  @override
  String get aiChatTitle => 'AI助手';

  @override
  String get aiChatClearHistory => '清除對話歷史';

  @override
  String get aiChatClearHistoryDialogTitle => '清除對話歷史';

  @override
  String get aiChatClearHistoryDialogContent => '確定要清除所有對話記錄嗎？此操作不可恢復。';

  @override
  String get aiChatInputHint => '例如：買了杯咖啡35元';

  @override
  String get aiChatThinking => '思考中...';

  @override
  String get aiChatHistoryCleared => '對話歷史已清空';

  @override
  String get aiChatCopy => '複製';

  @override
  String get aiChatCopied => '已複製到剪貼簿';

  @override
  String get aiChatDeleteMessageConfirm => '確定要刪除這條訊息嗎？';

  @override
  String get aiChatMessageDeleted => '訊息已刪除';

  @override
  String get aiChatUndone => '已撤銷';

  @override
  String get aiChatUndoFailed => '撤銷失敗';

  @override
  String get aiChatTransactionNotFound => '交易記錄不存在';

  @override
  String get aiChatOpenEditorFailed => '打開編輯頁面失敗';

  @override
  String get aiChatSendFailed => '發送失敗';

  @override
  String get billCardSuccess => '記帳成功';

  @override
  String get billCardUndone => '已撤銷';

  @override
  String get billCardAmount => '💰 金額';

  @override
  String get billCardCategory => '🏷️ 分類';

  @override
  String get billCardTime => '📅 時間';

  @override
  String get billCardNote => '📝 備註';

  @override
  String get billCardAccount => '💳 帳戶';

  @override
  String get billCardUndo => '撤銷';

  @override
  String get billCardEdit => '修改';

  @override
  String get aiQuickCommandFinancialHealthTitle => '財務健康分析';

  @override
  String get aiQuickCommandFinancialHealthDesc => '分析收支平衡和儲蓄率';

  @override
  String get aiQuickCommandFinancialHealthPrompt =>
      '請根據以下資料分析我的財務健康狀況：\n\n[monthlyStats]\n\n[recentTrends]\n\n請從收支平衡、儲蓄率、消費趨勢等角度給出專業分析和建議。請用繁體中文回覆。';

  @override
  String get aiQuickCommandMonthlyExpenseTitle => '本月支出總結';

  @override
  String get aiQuickCommandMonthlyExpenseDesc => '月度支出分析和建議';

  @override
  String get aiQuickCommandMonthlyExpensePrompt =>
      '請根據以下資料總結我本月的支出情況：\n\n[monthlyStats]\n\n[categoryStats]\n\n請分析哪些分類佔比最高，並給出優化建議。請用繁體中文回覆。';

  @override
  String get aiQuickCommandCategoryAnalysisTitle => '分類佔比分析';

  @override
  String get aiQuickCommandCategoryAnalysisDesc => '分析各分類支出分佈';

  @override
  String get aiQuickCommandCategoryAnalysisPrompt =>
      '請根據以下資料分析我的分類支出情況：\n\n[categoryStats]\n\n請指出是否存在不合理的支出比例，並給出優化建議。請用繁體中文回覆。';

  @override
  String get aiQuickCommandBudgetPlanningTitle => '預算規劃建議';

  @override
  String get aiQuickCommandBudgetPlanningDesc => '智能預算推薦';

  @override
  String get aiQuickCommandBudgetPlanningPrompt =>
      '請根據以下資料幫我規劃合理的預算：\n\n[monthlyStats]\n\n[recentTrends]\n\n請給出各分類的具體預算金額和執行建議。請用繁體中文回覆。';

  @override
  String get aiQuickCommandAbnormalExpenseTitle => '異常支出提醒';

  @override
  String get aiQuickCommandAbnormalExpenseDesc => '識別異常消費';

  @override
  String get aiQuickCommandAbnormalExpensePrompt =>
      '請根據以下資料檢查是否有異常支出：\n\n[recentTransactions]\n\n[monthlyStats]\n\n請識別出明顯高於平常的支出，並給出分析。請用繁體中文回覆。';

  @override
  String get aiQuickCommandSavingTipsTitle => '省錢小貼士';

  @override
  String get aiQuickCommandSavingTipsDesc => '個性化省錢建議';

  @override
  String get aiQuickCommandSavingTipsPrompt =>
      '請根據以下資料給出實用的省錢建議：\n\n[categoryStats]\n\n[recentTrends]\n\n請給出3-5條具體可行的建議。請用繁體中文回覆。';

  @override
  String get billCardUnknownLedger => '未知帳本';

  @override
  String get aiPromptEditTitle => '提示詞編輯';

  @override
  String get aiPromptEditSubtitle => '自訂 AI 帳單識別提示詞';

  @override
  String get aiPromptAdvancedSettings => '進階設定';

  @override
  String get aiAdvancedSettingsDesc => '模型選擇、執行策略、本地模型、提示詞';

  @override
  String get aiPromptEditEntry => '提示詞編輯';

  @override
  String get aiPromptEditEntryDesc => '自訂 AI 帳單識別提示詞，可分享給其他使用者';

  @override
  String get aiPromptVariables => '變數說明';

  @override
  String get aiPromptVariablesHint => '點擊展開檢視可用變數';

  @override
  String get aiPromptContent => '提示詞內容';

  @override
  String get aiPromptUnsaved => '未儲存';

  @override
  String get aiPromptInputHint => '輸入提示詞...';

  @override
  String get aiPromptPreview => '預覽';

  @override
  String get aiPromptSave => '儲存';

  @override
  String get aiPromptSaved => '提示詞已儲存';

  @override
  String get aiPromptResetDefault => '恢復預設';

  @override
  String get aiPromptResetConfirmTitle => '恢復預設';

  @override
  String get aiPromptResetConfirmMessage => '確定要恢復預設提示詞嗎？您的自訂內容將會遺失。';

  @override
  String get aiPromptPasted => '已貼上';

  @override
  String get aiPromptPreviewTitle => '提示詞預覽';

  @override
  String get aiPromptPreviewNote => '以上預覽使用範例資料替換變數，實際執行時會使用真實資料';

  @override
  String get aiPromptVarInputSource => '輸入來源描述，如「從以下支付帳單文字中」';

  @override
  String get aiPromptVarCurrentTime => '目前日期和時間，如「2025-01-15 14:30」';

  @override
  String get aiPromptVarCurrentDate => '目前日期，如「2025-01-15」';

  @override
  String get aiPromptVarOcrText => '使用者輸入的文字內容';

  @override
  String get aiPromptVarCategories => '支出和收入分類清單';

  @override
  String get aiPromptVarAccounts => '使用者的帳戶清單（可能為空）';

  @override
  String get aiModelTitle => '文字推理模型';

  @override
  String get aiVisionModelTitle => '視覺模型';

  @override
  String get aiModelFast => '快速';

  @override
  String get aiModelAccurate => '準確';

  @override
  String aiModelSwitched(String modelName) {
    return '已切換到 $modelName';
  }

  @override
  String get aiCustomBaseUrlHelper =>
      '標準聊天補全API位址，例如 https://api.example.com/v1';

  @override
  String get aiTextModelTitle => '文字模型';

  @override
  String get aiAudioModelTitle => '語音模型';

  @override
  String get customFieldManageTitle => '自訂欄位';

  @override
  String get customFieldManageSubtitle => '為本帳本定義欄位名稱與類型';

  @override
  String get customFieldManageEmpty => '尚無自訂欄位';

  @override
  String get customFieldManageEmptyHint => '新增「稅費」「發票號」等欄位，為每筆明細記錄額外資訊';

  @override
  String get customFieldAdd => '新增欄位';

  @override
  String get customFieldAddTitle => '新增自訂欄位';

  @override
  String get customFieldEditTitle => '編輯自訂欄位';

  @override
  String get customFieldNameLabel => '欄位名稱';

  @override
  String get customFieldNameHint => '例如：稅費';

  @override
  String get customFieldNameRequired => '請輸入欄位名稱';

  @override
  String get customFieldNameDuplicate => '已存在同名欄位';

  @override
  String get customFieldTypeLabel => '欄位類型';

  @override
  String get customFieldTypeAmount => '金額';

  @override
  String get customFieldTypeText => '文字';

  @override
  String get customFieldTypeDate => '日期';

  @override
  String get customFieldCreateSuccess => '欄位已新增';

  @override
  String get customFieldUpdateSuccess => '欄位已更新';

  @override
  String get customFieldDeleteSuccess => '欄位已刪除';

  @override
  String get customFieldDeleteConfirmTitle => '刪除自訂欄位';

  @override
  String customFieldDeleteConfirmMessage(String name) {
    return '確定刪除「$name」嗎？本帳本中已記錄的該欄位值將一併清除，且無法復原。';
  }

  @override
  String get customFieldDeleteReconfirmMessage =>
      '再次確認：刪除後該欄位及本帳本中已記錄的值將永久清除、無法復原。確定要繼續嗎？';

  @override
  String get customFieldSectionTitle => '自訂欄位';

  @override
  String get customFieldSectionEmpty => '此帳本尚無自訂欄位';

  @override
  String get customFieldDatePick => '選擇日期';

  @override
  String get customFieldTextHint => '請輸入內容';

  @override
  String get customFieldAmountHint => '0.00';

  @override
  String get customFieldSortHint => '長按拖曳排序';

  @override
  String get tagManageTitle => '標籤管理';

  @override
  String get tagManageSubtitle => '管理交易標籤';

  @override
  String get tagManageEmpty => '暫無標籤';

  @override
  String get tagManageEmptyHint => '點擊右上角新增標籤';

  @override
  String get tagManageGenerateDefault => '產生預設標籤';

  @override
  String get tagManageGenerateDefaultConfirm => '確定要產生預設標籤嗎？已有同名標籤不會被覆蓋。';

  @override
  String get tagManageGenerateDefaultSuccess => '預設標籤已產生';

  @override
  String get tagEditTitle => '編輯標籤';

  @override
  String get tagAddTitle => '新增標籤';

  @override
  String get tagNameLabel => '標籤名稱';

  @override
  String get tagNameHint => '請輸入標籤名稱';

  @override
  String get tagNameRequired => '標籤名稱不能為空';

  @override
  String get tagNameDuplicate => '標籤名稱已存在';

  @override
  String get tagColorLabel => '標籤顏色';

  @override
  String get tagCreateSuccess => '標籤建立成功';

  @override
  String get tagUpdateSuccess => '標籤更新成功';

  @override
  String get tagDeleteConfirmTitle => '刪除標籤';

  @override
  String tagDeleteConfirmMessage(String name) {
    return '確定要刪除標籤「$name」嗎？此操作不會影響已關聯的交易記錄。';
  }

  @override
  String get tagDeleteSuccess => '標籤已刪除';

  @override
  String get tagSelectTitle => '選擇標籤';

  @override
  String get tagSelectHint => '可多選';

  @override
  String get tagSelectCreateNew => '新建標籤';

  @override
  String get tagSelectRecentlyUsed => '最近使用';

  @override
  String get tagSelectAllTags => '全部標籤';

  @override
  String tagTransactionCount(int count) {
    return '$count筆';
  }

  @override
  String get tagDetailTitle => '標籤詳情';

  @override
  String get tagDetailTotalCount => '交易筆數';

  @override
  String get tagDetailTotalExpense => '總支出';

  @override
  String get tagDetailTotalIncome => '總收入';

  @override
  String get tagDetailTransactionList => '關聯交易';

  @override
  String get tagDetailNoTransactions => '暫無關聯交易';

  @override
  String get tagDetailNoTransactionsHint => '使用此標籤的交易將在此顯示';

  @override
  String get tagNotFound => '標籤不存在';

  @override
  String get tagDefaultMeituan => '美團';

  @override
  String get tagDefaultEleme => '餓了麼';

  @override
  String get tagDefaultTaobao => '淘寶';

  @override
  String get tagDefaultJD => '京東';

  @override
  String get tagDefaultPDD => '拼多多';

  @override
  String get tagDefaultStarbucks => '星巴克';

  @override
  String get tagDefaultLuckin => '瑞幸咖啡';

  @override
  String get tagDefaultMcDonalds => '麥當勞';

  @override
  String get tagDefaultKFC => '肯德基';

  @override
  String get tagDefaultHema => '盒馬';

  @override
  String get tagDefaultSams => '山姆';

  @override
  String get tagDefaultCostco => 'Costco';

  @override
  String get tagDefaultBusinessTrip => '出差';

  @override
  String get tagDefaultTravel => '旅行';

  @override
  String get tagDefaultDining => '聚餐';

  @override
  String get tagDefaultOnlineShopping => '網購';

  @override
  String get tagDefaultDaily => '日常';

  @override
  String get tagDefaultReimbursement => '報銷';

  @override
  String get tagDefaultRefundable => '可退款';

  @override
  String get tagDefaultRefunded => '已退款';

  @override
  String get tagDefaultVoiceBilling => '語音記帳';

  @override
  String get tagDefaultImageBilling => '圖片記帳';

  @override
  String get tagDefaultCameraBilling => '拍照記帳';

  @override
  String get tagDefaultAiBilling => 'AI記帳';

  @override
  String get tagShare => '分享標籤';

  @override
  String get tagImport => '匯入標籤';

  @override
  String get tagClearUnused => '清理未使用';

  @override
  String tagShareSuccess(String path) {
    return '已儲存到 $path';
  }

  @override
  String get tagShareSubject => 'PiggyCount 標籤配置';

  @override
  String get tagShareFailed => '分享失敗';

  @override
  String get tagImportInvalidFile => '請選擇 YAML 配置檔案';

  @override
  String get tagImportNoTags => '檔案中沒有標籤資料';

  @override
  String get tagImportModeTitle => '選擇匯入模式';

  @override
  String get tagImportModeMerge => '合併';

  @override
  String get tagImportModeMergeDesc => '保留現有標籤，新增不存在的';

  @override
  String get tagImportModeOverwrite => '覆蓋';

  @override
  String get tagImportModeOverwriteDesc => '清空未使用標籤後匯入';

  @override
  String get tagImportSuccess => '匯入成功';

  @override
  String get tagImportFailed => '匯入失敗';

  @override
  String get tagClearUnusedEmpty => '沒有未使用的標籤';

  @override
  String get tagClearUnusedTitle => '清理未使用標籤';

  @override
  String tagClearUnusedMessage(int count) {
    return '確定要刪除 $count 個未使用的標籤嗎？';
  }

  @override
  String get tagClearUnusedReconfirmMessage =>
      '再次確認：刪除後這些標籤不可復原，若誤刪需要重新建立。確定要繼續嗎？';

  @override
  String tagClearUnusedSuccess(int count) {
    return '已刪除 $count 個標籤';
  }

  @override
  String get tagClearUnusedFailed => '清理失敗';

  @override
  String get homeSwitchLedger => '選擇帳本';

  @override
  String get homeManageLedgers => '管理帳本';

  @override
  String get budgetTitle => '預算管理';

  @override
  String get budgetShowOnHome => '在首頁顯示預算';

  @override
  String get budgetEmptyHint => '還沒有設定預算';

  @override
  String get budgetAddTotal => '新增總預算';

  @override
  String get budgetMonthlyBudget => '本月預算';

  @override
  String get budgetUsed => '已用';

  @override
  String get budgetRemaining => '剩餘';

  @override
  String budgetDaysRemaining(int days) {
    return '剩餘 $days 天';
  }

  @override
  String budgetDailyAvailable(String amount) {
    return '日均可用 $amount';
  }

  @override
  String get budgetCategoryBudgets => '分類預算';

  @override
  String get budgetEditTitle => '編輯預算';

  @override
  String get budgetAddTitle => '新增預算';

  @override
  String get budgetTypeTotalLabel => '總預算';

  @override
  String get budgetTypeCategoryLabel => '分類預算';

  @override
  String get budgetAmountLabel => '預算金額';

  @override
  String get budgetAmountHint => '請輸入預算金額';

  @override
  String get budgetCategoryLabel => '選擇分類';

  @override
  String get budgetCategoryHint => '請選擇預算分類';

  @override
  String get budgetPeriodLabel => '週期';

  @override
  String get budgetSaveSuccess => '預算儲存成功';

  @override
  String get budgetDeleteConfirm => '確定刪除此預算？';

  @override
  String get budgetDeleteSuccess => '預算已刪除';

  @override
  String get attachmentAdd => '添加圖片';

  @override
  String get attachmentTakePhoto => '拍照';

  @override
  String get attachmentChooseFromGallery => '從相簿選擇';

  @override
  String get attachmentMaxReached => '已達到最大附件數量';

  @override
  String get attachmentDeleteConfirm => '確定刪除此附件？';

  @override
  String get commonDeleted => '已刪除';

  @override
  String get attachmentExportTitle => '匯出附件';

  @override
  String get attachmentExportSubtitle => '將所有附件打包匯出為壓縮檔案';

  @override
  String get attachmentImportTitle => '匯入附件';

  @override
  String get attachmentImportSubtitle => '從壓縮檔案匯入附件';

  @override
  String get attachmentExportEmpty => '沒有附件需要匯出';

  @override
  String attachmentExportProgress(int current, int total) {
    return '正在匯出附件 ($current/$total)';
  }

  @override
  String attachmentExportProgressDetail(
      int attachmentCount, int iconCount, int current, int total) {
    return '正在匯出 $attachmentCount 個附件 + $iconCount 個圖標 ($current/$total)';
  }

  @override
  String get attachmentExportSuccess => '附件匯出成功';

  @override
  String attachmentExportSavedTo(String path) {
    return '已儲存到: $path';
  }

  @override
  String get attachmentImportConflictStrategy => '衝突處理策略';

  @override
  String get attachmentImportConflictSkip => '跳過已存在的附件';

  @override
  String get attachmentImportConflictOverwrite => '覆蓋已存在的附件';

  @override
  String attachmentImportProgress(int current, int total) {
    return '正在匯入附件 ($current/$total)';
  }

  @override
  String attachmentImportResult(
      int imported, int skipped, int overwritten, int failed) {
    return '匯入 $imported 張，跳過 $skipped 張，覆蓋 $overwritten 張，失敗 $failed 張';
  }

  @override
  String get attachmentImportFailed => '附件匯入失敗';

  @override
  String attachmentArchiveInfo(int count, String date) {
    return '$count 個附件，匯出於 $date';
  }

  @override
  String get attachmentStartImport => '開始匯入';

  @override
  String get attachmentImportReconfirmTitle => '覆蓋匯入確認';

  @override
  String get attachmentImportReconfirmMessage =>
      '再次確認：選擇「覆蓋」後，同名附件將被封存中的檔案替換且無法復原。確定要繼續嗎？';

  @override
  String get attachmentPreview => '預覽附件';

  @override
  String get attachmentPreviewEmpty => '暫無附件';

  @override
  String get attachmentExportPreviewTitle => '匯出預覽';

  @override
  String get attachmentImportPreviewTitle => '匯入預覽';

  @override
  String get shortcutsGuide => '快捷指令';

  @override
  String get shortcutsGuideDesc => '快速開啟語音、拍照等記帳方式';

  @override
  String get shortcutsIntroTitle => '快速記帳';

  @override
  String get shortcutsIntroDesc => '使用快捷指令，可以在桌面直接開啟語音記帳、拍照記帳等功能，無需先開啟 App。';

  @override
  String get availableShortcuts => '可用快捷指令';

  @override
  String get shortcutVoice => '語音記帳';

  @override
  String get shortcutVoiceDesc => '透過語音快速記錄帳單';

  @override
  String get shortcutImage => '圖片記帳';

  @override
  String get shortcutImageDesc => '從相簿選擇圖片識別帳單';

  @override
  String get shortcutCamera => '拍照記帳';

  @override
  String get shortcutCameraDesc => '拍照識別帳單';

  @override
  String get shortcutNewExpense => '快捷記支出';

  @override
  String get shortcutNewExpenseDesc => '直接打開支出記帳頁面';

  @override
  String get shortcutNewIncome => '快捷記收入';

  @override
  String get shortcutNewIncomeDesc => '直接打開收入記帳頁面';

  @override
  String get shortcutNewTransfer => '快捷記轉帳';

  @override
  String get shortcutNewTransferDesc => '直接打開轉帳記帳頁面';

  @override
  String get shortcutUrlCopied => '連結已複製到剪貼簿';

  @override
  String get howToAddShortcut => '如何新增快捷指令';

  @override
  String get iosShortcutStep1 => '開啟「捷徑」App';

  @override
  String get iosShortcutStep2 => '點擊右上角「+」新建捷徑';

  @override
  String get iosShortcutStep3 => '加入「開啟 URL」動作';

  @override
  String get iosShortcutStep4 => '貼上上方複製的連結（如 piggycount://voice）';

  @override
  String get iosShortcutStep5 => '儲存後，可加入桌面使用';

  @override
  String get androidShortcutStep1 => '下載支援建立捷徑的應用程式（如 Shortcut Maker）';

  @override
  String get androidShortcutStep2 => '選擇「URL 捷徑」';

  @override
  String get androidShortcutStep3 => '貼上上方複製的連結（如 piggycount://voice）';

  @override
  String get androidShortcutStep4 => '設定圖示和名稱後加入桌面';

  @override
  String get shortcutsTip => '小提示';

  @override
  String get shortcutsTipDesc => '快捷指令需要搭配 AI 功能使用。請確保已開啟智慧識別並設定好 API Key。';

  @override
  String get shortcutOpenShortcutsApp => '開啟捷徑 App';

  @override
  String get shortcutAutoAdd => '自動記帳介面';

  @override
  String get shortcutAutoAddDesc => '透過 URL 參數自動建立帳單，適合與快捷指令、自動化工具配合使用。';

  @override
  String get shortcutAutoAddExample => '範例連結：';

  @override
  String get shortcutAutoAddParams => '支援的參數：';

  @override
  String get shortcutParamAmount => '金額（必填）';

  @override
  String get shortcutParamType => '類型：expense（支出）/ income（收入）/ transfer（轉帳）';

  @override
  String get shortcutParamCategory => '分類名稱（需與App中已有分類相符）';

  @override
  String get shortcutParamNote => '備註';

  @override
  String get shortcutParamAccount => '帳戶名稱（需與App中已有帳戶相符）';

  @override
  String get shortcutParamTags => '標籤（多個用逗號分隔）';

  @override
  String get shortcutParamDate => '日期（ISO格式，如 2024-01-15）';

  @override
  String get quickActionImage => '圖片記帳';

  @override
  String get quickActionCamera => '拍照記帳';

  @override
  String get quickActionVoice => '語音記帳';

  @override
  String get quickActionAiChat => 'AI 小助手';

  @override
  String get calendarTitle => '日曆';

  @override
  String get calendarToday => '今天';

  @override
  String get calendarNoTransactions => '當天無交易';

  @override
  String get calendarAddTransaction => '在該日記帳';

  @override
  String get commonUncategorized => '未分類';

  @override
  String get commonSaved => '已儲存';

  @override
  String get aiProviderManageTitle => '服務商管理';

  @override
  String get aiProviderManageSubtitle => '管理AI服務商設定';

  @override
  String get aiProviderAdd => '新增服務商';

  @override
  String get aiProviderBuiltIn => '內建';

  @override
  String get aiProviderEmpty => '暫無服務商設定';

  @override
  String get aiProviderNoApiKey => '未設定 API Key';

  @override
  String get aiProviderTapToEdit => '點擊編輯';

  @override
  String get aiProviderDeleteTitle => '刪除服務商';

  @override
  String aiProviderDeleteConfirm(String name) {
    return '確定刪除服務商「$name」嗎？使用該服務商的能力將自動切換到預設服務商。';
  }

  @override
  String get aiProviderDeleted => '服務商已刪除';

  @override
  String get aiProviderEditTitle => '編輯服務商';

  @override
  String get aiProviderAddTitle => '新增服務商';

  @override
  String get aiProviderBasicInfo => '基本資訊';

  @override
  String get aiProviderName => '服務商名稱';

  @override
  String get aiProviderNameHint => '如：矽基流動、DeepSeek';

  @override
  String get aiProviderNameRequired => '請輸入服務商名稱';

  @override
  String get aiProviderBaseUrlRequired => '請輸入 Base URL';

  @override
  String get aiProviderModels => '模型設定';

  @override
  String get aiProviderModelsHint => '留空的能力將無法使用該服務商';

  @override
  String get aiCapabilityText => '文字';

  @override
  String get aiCapabilityVision => '視覺';

  @override
  String get aiCapabilitySpeech => '語音';

  @override
  String get aiCapabilitySelectTitle => '能力綁定';

  @override
  String get aiCapabilitySelectSubtitle => '為每個AI能力選擇服務商';

  @override
  String get aiCapabilityTextChat => '文字對話';

  @override
  String get aiCapabilityTextChatDesc => '用於AI對話和文字帳單提取';

  @override
  String get aiCapabilityImageUnderstand => '圖片理解';

  @override
  String get aiCapabilityImageUnderstandDesc => '用於圖片帳單識別';

  @override
  String get aiCapabilitySpeechToText => '語音轉文字';

  @override
  String get aiCapabilitySpeechToTextDesc => '用於語音記帳';

  @override
  String get aiProviderTestRunning => '測試中...';

  @override
  String get aiProviderTestSuccess => '測試通過';

  @override
  String get aiProviderTestFailed => '測試失敗';

  @override
  String get aiProviderTestAll => '一鍵測試全部';

  @override
  String get aiProviderTestAllRetry => '重新測試';

  @override
  String get aiModelInputHelper => '留空則使用預設模型';

  @override
  String get syncPreviewTitle => '同步預覽';

  @override
  String get syncPreviewSelectAll => '全選';

  @override
  String get syncPreviewDeselectAll => '取消全選';

  @override
  String get syncPreviewAdded => '新增';

  @override
  String get syncPreviewModified => '修改';

  @override
  String get syncPreviewDeleted => '刪除';

  @override
  String syncPreviewAddedCount(int count) {
    return '新增 $count 條';
  }

  @override
  String syncPreviewModifiedCount(int count) {
    return '修改 $count 條';
  }

  @override
  String syncPreviewDeletedCount(int count) {
    return '刪除 $count 條';
  }

  @override
  String syncPreviewApply(int count) {
    return '套用 $count 項';
  }

  @override
  String get syncPreviewOldFormat => '雲端資料格式較舊，將執行全量替換';

  @override
  String get syncPreviewOldFormatMessage =>
      '雲端資料不包含同步標識，無法逐條對比。將清空當前帳本資料並從雲端重新匯入。';

  @override
  String syncPreviewApplied(int count) {
    return '已套用 $count 項變更';
  }

  @override
  String get cloudSyncGuideTitle => '雲端同步使用指南';

  @override
  String get cloudSyncGuideGotIt => '我知道了';

  @override
  String get cloudSyncGuideHowItWorks => '運作原理';

  @override
  String get cloudSyncGuideHowItem1 => '上傳：將當前帳本的全部資料打包上傳至雲端，覆蓋雲端舊資料';

  @override
  String get cloudSyncGuideHowItem2 => '下載：從雲端拉取資料，與本機逐條比對差異，您可以選擇要同步哪些變更';

  @override
  String get cloudSyncGuideHowItem3 => '雲端始終只儲存最後一次上傳的完整快照，不保留歷史版本';

  @override
  String get cloudSyncGuideCorrect => '正確的使用方式';

  @override
  String get cloudSyncGuideCorrectItem1 => '同一時間只在一台裝置上記帳，完成後上傳';

  @override
  String get cloudSyncGuideCorrectItem2 => '切換裝置前，先在新裝置上下載同步';

  @override
  String get cloudSyncGuideCorrectItem3 => '下載時仔細查看預覽，確認每條變更再套用';

  @override
  String get cloudSyncGuideCorrectItem4 => '養成「編輯→上傳→切換裝置→下載→編輯」的習慣';

  @override
  String get cloudSyncGuideWrong => '應避免的用法';

  @override
  String get cloudSyncGuideWrongItem1 => '兩台裝置同時編輯同一帳本，後上傳的會覆蓋先上傳的改動';

  @override
  String get cloudSyncGuideWrongItem2 =>
      '上傳後立刻在另一台裝置下載，檔案服務可能有數秒到數分鐘的同步延遲，請稍候再試';

  @override
  String get cloudSyncGuideWrongItem3 => '長時間不同步後一次性下載大量變更，容易遺漏需要處理的差異';

  @override
  String get cloudSyncGuideLimitations => '已知限制';

  @override
  String get cloudSyncGuideLimitItem1 => '非即時同步：需手動點擊上傳和下載';

  @override
  String get cloudSyncGuideLimitItem2 => '無衝突合併：不會自動合併兩端的修改，以最後上傳的為準';

  @override
  String get cloudSyncGuideLimitItem3 =>
      '檔案服務延遲：上傳後雲端檔案可能需要數秒到數分鐘才能被其他裝置讀取，取決於您使用的雲端服務';

  @override
  String get cloudSyncGuideLimitItem4 => '不含附件：交易的圖片附件不參與同步，需透過資料管理單獨匯出';

  @override
  String get appLockTitle => '應用鎖';

  @override
  String get appLockDesc => 'PIN碼與生物辨識保護隱私';

  @override
  String get appLockEnable => '啟用應用鎖';

  @override
  String get appLockEnableDesc => '啟動和切回應用時需要驗證身份';

  @override
  String get appLockSetPin => '設定密碼';

  @override
  String get appLockChangePin => '修改密碼';

  @override
  String get appLockVerifyPin => '驗證密碼';

  @override
  String get appLockVerifyCurrentPin => '請輸入當前密碼';

  @override
  String get appLockSetNewPin => '請設定新密碼';

  @override
  String get appLockConfirmPin => '請再次輸入密碼';

  @override
  String get appLockEnterPin => '請輸入密碼';

  @override
  String get appLockPinSetSuccess => '密碼設定成功';

  @override
  String get appLockDisabled => '應用鎖已關閉';

  @override
  String get appLockBiometric => '生物辨識解鎖';

  @override
  String get appLockBiometricDesc => '使用Face ID或指紋快速解鎖';

  @override
  String get appLockBiometricReason => '請驗證身份以解鎖小豬記帳';

  @override
  String get appLockTimeout => '自動鎖定時間';

  @override
  String get appLockTimeoutImmediate => '立即';

  @override
  String get appLockTimeout1Min => '1分鐘後';

  @override
  String get appLockTimeout5Min => '5分鐘後';

  @override
  String get appLockTimeout15Min => '15分鐘後';

  @override
  String get creditCardSettings => '信用卡設定';

  @override
  String get accountTabValuation => '估值帳戶';

  @override
  String get creditCardDaysRequired => '請選擇帳單日和還款日';

  @override
  String get creditLimit => '信用額度';

  @override
  String get creditLimitHint => '請輸入信用額度';

  @override
  String get billingDay => '帳單日';

  @override
  String get paymentDueDay => '還款日';

  @override
  String get creditUsed => '已用額度';

  @override
  String get creditAvailable => '可用額度';

  @override
  String get creditCardOwed => '待還款';

  @override
  String dayOfMonth(int day) {
    return '每月$day日';
  }

  @override
  String get creditCardReminderTitle => '還款提醒';

  @override
  String get creditCardReminderDesc => '在還款日前提醒還款';

  @override
  String creditCardReminderDaysBefore(int days) {
    return '提前$days天提醒';
  }

  @override
  String get creditCardInitialBalanceHint => '目前欠款（填負數）';

  @override
  String get selectDay => '選擇日期';

  @override
  String get accountBankName => '開戶行';

  @override
  String get accountBankNameHint => '例如：工商銀行';

  @override
  String get accountCardLastFour => '卡號後四位';

  @override
  String get accountCardLastFourHint => '例如：1234';

  @override
  String get accountNote => '備註';

  @override
  String get accountNoteHint => '新增備註資訊';

  @override
  String get accountMetaInfo => '帳戶資訊';

  @override
  String get accountBalanceTrend => '餘額趨勢';

  @override
  String get accountCategoryBreakdown => '分類統計';

  @override
  String get accountCategoryExpense => '支出';

  @override
  String get accountCategoryIncome => '收入';

  @override
  String get accountNoMoreData => '沒有更多資料了';

  @override
  String get totalAssets => '總資產';

  @override
  String get totalLiabilities => '總負債';

  @override
  String get assetAccounts => '資產帳戶';

  @override
  String get liabilityAccounts => '負債帳戶';

  @override
  String get assetComposition => '資產構成';

  @override
  String get accountTypeInvestment => '投資理財';

  @override
  String get accountTypeLoan => '貸款';

  @override
  String get accountTypeReceivable => '應收款';

  @override
  String get accountTypeRealEstate => '不動產';

  @override
  String get accountTypeVehicle => '車輛';

  @override
  String get accountTypeInsurance => '保險';

  @override
  String get accountTypeSocialFund => '公積金/社保';

  @override
  String get valuationCurrentValue => '當前估值';

  @override
  String get valuationCurrentDebt => '當前欠款';

  @override
  String get valuationUpdateValue => '更新估值';

  @override
  String get valuationUpdateDebt => '更新欠款';

  @override
  String valuationLastUpdated(String date) {
    return '上次更新: $date';
  }

  @override
  String get valuationAccountHint => '請輸入當前估值';

  @override
  String get valuationDebtHint => '請輸入當前欠款金額';

  @override
  String get accountGroupTradable => '日常帳戶';

  @override
  String get adjustmentTransaction => '估值調整';

  @override
  String creditCardBillingInfo(int billingDay, int paymentDueDay) {
    return '每月$billingDay日出帳 · $paymentDueDay日還款';
  }

  @override
  String creditCardDaysUntilPayment(int days) {
    return '距還款日還有$days天';
  }

  @override
  String get creditCardPaymentDueToday => '今天是還款日';

  @override
  String get creditCardQuickRepay => '記一筆還款';

  @override
  String get budgetManagement => '預算管理';

  @override
  String get budgetSetupHint => '設置預算，輕鬆掌控每月開支';

  @override
  String get budgetSetupAction => '去設置';

  @override
  String get maintenanceOrphanCleanupTitle => '資料清理';

  @override
  String get maintenanceOrphanCleanupSubtitle => '檢查並清理本地孤兒資料';

  @override
  String get maintenanceOrphanRescan => '重新掃描';

  @override
  String get maintenanceOrphanEmpty => '本地資料乾淨,未發現孤兒資料';

  @override
  String get maintenanceOrphanGroupDb => '資料庫孤兒';

  @override
  String get maintenanceOrphanGroupFile => '磁碟檔案孤兒';

  @override
  String get maintenanceOrphanGroupSync => '同步狀態孤兒';

  @override
  String maintenanceOrphanSummary(int count) {
    return '發現 $count 項異常';
  }

  @override
  String maintenanceOrphanSummarySize(String size) {
    return '可釋放空間約 $size';
  }

  @override
  String get maintenanceOrphanSelectAll => '全選';

  @override
  String get maintenanceOrphanDeselectAll => '取消全選';

  @override
  String get maintenanceOrphanDeleteOne => '刪除此項';

  @override
  String maintenanceOrphanSelectedHint(int count) {
    return '已選 $count 項';
  }

  @override
  String get maintenanceOrphanCleanSelected => '清理已選';

  @override
  String get maintenanceOrphanConfirmTitle => '確認清理';

  @override
  String maintenanceOrphanConfirmDeleteOne(String title) {
    return '確定清理「$title」嗎？操作不可撤銷。';
  }

  @override
  String maintenanceOrphanConfirmDeleteBatch(int count) {
    return '確定清理選中的 $count 項嗎？操作不可撤銷。';
  }

  @override
  String get maintenanceOrphanReconfirmMessage =>
      '再次確認：清理後這些資料將被永久刪除、無法找回。確定要繼續嗎？';

  @override
  String maintenanceOrphanCleanSuccess(int count) {
    return '已清理 $count 項';
  }

  @override
  String maintenanceOrphanCleanPartial(int ok, int fail) {
    return '成功 $ok 項,失敗 $fail 項';
  }

  @override
  String get exchangeRatePageTitle => '匯率管理';

  @override
  String get exchangeRateEntrySubtitle => '自動取得匯率，支援手動修正';

  @override
  String get baseCurrencyLabel => '主幣種';

  @override
  String get rateSourceAuto => '自動';

  @override
  String get rateSourceManual => '手動';

  @override
  String rateUpdatedAt(String date) {
    return '$date 更新';
  }

  @override
  String get rateNotFetched => '未取得';

  @override
  String get rateTapToSet => '點擊手動設定';

  @override
  String get rateEditTitle => '編輯匯率';

  @override
  String rateInverseHint(String base, String rate, String quote) {
    return '反向參考:1 $base ≈ $rate $quote';
  }

  @override
  String get rateResetToAuto => '恢復自動';

  @override
  String get rateRefreshSuccess => '匯率已更新';

  @override
  String get rateRefreshFailed => '取得失敗,可手動設定匯率';

  @override
  String get ratesEmptyHint => '給帳戶設定不同幣種後,這裡會出現可管理的匯率';

  @override
  String get rateDisclaimer => '資料來源:開源匯率資料,每日更新;折算僅供參考,可能與銀行實際牌價有差異。';

  @override
  String convertedNetWorth(String currency) {
    return '淨資產(折$currency)';
  }

  @override
  String convertedFootnote(String date) {
    return '按 $date 匯率折算,點擊管理匯率';
  }

  @override
  String convertedPartialWarning(String currencies) {
    return '$currencies 未折算,點擊設定匯率';
  }

  @override
  String get unconvertedBadge => '未折算';

  @override
  String get commonDetail => '詳情';

  @override
  String get conversionDetailTitle => '折算詳情';

  @override
  String rateManualApplied(int count) {
    return '已套用 $count 條手動匯率';
  }

  @override
  String get netWorthTrendTitle => '淨值趨勢';

  @override
  String get netWorthTrend3M => '3個月';

  @override
  String get netWorthTrend6M => '6個月';

  @override
  String get netWorthTrend12M => '12個月';

  @override
  String get netWorthTrendAll => '全部';

  @override
  String get netWorthTrendLineNet => '淨資產';

  @override
  String get netWorthTrendLineAssets => '總資產';

  @override
  String get netWorthTrendLineLiabilities => '總負債';

  @override
  String get netWorthTrendMultiCurrencyNote => '歷史淨值為各幣種原值相加,未折算';

  @override
  String get txFlagExcludeFromStats => '不計入收支';

  @override
  String get txFlagExcludeFromBudget => '不計入預算';

  @override
  String get txFlagDialogTitle => '帳單標記';

  @override
  String get txFlagExcludeFromStatsHint => '不計入收支統計,但仍計入帳戶餘額';

  @override
  String get txFlagExcludeFromBudgetHint => '不佔用預算額度';

  @override
  String get txFlagExcludedTag => '不計收支';

  @override
  String get txFlagBudgetExcludedTag => '不計預算';

  @override
  String get txCurrencyLabel => '幣種';

  @override
  String get txRateLabel => '匯率';

  @override
  String txConvertedPreview(Object amount, Object currency) {
    return '≈ $amount $currency';
  }

  @override
  String get txRateMissingHint => '請手動填寫本筆匯率後儲存';

  @override
  String get txOriginalAmountLabel => '原始金額（選填）';

  @override
  String get txOriginalAmountHint => '留空則按記帳金額';

  @override
  String get txOriginalAmountPrefix => '原';

  @override
  String get amountDeviationTitle => '金額偏差分析';

  @override
  String get amountDeviationMetricLabel => '金額口徑';

  @override
  String get amountDeviationMetricCurrency => '原幣金額';

  @override
  String get amountDeviationMetricNative => '本位幣折算';

  @override
  String get amountDeviationBasisLabel => '差異基準';

  @override
  String get amountDeviationBasisRecorded => '記帳金額';

  @override
  String get amountDeviationBasisOriginal => '原始金額';

  @override
  String get amountDeviationEntrySubtitle => '原始金額與記帳金額的差異彙總與洞察';

  @override
  String get amountDeviationTotalLabel => '明細總數';

  @override
  String get amountDeviationDeviatedLabel => '有偏差明細';

  @override
  String get amountDeviationDiffSumLabel => '差異合計';

  @override
  String get amountDeviationMaxDiffLabel => '最大偏差';

  @override
  String get amountDeviationTrendTitle => '差異趨勢';

  @override
  String get amountDeviationCategoryTitle => '分類偏差排行';

  @override
  String get amountDeviationInsightTitle => '偏差洞察';

  @override
  String get amountDeviationSeveritySlight => '輕微';

  @override
  String get amountDeviationSeverityNotable => '明顯';

  @override
  String get amountDeviationSeveritySevere => '嚴重';

  @override
  String get amountDeviationReasonAbove => '原始金額高於記帳金額，疑似未記錄優惠或折扣';

  @override
  String get amountDeviationReasonBelow => '原始金額低於記帳金額，疑似追加費用或事後補錄';

  @override
  String get amountDeviationReasonMultiple => '差值接近記帳金額的整數倍，疑似單位或幣種換算誤差';

  @override
  String get amountDeviationReasonCategoryHabit =>
      '該分類多筆明細出現同向偏差，疑似錄入慣例存在系統性偏差';

  @override
  String get amountDeviationEmptySubtext => '記帳時填寫「原始金額」後，這裡會顯示偏差與原因';

  @override
  String get amountDeviationBottomFillHint => '未填寫的原始金額按記帳金額儲存，不產生差異';

  @override
  String get amountDeviationNoDiff => '該區間沒有偏差';

  @override
  String get ledgerBaseCurrencyLabel => '主幣種';

  @override
  String statsConvertedFootnote(Object currency) {
    return '含外幣,已按各筆記帳時匯率折算為 $currency';
  }

  @override
  String get ledgerCurrencyChangeRecalcHint => '修改本位幣將按當前匯率重算全部歷史交易的折算值';

  @override
  String get recalcForeignTxBanner => '偵測到該帳本有未折算的外幣交易';

  @override
  String get recalcForeignTxAction => '按當前匯率重算折算';

  @override
  String recalcForeignTxDone(Object count) {
    return '已重算 $count 筆外幣交易的折算值';
  }

  @override
  String get txCurrencyPickerTitle => '選擇幣種';

  @override
  String recalcSyncCountHint(Object count) {
    return '將重算並同步 $count 筆交易';
  }

  @override
  String get exportCsvHeaderCurrency => '幣種';

  @override
  String get importFieldCurrency => '幣種';

  @override
  String get currencyMOP => '澳門元';

  @override
  String get currencyMNT => '蒙古圖格里克';

  @override
  String get currencyKPW => '朝鲜元';

  @override
  String get currencyKHR => '柬埔寨瑞爾';

  @override
  String get currencyLAK => '老撾基普';

  @override
  String get currencyBND => '文萊元';

  @override
  String get currencyNPR => '尼泊爾盧比';

  @override
  String get currencyBTN => '不丹努爾特魯姆';

  @override
  String get currencyMVR => '马爾代夫拉菲亞';

  @override
  String get currencyAFN => '阿富汗尼';

  @override
  String get currencyUZS => '烏茲別克斯坦索姆';

  @override
  String get currencyTJS => '塔吉克斯坦索莫尼';

  @override
  String get currencyTMT => '土庫曼斯坦马納特';

  @override
  String get currencyKGS => '吉爾吉斯斯坦索姆';

  @override
  String get currencyQAR => '卡塔爾里亞爾';

  @override
  String get currencyKWD => '科威特第納爾';

  @override
  String get currencyBHD => '巴林第納爾';

  @override
  String get currencyOMR => '阿曼里亞爾';

  @override
  String get currencyJOD => '约旦第納爾';

  @override
  String get currencyLBP => '黎巴嫩鎊';

  @override
  String get currencyIQD => '伊拉克第納爾';

  @override
  String get currencyIRR => '伊朗里亞爾';

  @override
  String get currencyYER => '也門里亞爾';

  @override
  String get currencySYP => '敘利亞鎊';

  @override
  String get currencyGEL => '格魯吉亞拉里';

  @override
  String get currencyAMD => '亞美尼亞德拉姆';

  @override
  String get currencyAZN => '阿塞拜疆马納特';

  @override
  String get currencyRON => '羅马尼亞列伊';

  @override
  String get currencyBGN => '保加利亞列弗';

  @override
  String get currencyRSD => '塞爾維亞第納爾';

  @override
  String get currencyISK => '冰岛克朗';

  @override
  String get currencyMDL => '摩爾多瓦列伊';

  @override
  String get currencyALL => '阿爾巴尼亞列克';

  @override
  String get currencyMKD => '北马其顿第納爾';

  @override
  String get currencyBAM => '波黑可兑換马克';

  @override
  String get currencyGIP => '直布羅陀鎊';

  @override
  String get currencyGTQ => '危地马拉格查爾';

  @override
  String get currencyHNL => '洪都拉斯伦皮拉';

  @override
  String get currencyNIO => '尼加拉瓜科多巴';

  @override
  String get currencyCRC => '哥斯達黎加科朗';

  @override
  String get currencyPAB => '巴拿马巴波亞';

  @override
  String get currencyDOP => '多米尼加比索';

  @override
  String get currencyCUP => '古巴比索';

  @override
  String get currencyJMD => '牙買加元';

  @override
  String get currencyTTD => '特立尼達和多巴哥元';

  @override
  String get currencyBSD => '巴哈马元';

  @override
  String get currencyBBD => '巴巴多斯元';

  @override
  String get currencyBZD => '伯利茲元';

  @override
  String get currencyHTG => '海地古德';

  @override
  String get currencyXCD => '东加勒比元';

  @override
  String get currencyKYD => '开曼群岛元';

  @override
  String get currencyAWG => '阿魯巴弗羅林';

  @override
  String get currencyANG => '荷屬安的列斯盾';

  @override
  String get currencyBMD => '百慕大元';

  @override
  String get currencyUYU => '烏拉圭比索';

  @override
  String get currencyPYG => '巴拉圭瓜拉尼';

  @override
  String get currencyBOB => '玻利維亞诺';

  @override
  String get currencyVES => '委內瑞拉玻利瓦爾';

  @override
  String get currencyGYD => '圭亞那元';

  @override
  String get currencySRD => '蘇里南元';

  @override
  String get currencyFJD => '斐濟元';

  @override
  String get currencyPGK => '巴布亞新幾內亞基那';

  @override
  String get currencySBD => '所羅門群岛元';

  @override
  String get currencyTOP => '湯加潘加';

  @override
  String get currencyVUV => '瓦努阿圖瓦圖';

  @override
  String get currencyWST => '薩摩亞塔拉';

  @override
  String get currencyXPF => '太平洋法郎';

  @override
  String get currencyKES => '肯尼亞先令';

  @override
  String get currencyGHS => '加納塞地';

  @override
  String get currencyMAD => '摩洛哥迪拉姆';

  @override
  String get currencyDZD => '阿爾及利亞第納爾';

  @override
  String get currencyTND => '突尼斯第納爾';

  @override
  String get currencyLYD => '利比亞第納爾';

  @override
  String get currencyETB => '埃塞俄比亞比爾';

  @override
  String get currencyUGX => '烏干達先令';

  @override
  String get currencyTZS => '坦桑尼亞先令';

  @override
  String get currencyRWF => '盧旺達法郎';

  @override
  String get currencyXAF => '中非法郎';

  @override
  String get currencyXOF => '西非法郎';

  @override
  String get currencyMUR => '毛里求斯盧比';

  @override
  String get currencyBWP => '博茨瓦納普拉';

  @override
  String get currencyNAD => '納米比亞元';

  @override
  String get currencyZMW => '贊比亞克瓦查';

  @override
  String get currencyMWK => '马拉維克瓦查';

  @override
  String get currencyMZN => '莫桑比克梅蒂卡爾';

  @override
  String get currencyAOA => '安哥拉宽扎';

  @override
  String get currencyCDF => '剛果法郎';

  @override
  String get currencyGMD => '岡比亞達拉西';

  @override
  String get currencyGNF => '幾內亞法郎';

  @override
  String get currencyLRD => '利比里亞元';

  @override
  String get currencySLE => '塞拉利昂利昂';

  @override
  String get currencySDG => '蘇丹鎊';

  @override
  String get currencySSP => '南蘇丹鎊';

  @override
  String get currencySOS => '索马里先令';

  @override
  String get currencyDJF => '吉布提法郎';

  @override
  String get currencyERN => '厄立特里亞納克法';

  @override
  String get currencyBIF => '布隆迪法郎';

  @override
  String get currencyCVE => '佛得角埃斯庫多';

  @override
  String get currencySTN => '聖多美多布拉';

  @override
  String get currencySCR => '塞舌爾盧比';

  @override
  String get currencyKMF => '科摩羅法郎';

  @override
  String get currencyLSL => '萊索托洛蒂';

  @override
  String get currencySZL => '斯威士蘭里蘭吉尼';

  @override
  String get currencyMGA => '马達加斯加阿里亞里';

  @override
  String get currencyMRU => '毛里塔尼亞烏吉亞';

  @override
  String get cloudSyncEncryptTitle => '同步加密';

  @override
  String get cloudSyncEncryptSubtitle => '用密碼加密雲端備份，保護帳本隱私';

  @override
  String get cloudSyncEncryptEnabled => '已開啟';

  @override
  String get cloudSyncEncryptDisabled => '未開啟';

  @override
  String get cloudSyncEncryptSettings => '加密設定';

  @override
  String get cloudSyncEncryptSetPassword => '設定密碼';

  @override
  String get cloudSyncEncryptChangePassword => '修改密碼';

  @override
  String get cloudSyncEncryptResetEncryption => '重置加密';

  @override
  String get cloudSyncEncryptPasswordLabel => '密碼';

  @override
  String get cloudSyncEncryptConfirmPasswordLabel => '確認密碼';

  @override
  String get cloudSyncEncryptOldPasswordLabel => '舊密碼';

  @override
  String get cloudSyncEncryptNewPasswordLabel => '新密碼';

  @override
  String get cloudSyncEncryptPasswordHint => '至少 8 個字元';

  @override
  String get cloudSyncEncryptPasswordMismatch => '兩次輸入的密碼不一致';

  @override
  String get cloudSyncEncryptPasswordTooShort => '密碼至少 8 個字元';

  @override
  String get cloudSyncEncryptWrongPassword => '密碼錯誤';

  @override
  String get cloudSyncEncryptEnableSuccess => '加密已開啟';

  @override
  String get cloudSyncEncryptChangeSuccess => '密碼已修改';

  @override
  String get cloudSyncEncryptResetConfirmTitle => '重置加密';

  @override
  String get cloudSyncEncryptResetConfirmMessage => '重置將清空雲端所有帳本備份且不可復原，確定繼續嗎？';

  @override
  String get cloudSyncEncryptResetReconfirmMessage =>
      '再次確認：重置後雲端所有帳本備份將永久刪除，無法復原。確定要繼續嗎？';

  @override
  String get cloudSyncEncryptResetSuccess => '加密已重置';

  @override
  String get cloudSyncEncryptDecryptFailed => '解密失敗，請檢查密碼';

  @override
  String get cloudSyncEncryptMultiDeviceHint => '在其他裝置上用相同密碼即可解密';

  @override
  String cloudSyncEncryptReencryptPartialFailed(int count) {
    return '加密已開啟，但有 $count 個雲端檔案重新加密失敗，下次同步時會自動重試。';
  }

  @override
  String get cloudSyncEncryptProbeFailedTitle => '探測雲端失敗';

  @override
  String get cloudSyncEncryptProbeFailedMessage =>
      '無法探測雲端是否已有加密資料（可能是網路或權限問題）。如果其他裝置已開啟加密，繼續將以新密碼重新加密雲端資料，可能導致其他裝置無法解密。確定繼續嗎？';

  @override
  String get cloudSyncEncryptProbeFailedContinue => '以首裝置繼續';

  @override
  String get saltMismatchNeedPasswordHint => '雲端備份金鑰與本地不匹配，點擊重新輸入密碼';

  @override
  String get cloudEncryptedLocallyDisabledHint =>
      '雲端備份為加密密文，但本裝置未開啟加密，點擊開啟加密以恢復資料';

  @override
  String get saltMismatchDialogTitle => '重新輸入密碼';

  @override
  String get saltMismatchRawStorageUnavailable => '雲端服務未初始化，無法恢復金鑰';

  @override
  String get saltMismatchProbeFailed => '雲端探測失敗，請檢查網路後重試';

  @override
  String get saltMismatchCloudCorrupted => '雲端密文已損壞，無法恢復金鑰';

  @override
  String get saltMismatchWebdavAuthTitle => '雲端認證失敗';

  @override
  String get saltMismatchWebdavAuthMessage =>
      '雲端儲存（WebDAV）帳號或密碼錯誤，請前往雲端服務設定修正憑證後重試。';

  @override
  String get saltMismatchGoConfig => '前往修改設定';

  @override
  String get startupSyncRecoveryFailedHint =>
      '密鑰啟用失敗，同步未恢復。請確認密碼後重試，或到同步設定重新操作。';

  @override
  String get backupNowTitle => '立即備份';

  @override
  String get backupNowSubtitle => '將全部賬本與附件打包為一份當日備份，存入 piggycount-bak';

  @override
  String get backupNoLedgers => '沒有可備份的賬本。';

  @override
  String get backupRunningStatus => '正在建立備份…';

  @override
  String backupPackingProgress(int done, int total) {
    return '正在打包賬本 $done/$total…';
  }

  @override
  String backupSuccessMessage(String fileName) {
    return '備份已上傳：piggycount-bak/$fileName';
  }

  @override
  String get backupFailedAuthMessage => '雲端認證失敗，請檢查雲服務設定後重試。';

  @override
  String get backupFailedNetworkMessage => '備份失敗，請檢查網路後重試。';

  @override
  String get restoreFromBackupTitle => '從備份還原';

  @override
  String get restoreFromBackupSubtitle => '用選定的每日備份覆蓋本機資料（全部賬本與附件）';

  @override
  String get backupListDialogTitle => '正在讀取備份列表…';

  @override
  String get backupListEmptyMessage => '雲端還沒有備份。';

  @override
  String restoreConfirm1Message(String date) {
    return '將使用 $date 的備份覆蓋本機全部賬本資料（帳戶、分類、交易），比備份更新的本機變更將遺失。';
  }

  @override
  String get restoreConfirm2Message => '此操作無法復原，確定要繼續嗎？';

  @override
  String get restoreRunningStatus => '正在從備份還原…';

  @override
  String restoreLedgerProgress(int done, int total) {
    return '正在還原賬本 $done/$total…';
  }

  @override
  String restoreResultMessage(int success, int failed) {
    return '還原完成：成功 $success 個，失敗 $failed 個。';
  }

  @override
  String restoreSkippedRecurringHint(int count) {
    return '注意：還原時有 $count 筆同日週期實例被判重跳過（同規則同日且 syncId 或金額+備註相同），如源端存在同日多筆交易請核對明細。';
  }

  @override
  String get backupAutoTitle => '定時備份';

  @override
  String get backupAutoSubtitle => '每日在設定時間自動備份一次（僅 App 執行期間生效）';

  @override
  String get backupTimeTitle => '每日備份時間';

  @override
  String lastBackupCaption(String date, String ok) {
    return '最近備份：$date · $ok';
  }

  @override
  String get lastBackupNone => '最近備份：尚無記錄';

  @override
  String get ledgersCreatedSuccess => '帳本建立成功';

  @override
  String ledgersCreateFailed(String error) {
    return '建立失敗: $error';
  }

  @override
  String get budgetOnlyOwnerCanEdit => '只有帳本所有者能編輯預算';

  @override
  String get transferSelectFromAccount => '請選擇轉出帳戶';

  @override
  String get transferSelectToAccount => '請選擇轉入帳戶';

  @override
  String get commonNoMessages => '暫無訊息';

  @override
  String commonLoadFailed(String error) {
    return '載入失敗: $error';
  }

  @override
  String get commonNoMatches => '無符合項目';

  @override
  String attachmentCustomIcons(int count) {
    return '自訂圖示 ($count)';
  }

  @override
  String get annualReportInsightTitle => '年度洞察';

  @override
  String get annualReportInsightSubtitle => '從資料中發現你的消費習慣';

  @override
  String get annualReportAvgPerTxTitle => '平均每筆消費';

  @override
  String get annualReportAvgPerTxDesc => '你每次記帳的平均金額';

  @override
  String get annualReportAvgDailyTitle => '日均支出';

  @override
  String get annualReportAvgDailyDesc => '平均每天花費金額';

  @override
  String get annualReportAvgMonthlyTitle => '月均支出';

  @override
  String get annualReportAvgMonthlyDesc => '平均每月花費金額';

  @override
  String get annualReportActiveMonthTitle => '最活躍月份';

  @override
  String get annualReportActiveMonthDesc => '記帳活動最頻繁的月份';

  @override
  String get annualReportCategoryCountTitle => '消費分類數';

  @override
  String get annualReportCategoryCountDesc => '你使用過的消費分類數量';

  @override
  String get annualReportSavingsRateTitle => '儲蓄率';

  @override
  String get annualReportSavingsRateDescPos => '今年你存下了收入的這個比例';

  @override
  String get annualReportSavingsRateDescNeg => '今年支出超過了收入';

  @override
  String get annualReportCompareTitle => '收支對比';

  @override
  String get annualReportCompareSubtitle => '每月收入與支出的對比';

  @override
  String get annualReportTopIncome => '收入最高';

  @override
  String get annualReportTopExpense => '支出最高';

  @override
  String get annualReportUnitDay => '天';

  @override
  String get annualReportUnitEntries => '筆';

  @override
  String get posterUnitPerDay => '元/天';

  @override
  String get posterUnitPerMonth => '元/月';

  @override
  String annualReportMonthValue(int month) {
    return '$month月';
  }

  @override
  String annualReportCategoryCountValue(int count) {
    return '$count個';
  }

  @override
  String get annualReportPosterSavedPos => '恭喜你存下了';

  @override
  String get annualReportPosterOverspent => '今年花超了';

  @override
  String get annualReportPosterBookkeeping => '記帳堅持';

  @override
  String get annualReportPosterTrend => '月度支出趨勢';

  @override
  String get annualReportPosterAchieved => '已達成';

  @override
  String get annualReportPosterNotAchieved => '未達成';

  @override
  String get annualReportPosterQrCta => '掃碼下載小豬記帳，開啟你的記帳之旅';

  @override
  String annualReportConsecutiveDaysValue(int count) {
    return '$count天';
  }

  @override
  String aiBillingRateMissingHint(String currency) {
    return '⚠️ 未取得 $currency 匯率，已按 1:1 暫記，可在統計頁「補折算」修正';
  }

  @override
  String get aiPromptVarCurrencies => '帳本主幣種 + 已在用的外幣帳戶';

  @override
  String get aiPromptVarBillGuard => '帳單過濾段（僅截圖 / 自動記帳時注入）';

  @override
  String aiPromptMissingVarsHint(String vars) {
    return '你的自訂模板缺少這些變數，對應能力會失效：$vars';
  }

  @override
  String aiPromptInsertVarSection(String name) {
    return '插入 $name 段落';
  }

  @override
  String aiPromptVarSectionInserted(String name) {
    return '已追加 $name 段落，確認後儲存';
  }

  @override
  String get tagSelectOwnerManaged => '共享帳本標籤由所有者管理';

  @override
  String get syncHealthTitle => '同步健康';

  @override
  String get syncHealthEmpty => '近 30 天暫無同步紀錄';

  @override
  String syncHealthRate(String rate) {
    return '近 30 天成功率：$rate';
  }

  @override
  String syncHealthDetail(int success, int failed, int softFail, int conflict) {
    return '成功 $success · 失敗 $failed · 未收斂 $softFail · 並發攔截 $conflict';
  }

  @override
  String get syncHealthTopErrors => '主要失敗類別';

  @override
  String get syncHealthExport => '匯出診斷資料';

  @override
  String syncHealthExported(String fileName) {
    return '診斷資料已匯出：$fileName';
  }

  @override
  String syncHealthExportFailed(String error) {
    return '診斷資料匯出失敗：$error';
  }

  @override
  String get cloudCapabilityTitle => '後端能力';

  @override
  String cloudCapabilityLine(String concurrency, String binary) {
    return '並發保護：$concurrency · 二進位傳輸：$binary';
  }

  @override
  String get cloudCapYes => '原生支援';

  @override
  String get cloudCapApprox => '近似（校驗兜底）';

  @override
  String get cloudCapNo => '降級模式';

  @override
  String get syncErrNotConfigured => '未設定';

  @override
  String get syncErrAuth => '認證失敗';

  @override
  String get syncErrNetworkTimeout => '網路逾時';

  @override
  String get syncErrGateway => '遠端／閘道異常';

  @override
  String get syncErrPrecondition => '並行衝突';

  @override
  String get syncErrDataCorruption => '資料完整性異常';

  @override
  String get syncErrOther => '其他';

  @override
  String get syncErrNotConfiguredMessage =>
      '雲端同步尚未設定。請先到「雲端服務」頁面填寫伺服器位址與憑證，然後再試。';

  @override
  String get syncErrCorruptionMessage =>
      '資料完整性檢查失敗，本機或雲端資料可能已損毀。建議先匯出備份留存，再從雲端快照還原，避免直接覆寫本機資料。';

  @override
  String get syncErrGenericMessage => '同步失敗，請稍後重試。若反覆失敗，可在「日誌中心」匯出診斷資料回報。';

  @override
  String get dbHealthCorruptTitle => '本機資料庫異常';

  @override
  String get dbHealthCorruptBodyCorrupted =>
      '本機資料庫未通過完整性檢查（頁面層級損毀）。為避免進一步損毀，本機讀寫已暫停。建議先匯出損毀檔案留存，再重置本機資料庫並重啟應用程式；重啟後可在「雲端服務」頁用雲端備份還原資料。';

  @override
  String get dbHealthCorruptBodyUnreadable =>
      '無法讀取本機資料庫檔案（可能被其他程式占用，或檔案已非有效的資料庫）。請先徹底關閉並重新開啟應用程式；若仍如此，可匯出檔案留存，再重置本機資料庫並重啟。';

  @override
  String get dbHealthActionExport => '匯出損毀檔案';

  @override
  String get dbHealthActionReset => '重置本機資料庫';

  @override
  String get dbHealthActionLater => '稍後處理';

  @override
  String dbHealthExported(String path) {
    return '已匯出至：$path';
  }

  @override
  String dbHealthExportFailed(String error) {
    return '匯出失敗：$error';
  }

  @override
  String get dbHealthResetConfirmTitle => '重置本機資料庫？';

  @override
  String get dbHealthResetConfirmMessage =>
      '損毀的資料庫檔案會被移到保留目錄（不會刪除），之後需要重啟應用程式以建立空白資料庫。之後可用雲端備份或備份檔案還原資料。';

  @override
  String dbHealthResetDone(String path) {
    return '損毀檔案已保留在：$path\n請完全結束並重新開啟應用程式。';
  }

  @override
  String dbHealthResetFailed(String error) {
    return '重置失敗：$error';
  }

  @override
  String get recycleBin => '回收筒';

  @override
  String get recycleBinSubtitle => '已刪除的交易會留在這裡，直到你徹底刪除';

  @override
  String get recycleBinEmpty => '回收筒是空的';

  @override
  String get recycleBinMoved => '已移入回收筒';

  @override
  String get recycleBinRestored => '已復原';

  @override
  String get recycleBinRestore => '復原';

  @override
  String get recycleBinPurge => '徹底刪除';

  @override
  String get recycleBinPurgeConfirm => '徹底刪除後無法復原，附件檔案也會一併清除，確定嗎？';

  @override
  String get recycleBinPurgeReconfirm => '再次確認：徹底刪除後該交易及其附件將永久消失、無法復原。確定要繼續嗎？';

  @override
  String get recycleBinRestoreConflict => '復原失敗：該位置已被另一筆交易佔用';

  @override
  String get rangeReportTitle => '自訂區間報表';

  @override
  String get rangeReportEntrySubtitle => '任意起止區間，含環比與同比變化，另依標籤維度拆分';

  @override
  String get rangeReportColumnCurrent => '本期';

  @override
  String get rangeReportColumnMom => '環比上期';

  @override
  String get rangeReportColumnYoy => '同比去年同期';

  @override
  String analyticsTagComposition(Object type) {
    return '$type標籤構成';
  }

  @override
  String get rangeReportChangeRange => '更換區間';

  @override
  String get rangeReportCustomFieldTitle => '自訂欄位彙總';

  @override
  String get rangeReportEmptySubtext => '這段時間還沒有記帳，點上方日期換一個區間';

  @override
  String semanticsChartSeries(int count, String points) {
    return '圖表，共 $count 個點：$points';
  }

  @override
  String get holidaySettingsTitle => '行事曆與節假日';

  @override
  String get holidaySettingsDesc => '法定節假日標註與農曆，資料每月自動更新';

  @override
  String get holidayCacheOverview => '快取概覽';

  @override
  String holidayCacheCount(int count, int off, int work) {
    return '共 $count 條（放假 $off · 補班 $work）';
  }

  @override
  String holidayCoverYears(String range) {
    return '覆蓋年份：$range';
  }

  @override
  String holidayLastUpdate(String time) {
    return '上次成功更新：$time';
  }

  @override
  String get holidayNeverUpdated => '從未成功更新';

  @override
  String holidayFailureCount(int count) {
    return '連續失敗 $count 次（舊快取仍可使用）';
  }

  @override
  String get holidayUpdateNow => '立即更新';

  @override
  String get holidayUpdating => '正在更新…';

  @override
  String get holidayUpdateSuccess => '節假日資料已更新';

  @override
  String holidayUpdateFailed(String error) {
    return '更新失敗：$error';
  }

  @override
  String get holidayAutoUpdate => '每月自動更新';

  @override
  String get holidayAutoUpdateDesc => '每月連網更新一次當年節假日，不含任何帳本或裝置資訊';

  @override
  String get holidayBadgeOff => '休';

  @override
  String get holidayBadgeWork => '班';

  @override
  String get holidayLoadFailed => '節假日資料載入失敗';

  @override
  String get holidayFetchByYear => '依年份範圍取得';

  @override
  String get holidayFetchByYearDesc => '選擇起訖年份，連網補寫該範圍節假日';

  @override
  String get holidayUpdateYear => '更新該年';

  @override
  String holidayFetchYearDone(int year) {
    return '$year 年節假日已更新';
  }

  @override
  String holidayYearNoData(int year) {
    return '$year 年暫無節假日資料';
  }

  @override
  String holidayFetchYearFailed(String error) {
    return '取得失敗：$error';
  }

  @override
  String get holidayYearRangeTitle => '選擇年份範圍';

  @override
  String get holidayYearRangeStart => '起始年份';

  @override
  String get holidayYearRangeEnd => '結束年份';

  @override
  String holidayFetchRangeDone(int count) {
    return '已補寫 $count 個年份';
  }

  @override
  String holidayFetchRangeDoneNoData(int updated, int noData) {
    return '已補寫 $updated 個年份，$noData 個年份無資料';
  }

  @override
  String holidayFetchRangePartial(int updated, int count) {
    return '已補寫 $updated 個年份，$count 個年份取得失敗';
  }
}
