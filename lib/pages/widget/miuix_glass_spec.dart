// ============================================================================
// Miuix 玻璃口径（单一事实来源）
// ============================================================================
//
// 顶栏与底栏都从这里取值，保证两栏是**同一种玻璃**。
//
// 【来源】
//   flutter_miuix `MiuixTopAppBarDefaults`：
//     blurRadius = 24、blurTintAlpha = 0.55
//   refs/miuix-blur/BackdropEffects.kt → sigma 换算
//
// 【历史：为什么曾经有一大堆 KernelSU 常量，现在没了】
//
// v4.8.6 / v4.8.7 曾按 KernelSU（`refs/kernelsu/`）对齐过顶栏与底栏：
// 顶栏 25/.87 的「重磨砂近乎实心」，底栏是悬浮胶囊（双层 64/56 + inset 4、
// 按下放大 78/56、rubber band、innerShadow、dropShadow、vibrancy 饱和度 1.5……）。
//
// 2026-09-22 用户拍板**取消液态玻璃、取消悬浮底栏**，一切回到 Miuix 规范本身。
// 于是那一整套 KernelSU 参数（`navBlurRadius` / `navContainerAlpha` /
// `navVibrancy` / `navPressScale` / `navPill*` / `navShadow*` / `navInset` …）
// 连同自研的 `miuix_liquid_glass_nav_bar.dart` 一并删除。
//
// 【为什么机制当初不能照搬 KernelSU（保留这条结论，避免以后有人再踩）】
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
//   → 所以 Flutter 侧的玻璃**只能**用 `BackdropFilter`（由合成器在合成时求值，
//     与重绘边界无关，永远与当前帧同步）。本项目的顶栏与底栏都是这个机制。
//
// 【搬不了、且以后也别惦记的】
//   ❌ `lens()` 折射 / 色差 —— 需要 `ImageFilter.shader`（**仅 Impeller 可用**），
//      且 filter 输入只覆盖当前裁剪区，做折射得用嵌套 ClipRRect 外扩留余量
//   ❌ 幽灵层 + `CombinedBackdrop` —— 需要 `GraphicsLayer` 录制
//   ❌ 重力感应高光 —— 需要加速度计（`rememberDeviceTilt`）
// ============================================================================

/// Miuix 玻璃口径。
abstract final class MiuixGlassSpec {
  // ── 通用换算 ────────────────────────────────────────────────────────────

  /// 模糊半径 → sigma 的换算系数。
  ///
  /// `MiuixTopAppBar` 与 `BackdropEffects.blur` 用的都是这一个值：
  /// `sigma = radius * 0.45`。
  static const double blurRadiusToSigma = .45;

  /// 把 dp 模糊半径换算成 `BackdropFilter` 要的 sigma。
  static double sigmaOf(double blurRadius) =>
      blurRadius.clamp(0.0, 150.0) * blurRadiusToSigma;

  // ── 玻璃口径（顶栏 / 底栏共用） ─────────────────────────────────────────
  //
  // 取的就是 `MiuixTopAppBarDefaults` 的默认值 —— 顶栏调用处不传参数即用库默认，
  // 底栏（`miuix_glass_navigation_bar.dart`）从这里取，两栏因此完全一致。

  /// 模糊半径（dp）→ sigma 10.8。
  static const double barBlurRadius = 24;

  /// 色调不透明度：`surface @ .55`。
  ///
  /// 注意铺的是 `colors.surface`（浅色 `#F7F7F7` / 深色 `#000000`），
  /// 不是 `surfaceContainer`。深色下就是「55% 的黑」压在模糊层上。
  static const double barTintAlpha = .55;
}
