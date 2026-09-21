// ============================================================================
// 液态玻璃底栏（Liquid Glass Navigation Bar）
// ============================================================================
//
// 当前生效方案：**A · 悬浮胶囊 + 真实模糊**（main.dart 里 mode: floatingBlur）。
// 其余 3 种方案（B 贴边 / C 悬浮仿真 / D 迷你药丸）保留在同一组件内，
// 通过 GlassNavMode 切换，方便后续再比较。
//
// 组件入口：GlassNavBar
//   - currentIndex / onTap  受控接口
//   - items                 List<GlassNavItem>（icon / activeIcon / label）
//   - mode                  GlassNavMode.{floatingBlur|edgeBlur|floatingFake|miniPill}
//   - isDark / colorScheme  主题（由调用方传入，避免依赖 context 查找）
//
// 性能说明：
//   floatingBlur / edgeBlur  → BackdropFilter 真实采样背后内容，GPU 开销较高
//   floatingFake / miniPill  → 半透明色仿真，无实时模糊，开销可忽略
//   若真机上发现掉帧，把 main.dart 里的 mode 改成 floatingFake 即可降级。
//
// 零新增依赖，全部使用 Flutter 原生能力。
//
// 独立预览页（含 4 方案对比 + 帧耗时指示器）：
//   LiquidGlassPreviewPage —— 用下面这行单独跑起来
//     home: const LiquidGlassPreviewPage(),
//   HTML 等效预览（免编译）：D:\CourseHelper\logs\liquid_glass_preview.html
//
// 创建：2026-09-21
// ============================================================================

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../setting/navbar_setting.dart';

/// 液态玻璃折射 shader 的全局缓存。
///
/// `FragmentProgram.fromAsset` 是异步且较慢的（首次要编译 GLSL），
/// 所以进程内只加载一次，之后所有底栏实例共用。加载完成前 shader 为 null，
/// 底栏会退回"无折射"的纯玻璃外观 —— 视觉上只是少了边缘色散，不会报错。
ui.FragmentProgram? _glassProgram;
Future<void>? _glassProgramLoading;

/// 触发加载（幂等）。在底栏首次构建时调用。
Future<void> _ensureGlassShaderLoaded() {
  return _glassProgramLoading ??= ui.FragmentProgram.fromAsset(
    'shaders/liquid_glass.frag',
  ).then((prog) {
    _glassProgram = prog;
  }).catchError((Object e) {
    // shader 编译失败不应该让底栏崩掉 —— 记日志、退回无 shader 外观
    debugPrint('[GlassNavBar] liquid_glass.frag 加载失败：$e');
  });
}

/// 底栏**内容区**的高度（不含底部抬起与系统安全区）。
///
/// 52 是参照 iOS 26 Liquid Glass 标签栏的紧凑比例定的：
/// 图标 22 + 上下各 15 内边距 ≈ 52，比 Material 默认的 80 矮一大截。
/// 想再紧凑可以改这里，`glassNavBarOccupiedHeight` 会自动跟着变。
const double glassNavBarContentHeight = 52;

/// 底栏离屏幕底边的抬起距离（不含系统安全区）。
///
/// Liquid Glass 的悬浮感来自「薄薄一层飘在内容之上」，
/// 抬起量要给得很克制 —— 8 刚好让它与屏幕边缘脱开，又不显臃肿。
const double glassNavBarLift = 8;

/// 悬浮底栏**自身**占用的高度（不含系统安全区）。
///
/// 组成：底部抬起 8 + 底栏高 52。
/// 用于给全局 `MediaQuery.padding.bottom` 加值，让 SnackBar / BottomSheet
/// 等贴底元素自动抬到底栏之上（见 main.dart 的 `_GlassNavInsets`）。
const double glassNavBarOccupiedHeight =
    glassNavBarLift + glassNavBarContentHeight;

/// 底栏占用的底部高度（供页面给滚动内容留白，避免最后一项被悬浮底栏遮住）。
///
/// 用法：`ListView(padding: EdgeInsets.only(bottom: glassNavBarClearance(context)))`
///
/// 组成：悬浮底栏 66px + 底部抬起 14px + 系统安全区。
/// 非悬浮模式（edgeBlur / miniPill）高度不同，这里按最大情形给值，
/// 宁可多留一点空白，也不要内容被盖。
double glassNavBarClearance(BuildContext context) {
  return glassNavBarOccupiedHeight +
      MediaQuery.of(context).padding.bottom +
      24;
}

/// 浮动按钮（FAB）的抬高位置：把按钮摆在悬浮底栏**之上**。
///
/// 背景：底栏用 `Stack` + `Positioned` 叠加在页面之上，
/// 而 `Scaffold.floatingActionButton` 默认贴屏幕底部右下角，
/// **会被底栏整个盖住**（表现为"添加按钮点不到"）。
///
/// 用法：
/// ```dart
/// Scaffold(
///   floatingActionButtonLocation: glassNavFabLocation(context),
///   floatingActionButton: FloatingActionButton(...),
/// )
/// ```
FloatingActionButtonLocation glassNavFabLocation(BuildContext context) {
  // 底栏整体占位 = 底部抬起 + 底栏高 + 安全区
  final barOccupied =
      glassNavBarOccupiedHeight + MediaQuery.of(context).padding.bottom;
  return _GlassNavFabLocation(barOccupied);
}

