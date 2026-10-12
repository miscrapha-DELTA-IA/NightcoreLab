import Foundation

/// Source-time feature sampler shared by preview and export. This preserves
/// the Marble's existing fixed 150 ms onset look-back without adding an FFT.
enum CompositionAudioSampler {
    static func sample(_ timeline: AudioFeatureTimeline?,
                       at sourceTime: TimeInterval) -> AudioFeatures? {
        guard let timeline, sourceTime.isFinite,
              sourceTime >= 0, sourceTime <= timeline.duration else { return nil }
        let frame = timeline.features(at: sourceTime)
        let onsets = timeline.beatCount(
            after: max(0, sourceTime - 0.15), through: sourceTime)
        return AudioFeatures(
            bass: frame.bass, mid: frame.mid, treble: frame.treble,
            energy: frame.energy, beatDetected: onsets > 0)
    }
}

/// Immutable runtime coordinator; no rendering, UI, audio engine, clock or
/// frame history. Repeated/out-of-order requests always return the same data.
struct CompositionRuntime: Sendable {
    let composition: VisualComposition

    init(composition: VisualComposition) {
        self.composition = composition
    }

    /// An already frozen feature sample. The caller must supply one measured
    /// at the composition's sourceTime, not the video's elapsed time.
    func frame(at elapsed: TimeInterval,
               features: AudioFeatures?) -> ResolvedCompositionFrame? {
        CompositionFrameResolver.resolve(composition, elapsed: elapsed,
                                         features: features)
    }

    /// The offline timeline is already cached by AudioFeatureEngine. Sampling
    /// is bounded and uses the SAME timestamp/beat window as the legacy Marble.
    func frame(at elapsed: TimeInterval,
               audioTimeline: AudioFeatureTimeline?) -> ResolvedCompositionFrame? {
        guard let timestamp = composition.timeline.timestamp(at: elapsed) else {
            return nil
        }
        let features = CompositionAudioSampler.sample(audioTimeline,
                                                      at: timestamp.sourceTime)
        return frame(at: elapsed, features: features)
    }

    /// Freeze a program once at StoryRequestBuilder time so preview and export
    /// receive exactly the same composition, clock and existing visual rules.
    static func freeze(program: CreativeVisualProgram?,
                       sourceStart: TimeInterval, speed: Double,
                       duration: TimeInterval) -> VisualComposition? {
        guard let program,
              let timeline = try? CompositionTimeline(
                sourceStart: sourceStart, playbackSpeed: speed, duration: duration) else {
            return nil
        }
        return try? CreativeSnapshotAdapter.wrap(program, timeline: timeline)
    }
}
