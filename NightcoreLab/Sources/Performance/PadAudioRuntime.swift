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

/// Fixed polyphony inside AudioEngineManager's ONE live AVAudioEngine.
/// Voices and tiny emergency release buffers are allocated/attached at setup.
/// A normal retrigger obtains another free voice so earlier tails overlap.
@MainActor
final class PadAudioRuntime {
    nonisolated static let releaseSeconds: Double = 0.008
    static let releaseFrameCount = 384 // 8ms at 48k
    private static let format = AVAudioFormat(
        standardFormatWithSampleRate: PadSampleSynthesizer.sampleRate, channels: 2)!

    let kit: PadKit
    let nodes: [AVAudioPlayerNode]
    /// Emergency release-only nodes: never consume the 12 musical voices.
    /// Their PCM buffers are allocated once before any touch events.
    let releaseNodes: [AVAudioPlayerNode]
    private let releaseBuffers: [AVAudioPCMBuffer]
    /// Never mutate PCM while the audio engine might still be consuming it.
    /// Slots are freed by the AVAudioPlayerNode dataConsumed completion.
    private var releaseSlotBusy: [Bool]
    private var releaseToken: [UInt64]
    private var voiceGains: [Float]
    private(set) var prepared: [String: AVAudioPCMBuffer] = [:]
    private(set) var sourceClip: PerformanceSourceClip?
    private var allocator: PadVoiceAllocator

    init(kit: PadKit = .starter, polyphony: Int = 12) {
        self.kit = kit
        let capacity = max(1, polyphony)
        nodes = (0..<capacity).map { _ in AVAudioPlayerNode() }
        let releaseCapacity = min(8, capacity)
        releaseNodes = (0..<releaseCapacity).map { _ in AVAudioPlayerNode() }
        releaseBuffers = (0..<releaseCapacity).compactMap { _ in
            AVAudioPCMBuffer(pcmFormat: Self.format,
                              frameCapacity: AVAudioFrameCount(Self.releaseFrameCount))
        }
        releaseSlotBusy = Array(repeating: false, count: releaseCapacity)
        releaseToken = Array(repeating: 0, count: releaseCapacity)
        voiceGains = Array(repeating: 0, count: capacity)
        allocator = PadVoiceAllocator(capacity: capacity)
        for sample in kit.samples {
            prepared[sample.id] = PadSampleSynthesizer.make(sample)
        }
    }

    var isReady: Bool {
        releaseBuffers.count == releaseNodes.count &&
            kit.isValid && kit.samples.allSatisfy { prepared[$0.id] != nil }
    }

    func descriptor(for padID: String) -> SampleDescriptor? {
        kit.samples.first(where: { $0.id == padID }) ??
            ((sourceClip != nil && padID == PerformanceSourceClip.slotID)
             ? sourceClip?.descriptor : nil)
    }

    func installSourceClip(_ clip: PerformanceSourceClip, pcm: PerformanceClipPCM) -> Bool {
        guard clip.isValid, let buffer = pcm.makeBuffer() else { return false }
        stopAll()
        prepared[PerformanceSourceClip.slotID] = buffer
        sourceClip = clip
        return true
    }

    func clearSourceClip() {
        stopAll()
        prepared[PerformanceSourceClip.slotID] = nil
        sourceClip = nil
    }

    func attach(to engine: AVAudioEngine) {
        (nodes + releaseNodes).forEach { engine.attach($0) }
    }

    func connect(to engine: AVAudioEngine, mixer: AVAudioMixerNode) {
        for node in nodes + releaseNodes {
            engine.connect(node, to: mixer, format: Self.format)
        }
    }

    /// Start players once on the already-running engine, outside the touch
    /// callback. On normal hits scheduleBuffer can then append immediately
    /// without a new node.play() transition (historically ~22ms p95).
    func primeVoices() {
        for node in nodes + releaseNodes where !node.isPlaying { node.play() }
    }

