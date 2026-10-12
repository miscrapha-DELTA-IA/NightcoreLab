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
struct MaterialFrame: Equatable, Sendable {
    let materialID: String
    let type: VisualMaterialType
    let parameters: VisualParameterSet
    let intensity: Double
    let audioResponse: MaterialAudioResponse
    let timestamp: TimeInterval

    var marbleUniforms: MarbleUniforms {
        MarbleUniforms(distortion: parameters.distortion,
                       beatPulse: parameters.beatPulse,
                       warpAmount: parameters.warpAmount,
                       brightnessBoost: parameters.brightnessBoost)
    }
}
