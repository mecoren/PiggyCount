// 深链 URL 契约（schema）回归测试 —— 对优化评估报告建议 12
// 「测试补齐」中点名的「加 deep link schema 测试」的落地。
//
// **为什么这层契约值得单独钉死**：`piggycount://` 的 URL 是由**多个互相独立的
// 生产者**拼出来的 —— 桌面小组件（home_widget 的原生侧）、iOS AppIntents /
// 快捷指令、以及 App 内的 `AppLinkBuilder`。它们与本文件的被测解析器
// （`AppLinkService.parseAction` / `AddTransactionParams.fromQueryParams`）
// 之间没有任何编译期约束：改一个 host 名或查询参数名不会有任何编译错误，
// 只会表现为**用户点击小组件没反应**，或**自动记账的备注/标签静默丢失**。
//
// 所以本测试的作用是把「URL 长什么样」变成可执行断言。改动 URL 形态时必须
// 同步改这里的预期值，从而强制改动者意识到这是一份跨进程契约。

import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/services/platform/app_link_service.dart';

void main() {
  // 被测代码本身是纯 Dart（静态方法与字面量构造），但 `app_link_service.dart`
  // 间接 import 了 logger_service —— 其全局 logger 一旦被构造就会挂
  // MethodChannel（`LoggerService._setupNativeBridge`）。本文件不访问 logger，
  // 这行是廉价保险：避免将来有人在此文件里加一条日志就把整个测试文件搞红。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseAction：host → action 映射表', () {
    // 这张表就是 URL 契约的「合法 host 白名单」。
    const cases = <String, AppLinkAction>{
      'piggycount://voice': AppLinkAction.voice,
      'piggycount://image': AppLinkAction.image,
      'piggycount://camera': AppLinkAction.camera,
      'piggycount://ai-chat': AppLinkAction.aiChat,
      'piggycount://aichat': AppLinkAction.aiChat, // 历史别名
      'piggycount://ai': AppLinkAction.aiChat, // 历史别名
      'piggycount://add': AppLinkAction.add,
      'piggycount://new': AppLinkAction.newTransaction,
      'piggycount://open': AppLinkAction.open,
      'piggycount://auto-billing': AppLinkAction.autoBilling,
      'piggycount://quick-billing': AppLinkAction.quickBilling, // 兼容旧版
    };

    cases.forEach((url, expected) {
      test('$url → ${expected.name}', () {
        expect(AppLinkService.parseAction(Uri.parse(url)), expected);
      });
    });

    test('host 大小写不敏感', () {
      expect(
        AppLinkService.parseAction(Uri.parse('piggycount://VOICE')),
        AppLinkAction.voice,
      );
      expect(
        AppLinkService.parseAction(Uri.parse('piggycount://New')),
        AppLinkAction.newTransaction,
      );
    });

    test('path 与 query 不影响动作判定', () {
      // 原生侧拼接时带上路径或多余参数不应导致动作丢失。
      expect(
        AppLinkService.parseAction(Uri.parse('piggycount://voice/anything')),
        AppLinkAction.voice,
      );
      expect(
        AppLinkService.parseAction(Uri.parse('piggycount://new?type=expense')),
        AppLinkAction.newTransaction,
      );
    });

    test('未知 host → unknown（不抛异常）', () {
      expect(
        AppLinkService.parseAction(Uri.parse('piggycount://nope')),
        AppLinkAction.unknown,
      );
      // 空 host 与「无 //」两种畸形形态都要安全落 unknown。
      expect(
        AppLinkService.parseAction(Uri.parse('piggycount://')),
        AppLinkAction.unknown,
      );
      expect(
        AppLinkService.parseAction(Uri.parse('piggycount:voice')),
        AppLinkAction.unknown,
      );
    });
  });

  group('AppLinkBuilder ↔ parseAction：生成与解析必须自洽', () {
    const cases = <String, AppLinkAction>{
      'voice': AppLinkAction.voice,
      'image': AppLinkAction.image,
      'camera': AppLinkAction.camera,
      'aiChat': AppLinkAction.aiChat,
      'newExpense': AppLinkAction.newTransaction,
      'newIncome': AppLinkAction.newTransaction,
      'newTransfer': AppLinkAction.newTransaction,
      'openAssets': AppLinkAction.open,
      'openBudget': AppLinkAction.open,
      'openDetail': AppLinkAction.open,
    };

    final built = <String, String>{
      'voice': AppLinkBuilder.voice(),
      'image': AppLinkBuilder.image(),
      'camera': AppLinkBuilder.camera(),
      'aiChat': AppLinkBuilder.aiChat(),
      'newExpense': AppLinkBuilder.newExpense(),
      'newIncome': AppLinkBuilder.newIncome(),
      'newTransfer': AppLinkBuilder.newTransfer(),
      'openAssets': AppLinkBuilder.openAssets(),
      'openBudget': AppLinkBuilder.openBudget(),
      'openDetail': AppLinkBuilder.openDetail(),
    };

    cases.forEach((name, expected) {
      test('AppLinkBuilder.$name() 解析回 ${expected.name}', () {
        expect(AppLinkService.parseAction(Uri.parse(built[name]!)), expected);
      });
    });

    test('全部 builder 输出使用同一 scheme', () {
      for (final entry in built.entries) {
        expect(
          Uri.parse(entry.value).scheme,
          AppLinkBuilder.scheme,
          reason: '${entry.key} 的 scheme 偏离契约',
        );
      }
    });

    test('newExpenseWithCategory 携带可被 int 解析的分类 id', () {
      final uri = Uri.parse(AppLinkBuilder.newExpenseWithCategory(12));
      expect(AppLinkService.parseAction(uri), AppLinkAction.newTransaction);
      expect(uri.queryParameters['type'], 'expense');
      // 解析器用 int.tryParse 取这个值（见 AppLinkService.handleUrl 的
      // newTransaction 分支），所以断言必须落在「能解析成 int」上。
      expect(int.tryParse(uri.queryParameters['category']!), 12);
    });

    test('open?page= 的取值标识与落地页约定一致', () {
      expect(
        Uri.parse(AppLinkBuilder.openAssets()).queryParameters['page'],
        'assets',
      );
      expect(
        Uri.parse(AppLinkBuilder.openBudget()).queryParameters['page'],
        'budget',
      );
      expect(
        Uri.parse(AppLinkBuilder.openDetail()).queryParameters['page'],
        'detail',
      );
    });

    test('add() 生成的 URL 解析回 add 动作', () {
      expect(
        AppLinkService.parseAction(
          Uri.parse(AppLinkBuilder.add(amount: 12.5, type: 'expense')),
        ),
        AppLinkAction.add,
      );
    });
  });

  group('AddTransactionParams.fromQueryParams：校验与默认值', () {
    test('缺 amount → ArgumentError(amount is required)', () {
      expect(
        () => AddTransactionParams.fromQueryParams(const {}),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('amount'))),
      );
    });

    test('amount 为空串同样视为缺失', () {
      expect(
        () => AddTransactionParams.fromQueryParams(const {'amount': ''}),
        throwsA(isA<ArgumentError>()),
      );
    });

    // 0 / 负数 / 非数字都应被拒 —— 这三条是「静默记出 0 元账单」的防线。
    for (final bad in const ['0', '-5', 'abc', '1e', '  ']) {
      test('amount="$bad" → ArgumentError(必须为正数)', () {
        expect(
          () => AddTransactionParams.fromQueryParams({'amount': bad}),
          throwsA(isA<ArgumentError>()
              .having((e) => e.message, 'message', contains('positive'))),
        );
      });
    }

    test('type 缺省为 expense', () {
      final p = AddTransactionParams.fromQueryParams(const {'amount': '100'});
      expect(p.type, 'expense');
    });

    test('date 合法则解析，非法则落 null 且不抛', () {
      expect(
        AddTransactionParams.fromQueryParams(
          const {'amount': '100', 'date': '2026-09-18'},
        ).date,
        DateTime(2026, 9, 18),
      );
      // 非法日期不能变成「整条链路失败」——它只是退化成「用当前时间」。
      expect(
        AddTransactionParams.fromQueryParams(
          const {'amount': '100', 'date': 'not-a-date'},
        ).date,
        isNull,
      );
    });

    test('tags 按逗号分割并 trim、丢弃空段', () {
      expect(
        AddTransactionParams.fromQueryParams(
          const {'amount': '100', 'tags': 'a, b ,,c'},
        ).tags,
        ['a', 'b', 'c'],
      );
    });

    test('tags 为空串 → null（不是空列表）', () {
      expect(
        AddTransactionParams.fromQueryParams(
          const {'amount': '100', 'tags': ''},
        ).tags,
        isNull,
      );
    });

    test('silent 只认 1/true，其余为 false', () {
      for (final v in const ['1', 'true']) {
        expect(
          AddTransactionParams.fromQueryParams(
            {'amount': '100', 'silent': v},
          ).silent,
          isTrue,
        );
      }
      for (final v in const ['0', 'false', 'yes', '']) {
        expect(
          AddTransactionParams.fromQueryParams(
            {'amount': '100', 'silent': v},
          ).silent,
          isFalse,
        );
      }
    });

    test('to_account → toAccount', () {
      expect(
        AddTransactionParams.fromQueryParams(
          const {'amount': '100', 'to_account': '现金'},
        ).toAccount,
        '现金',
      );
    });

    test('category 是「分类名」，categoryId 只能由 int 入口单独传入', () {
      // 两者语义不同（见 AddTransactionParams 的字段文档）：fromQueryParams
      // 解析的是 auto-billing 场景的分类**名称**；categoryId 是小组件
      // 「快速记账」点分类格时携带的**id**，由 handleUrl 直接构造。
      final p = AddTransactionParams.fromQueryParams(
        const {'amount': '100', 'category': '餐饮'},
      );
      expect(p.category, '餐饮');
      expect(p.categoryId, isNull);
    });
  });

  group('AppLinkBuilder.add()：编码与往返一致', () {
    test('最小参数集的 URL 形态', () {
      expect(
        AppLinkBuilder.add(amount: 100, type: 'expense'),
        'piggycount://add?amount=100.0&type=expense',
      );
    });

    test('中文与空格被百分号编码，不会截断查询串', () {
      final url = AppLinkBuilder.add(
        amount: 1,
        type: 'expense',
        category: '餐饮',
        note: '午饭 加蛋',
      );
      // 空格若未编码会把查询串截断成两半 → 往返测试（下面）会直接暴露。
      expect(url, contains('%20'));
      expect(url, isNot(contains(' ')));
      expect(url, isNot(contains('午饭')));
    });

    test('tags 的逗号被编码', () {
      final url = AppLinkBuilder.add(
        amount: 1,
        type: 'expense',
        tags: ['聚餐', '报销'],
      );
      expect(url, contains('tags='));
      expect(url, isNot(contains('tags=聚餐,报销')));
    });

    test('silent 仅在为 true 时出现', () {
      expect(
        AppLinkBuilder.add(amount: 1, type: 'expense'),
        isNot(contains('silent')),
      );
      expect(
        AppLinkBuilder.add(amount: 1, type: 'expense', silent: true),
        contains('silent=1'),
      );
    });

    test('全字段往返：构造 → 解析 → 字段逐一相等（支出）', () {
      final url = AppLinkBuilder.add(
        amount: 128.5,
        type: 'expense',
        category: '餐饮',
        note: '午饭 加蛋',
        account: '微信',
        tags: ['聚餐', '报销'],
        date: DateTime(2026, 9, 18, 12, 30),
        silent: true,
      );

      final p = AddTransactionParams.fromQueryParams(
        Uri.parse(url).queryParameters,
      );

      expect(p.amount, 128.5);
      expect(p.type, 'expense');
      expect(p.category, '餐饮');
      expect(p.note, '午饭 加蛋');
      expect(p.account, '微信');
      expect(p.tags, ['聚餐', '报销']);
      expect(p.date, DateTime(2026, 9, 18, 12, 30));
      expect(p.silent, isTrue);
      expect(p.toAccount, isNull);
    });

    test('全字段往返：转账（to_account 是独立参数）', () {
      final url = AppLinkBuilder.add(
        amount: 50,
        type: 'transfer',
        account: '支付宝',
        toAccount: '现金',
      );

      final p = AddTransactionParams.fromQueryParams(
        Uri.parse(url).queryParameters,
      );

      expect(p.type, 'transfer');
      expect(p.account, '支付宝');
      expect(p.toAccount, '现金');
    });

    test('往返后 parseAction 仍是 add（避免编码破坏 host）', () {
      final url = AppLinkBuilder.add(
        amount: 9.9,
        type: 'expense',
        category: '零食',
      );
      expect(AppLinkService.parseAction(Uri.parse(url)), AppLinkAction.add);
    });
  });

  group('scheme 常量', () {
    test('AppLinkBuilder.scheme 与原生侧/文档一致', () {
      expect(AppLinkBuilder.scheme, 'piggycount');
    });
  });
  // 说明：本文件刻意**不构造** AppLinkService 实例 —— 其构造会创建
  // AutoBillingService（触碰通知插件与 SharedPreferences），并且
  // _initAppIntentsListener() 只在 iOS 生效。因此这里只覆盖不依赖平台、
  // 不依赖插件的静态契约（parseAction / fromQueryParams / AppLinkBuilder），
  // 这三者恰好就是跨进程 URL 契约的全部内容。
  // handleUrl 的分发分支需要可用的 ProviderContainer，属后续测试批次。
}
