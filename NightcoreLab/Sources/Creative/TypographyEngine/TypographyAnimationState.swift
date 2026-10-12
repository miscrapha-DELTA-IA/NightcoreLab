import Foundation

/// Renderer-independent, fully resolved transformation for ONE word.
/// Pixel-based offsets and RGB split are conceptual normalized canvas units;
/// Stage 8 does not add a text shader. Every value is finite and bounded.
struct TypographyAnimationState: Equatable, Sendable {
    let opacity: Double
    let scale: Double
    let rotation: Double       // degrees
    let offsetX: Double        // normalized word width
    let offsetY: Double        // normalized word height
    let blur: Double           // points
    let glow: Double           // relative legacy glow multiplier
    let colorShift: Double     // normalized [-1,1]
    let chromaticOffset: Double // normalized width, reserved for RGB split
    let opacityVariation: Double // bounded flicker delta
    let effectIntensity: Double
    /// Magazine palette is decided in the engine, never sampled in a view.
    let magazineToneIndex: Int?
    let magazineFillEnabled: Bool

    static let neutral = TypographyAnimationState(
        opacity: 1, scale: 1, rotation: 0, offsetX: 0, offsetY: 0,
        blur: 0, glow: 0, colorShift: 0, chromaticOffset: 0,
        opacityVariation: 0, effectIntensity: 0,
        magazineToneIndex: nil, magazineFillEnabled: false)

    var isTransformNeutral: Bool {
        opacity == 1 && scale == 1 && rotation == 0 && offsetX == 0 &&
        offsetY == 0 && blur == 0 && colorShift == 0 &&
        chromaticOffset == 0 && opacityVariation == 0
    }

    var isValid: Bool {
        [opacity, scale, rotation, offsetX, offsetY, blur, glow, colorShift,
         chromaticOffset, opacityVariation, effectIntensity].allSatisfy(\.isFinite) &&
        (0...1).contains(opacity) && (0.5...1.25).contains(scale) &&
        (-16...16).contains(rotation) && (-0.15...0.15).contains(offsetX) &&
        (-0.15...0.15).contains(offsetY) && (0...2).contains(blur) &&
        (0...1.5).contains(glow) && (-1...1).contains(colorShift) &&
        (-0.025...0.025).contains(chromaticOffset) &&
        (-0.3...0.3).contains(opacityVariation) &&
        (0...1).contains(effectIntensity) &&
        (magazineToneIndex.map { (0...2).contains($0) } ?? true)
    }
}

enum TypographyEffectStyle: String, Codable, CaseIterable, Sendable {
    case neon, magazineCutout, glitch, kinetic, minimal

    init(_ style: TypographyStyle) {
        self = TypographyEffectStyle(rawValue: style.rawValue) ?? .neon
    }
}
