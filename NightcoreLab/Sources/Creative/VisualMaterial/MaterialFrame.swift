import Foundation

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

    /// The shader binding is the resolved parameter set itself.
    var marbleUniforms: MarbleUniforms { parameters }
}
