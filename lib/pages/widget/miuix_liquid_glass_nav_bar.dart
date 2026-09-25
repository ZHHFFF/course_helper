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

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_miuix/miuix.dart';

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
  late final AnimationController _showController = AnimationController.unbounded(
    vsync: this,
    value: widget.visible ? 1.0 : 0.0,
  );

  /// 指示器当前物理浮点位置（0.0 ~ N-1.0）
  late final AnimationController _positionController =
      AnimationController.unbounded(
    vsync: this,
    value: widget.selectedIndex.toDouble(),
  );

  /// 按压进出进度控制器（0.0 静止 ~ 1.0 完全按下）
  late final AnimationController _pressController =
      AnimationController.unbounded(
    vsync: this,
    value: 0.0,
  );

  final _key = GlobalKey();

  Timer? _animatingFromTapTimer;
  bool _isAnimatingFromTap = false;
  int? _pointer;
  int _pressedIndex = -1;
  double _width = 0.0;
  double _lastX = 0.0;
  double _dragVelocity = 0.0;
  int _lastTime = 0;
  bool _positioned = false;

  /// Kyant0 物理弹簧参数
  static const _positionSpring = SpringDescription(
    mass: 1.0,
    stiffness: 300.0,
    damping: 24.0,
  );
  static const _pressEnterSpring = SpringDescription(
    mass: 1.0,
    stiffness: 420.0,
    damping: 28.0,
  );
  static const _pressExitSpring = SpringDescription(
    mass: 1.0,
    stiffness: 280.0,
    damping: 22.0,
  );

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

  @override
  void initState() {
    super.initState();
    widget.pageController?.addListener(_onPageScroll);
  }

  @override
  void didUpdateWidget(MiuixLiquidGlassNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      if (_disabledMotion) {
        _showController.value = widget.visible ? 1.0 : 0.0;
      } else {
        _showController.animateWith(
          SpringSimulation(
            _positionSpring,
            _showController.value,
            widget.visible ? 1.0 : 0.0,
            _showController.velocity,
          ),
        );
      }
      if (!widget.visible) {
        _release();
      }
    }
    if (oldWidget.items.length != widget.items.length) {
      _positioned = false;
      _pointer = null;
      _pressedIndex = -1;
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
          widget.pageController!.position.userScrollDirection !=
              ScrollDirection.idle;
      if (!isDragging) {
        _animatePositionTo(widget.selectedIndex.toDouble());
      }
    }
  }

  @override
  void dispose() {
    _animatingFromTapTimer?.cancel();
    widget.pageController?.removeListener(_onPageScroll);
    _showController.dispose();
    _positionController.dispose();
    _pressController.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    if (widget.pageController == null || !widget.pageController!.hasClients) {
      return;
    }
    if (_pointer != null) return;
    if (_isAnimatingFromTap) {
      if (widget.pageController!.position.userScrollDirection !=
          ScrollDirection.idle) {
        _animatingFromTapTimer?.cancel();
        _isAnimatingFromTap = false;
      } else {
        return;
      }
    }
    final page = widget.pageController!.page;
    if (page != null && _width > 0) {
      final clampedPage =
          page.clamp(0.0, (widget.items.length - 1).toDouble());
      _positionController.value = clampedPage;
    }
  }

  double _localX(Offset global) {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return 0.0;
    return box.globalToLocal(global).dx;
  }

  int _itemAt(double x) {
    if (_tabWidth <= 0) return _index;
    final raw = ((x - 8) / _tabWidth).floor().clamp(0, widget.items.length - 1);
    return _rtl ? widget.items.length - 1 - raw : raw;
  }

  void _animatePositionTo(double target) {
    if (_disabledMotion) {
      _positionController.value = target;
      return;
    }
    _positionController.animateWith(
      SpringSimulation(
        _positionSpring,
        _positionController.value,
        target,
        _positionController.velocity,
      ),
    );
  }

  void _animatePressTo(double target) {
    if (_disabledMotion) {
      _pressController.value = target;
      return;
    }
    final spring = target > 0.5 ? _pressEnterSpring : _pressExitSpring;
    _pressController.animateWith(
      SpringSimulation(
        spring,
        _pressController.value,
        target,
        _pressController.velocity,
      ),
    );
  }

  void _select(int index) {
    _animatingFromTapTimer?.cancel();
    _isAnimatingFromTap = true;
    _animatingFromTapTimer = Timer(const Duration(milliseconds: 320), () {
      if (mounted) {
        _isAnimatingFromTap = false;
      }
    });
    _animatePositionTo(index.toDouble());
    widget.onSelect(index);
  }

  void _release() {
    if (_pointer == null && _pressedIndex == -1) return;
    final targetIndex =
        _positionController.value.round().clamp(0, widget.items.length - 1);
    setState(() {
      _pointer = null;
      _pressedIndex = -1;
      _dragVelocity = 0.0;
    });
    _animatePressTo(0.0);
    _animatePositionTo(targetIndex.toDouble());
    if (targetIndex != _index) {
      widget.onSelect(targetIndex);
    }
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
              _positionController.value = _index.toDouble();
              _positioned = true;
            } else {
              _positionController.value = _index.toDouble();
            }
          });
        }

        return AnimatedBuilder(
          animation: Listenable.merge(
              [_showController, _positionController, _pressController]),
          builder: (context, _) {
            final showProgress = _showController.value.clamp(0.0, 1.0);
            if (!widget.visible && showProgress < .001) {
              return SizedBox(
                width: width,
                height: widget.height + widget.bottomPadding,
              );
            }

            final pressProgress = _pressController.value.clamp(0.0, 1.0);
            final posValue = _positionController.value;
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
                          onPointerDown: (event) {
                            if (_pointer != null) return;
                            _pointer = event.pointer;
                            final x = _localX(event.position);
                            _lastX = x;
                            _lastTime = DateTime.now().millisecondsSinceEpoch;
                            _dragVelocity = 0.0;
                            final item = _itemAt(x);
                            setState(() => _pressedIndex = item);
                            _animatePressTo(1.0);
                            _select(item);
                          },
                          onPointerMove: (event) {
                            if (_pointer != event.pointer) return;
                            final x = _localX(event.position);
                            final now = DateTime.now().millisecondsSinceEpoch;
                            final dt = (now - _lastTime) / 1000.0;
                            if (dt > 0.003) {
                              _dragVelocity = ((x - _lastX) / dt / 360.0)
                                  .clamp(-2.5, 2.5);
                            }
                            _lastTime = now;
                            _lastX = x;

                            if (tabW > 0) {
                              // 即时跟手计算，零延迟
                              final logicalX = _rtl ? width - 8 - x : x - 8;
                              final floatTarget =
                                  (logicalX - tabW / 2) / tabW;
                              _positionController.value = floatTarget.clamp(
                                -0.4,
                                (widget.items.length - 1) + 0.4,
                              );
                              final item = _itemAt(x);
                              if (item != _pressedIndex) {
                                setState(() => _pressedIndex = item);
                                widget.onSelect(item);
                              }
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
                              // 1. Kyant0 液态玻璃选中指示器（并列层二次 BackdropFilter 采样）
                              if (tabW > 0)
                                Positioned(
                                  left: indicatorLeft,
                                  top: 3,
                                  width: tabW,
                                  height: math.max(1.0, widget.height - 6),
                                  child: _buildLiquidIndicator(
                                    context,
                                    dark: dark,
                                    pressProgress: pressProgress,
                                    velocity: _dragVelocity,
                                  ),
                                ),
                              // 2. 导航项内容图标与标签（顶层交互）
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
                                                    dimmed: _pressedIndex == i &&
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
  Widget _buildShell(
    BuildContext context, {
    required bool dark,
    required List<Widget> layers,
  }) {
    final borderRadius = BorderRadius.circular(999);
    final theme = MiuixTheme.of(context);

    // Kyant0 / KernelSU 风格：surfaceContainer 半透底色
    final surfaceContainer = theme.colors.surfaceContainer;
    final containerColor = dark
        ? surfaceContainer.withValues(alpha: 0.30 * widget.alpha)
        : surfaceContainer.withValues(alpha: 0.65 * widget.alpha);

    // Kyant0 Vibrancy: +35% 饱和度反差增强矩阵，让透过玻璃的底色色彩鲜艳通透
    const vibrancyMatrix = <double>[
      1.35, -0.18, -0.12, 0, 0,
      -0.12, 1.35, -0.18, 0, 0,
      -0.12, -0.18, 1.35, 0, 0,
      0,     0,     0,     1, 0,
    ];

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
            // 背景玻璃全向实时采样
            Positioned.fill(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma),
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
            // Kyant0 外壳双峰高光描边 (baseHighlight -45°)
            Positioned.fill(
              child: CustomPaint(
                painter: _Kyant0ShellRimPainter(dark: dark),
              ),
            ),
            ...layers,
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
  }) {
    final borderRadius = BorderRadius.circular(999);
    final theme = MiuixTheme.of(context);

    // Kyant0: pressedScale 78f / 56f ≈ 1.393x，此处采用 1.30x 自然饱满扩张
    final baseScale = 1.0 + 0.30 * pressProgress;

    // Kyant0 速度挤压拉伸形变
    final velClamp = (velocity * 0.16).clamp(-0.25, 0.25);
    final scaleX = baseScale / (1.0 - velClamp * 0.75);
    final scaleY = baseScale * (1.0 - velClamp.abs() * 0.35);

    return Transform(
      transform: Matrix4.diagonal3Values(scaleX, scaleY, 1.0),
      alignment: Alignment.center,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          // 选中区域二次采样磨砂折射
          filter: ui.ImageFilter.blur(
            sigmaX: _sigma * 0.45 * (1.0 + 0.25 * pressProgress),
            sigmaY: _sigma * 0.45 * (1.0 + 0.25 * pressProgress),
          ),
          child: CustomPaint(
            painter: _Kyant0LiquidPillPainter(
              dark: dark,
              pressProgress: pressProgress,
              primaryColor: theme.colors.primary,
            ),
          ),
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

/// Kyant0 外壳双峰高光描边绘制器（baseHighlight -45°）
class _Kyant0ShellRimPainter extends CustomPainter {
  const _Kyant0ShellRimPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.6),
      Radius.circular(size.height / 2),
    );

    // 沿左上 -45° 至右下 135° 的双峰镜面高光梯度
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomRight,
        [
          Colors.white.withValues(alpha: dark ? 0.38 : 0.45), // 左上主光峰值
          Colors.white.withValues(alpha: dark ? 0.08 : 0.12),
          Colors.white.withValues(alpha: dark ? 0.22 : 0.28), // 右下次光峰值
        ],
        const [0.0, 0.55, 1.0],
      );

    canvas.drawRRect(rrect, rimPaint);
  }

  @override
  bool shouldRepaint(_Kyant0ShellRimPainter oldDelegate) =>
      oldDelegate.dark != dark;
}

/// Kyant0 液态胶囊绘制器（镜面双峰高光 + InnerShadow 凹陷内阴影 + 微弱色散）
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

    // 4. 微弱色散边缘（Chromatic Aberration）：青与琥珀色分离次像素折射边
    final dispersionAlpha = (0.14 * (1.0 + pressProgress)).clamp(0.0, 0.25);
    final cyanRimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0xFF00E5FF).withValues(alpha: dispersionAlpha);
    final orangeRimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0xFFFF9100).withValues(alpha: dispersionAlpha);

    // 左上微偏青色，右下微偏琥珀色
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.shift(const Offset(-0.35, -0.35)).deflate(0.5),
        radius,
      ),
      cyanRimPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.shift(const Offset(0.35, 0.35)).deflate(0.5),
        radius,
      ),
      orangeRimPaint,
    );

    // 5. Kyant0 pillHighlight: 90° 双峰上下镜面聚光描边
    final highlightAlpha =
        ((dark ? 0.30 : 0.20) + 0.35 * pressProgress).clamp(0.0, 0.95);
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 + 0.4 * pressProgress
      ..shader = ui.Gradient.linear(
        Offset(size.width / 2, 0),
        Offset(size.width / 2, size.height),
        [
          Colors.white.withValues(alpha: highlightAlpha), // 顶部镜面主聚光
          Colors.white.withValues(alpha: 0.04),
          Colors.white.withValues(alpha: highlightAlpha * 0.55), // 底部次聚光
        ],
        const [0.0, 0.5, 1.0],
      );

    canvas.drawRRect(rrect.deflate(0.6), rimPaint);
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
