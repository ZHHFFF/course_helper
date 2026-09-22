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
// 【2026-09-22：按 KernelSU 的 `FloatingBottomBar` 重做观感】
//
// 用户指令「顶栏和底栏都按 kernelsu 的来」。KernelSU 的悬浮底栏
// （`refs/kernelsu/FloatingBottomBar.kt`，Adapted from compose-miuix-ui 官方
// example `IosLiquidGlassNavigationBar`）用的是 Miuix KMP 的 `LayerBackdrop`，
// 录的是 `GraphicsLayer`（**绘制指令**），且在 `DrawModifierNode.draw()` 这条
// 绘制链的必经之路上录制 —— 所以滚动时每帧都重录，**不会被重绘边界截断**。
// Flutter 侧没有等价物（只有 `toImageSync()` 位图，见上），所以：
//
//   → **机制继续用 `BackdropFilter`**（合成器求值、与重绘边界无关、零延迟），
//     只把 KernelSU 的**参数与设计**搬过来。
//
// 搬过来的（常量全部集中在 `miuix_glass_spec.dart`）：
//   1. **双层几何**：外壳 64dp + 内容层 56dp + 上下 inset 4dp；
//   2. **vibrancy()**：`saturation = 1.5`，用 `ImageFilter.compose` 叠在模糊外层
//      （`ColorFilter implements ImageFilter`，可直接塞进 `BackdropFilter`）；
//   3. **色调**：`containerColor = surfaceContainer @ .4`（不是顶栏的 `surface @ .87`）
//      —— 只挡 40%，所以能透出 60% 背景，vibrancy 在这里才看得出来；
//   4. **模糊更轻**：KernelSU 是 `blur(4.dp)`（像素），dpr 3.5 → sigma 6.3，
//      约顶栏（11.25）的一半；
//   5. **按压反馈**：外壳 `lerp(1, 1 + 16px/width, press)` 微微放大，
//      选中 pill `pressedScale = 78/56 ≈ 1.39` 放大，图标 `lerp(1, 1.2, press)`；
//   6. **选中 pill 按下变淡**：`黑/白 @ .1 × (1 − press)` + `黑 @ .03 × press`
//      （⚠️ 与包里 `MiuixGlassNavigationBar` 的「按下变亮」方向相反，按 KernelSU）；
//   7. **innerShadow**：`radius = 8dp × press`、`Black @ .15`、`alpha = press`；
//   8. **rubber band**：拖动越界时整条栏平移 `4dp × EaseOut(|fraction|)`，松手弹回；
//   9. **dropShadow**：`radius 10`、`Black @ .1(浅) / .2(深)`。
//
// 搬不过来的（已在注释处标明）：
//   - `lens()` 折射 + 色差 —— 需要 `ImageFilter.shader`（**仅 Impeller 可用**）；
//   - 幽灵层（`alpha(0f).layerBackdrop(tabsBackdrop)`）+ `CombinedBackdrop`
//     —— 需要 `GraphicsLayer` 录制，Flutter 无对应 API。KernelSU 靠它让选中 pill
//     里透出「放大 + 主色」的图标；这里改用 pill 自己的一次 `BackdropFilter`
//     作等价补偿（见 [_buildIndicator]）；
//   - 重力感应高光（`rememberDeviceTilt`）—— 需要加速度计。

// 用到的 Miuix 公开 API：
//   - `MiuixGlassMotion`   全部弹簧参数 + `pressScale`（按压缩放规范值）
//   - `MiuixGlassStroke(s)` 玻璃描边（含光照方向的 bloom 色）
//   - `MiuixGlassShadow(s)` 玻璃阴影预设（`floating` 等）
//   - `MiuixGlassShape`    圆角
//   - `MiuixGlassMotion`   全部弹簧参数 + `springOf(damping, response)`
//   - `miuixGlassNavigationDragTarget` / `miuixGlassNavigationIndicatorBounds`
//                          跨项拖动几何（跟手拉伸上限 60 物理像素）
//
// ⚠️ 包里 `GlassSpringBuilder` 与 `GlassInteractive` 在 `glass/internal/` 下
// **没有导出**：
//   - 按压 / 拖动 / rubber band 的弹簧改由本组件的 `AnimationController` +
//     `SpringSimulation` 直接驱动（见 `_animateTo` / `_setPress`），
//     弹簧参数仍取自 `MiuixGlassMotion`，手感与 Miuix 其它组件一致；
//   - 导航项交互用自写的 [_NavItemInteractive]。
// ============================================================================

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_miuix/miuix.dart';

