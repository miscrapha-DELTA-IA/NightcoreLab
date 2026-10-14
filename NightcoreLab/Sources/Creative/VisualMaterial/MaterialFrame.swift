import Foundation
import CoreGraphics

/// Contributions after clamping. Brightness/accent adjust the existing pulse
/// glow coefficient: they do not add an independent lighting pass.
struct MaterialAudioResponse: Equatable, Sendable {
    let distortion: Double
    let brightness: Double
    let pulse: Double
    let accent: Double
}

/// Complete CPU result at an ORIGINAL-source timestamp. The renderer owns
/// canvas size, palette and its frozen animation phase, as before Stage 13.
struct MaterialReactiveSignals: Equatable, Sendable {
    let energy: Double
    let bass: Double
    let movement: Double
    let brightness: Double
}

/// Logical viewport selected by CompositionLayoutPolicy; the Metal shader
/// still receives GeometryReader pixels and is never rebuilt.
struct MaterialViewport: Equatable, Sendable {
    let width: Double
    let height: Double
    var aspectRatio: Double { width / height }
}

/// Immutable Stage 13 frame, extended rather than replaced.
struct MaterialFrame: Equatable, Sendable {
    let materialID: String
    let type: VisualMaterialType
    let parameters: VisualParameterSet
    let intensity: Double
    let audioResponse: MaterialAudioResponse
    let timestamp: TimeInterval
    let seed: UInt64
    let controls: MaterialControls
    let signals: MaterialReactiveSignals
    /// Optional session-frozen viewport: nil preserves every Stage 13 caller.
    var viewport: MaterialViewport? = nil

    func withViewport(_ geometry: CGRect?) -> MaterialFrame {
        guard let geometry else { return self }
        var copy = self
        copy.viewport = MaterialViewport(
            width: Double(geometry.width), height: Double(geometry.height))
        return copy
    }

    /// Compatibility for still-image callers that pass an explicit pulse
    /// (pre-Stage-13 TurbulentMarbleView API): the same contract, pulse set.
    func replacingBeatPulse(_ pulse: Double) -> MaterialFrame {
        let p = parameters
        return MaterialFrame(
            materialID: materialID, type: type,
            parameters: VisualParameterSet(
                distortion: p.distortion, beatPulse: pulse, pulseDecay: p.pulseDecay,
                offbeatScale: p.offbeatScale, warpAmount: p.warpAmount,
                brightnessBoost: p.brightnessBoost,
                stripingFrequency: p.stripingFrequency, stripingMix: p.stripingMix,
                speckleIntensity: p.speckleIntensity, embossStrength: p.embossStrength,
                scanlineDensity: p.scanlineDensity, diffusionSoftness: p.diffusionSoftness,
                voidThreshold: p.voidThreshold, combStretch: p.combStretch,
                bilateralSymmetry: p.bilateralSymmetry,
                halftoneGrating: p.halftoneGrating),
            intensity: intensity, audioResponse: audioResponse, timestamp: timestamp,
            seed: seed, controls: controls, signals: signals,
            viewport: viewport)
    }

    /// The shader binding is the resolved parameter set itself.
    var marbleUniforms: MarbleUniforms { parameters }
}
