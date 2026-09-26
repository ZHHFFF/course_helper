#version 320 es
precision highp float;

#include <flutter/runtime_effect.glsl>

// ============================================================================
// 折射 + 7 抽光谱色散 —— 逐行移植自 refs/kyant/Shaders.kt
//                           的 `RoundedRectRefractionWithDispersionShaderString`
// ============================================================================
//
// 与 `liquid_refract.frag` 的唯一差别是末尾的 7 抽色散段。
// 上游用**两份独立 shader**（不是同一份加开关），Flutter 侧同样拆成两个
// `.frag`，以保证与上游一一对应。
//
// 【色散公式（上游原式，不要改动）】
//   dispersionIntensity = chromaticAberration * ((centeredCoord.x * centeredCoord.y)
//                                               / (halfSize.x * halfSize.y))
//   dispersedCoord      = d * grad * dispersionIntensity
//
//   ⚠️ 该式在**横竖中轴线上恒为 0** → 色散**集中在四个角附近**，不是一圈连续彩环。
//      这是上游的设计，不是 bug。
//   ⚠️ 上游 `Lens.kt` 里 `chromaticAberration` 是**布尔**，用色散版时
//      uniform 固定传 `1f`。它不是 0~1 的强度参数。
//
// 【uniform 索引】
//   0,1 = size | 2,3 = offset | 4..7 = cornerRadii
//   8 = refractionHeight | 9 = refractionAmount | 10 = depthEffect
//   11 = chromaticAberration
// ============================================================================

uniform sampler2D u_content;

uniform vec2 size;
uniform vec2 offset;
uniform vec4 cornerRadii;
uniform float refractionHeight;
uniform float refractionAmount;
uniform float depthEffect;
uniform float chromaticAberration;

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

float circleMap(float x) {
    return 1.0 - sqrt(1.0 - x * x);
}

// ---------------------------------------------- 采样（替代 AGSL 的 content.eval）

vec4 evalContent(vec2 coord) {
    vec2 uv = coord / size;
#ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
#endif
    return texture(u_content, uv);
}

// -------------------------------------------------------------------------- main

void main() {
    vec2 coord = FlutterFragCoord().xy;

    vec2 halfSize = size * 0.5;
    vec2 centeredCoord = (coord + offset) - halfSize;
    float radius = radiusAt(coord, cornerRadii);

    float sd = sdRoundedRect(centeredCoord, halfSize, radius);
    if (-sd >= refractionHeight) {
        frag_color = evalContent(coord);
        return;
    }
    sd = min(sd, 0.0);

    float d = circleMap(1.0 - -sd / refractionHeight) * refractionAmount;
    float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
    vec2 grad = normalize(gradSdRoundedRect(centeredCoord, halfSize, gradRadius)
                          + depthEffect * normalize(centeredCoord));

    vec2 refractedCoord = coord + d * grad;

    // ------------------------------------------------------- 7 抽光谱色散（原式）
    float dispersionIntensity = chromaticAberration
        * ((centeredCoord.x * centeredCoord.y) / (halfSize.x * halfSize.y));
    vec2 dispersedCoord = d * grad * dispersionIntensity;

    vec4 color = vec4(0.0);

    vec4 red = evalContent(refractedCoord + dispersedCoord);
    color.r += red.r / 3.5;
    color.a += red.a / 7.0;

    vec4 orange = evalContent(refractedCoord + dispersedCoord * (2.0 / 3.0));
    color.r += orange.r / 3.5;
    color.g += orange.g / 7.0;
    color.a += orange.a / 7.0;

    vec4 yellow = evalContent(refractedCoord + dispersedCoord * (1.0 / 3.0));
    color.r += yellow.r / 3.5;
    color.g += yellow.g / 3.5;
    color.a += yellow.a / 7.0;

    vec4 green = evalContent(refractedCoord);
    color.g += green.g / 3.5;
    color.a += green.a / 7.0;

    vec4 cyan = evalContent(refractedCoord - dispersedCoord * (1.0 / 3.0));
    color.g += cyan.g / 3.5;
    color.b += cyan.b / 3.0;
    color.a += cyan.a / 7.0;

    vec4 blue = evalContent(refractedCoord - dispersedCoord * (2.0 / 3.0));
    color.b += blue.b / 3.0;
    color.a += blue.a / 7.0;

    vec4 purple = evalContent(refractedCoord - dispersedCoord);
    color.r += purple.r / 7.0;
    color.b += purple.b / 3.0;
    color.a += purple.a / 7.0;

    frag_color = color;
}