/// Miuix 底栏的实测占位高度（逻辑像素 dp，**已扣除底部安全区**）。
///
/// **实测方法**（一加 13 / Android 15 / density 3.5）：
/// `uiautomator dump` 读底栏按钮的像素 bounds，配合
/// `dumpsys window` 的 `navigationBars frame` 拿安全区，再统一除以 density。
///
/// 实测原始数据：
/// - 安全区 `navigationBars frame=[0,2724][1264,2780]` → 56px = **16dp**
/// - 悬浮态按钮 `[443,2248][611,2416]`，顶边 2248
///   → 底栏顶边到屏底 `(2780-2248)/3.5 ≈ 152dp`，减 16dp 安全区 = **136dp**
/// - 贴边态按钮 `[0,2290][1264,2514]`，顶边 2290
///   → 底栏顶边到屏底 `(2780-2290)/3.5 = 140dp`，减 16dp 安全区 = **124dp**
///   （内容区高 `(2514-2290)/3.5 = 64dp`，与源码 itemHeight 吻合；
///     多出来的 60dp 是组件内的底部 padding）
///
/// ⚠️ 两个值都**远大于**只按源码常量算出的高度——源码里的
/// `bottomPadding` / `itemHeight` 并不等于组件在屏上实际占的位。
/// 所以不能照搬源码常量，必须用实测值。
///
/// 调用处会再叠加 `MediaQuery.padding.bottom`（即那 16dp 安全区）。
const double _miuixFloatingBarOccupied = 136;
const double _miuixEdgeBarOccupied = 124;

/// Miuix 底栏在滚动列表底部需要预留的留白高度。
///
/// 悬浮 / 贴边两态的高度不同，留白必须跟着变，否则贴边态下列表末项
/// 会被通栏底栏永久遮住。
///
/// 这里读全局 [NavBarSetting.floating]，与底栏渲染用的是同一个来源，
/// 保证「底栏换了形态但页面留白没跟上」这种错位不会发生。
double miuixNavBarClearance(BuildContext context) {
  final safeBottom = MediaQuery.of(context).padding.bottom;
  final floating = NavBarSetting.floating.value;
  final barOccupied =
      floating ? _miuixFloatingBarOccupied : _miuixEdgeBarOccupied;
  // 另加 16dp 余量，避免最后一张卡片紧贴底栏上沿
  return barOccupied + safeBottom + 16;
}

/// Miuix 底栏专用的 FAB 定位（悬浮 / 贴边两种形态各算一次）。
///
/// 与 [glassNavFabLocation] 的区别：Miuix 底栏的尺寸规范与自研底栏不同，
/// 用旧常量算出来的 FAB 会压在底栏上（真机实测贴边态尤其明显）。
/// 高度取 [_miuixFloatingBarOccupied] / [_miuixEdgeBarOccupied] 的实测值。
FloatingActionButtonLocation miuixNavFabLocation(
  BuildContext context, {
  required bool floating,
}) {
  final safeBottom = MediaQuery.of(context).padding.bottom;
  final barOccupied =
      floating ? _miuixFloatingBarOccupied : _miuixEdgeBarOccupied;
  return _GlassNavFabLocation(barOccupied + safeBottom + 12);
}

class _GlassNavFabLocation extends StandardFabLocation
    with FabEndOffsetX, FabFloatOffsetY {
  const _GlassNavFabLocation(this.barOccupied);

  /// 底栏占掉的底部高度
  final double barOccupied;

  @override
  double getOffsetY(
    ScaffoldPrelayoutGeometry scaffoldGeometry,
    double adjustment,
  ) {
    // 悬浮底栏之上，再留 16px 呼吸间距
    return scaffoldGeometry.scaffoldSize.height -
        barOccupied -
        16 -
        scaffoldGeometry.floatingActionButtonSize.height +
        adjustment;
  }
}

/// 底栏方案枚举（预览页与主流程共用）
enum GlassBarStyle {
  /// A：悬浮胶囊 · 真实模糊
  floatingBlur,

  /// B：贴边玻璃 · 真实模糊
  edgeBlur,

  /// C：悬浮胶囊 · 仿真玻璃（低开销）
  floatingFake,

  /// D：迷你药丸 · 极简仿真
  miniPill,
}

/// 预览宿主页
class LiquidGlassPreviewPage extends StatefulWidget {
  const LiquidGlassPreviewPage({super.key});

  @override
  State<LiquidGlassPreviewPage> createState() => _LiquidGlassPreviewPageState();
}

class _LiquidGlassPreviewPageState extends State<LiquidGlassPreviewPage> {
  GlassBarStyle _style = GlassBarStyle.floatingBlur;
  int _tabIndex = 0;

