import Foundation

/// The ONE definition of how the user's "Ritmo visual" setting scales any
/// audio-driven output, and of which layer maps audio onto a material.
///
/// Before this type the same 0 / 0.35 / 1 rule was written out in
/// `VisualMaterial.marble(for:)`, `CompositionRuntime`, `CreativeReactiveAccent`,
/// `AudioVisualMapper`, `CreativeParameterResolver` and `LayerAudioBinding`,
/// and Stage 13 materials could receive it twice (baked into the material
/// AND applied by the runtime). Materials are now reaction-free authored
/// data; the gain is applied once, by `MaterialResolver`, from this profile.
enum CreativeReactionProfile {
    /// Off silences every reactive term; Subtle keeps 35 %.
    static func gain(_ reaction: CreativePreset.AudioReaction) -> Double {
        switch reaction {
        case .off: return 0
        case .subtle: return 0.35
        case .responsive: return 1
        }
    }

    /// Which layer turns audio into MATERIAL parameters for one frame.
    /// Exactly one route is active: never program rules AND a material mapping.
    enum MaterialRoute: Equatable, Sendable {
        /// Recipes: the program's equations (CreativeParameterRule /
        /// AudioVisualMapper) drive the Marble distortion; the material only
        /// adds the rhythm pulse.
        case program
        /// Experiences with an authored `MaterialAudioMapping`: bass, energy and
        /// downbeat routes come from the mapping; program distortion is ignored.
        case material
    }

    static func materialRoute(for material: VisualMaterial) -> MaterialRoute {
        material.audioMapping == .legacy ? .program : .material
    }
}
