#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Stage 65. One deterministic evaluator for SwiftUI colorEffect and Story
// compute output; never sample the live audio engine from the render thread.
// Existing Shaders.metal entry points remain entirely untouched.
static inline float universeHash(float2 p) {
    p = fract(p * float2(123.34f, 456.21f));
    p += dot(p, p + 45.32f);
    return fract(p.x * p.y);
}
static inline float universeNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    return mix(mix(universeHash(i), universeHash(i + float2(1,0)), f.x),
               mix(universeHash(i + float2(0,1)),
                   universeHash(i + float2(1,1)), f.x), f.y);
}
static inline float universeLine(float v, float width) {
    return 1.0f - smoothstep(width, width * 1.8f, abs(sin(v)));
}
static inline float universeRing(float r, float phase, float width) {
    return universeLine(r + phase, width);
}
static inline float3 universeEval(float2 pos, float2 size, float time,
                 int look, float low, float mid, float high, float progress,
                 float seed, float3 A, float3 B, float3 C, float quality) {
    float2 uv = (pos - size * 0.5f) / max(min(size.x, size.y), 1.0f);
    float2 p = uv * 2.0f;
    float t = max(0.0f, time);
    float bass = saturate(low), voice = saturate(mid), treble = saturate(high);
    float phase = saturate(progress);
    float q = saturate(quality);
    float r = length(p);
    float angle = atan2(p.y, p.x);
    float3 col = A;

    if (look == 1) { // Xerox Serpentine: displaced hex scales + dry toner
        float2 xy = p * float2(8.0f, 9.0f);
        xy.x += floor(xy.y) * 0.5f;
        float2 cell = floor(xy), f = fract(xy);
        float d = 4.0f;
        for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
                float2 n = float2(x,y);
                float2 delta = n + 0.28f + 0.43f *
                    float2(universeHash(cell+n+17.0f), universeHash(cell+n+39.0f)) - f;
                d = min(d, dot(delta, delta));
            }
        }
        float toner = universeHash(floor(pos * (0.52f + 0.20f*q)));
        float scale = smoothstep(0.09f, 0.18f+bass*0.07f, d);
        float dots = step(0.46f - voice * 0.12f,
            length(fract(pos / 3.1f) - 0.5f));
        float print = step(0.32f, scale * 0.67f + dots * 0.24f + toner * 0.12f);
        col = mix(A, B, print);
        float scan = universeLine((p.y * 70.0f + t * 0.13f) * 3.14159f, 0.055f);
        col = mix(col, C, scan * (0.06f + 0.24f*treble));
    } else if (look == 2 || look == 8) { // Prism / Caustic Dissection
        float turn = 0.20f * sin(t * 0.17f) + 0.12f * voice;
        float c = cos(turn), s = sin(turn);
        float2 rotated = float2(p.x*c-p.y*s, p.x*s+p.y*c);
        float2 diamonds = float2(rotated.x-rotated.y, rotated.x+rotated.y) * 3.2f;
        float2 facet = abs(fract(diamonds)-0.5f);
        float edge = abs(facet.x + facet.y - (look == 8 ? 0.38f : 0.49f));
        float bevel = 1.0f - smoothstep(0.012f, 0.035f, edge);
        float caustic = pow(max(0.0f, sin((facet.x-facet.y)*31.0f +
                    t*0.64f + bass*3.0f)), 18.0f);
        float depth = 0.28f + 0.50f * sin(diamonds.x*0.8f-diamonds.y*0.7f+t*0.19f);
        col = mix(A, B, saturate(depth)*0.72f);
        col += C * caustic * (0.13f + 0.36f*bass);
        col += float3(0.23f,0.24f,0.28f) * bevel * (0.28f+0.22f*treble);
        if (look == 8) {
            float fracture = universeLine(angle * 6.0f + r * 9.0f -
                    t*0.21f, 0.035f);
            col = mix(col, C, fracture * phase * 0.42f);
        }
    } else if (look == 3) { // Bubble chamber: collision tracks and calibration
        float spiral = angle*1.8f + log(max(r, 0.035f)) *
                       (7.0f + 2.0f*voice) + t*0.17f;
        float track = universeLine(spiral, 0.052f);
        float shell = universeRing(r * 28.0f, t*0.09f, 0.065f);
        float2 grid = abs(fract(p*9.0f)-0.5f);
        float calibration = (1.0f-smoothstep(0.015f,0.045f,grid.x)) *
                            (1.0f-smoothstep(0.10f,0.14f,grid.y));
        calibration += (1.0f-smoothstep(0.015f,0.045f,grid.y)) *
                       (1.0f-smoothstep(0.10f,0.14f,grid.x));
        col = mix(A, B, saturate(r*0.33f));
        col = mix(col, C, track * (0.42f + 0.20f*bass));
        col += B * shell * (0.09f + 0.19f*treble);
        col += C * calibration * 0.12f;
    } else if (look == 4) { // Jacquard: individual interlaced V-shaped loops
        float fold = sin(p.y*2.0f + p.x*3.2f + t*0.11f) *
                     (0.09f + 0.04f*bass);
        float2 knit = (p + float2(fold, fold*0.45f))*float2(21.0f, 36.0f);
        knit.x += floor(knit.y)*0.5f;
        float2 stitch = fract(knit)-0.5f;
        float v = abs(abs(stitch.x) - 0.58f*(stitch.y+0.4f));
        float threadCoverage = 1.0f-smoothstep(0.07f,0.18f,v);
        float light = 0.68f + 0.30f*(stitch.x + 0.5f);
        float pattern = step(0.56f, universeNoise(floor(knit/7.0f)*0.7f +
                                                 float2(t*0.045f, voice)));
        col = mix(A, mix(B,C,pattern)*light, threadCoverage);
        col *= 0.91f + 0.09f*sin(p.x*2.2f + fold);
    } else if (look == 5) { // Isometric: sharp topographic contours
        float2 iso = float2(p.x*0.866f-p.y*0.5f,p.x*0.5f+p.y*0.866f);
        float sink = 1.0f / (0.28f + dot(p,p) * 2.3f);
        float field = iso.y*23.0f + 4.0f*sin(iso.x*3.4f + t*0.10f) +
                      sink*(2.0f+3.0f*bass) - t*0.40f;
        float contour = universeLine(field*3.14159f, 0.060f);
        col = mix(A, B, smoothstep(2.1f,0.12f,r));
        col = mix(col,C,contour*(0.48f+0.30f*voice));
    } else if (look == 6) { // Lenticular Wild: shifting fur/scale panels
        float displacement = sin(t*0.17f + voice*1.5f)*0.21f;
        float slat = step(0.5f, fract((p.x + displacement)*66.0f));
        float spots = universeNoise(p*15.0f+float2(t*0.02f,0));
        float hide = smoothstep(0.38f,0.64f,spots);
        float scale = universeLine(length(fract(p*float2(14,20))-0.5f)*9.0f,
                                   0.14f);
        col = mix(mix(A,B,hide),mix(A,C,scale),slat*0.78f);
    } else if (look == 7) { // Subcultural Archive: cumulative print wear
        float worn = universeNoise(p*18.0f+17.0f);
        float stamp = universeLine(angle*7.0f+r*13.0f,0.17f);
        float print = step(0.41f+0.13f*phase,worn);
        float reticle = step(0.52f,universeHash(floor(pos/4.0f)));
        col = mix(B,A,print*(0.30f+0.55f*phase));
        col = mix(col,C,reticle * phase * 0.23f + stamp*phase*0.18f);
    } else if (look == 9) { // Tectonic Mesh: cracked rock + tension threads
        float rock = universeNoise(p*11.0f) * 0.63f +
                     universeNoise(p*29.0f)*0.37f;
        float gap = 0.19f + 0.27f*bass + 0.12f*sin(p.y*2.3f+t*0.1f);
        float fissure = 1.0f-smoothstep(gap*0.78f,gap*1.20f,abs(p.x));
        float weave = universeLine(p.y*31.0f + p.x*8.0f,0.08f) *
                      universeLine(p.x*13.0f - p.y*2.0f,0.12f);
        col = mix(A* (0.43f+rock*0.6f), B*(0.30f+0.70f*bass),fissure);
        col = mix(col,C,weave*fissure*(0.62f+0.20f*phase));
    } else if (look == 10) { // Vector Drift: tunnel telemetry & curved rails
        float perspective = 1.0f/(r+0.11f);
        float flight = r*19.0f - t*(1.5f+bass);
        float rails = universeLine(angle*16.0f+sin(r*3.0f+t*0.1f),0.035f);
        float slabs = universeRing(flight,0.0f,0.08f);
        col = mix(A, B, rails*(0.34f+0.4f*perspective/(1.0f+perspective)));
        col += C*(slabs*0.2f + pow(max(0.0f,1.0f-r*4.2f),3.0f)*0.75f);
    } else if (look == 11) { // Liquid Monochrome: pearlescent pour cells
        float2 f = p + 0.08f*float2(sin(p.y*4.0f+t*0.21f),
                                   cos(p.x*3.0f-t*0.19f));
        float cell = universeNoise(f*6.5f);
        float edges = 1.0f-smoothstep(0.07f,0.16f,abs(cell-0.54f));
        float bloom = smoothstep(0.53f-bass*0.12f,0.79f,cell);
        col = mix(B, C, bloom*0.85f);
        col = mix(col,A,edges*0.82f);
        col += float3(0.05f,0.04f,0.05f) * universeHash(floor(pos*0.6f)) * q;
    } else if (look == 12) { // Nocturnal Lithograph: etched night horizon
        float skyline = 0.11f*sin(p.x*7.0f) + 0.06f*sin(p.x*19.0f);
        float horizon = smoothstep(skyline-0.03f,skyline+0.05f,p.y);
        float copper = universeRing(length(p-float2(0.36f,-0.2f))*16.0f,
                                    t*0.09f,0.045f);
        float etch = universeLine((p.y*52.0f+universeNoise(p*6.0f)*2.0f) *
                                  3.14159f,0.055f);
        col = mix(A, B*0.67f, horizon*0.65f);
        col += C * (copper*0.27f + etch*0.09f) * (0.5f+0.5f*phase);
    } else if (look == 13) { // Metamorphic Strata: replayable age-based scars
        float stratum = p.y * (32.0f + 12.0f*phase) +
            3.7f*sin(p.x*4.0f + t*0.035f) +
            3.1f*universeNoise(p*4.0f+float2(seed,0));
        float fault = 1.0f-smoothstep(0.014f,0.075f,
            abs(p.x-0.25f*sin(p.y*3.0f+seed*0.01f)));
        float sediment = universeLine(stratum*3.14159f,0.085f);
        col = mix(A,B,sediment*(0.42f+phase*0.28f));
        col = mix(col,C,fault*phase*0.65f);
    } else if (look == 14) { // Kinematic Compiler: deterministic force lattice
        float swirl = angle + 0.18f*sin(r*8.0f-t*0.17f);
        float flow = r*(17.0f+voice*8.0f) + 6.0f*sin(swirl*4.0f+t*0.24f);
        float wires = universeLine(flow*3.14159f,0.07f);
        float nodes = pow(max(0.0f,sin(angle*18.0f+t*0.17f)),24.0f);
        float lattice = universeLine(p.x*28.0f+seed*0.01f,0.06f) *
                        universeLine(p.y*28.0f+seed*0.01f,0.06f);
        col = A + B * wires * (0.26f+0.32f*bass);
        col += C*(nodes*0.25f+lattice*0.36f*voice);
    } else if (look == 15) { // Chromatic Organism: cellular pigment colonies
        float2 flow = p + float2(sin(p.y*5.0f+t*0.13f),
                                cos(p.x*4.0f-t*0.09f))*0.09f;
        float spot = universeNoise(flow*7.0f);
        float membrane = 1.0f-smoothstep(0.05f,0.13f,abs(spot-0.56f));
        float3 dye = mix(B,C,smoothstep(0.35f,0.80f,spot));
        float pigment = smoothstep(0.39f-bass*0.12f,0.63f,spot);
        col = mix(A,dye,pigment*0.85f);
        col = mix(col,A,membrane*0.50f);
        float sprinkle = step(0.987f,universeHash(floor(pos*0.65f)));
        col += B * sprinkle * treble * 0.18f * q;
    }
    // Accessibility-friendly global brightness ceiling and deterministic math.
    return saturate(col);
}

[[stitchable]]
half4 creativeUniverse(float2 position, half4 currentColor,
                       float2 size, float time, float look, float low,
                       float mid, float high, float progress, float seed,
                       half4 colorA, half4 colorB, half4 colorC, float quality) {
    float3 rgb = universeEval(position,size,time,int(look+0.5f),
        low,mid,high,progress,seed,float3(colorA.rgb),float3(colorB.rgb),
        float3(colorC.rgb),quality);
    return half4(half3(rgb),1.0h);
}

// Off-screen Story samples the exact same evaluator. No AVAudioEngine, extra
// draw pass, framebuffer history or frame-rate-dependent RNG.
kernel void storyCreativeUniverseFrame(texture2d<float,access::write> output [[texture(0)]],
                                       constant float *v [[buffer(0)]],
                                       constant float4 *colors [[buffer(1)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 size = float2(v[0], v[1]);
    float2 position = (float2(gid)+0.5f)*size /
        float2(output.get_width(),output.get_height());
    float3 rgb = universeEval(position,size,v[2],int(v[3]+0.5f),
        v[4],v[5],v[6],v[7],v[8],colors[0].rgb,colors[1].rgb,
        colors[2].rgb,1.0f);
    output.write(float4(rgb,1.0f),gid);
}
