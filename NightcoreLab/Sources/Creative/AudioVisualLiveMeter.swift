import AVFoundation
import Foundation
import os

/// Audio-derived visual levels. Separate the percussion transient from the
/// slower song energy; no extra AVAudioEngine or FFT worker is created.
struct LiveAudioLevels: Equatable, Sendable {
    var rms: Double = 0
    var bass: Double = 0
    var mid: Double = 0
    var onset: Double = 0
    var beatPulse: Double = 0
    var songEnergy: Double = 0
    static let silence = LiveAudioLevels()
}

/// Fixed-cost envelope processor. The kick is detected above the moving
/// low-frequency floor, with 18 ms attack / 240 ms exponential release.
/// Energy follows the overall mix over ~800 ms; it does not slow shader time.
struct MusicalBeatEnvelope: Sendable {
    private(set) var lowFloor = 0.0
    private(set) var beat = 0.0
    private(set) var energy = 0.0

    mutating func advance(bass: Double, rms: Double, dt: Double) -> (beat: Double, energy: Double, onset: Double) {
        guard dt.isFinite, dt > 0 else { return (beat, energy, 0) }
        let step = min(dt, 0.1)
        let low = clamp(bass)
        let loud = clamp(rms)
        let baseline = lowFloor
        let transient = clamp((low - baseline - 0.025) * 5.0)
        // Fast upward response and gentle ~350ms background adaptation:
        // a steady sine wave cannot become a recurring fake kick.
        lowFloor += (low - lowFloor) * (1 - exp(-step / 0.35))
        let timeConstant = transient > beat ? 0.018 : 0.240
        beat += (transient - beat) * (1 - exp(-step / timeConstant))
        energy += (loud - energy) * (1 - exp(-step / 0.800))
        return (clamp(beat), clamp(energy), transient)
    }

    private func clamp(_ x: Double) -> Double {
        x.isFinite ? min(1, max(0, x)) : 0
    }
}

/// Latest-wins meter connected to the ONE existing playback mixer output tap.
/// Audio callback uses strided PCM, bounded arithmetic and one small lock.
/// There is no Task, new engine, file analysis or SwiftUI update in this path.
final class AudioVisualLiveMeter: @unchecked Sendable {
    private struct State {
        var sample = LiveAudioLevels.silence
        var lowpass: Float = 0
        var midpass: Float = 0
        var envelope = MusicalBeatEnvelope()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func snapshot() -> LiveAudioLevels { state.withLock { $0.sample } }
    func reset() { state.withLock { $0 = State() } }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0],
              buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        let count = Int(buffer.frameLength)
        let step = 4
        let rate = buffer.format.sampleRate / Double(step)
        let a = Float(min(0.5, 2 * Double.pi * 140 / (rate + 2 * Double.pi * 140)))
        let midA = Float(min(0.5, 2 * Double.pi * 1_200 / (rate + 2 * Double.pi * 1_200)))
        var low = state.withLock { $0.lowpass }
        var mid = state.withLock { $0.midpass }
        var power = 0.0
        var bassPower = 0.0
        var midPower = 0.0
        var n = 0
        for i in stride(from: 0, to: count, by: step) {
            let x = samples[i]
            guard x.isFinite else { continue }
            low += a * (x - low)
            mid += midA * (x - mid)
            power += Double(x) * Double(x)
            bassPower += Double(low) * Double(low)
            midPower += Double(mid - low) * Double(mid - low)
            n += 1
        }
        guard n > 0 else { return }
        let rms = min(1, sqrt(power / Double(n)) * 3.6)
        let bass = min(1, sqrt(bassPower / Double(n)) * 5.0)
        let warmth = min(1, sqrt(midPower / Double(n)) * 4.0)
        let dt = Double(count) / buffer.format.sampleRate
        state.withLock {
            let response = $0.envelope.advance(bass: bass, rms: rms, dt: dt)
            $0.sample = LiveAudioLevels(rms: rms, bass: bass, mid: warmth,
                                        onset: response.onset,
                                        beatPulse: response.beat,
                                        songEnergy: response.energy)
            $0.lowpass = low
            $0.midpass = mid
        }
    }
}
