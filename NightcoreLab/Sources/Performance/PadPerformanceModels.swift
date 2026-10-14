import Foundation
import Observation

/// Rights-clear, deterministic samples synthesized inside the application.
/// No copyrighted audio is bundled, downloaded or copied into these pads.
struct SampleDescriptor: Codable, Equatable, Sendable, Identifiable {
    enum Category: String, Codable, Sendable { case drum, cymbal, bass, sample }
    let id: String
    let name: String
    let category: Category
    /// An internal, generated asset identity (not a disk path or URL).
    let asset: String
    let license: String
    let duration: TimeInterval
    let gain: Float
    let defaultVelocity: Float
    let loop: Bool
    let chokeGroup: String?
}

struct PadKit: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let samples: [SampleDescriptor]

    var isValid: Bool {
        !samples.isEmpty && Set(samples.map(\.id)).count == samples.count &&
            samples.allSatisfy {
                $0.duration > 0 && $0.duration <= 5 &&
                $0.gain.isFinite && (0...1).contains($0.gain) &&
                $0.defaultVelocity.isFinite && (0...1).contains($0.defaultVelocity) &&
                ($0.asset.hasPrefix("nightcore.original.") ||
                 ($0.id == PerformanceSourceClip.slotID &&
                  $0.asset == "nightcore.source-clip.v1"))
            }
    }

    static let starter: PadKit = {
        let license = "Original synthesized waveform by NightcoreLab; no external recordings"
        let entries: [(String, String, SampleDescriptor.Category, Double, Float, String?)] = [
            ("kick", "KICK", .drum, 0.46, 0.75, nil),
            ("snare", "SNARE", .drum, 0.28, 0.50, nil),
            ("closed-hat", "CLOSED HAT", .cymbal, 0.12, 0.36, "hat"),
            ("open-hat", "OPEN HAT", .cymbal, 0.54, 0.36, "hat"),
            ("clap", "CLAP", .drum, 0.33, 0.43, nil),
            ("crash", "CRASH", .cymbal, 1.10, 0.30, nil),
            ("808", "808", .bass, 1.30, 0.52, nil)
        ]
        return PadKit(id: "nightcore-original-drums-v1", name: "Nightcore Originals",
                      samples: entries.map { item in
            SampleDescriptor(id: item.0, name: item.1, category: item.2,
                             asset: "nightcore.original.\(item.0).v1",
                             license: license, duration: item.3, gain: item.4,
                             defaultVelocity: 0.85, loop: false, chokeGroup: item.5)
        })
    }()
}

/// A musical intent, not an AVFoundation node or a UI gesture.
/// Timestamp = monotonic seconds since capture began; sourceTime is optional
/// and always uses the existing AVAudioEngine source clock when available.
struct PadEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let padId: String
    let timestamp: TimeInterval
    let velocity: Float
    let duration: TimeInterval
    let sourceTime: TimeInterval?
}

struct PerformanceTimeline: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let version: Int
    let kitID: String
    let events: [PadEvent]
    /// Optional v1 additive field, absent from older event-only recordings.
    /// No file path or original waveform is serialized.
    let sourceClip: PerformanceSourceClip?

    init(kitID: String, events: [PadEvent],
         sourceClip: PerformanceSourceClip? = nil) {
        version = Self.schemaVersion
        self.kitID = kitID
        self.sourceClip = sourceClip
        self.events = events.sorted {
            $0.timestamp == $1.timestamp
                ? $0.id.uuidString < $1.id.uuidString
                : $0.timestamp < $1.timestamp
        }
    }

    var isValid: Bool {
        version == Self.schemaVersion &&
        (sourceClip?.isValid ?? true) &&
        events.count <= 4096 &&
        events.allSatisfy {
            $0.timestamp.isFinite && $0.timestamp >= 0 &&
            $0.velocity.isFinite && (0...1).contains($0.velocity) &&
            $0.duration.isFinite && $0.duration > 0 &&
            ($0.sourceTime == nil || ($0.sourceTime!.isFinite && $0.sourceTime! >= 0))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, kitID, events, sourceClip
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        kitID = try c.decode(String.self, forKey: .kitID)
        sourceClip = try c.decodeIfPresent(PerformanceSourceClip.self, forKey: .sourceClip)
        events = try c.decode([PadEvent].self, forKey: .events)
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                forKey: .events, in: c,
                debugDescription: "Invalid PerformanceTimeline payload")
        }
    }
}

