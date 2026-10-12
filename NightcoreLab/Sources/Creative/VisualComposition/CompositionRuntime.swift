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

    /// Frozen AudioFeatures path used by CreativeExperienceResolver and
    /// the existing offline-timeline path. The only new API is this overload.
    /// The original frame(at:features:) remains backward-compatible.
    func frame(at elapsed: TimeInterval,
               features: AudioFeatures?,
               typography: TypographyLayer?) -> ResolvedCompositionFrame? {
        guard let base = frame(at: elapsed, features: features) else {
            return nil
        }
        guard let typography,
              base.layers.contains(where: {
                  $0.id == typography.layerID && $0.kind == .typography
              }) else { return base }
        let lyricTime = base.timestamp.sourceTime + typography.lyricOffset
        guard lyricTime.isFinite else { return base }
        return base.withTypography(TypographyResolver.resolve(
            typography.state, at: lyricTime, features: features,
            preset: typography.preset))
    }

    /// Existing preview/export consumers use the SAME overload after
    /// sampling the already-cached audio timeline at sourceTime.
    func frame(at elapsed: TimeInterval,
               audioTimeline: AudioFeatureTimeline?,
               typography: TypographyLayer? = nil) -> ResolvedCompositionFrame? {
        guard let timestamp = composition.timeline.timestamp(at: elapsed) else {
            return nil
        }
        let features = CompositionAudioSampler.sample(
            audioTimeline, at: timestamp.sourceTime)
        return frame(at: elapsed, features: features, typography: typography)
    }

    /// Opt-in experience entry point; no effect on the Story renderer or
    /// legacy call sites. Reject mismatched frozen compositions.
    func experienceFrame(at elapsed: TimeInterval,
                         preset: CreativeExperiencePreset,
                         features: AudioFeatures? = nil,
                         typography: TypographyLayer? = nil) -> CreativeExperienceFrame? {
        guard preset.composition == composition else { return nil }
        return CreativeExperienceResolver.resolve(
            preset, elapsed: elapsed, features: features,
            typography: typography)
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
