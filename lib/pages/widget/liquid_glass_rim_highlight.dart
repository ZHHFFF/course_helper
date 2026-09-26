// ============================================================================
// 方向性高光（Highlight.Default）—— 移植 refs/kyant/HighlightModifier.kt +
//                                     refs/kyant/Shaders.kt 的
//                                     `DefaultHighlightShaderString`
// ============================================================================
//
// 【上游怎么画的】（HighlightModifier.kt 的 HighlightNode.draw）
//
//   ```kotlin
//   paint.color = highlight.style.color                    // White 0.5
//   paint.strokeWidth = ceil(width.toPx().coerceAtMost(minDimension/2)) * 2f
//   paint.blur(highlight.blurRadius.toPx())
//   paint.setRuntimeShader(shader)                          // DefaultHighlightShaderString
//
//   highlightLayer.alpha = highlight.alpha
//   highlightLayer.blendMode = highlight.style.blendMode    // BlendMode.Plus
//   highlightLayer.record(safeSize) {
//       canvas.clipOutline(outline)        // ★ 裁到形状内部
//       canvas.drawOutline(outline, paint) // ★ 用 Stroke 画形状轮廓
//   }
//   ```
//
//   三个要点：
//   1. 它是**形状轮廓的描边**，不是填充，也不是渐变
//   2. `strokeWidth` 有个反直觉的算法：
//      `ceil(width.toPx()) * 2` —— 0.5dp @ dpr3.5 → `ceil(1.75)=2` → **4px**
//      描边会向内外各扩 strokeWidth/2，但被 `clipOutline` 裁掉外侧
//   3. 整层用 `alpha` 与 `BlendMode.Plus` 合成
//
// 【为什么不能用 Gradient 模拟】
//   上游 shader 用 **SDF 梯度 · 光向**：
//     `intensity = pow(abs(dot(grad, normal)), falloff)`
//   内部梯度≈0 → 不亮；朝向光源那一侧边缘梯度与光向对齐 → 最亮。
//   这产生的是「随形状与光照方向变化」的方向性描边，
//   普通线性渐变无法表达（尤其胶囊两端与上下边的亮度分布完全不同）。
//
// 【坐标空间（与折射不同，别搞混）】
//   本 shader 走 `Paint.shader`，`FlutterFragCoord()` 来自
//   `runtime_effect.vert` 的 `_fragCoord = position` —— 即**画布局部坐标 = 逻辑像素**。
//   而折射走 `ImageFilter.shader`，其 `size` 是**绑定纹理尺寸 = 物理像素**。
//   → 本文件的 size / cornerRadii 一律用**逻辑像素**，不要再乘 dpr。
// ============================================================================

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'liquid_glass_shader_filter.dart';

/// 持有高光 shader 实例
///
/// ⚠️ `FragmentShader` 带 uniform 状态，必须按**角色**持有并复用，
///    不能全局共用一个实例（同帧多个使用者会互相覆盖参数）。
class LiquidGlassRimHighlightShader {
  ui.FragmentShader? _shader;

  /// 配置 uniform 并返回可用的 shader；不可用时返回 null（调用方降级）
  ui.FragmentShader? configure({
    required Size size,
    required List<double> cornerRadii,
    required Color color,
    required double angleRad,
    required double falloff,
  }) {
    if (!LiquidGlassShaderLibrary.isHighlightAvailable) return null;

    var s = _shader;
    if (s == null) {
      s = LiquidGlassShaderLibrary.newHighlightShader();
      if (s == null) return null;
      _shader = s;
    }

    // 索引与上游声明顺序一致：
    // 0,1 = size | 2..5 = cornerRadii | 6..9 = color | 10 = angle | 11 = falloff
    s.setFloat(0, size.width);
    s.setFloat(1, size.height);
    for (var i = 0; i < 4; i++) {
      s.setFloat(2 + i, i < cornerRadii.length ? cornerRadii[i] : 0.0);
    }
    s.setFloat(6, color.r);
    s.setFloat(7, color.g);
    s.setFloat(8, color.b);
    s.setFloat(9, color.a);
    s.setFloat(10, angleRad);
    s.setFloat(11, falloff);
    return s;
  }

  void dispose() {
    _shader?.dispose();
    _shader = null;
  }
}

/// 绘制方向性高光描边
class LiquidGlassRimHighlightPainter extends CustomPainter {
  const LiquidGlassRimHighlightPainter({
    required this.shaderHolder,
    this.width = 0.5,
    this.blurRadius = 0.25,
    this.alpha = 1.0,
    this.color = const Color(0x80FFFFFF),
    this.angleDeg = 45.0,
    this.falloff = 1.0,
  });

  final LiquidGlassRimHighlightShader shaderHolder;

  /// 对应上游 `Highlight.width`（默认 0.5dp）
  final double width;

  /// 对应上游 `Highlight.blurRadius`（默认 width/2 = 0.25dp）
  final double blurRadius;

  /// 对应上游 `Highlight.alpha`
  final double alpha;

  /// 对应上游 `HighlightStyle.Default.color`（默认 White 0.5）
  final Color color;

  /// 对应上游 `HighlightStyle.Default.angle`（默认 45°）
  final double angleDeg;

  /// 对应上游 `HighlightStyle.Default.falloff`（默认 1）
  final double falloff;

  @override
  void paint(Canvas canvas, Size size) {
    if (alpha <= 0 || width <= 0 || size.isEmpty) return;

    // 形状是 Capsule → 四角半径均为 minDimension/2
    final radius = size.shortestSide / 2.0;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final cornerRadii = <double>[radius, radius, radius, radius];

    // 上游：color 传给 shader 时 alpha 置 1，整体 alpha 由图层承担
    final shader = shaderHolder.configure(
      size: size,
      cornerRadii: cornerRadii,
      color: color.withValues(alpha: 1.0),
      angleRad: angleDeg * math.pi / 180.0,
      falloff: falloff,
    );
    if (shader == null) return;

    // 上游 strokeWidth = ceil(width.toPx().coerceAtMost(minDimension/2)) * 2f
    // ⚠️ 反直觉但必须照搬：0.5dp @ dpr3.5 → ceil(1.75)=2 → **4px**
    //    （`ceil` 是 num 的方法，dart:math 没有顶层 ceil）
    final clamped = math.min(width, size.shortestSide / 2.0);
    final strokeWidth = clamped.ceilToDouble() * 2.0;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color.withValues(alpha: 1.0)
      ..shader = shader
      ..isAntiAlias = true;
    if (blurRadius > 0) {
      paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blurRadius);
    }

    // 上游把整层设成 alpha + BlendMode.Plus 再合成
    final layerPaint = Paint()
      ..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0))
      ..blendMode = BlendMode.plus;

    canvas.saveLayer(Offset.zero & size, layerPaint);
    // ★ clipOutline：把描边的外侧裁掉，只留形状内侧那一半
    canvas.clipRRect(rrect);
    canvas.drawRRect(rrect, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(LiquidGlassRimHighlightPainter old) =>
      old.width != width ||
      old.blurRadius != blurRadius ||
      old.alpha != alpha ||
      old.color != color ||
      old.angleDeg != angleDeg ||
      old.falloff != falloff ||
      !identical(old.shaderHolder, shaderHolder);
}
