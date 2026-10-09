import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import 'sheet_actions.dart';
import 'sheet_card.dart';

/// 表单类底部抽屉的统一外壳（悬浮卡片式），基准实现见云同步配置
/// `cloud_service_page.dart` 的 Supabase / WebDAV / S3 三表单。
///
/// 结构固定为（AGENTS「表单抽屉一律用悬浮卡片外壳」）：
///
/// ```
/// 抓取条（下拉关闭的显式把手）
/// 标题居中（strongTitle + fs17，固定）〔左上角：编辑态删除图标，传 deleteLabel〕
/// 〔右上角：各页自定义图标动作，传 trailingAction〕
/// p16
/// ┌ 字段区（限高 + 内部滚动，下拉到顶继续拉 = 关闭）┐
/// └ Flexible(loose) → SingleChildScrollView ┘
/// p20
/// 「取消｜保存」（PiggySheetActions，**固定在卡片底部**）
/// ```
///
/// 卡片 chrome（键盘避让 / 底部安全区 / 左右留距 / Material）由 [PiggySheetCard]
/// 提供；只有中间字段区滚动，标题与按钮行常驻可见 —— 长表单不必滚到底才能保存。
///
/// ## 下拉关闭：整卡一条通路、跟手、可停住（2026-10-09 重做）
///
/// 此前是两套各自手写的通路，同一次「往下滑」在两处手感完全不同：
/// 抓取条 / 标题 / 按钮行交给模态抽屉自身的手势（跟手、可中途停住）；字段区由
/// `_DragToDismiss` 累计 overscroll，**攒够 72 逻辑像素直接 pop** —— 位移不跟手、
/// 到点就跳走、松手前停不住。
///
/// 现在整卡只有一条通路：卡片整体垫在一个 [Transform.translate] 上（外面套
/// [RepaintBoundary]，长表单位移时才不会逐帧重绘整张表单），纵向位移由 [_pull]
/// 的进度决定；两路输入都折算成同一个进度：
///
/// - **非滚动区**（抓取条 / 标题 / 按钮行）→ 本组件最外层的 [GestureDetector]
///   直接取手指位移（`primaryDelta`）；
/// - **字段区** → 手势在手势竞技场里被内部可滚动区吃掉（探针用例见
///   `test/widgets/form_sheet_shell_test.dart`），改从 `OverscrollNotification`
///   取位移；字段区用 [_PullPinnedScrollPhysics]：抽屉一下拉就把内容钉在顶部，
///   于是「手指折返上滑」也走同一条 overscroll 通道 —— **上滑 1:1 收回抽屉、
///   内容一动不动**（收回到顶后继续上滑才把内容交回滚动），不会出现「内容往上滚」
///   与「抽屉自己弹回」两个动画打架那种卡顿。
///
/// 判定与收尾沿用模态底抽屉自身的口径：位移超过卡片高度的一半、或下滑速度 >
/// 700px/s 才关闭（[_closeProgress] / [_minFlingVelocity]），否则回弹归位 ——
/// 「拖到一半松手」会先停在那儿再滑回去，而不是到点就跳走。回弹动画一次下拉只起
/// 一次（[_settle]），别每帧 `animateBack`：那会看着一顿一顿的。
///
/// 为什么不用模态抽屉自身的拖拽（`enableDrag: true`）：它按 `route.animation`
/// 的**曲线**折算位移，跟手只在它自己的拖拽回调里成立（dragStart 时临时改绑裸
/// 动画、dragEnd 再换回曲线）；字段区根本进不了那套回调，两路必然不一致。因此
/// [showPiggyFormSheet] 显式关掉它，整卡统一由这里驱动。代价：拖拽期间遮挡层不
/// 随之变浅（barrier 由 `route.animation` 驱动，这里不动它），关闭动画开始时照旧淡出。
///
/// ⚠️ [onCancel] 必须真的收起抽屉（项目内一律传 `Navigator.pop`）：判定关闭时卡片
/// 停在手指松开的位置，余下行程由路由自身的退场动画接着滑完。
///
/// 与另两种外壳的分工：
/// - 本组件：**含输入框的表单**（标题 + 字段 + 取消｜保存）；
/// - [PiggyPickerSheet]：选择器 / 动作菜单（顶栏 X + 标题，无底部按钮行）；
/// - [PiggySheetCard]：内容自备标题与按钮的面板（记账金额面板）。
class PiggyFormSheet extends StatefulWidget {
  const PiggyFormSheet({
    super.key,
    required this.title,
    required this.child,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.onCancel,
    required this.onConfirm,
    this.confirmBusy = false,
    this.deleteLabel,
    this.onDelete,
    this.deleteBusy = false,
    this.trailingAction,
  });

