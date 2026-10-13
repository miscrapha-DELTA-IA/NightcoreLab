import Foundation

/// Local, bounded feedback; none of these fields is sent to telemetry.
struct DiscoveryEvent: Codable, Equatable, Sendable {
    enum SkipReason: String, Codable, Sendable {
        case manualSelection, nextButton, completed, stopped
    }

    let trackID: String
    let timestamp: Date
    let playDuration: TimeInterval
    /// Fraction of source audio actually heard (not seek position). Clamped to [0, 1].
    let completionRatio: Double
    let skipReason: SkipReason?
    let selectedPreset: String?
    let materialID: String?
    let experienceID: String?
    let speed: Double?
    let audioPreset: String?
    let exported: Bool

    init(trackID: String, timestamp: Date = .now, playDuration: TimeInterval,
         completionRatio: Double, skipReason: SkipReason? = nil,
         selectedPreset: String? = nil, materialID: String? = nil,
         experienceID: String? = nil, speed: Double? = nil,
         audioPreset: String? = nil, exported: Bool = false) {
        self.trackID = trackID
        self.timestamp = timestamp
        self.playDuration = playDuration.isFinite ? max(0, playDuration) : 0
        self.completionRatio = completionRatio.isFinite ? min(1, max(0, completionRatio)) : 0
        self.skipReason = skipReason
        self.selectedPreset = selectedPreset
        self.materialID = materialID
        self.experienceID = experienceID
        self.speed = speed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.audioPreset = audioPreset
        self.exported = exported
    }
}

/// Append-only, file-backed actor. Disk I/O is never performed on the main actor.
/// Supports isolated directories for tests and atomic writes after every session/export.
actor DiscoveryEventLog {
    static let eventLimit = 1_000
    static let byteLimit = 1_048_576
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask)[0]
        .appendingPathComponent("NightcoreLab/Discovery", isDirectory: true)

    private let file: URL
    private var cached: [DiscoveryEvent]?

    init(directory: URL = DiscoveryEventLog.defaultDirectory) {
        file = directory.appendingPathComponent("events-v1.json")
    }

    func snapshot() -> [DiscoveryEvent] {
        if let cached { return cached }
        let events = (try? JSONDecoder().decode([DiscoveryEvent].self,
            from: Data(contentsOf: file))) ?? []
        cached = Array(events.suffix(Self.eventLimit))
        return cached ?? []
    }

    func append(_ event: DiscoveryEvent) {
        guard !event.trackID.isEmpty else { return }
        var values = snapshot()
        values.append(event)
        if values.count > Self.eventLimit {
            values.removeFirst(values.count - Self.eventLimit)
        }
        let encoder = JSONEncoder()
        while !values.isEmpty {
            guard let data = try? encoder.encode(values) else { break }
            if data.count <= Self.byteLimit {
                cached = values
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                    var dir = file.deletingLastPathComponent()
                    try? dir.setResourceValue(true, forKey: .isExcludedFromBackupKey)
                } catch {
                    // The log is best effort. Never interrupt audio or export on an I/O failure.
                }
                return
            }
            values.removeFirst()
        }
        cached = []
    }

    func clear() {
        cached = []
        try? FileManager.default.removeItem(at: file)
    }
}

/// Event-driven listening intervals use a monotonic system clock: no playback polling.
/// Pauses and seek gaps cannot inflate a listen; speed determines source exposure.
@MainActor
final class DiscoveryPlaybackTracker {
    private struct Active {
        let id: String
        let duration: Double?
        var heard: Double = 0
        var sourceHeard: Double = 0
        var since: TimeInterval?
        var speed: Double
        var completed = false
    }
    private var active: Active?

    func start(_ trackID: String, duration: Double?, speed: Double,
               uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        active = Active(id: trackID,
                        duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                        since: uptime, speed: Self.safeSpeed(speed))
    }

    func playbackChanged(isPlaying: Bool, speed: Double,
                         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard var value = active else { return }
        flush(&value, uptime: uptime)
        value.speed = Self.safeSpeed(speed)
        value.since = isPlaying ? uptime : nil
        active = value
    }

    func contextChanged(speed: Double,
                        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard var value = active else { return }
        flush(&value, uptime: uptime)
        value.speed = Self.safeSpeed(speed)
        active = value
    }

