import AVFoundation
import Foundation

enum VocalFXPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case studioClean = "Studio Clean"
    case nightcore = "Nightcore Vocal"
    case cyberChoir = "Cyber Choir"
    case dreamCloud = "Dream Cloud"
    var id: String { rawValue }
}

/// Exactly one normalized macro drives existing native DSP units.
struct VocalFXSetting: Codable, Equatable, Sendable {
    var preset: VocalFXPreset = .studioClean
    var intensity: Float = 0.5
    var isValid: Bool { intensity.isFinite && (0...1).contains(intensity) }
}

struct VocalFXParameters: Equatable, Sendable {
    let pitchCents: Float
    let eqPresenceDB: Float
    let lowPassHz: Float
    let delaySeconds: TimeInterval
    let delayWetMix: Float
    let reverbWetMix: Float
    let reverbPreset: AVAudioUnitReverbPreset

    static func resolve(_ settings: VocalFXSetting) -> Self {
        let amount = settings.intensity.isFinite ?
            min(1, max(0, settings.intensity)) : 0
        switch settings.preset {
        case .studioClean:
            return Self(pitchCents: 0, eqPresenceDB: 2.8 * amount,
                        lowPassHz: 18_000, delaySeconds: 0.06,
                        delayWetMix: 0, reverbWetMix: 8 * amount,
                        reverbPreset: .smallRoom)
        case .nightcore:
            return Self(pitchCents: 220 * amount,
                        eqPresenceDB: 5 * amount, lowPassHz: 18_000,
                        delaySeconds: 0.11, delayWetMix: 11 * amount,
                        reverbWetMix: 10 * amount, reverbPreset: .mediumRoom)
        case .cyberChoir:
            return Self(pitchCents: 14 * amount,
                        eqPresenceDB: 3 * amount, lowPassHz: 14_000,
                        delaySeconds: 0.025, delayWetMix: 35 * amount,
                        reverbWetMix: 46 * amount, reverbPreset: .largeHall)
        case .dreamCloud:
            return Self(pitchCents: -85 * amount,
                        eqPresenceDB: -2 * amount,
                        lowPassHz: 18_000 - 12_000 * amount,
                        delaySeconds: 0.23, delayWetMix: 12 * amount,
                        reverbWetMix: 62 * amount, reverbPreset: .largeHall)
        }
    }
}

/// Conservative acoustic safety; visual capture and karaoke scoring remain
/// available when monitoring is muted.
enum VocalMonitorSafety {
    static func allows(_ outputs: [AVAudioSessionPortDescription],
                       latency: TimeInterval) -> Bool {
        guard latency.isFinite, latency >= 0, latency <= 0.040,
              !outputs.isEmpty else { return false }
        return allows(portTypes: outputs.map(\.portType), latency: latency)
    }

    static func allows(portTypes: [AVAudioSession.Port],
                       latency: TimeInterval) -> Bool {
        guard latency.isFinite, latency >= 0, latency <= 0.040,
              !portTypes.isEmpty else { return false }
        return portTypes.allSatisfy {
            switch $0 {
            case .headphones, .headsetMic, .usbAudio:
                return true
            default:
                return false // Speaker, receivers, Bluetooth/A2DP, AirPlay
            }
        }
    }
}
