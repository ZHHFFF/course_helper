#version 320 es
precision highp float;

#include <flutter/runtime_effect.glsl>

// The same capsule SDF controls both icon refraction and visibility.
// The full row remains available to sample across the lens edge.
uniform sampler2D u_content;
uniform vec2 size;
uniform vec4 lensRect; // normalized left, top, width, height in the input row
uniform float refractionHeight;
uniform float refractionAmount; // negative, matching Lens.kt

out vec4 frag_color;

vec4 contentAt(vec2 coord) {
    vec2 uv = coord / size;
#ifdef IMPELLER_TARGET_OPENGLES
    uv.y = 1.0 - uv.y;
#endif
    return texture(u_content, uv);
}

float sdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
    vec2 corner = abs(coord) - (halfSize - vec2(radius));
    return length(max(corner, 0.0)) - radius
        + min(max(corner.x, corner.y), 0.0);
}

vec2 gradSdRoundedRect(vec2 coord, vec2 halfSize, float radius) {
    vec2 corner = abs(coord) - (halfSize - vec2(radius));
    if (corner.x >= 0.0 || corner.y >= 0.0) {
        return sign(coord) * normalize(max(corner, 0.0));
    }
    float gradX = step(corner.y, corner.x);
    return sign(coord) * vec2(gradX, 1.0 - gradX);
}

float circleMap(float x) {
    return 1.0 - sqrt(1.0 - x * x);
}

void main() {
    vec2 coord = FlutterFragCoord().xy;
    vec2 halfSize = lensRect.zw * size * 0.5;
    vec2 centered = coord - (lensRect.xy * size + halfSize);
    float radius = min(halfSize.x, halfSize.y);
    float sd = sdRoundedRect(centered, halfSize, radius);
    if (sd >= 0.5) {
        frag_color = vec4(0.0);
        return;
    }

    float alpha = 1.0 - smoothstep(-0.5, 0.5, sd);
    if (-sd >= refractionHeight) {
        frag_color = contentAt(coord) * alpha;
        return;
    }

    float d = circleMap(1.0 + sd / refractionHeight) * refractionAmount;
    float gradRadius = min(radius * 1.5, min(halfSize.x, halfSize.y));
    vec2 grad = normalize(gradSdRoundedRect(centered, halfSize, gradRadius));
    vec2 refracted = coord + d * grad;

    frag_color = contentAt(refracted) * alpha;
}
