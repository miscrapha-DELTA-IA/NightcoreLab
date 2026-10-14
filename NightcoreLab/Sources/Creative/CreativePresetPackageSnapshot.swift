import Foundation

/// Optional creative handoff; the existing CreativeSnapshot, StoryVideoRequest
/// and video export remain unchanged in Stage 7.
struct CreativePresetPackageSnapshot: Equatable, Sendable {
    enum SnapshotError: Error {
        case mismatchedPreset
    }

    let state: CreativeSnapshot
    /// Complete captured authoring recipe, including every program equation,
    /// layer, keyframe, audio reference, typography choice and deterministic seed.
    let package: CreativePresetPackage

    static func capture(_ state: CreativeSnapshot,
                        package: CreativePresetPackage,
                        duration: TimeInterval,
                        playbackSpeed: Double = 1) throws -> Self {
        guard package.isValid,
              state.preset == package.composition.program.preset else {
            throw SnapshotError.mismatchedPreset
        }
        let timeline = try CompositionTimeline(
            sourceStart: state.visualState.playbackTime,
            playbackSpeed: playbackSpeed, duration: duration,
            padPerformance: package.composition.timeline.padPerformance)
        let source = package.composition
        let frozen = try VisualComposition(
            id: source.id, name: source.name,
            program: source.program, layers: source.layers,
            timeline: timeline,
            deterministicSeed: source.deterministicSeed)
        let preview = CreativePresetPreviewMetadata(
            description: package.previewMetadata.description,
            previewElapsed: min(package.previewMetadata.previewElapsed, duration),
            canvasHint: package.previewMetadata.canvasHint)
        let captured = try CreativePresetPackage(
            id: package.id, name: package.name, author: package.author,
            composition: frozen,
            typographyPreset: package.typographyPreset,
            previewMetadata: preview)
        return Self(state: state, package: captured)
    }

    func frame(at elapsed: TimeInterval,
               features: AudioFeatures? = nil) -> ResolvedCompositionFrame? {
        CompositionFrameResolver.resolve(
            package.composition, elapsed: elapsed, features: features)
    }
}