  /// 卡片标题（居中展示，常驻不滚动）。
  final String title;

  /// 表单字段区。**不要**自带滚动容器 / `Expanded` —— 本组件的内容区已限高
  /// 并内部滚动；纵向要撑满用 [BoxConstraints] 限一下即可。
  final Widget child;

  final String cancelLabel;
  final String confirmLabel;

  /// 取消回调；同时作为「抓取条 / 标题 / 按钮行 / 字段区下拉关闭」的收尾动作，
  /// 一般传 `() => Navigator.of(context).pop()`（见类注释：必须真的收起抽屉）。
  final VoidCallback onCancel;

  /// 确认回调；传 `null` 即禁用确认键（如必填项为空时），与
  /// [PiggySheetActions.onConfirm] 的语义一致。
  final VoidCallback? onConfirm;

  /// 确认进行中：确认键转圈并与取消键一并禁用（防连点）。
  final bool confirmBusy;

  /// 编辑态抽屉的删除入口文案（**渲染为标题栏左上角的垃圾桶图标**，本值只作
  /// tooltip）；`null` = 不渲染删除入口（新建态就该传 null）。
  ///
  /// ⚠️ 删除入口**不要**塞进 [child]（字段区）：字段区是滚动区，周期账单那种
  /// 十几个字段的长表单会把入口推到屏幕外，用户以为「没有删除」。交给本参数渲染，
  /// 它固定在标题栏左上角、不随滚动移动，也不占底部动作行的空间。
  ///
  /// 为什么在左：删除不可逆，放在远离右拇指常停留位置的左上角，与「右下角是主
  /// 动作（保存）」形成对角；左侧要放别的图标动作时用 [trailingAction] 那侧。
  final String? deleteLabel;

  /// 删除回调；与 [deleteLabel] 成对使用。
  final VoidCallback? onDelete;

  /// 删除进行中：删除图标禁用（防连点）。
  final bool deleteBusy;

  /// 标题栏**右上角**的自定义图标动作（只渲染图标，`null` = 不渲染）。
  ///
  /// 左侧槽位归 [deleteLabel]（删除便捷写法），右上角留给各页自己的次要动作
  /// （如账户抽屉的「隐藏 / 恢复」）。槽位固定 48 宽，只放图标类动作，塞文字
  /// 按钮会把居中标题挤偏。
  final Widget? trailingAction;

  @override
  State<PiggyFormSheet> createState() => _PiggyFormSheetState();
}

