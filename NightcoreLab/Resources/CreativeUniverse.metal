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
    // Theme colors also alter material geometry in experiences (7–12).
    // No extra uniform: identical RGB inputs drive live and Story exports.
    float themeShift = fract(dot(B, float3(0.31f, 0.53f, 0.79f)) +
                             dot(C, float3(0.23f, 0.67f, 0.41f)));
    float themeTilt = (themeShift - 0.5f) * 1.2f;

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
    } else if (look == 2) { // Prism Carmine: precise crystalline rhombus lattice
        float turn = 0.20f * sin(t * 0.17f) + 0.13f * voice;
        float c = cos(turn), s = sin(turn);
        float2 rotated = float2(p.x*c-p.y*s, p.x*s+p.y*c);
        float2 diamonds = float2(rotated.x-rotated.y, rotated.x+rotated.y) * 3.2f;
        float2 facet = abs(fract(diamonds)-0.5f);
        float bevel = 1.0f-smoothstep(0.012f,0.04f,abs(facet.x+facet.y-0.48f));
        float depth = 0.45f+0.42f*sin(diamonds.x*0.8f-diamonds.y*0.7f+t*0.19f);
        float sparkle = pow(saturate(sin((facet.x-facet.y)*31.0f+t*0.64f+bass*3.0f)),18.0f);
        col = mix(A,B,saturate(depth));
        col += C*sparkle*(0.14f+0.4f*bass);
        col += float3(0.3f)*bevel*(0.18f+0.28f*treble);
    } else if (look == 8) { // Caustic Dissection: fractured fluid optics, NOT diamonds
        float melt = 0.17f*sin(p.y*5.0f+t*0.23f+themeTilt*2.0f) +
                     0.11f*cos(p.x*3.7f-t*0.17f);
        float2 liquid = p + float2(melt*0.55f,-melt*0.40f);
        float fractureAngle = atan2(liquid.y,liquid.x);
        float dist = length(liquid);
        float shards = universeLine(fractureAngle*(5.0f+floor(themeShift*5.0f))+
                                   dist*(8.0f+6.0f*bass)-t*0.30f,0.048f);
        float silk = universeNoise(liquid*5.0f+float2(t*0.10f,-t*0.08f));
        float flow = sin(liquid.x*8.0f+liquid.y*5.0f+
                         silk*7.0f-t*(0.30f+voice*1.2f));
        float refract = smoothstep(0.18f,0.85f,flow*0.5f+0.5f);
        float caustic = pow(saturate(0.5f+0.5f*sin(
            (liquid.x-liquid.y)*31.0f+silk*13.0f+t*0.75f)),18.0f);
        col = mix(A,B,refract*0.76f);
        col += C*shards*(0.16f+0.65f*bass);
        col += C*caustic*(0.12f+0.40f*treble);
        col = mix(col,C,shards*refract*0.28f);
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
    } else if (look == 7) { // Subcultural: kinetic zine print and dry star cuts
        float2 sheet = p + float2(
            sin(p.y*11.0f+t*0.22f+themeTilt)*0.030f*(0.35f+bass),
            -t*0.015f);
        float wear = universeNoise(sheet*19.0f+float2(17.0f+t*0.13f,5.0f));
        float offset = floor(sheet.y*17.0f);
        float printFault = universeHash(float2(offset,floor(t*2.0f)));
        sheet.x += (printFault-0.5f)*0.11f*(0.15f+treble);
        float2 grid = fract(sheet*float2(13.0f,15.0f))-0.5f;
        float halftone = step(0.20f+0.13f*voice,length(grid));
        float stamp = universeLine(angle*(7.0f+floor(themeShift*3.0f))+
                                   r*(12.0f+bass*5.0f)-t*0.15f,0.15f);
        float star = pow(saturate(cos(angle*7.0f))*saturate(1.0f-r*0.7f),6.0f);
        float distressed = step(0.42f-0.12f*bass,wear);
        col = mix(B,A,distressed*(0.31f+phase*0.49f));
        col = mix(col,C,halftone*(0.15f+0.22f*voice) +
                     star*(0.14f+0.52f*treble)+stamp*(0.13f+0.37f*bass));
    } else if (look == 9) { // Tectonic: mineral canyon + braided tensile filaments
        float fault = p.x-0.18f*sin(p.y*3.7f+t*0.09f+themeTilt);
        float opening = 0.12f+0.19f*bass+0.04f*sin(t*0.12f);
        float fissure = 1.0f-smoothstep(opening*0.65f,opening*1.35f,abs(fault));
        float2 ridges = p+float2(fault*0.22f,0.14f*sin(p.x*3.0f+t*0.12f));
        float contours = universeLine(
            (ridges.y*18.0f+3.8f*sin(ridges.x*4.0f+themeTilt)+
             universeNoise(ridges*6.0f)*2.0f-t*0.16f)*3.14159f,0.11f);
        float filament = universeLine(p.y*29.0f+
                         sin(p.x*4.0f+themeShift)*6.0f-t*0.4f,0.065f);
        float tension = universeLine(p.x*15.0f-p.y*7.0f+themeTilt,0.08f);
        float trace = filament*tension;
        float mineral = universeNoise(ridges*13.0f+float2(seed*0.001f,0));
        col = mix(A*(0.42f+mineral*0.24f),B*(0.40f+0.37f*bass),
                  contours*(0.22f+0.35f*voice));
        col = mix(col,C,fissure*(0.27f+0.40f*bass)+
                        trace*fissure*(0.32f+0.35f*treble));
    } else if (look == 10) { // Vector Drift: parallax perspective + continuous flight
        float2 focus = p + 0.05f*float2(sin(t*0.29f+themeTilt),
                                          cos(t*0.25f-themeTilt));
        float distanceToCenter = max(length(focus),0.018f);
        float theta = atan2(focus.y,focus.x);
        float speed = 1.6f+3.7f*bass+1.1f*voice;
        float depth = -log2(distanceToCenter+0.035f)*3.2f - t*speed;
        float layers = universeLine(depth*3.14159f,0.11f);
        float vanishing = exp(-distanceToCenter*7.0f);
        float rails = universeLine(theta*(12.0f+floor(themeShift*6.0f))+
                     sin(depth*0.21f+themeTilt)*1.8f,0.042f);
        float neon = universeLine(depth*3.14159f+theta*2.0f,0.06f);
        float warp = 0.5f+0.5f*sin(depth*0.67f+themeTilt);
        col = mix(A,B,rails*(0.23f+0.48f*warp));
        col += C*(layers*(0.17f+0.52f*bass)+
                  rails*neon*(0.12f+0.5f*treble)+vanishing*0.23f);
    } else if (look == 11) { // Liquid: themed silicone convection and expanding cells
        float swirl = sin(p.y*4.6f+t*(0.22f+voice*0.18f)+themeTilt);
        float2 f = p + float2(0.21f*swirl,
                         0.13f*cos(p.x*4.0f-t*0.21f));
        float n = universeNoise(f*(5.6f+themeShift*2.9f));
        float n2 = universeNoise(f*12.0f+float2(t*0.07f,-t*0.04f));
        float membrane = 1.0f-smoothstep(0.028f,0.095f,
                                  abs(n-0.51f-0.075f*bass));
        float cell = smoothstep(0.43f-0.20f*bass,0.74f-0.05f*bass,n);
        float pearl = pow(saturate(n2),4.0f)*(0.08f+0.43f*treble);
        col = mix(B,C,cell*(0.55f+0.31f*voice));
        col = mix(col,A,membrane*(0.54f+0.31f*bass));
        col += C*pearl*0.22f*q;
    } else if (look == 12) { // Nocturnal: interference sky + oxidized kinetic toroid
        float terrain = 0.10f*sin(p.x*7.0f+themeTilt)+
                        0.06f*sin(p.x*19.0f+0.6f*t);
        float horizon = smoothstep(terrain-0.03f,terrain+0.07f,p.y);
        float2 lens = p-float2(0.24f+0.10f*sin(t*0.15f+themeTilt),-0.12f);
        float ring = universeRing(length(lens)*(14.0f+4.0f*bass),
                                  -t*(0.26f+voice*0.45f),0.052f);
        float grain = universeNoise(p*7.0f+float2(t*0.16f,-t*0.055f));
        float sky = universeLine((p.y*45.0f+grain*4.0f+
                                t*(0.20f+0.55f*voice))*3.14159f,0.09f);
        float oxid = smoothstep(0.42f,0.71f,grain);
        float sparks = step(0.988f-0.008f*treble,
                           universeHash(floor(pos*(0.22f+q*0.07f)+
                           float2(t*0.4f,0))));
        col = mix(A,B*0.68f,horizon*(0.36f+0.22f*voice));
        col += C*(ring*(0.22f+0.62f*bass)+
                  sky*(0.13f+0.30f*voice)+oxid*0.10f+
                  sparks*treble*0.45f);
    } else if (look == 13) { // Strata: folded abyssal erosion, not horizontal bands
        float2 abyss = p-float2(0.10f*sin(t*0.09f),0.04f*cos(t*0.08f));
        float depth = length(abyss);
        float angleField = atan2(abyss.y,abyss.x);
        float sediment = depth*(22.0f+12.0f*phase)+
                         3.6f*sin(angleField*4.0f+t*0.06f)+
                         2.5f*universeNoise(abyss*4.0f+float2(seed*0.001f,0));
        float contour = universeLine(sediment*3.14159f,0.072f);
        float sink = exp(-depth*(3.9f+2.0f*bass));
        float scar = universeLine(angleField*5.0f+
                     depth*9.0f+t*0.08f,0.065f);
        float sedimentAge = smoothstep(0.05f,1.0f,phase);
        col = mix(A,B,contour*(0.35f+0.35f*voice));
        col = mix(col,C,scar*sedimentAge*(0.28f+0.44f*bass));
        col += B*sink*(0.10f+0.26f*bass);
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
