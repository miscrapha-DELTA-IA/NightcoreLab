import Foundation

/// Immutable snapshots. All times are seconds in the ORIGINAL audio file,
/// never wall-clock, player-rate-adjusted, or export-relative timestamps.
struct MusicAnalysisResult: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    // Bump whenever FFT, energy normalization, onset rules or coverage change.
    static let currentAnalyzerVersion = 1

    enum Capability: String, Codable, CaseIterable, Sendable {
        case energy, onsets
    }

    enum CapabilityStatus: Codable, Equatable, Sendable {
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
    /// Preserves the existing FFT bands as well as energy for Creative consumers.
    let energyTimeline: AudioFeatureTimeline?
    /// Energy-rise events from the existing detector; these are NOT a beat grid/BPM.
    let onsetEvents: [TimeInterval]?
    let coverage: Coverage

    init(asset: AudioAssetDescriptor,
         energy: CapabilityStatus = .pending,
         onsets: CapabilityStatus = .pending,
         timeline: AudioFeatureTimeline? = nil,
         onsetEvents: [TimeInterval]? = nil) {
        assetID = asset.assetID
        sourceRevision = asset.sourceRevision
        schemaVersion = Self.currentSchemaVersion
        analyzerVersion = Self.currentAnalyzerVersion
        capabilities = [.energy: energy, .onsets: onsets]
        energyTimeline = timeline
        self.onsetEvents = onsetEvents
        coverage = Coverage(sourceDuration: asset.duration,
                            analyzedThrough: timeline?.duration ?? 0)
    }

    var isTerminal: Bool { !capabilities.values.contains(.pending) }

    /// Cache files are disposable input: reject mismatched or malformed payloads.
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
              (capabilities[.onsets] == .available) == (onsetEvents != nil) else { return false }
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
        return true
    }
}
