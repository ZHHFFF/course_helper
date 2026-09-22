// ============================================================================
// KernelSU 对齐的玻璃规格（单一事实来源）
// ============================================================================
//
// 本文件把 `D:\CourseHelper\refs\kernelsu\` 里 KernelSU 的玻璃参数固化成常量 +
// 工厂，**顶栏与底栏都从这里取值**，保证两栏是同一种玻璃。
//
// 【来源】
//   refs/kernelsu/BottomBar.kt            → BlurredBar（顶栏 / 贴边底栏）
//   refs/kernelsu/FloatingBottomBar.kt    → 悬浮底栏
//   refs/kernelsu/liquid/Vibrancy.kt      → vibrancy()
//   refs/kernelsu/liquid/InnerShadow.kt   → innerShadow()
//   refs/miuix-blur/BackdropEffects.kt    → blur() 的 sigma 换算
//
// 【为什么机制不能照搬，只能对齐参数】
//
// KernelSU 用 Miuix KMP（Compose）的 `LayerBackdrop`，录的是 `GraphicsLayer`
// —— **绘制指令（display list）**，且在 `DrawModifierNode.draw()` 这条绘制链
// 的必经之路上录制，所以滚动时每帧都会重录，**不会被重绘边界截断**。
//
// Flutter 侧没有等价物：`RenderViewportBase.isRepaintBoundary => true`
// （`rendering/viewport.dart:752`），滚动时位于 viewport **之上**的捕获节点
// 根本收不到 `paint()`，只能靠 `toImageSync()` 录位图（整屏 1264×2780 ≈
// 14MB/帧）。真机实测滚动期间只有 ~19 次/秒 → 表现为「停住 → 跳一下 → 再停住」。
//
//   → 所以**机制**继续用 `BackdropFilter`（由合成器在合成时求值，与重绘边界
//     无关，永远与当前帧同步），只把 KernelSU 的**参数与设计**搬过来。
//     详见 `miuix_liquid_glass_nav_bar.dart` 的文件头。
//
// 【能搬 / 搬不了】
//   ✅ 模糊半径、色调、vibrancy（饱和度 1.5）、双层几何、按压放大、图标放大、
//      rubber band、innerShadow、dropShadow
//   ❌ `lens()` 折射 / 色差 —— 需要 `ImageFilter.shader`（**仅 Impeller 可用**）
//   ❌ 幽灵层 + `CombinedBackdrop` —— 需要 `GraphicsLayer` 录制
//   ❌ 重力感应高光 —— 需要加速度计（`rememberDeviceTilt`）
// ============================================================================

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// KernelSU 对齐的玻璃规格。
abstract final class MiuixGlassSpec {
  // ── 通用换算 ────────────────────────────────────────────────────────────

  /// 模糊半径 → sigma 的换算系数。
  ///
  /// 顶栏（`miuix_top_app_bar.dart`）与 KernelSU（`BackdropEffects.blur`）用的
  /// 都是这一个值：`sigma = radius * 0.45`。
  static const double blurRadiusToSigma = .45;

  /// 把 dp 模糊半径换算成 `BackdropFilter` 要的 sigma。
  static double sigmaOf(double blurRadius) =>
      blurRadius.clamp(0.0, 150.0) * blurRadiusToSigma;

  // ── 顶栏 / 贴边底栏：KernelSU `BlurredBar`（BottomBar.kt） ──────────────
  //
  //   Modifier.textureBlur(backdrop, shape = RectangleShape, blurRadius = 25f,
  //     colors = BlurColors(blendColors = listOf(
  //       BlendColorEntry(color = surface.copy(0.87f)))))
  //
  // 调用方把 barColor 设成 Color.Transparent，所以**整条栏的颜色全部来自
  // 这层 87% 的 surface 色调** —— 这是 HyperOS 顶栏那种「磨砂得几乎实心、
  // 只透出一点点底纹」的来源。

  /// 顶栏模糊半径（dp）。
  static const double topBarBlurRadius = 25;

  /// 顶栏色调不透明度：`surface @ .87`。
  static const double topBarTintAlpha = .87;

  // ── 悬浮底栏：KernelSU `FloatingBottomBar`（FloatingBottomBar.kt） ──────
  //
  //   effects = {
  //     padding = maxOf(padding, 40.dp.toPx())
  //     vibrancy()                      // saturation 1.5
  //     blur(4.dp.toPx(), 4.dp.toPx())  // ← 注意是**像素**
  //     lens(refractionHeight = 24.dp.toPx(), refractionAmount = 24.dp.toPx())
  //   }
  //
  // `blur()` 的入参是像素（`BackdropEffects.kt`：「Horizontal blur radius in
  // pixels」），4.dp 在 dpr 3.5 上 = 14px → sigma 6.3。
  // 我们的 `blurRadius` 名义上是 dp（sigma = dp × .45），所以取 14。
  //
  // 也就是说：**悬浮底栏的模糊比顶栏轻一半多**（6.3 vs 11.25），
  // 这符合 HyperOS 的观感 —— 顶栏是重磨砂，悬浮胶囊是轻霜。

  /// 悬浮底栏模糊半径（dp）。sigma 实际为 6.3。
  static const double navBlurRadius = 14;

  /// 悬浮底栏玻璃底色的不透明度：
  /// `containerColor = if (isBlurEnabled) surfaceContainer.copy(0.4f) else surfaceContainer`。
  ///
  /// ⚠️ 注意底色是 **`surfaceContainer`** 而不是顶栏的 `surface`，
  /// 且只有 40% —— 所以底栏能透出 60% 的背景，vibrancy 在这里才看得出来。
  static const double navContainerAlpha = .4;

