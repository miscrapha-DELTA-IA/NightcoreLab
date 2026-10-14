#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ---------------------------------------------------------------------------
// Liquid Marble: domain warping (fBM distorcendo fBM) + posterização com veios.
// Custo por pixel: 3+3+3+3+4 = 16 oitavas de value-noise (sem texturas, sem branches).
// ---------------------------------------------------------------------------

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Value noise com curva quíntica (sem vincos de grade).
static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// fBM com rotação entre oitavas (quebra o alinhamento da grade).
template <int OCT>
static inline float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < OCT; ++i) {
        v += a * vnoise(p);
        p = float2(0.8 * p.x + 0.6 * p.y, -0.6 * p.x + 0.8 * p.y) * 2.02 + 17.3;
        a *= 0.5;
    }
    return v;
}

// c1 = fundo/veios escuros · c2 = corpo · c3 = brilho/acento
static inline float3 ramp(float t, float3 c1, float3 c2, float3 c3) {
    float3 lo = mix(c1, c2, smoothstep(0.0, 0.5, t));
    return mix(lo, c3, smoothstep(0.5, 1.0, t));
}

[[ stitchable ]]
half4 liquidMarble(float2 position, half4 currentColor,
                   float2 size, float time,
                   half4 color1, half4 color2, half4 color3,
                   float reactiveDistortion, float beatPulse,
                   float pulseWarp, float pulseGlow)
{
    const float3 A = float3(color1.rgb);
    const float3 B = float3(color2.rgb);
    const float3 C = float3(color3.rgb);

    // 0 preserves the original marble exactly. A bounded uniform increases
    // the EXISTING domain warp; no extra noise octaves or shader passes.
    const float strength = clamp(reactiveDistortion, 0.0f, 1.0f);
    // Stage 12 Marble material: rhythm pulse (0 = previous pixels exactly;
    // every pulse term below is an added exact zero when beatPulse is 0).
    // Stage 12.5: the two pulse amounts come from VisualMaterial (defaults
    // 0.18 and 0.10, the former constants); the algorithm is unchanged.
    const float pulse = clamp(beatPulse, 0.0f, 1.0f);
    const float warpGain = clamp(pulseWarp, 0.0f, 0.5f);
    const float glowGain = clamp(pulseGlow, 0.0f, 0.3f);
    const float warp = 3.2f * (1.0f + 0.28f * strength + warpGain * pulse);

    // Coordenadas normalizadas pela menor dimensão (sem esticar em telas altas).
    float2 uv = (position - 0.5 * size) / min(size.x, size.y) * 1.9;

    // Redemoinho global: gira o domínio mais perto do centro -> espirais.
    float ang = exp(-0.5 * dot(uv, uv)) * (1.1 * sin(time * 0.2) + 0.9)
                * (1.0 + 0.16 * strength);
    float ca = cos(ang), sa = sin(ang);
    uv = float2(uv.x * ca - uv.y * sa, uv.x * sa + uv.y * ca);

    // Domain warping em duas camadas.
    float t = time * 0.15;
    float2 q = float2(fbm<3>(uv + float2(0.0, t)),
                      fbm<3>(uv + float2(5.2 - t, 1.3)));
    float2 r = float2(fbm<3>(uv + warp * q + float2(1.7 + 0.6 * t, 9.2)),
                      fbm<3>(uv + warp * q + float2(8.3, 2.8 - 0.5 * t)));
    float f = fbm<4>(uv + warp * r);

    // Campo escalar final (contraste alto) e quantização em níveis.
    float v = saturate((f * 1.5 + r.x * 0.6 + q.y * 0.25 - 0.35));
    const float N = 10.0;
    float s   = v * N;
    float lvl = floor(s);
    float fr  = s - lvl;

    // Cada nível = cor chapada; ciclo triangular dá repetição escuro/claro como no mármore.
    float tq = abs(fract(lvl / N * 1.5) * 2.0 - 1.0);
    float3 col = ramp(tq, A, B, C);

    // Veio escuro na fronteira entre níveis + fio de brilho no lado de cima.
    float edge = min(fr, 1.0 - fr);
    float vein = 1.0 - smoothstep(0.0, 0.05, edge);
    col = mix(col, A, vein * 0.7);
    float hl = smoothstep(0.90, 0.97, fr) * (1.0 - smoothstep(0.97, 1.0, fr));
    col += C * hl * 0.35;
    // Beat glow in the accent color, kept off the dark veins.
    col += C * (glowGain * pulse) * (1.0f - vein);

    return half4(half3(saturate(col)), 1.0h);
}
// Stage 13B: single procedural shader, using existing noise helpers and
// existing SwiftUI colorEffect; no feedback buffers or independent renderer.
// Glass creates a translucent caustic illusion (not framebuffer refraction).
[[ stitchable ]]
half4 proceduralMaterial(float2 position, half4 currentColor,
                         float2 size, float time,
                         half4 color1, half4 color2, half4 color3,
                         float kind, float p0, float p1, float p2, float p3,
                         float beat, float energy, float bass, float movement,
                         float brightness, float seed)
{
    float3 A = float3(color1.rgb), B = float3(color2.rgb), C = float3(color3.rgb);
    float2 uv = (position - 0.5f * size) / max(min(size.x, size.y), 1.0f);
    float t = time * (0.08f + 0.32f * p2);
    float2 shift = float2(fract(seed * 0.000137f), fract(seed * 0.000271f)) * 9.0f;
    float2 coord = uv * (2.0f + 4.0f * p0) + shift;
    float n = fbm<4>(coord + float2(t, -t * 0.7f));
    float swirl = fbm<3>(coord * 1.4f + float2(-t, t) + n * (1.0f + p1 * 2.0f));
    float3 col = B;
    float alpha = 1.0f;
    if (kind < 1.5f) {
        float ripple = sin((uv.x + 0.27f * swirl + 0.020f * beat) * 18.0f
                           + (uv.y + 0.18f * n) * 13.0f + t * 5.0f);
        float lens = smoothstep(0.48f, 0.9f, swirl * p1 + n * (0.6f + p2));
        col = mix(A, B, saturate(n * 0.7f + 0.28f + ripple * 0.06f * p1));
        col = mix(col, C, lens * (0.2f + 0.45f * p2 + 0.05f * beat));
        col += C * (smoothstep(0.8f, 0.99f, n) * p3 * 0.18f + energy * 0.06f);
        alpha = 0.50f + 0.45f * p0;
    } else if (kind < 2.5f) {
        float wave = sin(uv.y * 19.0f + 8.0f * n + t * 4.0f);
        float reflected = smoothstep(-0.6f, 0.85f, wave);
        float spec = pow(saturate(0.5f + 0.5f * wave), 12.0f + 34.0f * p3);
        col = mix(A, B, reflected * (0.35f + 0.55f * p1));
        col = mix(col, C, spec * (0.45f + 0.45f * p0));
        col = saturate((col - 0.5f) * (1.0f + 1.2f * p3) + 0.5f
                       + (p2 - 0.5f) * 0.25f + 0.15f * energy + 0.12f * brightness);
    } else if (kind < 3.5f) {
        float detail = fbm<4>(coord + (swirl - 0.5f) * (1.0f + 3.0f * p1)
                                   + float2(t, -t) * (0.5f + movement));
        col = ramp(saturate(detail * (1.1f + p3) + bass * 0.16f), A, B, C);
    } else if (kind < 4.5f) {
        float fog = smoothstep(0.24f, 0.8f,
            fbm<4>(coord * 0.68f + float2(t * (1.0f + movement), -t * 0.5f)
                   + swirl * p1));
        col = mix(A, B, fog);
        col = mix(col, C, pow(fog, 3.0f) * 0.42f);
        col += C * energy * 0.07f;
        alpha = saturate((0.20f + 0.65f * fog) * p3);
    } else {
        float veins = n * (1.0f + p1) + swirl * (0.4f + p0) + 0.1f * bass;
        float bands = fract(veins * (5.0f + 10.0f * p0));
        float vein = 1.0f - smoothstep(0.0f, 0.02f + 0.07f * (1.0f - p3),
                                         min(bands, 1.0f - bands));
        col = ramp(saturate((veins - 0.6f) * (1.0f + 2.0f * p2) + 0.5f), A, B, C);
        col = mix(col, A, vein * 0.85f);
        col += C * (0.08f * beat) * (1.0f - vein);
    }
    return half4(half3(saturate(col)), half(saturate(alpha)));
}


