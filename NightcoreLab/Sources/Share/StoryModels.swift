import Foundation
import SwiftUI

/// Frozen presentation state: a Story cannot change when playback, theme or lyrics change.
enum StoryMode: String, Sendable {
    case player, lyrics
}

/// Small immutable result badge. Passive and simulated runs are clearly named.
struct KaraokePerformanceStamp: Equatable, Sendable {
    let grade: String
    let score: Int
    let accuracy: Int
    let mode: KaraokeScoringSession.Mode

    init?(snapshot: KaraokeScoreSnapshot, mode: KaraokeScoringSession.Mode) {
        guard mode != .off, snapshot.judgedVerses > 0 else { return nil }
        grade = snapshot.rank
        score = snapshot.totalScore
        accuracy = Int(snapshot.accuracyPercentage.rounded())
        self.mode = mode
    }

    var label: String {
        switch mode {
        case .microphone: return "CANTO AO VIVO"
        case .simulation: return "SIMULAÇÃO"
        case .passive: return "RITMO DA FAIXA"
        case .off: return ""
        }
    }
}

struct StoryVideoRequest: Sendable {
    static let maxSeconds: TimeInterval = 15
    static let size = CGSize(width: 540, height: 960)
    static let fps: Int32 = 20

    let mode: StoryMode
    let trackID: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let theme: AppTheme
    let playerStyle: PlayerBackgroundStyle
    let karaokeBackground: BackgroundStyle
    let marblePhase: Float
    let marbleSpeed: Float
    let playbackTime: TimeInterval
    let speed: Float
    let duration: TimeInterval
    let totalSourceDuration: TimeInterval
    let lines: [TimedLyricLine]
    let lyricOffset: TimeInterval
    /// Frozen effect + font. The same value the live karaoke resolves with,
    /// so the Story reproduces the user's typography instead of a fixed Neon.
    var typographyPreset: TypographyPreset
    let includeAudio: Bool
    /// Frozen declarative recipe; nil means the pre-existing Marble appearance.
    let reactiveProgram: CreativeVisualProgram?
    /// The same local source file already loaded by the player.
    let reactiveSourceURL: URL?
    /// Frozen and compiled ONCE by StoryRequestBuilder (Stage 10C): preview
    /// scrubbing and every exported frame reuse it instead of recompiling.
    /// The original reactiveProgram stays available for callers still using
    /// the legacy compatibility contract.
    var compositionRuntime: CompositionRuntime? = nil
    /// Per-line stable word seeds and Magazine looks, prepared once.
    var preparedLyrics: [Int: TypographyPreparedLine] = [:]
    /// Stage 12.5: the selected experience's typography audio envelope,
    /// frozen with the preset (disabled for recipes or without reaction).
    var typographyAudioMapping: CreativeAudioMapping = .disabled
    /// Frozen once per editor selection; shared by preview and export.
    var layoutPolicy: CompositionLayoutPolicy? = nil
    var creatorParameters: CreatorParameterSet = .neutral
    /// Frozen source-time pad take, including the optional magnetic grid.
    /// Copy-on-write immutable value used by preview and offline exporter.
    var padPerformance: PerformanceTimeline? = nil
    /// Frozen live selection and source-matched musical intelligence.
    var experienceID: String = CreativePresetCatalog.defaultID
    var reactionMode: CreativePreset.AudioReaction = .off
    var songDNA: SongDNA? = nil
    var scoreStamp: KaraokePerformanceStamp? = nil
    var showsScoreStamp = true

    /// The active line's typography layer at a lyric time. The ONE builder
    /// used by StorySceneView (MP4) and StoryDraftPreview (scrub preview).
    func typographyLayer(atLyricTime lyricTime: TimeInterval) -> TypographyLayer? {
        TypographyLayer.forStory(
            lines: lines, lyricTime: lyricTime, lyricOffset: lyricOffset,
            preset: typographyPreset, prepared: preparedLyrics,
            experienceMapping: typographyAudioMapping)
    }

