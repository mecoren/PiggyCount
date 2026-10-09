import 'package:flutter/material.dart';

/// 更新日志数据模型与内容
///
/// 版本说明属随版本发布的资料性内容（非界面控件文案），直接以中文维护在本文件，
/// 与发版 tag 同步更新；页面标题等界面文案仍走 l10n。
/// 新版本发布时在 [kChangelogVersions] 头部插入新条目，最新版本在前。

/// 一个版本内的功能分组
class ChangelogSection {
  const ChangelogSection({
    required this.icon,
    required this.title,
    required this.items,
  });

  final IconData icon;
  final String title;
  final List<String> items;
}

/// 一个版本的更新信息
class ChangelogVersion {
  const ChangelogVersion({
    required this.version,
    required this.date,
    required this.summary,
    required this.sections,
  });

  final String version;
  final String date;
  final String summary;
  final List<ChangelogSection> sections;

  /// 变更条目总数（列表页副标题用）
  int get itemCount => sections.fold(0, (n, s) => n + s.items.length);
}

/// 全部版本，最新在前
const kChangelogVersions = <ChangelogVersion>[
  ChangelogVersion(
    version: '0.1.2',
    date: '2026-10-10',
    summary: '修复正式包签名不稳定导致的覆盖安装失败，后续版本可正常覆盖升级。',
    sections: [
      ChangelogSection(
        icon: Icons.verified_outlined,
        title: '修复与改进',
        items: [
          '统一正式包签名证书，修复覆盖安装时报「签名不一样」的问题（已装旧版本需卸载后重装一次）',
          '缺少签名配置时打包直接失败，不再产出随机签名的安装包',
          '发版流水线与本地使用同一签名证书，GitHub 发版产物可正常覆盖升级',
        ],
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.1.1',
    date: '2026-10-09',
    summary: '体验打磨与功能增强：记账抽屉更顺手，新增储蓄目标与投资持仓，搜索支持多维筛选。',
    sections: [
      ChangelogSection(
        icon: Icons.edit_note_outlined,
        title: '记账体验',
        items: [
          '记账抽屉键盘钉底，金额行按内容取宽，账户 / 标签合并一行',
          '新建记账不再预填分类，强制明确选择分类',
        ],
      ),
      ChangelogSection(
        icon: Icons.savings_outlined,
        title: '储蓄目标',
        items: [
          '全新增储蓄目标模块：设定目标、记录已存，进度一目了然',
          '总已存按账户去重，同账户多目标不再重复计入',
          '达成 / 超额进度条改用主题色与成功色，语义更清晰',
          '表单改行式字段 + 分段控件，汇总卡分层固定在标题栏下方',
        ],
      ),
      ChangelogSection(
        icon: Icons.trending_up_outlined,
        title: '投资持仓',
        items: [
          '新增投资持仓模块，手动记录持仓与估值，行情接入已预留',
        ],
      ),
      ChangelogSection(
        icon: Icons.notifications_active_outlined,
        title: '提醒与订阅',
        items: [
          '新增订阅视图，周期账单集中查看',
          '周期账单到期提醒与预算超支提醒',
        ],
      ),
      ChangelogSection(
        icon: Icons.search_outlined,
        title: '搜索与筛选',
        items: [
          '多维筛选补齐账户 / 标签 / 附件 / 币种，筛选面板改底部抽屉',
          '搜索页视觉精简：描边式搜索框、去除多层色块',
        ],
      ),
      ChangelogSection(
        icon: Icons.design_services_outlined,
        title: '界面统一',
        items: [
          '存量表单统一为表单抽屉：固定底部按钮行、支持下拉关闭',
          '编辑抽屉删除入口统一，破坏性操作改用危险确认分档',
          '抽出行式字段 / 分段控件公共组件，各表单版式更一致',
        ],
      ),
      ChangelogSection(
        icon: Icons.calendar_month_outlined,
        title: '日历修正',
        items: [
          '农历与节气表按天文历校准，修正多处月长与 57 项节气',
          '修复 1975 年节气数据导致的日历崩溃',
        ],
      ),
      ChangelogSection(
        icon: Icons.speed_outlined,
        title: '内部与稳定性',
        items: [
          '下线共享账本功能，移除相关数据表与代码，数据结构更精简',
          '修复 Android 高版本 SDK 构建目标查找失败的问题',
        ],
      ),
    ],
  ),
  ChangelogVersion(
    version: '0.1.0',
    date: '2026-10-07',
    summary: '首个公开版本：离线优先、隐私可控的个人记账应用正式发布。',
    sections: [
      ChangelogSection(
        icon: Icons.edit_note_outlined,
        title: '记账核心',
        items: [
          '多账本管理，账本间数据独立、互不干扰',
          '多账户体系与实时余额，支持现金 / 银行卡 / 信用卡 / 虚拟账户',
          '二级自定义分类与标签，收支去向一目了然',
          '预算管理，月度预算与超支提醒',
          '周期记账，房租 / 订阅等定期收支自动入账',
          '记账界面优先：点「记一笔」直出金额表单，分类选择下沉为子界面，编辑入口同步统一',
          '快捷记账模式，金额优先、自动记忆上次分类',
          '记账日历，农历 / 节气 / 法定节假日（休 / 班）一屏掌握',
          '回收站，删除的交易可随时找回，并标注「只在本机」的同步范围',
          '退款 / 冲正与报销标记，资金往来更清晰',
          '交易附件，拍照 / 相册选图、自动压缩与裁剪，支持打包导出',
          '自定义字段支持文本 / 数字 / 日期等类型，日期可精确到时分秒',
          '明细新增区间选择器，任意起止日期查看收支',
          '支付宝 / 微信账单一键导入（CSV / Excel）',
        ],
      ),
      ChangelogSection(
        icon: Icons.auto_awesome_outlined,
        title: 'AI 智能记账',
        items: [
          'AI 对话记账，一句自然语言完成记一笔',
          '拍照 OCR 识别票据，自动填好金额与分类',
          '语音记账，动口不动手',
          '截图识别自动记账，支付记录截图直接转交易',
          '智谱 GLM-4 / OpenAI 双引擎可选',
          'AI 上送前本地脱敏，敏感备注可标记，发送前二次确认',
        ],
      ),
      ChangelogSection(
        icon: Icons.shield_outlined,
        title: '安全与隐私',
        items: [
          '离线优先，全部数据存本地，无广告、零追踪',
          '整库加密（SQLCipher）：Android 端数据库整体加密，密钥由系统密钥库保护',
          '端到端加密（AES-256-GCM + Argon2id），密钥永不出设备',
          '应用锁，指纹 / 面容 / PIN 保护隐私',
          'PIN 连续错误自动退避，可选「PIN 错误自动清空数据」，并支持防截屏',
          '网络请求强制 HTTPS，云端凭据存入系统安全存储',
          '备份强制加密，明文备份给出醒目提示',
        ],
      ),
      ChangelogSection(
        icon: Icons.cloud_sync_outlined,
        title: '云同步',
        items: [
          '自备云端同步：Supabase / WebDAV / S3 / iCloud 任选',
          '整账本快照同步，冲突自动检测，合并前可预览确认',
          '合并支持对端已删除的账户 / 分类 / 标签 / 预算 / 周期规则 / 汇率覆盖，删除正确传播',
          '启动检查发现「云端账本数据与本地不同」时提示，不自动合并，交你决定',
          '修复「从备份恢复后再上传」被静默回退成旧云端数据的方向误判',
          '恢复后清理悬挂的未推送变更，同步方向判断更可靠',
          '云端全量自动备份，随时一键恢复',
          '附件导出包修复，导出的附件可正常解压',
          'S3 网关不支持条件请求头时自动降级，兼容更多对象存储',
        ],
      ),
      ChangelogSection(
        icon: Icons.insights_outlined,
        title: '统计与资产',
        items: [
          '多维度收支统计与趋势图表',
          '任意日期区间报表，支持环比 / 同比与标签维度',
          '净资产趋势，财富变化看得见',
          '多币种账户与自动汇率折算',
          '记账海报生成，一键分享',
        ],
      ),
      ChangelogSection(
        icon: Icons.palette_outlined,
        title: '体验与个性化',
        items: [
          '深色模式与主题色自定义',
          '全站弹窗与底部抽屉统一为悬浮卡片外壳，交互层级更一致',
          '记账 / 编辑表单统一为「金额优先」抽屉',
          '记账日历月份视图改版，法定节假日联网更新',
          '子分类、语言等选择改为卡片式弹窗与底部抽屉',
          'Android / iOS 桌面小组件，不打开应用也能记',
          '桌面快捷方式与深链接快速直达',
          '应用内检查更新（OTA）',
          '简体中文 / 繁体中文 / English / 한국어 多语言',
          '无障碍优化：字号收敛到设计令牌，亮色模式对比度提升',
        ],
      ),
      ChangelogSection(
        icon: Icons.speed_outlined,
        title: '性能与稳定性',
        items: [
          '首页数据窗口化加载、归档流式处理，大账本更流畅',
          '账本指针异常时自动回落到真实账本，避免卡在无账本状态',
          'Android 安装包精简，每个 ABI 体积减少约 1.5MB',
          '新增冷启动 / 页面切换 / 帧率基线监测，持续保障流畅度',
          '升级 Flutter 3.47.6 与 Riverpod 3，底层框架更现代、更稳定',
          '依赖全面升级并对齐 Android 构建链（AGP 9 / Gradle 9 / Kotlin 2.4）',
        ],
      ),
    ],
  ),
];
