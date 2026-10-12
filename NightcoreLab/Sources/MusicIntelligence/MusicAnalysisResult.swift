import Foundation

/// Immutable source-time snapshots. Energy/onset schema v1 stays readable when
/// independently versioned rhythm intelligence is added or upgraded.
struct MusicAnalysisResult: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    /// Existing energy/FFT/onset algorithm: do not bump for rhythm-only changes.
    static let currentAnalyzerVersion = 1

    enum Capability: String, Codable, CaseIterable, Sendable {
        case energy, onsets, rhythm
    }

    enum CapabilityStatus: Codable, Equatable, Sendable {
        case notRequested
        case pending
        case available
        case failed(String)
    }

    struct Coverage: Codable, Equatable, Sendable {
        let sourceDuration: TimeInterval
        let analyzedThrough: TimeInterval
        var isComplete: Bool { analyzedThrough >= sourceDuration }
    }

    let assetID: String
    let sourceRevision: String
    let schemaVersion: Int
    let analyzerVersion: Int
    let capabilities: [Capability: CapabilityStatus]
    let energyTimeline: AudioFeatureTimeline?
    /// Foundation onset heuristic; not a BPM grid.
    let onsetEvents: [TimeInterval]?
    /// Independent tempo candidates and predicted beat markers.
    let rhythmAnalysis: RhythmAnalysisResult?
    let rhythmAnalyzerVersion: Int
    let coverage: Coverage

    init(asset: AudioAssetDescriptor,
         energy: CapabilityStatus = .pending,
         onsets: CapabilityStatus = .pending,
         timeline: AudioFeatureTimeline? = nil,
         onsetEvents: [TimeInterval]? = nil,
         rhythm: CapabilityStatus = .notRequested,
         rhythmAnalysis: RhythmAnalysisResult? = nil,
         rhythmAnalyzerVersion: Int = RhythmAnalysisResult.algorithmVersion) {
        assetID = asset.assetID
        sourceRevision = asset.sourceRevision
        schemaVersion = Self.currentSchemaVersion
        analyzerVersion = Self.currentAnalyzerVersion
        capabilities = [.energy: energy, .onsets: onsets, .rhythm: rhythm]
        energyTimeline = timeline
        self.onsetEvents = onsetEvents
        self.rhythmAnalysis = rhythmAnalysis
        self.rhythmAnalyzerVersion = rhythmAnalyzerVersion
        coverage = Coverage(sourceDuration: asset.duration,
                            analyzedThrough: timeline?.duration ?? 0)
    }

    var isTerminal: Bool { !capabilities.values.contains(.pending) }

    /// Discard a stale rhythm derivation without losing the decoded FFT timeline.
    func droppingRhythm() -> MusicAnalysisResult {
        MusicAnalysisResult(copying: self, rhythmStatus: .notRequested)
    }

    private init(copying source: MusicAnalysisResult, rhythmStatus: CapabilityStatus) {
        assetID = source.assetID
        sourceRevision = source.sourceRevision
        schemaVersion = source.schemaVersion
        analyzerVersion = source.analyzerVersion
        var statuses = source.capabilities
        statuses[.rhythm] = rhythmStatus
        capabilities = statuses
        energyTimeline = source.energyTimeline
        onsetEvents = source.onsetEvents
        rhythmAnalysis = nil
        rhythmAnalyzerVersion = RhythmAnalysisResult.algorithmVersion
        coverage = source.coverage
    }

    private enum CodingKeys: String, CodingKey {
        case assetID, sourceRevision, schemaVersion, analyzerVersion, capabilities
        case energyTimeline, onsetEvents, rhythmAnalysis, rhythmAnalyzerVersion, coverage
    }

    /// Foundation caches predate the rhythm keys. No migration, re-FFT or
    /// schema-wide invalidation is required: missing rhythm = notRequested.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        assetID = try container.decode(String.self, forKey: .assetID)
        sourceRevision = try container.decode(String.self, forKey: .sourceRevision)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        analyzerVersion = try container.decode(Int.self, forKey: .analyzerVersion)
        var statuses = try container.decode([Capability: CapabilityStatus].self,
                                            forKey: .capabilities)
        if statuses[.rhythm] == nil { statuses[.rhythm] = .notRequested }
        capabilities = statuses
        energyTimeline = try container.decodeIfPresent(AudioFeatureTimeline.self,
                                                       forKey: .energyTimeline)
        onsetEvents = try container.decodeIfPresent([TimeInterval].self, forKey: .onsetEvents)
        rhythmAnalysis = try container.decodeIfPresent(RhythmAnalysisResult.self,
                                                       forKey: .rhythmAnalysis)
        rhythmAnalyzerVersion = try container.decodeIfPresent(Int.self,
                                                               forKey: .rhythmAnalyzerVersion) ?? 0
        coverage = try container.decode(Coverage.self, forKey: .coverage)
    }

    /// Reject corrupted persisted values and mismatched source identity.
    func isValid(for asset: AudioAssetDescriptor) -> Bool {
        guard assetID == asset.assetID, sourceRevision == asset.sourceRevision,
              schemaVersion == Self.currentSchemaVersion,
              analyzerVersion == Self.currentAnalyzerVersion,
              Set(capabilities.keys) == Set(Capability.allCases),
              coverage.sourceDuration == asset.duration,
              coverage.analyzedThrough.isFinite,
              coverage.analyzedThrough >= 0,
              coverage.analyzedThrough <= asset.duration + 0.000_001,
              coverage.analyzedThrough <= AudioFeatureAnalyzer.maxAnalysisSeconds + 0.000_001,
              (capabilities[.energy] == .available) == (energyTimeline != nil),
              (capabilities[.onsets] == .available) == (onsetEvents != nil),
              (capabilities[.rhythm] == .available) == (rhythmAnalysis != nil)
        else { return false }
        if let timeline = energyTimeline {
            guard timeline.duration == coverage.analyzedThrough,
                  !timeline.points.isEmpty else { return false }
            var previous = -Double.infinity
            for point in timeline.points {
                guard point.time.isFinite, point.time >= 0,
                      point.time > previous, point.time <= timeline.duration else { return false }
                previous = point.time
            }
        } else if coverage.analyzedThrough != 0 { return false }
        if let events = onsetEvents {
            guard energyTimeline != nil else { return false }
            var previous = -Double.infinity
            for time in events {
                guard time.isFinite, time >= 0, time > previous,
                      time <= coverage.analyzedThrough else { return false }
                previous = time
            }
        }
        if let rhythmAnalysis {
            guard energyTimeline != nil,
                  rhythmAnalyzerVersion == rhythmAnalysis.algorithmVersion,
                  rhythmAnalysis.isValid(through: coverage.analyzedThrough) else { return false }
        }
        return true
    }
}
