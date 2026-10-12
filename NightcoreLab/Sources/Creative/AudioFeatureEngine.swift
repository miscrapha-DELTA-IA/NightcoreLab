import Foundation

/// Optional, pull-based bridge between an audio file's source timeline and
/// future visual consumers. It never touches the live AVAudioEngine, exposes
/// no SwiftUI observable state, and has no background timer.
actor AudioFeatureEngine {
    private var current: AudioFeatures = .silent
    private var timeline: AudioFeatureTimeline?
    private var preparedURL: URL?
    private var throttle = VisualResponseThrottle()
    private var generation = 0
    private var lastVisualSampleTime: TimeInterval?
    private var analysisTask: Task<AudioFeatureTimeline, Error>?

    /// Existing frame-input contract from Creative Engine Block 1.
    func snapshot() -> AudioFeatures { current }

    @discardableResult
    func accept(_ frame: AudioFeatureFrame) -> AudioFeatures {
        // Live input (a future source) invalidates an offline timeline.
        analysisTask?.cancel()
        analysisTask = nil
        generation &+= 1
        timeline = nil
        preparedURL = nil
        throttle.reset()
        lastVisualSampleTime = nil
        let features = AudioFeatures(
            bass: frame.bassLevel,
            mid: frame.midLevel,
            treble: frame.trebleLevel,
            energy: frame.rmsLevel,
            beatDetected: frame.beatDetected
        )
        current = features
        return features
    }

    /// Analyzes a LOCAL copy of the same audio source the player loads,
    /// without creating/reconfiguring an AVAudioEngine or changing sound.
    /// Expensive file decoding and envelope processing run at utility QoS.
    /// Caller cancellation and track replacement cancel stale computations.
    func prepareAudio(at url: URL) async throws {
        // Return to a previously analyzed file without redecoding.
        if preparedURL == url && timeline != nil {
            throttle.reset()
            lastVisualSampleTime = nil
            return
        }
        analysisTask?.cancel()
        generation &+= 1
        let request = generation
        timeline = nil
        preparedURL = nil
        current = .silent
        throttle.reset()
        lastVisualSampleTime = nil

        // No automatic analysis during system Low Power Mode.
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let work = Task.detached(priority: .utility) {
            try AudioFeatureAnalyzer.analyzeFile(at: url)
        }
        analysisTask = work
        defer {
            if request == generation { analysisTask = nil }
        }
        let result = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        guard request == generation else { return }
        timeline = result
        preparedURL = url
        analysisTask = nil
    }

    /// Export can reuse cached, immutable feature samples for this exact URL.
    func cachedTimeline(for url: URL) -> AudioFeatureTimeline? {
        preparedURL == url ? timeline : nil
    }

    /// Seekable feature envelope, aligned to EnginePlaybackClock.lyricTime,
    /// which already uses original file time regardless of playback speed.
    func features(at sourceTime: TimeInterval) -> AudioFeatures {
        timeline?.features(at: sourceTime) ?? current
    }

    /// Future views/exports request values explicitly. Nil means throttled:
    /// it is not a command to redraw or to replace the last response.
    /// When paused, return the safe neutral response.
    func visualResponse(at sourceTime: TimeInterval,
                        preset: CreativePreset,
                        isPlaying: Bool,
                        lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) -> VisualResponse? {
        // Pause must clear the visual immediately, even when the media clock
        // stops advancing. Gating first would leave a stale glowing outline.
        guard isPlaying else {
            throttle.reset()
            lastVisualSampleTime = nil
            return .neutral
        }
        guard throttle.shouldEmit(at: sourceTime, lowPower: lowPower) else {
            return nil
        }

        var sampled = features(at: sourceTime)
        if let timeline {
            // Preserve beat onsets across downsampled visual frames. Don't
            // replay distant historical events after a forward seek.
            let prior = lastVisualSampleTime ?? max(0, sourceTime - 0.15)
            let start = sourceTime - prior <= 0.75 ? prior : sourceTime
            let beat = timeline.beatCount(after: start, through: sourceTime) > 0
            sampled = AudioFeatures(
                bass: sampled.bass, mid: sampled.mid, treble: sampled.treble,
                energy: sampled.energy, beatDetected: beat
            )
        }
        lastVisualSampleTime = sourceTime
        return AudioVisualMapper.map(sampled, preset: preset)
    }

    func reset() {
        analysisTask?.cancel()
        analysisTask = nil
        generation &+= 1
        timeline = nil
        preparedURL = nil
        current = .silent
        throttle.reset()
        lastVisualSampleTime = nil
    }
}