    func finish(reason: DiscoveryEvent.SkipReason?, selectedPreset: String?,
                materialID: String?, experienceID: String?,
                audioPreset: String?, exported: Bool = false,
                uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                at date: Date = .now) -> DiscoveryEvent? {
        guard var value = active else { return nil }
        flush(&value, uptime: uptime)
        if reason == .completed { value.completed = true }
        let ratio = value.completed ? 1 : value.sourceHeard / max(value.duration ?? .infinity, 1)
        let event = DiscoveryEvent(trackID: value.id, timestamp: date,
            playDuration: value.heard, completionRatio: ratio,
            skipReason: reason, selectedPreset: selectedPreset,
            materialID: materialID, experienceID: experienceID,
            speed: value.speed, audioPreset: audioPreset, exported: exported)
        if !exported { active = nil } else { active = value }
        return event
    }

    private func flush(_ value: inout Active, uptime: TimeInterval) {
        guard let from = value.since, uptime.isFinite, from.isFinite else { return }
        let delta = min(86_400, max(0, uptime - from))
        value.heard += delta
        value.sourceHeard += delta * value.speed
        value.since = uptime
    }

    private static func safeSpeed(_ speed: Double) -> Double {
        speed.isFinite ? min(2, max(0.5, speed)) : 1
    }
}

/// Small vector with explicit missing capabilities, never zero-filled audio signals.
struct DiscoveryFeatureVector: Codable, Equatable, Sendable {
    let bpm: Double?
    let energy: Double?
    let rhythmDensity: Double?
    let spectralBrightness: Double?
    let rhythmConfidence: Double?
    let sourceRevision: String?

    init(bpm: Double? = nil, energy: Double? = nil,
         rhythmDensity: Double? = nil, spectralBrightness: Double? = nil,
         rhythmConfidence: Double? = nil, sourceRevision: String? = nil) {
        self.bpm = bpm.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.energy = Self.unit(energy)
        self.rhythmDensity = Self.unit(rhythmDensity)
        self.spectralBrightness = Self.unit(spectralBrightness)
        self.rhythmConfidence = Self.unit(rhythmConfidence)
        self.sourceRevision = sourceRevision
    }

    private static func unit(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
    }

    init(analysis: MusicAnalysisResult) {
        let points = analysis.capabilities[.energy] == .available
            ? (analysis.energyTimeline?.points ?? []) : []
        let energy = points.isEmpty ? nil :
            points.reduce(0.0) { $0 + $1.features.energy } / Double(points.count)
        let brightness = points.isEmpty ? nil :
            points.reduce(0.0) { $0 + $1.features.treble } / Double(points.count)
        let duration = analysis.coverage.analyzedThrough
        let onsetCount = analysis.capabilities[.onsets] == .available
            ? analysis.onsetEvents?.count : nil
        let density = onsetCount.flatMap { duration > 0 ? min(1, Double($0) / duration / 4) : nil }
        let rhythm = analysis.capabilities[.rhythm] == .available ? analysis.rhythmAnalysis : nil
        let strongest = rhythm?.bpmCandidates.first
        let reliable = (rhythm?.confidence ?? 0) >= 0.5 &&
            (strongest?.confidence ?? 0) >= 0.5
        self.init(bpm: reliable ? strongest?.bpm : nil, energy: energy,
                  rhythmDensity: density, spectralBrightness: brightness,
                  rhythmConfidence: rhythm.map { Double($0.confidence) },
                  sourceRevision: analysis.sourceRevision)
    }

    /// Octave-invariant tempo and optional normalized acoustic dimensions.
    /// Nil means there are NO comparable observations; it is not a mismatch.
    func similarity(to other: Self) -> Double? {
        var sum = 0.0, weight = 0.0
        if let lhs = bpm, let rhs = other.bpm {
            let ratios = [lhs / rhs, lhs / (rhs * 2), lhs * 2 / rhs]
            let difference = ratios.map { abs(log2($0)) }.min() ?? 1
            sum += max(0, 1 - difference / 0.25) * 0.4; weight += 0.4
        }
        for (lhs, rhs, importance) in [
            (energy, other.energy, 0.35),
            (rhythmDensity, other.rhythmDensity, 0.15),
            (spectralBrightness, other.spectralBrightness, 0.10)
        ] {
            if let lhs, let rhs {
                sum += max(0, 1 - abs(lhs - rhs)) * importance
                weight += importance
            }
        }
        return weight > 0 ? sum / weight : nil
    }
}

struct MusicFeatureProfile {
    let trackID: String
    let textual: TrackFeatures
    let acoustic: DiscoveryFeatureVector?
    init(track: Track, acoustic: DiscoveryFeatureVector? = nil) {
        trackID = track.id
        textual = TrackFeatures(track: track)
        self.acoustic = acoustic
    }
}

