import Foundation
import SwiftUI

/// Immutable media-time context shared by Story preview and off-screen MP4.
struct GnarlyVisualContext: Sendable {
    let sourceTime: TimeInterval
    let sourceDuration: TimeInterval
    let artworkHue: Double?
}

/// Gnarly is a single-pass composition of the existing textured Marble
/// materials, not a second Metal engine. A frame is a PURE function of the
/// original song time, duration and one album-cover hue cached per track.
/// Live, Story preview and exported MP4 use this exact resolver.
enum GnarlyThemeEngine {
    struct RGB: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
        var color: Color { Color(red: red, green: green, blue: blue) }
        static func mix(_ a: RGB, _ b: RGB, _ amount: Double) -> RGB {
            let t = min(1, max(0, amount))
            return RGB(red: a.red + (b.red - a.red) * t,
                       green: a.green + (b.green - a.green) * t,
                       blue: a.blue + (b.blue - a.blue) * t)
        }
        static func hex(_ input: String) -> RGB {
            let value = UInt32(input.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
                               radix: 16) ?? 0
            return RGB(red: Double((value >> 16) & 255) / 255,
                       green: Double((value >> 8) & 255) / 255,
                       blue: Double(value & 255) / 255)
        }
        static func hsv(_ hue: Double, saturation: Double, brightness: Double) -> RGB {
            let h = ((hue.isFinite ? hue : 0.58).truncatingRemainder(dividingBy: 1) + 1)
                .truncatingRemainder(dividingBy: 1)
            let s = min(1, max(0, saturation)), v = min(1, max(0, brightness))
            let segment = h * 6
            let index = Int(segment)
            let f = segment - Double(index)
            let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
            switch index % 6 {
            case 0: return RGB(red: v, green: t, blue: p)
            case 1: return RGB(red: q, green: v, blue: p)
            case 2: return RGB(red: p, green: v, blue: t)
            case 3: return RGB(red: p, green: q, blue: v)
            case 4: return RGB(red: t, green: p, blue: v)
            default: return RGB(red: v, green: p, blue: q)
            }
        }
    }

    struct Sample {
        let colors: [RGB] // five stops for the ONE texturedMarble shader
        let frame: MaterialFrame
        let albumPhase: Bool
    }

    /// A fixed, deliberately varied cycle of the existing curated material
    /// looks: stripes, void, terrazzo, mirage, ebru and cymatic symmetry.
    private static let materials: [VisualMaterial] = [
        .init(id: VisualMaterialCatalog.agateZebra.id,
              name: VisualMaterialCatalog.agateZebra.name,
              parameters: VisualMaterialCatalog.agateZebra.parameters),
        VisualMaterialCatalog.voidGloss, VisualMaterialCatalog.terrazzoMagma,
        VisualMaterialCatalog.airbrushMirage, VisualMaterialCatalog.grooveEbru,
        VisualMaterialCatalog.cymaticRorschach, VisualMaterialCatalog.neonPulse
    ]
    private static let palettes: [[RGB]] = materials.map { material in
        (VisualMaterialCatalog.curatedPalettes[material.id]?.hex ??
         VisualMaterialCatalog.curatedPalettes["neon-pulse"]!.hex).map(RGB.hex)
    }

    private static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
    private static func interpolate(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
    private static func interpolate(_ a: VisualParameterSet, _ b: VisualParameterSet,
                                    _ t: Double) -> VisualParameterSet {
        VisualParameterSet(
            distortion: interpolate(a.distortion, b.distortion, t),
            beatPulse: interpolate(a.beatPulse, b.beatPulse, t),
            pulseDecay: interpolate(a.pulseDecay, b.pulseDecay, t),
            offbeatScale: interpolate(a.offbeatScale, b.offbeatScale, t),
            warpAmount: interpolate(a.warpAmount, b.warpAmount, t),
            brightnessBoost: interpolate(a.brightnessBoost, b.brightnessBoost, t),
            stripingFrequency: interpolate(a.stripingFrequency, b.stripingFrequency, t),
            stripingMix: interpolate(a.stripingMix, b.stripingMix, t),
            speckleIntensity: interpolate(a.speckleIntensity, b.speckleIntensity, t),
            embossStrength: interpolate(a.embossStrength, b.embossStrength, t),
            scanlineDensity: interpolate(a.scanlineDensity, b.scanlineDensity, t),
            diffusionSoftness: interpolate(a.diffusionSoftness, b.diffusionSoftness, t),
            voidThreshold: interpolate(a.voidThreshold, b.voidThreshold, t),
            combStretch: interpolate(a.combStretch, b.combStretch, t),
            bilateralSymmetry: interpolate(a.bilateralSymmetry, b.bilateralSymmetry, t),
            halftoneGrating: interpolate(a.halftoneGrating, b.halftoneGrating, t))
    }

    /// Runs in O(1), without image decoding, allocations proportional to song
    /// length, wall-clock randomness, or a second audio/Metal processing pass.
    static func sample(sourceTime: TimeInterval, duration: TimeInterval,
                       artworkHue: Double?, base: MaterialFrame) -> Sample {
        let safeDuration = duration.isFinite && duration > 0 ? duration : 1
        let safeTime = sourceTime.isFinite ? min(max(sourceTime, 0), safeDuration) : 0
        let position = safeTime / safeDuration

        // A dark, legible cover-matched monochromatic spectrum changes gently
        // through the first fifth. Missing cover = stable sapphire fallback.
        let hue = artworkHue?.isFinite == true ? artworkHue! : 0.58
        let drift = sin(safeTime * 0.23) * 0.018
        let album: [RGB] = [
            .hsv(hue + drift, saturation: 0.72, brightness: 0.09),
            .hsv(hue + drift - 0.032, saturation: 0.83, brightness: 0.68),
            .hsv(hue + drift + 0.032, saturation: 0.67, brightness: 0.98),
            .hsv(hue + drift + 0.015, saturation: 0.75, brightness: 0.44),
            .hsv(hue + drift - 0.018, saturation: 0.49, brightness: 0.91)
        ]
        // At the precise 20% mark, the cover still owns the palette.
        // Between 20% and 28% the entire spectrum becomes gradually available.
        let colorful = smooth((position - 0.2) / 0.08)
        let interval = safeTime / 14.0
        let index = Int(interval) % materials.count
        let next = (index + 1) % materials.count
        let blend = smooth(interval - floor(interval))
        let fullPalette = zip(palettes[index], palettes[next]).map {
            RGB.mix($0.0, $0.1, blend)
        }
        let palette = zip(album, fullPalette).map {
            RGB.mix($0.0, $0.1, colorful)
        }
        let mixedMaterial = interpolate(materials[index].parameters,
                                        materials[next].parameters, blend)
        // Nonzero texturing from the first instant. The source MaterialFrame
        // carries the existing pulse, reaction gain, creator viewport and seed.
        let albumTexture = VisualMaterialCatalog.agateZebra.parameters
        let authored = interpolate(albumTexture, mixedMaterial, colorful)
        let p = base.parameters
        let textured = VisualParameterSet(
            distortion: p.distortion, beatPulse: p.beatPulse,
            pulseDecay: p.pulseDecay, offbeatScale: p.offbeatScale,
            warpAmount: p.warpAmount, brightnessBoost: p.brightnessBoost,
            stripingFrequency: authored.stripingFrequency,
            stripingMix: authored.stripingMix,
            speckleIntensity: authored.speckleIntensity,
            embossStrength: authored.embossStrength,
            scanlineDensity: authored.scanlineDensity,
            diffusionSoftness: authored.diffusionSoftness,
            voidThreshold: authored.voidThreshold,
            combStretch: authored.combStretch,
            bilateralSymmetry: authored.bilateralSymmetry,
            halftoneGrating: authored.halftoneGrating)
        let frame = MaterialFrame(
            materialID: "gnarly", type: .marble, parameters: textured,
            intensity: base.intensity, audioResponse: base.audioResponse,
            timestamp: safeTime, seed: base.seed, controls: base.controls,
            signals: base.signals, viewport: base.viewport)
        return Sample(colors: palette, frame: frame, albumPhase: position <= 0.2)
    }
}
