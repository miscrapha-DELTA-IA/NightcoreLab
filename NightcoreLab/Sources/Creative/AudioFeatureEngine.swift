import Foundation

/// Optional, pull-based bridge between an audio file's source timeline and
/// future visual consumers. It never touches the live AVAudioEngine, exposes
/// no SwiftUI observable state, and has no background timer.
actor AudioFeatureEngine {
    private var current: AudioFeatures = .silent
    private var timeline: AudioFeatureTimeline?
    private var throttle = VisualResponseThrottle()
    private var generation = 0
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
        throttle.reset()
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
        analysisTask?.cancel()
        generation &+= 1
        let request = generation
        timeline = nil
        current = .silent
        throttle.reset()

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
        analysisTask = nil
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
        guard throttle.shouldEmit(at: sourceTime, lowPower: lowPower) else {
            return nil
        }
        guard isPlaying else { return .neutral }
        return AudioVisualMapper.map(features(at: sourceTime), preset: preset)
    }

    func reset() {
        analysisTask?.cancel()
        analysisTask = nil
        generation &+= 1
        timeline = nil
        current = .silent
        throttle.reset()
    }
}