import 'miuix_glass_spec.dart';

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
  });

  final List<MiuixLiquidGlassNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// 玻璃整体的不透明度倍率（同时作用于模糊与色调层）。
  final double alpha;
  final bool visible;
  final double height;

  /// 模糊半径（dp）。默认 [MiuixGlassSpec.navBlurRadius] = 14（KernelSU 口径）。
  ///
  /// 实际 sigma = `blurRadius * 0.45`（顶栏同款换算），所以 14 → **6.3**，
  /// 约顶栏（25 → 11.25）的一半 —— KernelSU 的悬浮胶囊就是「轻霜」而不是重磨砂。
  final double blurRadius;

  /// 模糊之上叠加的色调不透明度 [0,1]。
  /// 默认 [MiuixGlassSpec.navContainerAlpha] = .4（KernelSU `containerColor`）。
  final double blurTintAlpha;

  final MiuixGlassShape? shape;
  final MiuixGlassStroke? stroke;

  /// 外阴影。传 `null`（默认）用 KernelSU 口径的
  /// `dropShadow(radius = 10, Black @ .1/.2)`（见 [MiuixGlassSpec.navShadow]）；
  /// 传 `MiuixGlassShadow(radius: 0, color: Colors.transparent)` 可彻底关掉
  /// （贴边态用）。
  final MiuixGlassShadow? shadow;

  /// 选中 / 未选中项的图标与文字颜色（不传则用 `colors.onBackground`）。
  final Color? selectedColor, unselectedColor;

  @override
  State<MiuixLiquidGlassNavigationBar> createState() =>
      _MiuixLiquidGlassNavigationBarState();
}