    /// The runtime every Story frame resolves through. Requests from
    /// StoryRequestBuilder carry a frozen one; a request assembled without it
    /// (direct/legacy construction) gets one frozen from its reactive program,
    /// or a neutral recipe, so there is no second resolution path.
    var renderRuntime: CompositionRuntime? {
        if let compositionRuntime { return compositionRuntime }
        let program = reactiveProgram ?? CreativePresetCatalog.effectiveProgram(
            id: CreativePresetCatalog.defaultID, theme: theme,
            typography: typographyPreset.style, background: playerStyle, reaction: .off)
        return CompositionRuntime.freeze(
            program: program, sourceStart: playbackTime,
            speed: Double(speed), duration: duration
        ).map { CompositionRuntime(composition: $0) }
    }

    /// THE resolved state of one Story frame. The scrub preview
    /// (StoryDraftPreview) and the exporter (StorySceneView) both call this
    /// with the same audio timeline and rhythm analysis, so they receive the
    /// same timestamp, AudioFeatures, RhythmFrame, material and typography.
    func resolvedFrame(_ frame: StoryRenderFrame,
                       audioTimeline: AudioFeatureTimeline?,
                       rhythm: RhythmAnalysisResult?,
                       runtime: CompositionRuntime? = nil) -> ResolvedCompositionFrame? {
        let resolved = (runtime ?? renderRuntime)?.frame(
            at: frame.elapsed, audioTimeline: audioTimeline,
            typography: typographyLayer(atLyricTime: frame.lyricTime),
            rhythmAnalysis: rhythm, performance: padPerformance,
            padAccent: frame.padAccent)
        guard var resolved else { return nil }
        let cadence = reactionMode == .off ? SongSectionCadence.neutral :
            SongSectionCadence.at(sourceTime: frame.sourceTime, dna: songDNA)
        if let typography = resolved.typographyFrame {
            resolved = resolved.withTypography(
                TypographyAnimationEngine.evolve(typography, cadence: cadence))
        }
        if let material = resolved.materialFrame, reactionMode != .off {
            let features = CompositionAudioSampler.sample(audioTimeline, at: frame.sourceTime)
            let pulse = max(material.parameters.beatPulse,
                            StoryBeatEnvelope.at(sourceTime: frame.sourceTime, dna: songDNA))
            let levels = LiveAudioLevels(
                rms: features?.energy ?? 0, bass: features?.bass ?? 0,
                onset: 0, beatPulse: pulse,
                songEnergy: features?.energy ?? 0)
            let reactive = MarbleLiveResponse.apply(material, levels: levels, mode: reactionMode)
            resolved = resolved.withMaterial(SongSectionCadence.apply(
                reactive, cadence: cadence))
        }
        return resolved
    }

    /// Source-compatible view of the frozen composition.
    var visualComposition: VisualComposition? {
        get { compositionRuntime?.composition }
        set { compositionRuntime = newValue.map { CompositionRuntime(composition: $0) } }
    }

    /// Source audio and word timings refer to the original unaccelerated timeline.
    var frameCount: Int { max(1, Int(ceil(duration * Double(Self.fps)))) }
    func sourceTime(at elapsed: TimeInterval) -> TimeInterval {
        playbackTime + elapsed * Double(speed)
    }
    func lyricTime(at elapsed: TimeInterval) -> TimeInterval {
        sourceTime(at: elapsed) + lyricOffset
    }
    func marbleTime(at elapsed: TimeInterval) -> Float {
        marblePhase + Float(elapsed) * marbleSpeed
    }
    func activeLine(at elapsed: TimeInterval) -> TimedLyricLine? {
        let t = lyricTime(at: elapsed)
        return lines.last(where: { $0.start <= t && t < $0.end })
    }
    var canExportLyrics: Bool { !lines.isEmpty }
    /// Font family, kept for existing callers; derived from the frozen preset.
    var typography: TypographyFont { typographyPreset.font }
}

enum StoryRequestError: LocalizedError {
    case noRemainingAudio, lyricsUnavailable
    var errorDescription: String? {
        switch self {
        case .noRemainingAudio: return "Não há 15 segundos disponíveis a partir desta posição."
        case .lyricsUnavailable: return "A letra sincronizada ainda não está disponível."
        }
    }
}

