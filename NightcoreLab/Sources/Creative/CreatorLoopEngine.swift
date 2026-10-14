import AVFoundation
import Foundation

enum CreatorLoopSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakbeat = "Breakbeat"
    case subBassline = "Sub Bassline"
    case synthArp = "Synth Arp"
    case riserTexture = "Riser / Texture"
    var id: String { rawValue }
}

enum CreatorLoopGrid {
    /// Source-relative next recorded beat; do not fabricate a clock when
    /// acoustic evidence is missing. Four-beat bar if downbeat unavailable.
    static func nextBoundary(after source: TimeInterval,
                             rhythm: RhythmAnalysisResult?,
                             bar: Bool = true) -> TimeInterval? {
        guard source.isFinite, source >= 0, let rhythm,
              rhythm.quality == .medium || rhythm.quality == .high else { return nil }
        let beats = rhythm.beatGrid
        guard beats.count >= 4 else { return nil }
        return beats.first {
            $0.time > source + 0.010 &&
            (!bar || ($0.isDownbeat && rhythm.downbeatConfidence >= 0.4 ||
                       rhythm.downbeatConfidence < 0.4 && $0.index.isMultiple(of: 4)))
        }?.time
    }

    static func tempo(_ rhythm: RhythmAnalysisResult?) -> Double? {
        guard let rhythm, rhythm.quality == .medium || rhythm.quality == .high,
              let v = rhythm.bpmCandidates.first?.bpm,
              v.isFinite, (55...210).contains(v) else { return nil }
        return v
    }
}

@MainActor
final class CreatorLoopEngine {
    private struct Voice {
        let node: AVAudioPlayerNode
        let pitch: AVAudioUnitTimePitch
        let mixer: AVAudioMixerNode
        let buffer: AVAudioPCMBuffer
    }
    private var voices: [CreatorLoopSlot: Voice] = [:]
    private var stopTasks: [CreatorLoopSlot: Task<Void, Never>] = [:]
    private(set) var active: Set<CreatorLoopSlot> = []
    private let sampleRate: Double = 48_000

    func attach(to engine: AVAudioEngine, output: AVAudioMixerNode,
                format: AVAudioFormat) {
        if voices.isEmpty {
            for slot in CreatorLoopSlot.allCases {
                let node = AVAudioPlayerNode()
                let pitch = AVAudioUnitTimePitch()
                let mixer = AVAudioMixerNode()
                guard let buffer = makeBuffer(slot) else { continue }
                [node, pitch, mixer].forEach { engine.attach($0) }
                engine.connect(node, to: pitch, format: buffer.format)
                engine.connect(pitch, to: mixer, format: buffer.format)
                engine.connect(mixer, to: output, format: format)
                voices[slot] = Voice(node: node, pitch: pitch, mixer: mixer, buffer: buffer)
            }
        } else {
            for voice in voices.values {
                engine.connect(voice.mixer, to: output, format: format)
            }
        }
    }

    func toggle(_ slot: CreatorLoopSlot, sourceTime: TimeInterval,
                speed: Float, rhythm: RhythmAnalysisResult?,
                key: KeyAnalysisResult?, engine: AVAudioEngine) -> Bool {
        guard speed.isFinite, speed > 0,
              let next = CreatorLoopGrid.nextBoundary(after: sourceTime, rhythm: rhythm),
              let bpm = CreatorLoopGrid.tempo(rhythm),
              let voice = voices[slot] else { return false }
        let delay = max(0, (next - sourceTime) / Double(speed))
        guard delay < 20 else { return false }
        if active.contains(slot) {
            stopTasks[slot]?.cancel()
            stopTasks[slot] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                voice.node.stop()
                self.active.remove(slot)
                self.stopTasks[slot] = nil
            }
            return true
        }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return false }
        stopTasks[slot]?.cancel()
        // Original four-beat pattern at 120 BPM. TimePitch preserves pitch
        // during rate match; modest harmonic transposition follows cached key.
        voice.pitch.rate = Float(min(1.8, max(0.5, bpm / 120.0 * Double(speed))))
        let chromatic: [MusicalPitchClass] =
            [.c, .cSharp, .d, .dSharp, .e, .f, .fSharp,
             .g, .gSharp, .a, .aSharp, .b]
        let tone = key.flatMap { $0.confidence >= 0.5 ? $0.key : nil }
        if let tone, let position = chromatic.firstIndex(of: tone),
           slot == .subBassline || slot == .synthArp {
            // PCM samples were authored in C; cents shift melodic loops only.
            voice.pitch.pitch = Float((position <= 6 ? position : position - 12) * 100)
        } else { voice.pitch.pitch = 0 }
        voice.node.stop()
        voice.node.scheduleBuffer(voice.buffer, at: nil, options: [.loops])
        let now = mach_absolute_time()
        let deadline = now &+ AVAudioTime.hostTime(forSeconds: delay)
        voice.node.play(at: AVAudioTime(hostTime: deadline))
        active.insert(slot)
        return true
    }

    func stopAll() {
        stopTasks.values.forEach { $0.cancel() }
        stopTasks.removeAll()
        for voice in voices.values { voice.node.stop() }
        active.removeAll()
    }

    /// Generates only once before a user launches a loop; never from the
    /// render callback or a TimelineView. 4 beats at 120 BPM = two seconds.
    private func makeBuffer(_ slot: CreatorLoopSlot) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 2)),
              let a = buffer.floatChannelData else { return nil }
        buffer.frameLength = buffer.frameCapacity
        let n = Int(buffer.frameLength)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let beat = t * 2
            let beatPhase = beat - floor(beat)
            let note = Int(floor(beat * (slot == .synthArp ? 2 : 1))) % 4
            let env = exp(-beatPhase * 12)
            let signal: Double
            switch slot {
            case .breakbeat:
                let kick = sin(2 * .pi * (60 - 25 * beatPhase) * t) * exp(-beatPhase * 17)
                let clap = sin(2 * .pi * 2400 * t) * exp(-beatPhase * 30) *
                    (Int(beat) % 2 == 1 ? 0.45 : 0.05)
                signal = 0.25 * kick + 0.12 * clap
            case .subBassline:
                let freq = [65.406, 77.782, 98.0, 77.782][note]
                signal = 0.24 * sin(2 * .pi * freq * t) * (0.4 + 0.6 * env)
            case .synthArp:
                let freq = [261.63, 311.13, 392.0, 466.16][note]
                signal = 0.13 * (sin(2 * .pi * freq * t) +
                                 0.18 * sin(2 * .pi * freq * 2 * t)) * env
            case .riserTexture:
                signal = 0.075 * sin(2 * .pi * (220 + t * 280) * t) *
                    (0.3 + 0.7 * t / 2) * (0.85 + 0.15 * sin(t * 12))
            }
            let sample = Float(max(-0.4, min(0.4, signal)))
            a[0][i] = sample
            a[1][i] = sample
        }
        return buffer
    }
}
