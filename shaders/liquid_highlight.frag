#version 320 es
precision highp float;

#include <flutter/runtime_effect.glsl>

// ============================================================================
// 方向性高光 —— 逐行移植自 refs/kyant/Shaders.kt 的 `DefaultHighlightShaderString`
// ============================================================================
//
// 上游（AGSL）：
//   uniform float2 size;  uniform float4 cornerRadii;
//   layout(color) uniform half4 color;
//   uniform float angle;  uniform float falloff;
//
// 【它不是"渐变"，是 SDF 梯度 · 光向】
//   grad   = gradSdRoundedRect(...)      // 形状边缘的法线场（内部≈0，边缘朝外）
//   normal = (cos(angle), sin(angle))    // 光照方向（上游 Default 用 45°）
//   d      = dot(grad, normal)
//   intensity = pow(abs(d), falloff)     // 内部→0，朝光的边缘→1
//   return color * intensity
//   → 所以它天然只在**朝向光源的那一侧边缘**亮起，形成方向性描边。
//
// ⚠️ 本 shader **没有 sampler**，它不作为 `ImageFilter.shader` 使用，
//    而是作为 `Paint.shader` 画在**形状轮廓的描边上**（见 Dart 侧
//    LiquidGlassRimHighlightPainter）。因此不受
//    "第一个 uniform 必须是 vec2 + 必须有 sampler" 那条约束。
//
// 【uniform 索引】
//   0,1 = size | 2..5 = cornerRadii | 6..9 = color | 10 = angle | 11 = falloff
//   ⚠️ 顺序与上游声明顺序一致（color 在 cornerRadii 与 angle 之间）。
//
// 【单位】同折射 shader —— size 与 FlutterFragCoord() 都是**物理像素**。
// ============================================================================

uniform vec2 size;
uniform vec4 cornerRadii;
uniform vec4 color;
uniform float angle;
uniform float falloff;

out vec4 frag_color;

// ---------------------------------------------------- RoundedRectSDF（逐字照搬）

float radiusAt(vec2 coord, vec4 radii) {
    if (coord.x >= 0.0) {
        if (coord.y <= 0.0) return radii.y;
        else return radii.z;
    } else {
        if (coord.y <= 0.0) return radii.x;
        else return radii.w;
    }
}

float sdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
    vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
    float outside = length(max(cornerCoord, 0.0)) - radius;
    float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
    return outside + inside;
}

vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
    vec2 cornerCoord = abs(coord) - (halfSize - vec2(radius));
    if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
        return sign(coord) * normalize(max(cornerCoord, 0.0));
    } else {
        float gradX = step(cornerCoord.y, cornerCoord.x);
        return sign(coord) * vec2(gradX, 1.0 - gradX);
    }
}

// -------------------------------------------------------------------------- main

void main() {
    vec2 coord = FlutterFragCoord().xy;

    vec2 halfSize = size * 0.5;
    vec2 centeredCoord = coord - halfSize;
    float radius = radiusAt(coord, cornerRadii);

    float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
    vec2 grad = gradSdRoundedRect(centeredCoord, halfSize, gradRadius);
    vec2 normal = vec2(cos(angle), sin(angle));
    float d = dot(grad, normal);
    float intensity = pow(abs(d), falloff);
    frag_color = color * intensity;
}
