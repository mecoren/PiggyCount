/// 格式化工具函数
///
/// 包含各种数据格式化的工具函数
library;

import 'package:flutter/material.dart';
import 'currencies.dart';
import '../l10n/app_localizations.dart';

/// 格式化余额显示，支持多语言单位和多币种
///
/// [balance] 金额
/// [currencyCode] 币种代码 (如 'CNY', 'USD')
/// [isChineseLocale] 是否为中文环境，中文显示万单位，其他语言显示k/M单位
///
/// 智能精度规则：
/// - 小于1万：完整显示，不压缩
/// - 1万-10万：保留1-2位小数（智能判断）
/// - 10万以上：保留1-2位小数（智能判断）
/// - 如果小数部分为.0或.00，则不显示小数
String formatBalance(double balance, String currencyCode,
    {bool isChineseLocale = true}) {
  final absBalance = balance.abs();
  final currencySymbol = getCurrencySymbol(currencyCode);
  final sign = balance >= 0 ? currencySymbol : '-$currencySymbol';

  if (isChineseLocale) {
    // 中文环境：使用万作为单位
    if (absBalance < 10000) {
      // 小于1万：完整显示，不压缩
      return '$sign${absBalance.toStringAsFixed(2)}';
    } else {
      final wan = absBalance / 10000;

      // 智能决定小数位数
      String formattedWan;
      if (wan >= 10) {
        // 10万以上：先尝试1位小数，如果舍入误差大则用2位
        final rounded1 = double.parse(wan.toStringAsFixed(1));
        final error = (rounded1 * 10000 - absBalance).abs();

        if (error > 100) {
          // 误差超过100元，使用2位小数
          formattedWan = wan.toStringAsFixed(2);
        } else {
          formattedWan = wan.toStringAsFixed(1);
        }
      } else {
        // 1-10万：先尝试1位小数，如果舍入误差大则用2位
        final rounded1 = double.parse(wan.toStringAsFixed(1));
        final error = (rounded1 * 10000 - absBalance).abs();

        if (error > 50) {
          // 误差超过50元，使用2位小数
          formattedWan = wan.toStringAsFixed(2);
        } else {
          formattedWan = wan.toStringAsFixed(1);
        }
      }

      // 移除末尾的.0或.00
      formattedWan = formattedWan.replaceAll(RegExp(r'\.0+$'), '');

      return '$sign$formattedWan万';
    }
  } else {
    // 其他语言环境：使用k、M作为单位
    if (absBalance >= 1000000) {
      final million = absBalance / 1000000;

      // 智能决定小数位数
      final rounded1 = double.parse(million.toStringAsFixed(1));
      final error = (rounded1 * 1000000 - absBalance).abs();

      String formattedMillion;
      if (error > 1000) {
        formattedMillion = million.toStringAsFixed(2);
      } else {
        formattedMillion = million.toStringAsFixed(1);
      }

      // 移除末尾的.0或.00
      formattedMillion = formattedMillion.replaceAll(RegExp(r'\.0+$'), '');

      return '$sign${formattedMillion}M';
    } else if (absBalance >= 1000) {
      final thousand = absBalance / 1000;

      // 智能决定小数位数
      final rounded1 = double.parse(thousand.toStringAsFixed(1));
      final error = (rounded1 * 1000 - absBalance).abs();

      String formattedThousand;
      if (error > 100) {
        formattedThousand = thousand.toStringAsFixed(2);
      } else {
        formattedThousand = thousand.toStringAsFixed(1);
      }

      // 移除末尾的.0或.00
      formattedThousand = formattedThousand.replaceAll(RegExp(r'\.0+$'), '');

      return '$sign${formattedThousand}k';
    } else {
      return '$sign${absBalance.toStringAsFixed(2)}';
    }
  }
}

