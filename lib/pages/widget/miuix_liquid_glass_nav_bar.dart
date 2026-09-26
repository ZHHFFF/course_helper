// ============================================================================
// 液态玻璃底栏（Kyant0 / AndroidLiquidGlass 核心移植版）
// ============================================================================
//
// 移植自 Kyant0/AndroidLiquidGlass 与 KernelSU (FloatingBottomBar.kt / Lens.kt / InnerShadow.kt / Vibrancy.kt):
// 1. 实时全向双层采样（Dual-Layer BackdropFilter）：
//    外壳采样屏幕内容，选中指示器作为并列同级二次采样，零帧延迟，背景滚动实时响应。
// 2. Kyant0 Vibrancy 饱和度矩阵（Vibrancy.kt）：
//    +35% 色彩反差与饱和增强，穿透玻璃呈现透亮晶莹感。
// 3. 动态外向膨胀与水滴挤压形变（Squash & Stretch）：
//    按压时胶囊不缩小，而是向外自然放大膨胀至 1.30x（Kyant0 pressedScale = 78/56）。
//    拖动过程中根据实时滑动速度（_dragVelocity）动态形变：
//      scaleX /= 1.0 - (vel * 0.75)
//      scaleY *= 1.0 - (|vel| * 0.35)
//    产生真实液态水滴横向拉伸、纵向微缩的流体视觉。
// 4. 零延迟即时跟手与物理阻尼（DampedDragAnimation）：
//    手势拖动直接驱动指示器坐标（无慢半拍滞后），超出边缘施加 EaseOut 阻尼弹性；
//    松手后由物理弹簧（mass: 1.0, stiffness: 300, damping: 24）平滑回弹。
// 5. 光学双峰高光、内阴影凹陷与微弱色散边缘（Specular Bloom & Lens & InnerShadow）：
//    - iosIndicatorSpecular 双峰镜面高光（Dual-Peak Rim）；
//    - InnerShadow 动态凹陷内阴影；
//    - 次像素微弱色散边缘（Chromatic Aberration），提供纯正玻璃折射厚度感。
// ============================================================================

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_miuix/miuix.dart';

import 'liquid_glass_highlight.dart';
import 'liquid_glass_nav_controller.dart';
import 'liquid_glass_rim_highlight.dart';
import 'liquid_glass_shader_filter.dart';

/// 与 [MiuixGlassNavigationItem] 同名入参类型，保持完全兼容。
typedef MiuixLiquidGlassNavItem = MiuixGlassNavigationItem;

/// Kyant0 液态玻璃底栏
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

  /// 玻璃整体不透明度倍率
  final double alpha;
  final bool visible;
  final double height;

  /// 模糊半径（dp）
  final double blurRadius;

  /// 模糊之上叠加的色调不透明度 [0,1]
  final double blurTintAlpha;

  final MiuixGlassShape? shape;
  final MiuixGlassStroke? stroke;
  final MiuixGlassShadow? shadow;

  /// 选中 / 未选中项的图标与文字颜色
  final Color? selectedColor, unselectedColor;

  /// 底部手势安全区内边距
  final double bottomPadding;

  /// 页面滑动控制器（联动左右滑动切换与指示器平滑跟随）
  final PageController? pageController;

  @override
  State<MiuixLiquidGlassNavigationBar> createState() =>
      _MiuixLiquidGlassNavigationBarState();
}

