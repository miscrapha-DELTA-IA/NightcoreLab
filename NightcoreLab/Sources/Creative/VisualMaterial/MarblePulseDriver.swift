import Foundation

/// Render-rate pulse source for the LIVE Marble. The 12 Hz reactive loop is
/// too coarse for a ~150 ms pulse, so the Marble's own TimelineView asks this
/// driver once per frame. The value is still a pure function of the source
/// time read from the playback clock.
struct MarblePulseDriver: Equatable, Sendable {
    let material: VisualMaterial
    let rhythm: RhythmAnalysisResult?
    let clock: PlaybackClock
    let timeline: AudioFeatureTimeline?
    let reactionGain: Double
    let seed: UInt64
    /// Identity of this run, so views only update when the source changes.
    let id: UUID

    init(material: VisualMaterial, rhythm: RhythmAnalysisResult?, clock: PlaybackClock,
         timeline: AudioFeatureTimeline? = nil, reactionGain: Double = 1,
         seed: UInt64 = 0) {
        self.material = material
        self.rhythm = rhythm
        self.clock = clock
        self.timeline = timeline
        self.reactionGain = reactionGain
        self.seed = seed
        self.id = UUID()
    }

    func pulse() -> Double {
        guard clock.isPlaying else { return 0 }
        return MaterialResolver.beatPulse(
            material, rhythm: rhythm.flatMap { RhythmFrame.at(clock.lyricTime, in: $0) }) * reactionGain
    }

    /// The boundary reads the clock once; the resolver itself never reads it.
    func frame(parameters: CreativeParameterFrame) -> MaterialFrame {
        let time = clock.lyricTime
        let playing = clock.isPlaying
        return MaterialResolver.resolve(
            material,
            features: playing ? CompositionAudioSampler.sample(timeline, at: time) : nil,
            rhythm: playing ? rhythm.flatMap { RhythmFrame.at(time, in: $0) } : nil,
            timestamp: time, parameters: parameters,
            reactionGain: playing ? reactionGain : 0, seed: seed)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}
