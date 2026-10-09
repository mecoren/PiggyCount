/// 悬浮卡片抽屉的**整卡下拉关闭**公共件 —— 表单抽屉（[PiggyFormSheet]）与列表型
/// 选择器（`PiggyPickerSheet` + `showPiggyPickerSheet(dragToDismiss: true)`）共用
/// 同一套，不要再各写一份。
///
/// 结构：
///
/// ```
/// PiggySheetDragScope            ← 整卡手势 + 跟手位移 + 关闭判定 / 收尾
///   └ GestureDetector            ← 非滚动区（抓取条 / 标题 / 顶栏 / 按钮行）
///       └ AnimatedBuilder → Transform.translate
///           └ RepaintBoundary    ← 位移只重新合成图层，不逐帧重绘长表单
///               └ 卡片（PiggySheetCard）
///                   └ 顶栏 / 标题
///                   └ PiggySheetDragContent   ← 内容滚动区：overscroll 折算成位移
/// ```
///
/// 两路输入都只是「喂进度」，位移 / 判定 / 收尾共用一套：
///
/// - **非滚动区** → [PiggySheetDragScope] 外层 `GestureDetector` 直接取手指位移；
/// - **内容滚动区** → 手势在手势竞技场里归它（[PiggySheetDragContent] 只挂
///   `NotificationListener`，不参与竞技场），从 `OverscrollNotification` 取位移。
///
/// 内容区物理由 [PiggySheetDragContent] 统一注入（见 [_PullPinnedScrollPhysics]）：
/// 平时等价 `ClampingScrollPhysics`（顶部继续下拉必须发 `OverscrollNotification`，
/// 回弹物理不发，各平台必须一致），抽屉一下拉就把内容钉在顶部 —— 于是手指折返上滑
/// 也走同一条 overscroll 通道，**上滑 1:1 收回抽屉、内容一动不动**；收回到底后继续
/// 上滑才把内容交回滚动。
///
/// ⚠️ 只给**内容是可滚动列表 / 网格**的抽屉开（表单抽屉一律开；选择器里滚轮型
/// 不许开 —— 见 `showPiggyPickerSheet` 的 `dragToDismiss`）。
library;

import 'package:flutter/material.dart';

/// 整卡下拉的**作用域**：套在卡片外面，负责手势、跟手位移与关闭判定。
///
/// 判定沿用模态底抽屉自身的口径：位移超过卡片高度的一半、或下滑速度 > 700px/s
/// 才关闭，否则回弹归位 —— 「拖到一半松手」会先停在那儿再滑回去。
class PiggySheetDragScope extends StatefulWidget {
  const PiggySheetDragScope({
    super.key,
    required this.onDismiss,
    required this.child,
  });

  /// 判定关闭时调用（项目内一律是「收起抽屉」：表单抽屉传调用方的 `onCancel`，
  /// 选择器传 `Navigator.pop`）。**必须真的收起来** —— 卡片此时停在手指松开的
  /// 位置，余下行程由路由自身的退场动画接着滑完。
  final VoidCallback onDismiss;

  /// 卡片（含外壳留距）。
  final Widget child;

  /// 找最近一层作用域；没有（没开下拉）返回 null。
  static PiggySheetDragScopeState? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_PiggySheetDragScopeMarker>()
      ?.state;

  @override
  State<PiggySheetDragScope> createState() => PiggySheetDragScopeState();
}

class _PiggySheetDragScopeMarker extends InheritedWidget {
  const _PiggySheetDragScopeMarker({required this.state, required super.child});

  final PiggySheetDragScopeState state;

  @override
  bool updateShouldNotify(_PiggySheetDragScopeMarker oldWidget) => false;
}

