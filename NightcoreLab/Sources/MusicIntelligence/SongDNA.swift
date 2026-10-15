import Foundation

/// Immutable synthesis of existing MusicIntelligence and MusicExpressionEngine
/// snapshots. Never analyzes audio or changes either cache.
struct SongDNA: Codable, Equatable, Sendable {
    static let schemaVersion = 2
    let schemaVersion: Int
    let assetID: String
    let sourceRevision: String
    let sourceDuration: TimeInterval
    /// Zero means unknown; no BPM is invented during background analysis.
    let bpm: Double
    let beatTimestamps: [TimeInterval]
    let barTimestamps: [TimeInterval]
    let lyricSyllablesPerSecond: Double
    let lyricSyllablesPerBeat: Double
    let energy: Float
    let key: KeyAnalysisResult?
    let mood: MoodHintsResult?
    /// The existing SectionAnalysisResult exposes [MusicSection], not a nested Section type.
    let sections: [MusicSection]

    init(assetID: String, sourceRevision: String, sourceDuration: TimeInterval,
         bpm: Double = 0, beatTimestamps: [TimeInterval] = [],
         barTimestamps: [TimeInterval] = [],
         lyricSyllablesPerSecond: Double = 0, lyricSyllablesPerBeat: Double = 0,
         energy: Float = 0, key: KeyAnalysisResult? = nil,
         mood: MoodHintsResult? = nil, sections: [MusicSection] = []) {
        self.schemaVersion = Self.schemaVersion
        self.assetID = assetID
        self.sourceRevision = sourceRevision
        self.sourceDuration = sourceDuration
        self.bpm = bpm
        self.beatTimestamps = beatTimestamps
        self.barTimestamps = barTimestamps
        self.lyricSyllablesPerSecond = lyricSyllablesPerSecond
        self.lyricSyllablesPerBeat = lyricSyllablesPerBeat
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
                     expression: MusicExpressionResult?,
                     lyrics: [TimedLyricLine] = []) -> SongDNA {
        let music = analysis?.isValid(for: asset) == true ? analysis : nil
        let expr = expression?.isValid(for: asset) == true ? expression : nil
        let candidateRhythm = music?.capabilities[.rhythm] == .available &&
            music?.rhythmAnalyzerVersion == RhythmAnalysisResult.algorithmVersion
            ? music?.rhythmAnalysis : nil
        let rhythm = candidateRhythm?.quality == .high ||
                     candidateRhythm?.quality == .medium ? candidateRhythm : nil
        let bpm = rhythm.map { Self.resolveOctave($0.bpmCandidates, lyrics: lyrics) } ?? 0
        let beats = rhythm?.beatGrid.map(\.time) ?? []
        let bars = rhythm.map(Self.barGrid) ?? []
        let density = Self.lyricDensity(lyrics, bpm: bpm)
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
                       beatTimestamps: beats, barTimestamps: bars,
                       lyricSyllablesPerSecond: density.perSecond,
                       lyricSyllablesPerBeat: density.perBeat, energy: energy,
                       key: accepted(.key, expr?.key?.provenance) ? expr?.key : nil,
                       mood: accepted(.moodHints, expr?.moodHints?.provenance)
                         ? expr?.moodHints : nil,
                       sections: Self.refineChorus(
                        accepted(.sections, expr?.sections?.provenance)
                            ? (expr?.sections?.sections ?? []) : [], lyrics: lyrics))
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

    /// A faster octave wins when its autocorrelation support reaches 80% of
    /// the slower hypothesis. Lyric density is a tie breaker near that edge.
    static func resolveOctave(_ candidates: [RhythmAnalysisResult.BPMCandidate],
                              lyrics: [TimedLyricLine] = []) -> Double {
        guard let primary = candidates.first, primary.confidence >= 0.60 else { return 0 }
        let slower = candidates.filter { (70...180).contains($0.bpm) }
            .min { $0.bpm < $1.bpm }
        guard let slower else { return primary.bpm }
        let faster = candidates.first { abs($0.bpm - slower.bpm * 2) < 3 }
        guard let faster else { return primary.bpm }
        let ratio = Double(faster.confidence) / max(0.0001, Double(slower.confidence))
        let syllables = lyricDensity(lyrics, bpm: faster.bpm).perBeat
        return ratio >= 0.8 || (ratio >= 0.75 && syllables >= 0.5)
            ? faster.bpm : slower.bpm
    }

    static func barGrid(_ rhythm: RhythmAnalysisResult) -> [TimeInterval] {
        let beats = rhythm.beatGrid
        guard beats.count >= 4 else { return [] }
        let phase = beats.first(where: \.isDownbeat).map { $0.index % 4 } ?? (0..<4).max { left, right in
            stride(from: left, to: beats.count, by: 4).reduce(0.0) { $0 + Double(beats[$1].strength) } <
            stride(from: right, to: beats.count, by: 4).reduce(0.0) { $0 + Double(beats[$1].strength) }
        } ?? 0
        return stride(from: phase, to: beats.count, by: 4).map { index in
            let time = beats[index].time
            return rhythm.onsetEvents.min { abs($0 - time) < abs($1 - time) }
                .flatMap { abs($0 - time) <= 0.03 ? $0 : nil } ?? time
        }
    }

