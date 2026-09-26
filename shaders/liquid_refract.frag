#version 320 es
// ============================================================================
// Liquid Glass 折射着色器（圆角矩形 SDF 折射 + 7 抽光谱色散）
// ============================================================================
//
// 移植自 Kyant0/AndroidLiquidGlass (Apache 2.0) 的 Lens.kt：
//   ROUNDED_RECT_REFRACTION_WITH_DISPERSION_SHADER（AGSL）
//   经 KernelSU 的 refs/kernelsu/Lens.kt 中转。
//
// 【AGSL → Flutter GLSL 的四处必要改写】
//
// 1. `uniform shader content` → `uniform sampler2D u_content`
//    AGSL 用 `content.eval(coord)` 且 **coord 是像素坐标**；
//    GLSL 用 `texture(sampler, uv)` 且 **uv 是归一化坐标 (0~1)**。
//    → 所有采样点都要先除以 u_size。见下方 `sampleContent()`。
//
// 2. `half4 main(float2 coord)` → `void main()` + `FlutterFragCoord()`
//    AGSL 把片元坐标作为入参传入；GLSL 靠内建函数取。
//
// 3. `uniform float2 size` → `uniform vec2 u_size`，且**必须声明为第一个 uniform**
//    `ImageFilter.shader` 的契约（见 sky_engine/lib/ui/painting.dart:4426）：
//      「第一个 uniform 必须是 vec2，引擎会把它设成**绑定纹理的尺寸**」
//    → 这个值**不要**用 setFloat 传，引擎自己填。Dart 侧的自定义 float
//      从 index 2 开始（index 0~1 被 u_size 占用）。
//
// 4. GLES 后端 Y 轴反向
//    同契约文档：「Impeller 用 OpenGL(ES) 后端时 Y 轴反向，自定义着色器
//    必须在 GLES 上翻转 Y，否则会上下颠倒」
//    → 见 `toUv()` 里的 `IMPELLER_TARGET_OPENGLES` 分支。
//
// 【算法说明（与原实现一致）】
//
//   对圆角矩形求 SDF（有向距离场），只对**边缘 refractionHeight 宽度内的像素**
//   做折射：越靠近边缘，采样点朝法线方向偏移越远（circleMap 让偏移量呈圆形
//   渐变，模拟真实透镜的弧度）。色散则在偏移后的坐标上做 **7 次采样**，
//   分别取红/橙/黄/绿/青/蓝/紫通道并按权重叠加 —— 权重和为 1，因此不会
//   改变整体亮度，只让边缘出现微弱的光谱分离。
//
// 【⚠️ 待真机验证的 4 点】
//   a) u_size 是否等于底栏尺寸（BackdropFilter 的绑定纹理是裁剪区，非全屏）
//   b) premultiplied alpha 语义（7 抽累加后 alpha 权重和也应为 1）
//   c) GLES Y 翻转是否生效
//   d) Skia 后端下本文件不参与（Dart 侧已做能力探测并降级）
// ============================================================================

precision highp float;

#include <flutter/runtime_effect.glsl>

// ── 引擎自动填充（必须第一个）───────────────────────────────────────────
// 绑定纹理的尺寸（即 BackdropFilter 的裁剪区尺寸 = 底栏尺寸）
uniform vec2 u_size;

// ── 引擎自动绑定（sampler 不占用 setFloat 的 index）─────────────────────
uniform sampler2D u_content;

// ── Dart 侧通过 setFloat 传入（index 见下方注释）────────────────────────
uniform float u_refractionHeight;   // index 2  折射带宽度（px）
uniform float u_refractionAmount;   // index 3  最大折射位移（px）
uniform float u_depthEffect;        // index 4  0/1，是否叠加朝心的深度感
uniform float u_chromaticAberration;// index 5  色散强度，0 = 关闭（省 6 次采样）
uniform vec4 u_cornerRadii;         // index 6~9  TL, TR, BR, BL
uniform vec2 u_offset;              // index 10~11
uniform float u_zoom;               // index 12  采样放大倍率（1.0 = 不放大）

// 放大倍率 = 1.0 时无操作；>1 时绕中心放大采样内容。
// 对应 Compose 的 `layerBlock { scaleX = ...; scaleY = ... }` —— 在**采样层**
// 做缩放，而不是把渲染结果拉伸。这是「放大时内容真的被放大」与
// 「只是把糊掉的图拉大」的区别所在。

out vec4 frag_color;

// ---------------------------------------------------------------- SDF 工具

/// 按象限取对应的圆角半径（AGSL 原样移植）
float radiusAt(vec2 coord, vec4 radii) {
  if (coord.x >= 0.0) {
    return coord.y <= 0.0 ? radii.y : radii.z;
  } else {
    return coord.y <= 0.0 ? radii.x : radii.w;
  }
}