class _MiuixLiquidGlassNavigationBarState
    extends State<MiuixLiquidGlassNavigationBar>
    with TickerProviderStateMixin {
  /// 交互控制器：指针跟踪 + 位置/按压弹簧 + 选中收敛
  /// （原实现把这些散落在 State 里，现已抽到 liquid_glass_nav_controller.dart）
  late final LiquidGlassNavController _nav = LiquidGlassNavController(
    vsync: this,
    itemCount: widget.items.length,
    initialIndex: widget.selectedIndex,
    visible: widget.visible,
    onSelect: (i) => widget.onSelect(i),
    onPointerStateChanged: () {
      if (mounted) setState(() {});
    },
  );

  final _key = GlobalKey();

  double _width = 0.0;

  /// 上一帧的指针 x（上游 `canDrag` 需要同时判断当前与上一帧是否在栏内）
  double _lastPointerX = 0.0;

  // ── 只读转发：视觉层（build）从这里取动画值与手势状态 ────────────────
  bool get _positioned => _nav.positioned;

  bool get _disabledMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  int get _index => widget.items.isEmpty
      ? 0
      : widget.selectedIndex.clamp(0, widget.items.length - 1);

  double get _tabWidth {
    if (widget.items.isEmpty || _width <= 16) return 0.0;
    return (_width - 16) / widget.items.length;
  }

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  double get _sigma => widget.blurRadius.clamp(0.0, 150.0) * 0.45;

  /// 外壳玻璃的折射滤镜持有者（Impeller 下产出真实折射，否则恒为 null）
  final _shellGlass = LiquidGlassRefraction();

  /// 选中指示器玻璃的折射滤镜持有者
  ///
  /// ⚠️ 必须与外壳**分开持有** —— `FragmentShader` 带 uniform 状态，
  /// 共用同一实例会导致两者在同帧互相覆盖参数。
  final _indicatorGlass = LiquidGlassRefraction();

  /// 外壳高光 shader 持有者（上游 `drawBackdrop` 的 `highlight` 默认值是
  /// `Highlight.Default`，所以**外壳也有高光，且 alpha = 1**）
  final _shellHighlight = LiquidGlassRimHighlightShader();

  /// 指示器高光 shader 持有者（上游传 `Highlight.Default.copy(alpha = progress)`）
  final _indicatorHighlight = LiquidGlassRimHighlightShader();

  @override
  void initState() {
    super.initState();
    // 异步加载 shader program（幂等）。就绪前底栏走降级模糊，就绪后自动切换。
    LiquidGlassShaderLibrary.initialize();
    widget.pageController?.addListener(_onPageScroll);
  }

  @override
  void didUpdateWidget(MiuixLiquidGlassNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.visible != widget.visible) {
      _nav.setVisible(widget.visible);
    }
    if (oldWidget.items.length != widget.items.length) {
      _nav.itemCount = widget.items.length;
      _nav.resetForItemCountChange();
    }
    if (oldWidget.pageController != widget.pageController) {
      oldWidget.pageController?.removeListener(_onPageScroll);
      widget.pageController?.addListener(_onPageScroll);
    }
    if (oldWidget.selectedIndex != widget.selectedIndex &&
        !_nav.isDragging &&
        _width > 0 &&
        !_nav.isAnimatingFromTap) {
      final isDragging = widget.pageController?.hasClients == true &&
          widget.pageController!.position.userScrollDirection !=
              ScrollDirection.idle;
      if (!isDragging) {
        _nav.updateSelectedIndex(widget.selectedIndex);
        _nav.updateValue(widget.selectedIndex.toDouble());
      }
    }
  }

  @override
  void dispose() {
    widget.pageController?.removeListener(_onPageScroll);
    _shellGlass.dispose();
    _indicatorGlass.dispose();
    _shellHighlight.dispose();
    _indicatorHighlight.dispose();
    _nav.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    if (widget.pageController == null || !widget.pageController!.hasClients) {
      return;
    }
    if (_nav.isDragging) return;
    if (_nav.isAnimatingFromTap) {
      if (widget.pageController!.position.userScrollDirection !=
          ScrollDirection.idle) {
        _nav.cancelTapAnimation();
      } else {
        return;
      }
    }
    final page = widget.pageController!.page;
    if (page != null && _width > 0) {
      _nav.syncFromPage(page);
    }
  }

  // ── 交互：全部委托给 LiquidGlassNavController ──────────────────────────

  RenderBox? get _barBox =>
      _key.currentContext?.findRenderObject() as RenderBox?;

  /// 点击底栏（用于 `onTap` 路径）—— 对应上游 `activateTab` → `animateToValue`
  void _select(int index) => _nav.animateToValue(index.toDouble());

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    // ⚠️ 折射着色器是**异步**加载的。必须监听就绪事件并在就绪后重建 ——
    // 否则底栏会永远停在降级模糊路径（实机 A/B 验证发现：不监听时
    // 有/无 shader 两个版本的像素完全一致，即 shader 从未生效）。
    return ValueListenableBuilder<bool>(
      valueListenable: LiquidGlassShaderLibrary.ready,
      builder: (context, isReady, child) => _buildBar(context),
    );
  }

  Widget _buildBar(BuildContext context) {
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

        // 把布局相关的几何量同步给控制器 —— 手势的「跟手换算」依赖它们。
        // 控制器不碰布局，只消费这里算好的值。
        _nav.barWidth = width;
        _nav.syncGeometry(
          tabWidth: widget.items.isEmpty
              ? 0.0
              : (width - 16) / widget.items.length,
          barWidth: width,
          rtl: _rtl,
        );
        _nav.disabledMotion = _disabledMotion;

        if (_width != width || !_positioned) {
          _width = width;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || widget.items.isEmpty) return;
            _nav.placeAt(_nav.index);
            _nav.positioned = true;
          });
        }

        return AnimatedBuilder(
          // 六个动画（位置/速度/按压/scaleX/scaleY/显示）统一由控制器合并暴露
          animation: _nav.animatables,
          builder: (context, _) {
            final showProgress = _nav.showProgress.clamp(0.0, 1.0);
            if (!widget.visible && showProgress < .001) {
              return SizedBox(
                width: width,
                height: widget.height + widget.bottomPadding,
              );
            }

            final pressProgress = _nav.pressProgress.clamp(0.0, 1.0);
            final posValue = _nav.value;
            final tabW = _tabWidth;

            // 橡皮筋阻尼计算（Kyant0 EaseOut transform）
            double rubberBand = 0.0;
            if (posValue < 0.0) {
              final frac = (-posValue).clamp(0.0, 1.0);
              rubberBand = -4.0 * (1.0 - (1.0 - frac) * (1.0 - frac));
            } else if (posValue > widget.items.length - 1) {
              final frac = (posValue - (widget.items.length - 1)).clamp(0.0, 1.0);
              rubberBand = 4.0 * (1.0 - (1.0 - frac) * (1.0 - frac));
            }

            // 指示器左侧像素坐标与宽度
            final indicatorLeft = _rtl
                ? 8 + (widget.items.length - 1 - posValue) * tabW + rubberBand
                : 8 + posValue * tabW + rubberBand;

            // 指示器几何 —— 严格对齐上游 Compose：
            //   栏高 64 / 指示器高 56 / 上下各留 4 → 两者天然同心
            //   （半径差 = 4 = 边距，所以边缘间隙处处相等）
            final indicatorHeight =
                math.max(1.0, widget.height - widget.bottomPadding - 8);
            const indicatorInset = 4.0;

            // Kyant0 呼吸外壳微缩放（lerp(1f, 1f + 16dp / width, pressProgress)）
            final shellScale = 1.0 + 0.012 * pressProgress;

            return IgnorePointer(
              ignoring: !widget.visible,
              child: ExcludeSemantics(
                excluding: !widget.visible,
                child: Opacity(
                  opacity: showProgress,
                  child: Transform.scale(
                    scale: (.65 + .35 * showProgress) * shellScale,
                    child: ImageFiltered(
                      enabled: showProgress < .999,
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: (1 - showProgress) * 16,
                        sigmaY: (1 - showProgress) * 16,
                      ),
                      child: SizedBox(
                        width: width,
                        height: widget.height + widget.bottomPadding,
                        child: Listener(
                          key: _key,
                          // 手势全部转交控制器 —— 它内部负责指针校验、
                          // 速度采样、零延迟跟手与松手弹簧。
                          onPointerDown: (event) {
                            _lastPointerX = _nav.localX(event.position, _barBox);
                            _nav.handlePointerDown(
                              pointer: event.pointer,
                              x: _lastPointerX,
                            );
                          },
                          onPointerMove: (event) {
                            final x = _nav.localX(event.position, _barBox);
                            _nav.handlePointerMove(
                              pointer: event.pointer,
                              x: x,
                              previousX: _lastPointerX,
                            );
                            _lastPointerX = x;
                          },
                          onPointerUp: (event) =>
                              _nav.handlePointerUp(event.pointer),
                          onPointerCancel: (event) =>
                              _nav.handlePointerUp(event.pointer),
                          // 对应上游 Compose 外层 Box 的兄弟节点结构：
                          //   1. 外壳（背景玻璃，裁剪层止于此）
                          //   2. 选中指示器（与外壳并列 → 放大溢出不会被裁）
                          //   3. 图标与标签（最上层，保证清晰不被玻璃糊到）
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              // ── 1. 外壳：只画背景玻璃 ──────────────────────
                              Positioned.fill(
                                child: _buildShell(
                                  context,
                                  dark: dark,
                                  width: width,
                                  height: widget.height + widget.bottomPadding,
                                ),
                              ),

                              // ── 2. 选中指示器（不在外壳的 ClipRRect 内）─────
                              if (tabW > 0)
                                Positioned(
                                  left: indicatorLeft,
                                  top: indicatorInset,
                                  width: tabW,
                                  height: indicatorHeight,
                                  child: _buildLiquidIndicator(
                                    context,
                                    dark: dark,
                                    pressProgress: pressProgress,
                                    velocity: _nav.velocity,
                                    baseScaleX: _nav.scaleX,
                                    baseScaleY: _nav.scaleY,
                                    width: tabW,
                                    height: indicatorHeight,
                                  ),
                                ),

                              // ── 3. 导航项图标与标签（顶层交互）────────────
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
                                              builder: (
                                                context,
                                                itemPressed,
                                                focused,
                                              ) {
                                                final isSelected = i == _index;
                                                final tint = (isSelected
                                                        ? widget.selectedColor
                                                        : widget
                                                            .unselectedColor) ??
                                                    (isSelected
                                                        ? theme.colors.primary
                                                        : theme
                                                            .colors
                                                            .onSurfaceContainer
                                                            .withValues(
                                                                alpha: 0.55));

                                                // Kyant0: LocalFloatingBottomBarTabScale 动态微放大
                                                final itemScale = isSelected
                                                    ? 1.0 +
                                                        0.14 * pressProgress
                                                    : 1.0;

                                                return Transform.scale(
                                                  scale: itemScale,
                                                  child: _buildItem(
                                                    item: widget.items[i],
                                                    tint: tint,
                                                    focused: focused,
                                                    dimmed:
                                                        _nav.pressedIndex ==
                                                                i &&
                                                        !isSelected,
                                                    fontSize: fontSize,
                                                    primary:
                                                        theme.colors.primary,
                                                    selected: isSelected,
                                                  ),
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

  /// 玻璃外壳：Kyant0 Vibrancy + 双层柔和阴影 + 实时 BackdropFilter + 镜面双峰高光
  ///
  /// 玻璃管线与 Kyant0 一致 —— **先模糊，再折射**：
  ///   1. `ImageFilter.blur`  磨砂，抹掉背景细节（否则折射会把文字拉花）
  ///   2. `liquid_refract.frag`  沿圆角矩形 SDF 的边缘做折射 + 7 抽色散
  /// 两者用 `ImageFilter.compose(outer: 折射, inner: 模糊)` 串联 ——
  /// compose 的语义是 `outer(inner(source))`，正好是这个顺序。
  ///
  /// ⚠️ 折射**仅在 Impeller 后端可用**。Skia 下 `resolve()` 返回 null，
  ///    此时降级为**纯模糊**（用户确认的 fallback 策略），不做任何"假折射"。
  /// ⚠️ 本方法**只画背景玻璃**，不再承载指示器与图标。
  /// 这是为了对齐上游 Compose 的结构（外层 `Box` 的三个兄弟节点）：
  /// 指示器必须与外壳**并列**，否则放大到 1.39x 时会被这里的 `ClipRRect` 裁掉。
  Widget _buildShell(
    BuildContext context, {
    required bool dark,
    required double width,
    required double height,
  }) {
    final borderRadius = BorderRadius.circular(999);
    final theme = MiuixTheme.of(context);

    // Kyant0 / KernelSU 风格：surfaceContainer 半透底色
    final surfaceContainer = theme.colors.surfaceContainer;
    final containerColor = dark
        ? surfaceContainer.withValues(alpha: 0.30 * widget.alpha)
        : surfaceContainer.withValues(alpha: 0.65 * widget.alpha);

    // ── vibrancy（上游 ColorFilter.kt）────────────────────────────────────
    //   `vibrancy()` = `colorControlsColorFilter(saturation = 1.5f)`
    //   按 r=0.213*invSat, g=0.715*invSat, b=0.072*invSat（invSat = 1-1.5 = -0.5）
    //   且 contrast=1 / brightness=0 → 偏移项 t = 0：
    //     cr=-0.1065  cg=-0.3575  cb=-0.036  cs=1.5
    // ⚠️ 此前用的是自造的对称近似（1.35 / -0.18 / -0.12），与上游不符，已替换为精算矩阵。
    const vibrancyMatrix = <double>[
      1.3935, -0.3575, -0.036, 0, 0,
      -0.1065, 1.1425, -0.036, 0, 0,
      -0.1065, -0.3575, 1.464, 0, 0,
      0, 0, 0, 1, 0,
    ];

    // ── 折射层（Impeller）────────────────────────────────────────────────
    // 圆角半径取高度一半 —— 与 `BorderRadius.circular(999)` 被裁成胶囊后的
    // 实际半径一致（999 会被 Flutter 钳到 minDimension/2）。
    final pillRadius = math.min(999.0, height / 2);

    // ── 折射参数（严格对齐上游）────────────────────────────────────────────
    // 上游 `LiquidBottomTabs.kt` 外壳（第 1 个 Row）：
    //   `lens(24.dp.toPx(), 24.dp.toPx())`
    //   → `depthEffect` 与 `chromaticAberration` 都用默认值 **false**
    //   → 而且是**常量**，不随 pressProgress 变化（随按压变化的是隐藏层与指示器）
    // ⚠️ 单位是**物理像素**：引擎 runtime_effect_filter_contents.cc:144 用
    //    `Size(input_snapshot->texture->GetSize())` 填 size，
    //    与 FlutterFragCoord() 同空间 → 必须乘 dpr。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final refraction = _shellGlass.resolve(
      LiquidGlassRefractionParams(
        refractionHeight: 24.0 * dpr,
        refractionAmount: 24.0 * dpr,
        cornerRadii: [pillRadius, pillRadius, pillRadius, pillRadius],
        depthEffect: false,
        chromaticAberration: false,
      ),
    );

    final blurFilter = ui.ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma);

    // 折射可用 → 模糊 + 折射串联；不可用（Skia / shader 未就绪）→ 纯模糊
    final glassFilter = refraction == null
        ? blurFilter
        : ui.ImageFilter.compose(outer: refraction, inner: blurFilter);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.30 : 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.14 : 0.04),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          children: [
            // 背景玻璃全向实时采样（模糊 + 折射串联；Skia 下退化为纯模糊）
            Positioned.fill(
              child: BackdropFilter(
                filter: glassFilter,
                child: ColorFiltered(
                  colorFilter: const ColorFilter.matrix(vibrancyMatrix),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: containerColor,
                      borderRadius: borderRadius,
                    ),
                  ),
                ),
              ),
            ),
            // 外壳高光 —— 上游 `drawBackdrop` 的 `highlight` 参数默认值是
            // `Highlight.Default`，**外壳本来就有高光且 alpha = 1**。
            //   width 0.5dp / blurRadius 0.25dp / alpha 1 / angle 45° / falloff 1
            // 由 `shaders/liquid_highlight.frag` 绘制（SDF 梯度 · 光向），
            // 替代原先手绘的 `ui.Gradient.linear` 双峰描边。
            Positioned.fill(
              child: CustomPaint(
                painter: LiquidGlassRimHighlightPainter(
                  shaderHolder: _shellHighlight,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Kyant0 液态胶囊选中指示器
  ///
  /// 核心要素：
  /// - pressedScale 扩展放大（1.0x -> 1.30x），拒绝缩小；
  /// - 速度驱动横向水滴挤压拉伸（Squash & Stretch）；
  /// - 内部凹陷深度阴影（InnerShadow）；
  /// - 镜面双峰折射高光（pillHighlight 90°）；
  /// - 微弱色散边缘（Subtle Chromatic Aberration）；
  /// - 二次 BackdropFilter 磨砂折射。
  Widget _buildLiquidIndicator(
    BuildContext context, {
    required bool dark,
    required double pressProgress,
    required double velocity,
    required double baseScaleX,
    required double baseScaleY,
    required double width,
    required double height,
  }) {
    final borderRadius = BorderRadius.circular(999);
    final theme = MiuixTheme.of(context);

    // ── 折射层（Impeller）────────────────────────────────────────────────
    //
    // ── 折射参数（严格对齐上游）────────────────────────────────────────────
    // 上游 `LiquidBottomTabs.kt` 指示器（第 3 个节点）：
    //   ```kotlin
    //   val progress = dampedDragAnimation.pressProgress
    //   lens(10f.dp.toPx() * progress,
    //        14f.dp.toPx() * progress,
    //        chromaticAberration = true)
    //   ```
    // ★ 三个要点：
    //   1. **折射强度与 pressProgress 成正比** —— 静止时 `refractionHeight == 0`，
    //      上游 `lens()` 会直接 return（不加效果）；按下才浮现。
    //   2. **`depthEffect` 用默认值 false**（上游指示器没传这个参数）
    //   3. **`chromaticAberration = true`** → 走**色散版** shader
    //      （不是 0~1 的强度参数）
    // ⚠️ 单位是物理像素，必须乘 dpr（原因同外壳）。
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final progress = pressProgress.clamp(0.0, 1.0);
    final indicatorRadius = math.min(999.0, height / 2);
    final refraction = _indicatorGlass.resolve(
      LiquidGlassRefractionParams(
        refractionHeight: 10.0 * dpr * progress,
        refractionAmount: 14.0 * dpr * progress,
        cornerRadii: [
          indicatorRadius,
          indicatorRadius,
          indicatorRadius,
          indicatorRadius,
        ],
        depthEffect: false,
        chromaticAberration: true,
      ),
    );

    final blurFilter = ui.ImageFilter.blur(
      sigmaX: _sigma * 0.45 * (1.0 + 0.25 * pressProgress),
      sigmaY: _sigma * 0.45 * (1.0 + 0.25 * pressProgress),
    );

    final glassFilter = refraction == null
        ? blurFilter
        : ui.ImageFilter.compose(outer: refraction, inner: blurFilter);

    // ── 缩放与液态形变（严格对齐上游 layerBlock）──────────────────────────
    //   ```kotlin
    //   scaleX = dampedDragAnimation.scaleX      // 独立弹簧，ratio 0.6
    //   scaleY = dampedDragAnimation.scaleY      // 独立弹簧，ratio 0.7
    //   val velocity = dampedDragAnimation.velocity / 10f
    //   scaleX /= 1f - (velocity * 0.75f).fastCoerceIn(-0.2f, 0.2f)
    //   scaleY *= 1f - (velocity * 0.25f).fastCoerceIn(-0.2f, 0.2f)
    //   ```
    // scaleX / scaleY 由控制器传入（两条 dampingRatio 不同的弹簧 →
    // 按下时横向先到位、纵向稍后跟上，产生各向异性「液态」感）。
    final vel = (velocity / 10.0).clamp(-0.2, 0.2);
    final scaleX = baseScaleX / (1.0 - vel * 0.75);
    final scaleY = baseScaleY * (1.0 - vel * 0.25);

    return Transform(
      transform: Matrix4.diagonal3Values(scaleX, scaleY, 1.0),
      alignment: Alignment.center,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Stack(
          children: [
            // 1. 玻璃本体：二次采样（模糊 + 折射，Skia 下退化为纯模糊）
            Positioned.fill(
              child: BackdropFilter(
                filter: glassFilter,
                child: CustomPaint(
                  painter: _Kyant0LiquidPillPainter(
                    dark: dark,
                    pressProgress: pressProgress,
                    primaryColor: theme.colors.primary,
                  ),
                ),
              ),
            ),
            // 2. InteractiveHighlight（移植自 KernelSU 同名组件）：
            //    按下时在指示器位置叠加径向辉光，加法混合，随按压缩放。
            Positioned.fill(
              child: CustomPaint(
                painter: LiquidGlassHighlightPainter(
                  progress: pressProgress,
                  center: Offset(width / 2, height / 2),
                ),
              ),
            ),
            // 3. 方向性高光 —— 上游 `highlight = Highlight.Default.copy(alpha = progress)`
            //    由 `shaders/liquid_highlight.frag` 绘制，随按压淡入。
            Positioned.fill(
              child: CustomPaint(
                painter: LiquidGlassRimHighlightPainter(
                  shaderHolder: _indicatorHighlight,
                  alpha: pressProgress,
                ),
              ),
            ),
          ],
        ),
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
          opacity: dimmed ? .55 : 1,
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
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
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

// 原 `_Kyant0ShellRimPainter`（手绘 `ui.Gradient.linear` 双峰描边）已删除。
// 上游的外壳高光由 `DefaultHighlightShaderString` 绘制（SDF 梯度 · 光向），
// 现改用 `LiquidGlassRimHighlightPainter` + `shaders/liquid_highlight.frag`。
// 手绘渐变无法表达「内部不亮、朝光侧边缘最亮」的方向性。

/// Kyant0 液态胶囊绘制器（InnerShadow 凹陷内阴影；高光与色散已移交 shader）
class _Kyant0LiquidPillPainter extends CustomPainter {
  const _Kyant0LiquidPillPainter({
    required this.dark,
    required this.pressProgress,
    required this.primaryColor,
  });

  final bool dark;
  final double pressProgress;
  final Color primaryColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = Offset.zero & size;
    final radius = Radius.circular(size.height / 2);
    final rrect = RRect.fromRectAndRadius(rect, radius);

    // 1. 底层高光色调（静态淡亮色，按下时透亮提光）
    final surfacePaint = Paint()
      ..color = (dark ? Colors.white : Colors.black).withValues(
        alpha: (dark ? 0.12 : 0.06) + 0.08 * pressProgress,
      );
    canvas.drawRRect(rrect, surfacePaint);

    // 2. 主题色微光渗透
    final accentPaint = Paint()
      ..color = primaryColor.withValues(
        alpha: (dark ? 0.08 : 0.06) * (1.0 - 0.4 * pressProgress),
      );
    canvas.drawRRect(rrect, accentPaint);

    // 3. Kyant0 InnerShadow: 凹陷内阴影，随按压深度加深
    if (pressProgress > 0.01) {
      canvas.save();
      canvas.clipRRect(rrect);

      final shadowAlpha = (0.16 * pressProgress).clamp(0.0, 1.0);
      final shadowBlur = 6.0 * pressProgress;
      final innerShadowPaint = Paint()
        ..color = Colors.black.withValues(alpha: shadowAlpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, shadowBlur);

      // 反相镂空路径：上方向下位移投影，形成顶部镜面凹陷感
      final shadowPath = Path()
        ..addRect(rect.inflate(30.0))
        ..addRRect(rrect.shift(Offset(0, 3.5 * pressProgress)));
      shadowPath.fillType = PathFillType.evenOdd;

      canvas.drawPath(shadowPath, innerShadowPaint);
      canvas.restore();
    }

    // ── 已移除的两处「手绘模拟」（第一阶段修正）──────────────────────────
    //
    // ① 原第 4 段：用青（0xFF00E5FF）/ 琥珀（0xFFFF9100）两条错位描边
    //    **假装**色散。真正的色散现在由
    //    `shaders/liquid_refract_dispersion.frag` 的 7 抽采样产生
    //    （上游 `RoundedRectRefractionWithDispersionShaderString`）。
    //    用彩色描边冒充色散是明确被禁止的做法。
    //
    // ② 原第 5 段：用 `ui.Gradient.linear` 画上下双峰描边**假装**高光。
    //    真正的高光现在由 `shaders/liquid_highlight.frag` 产生
    //    （上游 `DefaultHighlightShaderString`：SDF 梯度 · 光向），
    //    由 `LiquidGlassRimHighlightPainter` 绘制。
    //    ⚠️ 普通线性渐变表达不了「内部不亮、朝光侧边缘最亮」的方向性。
    //
    // 保留 1~3 段（底色 / 主题色渗透 / 内阴影）—— 它们对应上游的
    // `onDrawSurface` 与 `InnerShadow`，将在后续阶段单独对齐。
  }

  @override
  bool shouldRepaint(_Kyant0LiquidPillPainter oldDelegate) =>
      oldDelegate.dark != dark ||
      oldDelegate.pressProgress != pressProgress ||
      oldDelegate.primaryColor != primaryColor;
}

/// 单个导航项交互包装
class _NavItemInteractive extends StatefulWidget {
  const _NavItemInteractive({
    required this.onTap,
    required this.builder,
    this.selected,
    this.label,
  });

  final VoidCallback? onTap;
  final Widget Function(BuildContext context, bool pressed, bool focused)
      builder;
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
