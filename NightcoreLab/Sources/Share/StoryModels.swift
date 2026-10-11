import Foundation
import SwiftUI

/// Frozen presentation state: a Story cannot change when playback, theme or lyrics change.
enum StoryMode: String, Sendable {
    case player, lyrics
}

enum StoryLyricTypography: String, CaseIterable, Identifiable, Sendable {
    case classic, neon, mono, cinematic, typewriter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Clássica"
        case .neon: return "Neon"
        case .mono: return "Mono"
        case .cinematic: return "Cinema"
        case .typewriter: return "Máquina"
        }
    }
    var font: Font {
        switch self {
        case .classic: return .system(size: 35, weight: .heavy, design: .rounded)
        case .neon: return .system(size: 35, weight: .black, design: .rounded)
        case .mono: return .system(size: 30, weight: .bold, design: .monospaced)
        case .cinematic: return .system(size: 37, weight: .bold, design: .serif)
        case .typewriter: return .system(size: 31, weight: .semibold, design: .monospaced)
        }
    }
    var tracking: CGFloat { self == .cinematic ? 0.6 : 0 }
}

struct StoryVideoRequest: Sendable {
    static let maxSeconds: TimeInterval = 15
    static let size = CGSize(width: 540, height: 960)
    static let fps: Int32 = 30

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
    let typography: StoryLyricTypography
    let includeAudio: Bool

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
                     typography: StoryLyricTypography, includeAudio: Bool) throws -> StoryVideoRequest {
        if mode == .lyrics && lines.isEmpty { throw StoryRequestError.lyricsUnavailable }
        let safeSpeed = max(Double(speed), 0.1)
        let start = min(max(playbackTime, 0), sourceDuration)
        let seconds = min(StoryVideoRequest.maxSeconds, max(0, sourceDuration - start) / safeSpeed)
        guard seconds > 0.05 else { throw StoryRequestError.noRemainingAudio }
        return StoryVideoRequest(
            mode: mode, trackID: track.id, title: track.title, artist: track.artist,
            artworkURL: track.coverURL, theme: theme, playerStyle: playerStyle,
            karaokeBackground: karaokeBackground, marblePhase: marblePhase,
            marbleSpeed: mode == .lyrics ? 0.8 : 0.6,
            playbackTime: start, speed: speed, duration: seconds,
            totalSourceDuration: sourceDuration, lines: lines, lyricOffset: lyricOffset,
            typography: typography, includeAudio: includeAudio
        )
    }
}
