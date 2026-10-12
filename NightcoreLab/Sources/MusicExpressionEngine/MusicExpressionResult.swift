import Foundation

/// Immutable, source-identified expression snapshot. Capabilities can be
/// pending or failed independently; no energy/rhythm data is stored here.
struct MusicExpressionResult: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let assetID: String
    let sourceRevision: String
    let sourceDuration: TimeInterval
    let schemaVersion: Int
    let capabilities: [ExpressionCapability: ExpressionCapabilityStatus]
    let key: KeyAnalysisResult?
    let sections: SectionAnalysisResult?
    let melodicFeatures: MelodicFeatures?
    let moodHints: MoodHintsResult?

    init(asset: AudioAssetDescriptor,
         statuses: [ExpressionCapability: ExpressionCapabilityStatus] = [:],
         key: KeyAnalysisResult? = nil,
         sections: SectionAnalysisResult? = nil,
         melodicFeatures: MelodicFeatures? = nil,
         moodHints: MoodHintsResult? = nil) {
        assetID = asset.assetID
        sourceRevision = asset.sourceRevision
        sourceDuration = asset.duration
        schemaVersion = Self.currentSchemaVersion
        var initial = Dictionary(uniqueKeysWithValues:
            ExpressionCapability.allCases.map { ($0, ExpressionCapabilityStatus.notRequested) })
        initial.merge(statuses) { _, new in new }
        capabilities = initial
        self.key = key
        self.sections = sections
        self.melodicFeatures = melodicFeatures
        self.moodHints = moodHints
    }

    var isTerminal: Bool { !capabilities.values.contains(.pending) }

    func isValid(for asset: AudioAssetDescriptor) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              assetID == asset.assetID, sourceRevision == asset.sourceRevision,
              sourceDuration == asset.duration, sourceDuration.isFinite,
              sourceDuration > 0,
              Set(capabilities.keys) == Set(ExpressionCapability.allCases),
              (capabilities[.key] == .available) == (key != nil),
              (capabilities[.sections] == .available) == (sections != nil),
              (capabilities[.melody] == .available) == (melodicFeatures != nil),
              (capabilities[.moodHints] == .available) == (moodHints != nil)
        else { return false }
        return (key?.isValid(sourceDuration: sourceDuration) ?? true) &&
               (sections?.isValid(sourceDuration: sourceDuration) ?? true) &&
               (melodicFeatures?.isValid(sourceDuration: sourceDuration) ?? true) &&
               (moodHints?.isValid(sourceDuration: sourceDuration) ?? true)
    }
}

/// Typed, versioned units persisted independently. This enum is an envelope,
/// not an analyzer and does not infer any features.
enum ExpressionPayload: Codable, Equatable, Sendable {
    case key(KeyAnalysisResult)
    case sections(SectionAnalysisResult)
    case melody(MelodicFeatures)
    case moodHints(MoodHintsResult)

    var capability: ExpressionCapability {
        switch self {
        case .key: return .key
        case .sections: return .sections
        case .melody: return .melody
        case .moodHints: return .moodHints
        }
    }

    var provenance: ExpressionProvenance {
        switch self {
        case .key(let result): return result.provenance
        case .sections(let result): return result.provenance
        case .melody(let result): return result.provenance
        case .moodHints(let result): return result.provenance
        }
    }

    func isValid(sourceDuration: TimeInterval) -> Bool {
        switch self {
        case .key(let result): return result.isValid(sourceDuration: sourceDuration)
        case .sections(let result): return result.isValid(sourceDuration: sourceDuration)
        case .melody(let result): return result.isValid(sourceDuration: sourceDuration)
        case .moodHints(let result): return result.isValid(sourceDuration: sourceDuration)
        }
    }
}
