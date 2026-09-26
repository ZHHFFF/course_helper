// ============================================================================
// InteractiveHighlight —— KernelSU / AndroidLiquidGlass 的交互辉光移植
// ============================================================================
//
// 来源：`refs/kernelsu/InteractiveHighlight.kt`
//   package me.weishu.kernelsu.ui.component.miuix.animation
//
// 【它是什么】
//
//   按下时在**指示器所在位置**叠加一圈径向辉光，随指示器移动，松手后淡出。
//   上游的 AGSL 着色器只有 6 行：
//
//     uniform float2 size;
//     layout(color) uniform half4 color;
//     uniform float radius;
//     uniform float2 position;
//     half4 main(float2 coord) {
//         float dist = distance(coord, position);
//         float intensity = smoothstep(radius, radius * 0.5, dist);
//         return color * intensity;
//     }
//
//   ⚠️ `smoothstep(radius, radius*0.5, dist)` 的**两个边界是反的**：
//      edge0 = radius（大），edge1 = radius*0.5（小）。
//      smoothstep 在 `x >= edge0` 时为 0、`x <= edge1` 时为 1 ——
//      所以是「半径内 0.5 倍范围内全亮、到 radius 处衰减到 0」的**内亮外暗**辉光。
//      参数写反会得到完全相反的效果（中间黑、边缘亮）。
//
//   叠加方式（上游）：
//     1. 先铺一层 `Color.White.copy(0.06f * progress)` 的整块矩形
//     2. 再叠一层径向辉光 `Color.White.copy(0.12f * progress)`
//     两层都用 **BlendMode.Plus（加法混合）**
//
//   半径 = `size.minDimension * 1.2` —— 比元素本身大，让辉光溢出边缘。
//
// 【Flutter 侧的等价实现】
//
//   - 着色器 → `ui.Gradient.radial`。`smoothstep` 用多段 stop 近似
//     （3t²-2t³ 采样成 6 个 stop），比线性渐变更接近原曲线。
//   - `BlendMode.Plus` → Flutter 同名枚举 `BlendMode.plus`。
//   - `Animatable` → 由 `LiquidGlassNavController` 的 `pressProgress` 驱动。
//
// 【为什么位置跟指示器而不是手指】
//
//   上游在 `FloatingBottomBar` 里把 `position` 覆写成指示器中心：
//     ```kotlin
//     position = { size, _ ->
//         Offset((dampedDragAnimation.value + 0.5f) * tabWidthPx + panelOffset, size.height / 2f)
//     }
//     ```
//   所以辉光**跟着胶囊走**，而不是跟着手指 —— 视觉上像"胶囊自己在发光"。
// ============================================================================

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 绘制指示器位置的径向辉光
class LiquidGlassHighlightPainter extends CustomPainter {
  const LiquidGlassHighlightPainter({
    required this.progress,
    required this.center,
    this.color = Colors.white,
  });

  /// 按压进度 0~1（辉光强度与它成正比）
  final double progress;

  /// 辉光中心（指示器中心，局部坐标）
  final Offset center;

  final Color color;

  /// `smoothstep(radius, radius*0.5, dist)` 的近似采样点。
  ///
  /// 归一化后 `u = (dist/radius - 0.5) / 0.5`，强度 = `1 - (3u² - 2u³)`。
  static const _stops = <double>[0.0, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0];
  static const _intensities = <double>[
    1.0, // dist = 0        → 全亮
    1.0, // dist = 0.5r     → 全亮（smoothstep 的 edge1）
    0.896, // u = 0.2
    0.648, // u = 0.4
    0.352, // u = 0.6
    0.104, // u = 0.8
    0.0, // dist = r        → 熄灭（edge0）
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.0 || size.isEmpty) return;

    // 1. 整块淡白（上游 Color.White.copy(0.06f * progress)）
    final basePaint = Paint()
      ..blendMode = BlendMode.plus
      ..color = color.withValues(alpha: 0.06 * progress);
    canvas.drawRect(Offset.zero & size, basePaint);

    // 2. 径向辉光（上游 Color.White.copy(0.12f * progress)）
    //    半径取 minDimension * 1.2 —— 让辉光溢出元素边缘
    final radius = size.shortestSide * 1.2;
    final peak = color.withValues(alpha: 0.12 * progress);
    final colors = <Color>[
      for (final i in _intensities)
        peak.withValues(alpha: peak.a * i),
    ];

    final glowPaint = Paint()
      ..blendMode = BlendMode.plus
      ..shader = ui.Gradient.radial(
        // 中心按上游做钳制，避免拖到栏外时辉光跑飞
        Offset(
          center.dx.clamp(0.0, size.width),
          center.dy.clamp(0.0, size.height),
        ),
        radius,
        colors,
        _stops,
      );

    canvas.drawRect(Offset.zero & size, glowPaint);
  }

  @override
  bool shouldRepaint(LiquidGlassHighlightPainter old) =>
      old.progress != progress ||
      old.center != center ||
      old.color != color;
}