class _PiggyFormSheetState extends State<PiggyFormSheet>
    with SingleTickerProviderStateMixin {
  /// 回弹归位时长：与模态底抽屉的入场时长同量级（250ms）。
  static const Duration _settleDuration = Duration(milliseconds: 250);

  /// 关闭进度阈值：下拉超过卡片高度的这个比例即算「关掉」。
  /// 同模态底抽屉自身的 `_kCloseProgressThreshold`（0.5）。
  static const double _closeProgress = 0.5;

  /// 快速下滑阈值（逻辑像素 / 秒）。同模态底抽屉自身的 `_kMinFlingVelocity`（700）。
  static const double _minFlingVelocity = 700;

  /// 字段区估速窗口：字段区手势被内部滚动区吃掉、拿不到 `DragEndDetails`，
  /// 只能用最近这一小段位移估速度（判定「快速下滑」）。
  static const Duration _velocityWindow = Duration(milliseconds: 100);

  /// 跟手进度：0 = 完全展开，1 = 整卡移出屏幕。像素位移 = value × 卡片高度。
  late final AnimationController _pull = AnimationController(
    vsync: this,
    duration: _settleDuration,
  );

  /// 字段区的物理：下拉期间把内容钉在顶部（见 [_PullPinnedScrollPhysics]）。
  ///
  /// ⚠️ 实例必须只建一次：`Scrollable` 靠 `physics != oldPhysics` 判断要不要重建
  /// `ScrollPosition`，每帧新建会把滚动状态连同进行中的手势一起丢掉。
  late final ScrollPhysics _fieldPhysics = _PullPinnedScrollPhysics(
    isPulling: () => _pulling,
  );

  /// 量高度用的 key —— `Transform` 的 RenderBox 尺寸就是整张卡片（含外壳留距）
  /// 的高度，与模态底抽屉自身的 `_childHeight` 同口径。
  final GlobalKey _sheetKey = GlobalKey();

  /// 卡片高度（逻辑像素）。每次手势开始时量一次 —— 拖拽期间它不变。
  double _height = 1;

  /// 是否正由本组件接管下拉（字段区正常滚动 / 惯性滚动期间为 false）。
  bool _pulling = false;

  /// 本次下拉是否来自字段区（决定收尾信号从哪来：字段区没有 `DragEndDetails`）。
  bool _fromField = false;

  /// 字段区下拉的 (时间戳, 累计位移) 采样，仅用于估算松手速度。
  final List<(Duration, double)> _samples = <(Duration, double)>[];

  @override
  void dispose() {
    _pull.dispose();
    super.dispose();
  }

  // ── 非滚动区：抓取条 / 标题 / 按钮行 ──────────────────────────────

  void _handleDragStart(DragStartDetails details) =>
      _beginPull(fromField: false);

  void _handleDragUpdate(DragUpdateDetails details) =>
      _applyPull(details.primaryDelta ?? 0);

  void _handleDragEnd(DragEndDetails details) =>
      _release(details.velocity.pixelsPerSecond.dy);

  void _handleDragCancel() => _settle();

  // ── 字段区：下拉到顶继续拉，位移从 overscroll 来 ───────────────────

  /// 字段区的下拉/收尾。返回 false：不拦截通知，overscroll 指示器继续收到。
  bool _handleFieldScroll(ScrollNotification notification) {
    // 只认字段区自己那层（内层横向列表等滚动的通知会带 depth / 非纵向轴，与本卡无关）。
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
        // 「顶部继续往下拉」（overscroll < 0）与「手指折返上滑」（> 0）走同一个
        // 进度入口：下拉期间物理是钉住的（见 [_fieldPhysics]），两者都按 overscroll
        // 上报，于是往上滑 = 等量收回抽屉，内容一动不动。
        _beginPull(fromField: true);
        _applyPull(-overscroll, at: dragDetails.sourceTimeStamp);
        if (overscroll > 0 && _pull.value == 0) {
          // 收回到底还继续上滑：解除钉住，内容从下一帧起正常滚动。
          _pulling = false;
        }
      case ScrollUpdateNotification(:final dragDetails):
        // 兜底（钉顶物理生效时到不了这里）：字段区真滚起来了 = 手指折返，
        // 立即归位并放手，免得抽屉挂在半途、内容却滚走。
        if (dragDetails != null && _pulling) _settle();
      case ScrollEndNotification():
        // 字段区手势结束（下拉期间不会进入惯性，这里就是松手那一刻）。
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

  /// 累加下拉位移（正数 = 向下）。非滚动区手势与字段区 overscroll 共用。
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
      widget.onCancel();
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

  /// 字段区松手速度（像素 / 秒，正数 = 向下）：用最近一段采样估一次。
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
    final String? deleteLabel = widget.deleteLabel;
    // 左上角槽位：deleteLabel 的垃圾桶便捷写法（唯一占左侧的动作）。
    final Widget? leading = deleteLabel == null
        ? null
        : IconButton(
            onPressed: widget.deleteBusy ? null : widget.onDelete,
            icon: const Icon(Icons.delete_outline),
            color: PiggyTokens.error(context),
            // 只要图标：文案走 tooltip（长按可见 + 无障碍朗读）。
            tooltip: deleteLabel,
            iconSize: 22,
          );
    return GestureDetector(
      // 非滚动区的下拉手势；字段区会被内部滚动区在手势竞技场里吃掉，
      // 那一路由 _handleFieldScroll 兜住（见类注释）。
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
        child: RepaintBoundary(
          child: PiggySheetCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SheetDragHandle(),
                // 标题行：居中标题 + 两侧图标槽（各占 48 等宽，标题不被挤偏）。
                Row(
                  children: [
                    SizedBox(width: 48, child: leading),
                    Expanded(
                      child: Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        style: PiggyTextTokens.strongTitle(context).copyWith(
                          fontSize: PiggyTextTokens.fs17,
                        ),
                      ),
                    ),
                    SizedBox(width: 48, child: widget.trailingAction),
                  ],
                ),
                const SizedBox(height: PiggyDimens.p16),
                // Flexible(loose)：拿到的剩余高度有限（模态抽屉本身有界），
                // 字段少时按内容收缩、字段多时截断并内部滚动。
                Flexible(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _handleFieldScroll,
                    child: SingleChildScrollView(
                      // 本卡专用物理：平时就是 Clamping（各平台手感一致，且顶部
                      // 继续下拉会发 OverscrollNotification —— bouncing 物理不会发，
                      // 那样 iOS 上字段区就永远拉不动抽屉）；一旦抽屉被拉下来就
                      // 把内容钉在顶部，见 [_PullPinnedScrollPhysics]。
                      physics: _fieldPhysics,
                      padding: const EdgeInsets.symmetric(
                        horizontal: PiggyDimens.p20,
                      ),
                      child: widget.child,
                    ),
                  ),
                ),
                const SizedBox(height: PiggyDimens.p20),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PiggyDimens.p20,
                  ),
                  child: PiggySheetActions(
                    cancelLabel: widget.cancelLabel,
                    confirmLabel: widget.confirmLabel,
                    onCancel: widget.onCancel,
                    onConfirm: widget.onConfirm,
                    confirmBusy: widget.confirmBusy,
                  ),
                ),
                const SizedBox(height: PiggyDimens.p20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 字段区下拉期间的**钉顶物理**：把手指数位移整段当「顶部过度滚动」上报，内容一动不动。
///
/// 为什么需要它：字段区是滚动区，手势在手势竞技场里归它。抽屉一旦被拉下来，手指
/// 折返上滑时它会立刻去滚内容 —— 于是「内容往上滚」和「抽屉往回弹」两件事同时发生，
/// 加上回弹是另起一个定时动画（与手指无关），长表单上看着就是一顿一顿的卡顿。
///
/// 钉住之后（[isPulling] 为真时）：
/// - 位移无论上下都只发 `OverscrollNotification`（符号即方向），下拉进度由它折算，
///   于是往上滑 = 1:1 收回抽屉，字段内容纹丝不动；
/// - 收回到底（进度归零）后由调用方解除钉住，内容从下一帧起正常滚动。
///
/// 平时（没在下拉）退化成普通 [ClampingScrollPhysics]，滚动、惯性一切照旧。
class _PullPinnedScrollPhysics extends ClampingScrollPhysics {
  const _PullPinnedScrollPhysics({required this.isPulling, super.parent});

  /// 抽屉是否正被下拉（读 [_PiggyFormSheetState._pulling]）。
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

/// 抽屉顶部抓取条（32×4 中性色圆角条）：既是「可下拉关闭」的视觉提示，
/// 也是长表单里最稳的拖拽落点。
class _SheetDragHandle extends StatelessWidget {
  const _SheetDragHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: PiggyDimens.p8,
        bottom: PiggyDimens.p4,
      ),
      child: Center(
        child: Container(
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: PiggyTokens.borderStrong(context),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
          ),
        ),
      ),
    );
  }
}

/// 以统一外壳弹出表单抽屉：[T] 是抽屉返回值类型。
///
/// 弹层底必须透明 —— 卡片由 [PiggyFormSheet] 内的 Material 绘制四角圆角与
/// 悬浮留距（传实色底会变成旧的全宽平底弹层）。
///
/// `enableDrag: false`：抽屉自身的拖拽按 `route.animation` 的曲线折算位移，
/// 只能盖住非滚动区，与字段区必定两套手感；整卡下拉统一交给 [PiggyFormSheet]，
/// 见其类注释。
Future<T?> showPiggyFormSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    enableDrag: false,
    builder: builder,
  );
}