/// 图表坐标轴/徽章的大金额紧凑缩写（不带币种符号）。
///
/// - 中文环境：>=1万 → `x.x万`（一位小数，去掉末尾 .0）；<1万 → 千分位整数
/// - 其他语言：>=1e9 → B，>=1e6 → M，>=1e3 → k（一位小数，去尾零）；<1e3 → 整数
///
/// 负数前置 `-`。供折线/柱状图 Y 轴、tooltip、汇总 badge 复用。
String formatCompactAxis(double v, {bool isChinese = true}) {
  final sign = v < 0 ? '-' : '';
  final abs = v.abs();

  String trim(double scaled) {
    var s = scaled.toStringAsFixed(1);
    if (s.endsWith('.0')) s = s.substring(0, s.length - 2);
    return s;
  }

  if (isChinese) {
    if (abs >= 10000) return '$sign${trim(abs / 10000)}万';
    return '$sign${_thousandSeparated(abs.round())}';
  }
  if (abs >= 1e9) return '$sign${trim(abs / 1e9)}B';
  if (abs >= 1e6) return '$sign${trim(abs / 1e6)}M';
  if (abs >= 1e3) return '$sign${trim(abs / 1e3)}k';
  return '$sign${abs.round()}';
}

String _thousandSeparated(int v) {
  final s = v.toString();
  final buffer = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buffer.write(',');
    buffer.write(s[i]);
  }
  return buffer.toString();
}

/// 格式化完整余额显示（带千分号）
///
/// [balance] 金额
/// [currencyCode] 币种代码 (如 'CNY', 'USD')
///
/// 始终显示完整金额，使用千分号分隔
String formatBalanceFull(double balance, String currencyCode) {
  final absBalance = balance.abs();
  final currencySymbol = getCurrencySymbol(currencyCode);
  final sign = balance >= 0 ? currencySymbol : '-$currencySymbol';

  // 格式化为带千分号的字符串
  final parts = absBalance.toStringAsFixed(2).split('.');
  final intPart = parts[0];
  final decPart = parts[1];

  // 添加千分号
  final buffer = StringBuffer();
  for (int i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(intPart[i]);
  }

  return '$sign${buffer.toString()}.$decPart';
}

/// 翻译账本名称
///
/// 如果账本名称是 "Default Ledger"，则返回国际化后的名称
/// 否则返回原始名称
String translateLedgerName(BuildContext context, String ledgerName) {
  final l10n = AppLocalizations.of(context);

  // 处理默认账本名称的多种形式
  if (ledgerName == 'Default Ledger' ||
      ledgerName == '默认账本' ||
      ledgerName == 'デフォルト家計簿' ||
      ledgerName == '기본 가계부' ||
      ledgerName == 'Standard-Kontenbuch' ||
      ledgerName == 'Livre par Défaut' ||
      ledgerName == 'Libro Predeterminado' ||
      ledgerName == '預設帳本') {
    return l10n.ledgersDefaultLedgerName;
  }

  return ledgerName;
}

/// 剥离 [formatBalance] 输出开头的币种符号（负号感知）。
///
/// formatBalance 对负数返回 `-¥15万`（负号拼在币种符之前），
/// 简单的 startsWith(symbol) 判断会漏掉负数场景（审计 U2）。
String stripCurrencySymbolPrefix(String formatted, String symbol) {
  if (symbol.isEmpty) return formatted;
  final isNegative = formatted.startsWith('-');
  final body = (isNegative ? formatted.substring(1) : formatted).trimLeft();
  if (!body.startsWith(symbol)) return formatted;
  return isNegative
      ? '-${body.substring(symbol.length).trimLeft()}'
      : body.substring(symbol.length).trimLeft();
}

/// 云端槽位 key 的展示级短 ID（前 6 位）。
///
/// 账本管理页「云端账本」卡片与各处同名多槽位警示弹窗**必须**走同一
/// 口径（否则用户拿着弹窗里的短 ID 到卡片页对不上号，甄别承诺无法
/// 兑现）。legacy 数字命名文件本身不足 6 位时原样返回。
String formatSlotShortId(String slotKey) =>
    slotKey.length > 6 ? slotKey.substring(0, 6) : slotKey;

/// 云端快照上传时间的展示级格式（yyyy-MM-dd HH:mm，本地时区）。
///
/// 远程账本卡片/警示弹窗共用。null（老文件无 metadata/导出时间键）
/// 显示 '?'，绝不拿发现时刻的本地时钟冒充云端时间。
String formatCloudUploadDate(DateTime? at) {
  if (at == null) return '?';
  final local = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
