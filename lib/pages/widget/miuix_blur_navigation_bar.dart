// ============================================================================
// Miuix 模糊底栏（贴边 · 非悬浮）
// ============================================================================
//
// 用户 2026-09-22 拍板：
//   「所有界面元素统一采用 miuix 设计风格，取消液态玻璃的视觉效果；
//     底部导航栏改为 miuix 标准样式，采用非悬浮的固定布局，
//     删除现有的悬浮底栏实现，确保整体风格与 miuix 规范保持一致。
//     顶栏底栏都有 miuix 的模糊效果」
//
// 所以本组件 = 包里的 `MiuixNavigationBar`（**Miuix 标准底栏**：几何、字号、
// 按压反馈、选中动画时长全部由库里定义，不自造一个）+ 一层与顶栏**完全相同**
// 的 `BackdropFilter` 玻璃。
//
// ⚠️ 类名为什么是 `Blur` 而不是 `Glass`：`package:flutter_miuix` 里**已经有**
// 一个 `MiuixGlassNavigationBar`（玻璃底栏），同名会撞成
// `ambiguous_import` 编译错误。包里的那个走「录图层快照 → 喂 shader」，
// 采样由 `paint()` 驱动；而 `ListView` 的 `Viewport` 自己就是重绘边界
// （`rendering/viewport.dart:752`），滚动时位于它之上的捕获节点收不到
// `paint()`，快照会冻住 → 真机实测滚动期间只有 ~19 次/秒，表现为
// 「停住 → 跳一下 → 再停住」。所以那一个不能用（用户已确认），
// 由本组件替代。命名上跟包的 `MiuixBlurTopAppBar` 保持一致。
//
// 【为什么外面还要套一层玻璃】
//   `MiuixNavigationBar` 是**纯色**的 —— 它 build 出来就是
//   `ColoredBox(color: resolvedColors.background)`，没有任何模糊能力。
//   而用户要求底栏也有模糊，所以由本组件补这一层。
//
// 【为什么玻璃能一路铺到屏幕底边（小白条不再割裂）】
//   `MiuixNavigationBar` 的 build 结构是
//     ColoredBox( ... Column[ divider?, Row(items), SizedBox(bottomInset) ] )
//   —— `ColoredBox` 包着**整个 Column**，所以底部那条手势区占位**也在它的
//   ColoredBox 之内**。我们把它的 `color` 传成 `Colors.transparent`，
//   自己在外层铺 `ColoredBox(surface @ alpha)`，玻璃就自然覆盖到屏幕最底边。
//
//   历史 bug：贴边态原先用 `ColoredBox(colors.surface)` 补手势区，而深色下
//   `surface = #000000` → 与上面那层 `surfaceContainer @ .4` 的玻璃之间出现
//   一条硬边（用户截图里底栏下方那条纯黑块）。现在整条栏只有一层玻璃，
//   不存在接缝。
//
// 【为什么不能挪进 Scaffold.bottomNavigationBar 槽位】
//   `BackdropFilter` 采样的是「**已经画好的**内容」。一旦挪进 Scaffold 槽位，
//   body 会被顶到栏上方，栏底下没有内容可糊 → 糊了个寂寞。
//   所以底栏必须由 `main.dart` 用 `Stack` + `Positioned(bottom: 0)` 叠加。
// ============================================================================

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'miuix_glass_spec.dart';

/// Miuix 标准底栏 + 模糊（贴边、通栏、直角）。
///
/// 用法与包里的 `MiuixNavigationBar` 一致：传 2~5 个
/// `MiuixNavigationBarItem`，等分宽度。
class MiuixBlurNavigationBar extends StatelessWidget {
  const MiuixBlurNavigationBar({
    super.key,
    required this.children,
    this.blurRadius = MiuixGlassSpec.barBlurRadius,
    this.blurTintAlpha = MiuixGlassSpec.barTintAlpha,
    this.showDivider = true,
  }) : assert(children.length >= 2 && children.length <= 5);

  /// 2~5 个 [MiuixNavigationBarItem]，由 `Expanded` 等分宽度。
  final List<Widget> children;

  /// 玻璃模糊半径（dp）。与顶栏同一套口径：`sigma = radius × .45`。
  final double blurRadius;

  /// 玻璃色调不透明度，铺的是 `colors.surface`。
  final double blurTintAlpha;

  /// 顶部分隔线（Miuix 普通底栏默认有，保留以贴合规范）。
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final sigma = MiuixGlassSpec.sigmaOf(blurRadius);

    // `ClipRect` 不是可选项：`BackdropFilter` 的模糊会把采样结果溢出到自己的
    // 边界之外（`saveLayer` 的固有行为），不裁的话栏顶会出现一圈模糊光晕。
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: ColoredBox(
          color: colors.surface.withValues(alpha: blurTintAlpha),
          // ⚠️ 必须显式传 `Colors.transparent`：`MiuixNavigationBar` 自己的
          // `ColoredBox` 会以 `colors.surface` 铺底（深色下是纯黑 `#000000`），
          // 直接盖住玻璃。传透明后，整条栏的颜色全部来自上面这层 55% 的色调，
          // 底下内容能透出来 —— 这才是「模糊」而不是「实心块」。
          child: MiuixNavigationBar(
            color: Colors.transparent,
            showDivider: showDivider,
            // 默认 true：它会在底部自动垫一条 `viewPadding.bottom` 的手势区占位，
            // 且这条占位**也在它自己的 ColoredBox 之内** → 一起被上面的玻璃覆盖。
            // 这就是「沉浸式小白条」的全部实现，不需要 main.dart 再补色块。
            children: children,
          ),
        ),
      ),
    );
  }
}