class PiggySheetDragScopeState extends State<PiggySheetDragScope>
    with SingleTickerProviderStateMixin {
  /// 回弹归位时长：与模态底抽屉的入场时长同量级（250ms）。
  static const Duration _settleDuration = Duration(milliseconds: 250);

  /// 关闭进度阈值：下拉超过卡片高度的这个比例即算「关掉」。
  /// 同模态底抽屉自身的 `_kCloseProgressThreshold`（0.5）。
  static const double _closeProgress = 0.5;

  /// 快速下滑阈值（逻辑像素 / 秒）。同模态底抽屉自身的 `_kMinFlingVelocity`（700）。
  static const double _minFlingVelocity = 700;

  /// 内容区估速窗口：内容区手势被滚动区吃掉、拿不到 `DragEndDetails`，
  /// 只能用最近这一小段位移估速度（判定「快速下滑」）。
  static const Duration _velocityWindow = Duration(milliseconds: 100);

  /// 跟手进度：0 = 完全展开，1 = 整卡移出屏幕。像素位移 = value × 卡片高度。
  late final AnimationController _pull = AnimationController(
    vsync: this,
    duration: _settleDuration,
  );

  /// 内容区物理用的钉顶装饰器（实例只建一次，见 [decorate]）。
  late final _PullPinnedScrollPhysics _pinned = _PullPinnedScrollPhysics(
    isPulling: () => _pulling,
  );

  /// 量高度用的 key —— `Transform` 的 RenderBox 尺寸就是整张卡片（含外壳留距）
  /// 的高度，与模态底抽屉自身的 `_childHeight` 同口径。
  final GlobalKey _sheetKey = GlobalKey();

  /// 卡片高度（逻辑像素）。每次手势开始时量一次 —— 拖拽期间它不变。
  double _height = 1;

  /// 是否正由本组件接管下拉（内容区正常滚动 / 惯性滚动期间为 false）。
  bool _pulling = false;

  /// 本次下拉是否来自内容区（决定收尾信号从哪来：内容区没有 `DragEndDetails`）。
  bool _fromField = false;

  /// 内容区下拉的 (时间戳, 累计位移) 采样，仅用于估算松手速度。
  final List<(Duration, double)> _samples = <(Duration, double)>[];

  /// 内容区是否正被下拉（[_PullPinnedScrollPhysics] 据此决定钉不钉）。
  bool get isPulling => _pulling;

  @override
  void dispose() {
    _pull.dispose();
    super.dispose();
  }

  /// 把 [inner] 接到钉顶装饰器上（内容区用）。返回值必须**缓存**：每帧新建
  /// `ScrollPhysics` 会让 `Scrollable` 重建 `ScrollPosition`（`physics != oldPhysics`），
  /// 把滚动状态连同进行中的手势一起丢掉。
  ScrollPhysics decorate(ScrollPhysics inner) => _pinned.applyTo(inner);

  // ── 非滚动区 ──────────────────────────────────────────────────────

  void _handleDragStart(DragStartDetails details) =>
      _beginPull(fromField: false);

  void _handleDragUpdate(DragUpdateDetails details) =>
      _applyPull(details.primaryDelta ?? 0);

  void _handleDragEnd(DragEndDetails details) =>
      _release(details.velocity.pixelsPerSecond.dy);

  void _handleDragCancel() => _settle();

  // ── 内容区：内容滚到顶后继续下拉，位移从 overscroll 来 ─────────────

  /// 内容区的下拉/收尾。返回 false：不拦截通知，overscroll 指示器继续收到。
  bool handleScrollNotification(ScrollNotification notification) {
    // 只认内容区自己那层（内层横向列表等滚动的通知会带 depth / 非纵向轴，与本卡无关）。
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    switch (notification) {
      case OverscrollNotification(:final overscroll, :final dragDetails):
        // 惯性 / 指示器带出来的 overscroll 没有 dragDetails，不算手指位移。
        if (dragDetails == null) break;
        if (overscroll > 0 && _pull.value == 0) {
          // 抽屉没被拉下来（或已经收回到底）：上滑是内容自己的事，不碰抽屉。
          break;
        }
        // 「内容到顶后继续下拉」（overscroll < 0）与「手指折返上滑」（> 0）走同一个
        // 进度入口：下拉期间物理是钉住的，两者都按 overscroll 上报，于是往上滑 =
        // 等量收回抽屉，内容一动不动。
        _beginPull(fromField: true);
        _applyPull(-overscroll, at: dragDetails.sourceTimeStamp);
        if (overscroll > 0 && _pull.value == 0) {
          // 收回到底还继续上滑：解除钉住，内容从下一帧起正常滚动。
          _pulling = false;
        }
      case ScrollUpdateNotification(:final dragDetails):
        // 兜底（钉顶物理生效时到不了这里）：内容真滚起来了 = 手指折返，
        // 立即归位并放手，免得抽屉挂在半途、内容却滚走。
        if (dragDetails != null && _pulling) _settle();
      case ScrollEndNotification():
        // 内容区手势结束（下拉期间不会进入惯性，这里就是松手那一刻）。
        if (_fromField) _release(_estimatedVelocity);
      case _:
        break;
    }
    return false;
  }

  // ── 下拉进度的公共账本 ────────────────────────────────────────────

  void _beginPull({required bool fromField}) {
    if (_pulling) return;
    final box = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
    final double height = box != null && box.hasSize ? box.size.height : 0;
    _height = height > 0 ? height : 1;
    _pulling = true;
    _fromField = fromField;
    _samples.clear();
  }

  /// 累加下拉位移（正数 = 向下）。非滚动区手势与内容区 overscroll 共用。
  void _applyPull(double delta, {Duration? at}) {
    _pull.value = (_pull.value + delta / _height).clamp(0.0, 1.0);
    if (at == null) return;
    _samples.add((at, _pull.value * _height));
    while (_samples.length > 1 && at - _samples.first.$1 > _velocityWindow) {
      _samples.removeAt(0);
    }
  }

  /// 松手：过阈值 / 快速下滑则关闭，否则回弹归位。
  void _release(double velocityDy) {
    if (!_pulling) return;
    _pulling = false;
    if (velocityDy > _minFlingVelocity || _pull.value > _closeProgress) {
      // 保持当前位移，余下行程交给路由自身的退场动画（卡片接着滑出屏幕）。
      widget.onDismiss();
      return;
    }
    _settle();
  }

  /// 回弹归位（松手未过阈值 / 手指折返 / 手势被系统取消）。
  ///
  /// 一次下拉只起一次动画：正在进行中就不要再 `animateBack` —— 每帧重新起一次会
  /// 让位移逐帧「重启」，看着一顿一顿的（长表单尤其明显）。
  void _settle() {
    _pulling = false;
    if (_pull.value == 0 || _pull.status == AnimationStatus.reverse) return;
    _pull.animateBack(0, curve: Easing.legacyDecelerate);
  }

  /// 内容区松手速度（像素 / 秒，正数 = 向下）：用最近一段采样估一次。
  double get _estimatedVelocity {
    if (_samples.length < 2) return 0;
    final (Duration firstTime, double firstPixels) = _samples.first;
    final (Duration lastTime, double lastPixels) = _samples.last;
    final Duration span = lastTime - firstTime;
    if (span <= Duration.zero) return 0;
    return (lastPixels - firstPixels) / (span.inMicroseconds / 1e6);
  }

  @override
  Widget build(BuildContext context) {
    return _PiggySheetDragScopeMarker(
      state: this,
      child: GestureDetector(
        // 非滚动区的下拉手势；内容滚动区会被内部滚动区在手势竞技场里吃掉，
        // 那一路由 handleScrollNotification 兜住。
        onVerticalDragStart: _handleDragStart,
        onVerticalDragUpdate: _handleDragUpdate,
        onVerticalDragEnd: _handleDragEnd,
        onVerticalDragCancel: _handleDragCancel,
        // 只有 Transform 这一层随进度重建，卡片子树不重建。
        child: AnimatedBuilder(
          animation: _pull,
          builder: (context, child) => Transform.translate(
            key: _sheetKey,
            offset: Offset(0, _pull.value * _height),
            child: child,
          ),
          // 整卡单独成一个图层：下拉 / 回弹只移动图层、不逐帧重绘整张表单 ——
          // 周期账单那种十几个字段的长表单，逐帧重绘会肉眼可见地卡。
          child: RepaintBoundary(child: widget.child),
        ),
      ),
    );
  }
}

