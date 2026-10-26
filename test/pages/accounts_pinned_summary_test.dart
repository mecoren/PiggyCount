import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/pages/account/accounts_page.dart';

/// 资产页标题行「净资产 / 总资产 / 总负债」三栏的折叠进度守门测试。
///
/// 这条进度决定三栏什么时候在标题行里淡入（「资产管理」右边）。
/// 符号写反会让三栏在页面顶部就冒出来（和净资产卡重复），或者滑到底都不出现
/// （用户以为需求没做）。真机上时序问题很难一眼验证，这里把判据固定住。
void main() {
  const appBarBottom = 100.0;
  const window = 36.0;

  test('净资产块还在标题栏下方时完全收起', () {
    expect(
      pinnedSummaryProgress(
        blockBottom: appBarBottom + 200,
        appBarBottom: appBarBottom,
        window: window,
      ),
      0,
    );
  });

  test('底边正好压到标题栏下沿时仍是 0', () {
    expect(
      pinnedSummaryProgress(
        blockBottom: appBarBottom,
        appBarBottom: appBarBottom,
        window: window,
      ),
      0,
    );
  });

  test('越过下沿后在过渡窗口内线性打开', () {
    expect(
      pinnedSummaryProgress(
        blockBottom: appBarBottom - window / 2,
        appBarBottom: appBarBottom,
        window: window,
      ),
      closeTo(0.5, 1e-9),
    );
    expect(
      pinnedSummaryProgress(
        blockBottom: appBarBottom - window,
        appBarBottom: appBarBottom,
        window: window,
      ),
      1,
    );
  });

  test('整块滑过之后保持钉住', () {
    expect(
      pinnedSummaryProgress(
        blockBottom: appBarBottom - 500,
        appBarBottom: appBarBottom,
        window: window,
      ),
      1,
    );
  });

  test('滚动越往上进度单调不减', () {
    var last = -1.0;
    for (var dy = 120.0; dy >= -120.0; dy -= 4) {
      final progress = pinnedSummaryProgress(
        blockBottom: appBarBottom + dy,
        appBarBottom: appBarBottom,
        window: window,
      );
      expect(progress, inInclusiveRange(0, 1));
      expect(progress, greaterThanOrEqualTo(last));
      last = progress;
    }
  });

  test('window 非法时退化成二值判定，不做除零', () {
    expect(
      pinnedSummaryProgress(
        blockBottom: appBarBottom - 1,
        appBarBottom: appBarBottom,
        window: 0,
      ),
      1,
    );
    expect(
      pinnedSummaryProgress(
        blockBottom: appBarBottom + 1,
        appBarBottom: appBarBottom,
        window: 0,
      ),
      0,
    );
  });
}
