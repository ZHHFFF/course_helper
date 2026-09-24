// ============================================================================
// 液态玻璃底栏（Miuix GlassNavigationBar 的增强版 · 方案 C：BackdropFilter）
// ============================================================================
//
// 【为什么不用包里的 MiuixGlassNavigationBar】
//
// `flutter_miuix 1.2.0` 的 `MiuixGlassNavigationBar` 是「官方的液态玻璃底栏」，
// 玻璃外壳 / backdrop 采样 / 跨项拖动 / spring 回弹都齐了，但有两处不够：
//
//   - 选中指示器只是一个纯色 `AnimatedContainer` + `StadiumBorder`
//     （`neutral.withValues(alpha: .12)`），不是玻璃，没有模糊也没有高光；
//   - 按压反馈只有图标 `Opacity(0.6)`，没有形变、没有描边变化、没有缩放。
//
// 这两处都写死在它的 `build()` 里，包内没有扩展点，所以把它的实现**原样搬过来
// 再补**。搬过来的部分（拖动几何 / 弹簧参数 / 显示隐藏动画）一行没改。
//
// 【为什么把玻璃从「快照采样」换成 BackdropFilter】
//
// Miuix 的 `MiuixGlassPanel` 不是 `BackdropFilter`，而是「录图层快照 → 喂
// `miuix_os4_glass.frag`」：靠 `paint()` 触发 `addPostFrameCallback` 里的
// `toImageSync()` 把内容层录成一张位图，玻璃再按偏移取样 + 模糊 + 折射。
//
// 这个机制在**静态**画面下没问题，但一滚动就崩：
//   `ListView` 的 `Viewport` 自己就是重绘边界
//   （`RenderViewportBase.isRepaintBoundary => true`，`rendering/viewport.dart:752`），
//   滚动时 `markNeedsPaint()` 只标脏 viewport 自己的图层，**位于它之上的捕获节点
//   收不到 `paint()`** → 快照冻在旧帧，只在偶尔重排时跳一次。
//   真机实测（一加 13 / 60Hz）：滚动期间捕获频率只有 **4~37 次/秒**（平均 ~19），
//   而同期 `SurfaceFlinger --latency` 显示**每帧都是 16.57ms、零掉帧** ——
//   所以卡顿不是掉帧，是**采样频率跟不上**。
//   而且每次捕获是整屏位图（1264×2780 ≈ 14MB）+ CPU 侧 `toImageSync`，
//   功耗也远高于 GPU 的一次 blur pass。
//
// 因此改用与**顶栏完全相同**的机制：`ClipRRect` + `BackdropFilter` +
// `ImageFilter.blur`，再叠一层半透明色调。
//   - 合成时实时取正下方像素 → **永远与当前帧同步，零延迟**；
//   - 只有一次 GPU blur pass，没有位图录制/上传 → 功耗低一个量级；
//   - 代价：**没有折射/色差**（那需要 `ImageFilter.shader`，见下）。
//
// 顶栏（`miuix_top_app_bar.dart:1097-1124`）用的正是这套：
//   `sigma = blurRadius.clamp(0,150) * 0.45`
//   `ColoredBox(color: colors.surface.withValues(alpha: blurTintAlpha))`
// 这里逐值对齐，保证底栏和顶栏是**同一种玻璃**。
//
// 【层级结构（有一个反直觉的坑，改之前务必看懂）】
//
// ```
// DecoratedBox(阴影)          ← 必须在 ClipRRect **外面**，否则阴影被裁掉
//  └ ClipRRect(圆角)
//     └ Stack
//        ├ BackdropFilter ← 背景玻璃层（唯一的「实时采样屏幕像素」入口）
//        ├ 选中指示器      ← 自己也有 BackdropFilter
//        └ 导航项          ← 画在最上
// ```
//
// ⚠️ 选中指示器必须与背景玻璃**并列**，绝不能嵌进背景玻璃的 `child` 里。
// 原因：`BackdropFilter` 的语义是「saveLayer 一个空图层，把**当前画布上已绘制的
// 内容**作为 backdrop 输入」。一旦嵌套，内层读到的就是外层**刚创建、几乎空白**的
// 图层（里面只有一层纯色调）—— 糊一个均匀色块等于没糊，**嵌套 BackdropFilter
// 会静默失效**。放进同一个 `Stack` 当兄弟节点，内层读到的才是
// 「屏幕内容 + 外层玻璃」的合成结果。
//
// 【以后想补回折射】
//
// Flutter 的 `ui.ImageFilter.shader` 可以把 `BackdropFilter` 的输入直接喂给
// fragment shader（引擎会把首个 `vec2` uniform 设为纹理尺寸、首个 `sampler2D`
// 设为 filter 输入），因此「实时 + 折射」理论上可以兼得。
// 但它 **只在 Impeller 下可用**（`painting.dart` 里对非 Impeller 直接
// `throw UnsupportedError`），且 GLES 后端要手动翻 y 轴。等确认目标机都走
// Impeller 再上。
//
// 用到的 Miuix 公开 API：
//   - `MiuixGlassMotion`   全部弹簧参数 + `pressScale`（按压缩放规范值）
//   - `MiuixGlassStroke(s)` 玻璃描边（含光照方向的 bloom 色）
//   - `MiuixGlassShadow(s)` 玻璃阴影预设（`floating` 等）
//   - `MiuixGlassShape`    圆角
//   - `miuixGlassNavigationDragTarget` / `miuixGlassNavigationIndicatorBounds`
//                          跨项拖动几何（跟手拉伸上限 60 物理像素）
//
// ⚠️ 包里 `GlassSpringBuilder` 与 `GlassInteractive` 在 `glass/internal/` 下
// **没有导出**，这里用同样公开的 `SpringDescription` 自己驱动
// （[_MiuixSpringValue]）与自写 [_NavItemInteractive]，弹簧参数仍取自
// `MiuixGlassMotion`，手感与 Miuix 其它组件一致。
// ============================================================================

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_miuix/miuix.dart';

