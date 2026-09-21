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

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 悬浮底栏**自身**占用的高度（不含系统安全区）。
///
/// 组成：底部抬起 14 + 底栏高 66。
/// 用于给全局 `MediaQuery.padding.bottom` 加值，让 SnackBar / BottomSheet
/// 等贴底元素自动抬到底栏之上（见 main.dart 的 `_GlassNavInsets`）。
const double glassNavBarOccupiedHeight = 14 + 66;

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

/// 通用玻璃底栏。所有模式共用同一套交互（选中项药丸滑动 + 图标缩放）。
class GlassNavBar extends StatelessWidget {
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

  bool get _usesRealBlur =>
      mode == GlassNavMode.floatingBlur || mode == GlassNavMode.edgeBlur;

  bool get _isFloating =>
      mode == GlassNavMode.floatingBlur || mode == GlassNavMode.floatingFake;

  double get _blurSigma => mode == GlassNavMode.edgeBlur ? 22 : 28;

  /// 玻璃底色：真实模糊时更透明，仿真时更不透明
  Color get _glassTint {
    if (_usesRealBlur) {
      return isDark ? Colors.black.withValues(alpha: 0.42) : Colors.white.withValues(alpha: 0.46);
    }
    return isDark ? const Color(0xFF1C1B1F).withValues(alpha: 0.88) : Colors.white.withValues(alpha: 0.86);
  }

  /// 顶部高光描边
  Color get _strokeColor =>
      isDark ? Colors.white.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.72);

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    if (mode == GlassNavMode.miniPill) {
      return _buildMiniPill(context, bottomInset);
    }

    final bar = _buildMainBar(context);

    final content = ClipRRect(
      borderRadius: BorderRadius.circular(_isFloating ? 30 : 0),
      child: BackdropFilter(
        // 仿真模式用 sigma=0（等价于不模糊，但保留结构一致）
        filter: ui.ImageFilter.blur(
          sigmaX: _usesRealBlur ? _blurSigma : 0,
          sigmaY: _usesRealBlur ? _blurSigma : 0,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: _glassTint,
            borderRadius: BorderRadius.circular(_isFloating ? 30 : 0),
            border: Border.all(
              color: _strokeColor,
              width: 1,
            ),
            boxShadow: _isFloating
                ? [
                    BoxShadow(
                      color: Colors.black
                          .withValues(alpha: isDark ? 0.42 : 0.14),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: bar,
        ),
      ),
    );

    if (_isFloating) {
      // 悬浮：左右留白 + 底部抬起
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 14),
        child: content,
      );
    }

    // 贴边：撑满宽度，底部吃掉安全区
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: content,
    );
  }

  Widget _buildMainBar(BuildContext context) {
    return SizedBox(
      height: 66,
      child: Row(
        children: List.generate(items.length, (i) {
          return Expanded(
            child: _GlassNavButton(
              item: items[i],
              selected: i == currentIndex,
              onTap: () => onTap(i),
              colorScheme: colorScheme,
              isDark: isDark,
            ),
          );
        }),
      ),
    );
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
                border: Border.all(color: _strokeColor, width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.16),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(items.length, (i) {
                  final selected = i == currentIndex;
                  return GestureDetector(
                    onTap: () => onTap(i),
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
                            ? colorScheme.primary.withValues(alpha: isDark ? 0.30 : 0.16)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            selected ? items[i].activeIcon : items[i].icon,
                            size: 22,
                            color: selected
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                          // 选中时才展开文字（宽度动画）
                          AnimatedSize(
                            duration: const Duration(milliseconds: 260),
                            curve: Curves.easeOutCubic,
                            child: selected
                                ? Padding(
                                    padding: const EdgeInsets.only(left: 6),
                                    child: Text(
                                      items[i].label,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: colorScheme.primary,
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

/// 单个底栏按钮：图标 + 标签，选中时药丸背景浮现
class _GlassNavButton extends StatelessWidget {
  const _GlassNavButton({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.colorScheme,
    required this.isDark,
  });

  final GlassNavItem item;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme colorScheme;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final activeColor = colorScheme.primary;
    final idleColor = colorScheme.onSurfaceVariant;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        decoration: BoxDecoration(
          // 选中：药丸底色
          color: selected
              ? activeColor.withValues(alpha: isDark ? 0.26 : 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Icon(
                selected ? item.activeIcon : item.icon,
                key: ValueKey(selected),
                size: 24,
                color: selected ? activeColor : idleColor,
              ),
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? activeColor : idleColor,
              ),
              child: Text(item.label),
            ),
          ],
        ),
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
