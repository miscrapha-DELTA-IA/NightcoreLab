import AVFoundation
import Foundation
import os

/// A latest-wins meter for the one existing playback mixer's output tap.
/// The callback only scans a bounded, strided PCM window and exchanges a few
/// scalars under a tiny unfair-lock critical section. No Task, SwiftUI,
/// allocations, file analysis, graph mutation or FFT occurs in the callback.
struct LiveAudioLevels: Equatable, Sendable {
    var rms: Double = 0
    var bass: Double = 0
    var onset: Double = 0
    static let silence = LiveAudioLevels()
}

final class AudioVisualLiveMeter: @unchecked Sendable {
    private struct State {
        var sample = LiveAudioLevels.silence
        var lowpass: Float = 0
        var previousBass: Double = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func snapshot() -> LiveAudioLevels { state.withLock { $0.sample } }
    func reset() {
        state.withLock { $0 = State() }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0],
              buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        let count = Int(buffer.frameLength)
        let step = 4
        let rate = buffer.format.sampleRate / Double(step)
        let a = Float(min(0.5, 2 * Double.pi * 140 / (rate + 2 * Double.pi * 140)))
        var low = state.withLock { $0.lowpass }
        var power = 0.0
        var bassPower = 0.0
        var n = 0
        for i in stride(from: 0, to: count, by: step) {
            let x = samples[i]
            guard x.isFinite else { continue }
            low += a * (x - low)
            power += Double(x) * Double(x)
            bassPower += Double(low) * Double(low)
            n += 1
        }
        guard n > 0 else { return }
        // 0...1 display coordinates; do not interpret as LUFS or a BPM.
        let rms = min(1, sqrt(power / Double(n)) * 3.6)
        let bass = min(1, sqrt(bassPower / Double(n)) * 5.0)
        state.withLock {
            let transient = max(0, bass - $0.previousBass * 0.92)
            $0.sample = LiveAudioLevels(rms: rms, bass: bass,
                                        onset: min(1, transient * 3.0))
            $0.previousBass = bass
            $0.lowpass = low
        }
    }
}