/// 与 `MiuixGlassNavigationBar` 同名的入参类型，直接复用包里的定义。
typedef MiuixLiquidGlassNavItem = MiuixGlassNavigationItem;

/// 液态玻璃底栏（`BackdropFilter` 版）。
///
/// 与 `MiuixGlassNavigationBar` 的差异：
/// 1. 玻璃外壳用 **`BackdropFilter`**（与顶栏同一机制）而不是图层快照采样 ——
///    滚动时模糊连续跟随、无 1 帧延迟、无整屏位图录制，功耗低一个量级；
/// 2. 选中区域是**一层与外壳并列叠加的玻璃**（自己再采样一次 + 更亮的色调 +
///    描边），而不是纯色胶囊，所以选中项有自己的模糊与边缘高光；
/// 3. 按压时有完整反馈：`MiuixGlassMotion.pressScale` 缩放 + 描边增亮加粗 +
///    高光叠加，全部由 Miuix 的弹簧（`navPressEnter` / `navPressExit`）驱动，
///    松手平滑回弹。
class MiuixLiquidGlassNavigationBar extends StatefulWidget {
  const MiuixLiquidGlassNavigationBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    this.alpha = 1,
    this.visible = true,
    this.height = 54,
    this.blurRadius = 20,
    this.blurTintAlpha = .55,
    this.shape,
    this.stroke,
    this.shadow = MiuixGlassShadows.floating,
    this.selectedColor,
    this.unselectedColor,
    this.bottomPadding = 0,
    this.pageController,
  });

  final List<MiuixLiquidGlassNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// 玻璃整体的不透明度倍率（同时作用于模糊与色调层）。
  final double alpha;
  final bool visible;
  final double height;

  /// 模糊半径（dp）。默认 20，与 Miuix 玻璃材质 `puredThinGlass` 一致。
  ///
  /// 实际 sigma = `blurRadius * 0.45`（顶栏同款换算），所以 20 → 9.0。
  final double blurRadius;

  /// 模糊之上叠加的色调不透明度 [0,1]。默认 .55，与顶栏 `blurTintAlpha` 一致。
  final double blurTintAlpha;

  final MiuixGlassShape? shape;
  final MiuixGlassStroke? stroke;
  final MiuixGlassShadow? shadow;

  /// 选中 / 未选中项的图标与文字颜色（不传则用 `colors.onBackground`）。
  final Color? selectedColor, unselectedColor;

  /// 底部手势安全区内边距（贴底模式下使玻璃铺满手势区）。
  final double bottomPadding;

  /// 页面滑动控制器（联动左右滑动切换与指示器平滑跟随）。
  final PageController? pageController;

  @override
  State<MiuixLiquidGlassNavigationBar> createState() =>
      _MiuixLiquidGlassNavigationBarState();
}

