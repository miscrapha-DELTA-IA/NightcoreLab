import Foundation

/// Opt-in handoff only; does not modify CreativeSnapshot, StoryVideoRequest,
/// StoryFrameRenderer, existing Marble, player or Share Export.
enum CreativeSnapshotAdapter {
    /// Freeze the COMPLETE program/rules as well as the preset identity.
    /// If no program is supplied, the captured preset is wrapped without
    /// guessing which catalog entry the user originally selected.
    static func freeze(_ snapshot: CreativeSnapshot,
                       program: CreativeVisualProgram? = nil,
                       duration: TimeInterval,
                       playbackSpeed: Double = 1,
                       layers: [PresetLayer] = PresetLayer.defaultLayers,
                       deterministicSeed: UInt64 = 0) throws -> VisualComposition {
        let frozenProgram = program ?? CreativeVisualProgram(preset: snapshot.preset)
        guard frozenProgram.preset == snapshot.preset else {
            throw VisualComposition.CompositionError.mismatchedPreset
        }
        let timeline = try CompositionTimeline(
            sourceStart: snapshot.visualState.playbackTime,
            playbackSpeed: playbackSpeed,
            duration: duration)
        return try VisualComposition(
            id: frozenProgram.preset.id, name: frozenProgram.preset.name,
            program: frozenProgram, layers: layers,
            timeline: timeline, deterministicSeed: deterministicSeed)
    }

    /// From an explicitly selected catalog preset with no snapshot, intended
    /// for tests/importers and later composition editors.
    static func wrap(_ program: CreativeVisualProgram,
                     timeline: CompositionTimeline,
                     layers: [PresetLayer] = PresetLayer.defaultLayers,
                     deterministicSeed: UInt64 = 0) throws -> VisualComposition {
        try VisualComposition(
            id: program.preset.id, name: program.preset.name,
            program: program, layers: layers,
            timeline: timeline, deterministicSeed: deterministicSeed)
    }
}