// EXP-7: five-color textured Marble, fully procedural. The original
// liquidMarble and proceduralMaterial functions stay pixel-identical.
// Uniform texture controls never depend on live FFT; only the slow/bounded
// warp and accent respond to the existing resolved Marble pulse.
[[ stitchable ]]
half4 texturedMarble(float2 position, half4 currentColor,
                     float2 size, float time,
                     half4 color0, half4 color1, half4 color2,
                     half4 color3, half4 color4,
                     float stripingFrequency, float stripingMix,
                     float speckleIntensity, float embossStrength,
                     float scanlineDensity, float diffusionSoftness,
                     float voidThreshold, float combStretch,
                     float bilateralSymmetry, float halftoneGrating,
                     float reactiveDistortion, float beatPulse,
                     float pulseWarp, float pulseGlow, float detailQuality)
{
    float3 c0 = float3(color0.rgb);
    float3 c1 = float3(color1.rgb);
    float3 c2 = float3(color2.rgb);
    float3 c3 = float3(color3.rgb);
    float3 c4 = float3(color4.rgb);
    float2 uv = (position - 0.5f * size) / max(min(size.x, size.y), 1.0f) * 1.85f;
    // Mirroring is centered on x=0 and the domain remains continuous.
    uv.x = mix(uv.x, abs(uv.x), saturate(bilateralSymmetry));
    float t = time * 0.065f;
    float comp = max(0.0f, combStretch);
    float2 stretched = uv * float2(1.0f + 0.24f * comp,
                                 1.0f / (1.0f + 0.18f * comp));
    // A typed pad impulse reaches beatPulse via the SAME CPU resolver in
    // live preview and Story frames. A single bounded radial wave distorts
    // contours without re-seeding noise or producing flashes.
    float radius = length(uv);
    float radialWave = sin(radius * 15.0f - t * 0.7f);
    stretched += (uv / max(radius, 0.025f)) *
                 (0.032f * saturate(beatPulse) * radialWave);
    float2 q = float2(fbm<2>(stretched * 1.2f + float2(t, 1.4f)),
                      fbm<2>(stretched * 1.2f + float2(7.2f, -t)));
    float warp = 0.42f + 0.16f * saturate(reactiveDistortion) +
                 0.12f * saturate(beatPulse) * clamp(pulseWarp, 0.0f, 0.5f);
    float flow = fbm<3>(stretched * 1.85f + warp * q +
                         float2(t * 0.55f, -t * 0.35f));
    float ribs = sin((stretched.y + 0.35f * flow + 0.12f * q.x) *
                     (5.0f + 1.8f * comp));
    float v = saturate(0.26f + 0.62f * flow + 0.18f * q.y + 0.14f * ribs);
    // Smooth, non-flashing airbrush transitions.
    float soft = saturate(diffusionSoftness);
    v = mix(v, smoothstep(0.13f, 0.88f, v), soft * 0.52f);
    float band = v * 4.0f;
    float3 col;
    if (band < 1.0f) col = mix(c0, c1, smoothstep(0.0f, 1.0f, band));
    else if (band < 2.0f) col = mix(c1, c2, smoothstep(1.0f, 2.0f, band));
    else if (band < 3.0f) col = mix(c2, c3, smoothstep(2.0f, 3.0f, band));
    else col = mix(c3, c4, smoothstep(3.0f, 4.0f, band));

    if (stripingMix > 0.001f && stripingFrequency > 0.001f) {
        // Optical micro-lines follow the WARPED scalar field, not screen
        // coordinates; gentle time drift prevents harsh neon strobing.
        float stripe = 0.5f + 0.5f * sin(
            (v + 0.24f * flow + 0.12f * ribs) * stripingFrequency *
            6.2831853f + t * 0.35f);
        float veinMask = smoothstep(0.16f, 0.6f, abs(ribs));
        col = mix(col, mix(c0, c4, stripe),
                  saturate(stripingMix) * veinMask * 0.55f);
    }

    // Dark void pools do not become gray due to fake ambient lighting.
    if (voidThreshold > 0.001f) {
        float mask = smoothstep(voidThreshold - 0.10f,
                                voidThreshold + 0.08f, v);
        col *= mask;
        // Small stationary whirlpool highlights, not a time-flickering noise.
        float eddy = abs(sin(length(uv + 0.15f * q) * 29.0f + flow * 8.0f));
        col += c2 * (1.0f - mask) * (1.0f - smoothstep(0.0f, 0.12f, eddy)) * 0.08f;
    }

    float quality = saturate(detailQuality);
    if (quality > 0.05f && speckleIntensity > 0.001f) {
        // Screen-stationary stochastic terrazzo: no temporal grain crawl.
        float2 cell = floor(position * 0.68f);
        float chips = hash21(cell);
        float fleck = smoothstep(0.955f, 0.988f, chips);
        float3 mineral = mix(c4, c3, hash21(cell + 19.7f));
        col = mix(col, mineral, fleck * saturate(speckleIntensity) * quality * 0.75f);
        col += (hash21(cell + 61.2f) - 0.5f) *
               saturate(speckleIntensity) * quality * 0.035f;
    }
    if (quality > 0.05f && embossStrength > 0.001f) {
        // Derivative-based, subtle directional relief on the ribbon contour.
        float emboss = clamp((dfdx(v) - dfdy(v)) * 7.0f, -1.0f, 1.0f);
        col *= 1.0f + emboss * saturate(embossStrength) * quality * 0.11f;
    }
    if (scanlineDensity > 0.001f) {
        float ridges = 0.5f + 0.5f * sin(
            uv.y * scanlineDensity * 6.2831853f + 0.75f * flow);
        col *= 1.0f - 0.038f * ridges * (0.35f + 0.65f * soft);
    }
    if (halftoneGrating > 0.001f) {
        // Bilateral guilloché rings; highlight width tracks luminance.
        float engravingRadius = length(uv * float2(1.0f, 0.85f) + 0.05f * q);
        float wave = abs(sin(engravingRadius * halftoneGrating * 3.14159265f +
                             flow * 4.2f));
        float luminance = dot(col, float3(0.2126f, 0.7152f, 0.0722f));
        float width = mix(0.07f, 0.27f, saturate(luminance));
        float engraving = 1.0f - smoothstep(width, width + 0.12f, wave);
        col = mix(col, c0, engraving * 0.63f);
    }
    // Smooth contour glints are visible when a Kick or Snare lands.
    // Void Gloss keeps black pools black even at maximum accent.
    float voidMask = voidThreshold > 0.001f
        ? smoothstep(voidThreshold - 0.10f, voidThreshold + 0.08f, v)
        : 1.0f;
    float accentGlow = saturate(beatPulse) *
        (0.055f + 0.075f * smoothstep(0.3f, 0.9f, abs(ribs)));
    col += c4 * voidMask *
        (accentGlow + saturate(beatPulse) *
         clamp(pulseGlow, 0.0f, 0.3f) * 0.18f);
    return half4(half3(saturate(col)), 1.0h);
}