class _MiuixLiquidGlassNavigationBarState
    extends State<MiuixLiquidGlassNavigationBar>
    with TickerProviderStateMixin {
  late final _show = AnimationController.unbounded(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  late final _left = AnimationController.unbounded(vsync: this);
  late final _right = AnimationController.unbounded(vsync: this);
  final _key = GlobalKey();
  final _controllers = <AnimationController>[];

  bool _isAnimatingFromTap = false;
  Timer? _animatingFromTapTimer;

  @override
  void initState() {
    super.initState();
    _controllers.addAll([_show, _left, _right]);
    widget.pageController?.addListener(_onPageScroll);
  }

  void _onPageScroll() {
    if (widget.pageController == null || !widget.pageController!.hasClients) return;
    if (_pointer != null) return;
    if (_isAnimatingFromTap) {
      if (widget.pageController!.position.userScrollDirection != ScrollDirection.idle) {
        _animatingFromTapTimer?.cancel();
        _isAnimatingFromTap = false;
      } else {
        return;
      }
    }
    final page = widget.pageController!.page;
    if (page != null && _width > 0) {
      final clampedPage = page.clamp(0.0, (widget.items.length - 1).toDouble());
      final frac = (clampedPage - clampedPage.floor()).clamp(0.0, 1.0);
      // 中间态微弱液态横向拉伸（SDF 液态微形变，最大 +6dp），两端归零
      final stretch = (1 - (2 * frac - 1).abs()) * 6.0;
      final targetLeft = leftOf(page) - stretch / 2;
      final targetRight = leftOf(page) + _slot + 10 + stretch / 2;
      _left.value = targetLeft;
      _right.value = targetRight;
    }
  }

  Timer? _timer;
  int? _pointer;
  int _pressed = -1;
  double _width = 0, _lastX = 0;
  bool _positioned = false;

  bool get _disabledMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  int get _index => widget.items.isEmpty
      ? 0
      : widget.selectedIndex.clamp(0, widget.items.length - 1);

  double get _slot =>
      (_width - 16).clamp(0.0, double.infinity) /
      math.max(1, widget.items.length);

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  double leftOf(num index) =>
      8 + (_rtl ? widget.items.length - 1 - index : index) * _slot - 5;

  /// 外壳圆角：`shape` 不传时用胶囊（999）。
  double get _radius => widget.shape?.cornerRadius ?? 999;

  /// 模糊 sigma，换算系数与顶栏一致（`BLUR_RADIUS_TO_SIGMA = 0.45`）。
  double get _sigma => widget.blurRadius.clamp(0.0, 150.0) * 0.45;

  void _select(int index) {
    _animatingFromTapTimer?.cancel();
    _isAnimatingFromTap = true;
    _animatingFromTapTimer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) {
        _isAnimatingFromTap = false;
      }
    });
    _move(leftOf(index), leftOf(index) + _slot + 10);
    widget.onSelect(index);
  }

  void _move(
    double left,
    double right, {
    bool following = false,
    bool? movingRight,
  }) {
    final rightwards = movingRight ?? left > _left.value;
    _animateTo(
      _left,
      left,
      following
          ? MiuixGlassMotion.navDragFollow
          : MiuixGlassMotion.edgeSpring(!rightwards),
    );
    _animateTo(
      _right,
      right,
      following
          ? MiuixGlassMotion.navDragFollow
          : MiuixGlassMotion.edgeSpring(rightwards),
    );
  }

  /// 等价于包里未导出的 `animateGlassTo`。
  void _animateTo(
    AnimationController controller,
    double target,
    SpringDescription spring,
  ) {
    if (_disabledMotion) {
      controller.value = target;
      return;
    }
    controller.animateWith(
      SpringSimulation(spring, controller.value, target, controller.velocity),
    );
  }

  @override
  void didUpdateWidget(MiuixLiquidGlassNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      _timer?.cancel();
      void run() {
        if (mounted) {
          _animateTo(_show, widget.visible ? 1 : 0, MiuixGlassMotion.navShowHide);
        }
      }

      if (widget.visible && !_disabledMotion) {
        _timer = Timer(MiuixGlassMotion.navShowDelay, run);
      } else {
        run();
      }
      if (!widget.visible) {
        _pointer = null;
        _pressed = -1;
      }
    }
    if (oldWidget.items.length != widget.items.length) {
      _positioned = false;
      _pointer = null;
      _pressed = -1;
    }
    if (oldWidget.pageController != widget.pageController) {
      oldWidget.pageController?.removeListener(_onPageScroll);
      widget.pageController?.addListener(_onPageScroll);
    }
    if (oldWidget.selectedIndex != widget.selectedIndex &&
        _pointer == null &&
        _width > 0 &&
        !_isAnimatingFromTap) {
      final isDragging = widget.pageController?.hasClients == true &&
          widget.pageController!.position.userScrollDirection != ScrollDirection.idle;
      if (!isDragging) {
        _move(leftOf(_index), leftOf(_index) + _slot + 10);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _animatingFromTapTimer?.cancel();
    widget.pageController?.removeListener(_onPageScroll);
    _pointer = null;
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  double _x(Offset global) =>
      (_key.currentContext!.findRenderObject() as RenderBox)
          .globalToLocal(global)
          .dx;

  int _item(double x) {
    final raw = ((x - 8) / math.max(_slot, .01)).floor().clamp(
      0,
      widget.items.length - 1,
    );
    return _rtl ? widget.items.length - 1 - raw : raw;
  }

  void _release() {
    if (_pointer == null) return;
    setState(() {
      _pointer = null;
      _pressed = -1;
    });
    _move(leftOf(_index), leftOf(_index) + _slot + 10);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final theme = MiuixTheme.of(context);
    final dark = theme.colors.background.computeLuminance() < .5;
    final fontSize = MediaQuery.textScalerOf(context).scale(1) >= 1.6
        ? 16.0
        : 11.0;
    final pressed = _pressed >= 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : widget.items.length * 80.0;
        if (_width != width || !_positioned) {
          _width = width;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || widget.items.isEmpty) return;
            if (!_positioned) {
              _left.value = leftOf(_index);
              _right.value = leftOf(_index) + _slot + 10;
              _positioned = true;
            } else {
              _move(leftOf(_index), leftOf(_index) + _slot + 10);
            }
          });
        }
        return AnimatedBuilder(
          animation: Listenable.merge([_show, _left, _right]),
          builder: (context, _) {
            final progress = _show.value.clamp(0.0, 1.0);
            if (!widget.visible && progress < .001) {
              return SizedBox(width: width, height: widget.height + widget.bottomPadding);
            }
            final effectiveLeft = !_positioned ? leftOf(_index) : _left.value;
            final effectiveRight =
                !_positioned ? leftOf(_index) + _slot + 10 : _right.value;
            final bounds = miuixGlassNavigationIndicatorBounds(
              effectiveLeft,
              effectiveRight,
              width,
              3,
            );
            return IgnorePointer(
              ignoring: !widget.visible,
              child: ExcludeSemantics(
                excluding: !widget.visible,
                child: Opacity(
                  opacity: progress,
                  child: Transform.scale(
                    scale: .6 + .4 * progress,
                    child: ImageFiltered(
                      enabled: progress < .999,
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: (1 - progress) * 18,
                        sigmaY: (1 - progress) * 18,
                      ),
                      child: SizedBox(
                        width: width,
                        height: widget.height + widget.bottomPadding,
                        child: Listener(
                          key: _key,
                          onPointerDown: (event) {
                            if (_pointer != null) return;
                            _pointer = event.pointer;
                            _lastX = _x(event.position);
                            setState(() => _pressed = _item(_lastX));
                            _select(_pressed);
                          },
                          onPointerMove: (event) {
                            if (_pointer != event.pointer) return;
                            final x = _x(event.position),
                                index = _item(x),
                                changed = index != _pressed;
                            final target = miuixGlassNavigationDragTarget(
                              left: changed
                                  ? leftOf(index)
                                  : x - (_slot + 10) / 2,
                              width: _slot + 10,
                              containerWidth: width,
                              delta: x - _lastX,
                              changedItem: changed,
                              devicePixelRatio: MediaQuery.devicePixelRatioOf(
                                context,
                              ),
                            );
                            _move(
                              target.left,
                              target.right,
                              following: target.following,
                              movingRight: target.movingRight,
                            );
                            _lastX = x;
                            if (changed) {
                              setState(() => _pressed = index);
                              widget.onSelect(index);
                            }
                          },
                          onPointerUp: (e) {
                            if (_pointer == e.pointer) _release();
                          },
                          onPointerCancel: (e) {
                            if (_pointer == e.pointer) _release();
                          },
                          child: _buildShell(
                            context,
                            dark: dark,
                            layers: [
                              // ★ 选中区域：一层独立叠加的玻璃
                              //   （位置与外壳对齐、画在导航项之下；它自己的
                              //    `BackdropFilter` 读到的是「屏幕内容 + 外壳玻璃」，
                              //    所以选中项真的有独立的模糊与边缘高光，
                              //    而不是一块纯色 —— 详见 _buildIndicator）
                              Positioned(
                                left: bounds.dx,
                                right: math.max(0, width - bounds.dy),
                                top: 3,
                                bottom: 3 + widget.bottomPadding,
                                child: _buildIndicator(
                                  context,
                                  dark: dark,
                                  pressed: pressed,
                                ),
                              ),
                              // 导航项（画在最上层）
                              Positioned(
                                left: 0,
                                right: 0,
                                top: 0,
                                bottom: widget.bottomPadding,
                                child: SizedBox(
                                  height: widget.height,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        for (
                                          var i = 0;
                                          i < widget.items.length;
                                          i++
                                        )
                                          Expanded(
                                            child: _NavItemInteractive(
                                              selected: i == _index,
                                              label: widget
                                                  .items[i]
                                                  .contentDescription,
                                              onTap: () {
                                                if (widget.visible &&
                                                    i != _index) {
                                                  _select(i);
                                                }
                                              },
                                              builder:
                                                  (
                                                    context,
                                                    itemPressed,
                                                    focused,
                                                  ) {
                                                final tint =
                                                    (i == _index
                                                        ? widget
                                                              .selectedColor
                                                        : widget
                                                              .unselectedColor) ??
                                                    (i == _index
                                                        ? theme.colors.onSurfaceContainer
                                                        : theme.colors.onSurfaceContainer.withValues(alpha: 0.45));
                                                return _buildItem(
                                                  item: widget.items[i],
                                                  tint: tint,
                                                  focused: focused,
                                                  dimmed: _pressed == i,
                                                  fontSize: fontSize,
                                                  primary:
                                                      theme.colors.primary,
                                                  selected: i == _index,
                                                );
                                                  },
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 玻璃外壳：`ClipRRect` + `BackdropFilter` + 半透明色调 + 描边 + 外阴影。
  ///
  /// 与顶栏（`miuix_top_app_bar.dart:1097-1124`）**同一套机制、同一套参数**，
  /// 所以底栏和顶栏是「同一种玻璃」。
  ///
  /// 层级顺序很关键，三层各司其职：
  ///
  /// ```
  /// DecoratedBox(阴影)          ← 必须在 ClipRRect **外面**，否则阴影被裁掉
  ///  └ ClipRRect(圆角)
  ///     └ Stack
  ///        ├ BackdropFilter ← 背景玻璃层（唯一的「实时采样屏幕像素」入口）
  ///        ├ layers[0]      ← 选中指示器（自己也有 BackdropFilter）
  ///        └ layers[1]      ← 导航项（画在最上）
  /// ```
  ///
  /// ⚠️ 指示器为什么必须与背景玻璃**并列**、而不能嵌在它的 child 里：
  /// `BackdropFilter` 在实现上是「saveLayer 一个空图层，把**当前画布上已绘制的内容**
  /// 作为 backdrop 输入」。若指示器嵌在背景玻璃的 child 中，它读到的就是那个
  /// **刚创建、几乎空白的图层**（里面只有一层纯色调），糊一个均匀色块等于没糊 ——
  /// 嵌套 `BackdropFilter` 会静默失效。
  /// 放进同一个 `Stack` 做并列兄弟，指示器读到的才是
  /// 「屏幕内容 + 背景玻璃」的合成结果，二次模糊才真正生效。
  Widget _buildShell(
    BuildContext context, {
    required bool dark,
    required List<Widget> layers,
  }) {
    final borderRadius = BorderRadius.circular(_radius);
    final stroke = widget.stroke ?? MiuixGlassStrokes.forTheme(dark);
    // 色调与顶栏一致：colors.surface @ blurTintAlpha。
    // 再叠一层极淡的亮面（近似 Miuix 玻璃材质里的 softLight / overlay 层），
    // 让玻璃不至于在深色背景上显得比原版更闷。
    final theme = MiuixTheme.of(context);
    final tint = theme.colors.surface.withValues(
      alpha: (widget.blurTintAlpha * widget.alpha).clamp(0.0, 1.0),
    );
    final sheen = Colors.white.withValues(
      alpha: (dark ? .04 : .12) * widget.alpha,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: _boxShadows(widget.shadow),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tint,
                    borderRadius: borderRadius,
                    border: Border.all(
                      color: stroke.color,
                      width: stroke.width,
                    ),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: sheen),
                  ),
                ),
              ),
            ),
            ...layers,
          ],
        ),
      ),
    );
  }

  /// 把 Miuix 的 `MiuixGlassShadow` 翻译成 Flutter 原生 `BoxShadow`。
  ///
  /// 源端 `offsetX/offsetY/radius` 的单位是**源端像素**，绘制时要除以
  /// `sourceDensity = 3`（见 `miuix_glass_decoration.dart` 的类注释），
  /// 这里照做，保证悬浮高度与原版观感一致。
  List<BoxShadow> _boxShadows(MiuixGlassShadow? shadow) {
    if (shadow == null) return const [];
    if (shadow.radius <= 0 && shadow.offsetX == 0 && shadow.offsetY == 0) {
      return const [];
    }
    return [
      BoxShadow(
        color: shadow.color,
        offset: Offset(shadow.offsetX / 3, shadow.offsetY / 3),
        blurRadius: math.max(shadow.radius / 3, 0),
      ),
    ];
  }

  /// 选中区域的玻璃指示器。
  ///
  /// 三层叠起来：
  ///   1. 自己的一次 `BackdropFilter` —— 它读到的是「屏幕内容 + 外壳玻璃」的合成
  ///      结果（因为它与外壳玻璃是 `Stack` 里的并列兄弟，见 [_buildShell]），
  ///      于是选中区比底栏本体更磨砂；
  ///   2. 更亮的色调层（深色底用白、浅色底用黑），按下时透明度随弹簧抬升；
  ///   3. 描边（宽度与亮度都随按压提亮）→ 边缘高光变化。
  ///
  /// 整块用 `MiuixGlassMotion.pressScale` 缩放，由 `navPressEnter` /
  /// `navPressExit` 两条弹簧驱动，松手平滑回弹。
  Widget _buildIndicator(
    BuildContext context, {
    required bool dark,
    required bool pressed,
  }) {
    // 指示器高度 = 底栏高 - 上下各 3 的 inset
    final shorterSide = math.max(widget.height - 6, 1.0);
    final restScale = MiuixGlassMotion.pressScale(shorterSide);
    final baseStroke = widget.stroke ?? MiuixGlassStrokes.forTheme(dark);
    final borderRadius = BorderRadius.circular(999);

    return _MiuixSpringValue(
      value: pressed ? 1.0 : 0.0,
      spring: pressed
          ? MiuixGlassMotion.navPressEnter
          : MiuixGlassMotion.navPressExit,
      builder: (context, t) {
        // 从 1.0 弹簧过渡到 Miuix 规范的按压缩放值
        final scale = 1.0 + (restScale - 1.0) * t;
        final rim = _pressedStroke(baseStroke, t);
        return Transform.scale(
          scale: scale,
          child: ClipRRect(
            borderRadius: borderRadius,
            child: BackdropFilter(
              // 它糊的是「已经糊过的外壳」，所以强度只需要外壳的六成
              filter: ui.ImageFilter.blur(
                sigmaX: _sigma * .6,
                sigmaY: _sigma * .6,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: borderRadius,
                  border: Border.all(color: rim.color, width: rim.width),
                  // 按下高光：深色底用白、浅色底用黑。
                  // alpha 逐值对齐 Miuix 原版 `MiuixGlassNavigationBar`：
                  //   neutral.withValues(alpha: dark ? .12 : .06)   ← 静止
                  //   neutral.withValues(alpha: dark ? .26 : .16)   ← 按下
                  // 这里写成 base + delta * t 的形式，由弹簧 t 驱动过渡。
                  color: (dark ? Colors.white : Colors.black).withValues(
                    alpha:
                        ((dark ? .12 : .06) + (dark ? .14 : .10) * t) *
                        widget.alpha,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 按压时把描边「提亮 + 加粗」，制造玻璃边缘被压出高光的观感。
  MiuixGlassStroke _pressedStroke(MiuixGlassStroke base, double t) {
    if (t <= 0) return base;
    Color lift(Color c, double amount) => c.withValues(
      alpha: (c.a + (1 - c.a) * amount * t).clamp(0.0, 1.0),
    );
    return MiuixGlassStroke(
      width: base.width * (1 + .6 * t),
      bevel: base.bevel,
      color: lift(base.color, .5),
      primary: MiuixGlassStrokeLight(
        base.primary.x,
        base.primary.y,
        base.primary.z,
        lift(base.primary.color, .45),
      ),
      secondary: MiuixGlassStrokeLight(
        base.secondary.x,
        base.secondary.y,
        base.secondary.z,
        lift(base.secondary.color, .35),
      ),
    );
  }

  Widget _buildItem({
    required MiuixLiquidGlassNavItem item,
    required Color tint,
    required bool focused,
    required bool dimmed,
    required double fontSize,
    required Color primary,
    required bool selected,
  }) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: StadiumBorder(
          side: focused
              ? BorderSide(color: primary, width: 2)
              : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
        child: Opacity(
          opacity: dimmed ? .6 : 1,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox.square(
                dimension: 26,
                child: MiuixContentColor(
                  color: tint,
                  child: IconTheme.merge(
                    data: IconThemeData(color: tint, size: 26),
                    child: item.icon,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              if (item.label != null)
                Text(
                  item.label!,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontSize: fontSize,
                    color: tint,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    height: 1.2,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 用 Miuix 的弹簧参数驱动一个标量进度。
///
/// 包里同款是 `GlassSpringBuilder`（`glass/internal/animation.dart`，**未导出**），
/// 这里用同样公开的 `SpringDescription` 自己驱动；弹簧本身仍取自
/// [MiuixGlassMotion]，所以手感和 Miuix 其它组件一致。
class _MiuixSpringValue extends StatefulWidget {
  const _MiuixSpringValue({
    required this.value,
    required this.spring,
    required this.builder,
  });

  final double value;
  final SpringDescription spring;
  final Widget Function(BuildContext context, double value) builder;

  @override
  State<_MiuixSpringValue> createState() => _MiuixSpringValueState();
}

class _MiuixSpringValueState extends State<_MiuixSpringValue>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
    value: widget.value,
  );

  @override
  void didUpdateWidget(_MiuixSpringValue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _controller.value = widget.value;
      return;
    }
    _controller.animateWith(
      SpringSimulation(
        widget.spring,
        _controller.value,
        widget.value,
        _controller.velocity,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => widget.builder(context, _controller.value),
  );
}

/// 单个导航项的按压 / 焦点包装。
///
/// 包里同款是 `GlassInteractive`（`glass/internal/interactive.dart`，**未导出**），
/// 这里重写一份等价的最小实现：无障碍语义 + 无涟漪按压 + 键盘激活 + 焦点高亮。
class _NavItemInteractive extends StatefulWidget {
  const _NavItemInteractive({
    required this.onTap,
    required this.builder,
    this.selected,
    this.label,
  });

  final VoidCallback? onTap;
  final Widget Function(BuildContext context, bool pressed, bool focused) builder;
  final bool? selected;
  final String? label;

  @override
  State<_NavItemInteractive> createState() => _NavItemInteractiveState();
}

class _NavItemInteractiveState extends State<_NavItemInteractive> {
  bool _pressed = false, _focused = false;

  @override
  void didUpdateWidget(_NavItemInteractive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onTap == null) _pressed = false;
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: widget.onTap != null,
    selected: widget.selected,
    inMutuallyExclusiveGroup: widget.selected != null,
    label: widget.label,
    child: FocusableActionDetector(
      enabled: widget.onTap != null,
      mouseCursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: widget.onTap == null
            ? null
            : (_) => setState(() => _pressed = true),
        onTapUp: widget.onTap == null
            ? null
            : (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: widget.builder(context, _pressed, _focused),
      ),
    ),
  );
}