  /// `vibrancy()` = `colorControls(brightness = 0f, contrast = 1f, saturation = 1.5f)`。
  static const double navVibrancy = 1.5;

  // ── 双层几何 ────────────────────────────────────────────────────────────

  /// 玻璃外壳高度：`Row(Modifier.height(64.dp))`。
  static const double navShellHeight = 64;

  /// 玻璃内容层高度：`.height(56.dp)`（= 外壳 64 − 上下各 4 的 inset）。
  static const double navContentHeight = 56;

  /// 内边距：`.padding(4.dp)` / `.padding(horizontal = 4.dp)`。
  static const double navInset = 4;

  // ── 阴影 ────────────────────────────────────────────────────────────────

  /// `dropShadow(radius = 10.dp, color = Black, alpha = 0.2f(深) / 0.1f(浅))`。
  ///
  /// Compose 的 `Shadow.radius` 与 Flutter 的 `BoxShadow.blurRadius` 都近似
  /// 「高斯 sigma」，所以直接照搬 10，不再走 Miuix 的 `/3`（那是源端像素口径）。
  static const double navShadowRadius = 10;
  static const double navShadowAlphaDark = .2;
  static const double navShadowAlphaLight = .1;

  /// 悬浮底栏外阴影（KernelSU 口径，与主题无关地按明暗取 alpha）。
  static List<BoxShadow> navShadow({required bool dark}) => [
    BoxShadow(
      color: Colors.black.withValues(
        alpha: dark ? navShadowAlphaDark : navShadowAlphaLight,
      ),
      blurRadius: navShadowRadius,
    ),
  ];

  // ── 按压（`DampedDragAnimation` + `pressProgress`） ──────────────────────

  /// `pressedScale = 78f / 56f` —— 选中 pill 按下时的缩放。
  ///
  /// ⚠️ 是 **放大**（56 → 78），不是缩小。包里 `MiuixGlassMotion.pressScale`
  /// 是「内缩 10dp」即缩小，方向相反，别混用。
  static const double navPressScale = 78 / 56;

  /// 外壳按下时的放大：`lerp(1f, 1f + 16.dp.toPx() / width, pressProgress)`。
  ///
  /// 注意这是**像素**增量除以宽度，所以实际放大比例随屏幕宽度变化
  /// （313dp 宽时约 +5%）。这里存的是 dp 值，换算在调用处做。
  static const double navPressShellGrow = 16;

  /// 图标按下时的放大：`lerp(1f, 1.2f, pressProgress)`。
  static const double navPressIconScale = 1.2;

  /// 拖动越界时的 rubber band 位移上限：`rubberBandPx = 4.dp.toPx()`。
  static const double navRubberBand = 4;

  // ── 选中 pill 的填充与内阴影 ─────────────────────────────────────────────

  /// pill 静止时的填充不透明度（浅色底用黑、深色底用白）：
  /// `drawRect(color = 黑/白, alpha = 0.1f * (1f - pressProgress))`。
  ///
  /// ⚠️ KernelSU 是**按下变淡**（让折射/放大的内容透出来），与包里
  /// `MiuixGlassNavigationBar` 的「按下变亮（.06 → .16）」方向相反。
  /// 用户 2026-09-22 明确「按 kernelsu 的来」，故取 KernelSU 口径。
  static const double navPillFillAlpha = .1;

  /// pill 按下时**额外**叠的一层黑：`drawRect(Color.Black.copy(alpha = 0.03f * progress))`。
  static const double navPillPressFillAlpha = .03;

  /// `innerShadow(radius = 8.dp * pressProgress, color = Black@.15, alpha = pressProgress)`。
  static const double navPillInnerShadowRadius = 8;
  static const double navPillInnerShadowAlpha = .15;

  // ── 滤镜工厂 ────────────────────────────────────────────────────────────

  /// 饱和度矩阵（亮度加权，保持亮度不变）。
  ///
  /// 等价于 KernelSU 的 `colorControls(saturation = 1.5f)`。
  static ColorFilter saturationFilter(double saturation) =>
      _saturationCache.putIfAbsent(saturation, () {
        final s = saturation;
        const lumR = .2126, lumG = .7152, lumB = .0722;
        final inv = 1 - s;
        final r = inv * lumR, g = inv * lumG, b = inv * lumB;
        return ColorFilter.matrix(<double>[
          r + s, g, b, 0, 0, //
          r, g + s, b, 0, 0, //
          r, g, b + s, 0, 0, //
          0, 0, 0, 1, 0, //
        ]);
      });

  static final Map<double, ColorFilter> _saturationCache = {};

  /// 玻璃滤镜：模糊 +（可选）vibrancy。
  ///
  /// ⚠️ `ImageFilter.compose({outer, inner})` 的语义是 **inner 先、outer 后**
  /// （`dart:ui` 里 `toString()` 写作 `source -> inner -> outer -> result`），
  /// 所以「先模糊再提饱和」要把饱和放 `outer`。
  ///
  /// ⚠️ `ColorFilter implements ImageFilter`（`dart:ui/painting.dart:4073`），
  /// 所以可以直接塞进 `BackdropFilter` 的 `filter`。
  static ui.ImageFilter glassFilter({
    required double blurRadius,
    double saturation = navVibrancy,
  }) {
    final sigma = sigmaOf(blurRadius);
    final blur = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    if (saturation == 1) return blur;
    return ui.ImageFilter.compose(
      outer: saturationFilter(saturation),
      inner: blur,
    );
  }
}