  /// 帧耗时采样（用于对比性能）
  final List<double> _frameMs = <double>[];

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        final ms = t.totalSpan.inMicroseconds / 1000.0;
        _frameMs.add(ms);
        if (_frameMs.length > 120) _frameMs.removeAt(0);
      }
    });
  }

  double get _avgFrameMs {
    if (_frameMs.isEmpty) return 0;
    return _frameMs.reduce((a, b) => a + b) / _frameMs.length;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      // 不放 bottomNavigationBar —— 底栏由 Stack 叠加，才能悬浮
      body: Stack(
        children: [
          // ── 背景内容：故意放彩色渐变 + 滚动列表，便于观察模糊效果 ──
          Positioned.fill(
            child: _DemoBackground(isDark: isDark),
          ),

          // ── 页面内容 ──
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '液态玻璃底栏 · 预览',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '对比 4 种方案，选定后再接入主流程',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          const SizedBox(height: 20),
                          _StylePicker(
                            current: _style,
                            onChanged: (s) => setState(() => _style = s),
                          ),
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ),
                  SliverList.builder(
                    itemCount: 14,
                    itemBuilder: (context, i) => _DemoCard(
                      index: i,
                      isDark: isDark,
                    ),
                  ),
                  // 给底栏留出空间
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 150),
                  ),
                ],
              ),
            ),
          ),

          // ── 底部导航栏（悬浮） ──
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBar(cs, isDark),
          ),

          // ── 性能指示（左上角） ──
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 12,
            child: _PerfBadge(
              avgMs: _avgFrameMs,
              isBlur: _style == GlassBarStyle.floatingBlur ||
                  _style == GlassBarStyle.edgeBlur,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBar(ColorScheme cs, bool isDark) {
    switch (_style) {
      case GlassBarStyle.floatingBlur:
        return GlassNavBar(
          currentIndex: _tabIndex,
          onTap: (i) => setState(() => _tabIndex = i),
          items: _items,
          mode: GlassNavMode.floatingBlur,
          isDark: isDark,
          colorScheme: cs,
        );
      case GlassBarStyle.edgeBlur:
        return GlassNavBar(
          currentIndex: _tabIndex,
          onTap: (i) => setState(() => _tabIndex = i),
          items: _items,
          mode: GlassNavMode.edgeBlur,
          isDark: isDark,
          colorScheme: cs,
        );
      case GlassBarStyle.floatingFake:
        return GlassNavBar(
          currentIndex: _tabIndex,
          onTap: (i) => setState(() => _tabIndex = i),
          items: _items,
          mode: GlassNavMode.floatingFake,
          isDark: isDark,
          colorScheme: cs,
        );
      case GlassBarStyle.miniPill:
        return GlassNavBar(
          currentIndex: _tabIndex,
          onTap: (i) => setState(() => _tabIndex = i),
          items: _items,
          mode: GlassNavMode.miniPill,
          isDark: isDark,
          colorScheme: cs,
        );
    }
  }

  static const List<GlassNavItem> _items = <GlassNavItem>[
    GlassNavItem(icon: Icons.school_outlined, activeIcon: Icons.school, label: '课程'),
    GlassNavItem(
        icon: Icons.account_circle_outlined,
        activeIcon: Icons.account_circle,
        label: '账号'),
  ];
}

// ============================================================================
// 底栏组件
// ============================================================================

class GlassNavItem {
  const GlassNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

enum GlassNavMode {
  /// 悬浮胶囊 + 真实模糊
  floatingBlur,

  /// 贴边 + 真实模糊
  edgeBlur,

  /// 悬浮胶囊 + 仿真玻璃
  floatingFake,

  /// 迷你药丸 + 仿真
  miniPill,
}

/// 通用玻璃底栏。
///
/// 交互（三件套，模仿 iOS Liquid Glass 标签栏）：
/// 1. **点击**切换 —— 指示器平滑滑到目标位置
/// 2. **左右滑动**切换 —— 手指按住拖动时，指示器实时跟随；松手后
///    吸附到最近的一项（超过半格则翻页）
/// 3. **图标联动** —— 选中项图标实心 + 轻微放大，非选中项描边 + 常规大小
///
/// 视觉（对标 iOS 26 Liquid Glass）：
/// - 整体矮（52）且离底边近（抬起 8），薄薄一层飘着
/// - 选中指示器是**半透明玻璃胶囊**，不是实色块 —— 这是"透明按钮"的关键
/// - 采用多层描边：外层上缘高光 + 内侧暗描边，制造玻璃厚度
class GlassNavBar extends StatefulWidget {
  const GlassNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
    required this.mode,
    required this.isDark,
    required this.colorScheme,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<GlassNavItem> items;
  final GlassNavMode mode;
  final bool isDark;
  final ColorScheme colorScheme;

