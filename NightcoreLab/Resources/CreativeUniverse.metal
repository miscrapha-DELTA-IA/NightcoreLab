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

// Reference-driven surface grammar. Stable under seek / Story frame order.
// Three bounded octaves; avoid dynamic texture, per-frame SwiftUI bitmaps and
// derivatives that would break the shared compute + fragment evaluator.
static inline float universeFbm(float2 p) {
    return 0.55f*universeNoise(p) +
           0.29f*universeNoise(p*2.09f+17.6f) +
           0.16f*universeNoise(p*4.27f-9.7f);
}
static inline float2 universeAdvection(float2 p, float time, float anisotropy) {
    float a = universeFbm(p*1.36f + float2(0.07f*time, -0.04f*time))*6.283185f;
    float2 current = float2(cos(a),sin(a));
    return p + current*float2(0.15f,0.15f+anisotropy);
}
static inline float universePrintDots(float2 p, float ink) {
    float2 cell = fract(p)-0.5f;
    // A physically enlarged toner droplet, not a flat repeating checker.
    float grain = universeHash(floor(p)+31.0f);
    float coverage = saturate(ink*0.65f+0.19f*(grain-0.5f));
    float radius = sqrt(coverage)*0.68f;
    return 1.0f - smoothstep(radius-0.07f,radius+0.035f,length(cell));
}
static inline float universeContour(float elevation, float frequency, float width) {
    return universeLine(elevation*frequency*3.1415926f,width);
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

    if (look == 1) { // Xerox: stressed serpentine screen-print, toner and VHS shear
        float2 sheet = universeAdvection(p*float2(1.1f,1.38f),
                                        t*0.55f,0.06f+bass*0.10f);
        // Low frequencies bend the print plate; transients offset each scan.
        sheet.x += 0.18f*sin(sheet.y*4.4f+t*0.19f)*bass;
        float2 lattice = sheet*float2(11.0f+themeShift*3.0f,16.0f);
        lattice.x += floor(lattice.y)*0.5f;
        float2 tile = floor(lattice), local = fract(lattice)-0.5f;
        float vein = sin(local.y*6.2f+sin(sheet.x*6.0f)*2.0f);
        float2 streak = local+float2(0.22f*vein,0.13f*sin(local.x*8.0f));
        float scaleEdge = abs(length(streak*float2(0.79f,1.25f))-0.37f);
        float reptile = 1.0f-smoothstep(0.025f,0.12f,scaleEdge);
        float bleach = universeFbm(sheet*7.1f+float2(seed*0.002f,0));
        float ink = saturate(reptile*0.85f+bleach*0.31f-0.25f);
        float print = universePrintDots(pos/(2.65f+0.85f*themeShift),ink);
        float scratches = 1.0f-smoothstep(0.008f,0.042f,
             abs(sin(sheet.x*(46.0f+18.0f*treble)+
                     1.9f*universeNoise(sheet*3.0f))));
        float mechanical = sin(p.y*180.0f+t*(1.5f+treble*3.0f));
        float failure = step(0.972f-bass*0.033f,universeHash(
                                float2(floor(p.y*26.0f),floor(t*2.0f))));
        float shear = failure*universeHash(tile+floor(t*2.0f));
        float3 black = A*0.17f, paper = mix(B,C,0.08f+0.38f*themeShift);
        float mask = saturate(print*0.82f+scratches*0.18f+mechanical*0.025f);
        col = mix(paper,black,mask);
        col = mix(col, C*(0.36f+0.45f*treble),shear*0.15f);
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
    } else if (look == 7) { // Subcultural: adhesive stencil, offset registration, halftone
        float2 paper = p+float2(
            0.055f*sin(p.y*4.0f+themeTilt+t*0.25f)*(0.25f+bass),
            -t*0.018f);
        float distressed = universeFbm(paper*9.1f+float2(19.0f,7.0f));
        float2 gate = float2(paper.x*6.0f,paper.y*7.0f);
        float2 snapped = floor(gate);
        float3 plate = mix(A,B,step(0.48f,distressed));
        float printer = universePrintDots(pos*0.23f,
                         smoothstep(0.28f,0.77f,distressed));
        // Five ray stencil holes, elliptical ink smears and local tears.
        float2 cell = fract(gate)-0.5f;
        float polar = atan2(cell.y,cell.x);
        float radial = length(cell);
        float spikes = 0.20f+0.22f*pow(abs(cos(polar*2.5f)),13.0f);
        float fivePoint = 1.0f-smoothstep(0.015f,0.055f,
                                                abs(radial-spikes));
        float sheetTear = step(0.77f,universeNoise(
                                   paper*21.0f+float2(0.0f,floor(t*1.5f))));
        float shot = step(0.88f-bass*0.06f,universeHash(
                                  snapped+floor(t*0.36f)));
        col = mix(plate,C,printer*(0.21f+0.42f*voice));
        col = mix(col,B*(0.4f+treble*0.5f),
                  fivePoint*shot*(0.55f+0.37f*treble));
        col = mix(col,A,sheetTear*0.44f);
        col *= 0.84f+0.16f*universeNoise(paper*37.0f+seed*0.005f);
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
    } else if (look == 11) { // Liquid: advected enamel with viscous folded membranes
        float2 field = universeAdvection(p*float2(1.04f,0.85f),
                                        t*(0.17f+0.18f*voice),
                                        0.12f+0.13f*bass);
        field.x += 0.19f*sin(field.y*5.7f-t*0.23f+themeTilt*4.0f);
        field.y += 0.13f*sin(field.x*4.8f+t*0.16f+themeShift*3.0f);
        float elevation = universeFbm(field*3.8f);
        float foam = universeFbm(field*8.5f+21.0f);
        float2 viscosity = float2(
            sin(elevation*13.0f+t*0.22f),
            cos(foam*11.0f-t*0.15f));
        float layer = 0.5f+0.5f*sin(
            field.y*6.6f+elevation*16.0f+foam*2.4f+
            viscosity.x*1.2f);
        float folded = smoothstep(0.33f-bass*0.18f,
                                  0.65f+voice*0.08f, layer);
        // Closely-spaced interference bands mimic thickness of viscous paint.
        float membrane = 1.0f-smoothstep(0.020f,0.085f,
            abs(fract(layer*5.0f+foam*0.28f)-0.5f));
        float gloss = pow(saturate(1.0f-
            abs(layer-0.69f)*5.0f),10.0f);
        float bubble = smoothstep(0.74f,0.93f,foam)*(
                                      0.11f+0.49f*treble);
        float3 dye = mix(B,C,folded*(0.57f+0.35f*voice));
        col = mix(A,dye,0.78f+0.15f*elevation);
        col = mix(col,A*0.32f,membrane*(0.45f+0.29f*bass));
        col += C*gloss*(0.09f+0.45f*treble);
        col += B*bubble*0.19f;
    } else if (look == 12) { // Nocturnal: engraved lithographic topography
        float2 etch = universeAdvection(p,t*0.085f,0.04f+0.10f*bass);
        float rock = universeFbm(etch*2.9f+float2(seed*0.002f,0));
        float2 eye = etch-float2(-0.15f,0.11f);
        float depth = length(eye);
        float polar = atan2(eye.y,eye.x);
        float carved = depth*(21.0f+themeShift*7.0f)+
            3.8f*sin(polar*2.4f)+7.2f*rock+1.4f*sin(etch.x*5.0f);
        float contour = universeContour(carved,
                                        1.0f+0.13f*voice,0.049f);
        float micro = universeContour(carved*2.1f+etch.y*10.0f,
                                       1.0f,0.033f);
        float hatching = universeLine(etch.x*86.0f+
                                     rock*10.0f+etch.y*39.0f,0.035f);
        float acid = smoothstep(0.55f,0.79f,rock);
        float oxide = universeNoise(etch*22.0f+seed*0.002f);
        float worn = step(0.62f,oxide);
        // Black carbon ink with broken cream relief lines.
        float3 ink = A*0.18f, stone = mix(B,C,0.12f+themeShift*0.25f);
        float relief = saturate(contour*(0.54f+0.31f*voice)+
                       micro*0.22f+hatching*0.12f*(0.3f+treble));
        col = mix(ink,stone,relief);
        col = mix(col,B,acid*0.17f+0.10f*worn);
        col += C*contour*bass*0.12f;
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