class _MiuixLiquidGlassNavigationBarState
    extends State<MiuixLiquidGlassNavigationBar>
    with TickerProviderStateMixin {
  /// KernelSU `spring(1f, 300f, 0.5f)` 的等价物：阻尼比 1（临界阻尼），
  /// 刚度 300 → 响应 ≈ 2π/√300 ≈ .36s。用于 rubber band 回弹。
  static final _panelSpring = MiuixGlassMotion.springOf(1, .36);

  late final _show = AnimationController.unbounded(
    vsync: this,
    value: widget.visible ? 1 : 0,
  );
  late final _left = AnimationController.unbounded(vsync: this);
  late final _right = AnimationController.unbounded(vsync: this);

  /// 按压进度 0→1。对应 KernelSU 的 `DampedDragAnimation.pressProgress`，
  /// 驱动外壳放大 / pill 放大 / 图标放大 / pill 填充淡出 / innerShadow 加深。
  late final _press = AnimationController.unbounded(vsync: this);

  /// 整条栏的横向偏移（rubber band）。对应 KernelSU 的 `offsetAnimation`：
  /// 拖动时按 `dragAmount.dx` 累加，松手 `spring(1, 300, .5)` 弹回 0。
  late final _panel = AnimationController.unbounded(vsync: this);

  final _key = GlobalKey();
  final _controllers = <AnimationController>[];

  @override
  void initState() {
    super.initState();
    _controllers.addAll([_show, _left, _right, _press, _panel]);
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

  double leftOf(int index) =>
      8 + (_rtl ? widget.items.length - 1 - index : index) * _slot - 5;

  /// 外壳圆角：`shape` 不传时用胶囊（999）。
  double get _radius => widget.shape?.cornerRadius ?? 999;

  /// 模糊 sigma，换算系数与顶栏一致（`BLUR_RADIUS_TO_SIGMA = 0.45`）。
  double get _sigma => widget.blurRadius.clamp(0.0, 150.0) * 0.45;

  void _select(int index) {
    _move(leftOf(index), leftOf(index) + _slot);
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
        _press.value = 0;
        _panel.value = 0;
      }
    }
    if (oldWidget.items.length != widget.items.length) {
      _positioned = false;
      _pointer = null;
      _pressed = -1;
    }
    if (oldWidget.selectedIndex != widget.selectedIndex &&
        _pointer == null &&
        _width > 0) {
      _move(leftOf(_index), leftOf(_index) + _slot);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
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
    final raw =
        ((x - MiuixGlassSpec.navInset) / math.max(_slot, .01)).floor().clamp(
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
    _setPress(false);
    // KernelSU：松手后 `offsetAnimation.animateTo(0f, spring(1f, 300f, 0.5f))`
    // —— 阻尼比 1（临界阻尼）、刚度 300 → 响应 ≈ 2π/√300 ≈ 0.36s。
    _animateTo(_panel, 0, _panelSpring);
    _move(leftOf(_index), leftOf(_index) + _slot);
  }

  /// 按压进度弹簧。KernelSU 用 `DampedDragAnimation` 的 `pressProgress`，
  /// 这里用 Miuix 自己的 `navPressEnter` / `navPressExit` 驱动。
  void _setPress(bool down) {
    _animateTo(
      _press,
      down ? 1 : 0,
      down ? MiuixGlassMotion.navPressEnter : MiuixGlassMotion.navPressExit,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final theme = MiuixTheme.of(context);
    final dark = theme.colors.background.computeLuminance() < .5;
    final fontSize = MediaQuery.textScalerOf(context).scale(1) >= 1.6
        ? 16.0
        : 11.0;

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
              _right.value = leftOf(_index) + _slot;
              _positioned = true;
            } else {
              _move(leftOf(_index), leftOf(_index) + _slot);
            }
          });
        }
        return AnimatedBuilder(
          animation: Listenable.merge([_show, _left, _right, _press, _panel]),
          builder: (context, _) {
            final progress = _show.value.clamp(0.0, 1.0);
            if (!widget.visible && progress < .001) {
              return SizedBox(width: width, height: widget.height);
            }
            // KernelSU 的 `DampedDragAnimation.pressProgress`（0 → 1）。
            final press = _press.value.clamp(0.0, 1.0);
            // KernelSU 的 `panelOffset`（rubber band）：
            //   fraction = (offset / totalWidth).clamp(-1, 1)
            //   panelOffset = rubberBandPx * sign * EaseOut.transform(|fraction|)
            // 效果：拖过头时整条栏跟着挪一点，越界越拖不动，松手弹回。
            final fraction = width <= 0
                ? 0.0
                : (_panel.value / width).clamp(-1.0, 1.0);
            final panelOffset =
                MiuixGlassSpec.navRubberBand *
                (fraction < 0 ? -1.0 : 1.0) *
                Curves.easeOut.transform(fraction.abs());
            final bounds = miuixGlassNavigationIndicatorBounds(
              _left.value,
              _right.value,
              width,
              MiuixGlassSpec.navInset,
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
                        child: Listener(
                          key: _key,
                          onPointerDown: (event) {
                            if (_pointer != null) return;
                            _pointer = event.pointer;
                            _lastX = _x(event.position);
                            setState(() => _pressed = _item(_lastX));
                            _setPress(true);
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
                                  : x - _slot / 2,
                              width: _slot,
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
                            // KernelSU：`offsetAnimation.snapTo(value + dragAmount.x)`
                            // —— 整条栏跟着手指平移，越界部分由 [panelOffset] 的
                            //    rubber band 曲线吃掉。这里夹住累加值，避免越界
                            //    拖太久导致回弹行程过长。
                            _panel.value = (_panel.value + (x - _lastX)).clamp(
                              -width,
                              width,
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
                            width: width,
                            press: press,
                            panelOffset: panelOffset,
                            layers: [
                              // ★ 选中区域：一层独立叠加的玻璃
                              //   （位置与外壳对齐、画在导航项之下；它自己的
                              //    `BackdropFilter` 读到的是「屏幕内容 + 外壳玻璃」，
                              //    所以选中项真的有独立的模糊与边缘高光，
                              //    而不是一块纯色 —— 详见 _buildIndicator）
                              Positioned(
                                left: bounds.dx,
                                right: math.max(0, width - bounds.dy),
                                top: MiuixGlassSpec.navInset,
                                bottom: MiuixGlassSpec.navInset,
                                child: _buildIndicator(
                                  context,
                                  dark: dark,
                                  press: press,
                                ),
                              ),
                              // 导航项（画在最上层）
                              IntrinsicHeight(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: widget.height,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: MiuixGlassSpec.navInset,
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
                                                        theme
                                                            .colors
                                                            .onBackground;
                                                    return _buildItem(
                                                      item: widget.items[i],
                                                      tint: tint,
                                                      focused: focused,
                                                      // KernelSU 的
                                                      // `LocalFloatingBottomBarTabScale`
                                                      // 是 `lerp(1, 1.2, pressProgress)`，
                                                      // 作用在「幽灵层」上 —— 只有
                                                      // 选中 pill 里透出的那套图标会放大。
                                                      // 我们没有幽灵层，就直接把选中项
                                                      // 的图标放大，观感等价。
                                                      press: i == _index
                                                          ? press
                                                          : 0,
                                                      fontSize: fontSize,
                                                      primary:
                                                          theme.colors.primary,
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
    required double width,
    required double press,
    required double panelOffset,
    required List<Widget> layers,
  }) {
    final borderRadius = BorderRadius.circular(_radius);
    final stroke = widget.stroke ?? MiuixGlassStrokes.forTheme(dark);
    final theme = MiuixTheme.of(context);
    // 色调：KernelSU 的 `containerColor = surfaceContainer.copy(0.4f)`
    //   —— 注意底色是 **surfaceContainer** 而不是顶栏的 `surface`，且只有 40%。
    //   只挡 40% 才透得出 60% 背景，vibrancy（饱和度 1.5）在这里才看得出来。
    final tint = theme.colors.surfaceContainer.withValues(
      alpha: (widget.blurTintAlpha * widget.alpha).clamp(0.0, 1.0),
    );
    final sheen = Colors.white.withValues(
      alpha: (dark ? .04 : .12) * widget.alpha,
    );
    // KernelSU 的 `layerBlock`：
    //   lerp(1f, 1f + 16.dp.toPx() / width, pressProgress)
    // ⚠️ 16 是**像素**增量，所以放大比例随栏宽变化（313dp 栏宽时约 +5%）。
    final pressScale =
        1 +
        MiuixGlassSpec.navPressShellGrow / math.max(width, 1) *
            press.clamp(0.0, 1.0);

    return Transform.translate(
      // rubber band：拖动越界时整条栏跟着挪一点，松手弹回（KernelSU `panelOffset`）。
      offset: Offset(panelOffset, 0),
      child: Stack(
        // ⚠️ 必须 `Clip.none`：选中 pill 按压缩放到 `78/56 ≈ 1.39` 倍后会**溢出**外壳
        // （56dp → 78dp，而外壳只有 64dp），这正是 KernelSU 的「液态鼓起」效果。
        // 若让它待在外壳的 `ClipRRect` 里，鼓起会被裁成平口 —— 真机实测过：
        // 按下时 x=200（pill 处）与 x=1000（未按下处）的可见纵向范围完全一样
        // （都是 y 2452→2688），形变等于白做。
        clipBehavior: Clip.none,
        children: [
          // ① 玻璃外壳（按压时整条微放大 —— KernelSU 的 `layerBlock`）
          Positioned.fill(
            child: IgnorePointer(
              child: Transform.scale(
                scale: pressScale,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: borderRadius,
                    boxShadow: _boxShadows(dark),
                  ),
                  child: ClipRRect(
                    borderRadius: borderRadius,
                    child: BackdropFilter(
                      // ★ KernelSU 的 `vibrancy()` + `blur(4.dp)`：
                      //   先模糊、再提饱和（`ImageFilter.compose` 是 inner 先 outer 后）。
                      filter: MiuixGlassSpec.glassFilter(
                        blurRadius: widget.blurRadius,
                      ),
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
                ),
              ),
            ),
          ),
          // ② 选中 pill、③ 导航项（顺序即绘制顺序，导航项在最上）
          //
          // ⚠️ pill 必须与外壳做成**并列兄弟**，不能塞进外壳的 `child` / 内层 `Stack`：
          //   a. 进了外壳的 `ClipRRect` 就会被裁掉 → 按压缩放溢出看不见（见上）；
          //   b. `BackdropFilter` 读的是「当前画布上**已绘制**的内容」。① 先画，
          //      所以 pill 读到的仍是「屏幕内容 + 外壳玻璃」的合成结果；
          //      一旦嵌进 ① 的 child，它读到的就是 ① 刚建的空图层 → 静默失效。
          ...layers,
        ],
      ),
    );
  }

  /// 外阴影。
  ///
  /// - `shadow == null`（默认）→ **KernelSU 口径**：
  ///   `dropShadow(radius = 10, color = Black, alpha = .2(深) / .1(浅))`。
  ///   Compose 的 `Shadow.radius` 与 Flutter 的 `BoxShadow.blurRadius` 都近似
  ///   「高斯 sigma」，所以直接照搬，不走 Miuix 的 `/3`（那是源端像素口径）。
  /// - 传了 `MiuixGlassShadow` → 按 Miuix 口径翻译：源端 `offsetX/offsetY/radius`
  ///   的单位是**源端像素**，绘制时要除以 `sourceDensity = 3`
  ///   （见 `miuix_glass_decoration.dart` 的类注释）。
  List<BoxShadow> _boxShadows(bool dark) {
    final shadow = widget.shadow;
    if (shadow == null) return MiuixGlassSpec.navShadow(dark: dark);
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

  /// 选中区域的玻璃指示器（= KernelSU 的「选中 pill」）。
  ///
  /// 【为什么这里要自己补一次 `BackdropFilter`】
  /// KernelSU 的 pill 自己**不模糊**：它靠 `combinedBackdrop`
  /// （外壳 backdrop + 幽灵层 backdrop）做 `lens()` 折射，再用 `onDrawSurface`
  /// 画一层纯色。折射需要 `ImageFilter.shader`（**仅 Impeller**）、幽灵层需要
  /// `GraphicsLayer` 录制 —— 两者都搬不过来，所以这里给 pill **补一次自己的
  /// `BackdropFilter`** 作为等价补偿：它读到的是「屏幕内容 + 外壳玻璃」的合成
  /// 结果（与外壳玻璃是 `Stack` 里的并列兄弟，见 [_buildShell]），
  /// 于是选中区比底栏本体更磨砂。
  ///
  /// 其余逐值对齐 KernelSU：
  ///   - 填充：`黑/白 @ .1 × (1 − press)`，按下再**额外**叠 `黑 @ .03 × press`
  ///     （⚠️ 是**按下变淡**，与包里 `MiuixGlassNavigationBar` 的按下变亮相反）；
  ///   - 缩放：`pressedScale = 78/56 ≈ 1.39`（56 → 78，**放大**不是缩小）；
  ///   - 内阴影：`radius = 8dp × press`、`Black @ .15`、`alpha = press`，
  ///     且 `offset = (0, radius)` → 是**顶边偏重**的一圈内暗边；
  ///   - 描边随按压提亮加粗（[._pressedStroke]）。
  Widget _buildIndicator(
    BuildContext context, {
    required bool dark,
    required double press,
  }) {
    final t = press.clamp(0.0, 1.0);
    final scale = 1 + (MiuixGlassSpec.navPressScale - 1) * t;
    final baseStroke = widget.stroke ?? MiuixGlassStrokes.forTheme(dark);
    final rim = _pressedStroke(baseStroke, t);
    final radius = _radius;
    // KernelSU：`if (!isInDark) Color.Black else Color.White`，alpha = .1
    final neutral = dark ? Colors.white : Colors.black;

    return Transform.scale(
      scale: scale,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          // 它糊的是「已经糊过的外壳」，所以强度只需要外壳的六成
          filter: ui.ImageFilter.blur(
            sigmaX: _sigma * .6,
            sigmaY: _sigma * .6,
          ),
          child: CustomPaint(
            painter: _NavPillPainter(
              radius: radius,
              fill: neutral.withValues(
                alpha:
                    MiuixGlassSpec.navPillFillAlpha *
                    (1 - t) *
                    widget.alpha,
              ),
              pressFill: Colors.black.withValues(
                alpha:
                    MiuixGlassSpec.navPillPressFillAlpha * t * widget.alpha,
              ),
              innerShadow: Colors.black.withValues(
                alpha:
                    MiuixGlassSpec.navPillInnerShadowAlpha * t * widget.alpha,
              ),
              innerShadowRadius: MiuixGlassSpec.navPillInnerShadowRadius * t,
              stroke: rim.color,
              strokeWidth: rim.width,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
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
    required double press,
    required double fontSize,
    required Color primary,
  }) {
    // KernelSU 的 `LocalFloatingBottomBarTabScale = lerp(1f, 1.2f, pressProgress)`。
    final iconScale =
        1 +
        (MiuixGlassSpec.navPressIconScale - 1) * press.clamp(0.0, 1.0);

    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: StadiumBorder(
          side: focused
              ? BorderSide(color: primary, width: 2)
              : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Transform.scale(
              scale: iconScale,
              child: SizedBox.square(
                dimension: 28,
                child: MiuixContentColor(
                  color: tint,
                  child: IconTheme.merge(
                    data: IconThemeData(color: tint, size: 28),
                    child: item.icon,
                  ),
                ),
              ),
            ),
            if (item.label != null)
              Text(
                item.label!,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                textScaler: TextScaler.noScaling,
                style: TextStyle(fontSize: fontSize, color: tint, height: 1.2),
              ),
          ],
        ),
      ),
    );
  }
}

/// 画 KernelSU 选中 pill 的填充、按下叠色、描边与内阴影。
///
/// KernelSU 里这是两段独立的绘制：
/// ```kotlin
/// onDrawSurface = {
///     drawRect(color = 黑/白, alpha = 0.1f * (1f - pressProgress))
///     drawRect(Color.Black.copy(alpha = 0.03f * pressProgress))
/// }
/// .innerShadow(shape = pillShape) {
///     InnerShadow(radius = 8.dp * pressProgress,
///                 color = Color.Black.copy(alpha = 0.15f),
///                 alpha = pressProgress)
/// }
/// ```
///
/// 内阴影的几何：`InnerShadow` 的默认 `offset = (0, radius)`，实现是
/// 「圆角矩形 − 下移 radius 的圆角矩形」= **顶边一条月牙**，再按 radius 模糊、
/// 最后裁回形状内。这里用 `PathFillType.evenOdd` 同时加两个圆角矩形取 XOR
/// 得到同一条月牙（比 `Path.combine` 便宜），底部那半会被 `clipRRect` 裁掉。
///
/// ⚠️ Flutter 没有 CSS 的 `inset box-shadow`，内阴影只能自己描边加模糊
/// （项目里同类坑见 MEMORY「其它技术坑」）。
class _NavPillPainter extends CustomPainter {
  const _NavPillPainter({
    required this.radius,
    required this.fill,
    required this.pressFill,
    required this.innerShadow,
    required this.innerShadowRadius,
    required this.stroke,
    required this.strokeWidth,
  });

  final double radius, innerShadowRadius, strokeWidth;
  final Color fill, pressFill, innerShadow, stroke;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final r = math.min(radius, size.shortestSide / 2);
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(r));

    if (fill.a > 0) canvas.drawRRect(rrect, Paint()..color = fill);
    if (pressFill.a > 0) {
      canvas.drawRRect(rrect, Paint()..color = pressFill);
    }
    if (strokeWidth > 0 && stroke.a > 0) {
      canvas.drawRRect(
        rrect.deflate(strokeWidth / 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = stroke,
      );
    }
    if (innerShadowRadius > 0 && innerShadow.a > 0) {
      final crescent = Path()
        ..fillType = PathFillType.evenOdd
        ..addRRect(rrect)
        ..addRRect(rrect.shift(Offset(0, innerShadowRadius)));
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawPath(
        crescent,
        Paint()
          ..color = innerShadow
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            innerShadowRadius * .5,
          ),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_NavPillPainter old) =>
      radius != old.radius ||
      fill != old.fill ||
      pressFill != old.pressFill ||
      innerShadow != old.innerShadow ||
      innerShadowRadius != old.innerShadowRadius ||
      stroke != old.stroke ||
      strokeWidth != old.strokeWidth;
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
