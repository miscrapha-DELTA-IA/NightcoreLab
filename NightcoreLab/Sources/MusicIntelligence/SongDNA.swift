import Foundation

/// Immutable synthesis of existing MusicIntelligence and MusicExpressionEngine
/// snapshots. Never analyzes audio or changes either cache.
struct SongDNA: Codable, Equatable, Sendable {
    let assetID: String
    let sourceRevision: String
    let sourceDuration: TimeInterval
    /// Zero means unknown; no BPM is invented during background analysis.
    let bpm: Double
    let beatTimestamps: [TimeInterval]
    let energy: Float
    let key: KeyAnalysisResult?
    let mood: MoodHintsResult?
    /// The existing SectionAnalysisResult exposes [MusicSection], not a nested Section type.
    let sections: [MusicSection]

    init(assetID: String, sourceRevision: String, sourceDuration: TimeInterval,
         bpm: Double = 0, beatTimestamps: [TimeInterval] = [],
         energy: Float = 0, key: KeyAnalysisResult? = nil,
         mood: MoodHintsResult? = nil, sections: [MusicSection] = []) {
        self.assetID = assetID
        self.sourceRevision = sourceRevision
        self.sourceDuration = sourceDuration
        self.bpm = bpm
        self.beatTimestamps = beatTimestamps
        self.energy = energy
        self.key = key
        self.mood = mood
        self.sections = sections
    }

    /// O(1) fallback while AnalysisScheduler is still producing evidence.
    static func fallback(for asset: AudioAssetDescriptor) -> SongDNA {
        SongDNA(assetID: asset.assetID, sourceRevision: asset.sourceRevision,
                sourceDuration: asset.duration)
    }

    /// Load from the TWO existing actors; call on a background/coordinator Task,
    /// never from the real-time AVAudioEngine callback.
    static func cached(for asset: AudioAssetDescriptor,
                       musicCache: MusicAnalysisCache,
                       expressionCache: ExpressionCache) async -> SongDNA {
        async let music = musicCache.load(for: asset)
        async let expression = expressionCache.load(
            for: asset,
            requiring: SongCreativeProfileResolver.acceptedExpressionFingerprints)
        return SongDNA.from(asset: asset, analysis: await music,
                            expression: await expression)
    }

    static func from(asset: AudioAssetDescriptor,
                     analysis: MusicAnalysisResult?,
                     expression: MusicExpressionResult?) -> SongDNA {
        let music = analysis?.isValid(for: asset) == true ? analysis : nil
        let expr = expression?.isValid(for: asset) == true ? expression : nil
        let candidateRhythm = music?.capabilities[.rhythm] == .available &&
            music?.rhythmAnalyzerVersion == RhythmAnalysisResult.algorithmVersion
            ? music?.rhythmAnalysis : nil
        let rhythm = candidateRhythm?.quality == .high ||
                     candidateRhythm?.quality == .medium ? candidateRhythm : nil
        let first = rhythm?.bpmCandidates.first
        let bpm = (first?.confidence ?? 0) >= 0.60 ? first?.bpm ?? 0 : 0
        let beats = rhythm?.beatGrid.map(\.time) ?? []
        let points = music?.energyTimeline?.points ?? []
        let energy = points.isEmpty ? 0 :
            Float(points.reduce(0.0) { $0 + $1.features.energy } / Double(points.count))
        func accepted(_ cap: ExpressionCapability, _ provenance: ExpressionProvenance?) -> Bool {
            expr?.capabilities[cap] == .available &&
                provenance?.fingerprint ==
                SongCreativeProfileResolver.acceptedExpressionFingerprints[cap]
        }
        return SongDNA(assetID: asset.assetID, sourceRevision: asset.sourceRevision,
                       sourceDuration: asset.duration, bpm: bpm,
                       beatTimestamps: beats, energy: energy,
                       key: accepted(.key, expr?.key?.provenance) ? expr?.key : nil,
                       mood: accepted(.moodHints, expr?.moodHints?.provenance)
                         ? expr?.moodHints : nil,
                       sections: accepted(.sections, expr?.sections?.provenance)
                         ? (expr?.sections?.sections ?? []) : [])
    }

    /// Human-readable only; never replaces the typed, provenance-checked
    /// harmonic and measured mood evidence.
    var keyName: String? {
        guard let hypothesis = key?.hypotheses.first,
              hypothesis.confidence >= 0.70 else { return nil }
        return hypothesis.tonic.rawValue + " " + hypothesis.scale.rawValue
    }
    var moodName: String? {
        guard let hint = mood?.hints
            .filter({ $0.confidence >= 0.60 })
            .max(by: { $0.confidence < $1.confidence }) else { return nil }
        return hint.dimension.rawValue
    }

    var isValid: Bool {
        guard !assetID.isEmpty, !sourceRevision.isEmpty,
              sourceDuration.isFinite, sourceDuration > 0,
              bpm.isFinite, (bpm == 0 || (55...210).contains(bpm)),
              energy.isFinite, (0...1).contains(energy),
              beatTimestamps.count <= 5_000, sections.count <= 8_192,
              key?.isValid(sourceDuration: sourceDuration) ?? true,
              mood?.isValid(sourceDuration: sourceDuration) ?? true else { return false }
        var previousBeat = -Double.infinity
        for beat in beatTimestamps {
            guard beat.isFinite, beat >= 0, beat <= sourceDuration,
                  beat > previousBeat else { return false }
            previousBeat = beat
        }
        var previousEnd = 0.0
        for section in sections {
            guard section.startTime.isFinite, section.endTime.isFinite,
                  section.startTime >= previousEnd, section.endTime > section.startTime,
                  section.endTime <= sourceDuration, section.confidence.isFinite,
                  (0...1).contains(section.confidence) else { return false }
            previousEnd = section.endTime
        }
        return true
    }

    /// Half-open intervals: deterministic at exact section boundaries.
    /// Confidence below 0.65 and unclassified gaps are neutral.
    func section(at time: TimeInterval) -> MusicSection? {
        // This executes during frame resolution. Validate the whole DNA once
        // on cache ingress, not O(beats + sections) on every rendered frame.
        guard sourceDuration.isFinite, sourceDuration > 0,
              time.isFinite, time >= 0, time < sourceDuration else { return nil }
        var low = 0, high = sections.count
        while low < high {
            let mid = low + (high - low) / 2
            if sections[mid].startTime <= time { low = mid + 1 }
            else { high = mid }
        }
        guard low > 0 else { return nil }
        let item = sections[low - 1]
        return item.startTime.isFinite && item.endTime.isFinite &&
            item.startTime <= time && time < item.endTime &&
            item.confidence.isFinite && item.confidence >= 0.65 &&
            item.confidence <= 1 ? item : nil
    }
}