    static func lyricDensity(_ lyrics: [TimedLyricLine], bpm: Double)
        -> (perSecond: Double, perBeat: Double) {
        let duration = lyrics.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        guard duration > 0 else { return (0, 0) }
        let syllables = lyrics.flatMap(\.words).reduce(0) {
            $0 + LyricsAlignmentRefiner.syllableWeight($1.text)
        }
        let perSecond = Double(syllables) / duration
        return (perSecond, bpm > 0 ? perSecond * 60 / bpm : 0)
    }

    static func refineChorus(_ sections: [MusicSection],
                             lyrics: [TimedLyricLine]) -> [MusicSection] {
        let normalized = lyrics.map { line in
            line.text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var counts: [String: Int] = [:]
        for text in normalized where !text.isEmpty { counts[text, default: 0] += 1 }
        return sections.map { section in
            guard section.label == .chorus || section.label == .unknown else { return section }
            let repeated = lyrics.indices.contains { index in
                let line = lyrics[index]
                return line.start < section.endTime && line.end > section.startTime &&
                    counts[normalized[index], default: 0] >= 2
            }
            guard repeated else { return section }
            return MusicSection(startTime: section.startTime, endTime: section.endTime,
                                label: .chorus,
                                confidence: max(section.confidence, 0.77))
        }
    }

    func applyingLyrics(_ lyrics: [TimedLyricLine]) -> SongDNA {
        let density = Self.lyricDensity(lyrics, bpm: bpm)
        return SongDNA(assetID: assetID, sourceRevision: sourceRevision,
                       sourceDuration: sourceDuration, bpm: bpm,
                       beatTimestamps: beatTimestamps, barTimestamps: barTimestamps,
                       lyricSyllablesPerSecond: density.perSecond,
                       lyricSyllablesPerBeat: density.perBeat, energy: energy,
                       key: key, mood: mood,
                       sections: Self.refineChorus(sections, lyrics: lyrics))
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, assetID, sourceRevision, sourceDuration, bpm
        case beatTimestamps, barTimestamps, lyricSyllablesPerSecond
        case lyricSyllablesPerBeat, energy, key, mood, sections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.schemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: c,
                                                    debugDescription: "Unsupported SongDNA schema")
        }
        self.init(assetID: try c.decode(String.self, forKey: .assetID),
                  sourceRevision: try c.decode(String.self, forKey: .sourceRevision),
                  sourceDuration: try c.decode(TimeInterval.self, forKey: .sourceDuration),
                  bpm: try c.decode(Double.self, forKey: .bpm),
                  beatTimestamps: try c.decode([TimeInterval].self, forKey: .beatTimestamps),
                  barTimestamps: try c.decodeIfPresent([TimeInterval].self, forKey: .barTimestamps) ?? [],
                  lyricSyllablesPerSecond: try c.decodeIfPresent(Double.self, forKey: .lyricSyllablesPerSecond) ?? 0,
                  lyricSyllablesPerBeat: try c.decodeIfPresent(Double.self, forKey: .lyricSyllablesPerBeat) ?? 0,
                  energy: try c.decode(Float.self, forKey: .energy),
                  key: try c.decodeIfPresent(KeyAnalysisResult.self, forKey: .key),
                  mood: try c.decodeIfPresent(MoodHintsResult.self, forKey: .mood),
                  sections: try c.decode([MusicSection].self, forKey: .sections))
    }

    var isValid: Bool {
        guard !assetID.isEmpty, !sourceRevision.isEmpty,
              sourceDuration.isFinite, sourceDuration > 0,
              bpm.isFinite, (bpm == 0 || (55...210).contains(bpm)),
              energy.isFinite, (0...1).contains(energy),
              schemaVersion == Self.schemaVersion,
              lyricSyllablesPerSecond.isFinite, lyricSyllablesPerSecond >= 0,
              lyricSyllablesPerBeat.isFinite, lyricSyllablesPerBeat >= 0,
              beatTimestamps.count <= 5_000, barTimestamps.count <= 1_250,
              sections.count <= 8_192,
              key?.isValid(sourceDuration: sourceDuration) ?? true,
              mood?.isValid(sourceDuration: sourceDuration) ?? true else { return false }
        var previousBeat = -Double.infinity
        for beat in beatTimestamps {
            guard beat.isFinite, beat >= 0, beat <= sourceDuration,
                  beat > previousBeat else { return false }
            previousBeat = beat
        }
        var previousBar = -Double.infinity
        for bar in barTimestamps {
            guard bar.isFinite, bar >= 0, bar <= sourceDuration,
                  bar > previousBar else { return false }
            previousBar = bar
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


/// All section lookups execute on a background actor. The SwiftUI/audio paths
/// receive only the last immutable modulation; no per-frame cache traversal.
actor SongSectionTracker {
    func modulation(for dna: SongDNA?, sourceTime: TimeInterval,
                    enabled: Bool) -> SongSectionCadence {
        // SongDNA validity is checked once before publishing it to the player.
        // A background actor performs only binary search during playback.
        guard enabled, let dna else { return .neutral }
        return SongSectionCadence.at(sourceTime: sourceTime, dna: dna)
    }
}
