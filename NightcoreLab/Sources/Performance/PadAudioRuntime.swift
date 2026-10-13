import AVFoundation
import Foundation

/// Prebuilt original PCM kit. Synthesis runs during setup, never on a pad tap.
/// All sounds are synthesized from elementary oscillators/noise, not recordings.
enum PadSampleSynthesizer {
    static let sampleRate: Double = 48_000

    static func make(_ sample: SampleDescriptor) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let frames = AVAudioFrameCount((sample.duration * sampleRate).rounded(.up))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let left = buffer.floatChannelData?[0],
              let right = buffer.floatChannelData?[1] else { return nil }
        buffer.frameLength = frames

        var seed: UInt32 = 0xC0FFEE42
        var lowpass = 0.0
        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let x = t / sample.duration
            seed = 1_664_525 &* seed &+ 1_013_904_223
            let noise = Double(seed & 0xFFFF) / 32767.5 - 1
            lowpass = 0.87 * lowpass + 0.13 * noise
            let highpass = noise - lowpass
            let amp: Double
            switch sample.id {
            case "kick":
                phase += 2 * .pi * (48 + 115 * exp(-t * 28)) / sampleRate
                amp = sin(phase) * exp(-t * 12) + 0.11 * noise * exp(-t * 75)
            case "snare":
                phase += 2 * .pi * 185 / sampleRate
                amp = (0.73 * highpass + 0.27 * sin(phase)) * exp(-t * 16)
            case "closed-hat":
                amp = highpass * exp(-t * 48)
            case "open-hat":
                amp = highpass * exp(-t * 9)
            case "clap":
                let early = (t < 0.016 || (t > 0.026 && t < 0.042) ||
                             (t > 0.055 && t < 0.075)) ? 1.0 : 0.38
                amp = highpass * early * exp(-t * 12)
            case "crash":
                amp = highpass * exp(-t * 3.9)
            case "808":
                phase += 2 * .pi * (45 + 70 * exp(-t * 26)) / sampleRate
                let bass = sin(phase) * exp(-t * 2.8)
                amp = tanh(1.25 * bass) * 0.7
            default:
                amp = 0
            }
            // Short fade-in prevents a discontinuity; fade-out bounds each
            // sample, including a stolen/short-lived cymbal tail.
            let attack = min(1, t / 0.002)
            let release = min(1, max(0, (sample.duration - t) / 0.025))
            let value = Float(min(0.95, max(-0.95, amp * attack * release)))
            left[i] = value
            right[i] = value
            _ = x
        }
        return buffer
    }
}

/// Fixed polyphony; 12 AVAudioPlayerNodes are attached to the existing
/// AudioEngineManager's graph. Never owns or instantiates an AVAudioEngine.
/// No sample generation, file operations or dependency resolution on touch.
@MainActor
final class PadAudioRuntime {
    let kit: PadKit
    let nodes: [AVAudioPlayerNode]
    private(set) var prepared: [String: AVAudioPCMBuffer] = [:]
    private var allocator: PadVoiceAllocator

    init(kit: PadKit = .starter, polyphony: Int = 12) {
        self.kit = kit
        self.nodes = (0..<max(1, polyphony)).map { _ in AVAudioPlayerNode() }
        allocator = PadVoiceAllocator(capacity: nodes.count)
        for sample in kit.samples {
            prepared[sample.id] = PadSampleSynthesizer.make(sample)
        }
    }

    var isReady: Bool {
        kit.isValid && prepared.count == kit.samples.count
    }

    func attach(to engine: AVAudioEngine) {
        nodes.forEach { engine.attach($0) }
    }

    func connect(to engine: AVAudioEngine, mixer: AVAudioMixerNode) {
        for node in nodes {
            engine.connect(node, to: mixer,
                           format: AVAudioFormat(standardFormatWithSampleRate:
                                PadSampleSynthesizer.sampleRate, channels: 2)!)
        }
    }

    func trigger(padID: String, velocity: Float,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let sample = kit.samples.first(where: { $0.id == padID }),
              let buffer = prepared[padID], velocity.isFinite, velocity > 0 else { return false }
        let vel = min(max(velocity, 0), 1)
        guard let selection = allocator.allocate(
            id: padID, chokeGroup: sample.chokeGroup,
            duration: sample.duration, at: now) else { return false }
        for index in selection.chokeIndices { nodes[index].stop() }
        let node = nodes[selection.voiceIndex]
        node.stop()
        node.volume = sample.gain * vel
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        node.play()
        return true
    }

    func stopAll() {
        nodes.forEach { $0.stop() }
        allocator.reset()
    }
}
