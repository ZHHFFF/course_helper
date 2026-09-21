#version 460 core
// 液态玻璃 fragment shader。
//
// 移植自 rdev/liquid-glass-react（MIT）的 SVG 滤镜方案，用 GLSL 重写。
// 原方案用 SVG 的 feDisplacementMap 对**背后已模糊的图层**做位移：
//   · 圆角矩形 SDF 算"到边缘的距离"
//   · 只在靠近边缘处产生位移，中心完全不动 → 这就是"边缘折射"
//   · R/G/B 三通道用递减的位移量分别采样 → 边缘出现色散（彩虹边）
//
// Flutter 的 FragmentProgram 拿不到"背后的像素"（无法直接采背景），
// 所以这里改成：**接收一个已模糊的背景纹理 + 位移图**，在其中采样。
// 调用方负责把 BackdropFilter 的结果作为 sampler 传进来。
//
// 但 Flutter 的 BackdropFilter 结果无法直接作为纹理 —— 所以本 shader
// 走另一条路：自己合成"玻璃外观"（折射后的高光 + 色散边缘），
// 叠在真实的 BackdropFilter 之上。这样既保留真模糊，又拿到折射观感。

#include <flutter/runtime_effect.glsl>

// ── uniforms ──
uniform vec2 uSize;          // 玻璃尺寸（逻辑像素）
uniform float uRadius;       // 圆角半径（像素）
uniform float uDisplacement; // 位移强度（对应 displacementScale，默认 25）
uniform float uAberration;   // 色差强度（对应 aberrationIntensity，默认 2）
uniform float uTint;         // 玻璃染色不透明度（默认 0.11，按住 0.25）
uniform float uEdgeWidth;    // 边缘折射带宽度（相对尺寸，默认 0.15）
uniform float uShift;        // 鼠标/手指位置对高光的影响（0~1）

out vec4 fragColor;

// 圆角矩形有符号距离场：返回负值在内部、正值在外部、0 在边界
float roundedRectSDF(vec2 p, vec2 halfSize, float radius) {
  vec2 q = abs(p) - halfSize + radius;
  return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - radius;
}

float smoothStep(float a, float b, float t) {
  t = clamp((t - a) / (b - a), 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;      // [0,1]
  vec2 centered = uv - 0.5;                      // [-0.5,0.5]

  // ── ① 到边缘的距离 ──
  // 半尺寸留出圆角半径的余量，让 SDF 形状与容器圆角一致
  vec2 halfSize = vec2(0.5) - vec2(uRadius / uSize.x, uRadius / uSize.y);
  float dist = roundedRectSDF(centered, halfSize, min(uRadius / uSize.x, uRadius / uSize.y));

  // ── ② 边缘强度：中心 0、边缘 1 ──
  // 对齐原方案 smoothStep(0.8, 0, dist - 0.15)
  // 即：距边缘 > 0.15 的区域完全不折射，越贴边折射越强
  float edge = smoothStep(0.0, uEdgeWidth, -dist);
  edge = pow(edge, 1.6);   // 让折射带更集中在最外圈

  // ── ③ 折射方向：从中心指向外侧的单位向量 ──
  vec2 dir = normalize(centered + vec2(1e-6));

  // ── ④ 三通道色差边缘 ──
  // 原方案对 R/G/B 用递减的位移量，这里直接算三通道的边缘亮度差。
  // 视觉目标是：玻璃最外圈出现一道极细的彩色亮线（红/蓝分居两侧）。
  float ab = uAberration * 0.012;
  float edgeR = smoothStep(0.0, uEdgeWidth + ab, -dist);
  float edgeB = smoothStep(0.0, uEdgeWidth - ab, -dist);

  // 色散：R 带偏一侧、B 带偏另一侧，G 居中
  vec3 aberration = vec3(edgeR - edge, 0.0, edge - edgeB);
  aberration *= uDisplacement / 25.0;   // 位移越强，色散越明显

  // ── ⑤ 玻璃填充 + 高光 ──
  // 基础填充色（白）
  vec3 fill = vec3(1.0);

  // 上缘高光：光从上方来，顶边最亮
  float topSheen = smoothStep(0.0, 0.42, -centered.y) * edge;
  // 手指位置影响高光（对应原方案的 mouse tracking）
  float sideSheen = smoothStep(0.0, 0.6, -centered.x) * edge * uShift;

  float alpha = uTint;                        // 玻璃本身很透
  alpha += edge * 0.22;                       // 边缘略实，体现厚度
  alpha += topSheen * 0.14;                   // 上缘高光
  alpha = clamp(alpha, 0.0, 0.92);

  // 玻璃本体颜色：白 + 上缘更白
  vec3 color = fill + vec3(topSheen * 0.18 + sideSheen * 0.06);

  // 把色偏加进去（冷边偏蓝、暖边偏红）
  color.r += max(aberration.r, 0.0) * 0.9;
  color.b += max(aberration.b, 0.0) * 0.9;
  color.g += max(aberration.g, 0.0) * 0.4;

  // ── ⑥ 最外圈一道细亮线（玻璃边缘反光）──
  float rim = smoothStep(0.0, 0.012, -dist) * smoothStep(0.055, 0.012, -dist);
  color += vec3(rim) * 0.55;
  alpha += rim * 0.30;

  fragColor = vec4(clamp(color, 0.0, 1.0), alpha);
}
