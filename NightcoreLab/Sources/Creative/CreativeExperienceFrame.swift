import Foundation

/// The existing CreativeParameterFrame remains the renderer contract.
/// These supplementary, normalized controls are DATA only in Stage 9.
struct CreativeExperienceVisualFrame: Equatable, Sendable {
    let parameters: CreativeParameterFrame
    let intensity: Double
    let movement: Double
}

struct CreativeExperienceFrame: Equatable, Sendable {
    let experienceID: String
    let visualFrame: CreativeExperienceVisualFrame
    let typographyFrame: TypographyFrame?
    let compositionFrame: ResolvedCompositionFrame
    let audioState: CreativeAudioState

    var timestamp: CompositionTimestamp { compositionFrame.timestamp }
}