/// 卡片**内容区（滚动区）**的包装：把内容区的滚动通知折算成下拉进度，并在作用域
/// 存在时给它注入统一的内容区物理。
///
/// 作用域不存在（没开下拉）时**原样返回** —— 选择器默认就是这条路，行为与原生
/// 模态底抽屉一字不差。
class PiggySheetDragContent extends StatefulWidget {
  const PiggySheetDragContent({super.key, required this.child});

  /// 内容（自带滚动区的列表 / 网格 / 滚动兜底）。
  final Widget child;

  @override
  State<PiggySheetDragContent> createState() => _PiggySheetDragContentState();
}

class _PiggySheetDragContentState extends State<PiggySheetDragContent> {
  PiggySheetDragScopeState? _scope;
  ScrollBehavior? _behavior;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final PiggySheetDragScopeState? scope =
        PiggySheetDragScope.maybeOf(context);
    if (scope == _scope) return;
    _scope = scope;
    if (scope == null) {
      _behavior = null;
      return;
    }
    // 只建一次：`ScrollConfiguration` 每次换成新实例都会通知依赖者重建
    // `ScrollPosition`，手势进行中重建会把手势一起丢掉。
    final ScrollBehavior base = ScrollConfiguration.of(context);
    _behavior = base.copyWith(
      physics: scope.decorate(
        const ClampingScrollPhysics().applyTo(base.getScrollPhysics(context)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PiggySheetDragScopeState? scope = _scope;
    if (scope == null) return widget.child;
    return NotificationListener<ScrollNotification>(
      onNotification: scope.handleScrollNotification,
      child: ScrollConfiguration(behavior: _behavior!, child: widget.child),
    );
  }
}

/// 内容区下拉期间的**钉顶物理**：把手指数位移整段当「顶部过度滚动」上报，内容一动不动。
///
/// 为什么需要它：内容区是滚动区，手势在手势竞技场里归它。抽屉一旦被拉下来，手指
/// 折返上滑时它会立刻去滚内容 —— 于是「内容往上滚」和「抽屉往回弹」两件事同时发生，
/// 看着就是一顿一顿的卡顿。钉住之后（[isPulling] 为真时）位移无论上下都只发
/// `OverscrollNotification`（符号即方向），下拉进度由它折算。
///
/// 是个**纯装饰器**：不钉住时所有行为都交给父链（[decorate] 会把内容区原本的物理
/// 接在下游），自己只 override 边界条件。
class _PullPinnedScrollPhysics extends ScrollPhysics {
  const _PullPinnedScrollPhysics({required this.isPulling, super.parent});

  /// 抽屉是否正被下拉。
  final bool Function() isPulling;

  /// 钉住时把任意目标值都判成「整段都是过度滚动」：`setPixels` 里
  /// `_pixels = value - overscroll` 正好回到原位（内容不动），同时按
  /// [ScrollPosition.didOverscrollBy] 发一条带 `dragDetails` 的 overscroll 通知。
  ///
  /// 返回值恰好等于位移量（不会超过），满足 `setPixels` 的 `|overscroll| <= |delta|` 断言。
  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    if (!isPulling()) return super.applyBoundaryConditions(position, value);
    return value - position.pixels;
  }

  @override
  _PullPinnedScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _PullPinnedScrollPhysics(
        isPulling: isPulling,
        parent: buildParent(ancestor),
      );
}