struct MusicDiscoveryFeatures {
    let profile: MusicFeatureProfile
    let creativeEvents: [DiscoveryEvent]
}

/// A snapshot is provided only when ranking an incoming batch; no realtime worker.
struct DiscoverySnapshot {
    let events: [DiscoveryEvent]
    let vectors: [String: DiscoveryFeatureVector]
    let currentID: String
    let materialID: String?
    let presetID: String?
    static let empty = Self(events: [], vectors: [:], currentID: "",
                            materialID: nil, presetID: nil)
}

enum DiscoveryScoring {
    struct Contribution {
        let acoustic: Double
        let creative: Double
        let history: Double
        let explanation: String?
        var total: Double { acoustic + creative + history }
    }

    static func contribution(for candidate: RecCandidate, profile: UserTasteProfile,
                             context: RecContext, snapshot: DiscoverySnapshot) -> Contribution {
        let similarity = snapshot.vectors[snapshot.currentID]
            .flatMap { current in snapshot.vectors[candidate.track.id].flatMap { current.similarity(to: $0) } }
        // No feature value contributes until available at both ends.
        let acoustic = (similarity ?? 0) * 0.12
        let priorEvents = snapshot.events.filter { $0.trackID == candidate.track.id ||
            (profile.featuresByID[$0.trackID].map {
                !$0.artists.isDisjoint(with: candidate.features.artists)
                && $0.artistIsReliable && candidate.features.artistIsReliable
            } ?? false) }
        let relevant = priorEvents.filter { !$0.exported && $0.playDuration > 0 }
        let positive = relevant.filter { $0.completionRatio >= 0.5 }
        let negative = relevant.filter { $0.skipReason == .manualSelection && $0.completionRatio < 0.15 }
        let history = min(0.08, Double(positive.count) * 0.025) -
                      min(0.08, Double(negative.count) * 0.04)
        let creativeMatches = positive.filter {
            abs(($0.speed ?? 1) - Double(context.speed)) < 0.12 &&
            (snapshot.materialID == nil || $0.materialID == snapshot.materialID) &&
            (snapshot.presetID == nil || $0.selectedPreset == snapshot.presetID)
        }
        let creative = min(0.16, Double(creativeMatches.count) * 0.08)
        let explanation: String?
        if creative > 0, let event = creativeMatches.last {
            let rate = String(format: "%.2f", event.speed ?? 1)
            let material = event.materialID.map { " + " + $0 } ?? ""
            explanation = "Combina com suas músicas em " + rate + "x" + material
        } else if acoustic > 0 {
            explanation = "Ritmo e energia semelhantes à faixa atual"
        } else if history > 0 {
            explanation = "Relacionado ao seu histórico de escuta"
        } else {
            explanation = nil
        }
        return Contribution(acoustic: acoustic, creative: creative,
                            history: history, explanation: explanation)
    }
}

/// Deterministic queue policy. Must be invoked only on committed skips,
/// never during progress callbacks, and only for existing queued tracks.
enum DiscoveryQueuePolicy {
    static func afterSkip(_ queue: [Track], anchor: Track?,
                          vectors: [String: DiscoveryFeatureVector],
                          recentlyPlayed: Set<String> = []) -> [Track] {
        guard queue.count > 1, let anchor, let initial = vectors[anchor.id],
              queue.contains(where: { vectors[$0.id] != nil }) else { return queue }
        var remaining = queue.enumerated().map { ($0.offset, $0.element) }
        var result: [Track] = []
        var prior = anchor
        var priorVector = initial
        while !remaining.isEmpty {
            let best = remaining.indices.min { a, b in
                func cost(_ index: Int) -> Double {
                    let item = remaining[index].1
                    let vector = vectors[item.id]
                    let proximity = vector.flatMap { priorVector.similarity(to: $0) } ?? 0.5
                    let repeatedArtist = TrackFeatures(track: prior).primaryArtist
                        .flatMap { $0 == TrackFeatures(track: item).primaryArtist ? 0.6 : 0 } ?? 0
                    let recent = recentlyPlayed.contains(item.id) ? 0.8 : 0
                    return 1 - proximity + repeatedArtist + recent
                }
                let lhs = cost(a), rhs = cost(b)
                return lhs == rhs ? remaining[a].0 < remaining[b].0 : lhs < rhs
            }!
            let next = remaining.remove(at: best).1
            result.append(next)
            prior = next
            if let vector = vectors[next.id] { priorVector = vector }
        }
        return result
    }
}