    /// Continue a stolen/choked voice in a short preallocated release channel.
    /// Only 384 stereo frames are copied; no allocation or I/O on touch.
    /// When all release channels are busy, prefer a rare hard cut to
    /// rewriting a PCM buffer that CoreAudio may still be reading.
    private func release(_ item: PadVoiceAllocator.InterruptedLease,
                         at now: TimeInterval) {
        guard let id = item.previous.id, let source = prepared[id],
              let srcL = source.floatChannelData?[0],
              let srcR = source.floatChannelData?[1],
              let slot = releaseSlotBusy.indices.first(where: { !releaseSlotBusy[$0] }),
              slot < releaseBuffers.count,
              let destL = releaseBuffers[slot].floatChannelData?[0],
              let destR = releaseBuffers[slot].floatChannelData?[1] else { return }
        let elapsed = max(0, now - item.previous.began)
        let sourceIndex = min(Int(elapsed * PadSampleSynthesizer.sampleRate),
                              Int(source.frameLength))
        let length = Self.releaseFrameCount
        for i in 0..<length {
            let index = sourceIndex + i
            let fade = Float(length - 1 - i) / Float(max(1, length - 1))
            let envelope = fade * fade
            destL[i] = index < Int(source.frameLength) ? srcL[index] * envelope : 0
            destR[i] = index < Int(source.frameLength) ? srcR[index] * envelope : 0
        }
        let node = releaseNodes[slot]
        // Do not stop an already-primed release player: this slot has
        // completed consumption, so it has no pending PCM to interrupt.
        node.volume = voiceGains[item.voiceIndex]
        releaseBuffers[slot].frameLength = AVAudioFrameCount(length)
        releaseSlotBusy[slot] = true
        releaseToken[slot] &+= 1
        let token = releaseToken[slot]
        node.scheduleBuffer(releaseBuffers[slot], at: nil, options: .interrupts,
                            completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.releaseToken[slot] == token else { return }
                self.releaseSlotBusy[slot] = false
            }
        }
        if !node.isPlaying { node.play() }
    }

    func trigger(padID: String, velocity: Float,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                 timing: ((PadNodeDispatchTiming) -> Void)? = nil) -> Bool {
        guard let sample = descriptor(for: padID),
              let buffer = prepared[padID], velocity.isFinite, velocity > 0 else { return false }
        let vel = min(max(velocity, 0), 1)
        guard let selection = allocator.allocate(
            id: padID, chokeGroup: sample.chokeGroup,
            duration: sample.duration, at: now) else { return false }
        let measuring = timing != nil
        let started = measuring ? ProcessInfo.processInfo.systemUptime : 0
        for interrupted in selection.interrupted {
            release(interrupted, at: now)
        }
        // Choked voices are intentionally stopped after scheduling the release.
        for index in selection.chokeIndices { nodes[index].stop() }
        let node = nodes[selection.voiceIndex]
        // Reusing an idle voice must NOT stop another sounding voice.
        // An exhausted pool steals the oldest voice, but its outgoing signal
        // is already declicked on a dedicated preconnected release node.
        if selection.stoleVoice { node.stop() }
        let stopped = measuring ? ProcessInfo.processInfo.systemUptime : 0
        voiceGains[selection.voiceIndex] = sample.gain * vel
        node.volume = voiceGains[selection.voiceIndex]
        node.scheduleBuffer(buffer, at: nil, options: .interrupts)
        let scheduled = measuring ? ProcessInfo.processInfo.systemUptime : 0
        // Only a stolen/stopped voice needs replay; normal prepared voices
        // remain running and accept subsequent buffers without play().
        if !node.isPlaying { node.play() }
        if let timing {
            let played = ProcessInfo.processInfo.systemUptime
            timing(PadNodeDispatchTiming(stopMS: max(0, stopped - started) * 1_000,
                                         scheduleMS: max(0, scheduled - stopped) * 1_000,
                                         playMS: max(0, played - scheduled) * 1_000))
        }
        return true
    }

    func stopAll() {
        (nodes + releaseNodes).forEach { $0.stop() }
        releaseToken = releaseToken.map { $0 &+ 1 }
        releaseSlotBusy = Array(repeating: false, count: releaseSlotBusy.count)
        voiceGains = Array(repeating: 0, count: voiceGains.count)
        allocator.reset()
    }
}
