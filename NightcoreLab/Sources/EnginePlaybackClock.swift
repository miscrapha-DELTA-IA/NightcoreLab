import AVFoundation
import os
import Darwin

/// Relógio de letras sobre AVAudioPlayerNode.
///
/// Por que não usar tempo de parede × speed?
///   `playerTime.sampleTime` conta frames do ARQUIVO consumidos pelo node, então já está na
///   linha do tempo original mesmo com AVAudioUnitTimePitch/Varispeed a jusante.
///
/// `lastRenderTime` só atualiza a cada buffer (~20 ms), o que faria o fill "dar degraus" em 120 Hz.
/// Por isso ancoramos (mídia, hostTime) e extrapolamos entre buffers usando `speed`.
final class EnginePlaybackClock: PlaybackClock, @unchecked Sendable {

    private struct State {
        var segmentOffset: TimeInterval = 0   // posição do arquivo no último schedule/seek
        var speed: Double = 1                 // rate do timePitch/varispeed
        var anchorMedia: TimeInterval = 0
        var anchorHost: UInt64 = 0
        var hasAnchor = false
        var frozen: TimeInterval = 0
        /// Cached AVAudioSession.outputLatency (Stage 10C). Reading the session
        /// on every lyricTime query (up to 120 Hz per TimelineView, plus the
        /// reactive loop) was unnecessary: it only changes with the route.
        var outputLatency: TimeInterval = 0
    }

    private let player: AVAudioPlayerNode
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(player: AVAudioPlayerNode) {
        self.player = player
        refreshOutputLatency()
    }

    /// Call when playback starts and on every audio route change
    /// (Bluetooth can exceed 200 ms).
    func refreshOutputLatency() {
        let latency = AVAudioSession.sharedInstance().outputLatency
        let safe = latency.isFinite ? max(0, latency) : 0
        state.withLock { $0.outputLatency = safe }
    }

    // MARK: Chamar do seu engine

    /// Após `player.stop()` + `scheduleSegment`, o sampleTime do node volta a 0.
    func didSeek(to seconds: TimeInterval) {
        state.withLock { s in
            s.segmentOffset = seconds; s.frozen = seconds; s.hasAnchor = false
        }
    }

    /// Preserve a precise paused position; a stopped player has no valid live render time.
    func didPause(at seconds: TimeInterval) {
        state.withLock { s in
            s.frozen = seconds
            s.hasAnchor = false
        }
    }

    /// Sempre que mudar timePitch.rate / varispeed.rate.
    func setSpeed(_ speed: Double) {
        state.withLock { s in
            // A âncora se renova no próximo buffer (≤ ~20 ms), erro desprezível.
            s.speed = max(speed, 0.01)
            s.hasAnchor = false
        }
    }

    // MARK: PlaybackClock

    var isPlaying: Bool { player.isPlaying }
    var playbackSpeed: Double { state.withLock { $0.speed } }

    /// Convert the route's wall-clock latency to the source timeline.
    /// A 200 ms output delay spans 400 ms of lyrics at 2× speed.
    static func audibleSourceTime(anchorMedia: TimeInterval, elapsed: TimeInterval,
                                  speed: Double, outputLatency: TimeInterval) -> TimeInterval {
        max(0, anchorMedia + elapsed * speed - outputLatency * speed)
    }

    var lyricTime: TimeInterval {
        let playing = player.isPlaying
        let rt = playing ? player.lastRenderTime : nil
        let pt = rt.flatMap { $0.isSampleTimeValid ? player.playerTime(forNodeTime: $0) : nil }

        return state.withLock { s in
            if let rt, rt.isHostTimeValid, let pt, pt.sampleRate > 0, rt.hostTime != s.anchorHost {
                s.anchorHost = rt.hostTime
                s.anchorMedia = Double(pt.sampleTime) / pt.sampleRate + s.segmentOffset
                s.hasAnchor = true
            }
            guard playing else { return s.frozen }
            guard s.hasAnchor else { return s.frozen }

            let delta = Int64(bitPattern: mach_absolute_time() &- s.anchorHost)
            let secs = AVAudioTime.seconds(forHostTime: delta.magnitude) * (delta < 0 ? -1 : 1)
            let t = Self.audibleSourceTime(
                anchorMedia: s.anchorMedia, elapsed: min(max(secs, 0), 0.15),
                speed: s.speed, outputLatency: s.outputLatency)
            s.frozen = t
            return t
        }
    }
}
