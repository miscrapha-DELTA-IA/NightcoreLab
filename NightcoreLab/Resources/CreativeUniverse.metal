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
// Stage 72: bounded signed-distance vocabulary. No frame history or
// derivative-only instructions: the exact functions run in SwiftUI and Story.
// A light-weight two-pass Voronoi cell edge, limited to 3×3 neighbors.
static inline float2 universePlateMetric(float2 p, float seed) {
    float2 base = floor(p);
    float best = 1.0e6f;
    float2 owner = float2(0);
    float2 ownerCell = base;
    for (int y=-1; y<=1; ++y) {
        for (int x=-1; x<=1; ++x) {
            float2 cell = base+float2(x,y);
            float2 center = cell+0.17f+0.66f*float2(
                universeHash(cell+float2(seed,5.3f)),
                universeHash(cell+float2(17.7f,seed)));
            float d = dot(center-p,center-p);
            if (d<best) { best=d; owner=center; ownerCell=cell; }
        }
    }
    float edge=2.0f;
    for (int y=-1; y<=1; ++y) {
        for (int x=-1; x<=1; ++x) {
            float2 cell=base+float2(x,y);
            if (all(cell==ownerCell)) continue;
            float2 center=cell+0.17f+0.66f*float2(
                universeHash(cell+float2(seed,5.3f)),
                universeHash(cell+float2(17.7f,seed)));
            float2 v=center-owner;
            float len=length(v);
            if (len>0.001f) edge=min(edge,
                dot((owner+center)*0.5f-p,v)/len);
        }
    }
    return float2(max(0.0f,edge),universeHash(ownerCell+seed));
}
static inline float universeStrataHeight(float2 p, float seed) {
    // Smooth minerals + carved scar: the noise field is fixed in song space.
    float n=universeFbm(p*2.1f+float2(seed*0.004f,0));
    float fold=0.27f*sin(p.x*4.1f+n*6.1f);
    float sink=1.0f/(1.0f+dot(p*float2(1.1f,0.83f),
                           p*float2(1.1f,0.83f))*5.0f);
    return n*0.68f+fold*0.35f-sink*0.62f+0.15f*p.y;
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
    } else if (look == 8) { // Caustic: liquid quartz, refracting rather than Prism's diamonds
        float2 glass = universeAdvection(p,t*0.21f+themeShift*7.0f,
                                       0.10f+0.15f*bass);
        float current = universeFbm(glass*3.6f+float2(t*0.05f,-t*0.07f));
        float ripples = sin(glass.y*7.9f+current*14.0f-t*0.32f);
        glass += float2(0.12f*ripples,0.07f*sin(
                   glass.x*9.0f+current*11.0f+t*0.12f));
        // Thin etched edges form flowing mineral fissures rather than a
        // fixed repeating rhombus. Bass opens cracks; treble scatters light.
        float mineral = universeFbm(glass*6.5f+21.0f);
        float ridge = abs(mineral-0.51f);
        float fracture = 1.0f-smoothstep(0.018f,0.070f+bass*0.065f,ridge);
        float2 pane = glass*float2(4.5f,5.6f);
        float2 facet = abs(fract(pane+float2(
                          current*0.8f,-current*0.5f))-0.5f);
        float cut = 1.0f-smoothstep(0.025f,0.075f,
                        min(facet.x,abs(facet.y-0.4f*facet.x)));
        float optical = sin(
            (glass.x*16.0f+glass.y*8.0f)+current*23.0f+
            mineral*10.0f+t*(0.39f+0.16f*voice));
        float bright = pow(saturate(optical*0.5f+0.5f),19.0f);
        float opticBand = 0.5f+0.5f*sin(current*9.0f+
                                    glass.y*5.0f+themeTilt*2.0f);
        float3 spectrum = float3(
            bright*1.13f,
            pow(saturate(0.5f+0.5f*sin(optical*0.93f+0.35f)),18.0f),
            pow(saturate(0.5f+0.5f*sin(optical*0.88f-0.48f)),17.0f));
        float wetEdge = saturate(fracture*0.74f+cut*0.21f);
        col = mix(A,B,smoothstep(0.24f,0.79f,opticBand)*0.74f);
        col = mix(col,C,wetEdge*(0.20f+0.52f*bass));
        col += spectrum*mix(C,B,0.3f)*bright*(0.18f+0.53f*treble);
        col += B*cut*0.16f*(0.33f+voice);
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
    } else if (look == 9) { // Tectonic: mineral VORONOI plates + inter-crack fibers
        float2 warped = p*float2(1.95f,2.22f);
        warped += 0.21f*float2(
            sin(p.y*3.4f+t*0.09f+themeTilt),
            cos(p.x*3.0f-t*0.055f));
        float2 metric = universePlateMetric(warped,seed*0.001f+7.0f);
        float pressure = saturate(0.59f*bass+0.23f*voice+0.18f*treble);
        float aperture = 0.042f+0.102f*pressure;
        float jagged = 0.022f*universeNoise(warped*10.0f+
                                       metric.y*19.0f);
        float boundary = metric.x - aperture-jagged;
        float crack = 1.0f-smoothstep(-0.008f,0.027f,boundary);
        float bevel = 1.0f-smoothstep(0.012f,0.10f,abs(boundary));
        float grain = universeFbm(warped*3.9f+float2(metric.y*4.0f,0));
        float illumination = 0.38f+0.39f*grain+
                              0.12f*sin(warped.y*3.7f+themeTilt);
        float3 basalt = mix(A*0.24f,B*0.58f,
                            saturate(illumination));
        basalt += C*bevel*(0.12f+0.28f*treble);
        float3 abyss = A*0.08f+0.028f*B;
        // Tensioned strands only light the *actual fractures*. The varying
        // tangential axis gives different fibers to different mineral plates.
        float fiberPhase = (warped.y+warped.x*0.46f)*25.0f+
                           metric.y*21.0f+t*(0.14f+0.27f*voice);
        float cable = universeLine(fiberPhase*3.1415926f,0.064f);
        float tension = 1.0f-smoothstep(0.00f,aperture+0.055f,
                                         metric.x);
        float3 fibers = C*cable*(0.35f+0.51f*pressure)*
                        (0.52f+0.48f*tension);
        if (q>0.68f) {
            float braided = universeLine(fiberPhase*6.283185f+
                             sin(warped.x*8.0f)*2.4f,0.075f);
            fibers += B*braided*(0.09f+0.26f*treble);
        }
        col = mix(basalt,abyss+fibers,crack);
        col += C*bevel*crack*(0.09f+0.18f*bass);
    } else if (look == 10) { // Vector: cylindrical perspective with layered cable ribs
        float2 focus=p+float2(0.035f*sin(t*0.17f+themeTilt),
                               0.042f*cos(t*0.12f-themeTilt));
        float radius=max(0.023f,length(focus));
        float theta=atan2(focus.y,focus.x);
        float depth=min(34.0f,1.1f/radius);
        float propulsion=t*(0.92f+1.42f*bass+0.36f*voice);
        // Advancing z is independent from redraw count; seeking reproduces
        // the same cell and the central vanishing point.
        float z=depth+propulsion;
        float sector=theta*1.91f; // 12 longitudinal rails around the tunnel
        float wobble=0.085f*sin(z*0.31f+theta*3.0f);
        float longitudinal=universeLine(
            (sector+wobble+themeTilt*0.19f)*3.1415926f,0.08f);
        float rib=universeLine(z*2.14f+0.26f*sin(theta*5.0f),0.11f);
        float hollow=1.0f-smoothstep(0.065f,0.21f,
                         length(float2(fract(sector+wobble)-0.5f,
                                       fract(z*0.68f)-0.5f)));
        float cage=saturate(longitudinal*0.90f+rib*0.78f);
        float reflect=pow(saturate(0.5f+0.5f*cos(
                      theta*2.7f+z*0.13f-t*0.25f)),15.0f);
        float brushed=universeNoise(float2(theta*17.0f,z*7.2f));
        float nearFade=smoothstep(0.3f,6.0f,depth);
        float fog=1.0f-smoothstep(11.0f,34.0f,depth);
        float3 chrome=mix(B,C,0.32f+0.42f*brushed);
        col=mix(A*0.035f,chrome,cage*(0.50f+0.5f*fog));
        col += C*cage*reflect*(0.17f+0.39f*treble);
        // Depth-separated foreground cable coils with true parallax shift.
        if (q>0.47f) {
            float cableA=universeLine(theta*4.0f+
                           z*0.35f+sin(z*0.43f+t*0.16f),0.063f);
            float cableB=universeLine(theta*4.0f-
                           z*0.25f+cos(z*0.32f-t*0.15f),0.074f);
            col += B*cableA*(0.08f+0.29f*voice)*fog;
            col += C*cableB*(0.05f+0.25f*bass)*fog;
        }
        float vanishing=exp(-radius*(13.0f+4.0f*bass));
        float core=pow(saturate(vanishing),2.0f);
        col += C*core*(0.20f+0.54f*bass);
        // Dark open compartments, not an opaque flat wireframe.
        col *= 0.75f+0.25f*hollow;
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
    } else if (look == 13) { // Strata: deterministic terraced heightfield + heat
        float age=saturate(phase);
        float2 domain=p*float2(1.0f,0.82f);
        // Geologic drift is intentionally slow; history is a deterministic
        // maturity envelope, NOT a sampled recording of earlier audio.
        domain+=float2(t*0.0032f,0.012f*sin(t*0.045f));
        float h=universeStrataHeight(domain,seed);
        float terracing=17.0f+19.0f*age;
        float layers=h*terracing;
        float fraction=fract(layers);
        float terrace=floor(layers)+smoothstep(0.0f,0.20f,fraction);
        float edge=1.0f-smoothstep(0.027f,0.120f,
                                   min(fraction,1.0f-fraction));
        float3 cold=mix(A*0.27f,B*0.53f,saturate(0.47f+h*0.36f));
        float3 stone=cold;
        float ledge=1.0f-smoothstep(0.08f,0.24f,fraction);
        float depthShadow=1.0f-smoothstep(-0.11f,0.37f,h);
        stone *= 0.62f+0.38f*(1.0f-depthShadow*0.47f);
        // A height-gradient estimates the raking light on terraces. The
        // quality condition avoids three additional fBm evaluations in low
        // power / thermal state.
        if (q>0.60f) {
            float epsilon=0.018f;
            float hx=universeStrataHeight(domain+float2(epsilon,0),seed);
            float hy=universeStrataHeight(domain+float2(0,epsilon),seed);
            float3 normal=normalize(float3(
                 -(hx-h)/epsilon*0.55f,-(hy-h)/epsilon*0.55f,1.0f));
            float lit=saturate(dot(normal,normalize(
                             float3(-0.50f,0.47f,0.65f))));
            stone *= 0.56f+0.45f*lit;
        }
        stone=mix(stone,C*0.67f,edge*(0.25f+0.28f*voice));
        float basin=smoothstep(0.18f,0.65f,0.35f-h);
        float heat=saturate(basin*(0.11f+0.23f*age)+
                         0.43f*bass+0.16f*voice);
        float fault=universeLine(
                      atan2(domain.y,domain.x)*4.3f+
                      length(domain)*(8.0f+4.0f*age),0.070f);
        float3 thermal=mix(B,C,0.42f+0.37f*heat);
        col=mix(stone,thermal,heat*0.54f*basin);
        col += C*fault*edge*(0.13f+0.30f*bass);
        col *= 0.91f+0.09f*saturate(terrace/terracing+0.5f);
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