/// 圆角矩形的有向距离：< 0 在内部，> 0 在外部
float sdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
  float outside = length(max(cornerCoord, 0.0)) - radius;
  float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
  return outside + inside;
}

/// SDF 的梯度（≈ 边缘法线方向）
vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
  vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
  if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
    return sign(coord) * normalize(max(cornerCoord, 0.0));
  } else {
    float gradX = step(cornerCoord.y, cornerCoord.x);
    return sign(coord) * vec2(gradX, 1.0 - gradX);
  }
}

/// 圆形映射：让折射位移沿边缘呈圆弧渐变（透镜感的关键）
float circleMap(float x) {
  return 1.0 - sqrt(1.0 - x * x);
}

// ------------------------------------------------- 坐标换算（含 GLES Y 翻转）

/// 像素坐标 → 归一化 UV
vec2 toUv(vec2 px) {
  vec2 uv = px / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

/// 绕中心施加放大倍率（u_zoom = 1.0 时恒等）
vec2 applyZoom(vec2 px) {
  if (u_zoom <= 0.0 || abs(u_zoom - 1.0) < 1e-4) return px;
  vec2 center = u_size * 0.5;
  return (px - center) / u_zoom + center;
}

/// 按像素坐标采样背景（替代 AGSL 的 content.eval(coord)）
///
/// 采样前统一施加放大 —— 折射位移与放大都在**坐标空间**完成，
/// 所以放大后的内容仍会被正确折射（而不是先糊再拉大）。
vec4 sampleContent(vec2 px) {
  return texture(u_content, toUv(applyZoom(px)));
}

// -------------------------------------------------------------------- main

void main() {
  // AGSL 的 `main(float2 coord)` 入参 → 这里从内建函数取
  vec2 coord = FlutterFragCoord().xy;

  vec2 halfSize = u_size * 0.5;
  vec2 centeredCoord = (coord + u_offset) - halfSize;

  float radius = radiusAt(centeredCoord, u_cornerRadii);

  // 距边缘超过折射带宽 → 直接返回原样（内部平坦区）
  float sd = sdRoundedRect(centeredCoord, halfSize, radius);
  if (-sd >= u_refractionHeight) {
    frag_color = sampleContent(coord);
    return;
  }

  // 只保留内部（负）部分
  sd = min(sd, 0.0);

  // 折射位移量：边缘最强，向内衰减到 0
  float d = circleMap(1.0 - (-sd) / u_refractionHeight) * u_refractionAmount;

  // 法线方向 = SDF 梯度（+ 可选的朝心分量，制造厚度/凹陷感）
  float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
  vec2 grad = normalize(
      gradSdRoundedRect(centeredCoord, halfSize, gradRadius)
      + u_depthEffect * normalize(centeredCoord));

  vec2 refractedCoord = coord + d * grad;

  // ── 无版散快路径：省掉 6 次采样 ────────────────────────────────────────
  if (u_chromaticAberration <= 0.0) {
    frag_color = sampleContent(refractedCoord);
    return;
  }

  // ── 7 抽光谱色散 ──────────────────────────────────────────────────────
  // 色散强度在四角最强（|x*y| 最大）、边中点最弱 —— 与原实现一致
  float dispersionIntensity = u_chromaticAberration
      * ((centeredCoord.x * centeredCoord.y) / (halfSize.x * halfSize.y));
  vec2 dispersedCoord = d * grad * dispersionIntensity;

  // 权重和 = 1（alpha 亦为 1），保持 premultiplied 语义不变
  vec4 color = vec4(0.0);

  vec4 red = sampleContent(refractedCoord + dispersedCoord);
  color.r += red.r / 3.5;
  color.a += red.a / 7.0;

  vec4 orange = sampleContent(refractedCoord + dispersedCoord * (2.0 / 3.0));
  color.r += orange.r / 3.5;
  color.g += orange.g / 7.0;
  color.a += orange.a / 7.0;

  vec4 yellow = sampleContent(refractedCoord + dispersedCoord * (1.0 / 3.0));
  color.r += yellow.r / 3.5;
  color.g += yellow.g / 3.5;
  color.a += yellow.a / 7.0;

  vec4 green = sampleContent(refractedCoord);
  color.g += green.g / 3.5;
  color.a += green.a / 7.0;

  vec4 cyan = sampleContent(refractedCoord - dispersedCoord * (1.0 / 3.0));
  color.g += cyan.g / 3.5;
  color.b += cyan.b / 3.0;
  color.a += cyan.a / 7.0;

  vec4 blue = sampleContent(refractedCoord - dispersedCoord * (2.0 / 3.0));
  color.b += blue.b / 3.0;
  color.a += blue.a / 7.0;

  vec4 purple = sampleContent(refractedCoord - dispersedCoord);
  color.r += purple.r / 7.0;
  color.b += purple.b / 3.0;
  color.a += purple.a / 7.0;

  frag_color = color;
}
