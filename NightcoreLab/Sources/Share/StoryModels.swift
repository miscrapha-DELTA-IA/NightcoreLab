import Foundation
import SwiftUI

/// Frozen presentation state: a Story cannot change when playback, theme or lyrics change.
enum StoryMode: String, Sendable {
    case player, lyrics
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
    let typographyPreset: TypographyPreset
    let includeAudio: Bool
    /// Frozen declarative recipe; nil means the pre-existing Marble appearance.
    let reactiveProgram: CreativeVisualProgram?
    /// The same local source file already loaded by the player.
    let reactiveSourceURL: URL?
    /// Frozen only by StoryRequestBuilder. The original reactiveProgram stays
    /// available for callers still using the legacy compatibility contract.
    var visualComposition: VisualComposition? = nil

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
                     reactiveSourceURL: URL? = nil) throws -> StoryVideoRequest {
        if mode == .lyrics && lines.isEmpty { throw StoryRequestError.lyricsUnavailable }
        let safeSpeed = max(Double(speed), 0.1)
        let start = min(max(playbackTime, 0), sourceDuration)
        let seconds = min(StoryVideoRequest.maxSeconds, max(0, sourceDuration - start) / safeSpeed)
        guard seconds > 0.05 else { throw StoryRequestError.noRemainingAudio }
        var request = StoryVideoRequest(
            mode: mode, trackID: track.id, title: track.title, artist: track.artist,
            artworkURL: track.coverURL, theme: theme, playerStyle: playerStyle,
            karaokeBackground: karaokeBackground, marblePhase: marblePhase,
            marbleSpeed: mode == .lyrics ? 0.8 : 0.6,
            playbackTime: start, speed: speed, duration: seconds,
            totalSourceDuration: sourceDuration, lines: lines, lyricOffset: lyricOffset,
            typographyPreset: .current(style: typographyStyle, font: typography),
            includeAudio: includeAudio,
            reactiveProgram: reactiveProgram,
            reactiveSourceURL: reactiveSourceURL
        )
        // One immutable source of truth for preview and the StoryFrameRenderer
        // scene. Do not rebuild from a potentially changed preset during export.
        request.visualComposition = CompositionRuntime.freeze(
            program: reactiveProgram, sourceStart: start,
            speed: Double(speed), duration: seconds)
        return request
    }
}
