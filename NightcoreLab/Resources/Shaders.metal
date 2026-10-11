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
                   half4 color1, half4 color2, half4 color3)
{
    const float3 A = float3(color1.rgb);
    const float3 B = float3(color2.rgb);
    const float3 C = float3(color3.rgb);

    // Coordenadas normalizadas pela menor dimensão (sem esticar em telas altas).
    float2 uv = (position - 0.5 * size) / min(size.x, size.y) * 1.9;

    // Redemoinho global: gira o domínio mais perto do centro -> espirais.
    float ang = exp(-0.5 * dot(uv, uv)) * (1.1 * sin(time * 0.2) + 0.9);
    float ca = cos(ang), sa = sin(ang);
    uv = float2(uv.x * ca - uv.y * sa, uv.x * sa + uv.y * ca);

    // Domain warping em duas camadas.
    float t = time * 0.15;
    float2 q = float2(fbm<3>(uv + float2(0.0, t)),
                      fbm<3>(uv + float2(5.2 - t, 1.3)));
    float2 r = float2(fbm<3>(uv + 3.2 * q + float2(1.7 + 0.6 * t, 9.2)),
                      fbm<3>(uv + 3.2 * q + float2(8.3, 2.8 - 0.5 * t)));
    float f = fbm<4>(uv + 3.2 * r);

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

    return half4(half3(saturate(col)), 1.0h);
}