  @override
  State<GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends State<GlassNavBar>
    with TickerProviderStateMixin {
  /// 指示器位置：0.0 = 第 0 项，1.0 = 第 1 项…… 允许小数（拖动中）
  late double _indicatorPos;

  /// 拖动中的临时位移（-1 ~ 1 格），松手后归零
  double _dragOffset = 0;

  /// 是否正在被手指拖拽（拖拽时禁用动画，跟手）
  bool _dragging = false;

  /// 「冲水气球」形变控制器。
  ///
  /// 参考 fengluoxiao/liquid-FrostedGlass 的做法：切换 Tab 的瞬间，
  /// 指示器先**压扁 + 拉宽**（86×64 → 96×50），约 250ms 后弹回原尺寸。
  /// 视觉上就像一颗水球被挤着滑过去 —— 这是"液态感"的主要来源。
  late final AnimationController _squash =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  /// 0 = 常态，1 = 最大形变。用一个带回弹的曲线驱动。
  late final Animation<double> _squashAnim = CurvedAnimation(
    parent: _squash,
    // 前半程迅速压扁，后半程弹性恢复 —— 对齐参考项目的
    // cubic-bezier(.4, 1.5, .5, 1)
    curve: const _ElasticSquashCurve(),
  );

  /// 按住时整个玻璃容器轻微放大 + 提亮（参考项目的 .glass-active）
  bool _pressed = false;

  /// 已加载的折射 shader（未加载完为 null）
  ui.FragmentShader? _glassShader;

  @override
  void initState() {
    super.initState();
    _indicatorPos = widget.currentIndex.toDouble();
    // 让 controller 停在 0（无形变）状态
    _squash.value = 0;

    // 异步加载 shader；加载完 setState 触发一次重绘，让折射生效
    _glassShader = _glassProgram?.fragmentShader();
    if (_glassShader == null) {
      _ensureGlassShaderLoaded().then((_) {
        if (!mounted) return;
        setState(() => _glassShader = _glassProgram?.fragmentShader());
      });
    }
  }

  @override
  void dispose() {
    _glassShader?.dispose();
    _squash.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(GlassNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部改了选中项（例如点按钮）→ 指示器滑过去
    if (widget.currentIndex != oldWidget.currentIndex && !_dragging) {
      setState(() => _indicatorPos = widget.currentIndex.toDouble());
    }
  }

  /// 播放一次「冲水气球」形变
  void _playSquash() {
    _squash.forward(from: 0);
  }

  bool get _usesRealBlur =>
      widget.mode == GlassNavMode.floatingBlur ||
      widget.mode == GlassNavMode.edgeBlur;

  bool get _isFloating =>
      widget.mode == GlassNavMode.floatingBlur ||
      widget.mode == GlassNavMode.floatingFake;

  /// 模糊强度。
  ///
  /// 参考项目只用 9px —— Liquid Glass 的磨砂是"能看出底下是什么"的
  /// 轻度模糊；之前给到 28 会把背景糊成一团，反而不像玻璃。
  /// 贴边模式稍强一点（14），因为它在屏幕边缘、背后的内容更杂。
  double get _blurSigma => widget.mode == GlassNavMode.edgeBlur ? 14 : 9;

  /// 玻璃染色。
  ///
  /// 对齐参考项目：白色 11%（常态）/ 25%（按住时，即 HDR 提亮）。
  /// 注意是无所谓深浅色的 —— Liquid Glass 本身就是浅色玻璃，
  /// 在深色背景上它呈现为"一层薄薄的白雾"，而不是一块黑板。
  double get _tintAlpha {
    final base = widget.isDark ? 0.11 : 0.16;
    return _pressed ? base + 0.14 : base;
  }

  /// 玻璃染色。仿真模式（不模糊）需要更实的底色才看得清，单独给值。
  Color get _glassTint {
    if (_usesRealBlur) return Colors.white.withValues(alpha: _tintAlpha);
    return widget.isDark
        ? const Color(0xFF1C1B1F).withValues(alpha: 0.88)
        : Colors.white.withValues(alpha: 0.86);
  }

  /// 内阴影高光色（参考项目 --shadow-color: rgba(255,255,255,0.7)）。
  ///
  /// 这是"玻璃有厚度"的关键 —— 用 inset box-shadow 在容器内缘
  /// 打一圈柔光，比 border 更自然（border 是硬边，像贴了胶带）。
  Color get _innerGlow => widget.isDark
      ? Colors.white.withValues(alpha: 0.42)
      : Colors.white.withValues(alpha: 0.75);

  /// 内阴影参数：offset 0 / blur 5 / spread -1（对齐参考项目）
  static const double _innerShadowBlur = 5;
  static const double _innerShadowSpread = -1;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    if (widget.mode == GlassNavMode.miniPill) {
      return _buildMiniPill(context, bottomInset);
    }

    final bar = _buildMainBar(context);

    final double radius = _isFloating ? 28 : 0;

    // 玻璃本体：三层叠出质感。
    //
    // ⚠️ 本项目的背景是**纯黑/纯白**（用户明确要求），这与参考项目的
    // 彩色照片背景不同 —— 在纯色背景上做 backdrop-blur 视觉上几乎无效
    // （模糊一块纯色还是那块纯色）。所以玻璃的"存在感"必须主要靠
    //   ① 边缘高光描边（外圈一道细亮线）
    //   ② 内缘柔光（玻璃厚度）—— 用 CustomPainter 实现，Flutter 无 inset
    //   ③ 极淡的纵向渐变（模拟光从上方衰减）
    // 模糊只负责在滚动内容掠过时提供"隔着毛玻璃"的观感。
    final content = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        // 仿真模式用 sigma=0（等价于不模糊，但保留结构一致）
        filter: ui.ImageFilter.blur(
          sigmaX: _usesRealBlur ? _blurSigma : 0,
          sigmaY: _usesRealBlur ? _blurSigma : 0,
        ),
        child: Stack(
          children: [
            // ── 玻璃外观：由 GLSL shader 绘制 ──
            //
            // shader 负责三件事，都是纯 CSS/SVG 做不到或做不好的：
            //   ① 圆角矩形 SDF → 只在**边缘**产生折射（中心保持通透）
            //   ② 三通道色差 → 边缘一道极细的红/蓝色散线
            //   ③ 上缘高光 + 最外圈 rim 亮线
            //
            // 之所以要用 shader：Flutter 的 BoxShadow **没有 inset**，
            // 想画"内缘柔光"只能靠 CustomPainter 描边加模糊，效果生硬；
            // 而要复刻 rdev 方案的边缘折射，必须逐像素算 SDF，只能用 shader。
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _GlassShaderPainter(
                    shader: _glassShader,
                    radius: radius,
                    tintAlpha: _tintAlpha,
                    isDark: widget.isDark,
                  ),
                ),
              ),
            ),

            // 顶层：图标 + 指示器
            bar,
          ],
        ),
      ),
    );

    // 按住时整块玻璃轻微放大 + 提亮（参考项目 .glass-active 的 scale(1.05)）。
    // 幅度取 1.02 —— 手机底栏比参考项目的 400px 卡片小得多，1.05 会显晃。
    //
    // 外阴影必须包在 ClipRRect **外面**，否则会被圆角裁剪吃掉。
    final shadowed = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: _isFloating
            ? [
                // 参考项目：0 6px 32px rgba(0,0,0,.2)
                BoxShadow(
                  color: Colors.black
                      .withValues(alpha: widget.isDark ? 0.45 : 0.18),
                  blurRadius: 28,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: content,
    );

    final scaled = AnimatedScale(
      scale: _pressed ? 1.02 : 1.0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      child: shadowed,
    );

    if (_isFloating) {
      // 悬浮：左右留白 + 底部轻微抬起
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + glassNavBarLift),
        child: scaled,
      );
    }

    // 贴边：撑满宽度，底部吃掉安全区
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: scaled,
    );
  }

  /// 主栏：一个 Stack，底层是滑动指示器，上层是「图标 + 文字」。
  ///
  /// 为什么用 Stack 而不是 Row + 每个按钮自己画选中背景：
  /// 左右滑动时指示器要**跨格连续移动**（比如从第 0 格滑到第 1 格，
  /// 中间要经过 0.5 的位置）。每个按钮独立画背景做不到这种连续性，
  /// 必须由一个独立的、位置可任意取值的指示器来做。
  Widget _buildMainBar(BuildContext context) {
    const double outerPad = 6; // 玻璃内边距，指示器不贴边

    // 指示器实际位置 = 选中格 + 拖动位移
    final double pos = _indicatorPos + _dragOffset;

    return SizedBox(
      height: glassNavBarContentHeight,
      child: Listener(
        // 用 Listener 而不是 GestureDetector 的 onTapDown，
        // 因为要区分"按住不放"（提亮玻璃）与"点一下就松"（正常切换）
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (details) {
            setState(() {
              _dragging = true;
              _dragOffset = 0;
            });
          },
          onHorizontalDragUpdate: (details) {
            // 手指位移换算成「格」。除以 cellWidth 得格数；
            // 手指右滑（dx > 0）表示想看左边那格，所以是减。
            final double cell = _cellWidth(context);
            if (cell <= 0) return;
            setState(() => _dragOffset -= details.delta.dx / cell);
          },
          onHorizontalDragEnd: (details) {
            final double raw = _indicatorPos + _dragOffset;
            // 松手后吸附到最近格；速度足够大时按方向翻页
            double target = raw.roundToDouble();
            final vx = details.velocity.pixelsPerSecond.dx;
            if (vx < -300) {
              target = (_indicatorPos + 1).floorToDouble();
            } else if (vx > 300) {
              target = (_indicatorPos - 1).ceilToDouble();
            }
            target = target.clamp(0, widget.items.length - 1);

            setState(() {
              _dragging = false;
              _dragOffset = 0;
              _indicatorPos = target;
            });
            final int idx = target.toInt();
            if (idx != widget.currentIndex) {
              _playSquash(); // 切换成功才播形变
              widget.onTap(idx);
            }
          },
          onHorizontalDragCancel: () {
            setState(() {
              _dragging = false;
              _dragOffset = 0;
            });
          },
          // 用 LayoutBuilder 拿**真实**可用宽度，避免自己算屏幕宽再减边距
          // 这种容易算错（也容易在边距变化时失配）的做法。
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double innerWidth = constraints.maxWidth - outerPad * 2;
              final double cellWidth = innerWidth / widget.items.length;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: outerPad),
                child: Stack(
                  children: [
                    // ── 滑动指示器：半透明玻璃胶囊（"透明按钮"的核心）──
                    //
                    // 职责分离，避免动画互相打架：
                    //   · 位置/基准尺寸 → AnimatedPositioned（负责"滑动"）
                    //   · 冲水气球形变   → 内层 Transform（负责"挤压"）
                    // 早先把两者混在一个 AnimatedPositioned 里，每帧改
                    // left/width 会让它的补间状态不断重置，出现漂移。
                    AnimatedPositioned(
                      duration: _dragging
                          ? Duration.zero
                          : const Duration(milliseconds: 460),
                      // 超调弹性曲线 —— 对齐参考项目
                      // cubic-bezier(.4, 1.5, .5, 1)
                      curve: Curves.easeOutBack,
                      left: pos * cellWidth,
                      top: 3,
                      width: cellWidth,
                      height: glassNavBarContentHeight - 6,
                      child: AnimatedBuilder(
                        animation: _squashAnim,
                        builder: (context, child) {
                          // 形变：横向拉伸、纵向压缩 = 水球被挤扁
                          final double sq = _squashAnim.value;
                          return Transform.scale(
                            scaleX: 1 + sq * 0.14,
                            scaleY: 1 - sq * 0.16,
                            child: child,
                          );
                        },
                        child: _GlassIndicator(
                          isDark: widget.isDark,
                          pressed: _pressed,
                        ),
                      ),
                    ),

                    // ── 图标 + 文字 ──
                    Row(
                      children: List.generate(widget.items.length, (i) {
                        return Expanded(
                          child: _GlassNavButton(
                            item: widget.items[i],
                            selected: i == widget.currentIndex,
                            onTap: () {
                              if (i == widget.currentIndex) return;
                              setState(() => _indicatorPos = i.toDouble());
                              _playSquash();
                              widget.onTap(i);
                            },
                            colorScheme: widget.colorScheme,
                            isDark: widget.isDark,
                            // 拖动中：离指示器越近的项越"亮"，形成平滑过渡
                            highlight: _dragging
                                ? (1 - (pos - i).abs()).clamp(0.0, 1.0)
                                : (i == widget.currentIndex ? 1.0 : 0.0),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 单格宽度。仅供拖拽换算使用；渲染路径走 LayoutBuilder 里的 cellWidth。
  double _cellWidth(BuildContext context) {
    const double outerPad = 5;
    final double inner = MediaQuery.of(context).size.width - 32 - outerPad * 2;
    return inner / widget.items.length;
  }

  /// 迷你药丸：只有一个短胶囊，图标 + 文字并列
  Widget _buildMiniPill(BuildContext context, double bottomInset) {
    return Padding(
      padding: EdgeInsets.fromLTRB(0, 0, 0, bottomInset + 16),
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(40),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: _glassTint,
                borderRadius: BorderRadius.circular(40),
                boxShadow: [
                  // 内阴影高光：与主栏口径一致
                  BoxShadow(
                    color: _innerGlow,
                    blurRadius: _innerShadowBlur,
                    spreadRadius: _innerShadowSpread,
                    offset: Offset.zero,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: widget.isDark ? 0.42 : 0.16),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(widget.items.length, (i) {
                  final selected = i == widget.currentIndex;
                  return GestureDetector(
                    onTap: () => widget.onTap(i),
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      padding: EdgeInsets.symmetric(
                        horizontal: selected ? 18 : 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? widget.colorScheme.primary.withValues(alpha: widget.isDark ? 0.30 : 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            selected ? widget.items[i].activeIcon : widget.items[i].icon,
                            size: 22,
                            color: selected
                                ? widget.colorScheme.primary
                                : widget.colorScheme.onSurfaceVariant,
                          ),
                          // 选中时才展开文字（宽度动画）
                          AnimatedSize(
                            duration: const Duration(milliseconds: 260),
                            curve: Curves.easeOutCubic,
                            child: selected
                                ? Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: Text(
                                      widget.items[i].label,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: widget.colorScheme.primary,
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「冲水气球」形变曲线。
///
/// 参考项目用 `cubic-bezier(.4, 1.5, .5, 1)` —— 控制点 y=1.5 超过 1，
/// 意味着曲线会**越过终点再弹回来**，这就是"水球被挤后回弹"的来源。
///
/// Flutter 内置曲线里 `Curves.easeOutBack` 最接近这个手感，但前段
/// 太急。这里自定义一段：前 35% 快速压到最大形变，随后带一次轻微
/// 回弹地收敛到 0。
class _ElasticSquashCurve extends Curve {
  const _ElasticSquashCurve();

  @override
  double transformInternal(double t) {
    // 0 → 1（压扁）→ 回弹 → 0（恢复）
    // 用一个"先冲高再回落"的钟形：sin 的半周期，带 1.08 的过冲
    final double bell = math.sin(math.pi * t) * 1.08;
    // 收尾时强制归零，避免动画结束仍有残余形变
    final double fadeOut = t < 0.5 ? 1.0 : (1 - (t - 0.5) / 0.5);
    return (bell * fadeOut).clamp(0.0, 1.2);
  }
}

/// 滑动指示器：一颗**半透明玻璃胶囊**，浮在图标底下。
///
/// 这是"透明按钮"观感的关键 —— Apple Liquid Glass 的选中态不是实色块，
/// 而是一层更亮的玻璃。填充极淡（11%，按住 25%），存在感全靠内缘高光。
///
/// ⚠️ Flutter 的 `BoxShadow` **不支持 `inset`**（CSS 有，Flutter 没有）。
/// 直接写 `BoxShadow` 得到的是向外扩散的外阴影 —— 在深色底上会把
/// 胶囊周围糊成一圈灰雾，看起来又脏又实。参考项目那条
/// `inset 0 0 5px -1px rgba(255,255,255,.7)` 必须用 CustomPainter
/// 自己描内缘，才拿得到正确的"玻璃边缘反光"。
class _GlassIndicator extends StatelessWidget {
  const _GlassIndicator({required this.isDark, this.pressed = false});

  final bool isDark;
  final bool pressed;

  @override
  Widget build(BuildContext context) {
    // 填充：对齐参考项目 --tint-opacity: 0.11 / active: 0.25
    final double alpha = pressed ? 0.25 : 0.11;

    return CustomPaint(
      painter: _InsetGlowPainter(
        fill: Colors.white.withValues(alpha: alpha),
        glow: Colors.white.withValues(alpha: isDark ? 0.55 : 0.75),
        radius: 24,
        blur: 5,
        spread: -1,
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// 用 GLSL shader 画玻璃外观：边缘折射 + 色差 + 上缘高光。
///
/// 对齐 rdev/liquid-glass-react 的 SVG 滤镜方案（MIT），
/// 但 Flutter 侧有两点必须自己解决：
///   · Flutter 没有 `feDisplacementMap`，逐像素 SDF 只能在 shader 里算
///   · Flutter 的 `BoxShadow` 没有 `inset` 模式，内缘高光无法用装饰器表达
/// 所以直接上 FragmentShader。
class _GlassShaderPainter extends CustomPainter {
  const _GlassShaderPainter({
    required this.shader,
    required this.radius,
    required this.tintAlpha,
    required this.isDark,
  });

  final ui.FragmentShader? shader;
  final double radius;
  final double tintAlpha;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final s = shader;

    // shader 还没加载好：退回一层极淡的白填充，保证不出现"黑洞"
    if (s == null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
        Paint()..color = Colors.white.withValues(alpha: tintAlpha),
      );
      return;
    }

    s
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, radius)
      // 位移强度：对齐参考项目 displacementScale 默认值 25
      ..setFloat(3, 25.0)
      // 色差强度：对齐 aberrationIntensity 默认值 2
      ..setFloat(4, 2.0)
      // 染色不透明度：深色背景下略高才有存在感
      ..setFloat(5, isDark ? tintAlpha + 0.04 : tintAlpha)
      // 边缘折射带宽度
      ..setFloat(6, 0.16)
      // 手指位置对高光的影响（暂固定）
      ..setFloat(7, 0.0);

    canvas.drawRect(Offset.zero & size, Paint()..shader = s);
  }

  @override
  bool shouldRepaint(_GlassShaderPainter old) =>
      old.shader != shader ||
      old.radius != radius ||
      old.tintAlpha != tintAlpha ||
      old.isDark != isDark;
}

/// 画「填充 + 内缘柔光」，模拟 CSS 的 `inset box-shadow`。
///
/// 实现：先把内缘高光画在底层，再用 `BlendMode.dstOut` 之类的方式
/// 把中间掏空是反的 —— 正确做法是**用描边路径加模糊**：
/// 沿着圆角矩形的内缩边界描一圈带模糊的亮线，再在其上铺半透明填充。
/// 这样亮光只会出现在边缘内侧，中间保持通透。
class _InsetGlowPainter extends CustomPainter {
  const _InsetGlowPainter({
    required this.fill,
    required this.glow,
    required this.radius,
    required this.blur,
    required this.spread,
  });

  final Color fill;
  final Color glow;
  final double radius;
  final double blur;
  final double spread;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );

    canvas.save();
    // 裁剪到胶囊内部，保证高光只出现在内侧
    canvas.clipRRect(rrect);

    // ① 内缘高光：描一圈带模糊的亮线（模拟 inset 0 0 blur spread）
    final inner = rrect.deflate(spread.abs());
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = blur * 2
      ..color = glow
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
    canvas.drawRRect(inner, glowPaint);

    // ② 填充：半透明白，压在中间
    // 用 srcOver 叠在高光之上，中间区域就只剩这层淡白
    canvas.drawRRect(
      rrect.deflate(blur * 0.5),
      Paint()..color = fill,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_InsetGlowPainter old) =>
      old.fill != fill || old.glow != glow || old.blur != blur;
}

/// 单个底栏按钮：图标 + 标签。
///
/// 注意：**这里不画选中背景** —— 选中背景由外层的 `_GlassIndicator`
/// 统一负责（它需要跨格连续移动）。本组件只负责图标/文字的着色与缩放。
class _GlassNavButton extends StatelessWidget {
  const _GlassNavButton({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.colorScheme,
    required this.isDark,
    this.highlight = 0,
  });

  final GlassNavItem item;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme colorScheme;
  final bool isDark;

  /// 0~1：离滑动指示器有多近。拖动时用它做图标亮度的平滑过渡，
  /// 这样指示器滑过一格时，两边的图标不会突然跳变。
  final double highlight;

  @override
  Widget build(BuildContext context) {
    // 选中色：深色下用白，浅色下用主色（保证在近白玻璃上有对比度）
    final Color activeColor = isDark ? Colors.white : colorScheme.primary;
    final Color idleColor = isDark
        ? Colors.white.withValues(alpha: 0.58)
        : colorScheme.onSurfaceVariant;

    // 按 highlight 在 idle 与 active 之间插值，拖动中形成连续过渡
    final Color iconColor = Color.lerp(idleColor, activeColor, highlight)!;

    // 图标尺寸：选中略大一点（22 → 23.5），营造轻微"浮起"
    final double iconSize = 22 + highlight * 1.5;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            // 过半才换成实心图标，避免拖动中途来回跳
            highlight > 0.5 ? item.activeIcon : item.icon,
            size: iconSize,
            color: iconColor,
          ),
          const SizedBox(height: 2),
          Text(
            item.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: highlight > 0.5 ? FontWeight.w600 : FontWeight.w500,
              color: iconColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 预览辅助组件
// ============================================================================

class _StylePicker extends StatelessWidget {
  const _StylePicker({required this.current, required this.onChanged});

  final GlassBarStyle current;
  final ValueChanged<GlassBarStyle> onChanged;

  static const Map<GlassBarStyle, String> _labels = <GlassBarStyle, String>{
    GlassBarStyle.floatingBlur: 'A 悬浮胶囊·真模糊',
    GlassBarStyle.edgeBlur: 'B 贴边玻璃·真模糊',
    GlassBarStyle.floatingFake: 'C 悬浮胶囊·仿真',
    GlassBarStyle.miniPill: 'D 迷你药丸·仿真',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _labels.entries.map((e) {
        final selected = e.key == current;
        return GestureDetector(
          onTap: () => onChanged(e.key),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: selected ? cs.primary : cs.surface.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant,
              ),
            ),
            child: Text(
              e.value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? cs.onPrimary : cs.onSurfaceVariant,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// 性能指示徽标
class _PerfBadge extends StatelessWidget {
  const _PerfBadge({required this.avgMs, required this.isBlur});

  final double avgMs;
  final bool isBlur;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ok = avgMs < 16.7;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${avgMs.toStringAsFixed(1)} ms/帧',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: ok ? Colors.green.shade700 : Colors.orange.shade800,
            ),
          ),
          Text(
            isBlur ? '真实模糊' : '仿真玻璃',
            style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 演示背景：彩色渐变 + 模糊光斑，用来凸显玻璃效果
class _DemoBackground extends StatelessWidget {
  const _DemoBackground({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [
                  Color(0xFF1A1B2E),
                  Color(0xFF2D1B3D),
                  Color(0xFF0F2027),
                ]
              : const [
                  Color(0xFFE8E4FF),
                  Color(0xFFFFE4F0),
                  Color(0xFFDDF3FF),
                ],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: 120,
            left: -40,
            child: _Blob(
              color: isDark
                  ? const Color(0xFF7C4DFF).withValues(alpha: 0.5)
                  : const Color(0xFF9C6BFF).withValues(alpha: 0.45),
              size: 220,
            ),
          ),
          Positioned(
            top: 380,
            right: -60,
            child: _Blob(
              color: isDark
                  ? const Color(0xFF00BCD4).withValues(alpha: 0.42)
                  : const Color(0xFF4DD0E1).withValues(alpha: 0.45),
              size: 260,
            ),
          ),
          Positioned(
            bottom: 200,
            left: 40,
            child: _Blob(
              color: isDark
                  ? const Color(0xFFFF4081).withValues(alpha: 0.38)
                  : const Color(0xFFFF8FB1).withValues(alpha: 0.45),
              size: 200,
            ),
          ),
        ],
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 演示卡片
class _DemoCard extends StatelessWidget {
  const _DemoCard({required this.index, required this.isDark});

  final int index;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surface.withValues(alpha: isDark ? 0.72 : 0.82),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.auto_stories_outlined,
                color: cs.onPrimaryContainer,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '示例课程 ${index + 1}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '向下滚动，观察底栏玻璃的取景效果',
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