/// Stable, finite-size event capture. No microphone, analytics or file IO.
@MainActor
@Observable
final class PerformanceRecorder {
    private(set) var isRecording = false
    private(set) var events: [PadEvent] = []
    private var startUptime: TimeInterval = 0

    func start(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        events.removeAll(keepingCapacity: true)
        startUptime = uptime
        isRecording = true
    }

    func stop() { isRecording = false }

    func append(_ sample: SampleDescriptor, velocity: Float, sourceTime: TimeInterval?,
                at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard isRecording, events.count < 4096, uptime.isFinite,
              uptime >= startUptime else { return }
        let velocity = min(max(velocity, 0), 1)
        guard velocity.isFinite else { return }
        events.append(PadEvent(id: UUID(), padId: sample.id,
                               timestamp: uptime - startUptime, velocity: velocity,
                               duration: sample.duration, sourceTime: sourceTime))
    }

    func timeline(kit: PadKit = .starter,
                  sourceClip: PerformanceSourceClip? = nil) -> PerformanceTimeline {
        PerformanceTimeline(kitID: kit.id, events: events, sourceClip: sourceClip)
    }

    func shareJSON(kit: PadKit = .starter,
                   sourceClip: PerformanceSourceClip? = nil) -> String? {
        let timeline = timeline(kit: kit, sourceClip: sourceClip)
        guard timeline.isValid,
              let data = try? JSONEncoder().encode(timeline) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Pure voice allocation rule, independent from CoreAudio timing.
/// Oldest active voice is stolen only after free or expired voices run out.
/// A new closed/open hat stops other voices in the same choke group.
struct PadVoiceAllocator {
    struct Lease: Equatable {
        var id: String?
        var chokeGroup: String?
        var began: TimeInterval = 0
        var expires: TimeInterval = 0
    }

    struct InterruptedLease: Equatable {
        let voiceIndex: Int
        let previous: Lease
    }

    struct Selection: Equatable {
        let voiceIndex: Int
        let chokeIndices: [Int]
        let stoleVoice: Bool
        /// Snapshot of interrupted voices before assigning/releasing leases.
        /// Used for short-release tails rather than cutting PCM at full level.
        let interrupted: [InterruptedLease]
    }

    private(set) var leases: [Lease]
    /// Pick each next free voice circularly instead of hammering voice zero.
    private var nextVoiceIndex = 0

    init(capacity: Int = 12) {
        leases = Array(repeating: Lease(), count: max(1, capacity))
    }

    mutating func allocate(id: String, chokeGroup: String?, duration: TimeInterval,
                           at uptime: TimeInterval) -> Selection? {
        guard uptime.isFinite, duration.isFinite, duration > 0 else { return nil }
        let chokes = leases.indices.filter {
            guard let chokeGroup else { return false }
            return leases[$0].chokeGroup == chokeGroup &&
                leases[$0].id != nil && leases[$0].expires > uptime
        }
        let available = (0..<leases.count).first { offset in
            let index = (nextVoiceIndex + offset) % leases.count
            return leases[index].id == nil || leases[index].expires <= uptime
        }.map { (nextVoiceIndex + $0) % leases.count }
        let index = available ?? chokes.first ?? leases.indices.min(by: {
            leases[$0].began < leases[$1].began
        })!
        nextVoiceIndex = (index + 1) % leases.count
        let stolen = leases[index].id != nil && leases[index].expires > uptime
        let interruptedIndices = chokes.filter { $0 != index } + (stolen ? [index] : [])
        let interrupted = interruptedIndices.map {
            InterruptedLease(voiceIndex: $0, previous: leases[$0])
        }
        leases[index] = Lease(id: id, chokeGroup: chokeGroup,
                              began: uptime, expires: uptime + duration)
        chokes.filter { $0 != index }.forEach { leases[$0] = Lease() }
        return Selection(voiceIndex: index,
                         chokeIndices: chokes.filter { $0 != index },
                         stoleVoice: stolen, interrupted: interrupted)
    }

    mutating func reset() {
        leases = Array(repeating: Lease(), count: leases.count)
        nextVoiceIndex = 0
    }
}