enum StoryRequestBuilder {
    static func make(mode: StoryMode, track: TrackInfo, theme: AppTheme,
                     playerStyle: PlayerBackgroundStyle, karaokeBackground: BackgroundStyle,
                     marblePhase: Float, playbackTime: TimeInterval, sourceDuration: TimeInterval,
                     speed: Float, lines: [TimedLyricLine], lyricOffset: TimeInterval,
                     typography: TypographyFont,
                     typographyStyle: TypographyStyle = .neon,
                     includeAudio: Bool,
                     reactiveProgram: CreativeVisualProgram? = nil,
                     reactiveSourceURL: URL? = nil,
                     creativePresetID: String = CreativePresetCatalog.defaultID,
                     padPerformance: PerformanceTimeline? = nil,
                     reactionMode: CreativePreset.AudioReaction? = nil,
                     songDNA: SongDNA? = nil,
                     scoreStamp: KaraokePerformanceStamp? = nil) throws -> StoryVideoRequest {
        if mode == .lyrics && lines.isEmpty { throw StoryRequestError.lyricsUnavailable }
        let safeSpeed = max(Double(speed), 0.1)
        let start = min(max(playbackTime, 0), sourceDuration)
        let seconds = min(StoryVideoRequest.maxSeconds, max(0, sourceDuration - start) / safeSpeed)
        guard seconds > 0.05 else { throw StoryRequestError.noRemainingAudio }
        // Typography reacts to audio only when the visuals do (same gate as
        // the live karaoke, which only gets features while reacting).
        let activeReaction = reactionMode ?? reactiveProgram?.preset.audioReaction ?? .off
        let reacts = activeReaction != .off
        var request = StoryVideoRequest(
            mode: mode, trackID: track.id, title: track.title, artist: track.artist,
            artworkURL: track.coverURL, theme: theme, playerStyle: playerStyle,
            karaokeBackground: karaokeBackground, marblePhase: marblePhase,
            marbleSpeed: mode == .lyrics ? 0.8 : 0.6,
            playbackTime: start, speed: speed, duration: seconds,
            totalSourceDuration: sourceDuration, lines: lines, lyricOffset: lyricOffset,
            typographyPreset: CreativePresetCatalog.typographyPreset(
                selection: creativePresetID, style: typographyStyle,
                font: typography, reacts: reacts),
            includeAudio: includeAudio,
            reactiveProgram: reactiveProgram,
            reactiveSourceURL: reactiveSourceURL
        )
        // A sound/visual pad take is frozen with this request. No capture
        // or cache read is performed during preview and export frame loops.
        request.padPerformance = padPerformance?.isValid == true
            ? padPerformance : nil
        request.experienceID = creativePresetID
        request.reactionMode = activeReaction
        request.songDNA = songDNA?.isValid == true ? songDNA : nil
        request.scoreStamp = scoreStamp
        // One immutable source of truth for preview and the StoryFrameRenderer
        // scene. Do not rebuild from a potentially changed preset during export.
        // Always freeze a composition (ported from Stage 10A): with audio
        // reaction off, the selected recipe with reaction .off resolves to the
        // neutral Marble, so pixels match the legacy path while layers and
        // typography still flow through the single runtime.
        let effective = reactiveProgram ?? CreativePresetCatalog.effectiveProgram(
            id: creativePresetID, theme: theme, typography: typographyStyle,
            background: playerStyle, reaction: .off)
        request.visualComposition = CompositionRuntime.freeze(
            program: effective, sourceStart: start,
            speed: Double(speed), duration: seconds,
            deterministicSeed: CreativePresetCatalog.selectedExperience(id: creativePresetID)?
                .composition.deterministicSeed ?? 0)
        if let composition = request.visualComposition {
            request.compositionRuntime = CompositionRuntime(
                composition: composition,
                // Single material rule, applied to the program actually frozen.
                material: CreativeExperienceResolver.material(
                    experience: CreativePresetCatalog.selectedExperience(id: creativePresetID),
                    recipe: effective))
        }
        request.typographyAudioMapping = CreativePresetCatalog.typographyAudioMapping(
            selection: creativePresetID, style: typographyStyle, reacts: reacts)
        request.preparedLyrics = Dictionary(
            lines.map { ($0.id, TypographyPreparedLine($0)) },
            uniquingKeysWith: { first, _ in first })
        return request
    }
}
