import Foundation

/// Deterministic bridge between a frozen source-audio feature timeline and
/// the projectM-style typed parameters. Live playback, Story scrub preview
/// and MP4 encoding all use this with the original-file timestamp.
enum CreativeMarbleFrameResolver {
    static func resolve(program: CreativeVisualProgram?,
                        timeline: AudioFeatureTimeline?,
                        sourceTime: TimeInterval) -> CreativeParameterFrame {
        guard let program, let timeline, sourceTime.isFinite,
              sourceTime >= 0, sourceTime <= timeline.duration,
              program.preset.audioReaction != .off else { return .neutral }

        let frame = timeline.features(at: sourceTime)
        // Use a fixed look-back, not previous render-frame state: scrubbing,
        // reordering frames and different FPS profiles yield identical values.
        let pulses = timeline.beatCount(
            after: max(0, sourceTime - 0.15), through: sourceTime)
        let features = AudioFeatures(
            bass: frame.bass, mid: frame.mid, treble: frame.treble,
            energy: frame.energy, beatDetected: pulses > 0)
        let response = AudioVisualMapper.map(
            features, preset: program.preset)
        return CreativeParameterResolver.resolve(
            program: program, response: response,
            features: features, sourceTime: sourceTime)
    }
}
